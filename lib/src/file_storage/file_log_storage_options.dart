import '../logger/log_levels.dart';
import '../logger/logger.dart';

/// Limits and policies for `FileLogStorage`.
///
/// Defaults are sized for mobile support logs: a session is capped at 2 MiB,
/// the whole log directory at 20 MiB, and nothing older than a week survives.
final class FileLogStorageOptions {
  /// Upper bound for one session on disk (all chunks together).
  final int maxSessionBytes;

  /// How many rotation chunks a session is split into.
  ///
  /// When the session outgrows [maxSessionBytes], the oldest chunk is
  /// deleted, so the tail of the session is what survives.
  final int chunksPerSession;

  /// Sessions older than this are deleted on startup.
  final Duration maxAge;

  /// Upper bound for the whole log directory.
  final int maxTotalBytes;

  /// Upper bound for a single encoded record. Longer records get their
  /// stack, data and message truncated (in that order).
  final int maxRecordBytes;

  /// Records below this level are not written.
  final int minLevel;

  /// Optional per-record filter. Return `false` to skip the record.
  final bool Function(Log log)? recordFilter;

  /// Called once if the storage disables itself after repeated IO errors.
  final void Function(Object error, StackTrace stackTrace)? onInternalError;

  const FileLogStorageOptions({
    this.maxSessionBytes = 2 * 1024 * 1024,
    this.chunksPerSession = 4,
    this.maxAge = const Duration(days: 7),
    this.maxTotalBytes = 20 * 1024 * 1024,
    this.maxRecordBytes = 32 * 1024,
    this.minLevel = LogLevels.all,
    this.recordFilter,
    this.onInternalError,
  })  : assert(maxSessionBytes > 0, 'maxSessionBytes must be positive'),
        assert(chunksPerSession > 0, 'chunksPerSession must be positive'),
        assert(maxTotalBytes > 0, 'maxTotalBytes must be positive'),
        assert(maxRecordBytes > 0, 'maxRecordBytes must be positive'),
        assert(
          maxRecordBytes < maxSessionBytes / chunksPerSession,
          'a single record must fit into one chunk',
        );

  /// Size of one rotation chunk.
  int get chunkBytes => maxSessionBytes ~/ chunksPerSession;
}
