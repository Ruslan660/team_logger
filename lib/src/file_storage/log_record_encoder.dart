import 'dart:convert';

import '../logger/logger.dart';

const _truncatedMarker = '…[truncated]';

/// First line of every chunk: session identity plus app-provided meta.
String encodeSessionHeader({
  required String sessionId,
  required DateTime startedAt,
  required Map<String, Object?> meta,
}) =>
    '${_encode({
      'kind': 'session',
      'schema': 1,
      'sessionId': sessionId,
      'startedAt': startedAt.toUtc().toIso8601String(),
      'meta': meta,
    })}\n';

/// Encodes one [Log] as a JSON line no longer than [maxRecordBytes].
///
/// Oversized records lose fields in order of diagnostic value:
/// stack trace is cut first, then serialized data, then the message.
String encodeLog(Log log, {required int maxRecordBytes}) {
  final stack = log.stackTrace?.toString();
  final line = _tryEncode(log, stack: stack, data: log.data);
  if (utf8.encode(line).length <= maxRecordBytes) return line;

  // Overweight: rebuild with progressively harsher cuts.
  var candidate = _tryEncode(
    log,
    stack: stack == null ? null : _cutUtf8(stack, 256),
    data: log.data,
    trunc: true,
  );
  if (utf8.encode(candidate).length <= maxRecordBytes) return candidate;

  candidate = _tryEncode(
    log,
    stack: stack == null ? null : _cutUtf8(stack, 256),
    data: log.hasData ? _truncatedMarker : null,
    trunc: true,
  );
  if (utf8.encode(candidate).length <= maxRecordBytes) return candidate;

  // Last resort: shrink the message until the record fits.
  final overhead = utf8.encode(candidate).length -
      utf8.encode(jsonEncode(log.message)).length;
  final budget = maxRecordBytes - overhead - _truncatedMarker.length * 4;
  return _tryEncode(
    log,
    stack: null,
    data: log.hasData ? _truncatedMarker : null,
    message: _cutUtf8(log.message, budget < 0 ? 0 : budget),
    trunc: true,
  );
}

String _tryEncode(
  Log log, {
  required String? stack,
  required Object? data,
  String? message,
  bool trunc = false,
}) {
  final map = <String, Object?>{
    'ts': log.time.toUtc().toIso8601String(),
    'seq': log.sequenceNum,
    'lvl': log.level,
    'lvlName': log.levelName,
    'path': log.path,
    'msg': message ?? log.message,
    if (log.traceIds.isNotEmpty)
      'trace': log.traceIds.map((e) => e.toString()).toList(),
    if (log.tags.isNotEmpty) 'tags': log.tags.toList(),
    if (data != null && log.hasData) 'data': data,
    if (log.error != null) 'err': log.error.toString(),
    if (stack != null) 'stack': stack,
    if (trunc) 'trunc': true,
  };
  return '${_encode(map)}\n';
}

String _encode(Object? value) =>
    jsonEncode(value, toEncodable: (o) => o.toString());

/// Cuts [s] to at most [maxBytes] of UTF-8 (plus marker), not splitting
/// code points.
String _cutUtf8(String s, int maxBytes) {
  final bytes = utf8.encode(s);
  if (bytes.length <= maxBytes) return s;

  final cut = utf8.decode(bytes.sublist(0, maxBytes), allowMalformed: true);
  // Malformed tail decodes to U+FFFD; drop it.
  final clean = cut.endsWith('�')
      ? cut.substring(0, cut.length - 1)
      : cut;
  return '$clean$_truncatedMarker';
}
