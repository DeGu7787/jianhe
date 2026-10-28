import 'package:jianhe_skill_io/imported.dart';

import '../l10n/app_strings.dart';
import 'skill_import_service.dart';

/// Web builds run as a demo of the desktop UI: there is no local file
/// system behind the dialogs, so imports fail with a clear message.
class NativeSkillImportService implements SkillImportService {
  const NativeSkillImportService();

  @override
  Future<ImportedSkillPackage?> importFile() async {
    throw SkillImportException(AppStrings.current.skillImportUnsupported);
  }

  @override
  Future<ImportedSkillPackage?> importDirectory() async {
    throw SkillImportException(AppStrings.current.skillImportUnsupported);
  }
}
