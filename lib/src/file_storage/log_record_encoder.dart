import 'dart:convert';

import '../logger/logger.dart';

const _truncatedMarker = '…[truncated]';
const _maxDataDepth = 32;

/// First line of every chunk: session identity plus app-provided meta.
String encodeSessionHeader({
  required String sessionId,
  required DateTime startedAt,
  required Map<String, Object?> meta,
}) =>
    '${jsonEncode({
          'kind': 'session',
          'schema': 1,
          'sessionId': sessionId,
          'startedAt': startedAt.toUtc().toIso8601String(),
          'meta': _jsonSafe(meta, _maxDataDepth, <Object>{}),
        })}\n';

/// Encodes one [Log] as a JSON line no longer than [maxRecordBytes].
///
/// Oversized records lose fields in order of diagnostic value:
/// stack trace is cut first, then serialized data, then the message.
String encodeLog(Log log, {required int maxRecordBytes}) {
  final stack = log.stackTrace?.toString();
  final data =
      log.hasData ? _jsonSafe(log.data, _maxDataDepth, <Object>{}) : null;

  final line = _tryEncode(log, stack: stack, data: data);
  if (utf8.encode(line).length <= maxRecordBytes) return line;

  // Overweight: rebuild with progressively harsher cuts.
  var candidate = _tryEncode(
    log,
    stack: stack == null ? null : _cutUtf8(stack, 256),
    data: data,
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

  // Shrink the message until the record fits.
  final overhead = utf8.encode(candidate).length -
      utf8.encode(jsonEncode(log.message)).length;
  final budget = maxRecordBytes - overhead - _truncatedMarker.length * 4;
  candidate = _tryEncode(
    log,
    stack: null,
    data: log.hasData ? _truncatedMarker : null,
    message: _cutUtf8(log.message, budget < 0 ? 0 : budget),
    trunc: true,
  );
  if (utf8.encode(candidate).length <= maxRecordBytes) return candidate;

  // Some other field (path, tags, err) is the hog; last resort keeps the
  // record parseable and within the cap.
  return encodeFallbackLog(log, reason: 'record too large');
}

/// Minimal record for logs that failed normal encoding. Keeps identity
/// fields only, so it always fits and always encodes.
String encodeFallbackLog(Log log, {required String reason}) => '${jsonEncode({
          'ts': log.time.toUtc().toIso8601String(),
          'seq': log.sequenceNum,
          'lvl': log.level,
          'lvlName': log.levelName,
          'msg': _cutUtf8('[encode failed: $reason]', 256),
          'trunc': true,
        })}\n';

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
      'trace': [for (final id in log.traceIds) id.toString()],
    if (log.tags.isNotEmpty) 'tags': log.tags.toList(),
    if (data != null && log.hasData) 'data': data,
    if (log.error != null) 'err': _safeToString(log.error),
    if (stack != null) 'stack': stack,
    if (trunc) 'trunc': true,
  };
  return '${jsonEncode(map)}\n';
}

/// Converts an arbitrary value into a tree [jsonEncode] cannot choke on:
/// non-string map keys become strings, cycles and too-deep nesting are
/// cut, and a throwing `toString()` is caught.
Object? _jsonSafe(Object? value, int depth, Set<Object> seen) {
  switch (value) {
    case null || bool() || num() || String():
      return value;
    case Map():
      if (depth <= 0) return '…[too deep]';
      if (!seen.add(value)) return '…[cycle]';
      final result = {
        for (final entry in value.entries)
          _safeToString(entry.key): _jsonSafe(entry.value, depth - 1, seen),
      };
      seen.remove(value);
      return result;
    case Iterable():
      if (depth <= 0) return '…[too deep]';
      if (!seen.add(value)) return '…[cycle]';
      final result = [
        for (final item in value) _jsonSafe(item, depth - 1, seen),
      ];
      seen.remove(value);
      return result;
    default:
      return _safeToString(value);
  }
}

String _safeToString(Object? value) {
  try {
    return value.toString();
  } on Object {
    return '<unprintable ${value.runtimeType}>';
  }
}

/// Cuts [s] to at most [maxBytes] of UTF-8 (plus marker), not splitting
/// code points.
String _cutUtf8(String s, int maxBytes) {
  final bytes = utf8.encode(s);
  if (bytes.length <= maxBytes) return s;

  final cut = utf8.decode(bytes.sublist(0, maxBytes), allowMalformed: true);
  // Malformed tail decodes to U+FFFD; drop it.
  final clean = cut.endsWith('�') ? cut.substring(0, cut.length - 1) : cut;
  return '$clean$_truncatedMarker';
}
