# File-based session logs

`package:team_logger/team_logger_io.dart` persists logs of every app
session to disk. The files survive crashes and restarts, so when a user
writes to support you can attach what actually happened, including the
previous sessions.

The module lives in a separate entrypoint because it needs `dart:io`.
Importing the main `team_logger.dart` stays safe for web builds.

## Wiring

```dart
import 'package:team_logger/team_logger.dart';
import 'package:team_logger/team_logger_io.dart';

final fileLogStorage = FileLogStorage(
  directory: Directory(appSupportPath), // e.g. from path_provider
  sessionMeta: {'app': 'client', 'version': '1.42.0'},
);

final log = Logger('app')
  ..publisher = MultiPublisher([
    logStorage,      // in-memory, for the log UI
    fileLogStorage,  // on-disk, for support
  ]);
```

One `FileLogStorage` instance is one session. Don't point two instances
at the same directory: each one protects only its own session during
cleanup and would treat the other's files as old garbage.

## What lands on disk

JSON Lines, one record per line, UTC timestamps. The first line of every
file is a session header with `sessionId`, start time and your
`sessionMeta`. A crash can corrupt at most the last line, and readers
are expected to skip an unparseable tail.

A session is split into chunks (4 by default). When a session outgrows
its byte budget, the oldest chunk is deleted, so the tail always
survives: after a crash the last events are the ones you want.

Old sessions are cleaned up on the first write of a new one, in two
passes: sessions older than `maxAge` go first, then the oldest ones
until the directory fits `maxTotalBytes`.

Defaults (all tunable through `FileLogStorageOptions`): 2 MiB per
session in 4 chunks, 7 days, 20 MiB per directory, 32 KiB per record.
Oversized records lose their stack trace first, then data, then the
message gets cut.

## Sending to support

```dart
final zip = await fileLogStorage.exportArchive();
// share_plus, an upload API — the transport is up to the app
```

`exportArchive()` flushes the current session and zips a point-in-time
snapshot of every session file. The archive doesn't change after
creation, so it is safe to upload while logging continues.
`collectFiles()` returns the raw file list instead, but the current
session keeps growing under your feet; prefer the archive for uploads.

## Failure policy

Logging must never crash the app. IO errors skip the record; after 5
consecutive failures the storage disables itself for the rest of the
session and reports once through `onInternalError`. Serialization
problems (cyclic `data`, a throwing `toString()`) don't count as IO
failures: the record is replaced with a short fallback line instead.

`fsync` runs after error-level records, at most once a second, and on
explicit `flush()`. Flush on app pause is one line with the companion
package: `FileLogFlushObserver(fileLogStorage).attach()` from
`flutter_team_logger`.

## What the package does not do

- It doesn't know what is sensitive. Filtering PII and secrets is the
  app's logging policy; `recordFilter` can only drop whole records.
- It doesn't pick a directory. Use an application support path and keep
  it out of cloud backups.
- It doesn't limit the in-memory queue: if the disk is slower than an
  extreme logging flood, memory grows. Real workloads are nowhere near
  this, but the limitation is worth knowing.
