import 'dart:io';

import 'file_log_storage_options.dart';
import 'session_file_name.dart';

/// Startup cleanup of the log directory.
///
/// Deletes whole sessions (all chunks at once), oldest first, in three
/// passes: older than `maxAge`, beyond `maxSessions`, and until the
/// directory fits `maxTotalBytes`. The current session and files with
/// foreign names are never touched. Deletion errors are swallowed:
/// retention must not break logging.
Future<void> applyRetention(
  Directory dir,
  FileLogStorageOptions options, {
  required String currentSessionId,
  required DateTime now,
}) async {
  final sessions = <String, _Session>{};

  await for (final entry in dir.list()) {
    if (entry is! File) continue;
    final info = parseFileName(entry.uri.pathSegments.last);
    if (info == null) continue;

    final session = sessions.putIfAbsent(
      info.sessionId,
      () => _Session(info.startedAt),
    );
    session.files.add(entry);
    try {
      session.bytes += await entry.length();
    } on IOException {
      // Sizes are best-effort; a vanished file just counts as zero.
    }
  }

  final past = sessions.entries
      .where((e) => e.key != currentSessionId)
      .toList()
    ..sort((a, b) => a.value.startedAt.compareTo(b.value.startedAt));

  var totalBytes =
      sessions.values.fold(0, (sum, session) => sum + session.bytes);

  Future<void> delete(MapEntry<String, _Session> entry) async {
    for (final file in entry.value.files) {
      try {
        await file.delete();
      } on IOException {
        // Best effort.
      }
    }
    totalBytes -= entry.value.bytes;
  }

  final deleted = <String>{};

  for (final entry in past) {
    if (now.difference(entry.value.startedAt) > options.maxAge) {
      await delete(entry);
      deleted.add(entry.key);
    }
  }

  final alive = past.where((e) => !deleted.contains(e.key)).toList();
  final overCount = alive.length - options.maxSessions;
  for (final entry in alive.take(overCount < 0 ? 0 : overCount)) {
    await delete(entry);
    deleted.add(entry.key);
  }

  for (final entry in past) {
    if (totalBytes <= options.maxTotalBytes) break;
    if (deleted.contains(entry.key)) continue;
    await delete(entry);
    deleted.add(entry.key);
  }
}

final class _Session {
  final DateTime startedAt;
  final List<File> files = [];
  int bytes = 0;

  _Session(this.startedAt);
}
