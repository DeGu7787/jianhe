import 'dart:typed_data';

import 'package:jianhe_core/jianhe_core.dart';
import 'package:sqlite3/sqlite3.dart';

import 'sqlite_item_repository.dart';
import 'sqlite_sync_journal.dart';

class SqliteSkillPackageRepository implements SkillPackageRepository {
  SqliteSkillPackageRepository(this._database);

  final Database _database;
  Future<void> Function(Future<void> Function() action)? _transactionRunner;
  SqliteSyncJournal? _journal;

  /// Installed by [JianheStorageDatabase] so replaceSkill joins the
  /// serialized write-transaction queue instead of guessing from the
  /// autocommit flag, which is false both inside a transaction and while
  /// another queued transaction is suspended mid-await.
  void attachTransactionRunner(
    Future<void> Function(Future<void> Function() action) runner,
  ) {
    _transactionRunner = runner;
  }

  /// Installed by [JianheStorageDatabase] so package writes append sync
  /// journal rows inside their transaction.
  void attachJournal(SqliteSyncJournal journal) {
    _journal = journal;
  }

  @override
  Future<void> deleteForSkill(String skillId) async {
    _database.execute('DELETE FROM skill_packages WHERE skill_id = ?;', [
      skillId,
    ]);
    if (_database.updatedRows > 0) {
      _journal?.record(
        SyncEntityType.skillPackage,
        skillId,
        SyncChangeOp.delete,
      );
    }
  }

  @override
  Future<String?> findSkillIdByPackageHash(String packageHash) async {
    final rows = _database.select(
      'SELECT skill_id FROM skill_packages WHERE package_hash = ? LIMIT 1;',
      [packageHash],
    );
    return rows.isEmpty ? null : rows.first['skill_id'] as String;
  }

  @override
  Future<SkillPackage?> getBySkillId(String skillId) async {
    final packageRows = _database.select(
      'SELECT * FROM skill_packages WHERE skill_id = ? LIMIT 1;',
      [skillId],
    );
    if (packageRows.isEmpty) return null;
    final row = packageRows.first;
    final fileRows = _database.select(
      '''
      SELECT relative_path, media_type, content_hash, content
      FROM skill_files
      WHERE skill_id = ?
      ORDER BY relative_path COLLATE NOCASE ASC;
      ''',
      [skillId],
    );
    return SkillPackage(
      skillId: skillId,
      entrypoint: row['entrypoint'] as String,
      sourceFormat: SkillSourceFormat.fromStorage(
        row['source_format'] as String,
      ),
      importedAt: DateTime.parse(row['imported_at'] as String).toUtc(),
      files: fileRows
          // 入口内容存放在 items 表，历史上误写入的入口重名行直接跳过，
          // 避免单个坏行让备份/导出全盘失败（建库迁移会清理这类行）。
          .where(
            (row) => (row['relative_path'] as String).toLowerCase() !=
                SkillPackage.defaultEntrypoint.toLowerCase(),
          )
          .map(
            (file) => SkillFile.trusted(
              relativePath: file['relative_path'] as String,
              mediaType: file['media_type'] as String?,
              contentHash: file['content_hash'] as String,
              // sqlite3 hands out a fresh buffer per row; no copy needed.
              content: file['content'] as Uint8List,
            ),
          )
          .toList(growable: false),
    );
  }

  @override
  Future<List<SkillFileMetadata>> listFiles(String skillId) async {
    final rows = _database.select(
      '''
      SELECT relative_path, media_type, byte_length, content_hash
      FROM skill_files
      WHERE skill_id = ?
      ORDER BY relative_path COLLATE NOCASE ASC;
      ''',
      [skillId],
    );
    return rows
        .map(
          (row) => SkillFileMetadata(
            relativePath: row['relative_path'] as String,
            mediaType: row['media_type'] as String?,
            byteLength: row['byte_length'] as int,
            contentHash: row['content_hash'] as String,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<SkillFile?> readFile(String skillId, String relativePath) async {
    final normalizedPath = SkillPackage.normalizeRelativePath(relativePath);
    final rows = _database.select(
      '''
      SELECT relative_path, media_type, content_hash, content
      FROM skill_files
      WHERE skill_id = ? AND relative_path = ?
      LIMIT 1;
      ''',
      [skillId, normalizedPath],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return SkillFile.trusted(
      relativePath: row['relative_path'] as String,
      mediaType: row['media_type'] as String?,
      contentHash: row['content_hash'] as String,
      content: row['content'] as Uint8List,
    );
  }

  @override
  Future<List<SkillPackage>> listAll() async {
    final ids = _database.select(
      'SELECT skill_id FROM skill_packages ORDER BY skill_id ASC;',
    );
    final packages = <SkillPackage>[];
    for (final row in ids) {
      final package = await getBySkillId(row['skill_id'] as String);
      if (package != null) packages.add(package);
    }
    return List<SkillPackage>.unmodifiable(packages);
  }

  @override
  Future<void> replaceSkill(JianheItem skill, SkillPackage? package) {
    final runner = _transactionRunner;
    if (runner == null) return _replaceSkillUnqueued(skill, package);
    return runner(() => _replaceSkillUnqueued(skill, package));
  }

  Future<void> _replaceSkillUnqueued(
    JianheItem skill,
    SkillPackage? package,
  ) async {
    if (skill.type != ItemType.skill) {
      throw ArgumentError.value(
        skill.type,
        'skill',
        'A Skill package can only belong to a Skill item.',
      );
    }
    if (package != null && package.skillId != skill.id) {
      throw ArgumentError.value(
        package.skillId,
        'package',
        'The package Skill id does not match the item id.',
      );
    }

    final priorPackageRows = _database.select(
      'SELECT package_hash FROM skill_packages WHERE skill_id = ?;',
      [skill.id],
    );
    final previousPackageHash = priorPackageRows.isEmpty
        ? null
        : priorPackageRows.first['package_hash'] as String?;

    final itemRepository = SqliteItemRepository(_database);
    final journal = _journal;
    if (journal != null) {
      itemRepository.attachJournal(journal);
    }
    await itemRepository.save(skill);
    _database.execute('DELETE FROM skill_packages WHERE skill_id = ?;', [
      skill.id,
    ]);
    final hadPackage = _database.updatedRows > 0;
    if (package != null) {
      final packageHash = package.packageHash(skill.content);
      _database.execute(
        '''
        INSERT INTO skill_packages (
          skill_id, entrypoint, source_format, imported_at, package_hash
        ) VALUES (?, ?, ?, ?, ?);
        ''',
        [
          skill.id,
          package.entrypoint,
          package.sourceFormat.storageValue,
          package.importedAt.toUtc().toIso8601String(),
          packageHash,
        ],
      );
      for (final file in package.files) {
        _database.execute(
          '''
          INSERT INTO skill_files (
            skill_id, relative_path, media_type, byte_length,
            content_hash, content
          ) VALUES (?, ?, ?, ?, ?, ?);
          ''',
          [
            skill.id,
            file.relativePath,
            file.mediaType,
            file.byteLength,
            file.contentHash,
            file.content,
          ],
        );
      }
      if (previousPackageHash != packageHash) {
        _journal?.record(
          SyncEntityType.skillPackage,
          skill.id,
          SyncChangeOp.put,
        );
      }
    } else if (hadPackage) {
      _journal?.record(
        SyncEntityType.skillPackage,
        skill.id,
        SyncChangeOp.delete,
      );
    }
  }
}

