import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:logger_builder/logger_builder.dart';

import '../logger/log_levels.dart';
import '../logger/logger.dart';

import 'file_log_storage_options.dart';
import 'log_record_encoder.dart';
import 'retention.dart';
import 'session_file_name.dart';

/// Publisher that persists session logs to files for crash diagnostics
/// and support requests.
///
/// One instance = one session. Records are appended as JSON lines to
/// rotating chunk files (see [FileLogStorageOptions]); past sessions are
/// cleaned up on first write. All IO runs on the [AsyncPublisherBase]
/// queue, so logging calls never block on disk. IO failures are silent:
/// after 5 consecutive errors the storage disables itself and reports
/// once through [FileLogStorageOptions.onInternalError].
///
/// Single-isolate only: two isolates writing to one directory get
/// separate sessions, but must not share one [FileLogStorage].
final class FileLogStorage extends AsyncPublisherBase<Log> {
  static const _maxConsecutiveFailures = 5;

  final Directory directory;
  final FileLogStorageOptions options;
  final Map<String, Object?> sessionMeta;

  /// Identity of this session, also the file name prefix.
  final String sessionId;
  final DateTime _startedAt;

  RandomAccessFile? _raf;
  int _chunkIndex = 0;
  int _chunkBytes = 0;
  int _recordsInChunk = 0;
  final List<int> _liveChunks = [];

  bool _initialized = false;
  bool _disabled = false;
  int _failures = 0;

  FileLogStorage({
    required this.directory,
    this.options = const FileLogStorageOptions(),
    this.sessionMeta = const {},
  })  : _startedAt = clock.now().toUtc(),
        sessionId = sessionIdFrom(
          clock.now().toUtc(),
          Random().nextInt(0x10000).toRadixString(16).padLeft(4, '0'),
        );

  @override
  Future<void> handle(Log log) async {
    if (_disabled) return;
    if (log.level < options.minLevel) return;
    if (options.recordFilter?.call(log) == false) return;

    try {
      if (!_initialized) await _init();

      final line = encodeLog(log, maxRecordBytes: options.maxRecordBytes);
      final bytes = utf8.encode(line);

      if (_recordsInChunk > 0 &&
          _chunkBytes + bytes.length > options.chunkBytes) {
        await _rotate();
      }

      await _raf!.writeFrom(bytes);
      _chunkBytes += bytes.length;
      _recordsInChunk++;
      if (log.level >= LogLevels.error) await _raf!.flush();

      _failures = 0;
    } on Object catch (error, stackTrace) {
      _failures++;
      if (_failures >= _maxConsecutiveFailures) {
        _disabled = true;
        options.onInternalError?.call(error, stackTrace);
      }
    }
  }

  /// Drains the queue and syncs the current chunk to disk.
  @override
  Future<void> flush() async {
    await super.flush();
    try {
      await _raf?.flush();
    } on IOException {
      // Same policy as writes: never throw.
    }
  }

  /// Files of all sessions in this directory, newest session first,
  /// chunks in write order. Flushes the current session before listing,
  /// so the caller gets records made just before the export.
  Future<List<File>> collectFiles() async {
    await flush();

    final infos = <(SessionFileInfo, File)>[];
    try {
      await for (final entry in directory.list()) {
        if (entry is! File) continue;
        final info = parseFileName(entry.uri.pathSegments.last);
        if (info != null) infos.add((info, entry));
      }
    } on IOException {
      return const [];
    }

    infos.sort((a, b) {
      final bySession = b.$1.startedAt.compareTo(a.$1.startedAt);
      if (bySession != 0) return bySession;
      final sameSession = a.$1.sessionId.compareTo(b.$1.sessionId);
      if (sameSession != 0) return sameSession;
      return a.$1.part.compareTo(b.$1.part);
    });

    return [for (final (_, file) in infos) file];
  }

  @override
  Future<void> close() async {
    await super.close();
    try {
      await _raf?.flush();
      await _raf?.close();
    } on IOException {
      // Closing must not throw either.
    }
    _raf = null;
  }

  Future<void> _init() async {
    await directory.create(recursive: true);
    await applyRetention(
      directory,
      options,
      currentSessionId: sessionId,
      now: clock.now().toUtc(),
    );
    await _openChunk(0);
    _initialized = true;
  }

  Future<void> _openChunk(int part) async {
    final file = File('${directory.path}/${chunkFileName(sessionId, part)}');
    _raf = await file.open(mode: FileMode.writeOnlyAppend);
    _chunkIndex = part;
    _recordsInChunk = 0;
    _liveChunks.add(part);

    final header = encodeSessionHeader(
      sessionId: sessionId,
      startedAt: _startedAt,
      meta: sessionMeta,
    );
    final headerBytes = utf8.encode(header);
    await _raf!.writeFrom(headerBytes);
    _chunkBytes = headerBytes.length;
  }

  Future<void> _rotate() async {
    await _raf!.close();
    _raf = null;
    await _openChunk(_chunkIndex + 1);

    while (_liveChunks.length > options.chunksPerSession) {
      final oldest = _liveChunks.removeAt(0);
      try {
        await File('${directory.path}/${chunkFileName(sessionId, oldest)}')
            .delete();
      } on IOException {
        // A stuck chunk costs disk space, not correctness.
      }
    }
  }
}
