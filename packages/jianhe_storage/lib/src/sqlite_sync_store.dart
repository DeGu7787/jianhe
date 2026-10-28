import 'dart:typed_data';

import 'package:jianhe_core/jianhe_core.dart';
import 'package:sqlite3/sqlite3.dart';

/// One row of `pending_changes`: a local change waiting to be pushed.
class PendingChangeRow {
  const PendingChangeRow({
    required this.seq,
    required this.entityType,
    required this.entityId,
    required this.op,
    required this.changedAt,
  });

  final int seq;
  final SyncEntityType entityType;
  final String entityId;
  final SyncChangeOp op;
  final DateTime changedAt;
}

/// Category row as needed to build a sync envelope (protocol §3.2:
/// `item_categories` has no updated_at column; the change's timestamp
/// travels with the change record instead).
class CategorySyncSnapshot {
  const CategorySyncSnapshot({
    required this.name,
    required this.sortOrder,
    required this.createdAt,
  });

  final String name;
  final int sortOrder;
  final String createdAt;
}

/// Read side and state helpers for the incremental sync engine. Writes go
/// through the repositories (which journal); this store only reads pending
/// rows, reads entity snapshots for push building, maintains `sync_state`,
/// and deletes acknowledged pending rows.
class SqliteSyncStore {
  SqliteSyncStore(this._database);

  final Database _database;

  int pendingCount() {
    final rows = _database
        .select('SELECT COUNT(*) AS c FROM pending_changes;')
    ;
    return rows.first['c'] as int;
  }

  /// Oldest pending rows first. [afterSeq] skips rows up to and including
  /// that seq, so a push run can page past rows it cannot deliver yet
  /// (for example ones waiting for cloud space) instead of stopping there.
  List<PendingChangeRow> readPendingChanges({int limit = 100, int afterSeq = 0}) {
    final rows = _database.select(
      '''
      SELECT seq, entity_type, entity_id, op, changed_at
      FROM pending_changes
      WHERE seq > ?
      ORDER BY seq ASC
      LIMIT ?;
      ''',
      [afterSeq, limit],
    );
    return rows
        .map(
          (row) => PendingChangeRow(
            seq: row['seq'] as int,
            entityType: SyncEntityType.parse(row['entity_type'] as String),
            entityId: row['entity_id'] as String,
            op: SyncChangeOp.parse(row['op'] as String),
            changedAt: DateTime.parse(row['changed_at'] as String),
          ),
        )
        .toList(growable: false);
  }

  /// `changed_at` of the newest unpushed journal row for one entity, or null
  /// when the entity has no pending local change. Ids are local row ids
  /// (category names for category entities).
  DateTime? latestPendingChangedAt(SyncEntityType entityType, String entityId) {
    final rows = _database.select(
      '''
      SELECT changed_at FROM pending_changes
      WHERE entity_type = ? AND entity_id = ?
      ORDER BY seq DESC
      LIMIT 1;
      ''',
      [entityType.storageValue, entityId],
    );
    return rows.isEmpty
        ? null
        : DateTime.parse(rows.first['changed_at'] as String);
  }

  String? readItemUpdatedAt(String id) {
    final rows = _database.select(
      'SELECT updated_at FROM items WHERE id = ? LIMIT 1;',
      [id],
    );
    return rows.isEmpty ? null : rows.first['updated_at'] as String;
  }

  /// All surviving entity identities for the full-resync re-push (protocol
  /// §6.6): item ids, category (type, name) keys and skill package ids.
  List<String> readAllItemIds() {
    final rows = _database.select('SELECT id FROM items ORDER BY id ASC;');
    return [for (final row in rows) row['id'] as String];
  }

  List<(ItemType, String)> readAllCategoryKeys() {
    final rows = _database.select(
      'SELECT type, name FROM item_categories ORDER BY type ASC, name ASC;',
    );
    return [
      for (final row in rows)
        (ItemType.parse(row['type'] as String), row['name'] as String),
    ];
  }

  List<String> readAllSkillIds() {
    final rows = _database.select(
      'SELECT skill_id FROM skill_packages ORDER BY skill_id ASC;',
    );
    return [for (final row in rows) row['skill_id'] as String];
  }

  /// Highest pending seq at the moment the full-resync re-push starts; the
  /// pending cleanup afterwards must not touch rows journaled later.
  int maxPendingSeq() {
    final rows = _database.select(
      'SELECT COALESCE(MAX(seq), 0) AS m FROM pending_changes;',
    );
    return rows.first['m'] as int;
  }

  /// Clears the pending rows that the re-pushed winning state has covered.
  /// [upToSeq] keeps edits journaled while the recovery was in flight, and
  /// entities whose re-push failed (shelved or unacknowledged) keep their
  /// rows for the normal push path.
  void deletePendingChangesForEntities(
    List<({SyncEntityType entityType, String entityId})> entries, {
    required int upToSeq,
  }) {
    for (final entry in entries) {
      _database.execute(
        '''
        DELETE FROM pending_changes
        WHERE entity_type = ? AND entity_id = ? AND seq <= ?;
        ''',
        [entry.entityType.storageValue, entry.entityId, upToSeq],
      );
    }
  }

  /// Full item snapshot for push envelope building. Synchronous on purpose:
  /// the engine reads pending rows and their snapshots without ever
  /// suspending in between, so a concurrent write cannot interleave and the
  /// pushed state always matches the acknowledged rows.
  JianheItem? readItem(String id) {
    final rows = _database.select('SELECT * FROM items WHERE id = ? LIMIT 1;', [
      id,
    ]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    final lastUsedAt = row['last_used_at'] as String?;
    return JianheItem(
      id: row['id'] as String,
      type: ItemType.parse(row['type'] as String),
      title: row['title'] as String,
      content: row['content'] as String,
      isFavorite: (row['is_favorite'] as int) == 1,
      rating: row['rating'] as int,
      category: row['category'] as String,
      sortOrder: row['sort_order'] as int,
      useCount: row['use_count'] as int,
      lastUsedAt: lastUsedAt == null ? null : DateTime.parse(lastUsedAt),
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
      contentHash: row['content_hash'] as String,
    );
  }

  /// Package snapshot with file contents for blob building. Same
  /// synchronous-read rationale as [readItem].
  SkillPackage? readSkillPackage(String skillId) {
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

  /// The row's current item type, or null when the item does not exist.
  ItemType? readItemType(String id) {
    final rows = _database.select(
      'SELECT type FROM items WHERE id = ? LIMIT 1;',
      [id],
    );
    return rows.isEmpty ? null : ItemType.parse(rows.first['type'] as String);
  }

  bool itemExists(String id) {
    return _database
        .select('SELECT 1 FROM items WHERE id = ? LIMIT 1;', [id])
        .isNotEmpty;
  }

  bool categoryExists(ItemType type, String name) {
    return _database
        .select(
          'SELECT 1 FROM item_categories WHERE type = ? AND name = ? LIMIT 1;',
          [type.name, name],
        )
        .isNotEmpty;
  }

  CategorySyncSnapshot? readCategory(ItemType type, String name) {
    final rows = _database.select(
      '''
      SELECT name, sort_order, created_at
      FROM item_categories
      WHERE type = ? AND name = ?
      LIMIT 1;
      ''',
      [type.name, name],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return CategorySyncSnapshot(
      name: row['name'] as String,
      sortOrder: row['sort_order'] as int,
      createdAt: row['created_at'] as String,
    );
  }

  bool skillPackageExists(String skillId) {
    return _database
        .select(
          'SELECT 1 FROM skill_packages WHERE skill_id = ? LIMIT 1;',
          [skillId],
        )
        .isNotEmpty;
  }

  String? readPackageHash(String skillId) {
    final rows = _database.select(
      'SELECT package_hash FROM skill_packages WHERE skill_id = ? LIMIT 1;',
      [skillId],
    );
    return rows.isEmpty ? null : rows.first['package_hash'] as String;
  }

  /// Removes a coalesced entity's pending rows up to and including the
  /// seq that was pushed. Rows newer than [upToSeq] (edits made while the
  /// push was in flight) survive for the next round.
  void deletePendingChanges(
    SyncEntityType entityType,
    String entityId, {
    required int upToSeq,
  }) {
    _database.execute(
      '''
      DELETE FROM pending_changes
      WHERE entity_type = ? AND entity_id = ? AND seq <= ?;
      ''',
      [entityType.storageValue, entityId, upToSeq],
    );
  }

  String? readState(String key) {
    final rows = _database.select(
      'SELECT value FROM sync_state WHERE key = ? LIMIT 1;',
      [key],
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void writeState(String key, String value) {
    _database.execute(
      '''
      INSERT INTO sync_state (key, value) VALUES (?, ?)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value;
      ''',
      [key, value],
    );
  }

  void deleteState(String key) {
    _database.execute('DELETE FROM sync_state WHERE key = ?;', [key]);
  }

  /// Raw remote-item upsert for the pull apply path. Runs inside the
  /// engine's `recordChanges: false` transaction: no journal row, and the
  /// device-local use statistics survive the overwrite. Envelopes exclude
  /// `content_hash`, so it is recomputed from the content (same rule as
  /// [JianheItem.fromJson]).
  void upsertRemoteItem(JianheItem item) {
    final priorRows = _database.select(
      'SELECT use_count, last_used_at FROM items WHERE id = ? LIMIT 1;',
      [item.id],
    );
    final useCount = priorRows.isEmpty
        ? 0
        : priorRows.first['use_count'] as int;
    final lastUsedAt = priorRows.isEmpty
        ? null
        : priorRows.first['last_used_at'] as String?;
    _database.execute(
      '''
      INSERT INTO items (
        id, type, title, content, is_favorite, rating, category,
        sort_order, use_count, last_used_at, created_at, updated_at,
        content_hash
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        type = excluded.type,
        title = excluded.title,
        content = excluded.content,
        is_favorite = excluded.is_favorite,
        rating = excluded.rating,
        category = excluded.category,
        sort_order = excluded.sort_order,
        updated_at = excluded.updated_at,
        content_hash = excluded.content_hash;
      ''',
      [
        item.id,
        item.type.name,
        item.title,
        item.content,
        item.isFavorite ? 1 : 0,
        item.rating,
        item.category,
        item.sortOrder,
        useCount,
        lastUsedAt,
        item.createdAt.toUtc().toIso8601String(),
        item.updatedAt.toUtc().toIso8601String(),
        JianheItem.calculateContentHash(item.content),
      ],
    );
  }

  void deleteRemoteItem(String id) {
    _database.execute('DELETE FROM items WHERE id = ?;', [id]);
  }

  /// Remote category puts apply unconditionally: the server only ships its
  /// LWW winner, and categories carry no local updated_at to compare.
  void upsertRemoteCategory(
    ItemType type,
    String name, {
    required int sortOrder,
    required String createdAt,
  }) {
    _database.execute(
      '''
      INSERT INTO item_categories (type, name, sort_order, created_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(type, name) DO UPDATE SET
        sort_order = excluded.sort_order,
        created_at = excluded.created_at;
      ''',
      [type.name, name, sortOrder, createdAt],
    );
  }

  /// Mirrors the local deleteCategory semantics minus the journal and the
  /// updated_at bump: the origin device re-pushes affected items as their
  /// own records, and those records must still look newer than the
  /// untouched local rows.
  void deleteRemoteCategory(ItemType type, String name) {
    _database.execute(
      "UPDATE items SET category = '' WHERE type = ? AND category = ?;",
      [type.name, name],
    );
    _database.execute(
      'DELETE FROM item_categories WHERE type = ? AND name = ?;',
      [type.name, name],
    );
  }

  /// Whole-package replace on the pull path: the package_hash differs from
  /// the local one, so rebuild skill_packages + skill_files without
  /// touching the items row (the item entity arrives as its own record).
  void replaceRemotePackage({
    required String skillId,
    required String entrypoint,
    required SkillSourceFormat sourceFormat,
    required DateTime importedAt,
    required String packageHash,
    required List<SkillFile> files,
  }) {
    _database.execute(
      'DELETE FROM skill_packages WHERE skill_id = ?;',
      [skillId],
    );
    _database.execute(
      '''
      INSERT INTO skill_packages (
        skill_id, entrypoint, source_format, imported_at, package_hash
      ) VALUES (?, ?, ?, ?, ?);
      ''',
      [
        skillId,
        entrypoint,
        sourceFormat.storageValue,
        importedAt.toUtc().toIso8601String(),
        packageHash,
      ],
    );
    for (final file in files) {
      _database.execute(
        '''
        INSERT INTO skill_files (
          skill_id, relative_path, media_type, byte_length,
          content_hash, content
        ) VALUES (?, ?, ?, ?, ?, ?);
        ''',
        [
          skillId,
          file.relativePath,
          file.mediaType,
          file.byteLength,
          file.contentHash,
          file.content,
        ],
      );
    }
  }

  void deleteRemotePackage(String skillId) {
    _database.execute('DELETE FROM skill_packages WHERE skill_id = ?;', [
      skillId,
    ]);
  }
}
