import 'dart:io';

import 'package:team_logger/team_logger.dart';
import 'package:team_logger/team_logger_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('collect_files_test');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('returns current and past sessions, newest first', () async {
    // Fake past session, one day old.
    final pastId = sessionIdFrom(
      DateTime.now().toUtc().subtract(const Duration(days: 1)),
      'aaaa',
    );
    File('${dir.path}/${chunkFileName(pastId, 0)}').writeAsStringSync('{}\n');
    File('${dir.path}/${chunkFileName(pastId, 1)}').writeAsStringSync('{}\n');
    File('${dir.path}/foreign.txt').writeAsStringSync('not a log');

    final storage = FileLogStorage(directory: dir);
    final log = Logger('test')
      ..level = LogLevels.all
      ..publisher = storage;

    log.i('last-moment record');
    final files = await storage.collectFiles();

    final names = files.map((f) => f.uri.pathSegments.last).toList();
    expect(names, hasLength(3));
    // Current session first, then past session chunks in write order.
    expect(names[0], contains(storage.sessionId));
    expect(names[1], chunkFileName(pastId, 0));
    expect(names[2], chunkFileName(pastId, 1));
    expect(names.any((n) => n == 'foreign.txt'), isFalse);

    // The record logged right before collect is already on disk.
    expect(files[0].readAsStringSync(), contains('last-moment record'));

    await storage.close();
  });
}
