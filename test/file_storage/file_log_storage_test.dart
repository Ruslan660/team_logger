import 'dart:convert';
import 'dart:io';

import 'package:team_logger/team_logger.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('file_log_storage_test');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Logger loggerFor(FileLogStorage storage) => Logger('test')
    ..level = LogLevels.all
    ..publisher = storage;

  List<File> chunkFiles() => (dir
          .listSync()
          .whereType<File>()
          .where((f) => parseFileName(f.uri.pathSegments.last) != null)
          .toList())
    ..sort((a, b) => a.path.compareTo(b.path));

  test('writes header line first, then records', () async {
    final storage = FileLogStorage(
      directory: dir,
      sessionMeta: const {'app': 'client'},
    );
    final log = loggerFor(storage);

    log.i('first');
    log.w('second');
    await storage.flush();

    final lines = chunkFiles().single.readAsLinesSync();
    expect(lines, hasLength(3));

    final header = jsonDecode(lines[0]) as Map<String, Object?>;
    expect(header['kind'], 'session');
    expect(header['sessionId'], storage.sessionId);
    expect(header['meta'], {'app': 'client'});

    expect((jsonDecode(lines[1]) as Map)['msg'], 'first');
    expect((jsonDecode(lines[2]) as Map)['msg'], 'second');

    await storage.close();
  });

  test('rotates chunks and drops the oldest, keeping the tail', () async {
    final storage = FileLogStorage(
      directory: dir,
      options: const FileLogStorageOptions(
        maxSessionBytes: 4 * 1024,
        maxRecordBytes: 512,
      ),
    );
    final log = loggerFor(storage);

    for (var i = 0; i < 200; i++) {
      log.i('record number $i padded ${'x' * 80}');
    }
    await storage.flush();

    final files = chunkFiles();
    expect(files.length, lessThanOrEqualTo(4));

    final parts = files
        .map((f) => parseFileName(f.uri.pathSegments.last)!.part)
        .toList();
    expect(parts.contains(0), isFalse); // oldest chunk is gone

    // Every chunk starts with a session header.
    for (final file in files) {
      final first = jsonDecode(file.readAsLinesSync().first) as Map;
      expect(first['kind'], 'session');
    }

    // The last record survived rotation.
    final allLines = files.expand((f) => f.readAsLinesSync()).toList();
    expect(
      allLines.any((l) => l.contains('record number 199')),
      isTrue,
    );

    await storage.close();
  });

  test('session stays within maxSessionBytes', () async {
    final storage = FileLogStorage(
      directory: dir,
      options: const FileLogStorageOptions(
        maxSessionBytes: 4 * 1024,
        maxRecordBytes: 512,
      ),
    );
    final log = loggerFor(storage);

    for (var i = 0; i < 500; i++) {
      log.i('padded record $i ${'y' * 100}');
    }
    await storage.flush();

    final total = chunkFiles().fold<int>(0, (s, f) => s + f.lengthSync());
    // Header duplication adds a little slack on top of the raw cap.
    expect(total, lessThan(5 * 1024));

    await storage.close();
  });

  test('disables itself after 5 consecutive failures, reports once',
      () async {
    final errors = <Object>[];
    // A file where the directory should be: every init attempt fails.
    final blocked = File('${dir.path}/blocked')..createSync();
    final storage = FileLogStorage(
      directory: Directory(blocked.path),
      options: FileLogStorageOptions(
        onInternalError: (e, s) => errors.add(e),
      ),
    );
    final log = loggerFor(storage);

    for (var i = 0; i < 10; i++) {
      log.i('doomed $i');
    }
    await storage.flush();

    expect(errors, hasLength(1));
    await storage.close();
  });

  test('minLevel and recordFilter skip records', () async {
    final storage = FileLogStorage(
      directory: dir,
      options: FileLogStorageOptions(
        minLevel: LogLevels.info,
        recordFilter: (log) => !log.message.contains('secret'),
      ),
    );
    final log = loggerFor(storage);

    log.d('below level');
    log.i('normal');
    log.i('with secret inside');
    await storage.flush();

    final lines = chunkFiles().single.readAsLinesSync();
    expect(lines, hasLength(2)); // header + 'normal'
    expect(lines[1], contains('normal'));

    await storage.close();
  });
}
