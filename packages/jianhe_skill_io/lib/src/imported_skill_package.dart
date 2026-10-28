import 'package:jianhe_core/jianhe_core.dart';

/// Pure data half of the skill import result, free of dart:io so web builds
/// can reference the type while the file/dialog IO stays desktop-only.
class ImportedSkillPackage {
  const ImportedSkillPackage({
    required this.title,
    required this.entrypointContent,
    required this.sourceFormat,
    required this.files,
  });

  final String title;
  final String entrypointContent;
  final SkillSourceFormat sourceFormat;
  final List<SkillFile> files;

  SkillPackage toPackage(String skillId, {DateTime? now}) {
    return SkillPackage(
      skillId: skillId,
      sourceFormat: sourceFormat,
      importedAt: (now ?? DateTime.now()).toUtc(),
      files: files,
    );
  }
}
