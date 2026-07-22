import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
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
/// queue plus an internal lock, so logging calls never block on disk and
/// file operations never overlap. IO failures are silent: after 5
/// consecutive errors the storage disables itself and reports once
/// through [FileLogStorageOptions.onInternalError].
///
/// Single-isolate, single-instance per directory: two instances writing
/// to one directory would treat each other's session as past and could
/// delete it during retention.
final class FileLogStorage extends AsyncPublisherBase<Log> {
  static const _maxConsecutiveFailures = 5;
  static const _fsyncMinInterval = Duration(seconds: 1);

  final Directory directory;
  final FileLogStorageOptions options;
  final Map<String, Object?> sessionMeta;

  /// Identity of this session, also the file name prefix.
  final String sessionId;
  final DateTime _startedAt;

  RandomAccessFile? _raf;
  int _chunkIndex = -1;
  int _chunkBytes = 0;
  int _recordsInChunk = 0;
  final List<int> _liveChunks = [];

  /// Serializes raw file operations: `flush()`/`close()` run outside the
  /// publisher queue, and [RandomAccessFile] forbids overlapping calls.
  Future<void> _ioLock = Future.value();

  /// Serializes whole flush()/close() calls. Two overlapping
  /// `AsyncPublisherBase.flush()` calls can strand a queue controller
  /// without a listener (vendor race), so they must never interleave.
  Future<void> _flushLock = Future.value();

  bool _initialized = false;
  bool _closed = false;
  bool _disabled = false;
  int _failures = 0;
  DateTime? _lastFsync;

  FileLogStorage({
    required Directory directory,
    FileLogStorageOptions options = const FileLogStorageOptions(),
    Map<String, Object?> sessionMeta = const {},
  }) : this._at(
          clock.now().toUtc(),
          directory: directory,
          options: options,
          sessionMeta: sessionMeta,
        );

  FileLogStorage._at(
    DateTime startedAt, {
    required this.directory,
    required this.options,
    required this.sessionMeta,
  })  : _startedAt = startedAt,
        sessionId = sessionIdFrom(
          startedAt,
          Random().nextInt(0xffffffff).toRadixString(16).padLeft(8, '0'),
        );

  @override
  Future<void> handle(Log log) => _locked(() => _handle(log));

  Future<T> _locked<T>(Future<T> Function() action) {
    final result = _ioLock.then((_) => action());
    _ioLock = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _handle(Log log) async {
    if (_disabled || _closed) return;
    if (log.level < options.minLevel) return;

    // A throwing filter must not kill the stream listener; treat it as
    // "keep the record".
    try {
      if (options.recordFilter?.call(log) == false) return;
    } on Object {
      // Ignore.
    }

    // Encoding failures are deterministic, not IO: report the record
    // itself instead of burning the failure counter.
    String line;
    try {
      line = encodeLog(log, maxRecordBytes: options.maxRecordBytes);
    } on Object catch (error) {
      String reason;
      try {
        reason = error.toString();
      } on Object {
        reason = error.runtimeType.toString();
      }
      line = encodeFallbackLog(log, reason: reason);
    }

    try {
      if (!_initialized) await _init();

      final bytes = utf8.encode(line);
      if (_recordsInChunk > 0 &&
          _chunkBytes + bytes.length > options.chunkBytes) {
        await _rotate();
      }
      if (_raf == null) {
        // A previous rotation failed mid-way; try a fresh chunk.
        await _openChunk(_chunkIndex + 1);
      }

      await _raf!.writeFrom(bytes);
      _chunkBytes += bytes.length;
      _recordsInChunk++;

      if (log.level >= LogLevels.error) await _fsyncThrottled();

      _failures = 0;
    } on Object catch (error, stackTrace) {
      _failures++;
      if (_failures >= _maxConsecutiveFailures && !_disabled) {
        _disabled = true;
        try {
          options.onInternalError?.call(error, stackTrace);
        } on Object {
          // A throwing callback must not escape into the stream.
        }
      }
    }
  }

  Future<T> _flushSerial<T>(Future<T> Function() action) {
    final result = _flushLock.then((_) => action());
    _flushLock = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Drains the queue and syncs the current chunk to disk. Calls are
  /// serialized: concurrent flushes run one after another.
  @override
  Future<void> flush() => _flushSerial(() async {
        if (_closed) return;
        await super.flush();
        await _locked(() async {
          try {
            await _raf?.flush();
          } on IOException {
            // Same policy as writes: never throw.
          }
        });
      });

  /// Files of all sessions in this directory, newest session first,
  /// chunks in write order. Flushes the current session before listing.
  ///
  /// The current session's files keep growing after this call; for a
  /// stable artifact use [exportArchive].
  Future<List<File>> collectFiles() async {
    await flush();
    return _listSessionFiles();
  }

  Future<List<File>> _listSessionFiles() async {
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

  /// Zips a point-in-time snapshot of all session files into [target]
  /// (default: `<directory>/export/tlogs_<sessionId>.zip`) and returns it.
  ///
  /// The snapshot is taken under the write lock, so no record lands and
  /// no rotation happens between reading the first and the last file.
  /// The archive is immutable — safe to upload while logging continues.
  /// Returns `null` when there is nothing to export or the export failed.
  ///
  /// Files are buffered in memory while zipping; with default limits
  /// that is up to ~20 MiB, size the caps accordingly.
  Future<File?> exportArchive({File? target}) async {
    await flush();

    try {
      // Read all bytes atomically with respect to writes and rotation.
      final entries = await _locked(() async {
        final files = await _listSessionFiles();
        return [
          for (final file in files)
            (file.uri.pathSegments.last, await file.readAsBytes()),
        ];
      });
      if (entries.isEmpty) return null;

      final archive = Archive();
      for (final (name, bytes) in entries) {
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }

      final out =
          target ?? File('${directory.path}/export/tlogs_$sessionId.zip');
      await out.parent.create(recursive: true);
      if (target == null) {
        // Keep at most one default archive around.
        await for (final old in out.parent.list()) {
          if (old is File && old.path != out.path) {
            try {
              await old.delete();
            } on IOException {
              // Best effort.
            }
          }
        }
      }
      await out.writeAsBytes(ZipEncoder().encode(archive));
      return out;
    } on Object catch (error, stackTrace) {
      try {
        options.onInternalError?.call(error, stackTrace);
      } on Object {
        // Ignore.
      }
      return null;
    }
  }

  @override
  Future<void> close() => _flushSerial(() async {
        if (_closed) return;
        _closed = true;
        await super.close();
        await _locked(() async {
          try {
            await _raf?.flush();
            await _raf?.close();
          } on IOException {
            // Closing must not throw either.
          }
          _raf = null;
        });
      });

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

  /// Opens a chunk atomically: state is committed only after the header
  /// hit the file, so a failure leaves no half-open descriptor behind.
  Future<void> _openChunk(int part) async {
    final file = File('${directory.path}/${chunkFileName(sessionId, part)}');
    final raf = await file.open(mode: FileMode.writeOnlyAppend);

    final int headerLength;
    try {
      final header = utf8.encode(
        encodeSessionHeader(
          sessionId: sessionId,
          startedAt: _startedAt,
          meta: sessionMeta,
        ),
      );
      await raf.writeFrom(header);
      headerLength = header.length;
    } on Object {
      try {
        await raf.close();
        await file.delete();
      } on IOException {
        // Ignore.
      }
      rethrow;
    }

    _raf = raf;
    _chunkIndex = part;
    _chunkBytes = headerLength;
    _recordsInChunk = 0;
    _liveChunks.add(part);
  }

  Future<void> _rotate() async {
    final old = _raf;
    _raf = null;
    if (old != null) await old.close();

    await _openChunk(_chunkIndex + 1);

    while (_liveChunks.length > options.chunksPerSession) {
      final oldest = _liveChunks.first;
      try {
        await File('${directory.path}/${chunkFileName(sessionId, oldest)}')
            .delete();
        _liveChunks.removeAt(0);
      } on IOException {
        // Kept in the list, so the next rotation retries the delete.
        break;
      }
    }
  }

  /// Error-level records ask for durability, but an error storm must not
  /// turn into an fsync storm.
  Future<void> _fsyncThrottled() async {
    final now = clock.now();
    final last = _lastFsync;
    if (last != null && now.difference(last) < _fsyncMinInterval) return;
    _lastFsync = now;
    await _raf!.flush();
  }
}
