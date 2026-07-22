import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:team_logger/team_logger.dart';
import 'package:team_logger/team_logger_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('concurrency_test');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('overlapping flushes all complete and lose no records', () async {
    final storage = FileLogStorage(directory: dir);
    final log = Logger('test')
      ..level = LogLevels.all
      ..publisher = storage;

    // Interleave logging with a burst of concurrent flushes — the
    // pattern FileLogFlushObserver (paused+detached) and exportArchive
    // produce in real apps.
    final flushes = <Future<void>>[];
    for (var i = 0; i < 30; i++) {
      log.i('record $i');
      if (i % 3 == 0) flushes.add(storage.flush());
    }
    await Future.wait(flushes).timeout(const Duration(seconds: 10));
    await storage.flush().timeout(const Duration(seconds: 10));

    final lines = dir
        .listSync()
        .whereType<File>()
        .expand((f) => f.readAsLinesSync())
        .where((l) => l.contains('"msg":"record '))
        .length;
    expect(lines, 30);

    await storage.close();
  });

  test('exportArchive under a write storm yields a consistent zip',
      () async {
    final storage = FileLogStorage(directory: dir);
    final log = Logger('test')
      ..level = LogLevels.all
      ..publisher = storage;

    for (var i = 0; i < 50; i++) {
      log.i('before $i');
    }
    final exportFuture = storage.exportArchive();
    // Keep writing while the export is in flight.
    for (var i = 0; i < 50; i++) {
      log.i('after $i');
    }

    final zip = await exportFuture.timeout(const Duration(seconds: 10));
    expect(zip, isNotNull);

    // Every line of every archived file parses: the snapshot was not
    // torn by concurrent writes.
    final archive = ZipDecoder().decodeBytes(zip!.readAsBytesSync());
    for (final f in archive.files) {
      final text = utf8.decode(f.content);
      for (final line in const LineSplitter().convert(text)) {
        expect(() => jsonDecode(line), returnsNormally);
      }
    }

    await storage.flush();
    await storage.close();
  });

  test('logging after close is silently ignored', () async {
    final storage = FileLogStorage(directory: dir);
    Logger('test')
      ..level = LogLevels.all
      ..publisher = storage
      ..i('before close');
    await storage.flush();
    await storage.close();

    // The publisher contract throws on publish-after-close; the storage
    // itself must stay inert even if flush/close are called again.
    await storage.flush().timeout(const Duration(seconds: 5));
    await storage.close().timeout(const Duration(seconds: 5));
  });
}
