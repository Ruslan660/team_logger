import 'dart:convert';

import 'package:team_logger/team_logger.dart';
import 'package:team_logger/team_logger_io.dart';
import 'package:test/test.dart';

/// Collects every published [Log] so tests can encode real records.
List<Log> capture(void Function(Logger log) emit) {
  final captured = <Log>[];
  final logger = Logger('test')
    ..level = LogLevels.all
    ..publisher = CustomLogPublisher(captured.add);
  emit(logger);
  return captured;
}

class _Unserializable {
  @override
  String toString() => '<socket fd=3>';
}

void main() {
  group('encodeSessionHeader', () {
    test('writes one JSON line with session identity and meta', () {
      final line = encodeSessionHeader(
        sessionId: '20260722T104501-a3f2',
        startedAt: DateTime.utc(2026, 7, 22, 10, 45, 1, 123),
        meta: {'app': 'client', 'version': '1.42.0'},
      );

      expect(line, endsWith('\n'));
      final json = jsonDecode(line) as Map<String, Object?>;
      expect(json['kind'], 'session');
      expect(json['schema'], 1);
      expect(json['sessionId'], '20260722T104501-a3f2');
      expect(json['startedAt'], '2026-07-22T10:45:01.123Z');
      expect(json['meta'], {'app': 'client', 'version': '1.42.0'});
    });
  });

  group('encodeLog', () {
    test('writes core fields, omits absent ones', () {
      final log = capture((log) => log.i('hello')).single;

      final line = encodeLog(log, maxRecordBytes: 32 * 1024);

      expect(line, endsWith('\n'));
      final json = jsonDecode(line) as Map<String, Object?>;
      expect(json['ts'], endsWith('Z'));
      expect(json['seq'], log.sequenceNum);
      expect(json['lvl'], LogLevels.info);
      expect(json['lvlName'], 'info');
      expect(json['path'], 'test');
      expect(json['msg'], 'hello');
      expect(json.containsKey('trace'), isFalse);
      expect(json.containsKey('tags'), isFalse);
      expect(json.containsKey('data'), isFalse);
      expect(json.containsKey('err'), isFalse);
      expect(json.containsKey('stack'), isFalse);
      expect(json.containsKey('trunc'), isFalse);
    });

    test('writes tags, data, error and stack when present', () {
      final log = capture(
        (log) => log.e(
          'boom',
          data: {'a': 1},
          tags: 'net',
          error: Exception('bad'),
          stackTrace: StackTrace.fromString('#0 main (main.dart:1)'),
        ),
      ).single;

      final json =
          jsonDecode(encodeLog(log, maxRecordBytes: 32 * 1024))
              as Map<String, Object?>;
      expect(json['tags'], ['net']);
      expect(json['data'], {'a': 1});
      expect(json['err'], 'Exception: bad');
      expect(json['stack'], '#0 main (main.dart:1)');
    });

    test('unserializable data falls back to toString', () {
      final log = capture(
        (log) => log.i('x', data: {'conn': _Unserializable()}),
      ).single;

      final json =
          jsonDecode(encodeLog(log, maxRecordBytes: 32 * 1024))
              as Map<String, Object?>;
      expect(json['data'], {'conn': '<socket fd=3>'});
    });

    test('oversized record is truncated: stack first, msg last', () {
      final log = capture(
        (log) => log.e(
          'M' * 500,
          data: {'blob': 'D' * 2000},
          error: Exception('bad'),
          stackTrace: StackTrace.fromString('#0 f\n' * 1000),
        ),
      ).single;

      final line = encodeLog(log, maxRecordBytes: 1024);

      expect(utf8.encode(line).length, lessThanOrEqualTo(1024));
      final json = jsonDecode(line) as Map<String, Object?>;
      expect(json['trunc'], isTrue);
      // Stack and data are sacrificed, message survives.
      expect(json['msg'], 'M' * 500);
      // Stack is capped at 256 bytes plus the marker.
      expect((json['stack']! as String).length, lessThan(300));
      expect(json['data'], contains('truncated'));
    });

    test('oversized message alone still fits the cap', () {
      final log = capture((log) => log.i('M' * 5000)).single;

      final line = encodeLog(log, maxRecordBytes: 1024);

      expect(utf8.encode(line).length, lessThanOrEqualTo(1024));
      final json = jsonDecode(line) as Map<String, Object?>;
      expect(json['trunc'], isTrue);
      expect(json['msg'], contains('truncated'));
    });
  });

  group('json safety', () {
    test('cyclic data does not hang or throw', () {
      final map = <String, Object?>{'a': 1};
      map['self'] = map;
      final log = capture((log) => log.i('x', data: map)).single;

      final json = jsonDecode(encodeLog(log, maxRecordBytes: 32 * 1024))
          as Map<String, Object?>;
      expect((json['data']! as Map)['self'], '…[cycle]');
    });

    test('non-string map keys become strings', () {
      final log = capture((log) => log.i('x', data: {1: 'one'})).single;

      final json = jsonDecode(encodeLog(log, maxRecordBytes: 32 * 1024))
          as Map<String, Object?>;
      expect(json['data'], {'1': 'one'});
    });

    test('fallback record always fits and parses', () {
      final log = capture((log) => log.e('boom')).single;

      final line = encodeFallbackLog(log, reason: 'test reason');

      expect(utf8.encode(line).length, lessThan(512));
      final json = jsonDecode(line) as Map<String, Object?>;
      expect(json['seq'], log.sequenceNum);
      expect(json['msg'], contains('test reason'));
      expect(json['trunc'], isTrue);
    });
  });
}

