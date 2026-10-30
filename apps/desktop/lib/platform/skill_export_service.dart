import 'package:jianhe_core/jianhe_core.dart';

export 'skill_export_service_io.dart'
    if (dart.library.html) 'skill_export_service_web.dart';

/// Saves one local Skill (SKILL.md plus its supporting files) as a ZIP on
/// this computer, after asking the user where to put it. Implementations are
/// platform-conditional; web builds get an inert stub.
abstract interface class SkillExportService {
  /// Returns the path written, or null when the user cancelled the dialog.
  Future<String?> exportZip({
    required JianheItem skill,
    required SkillPackage? package,
  });
}

/// Platform-neutral export failure (dialog subprocess errors, unwritable
/// paths) — dart:io exception types must not leak past this seam.
class SkillExportException implements Exception {
  const SkillExportException(this.message);

  final String message;

  @override
  String toString() => message;
}
