import 'package:team_logger/team_logger.dart';
import 'package:test/test.dart';

void main() {
  group('sessionIdFrom', () {
    test('builds id from UTC time and random suffix', () {
      final id = sessionIdFrom(DateTime.utc(2026, 7, 22, 10, 45, 1), 'a3f2');

      expect(id, '20260722T104501-a3f2');
    });
  });

  group('chunkFileName', () {
    test('builds chunk file name with zero-padded part', () {
      expect(
        chunkFileName('20260722T104501-a3f2', 3),
        'tlog_20260722T104501-a3f2_p03.jsonl',
      );
    });
  });

  group('parseFileName', () {
    test('parses its own output back', () {
      final info = parseFileName('tlog_20260722T104501-a3f2_p03.jsonl');

      expect(info, isNotNull);
      expect(info!.sessionId, '20260722T104501-a3f2');
      expect(info.startedAt, DateTime.utc(2026, 7, 22, 10, 45, 1));
      expect(info.startedAt.isUtc, isTrue);
      expect(info.part, 3);
    });

    test('returns null for foreign files', () {
      expect(parseFileName('foo.txt'), isNull);
      expect(parseFileName('tlog_garbage.jsonl'), isNull);
      expect(parseFileName('tlog_20261722T104501-a3f2_p00.jsonl'), isNull);
    });

    test('startedAt sorts sessions chronologically', () {
      final older = parseFileName('tlog_20260721T235959-0000_p00.jsonl')!;
      final newer = parseFileName('tlog_20260722T000000-ffff_p00.jsonl')!;

      expect(older.startedAt.isBefore(newer.startedAt), isTrue);
    });
  });
}
