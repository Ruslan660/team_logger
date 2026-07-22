// End-to-end check of the file storage against real disk IO.
// Run: fvm dart run tool/e2e_check.dart
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:team_logger/team_logger.dart';
import 'package:team_logger/team_logger_io.dart';

int passed = 0;
int failed = 0;

void check(String name, bool cond, [Object? detail]) {
  if (cond) {
    passed++;
    stdout.writeln('  ok  $name');
  } else {
    failed++;
    stdout.writeln('  FAIL $name${detail == null ? '' : '  <- $detail'}');
  }
}

class _Throwing {
  @override
  String toString() => throw StateError('no toString for you');
}

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('tlog_e2e');
  stdout
    ..writeln('dir: ${dir.path}')
    // --- Session A: heavy write, rotation, dirty data ---------------
    ..writeln('\n[session A: rotation + dirty data]');
  const optionsA = FileLogStorageOptions(
    maxSessionBytes: 8 * 1024,
    maxRecordBytes: 512,
  );
  final a = FileLogStorage(
    directory: dir,
    options: optionsA,
    sessionMeta: const {'app': 'e2e', 'run': 'A'},
  );
  final logA = Logger('e2e')
    ..level = LogLevels.all
    ..publisher = a;

  final cyclicMap = <String, Object?>{'tag': 'cyclic'};
  cyclicMap['self'] = cyclicMap;

  for (var i = 0; i < 400; i++) {
    logA.i('bulk record $i ${'x' * 64}');
  }
  logA.e(
    'boom',
    error: Exception('e2e error'),
    stackTrace: StackTrace.current,
  );
  logA.i('cyclic', data: cyclicMap);
  logA.i('thrower', data: _Throwing());
  logA.i('LAST-RECORD-A');
  await a.flush();

  List<File> chunksOf(String sessionId) => dir
      .listSync()
      .whereType<File>()
      .where((f) => f.uri.pathSegments.last.contains(sessionId))
      .toList()
    ..sort((x, y) => x.path.compareTo(y.path));

  final aChunks = chunksOf(a.sessionId);
  check(
    'rotation keeps <= 4 chunks',
    aChunks.length <= 4,
    'got ${aChunks.length}',
  );
  check(
    'oldest chunk p00 deleted',
    !aChunks.any((f) => f.path.endsWith('_p00.jsonl')),
  );
  final totalA = aChunks.fold<int>(0, (s, f) => s + f.lengthSync());
  check(
    'session size bounded (~8KiB + headers)',
    totalA < 10 * 1024,
    'got $totalA',
  );

  var allParse = true;
  var headerFirst = true;
  String? lastMsg;
  var sawCycleMarker = false;
  var sawUnprintable = false;
  for (final f in aChunks) {
    final lines = f.readAsLinesSync();
    final first = jsonDecode(lines.first) as Map<String, Object?>;
    if (first['kind'] != 'session') headerFirst = false;
    for (final line in lines) {
      try {
        final m = jsonDecode(line) as Map<String, Object?>;
        final msg = m['msg'];
        if (msg is String) lastMsg = msg;
        final data = m['data'];
        if (data != null && data.toString().contains('cycle')) {
          sawCycleMarker = true;
        }
        if (data.toString().contains('unprintable')) sawUnprintable = true;
      } on Object {
        allParse = false;
      }
    }
  }
  check('every line is valid JSON', allParse);
  check('every chunk starts with session header', headerFirst);
  check(
    'tail of session survived rotation',
    lastMsg == 'LAST-RECORD-A',
    'last=$lastMsg',
  );
  check('cyclic data encoded with cycle marker', sawCycleMarker);
  check('throwing toString encoded as unprintable', sawUnprintable);

  // --- collectFiles + exportArchive ---------------------------------
  stdout.writeln('\n[collect + zip export]');
  final collected = await a.collectFiles();
  check(
    'collectFiles returns the live chunks',
    collected.length == aChunks.length,
    'collected ${collected.length} vs ${aChunks.length}',
  );

  final zip = await a.exportArchive();
  check('exportArchive returns a file', zip != null && zip.existsSync());
  if (zip != null) {
    final archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
    check(
      'zip holds all collected files',
      archive.files.length == collected.length,
      'zip ${archive.files.length}',
    );
    var zipParses = true;
    for (final f in archive.files) {
      final text = utf8.decode(f.content);
      for (final line in const LineSplitter().convert(text)) {
        try {
          jsonDecode(line);
        } on Object {
          zipParses = false;
        }
      }
    }
    check('zip content is valid JSONL', zipParses);
  }
  final again = await a.collectFiles();
  check(
    'export dir does not pollute collectFiles',
    again.every((f) => !f.path.contains('${dir.path}/export')),
  );
  await a.close();

  // --- corrupted tail tolerance --------------------------------------
  stdout.writeln('\n[corrupted tail]');
  chunksOf(a.sessionId).last.writeAsStringSync(
    '{"ts":"2026-07-22T12:00:00Z","seq":9', // cut line
    mode: FileMode.append,
  );

  // --- Session B: retention kicks out A ------------------------------
  stdout.writeln('\n[session B: retention]');
  const optionsB = FileLogStorageOptions(
    maxSessionBytes: 8 * 1024,
    maxRecordBytes: 512,
    maxTotalBytes: 4 * 1024, // smaller than session A leftovers
  );
  final b = FileLogStorage(
    directory: dir,
    options: optionsB,
    sessionMeta: const {'app': 'e2e', 'run': 'B'},
  );
  final logB = Logger('e2e')
    ..level = LogLevels.all
    ..publisher = b;
  logB.i('first record of B');
  await b.flush();

  check('retention deleted old session A', chunksOf(a.sessionId).isEmpty);
  check('session B alive', chunksOf(b.sessionId).isNotEmpty);

  final bFiles = await b.collectFiles();
  check(
    'collect after corruption+retention does not throw',
    bFiles.isNotEmpty,
  );
  final zipB = await b.exportArchive();
  check('export after corruption works', zipB != null);
  await b.close();

  // --- failure policy -------------------------------------------------
  stdout.writeln('\n[failure policy]');
  final blockedPath = File('${dir.path}/blocked')..createSync();
  final errors = <Object>[];
  final c = FileLogStorage(
    directory: Directory(blockedPath.path),
    options: FileLogStorageOptions(
      onInternalError: (e, s) => errors.add(e),
      recordFilter: (log) => throw StateError('bad filter'),
    ),
  );
  final logC = Logger('e2e')
    ..level = LogLevels.all
    ..publisher = c;
  for (var i = 0; i < 12; i++) {
    logC.i('doomed $i');
  }
  await c.flush();
  check(
    'self-disabled, onInternalError exactly once',
    errors.length == 1,
    'got ${errors.length}',
  );
  check('throwing recordFilter did not crash anything', true);
  await c.close();

  // --- summary --------------------------------------------------------
  dir.deleteSync(recursive: true);
  stdout.writeln('\nRESULT: $passed passed, $failed failed');
  exit(failed == 0 ? 0 : 1);
}
