import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:team_logger/team_logger.dart';
import 'package:team_logger/team_logger_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('export_archive_test');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('zips all session files into an immutable snapshot', () async {
    final storage = FileLogStorage(directory: dir);
    Logger('test')
      ..level = LogLevels.all
      ..publisher = storage
      ..i('hello archive');

    final zip = await storage.exportArchive();

    expect(zip, isNotNull);
    expect(zip!.existsSync(), isTrue);

    final archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
    expect(archive.files, hasLength(1));
    final content = utf8.decode(archive.files.single.content);
    expect(content, contains('"kind":"session"'));
    expect(content, contains('hello archive'));

    // The export directory itself must not pollute collectFiles().
    final files = await storage.collectFiles();
    expect(files.every((f) => !f.path.contains('/export/')), isTrue);

    await storage.close();
  });

  test('returns null when there is nothing to export', () async {
    final storage = FileLogStorage(directory: dir);

    expect(await storage.exportArchive(), isNull);

    await storage.close();
  });
}
