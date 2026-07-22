import 'package:team_logger/team_logger.dart';
import 'package:test/test.dart';

void main() {
  group('FileLogStorageOptions', () {
    test('defaults match the spec', () {
      const options = FileLogStorageOptions();

      expect(options.maxSessionBytes, 2 * 1024 * 1024);
      expect(options.chunksPerSession, 4);
      expect(options.maxSessions, 10);
      expect(options.maxAge, const Duration(days: 7));
      expect(options.maxTotalBytes, 20 * 1024 * 1024);
      expect(options.maxRecordBytes, 32 * 1024);
      expect(options.minLevel, LogLevels.all);
      expect(options.recordFilter, isNull);
      expect(options.onInternalError, isNull);
    });

    test('chunkBytes is maxSessionBytes / chunksPerSession', () {
      const options = FileLogStorageOptions(
        maxSessionBytes: 1024 * 1024,
        chunksPerSession: 2,
      );

      expect(options.chunkBytes, 512 * 1024);
    });

    test('rejects invalid values', () {
      expect(
        () => FileLogStorageOptions(chunksPerSession: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => FileLogStorageOptions(maxSessions: -1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        // A single record must fit into a chunk.
        () => FileLogStorageOptions(
          maxSessionBytes: 64 * 1024,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
