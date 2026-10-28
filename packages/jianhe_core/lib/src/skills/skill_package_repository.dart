import '../items/jianhe_item.dart';
import 'skill_package.dart';

abstract interface class SkillPackageRepository {
  Future<SkillPackage?> getBySkillId(String skillId);

  Future<List<SkillFileMetadata>> listFiles(String skillId);

  Future<SkillFile?> readFile(String skillId, String relativePath);

  Future<List<SkillPackage>> listAll();

  Future<String?> findSkillIdByPackageHash(String packageHash);

  /// Replaces a Skill and its package atomically. A null package represents a
  /// legacy single-file Skill and removes any existing auxiliary files.
  Future<void> replaceSkill(JianheItem skill, SkillPackage? package);

  Future<void> deleteForSkill(String skillId);
}
