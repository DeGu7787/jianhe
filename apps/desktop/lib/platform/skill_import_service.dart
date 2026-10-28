import 'package:jianhe_skill_io/imported.dart';

export 'skill_import_service_io.dart'
    if (dart.library.html) 'skill_import_service_web.dart';

/// Picks and imports a local Skill package (folder / zip / markdown) using
/// native file dialogs. Implementations are platform-conditional; web
/// builds get an inert stub.
abstract interface class SkillImportService {
  Future<ImportedSkillPackage?> importFile();

  Future<ImportedSkillPackage?> importDirectory();
}

/// Platform-neutral import failure (dialog subprocess errors, unreachable
/// paths) — dart:io exception types must not leak past this seam.
class SkillImportException implements Exception {
  const SkillImportException(this.message);

  final String message;

  @override
  String toString() => message;
}
