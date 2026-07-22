/// Naming scheme for session log files:
/// `tlog_<yyyyMMddTHHmmss UTC>-<4 hex>_p<NN>.jsonl`.
///
/// Session age is derived from the file name, not from mtime: mtime does
/// not survive backups and file copies.
library;

final _fileNameRe = RegExp(
  r'^tlog_(\d{8}T\d{6}-[0-9a-f]{4})_p(\d{2})\.jsonl$',
);

/// Parsed identity of one chunk file.
final class SessionFileInfo {
  final String sessionId;
  final DateTime startedAt;
  final int part;

  const SessionFileInfo({
    required this.sessionId,
    required this.startedAt,
    required this.part,
  });
}

/// Builds a session id like `20260722T104501-a3f2`.
String sessionIdFrom(DateTime utcStart, String rand4) {
  final t = utcStart;
  String pad2(int n) => n.toString().padLeft(2, '0');
  final date = '${t.year.toString().padLeft(4, '0')}${pad2(t.month)}'
      '${pad2(t.day)}T${pad2(t.hour)}${pad2(t.minute)}${pad2(t.second)}';
  return '$date-$rand4';
}

/// File name for the [part]-th chunk of a session.
String chunkFileName(String sessionId, int part) =>
    'tlog_${sessionId}_p${part.toString().padLeft(2, '0')}.jsonl';

/// Parses a chunk file name; returns `null` for files we don't own.
SessionFileInfo? parseFileName(String name) {
  final match = _fileNameRe.firstMatch(name);
  if (match == null) return null;

  final sessionId = match.group(1)!;
  final year = int.parse(sessionId.substring(0, 4));
  final month = int.parse(sessionId.substring(4, 6));
  final day = int.parse(sessionId.substring(6, 8));
  final hour = int.parse(sessionId.substring(9, 11));
  final minute = int.parse(sessionId.substring(11, 13));
  final second = int.parse(sessionId.substring(13, 15));

  final startedAt = DateTime.utc(year, month, day, hour, minute, second);
  // DateTime.utc normalizes overflow (month 17 -> next year), so a
  // round-trip check catches out-of-range fields the regexp lets through.
  if (sessionIdFrom(startedAt, '').length - 1 != 15 ||
      !sessionId.startsWith(_dateOf(startedAt))) {
    return null;
  }

  return SessionFileInfo(
    sessionId: sessionId,
    startedAt: startedAt,
    part: int.parse(match.group(2)!),
  );
}

String _dateOf(DateTime t) {
  final id = sessionIdFrom(t, '');
  return id.substring(0, id.length - 1);
}
