/// File-based session log storage. Kept out of the main entrypoint
/// because it depends on `dart:io` and would break web builds.
library;

export 'src/file_storage/file_log_storage.dart';
export 'src/file_storage/file_log_storage_options.dart';
export 'src/file_storage/log_record_encoder.dart';
export 'src/file_storage/retention.dart';
export 'src/file_storage/session_file_name.dart';
