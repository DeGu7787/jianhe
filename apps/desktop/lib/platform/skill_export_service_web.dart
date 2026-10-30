import 'package:jianhe_core/jianhe_core.dart';

import '../l10n/app_strings.dart';
import 'skill_export_service.dart';

/// Web builds run as a demo of the desktop UI: there is no local file
/// system to save into, so exports fail with a clear message.
class NativeSkillExportService implements SkillExportService {
  const NativeSkillExportService();

  @override
  Future<String?> exportZip({
    required JianheItem skill,
    required SkillPackage? package,
  }) async {
    throw SkillExportException(AppStrings.current.skillExportUnsupported);
  }
}
