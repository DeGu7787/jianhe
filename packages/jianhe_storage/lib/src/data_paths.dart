import 'dart:io';

import 'package:path/path.dart' as p;

class JianheDataPaths {
  const JianheDataPaths._();

  static Directory dataDirectory({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final override = env['JIANHE_DATA_DIR']?.trim();
    if (override != null && override.isNotEmpty) {
      return Directory(p.normalize(p.absolute(override)));
    }

    final appData = env['APPDATA']?.trim();
    if (appData != null && appData.isNotEmpty) {
      return Directory(p.join(appData, 'JianHe'));
    }

    return Directory(p.join(Directory.current.path, '.jianhe-data'));
  }

  static File databaseFile({Map<String, String>? environment}) {
    return File(
      p.join(dataDirectory(environment: environment).path, 'jianhe.db'),
    );
  }
}
