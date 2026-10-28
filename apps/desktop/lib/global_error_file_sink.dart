import 'dart:io';

import 'global_error_handlers.dart';

/// Appends entries to error.log inside [directoryPath], recreating the file
/// once it passes 512 KB so a repetitive failure cannot grow it unbounded.
/// Never throws: the sink runs inside error paths that must not fail.
GlobalErrorSink fileErrorSink(String directoryPath) {
  return (String message) {
    try {
      final directory = Directory(directoryPath);
      if (!directory.existsSync()) directory.createSync(recursive: true);
      final file = File('${directory.path}${Platform.pathSeparator}error.log');
      final mode = file.existsSync() && file.lengthSync() < 512 * 1024
          ? FileMode.append
          : FileMode.write;
      file.writeAsStringSync(message, mode: mode);
    } on Object {
      // Dropping the log entry is better than failing inside an error path.
    }
  };
}
