## 0.4.0

- Add file-based session log storage (`package:team_logger/team_logger_io.dart`):
  `FileLogStorage` writes JSON Lines chunks with rotation and startup
  retention, `exportArchive()` produces a zip snapshot for support
  uploads. See `doc/file_storage.md`.

## 0.3.0

- Update README.
- [breaking changes] Rename `activeLoggers` to `activeNamespaces`.
- [breaking changes] Rename `activeLevel` to `activeMinLevel`.
- [breaking changes] Remove `AnsiPair`.
- Add `activeLevels`.
- Fix minor bugs.

## 0.2.0-0.2.2

- Publish.

## 0.1.0-0.1.70

- Initial version.
