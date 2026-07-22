import 'dart:io';

import 'package:team_logger/team_logger.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  final now = DateTime.utc(2026, 7, 22, 12);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('retention_test');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// Creates chunk files for a fake session started [age] before [now].
  String session(Duration age, {int chunks = 1, int chunkSize = 10}) {
    final id = sessionIdFrom(
      now.subtract(age),
      age.inMinutes.toRadixString(16).padLeft(4, '0'),
    );
    for (var part = 0; part < chunks; part++) {
      File('${dir.path}/${chunkFileName(id, part)}')
          .writeAsStringSync('x' * chunkSize);
    }
    return id;
  }

  List<String> names() =>
      dir.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

  const options = FileLogStorageOptions();

  test('deletes sessions older than maxAge with all their chunks', () async {
    final old = session(const Duration(days: 8), chunks: 3);
    final fresh = session(const Duration(hours: 1));

    await applyRetention(dir, options, currentSessionId: 'none', now: now);

    expect(names().where((n) => n.contains(old)), isEmpty);
    expect(names().where((n) => n.contains(fresh)), hasLength(1));
  });

  test('deletes oldest sessions until under maxTotalBytes', () async {
    const small = FileLogStorageOptions(
      maxTotalBytes: 250,
      maxRecordBytes: 100,
    );
    final oldest = session(const Duration(hours: 3), chunkSize: 100);
    session(const Duration(hours: 2), chunkSize: 100);
    session(const Duration(hours: 1), chunkSize: 100);

    await applyRetention(dir, small, currentSessionId: 'none', now: now);

    expect(names(), hasLength(2));
    expect(names().where((n) => n.contains(oldest)), isEmpty);
  });

  test('never deletes the current session', () async {
    const small = FileLogStorageOptions(
      maxTotalBytes: 100,
      maxRecordBytes: 50,
    );
    final current = session(const Duration(days: 30), chunkSize: 200);

    await applyRetention(dir, small, currentSessionId: current, now: now);

    expect(names().where((n) => n.contains(current)), hasLength(1));
  });

  test('ignores foreign files', () async {
    File('${dir.path}/foo.txt').writeAsStringSync('keep me');
    session(const Duration(days: 30));

    await applyRetention(dir, options, currentSessionId: 'none', now: now);

    expect(names(), ['foo.txt']);
  });
}
