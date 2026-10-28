import 'package:jianhe_core/jianhe_core.dart';
import 'package:sqlite3/sqlite3.dart';

import 'sqlite_sync_journal.dart';

class SqliteItemRepository implements ItemRepository {
  SqliteItemRepository(this._database);

  final Database _database;
  Future<void> Function(Future<void> Function() action)? _transactionRunner;
  SqliteSyncJournal? _journal;

  /// Installed by [JianheStorageDatabase] so saves join the serialized
  /// write-transaction queue. Standalone instances (e.g. the one
  /// replaceSkill creates) keep writing directly inside the caller's
  /// transaction.
  void attachTransactionRunner(
    Future<void> Function(Future<void> Function() action) runner,
  ) {
    _transactionRunner = runner;
  }

  /// Installed by [JianheStorageDatabase] so writes append sync journal
  /// rows inside their transaction.
  void attachJournal(SqliteSyncJournal journal) {
    _journal = journal;
  }

  @override
  Future<void> delete(String id) {
    final runner = _transactionRunner;
    if (runner == null) return _deleteUnqueued(id);
    return runner(() => _deleteUnqueued(id));
  }

  Future<void> _deleteUnqueued(String id) async {
    final rows = _database.select(
      'SELECT type FROM items WHERE id = ? LIMIT 1;',
      [id],
    );
    if (rows.isEmpty) return;
    final type = ItemType.parse(rows.first['type'] as String);
    _database.execute('DELETE FROM items WHERE id = ?;', [id]);
    _journal?.record(SyncEntityType.forItem(type), id, SyncChangeOp.delete);
    if (type == ItemType.skill) {
      _journal?.record(SyncEntityType.skillPackage, id, SyncChangeOp.delete);
    }
  }

  @override
  Future<void> createCategory(ItemType type, String name) {
    final runner = _transactionRunner;
    if (runner == null) return _createCategoryUnqueued(type, name);
    return runner(() => _createCategoryUnqueued(type, name));
  }

  Future<void> _createCategoryUnqueued(ItemType type, String name) async {
    final normalized = _normalizeCategory(name);
    final row = _database
        .select(
          '''
      SELECT COALESCE(MAX(sort_order), -1) + 1 AS next_order
      FROM item_categories
      WHERE type = ?;
    ''',
          [type.name],
        )
        .first;
    _database.execute(
      '''
      INSERT OR IGNORE INTO item_categories (
        type, name, sort_order, created_at
      ) VALUES (?, ?, ?, ?);
    ''',
      [
        type.name,
        normalized,
        row['next_order'] as int,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
    if (_database.updatedRows > 0) {
      _journal?.record(
        SyncEntityType.forCategory(type),
        normalized,
        SyncChangeOp.put,
      );
    }
  }

  @override
  Future<void> deleteCategory(ItemType type, String name) {
    final runner = _transactionRunner;
    if (runner == null) return _deleteCategoryUnqueued(type, name);
    return runner(() => _deleteCategoryUnqueued(type, name));
  }

  Future<void> _deleteCategoryUnqueued(ItemType type, String name) async {
    final normalized = _normalizeCategory(name);
    final changedAt = DateTime.now().toUtc().toIso8601String();
    final affectedIds = _database
        .select(
          'SELECT id FROM items WHERE type = ? AND category = ?;',
          [type.name, normalized],
        )
        .map((row) => row['id'] as String)
        .toList(growable: false);
    final categoryExists =
        _database
            .select(
              'SELECT 1 FROM item_categories WHERE type = ? AND name = ?;',
              [type.name, normalized],
            )
            .isNotEmpty;
    _database.execute(
      "UPDATE items SET category = '', updated_at = ? "
      'WHERE type = ? AND category = ?;',
      [changedAt, type.name, normalized],
    );
    _database.execute(
      'DELETE FROM item_categories WHERE type = ? AND name = ?;',
      [type.name, normalized],
    );
    // The items themselves changed state, so each one must be re-pushed:
    // journaling only the category tombstone would leave other devices with
    // dangling category references.
    for (final id in affectedIds) {
      _journal?.record(SyncEntityType.forItem(type), id, SyncChangeOp.put);
    }
    if (categoryExists) {
      _journal?.record(
        SyncEntityType.forCategory(type),
        normalized,
        SyncChangeOp.delete,
      );
    }
  }

  @override
  Future<JianheItem?> getById(String id) async {
    final rows = _database.select('SELECT * FROM items WHERE id = ? LIMIT 1;', [
      id,
    ]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  @override
  Future<List<JianheItem>> listAll() async {
    final rows = _database.select('''
      SELECT * FROM items
      ORDER BY ${_orderBy(ItemSortMode.smart)};
    ''');
    return rows.map(_fromRow).toList(growable: false);
  }

  @override
  Future<List<String>> listCategories(ItemType type) async {
    final rows = _database.select(
      '''
      SELECT name
      FROM item_categories
      WHERE type = ?
      ORDER BY sort_order ASC, name COLLATE NOCASE ASC;
    ''',
      [type.name],
    );
    return rows.map((row) => row['name'] as String).toList(growable: false);
  }

  @override
  Future<List<JianheItem>> list({
    ItemType? type,
    bool favoritesOnly = false,
    int? rating,
    String? category,
    ItemSortMode sortMode = ItemSortMode.smart,
    int limit = 100,
  }) async {
    _validateLimit(limit);
    final clauses = <String>[];
    final parameters = <Object?>[];
    if (type != null) {
      clauses.add('type = ?');
      parameters.add(type.name);
    }
    if (rating != null) {
      _validateRating(rating);
      clauses.add('rating = ?');
      parameters.add(rating);
    } else if (favoritesOnly) {
      clauses.add('rating > 0');
    }
    if (category != null) {
      clauses.add('category = ?');
      parameters.add(category.trim());
    }
    parameters.add(limit);

    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    final rows = _database.select('''
      SELECT * FROM items
      $where
      ORDER BY ${_orderBy(sortMode)}
      LIMIT ?;
    ''', parameters);
    return rows.map(_fromRow).toList(growable: false);
  }

  /// Runs [action] in the serialized write-transaction queue when one is
  /// attached (see [attachTransactionRunner]) and returns its result.
  Future<T> _runQueued<T>(Future<T> Function() action) async {
    final runner = _transactionRunner;
    if (runner == null) return action();
    late T result;
    await runner(() async {
      result = await action();
    });
    return result;
  }

  // markUsed, setRating and setSortOrders write only their own columns,
  // inside the write queue. Reading the whole item and saving it back used to queue that
  // save behind an open transaction (a sync pull applying remote changes):
  // it then restored the content and updated_at read before the pull,
  // journaled that stale state, and the server dropped it as older, leaving
  // this device on old content for good.

  @override
  Future<JianheItem?> markUsed(String id, {DateTime? now}) {
    return _runQueued(() async {
      final usedAt = (now ?? DateTime.now()).toUtc().toIso8601String();
      _database.execute(
        'UPDATE items SET use_count = use_count + 1, last_used_at = ? '
        'WHERE id = ?;',
        [usedAt, id],
      );
      if (_database.updatedRows == 0) return null;
      return getById(id);
    });
  }

  @override
  Future<JianheItem?> setRating(
    String id,
    int rating, {
    DateTime? now,
  }) async {
    _validateRating(rating);
    return _runQueued(() async {
      final rows = _database.select(
        'SELECT type, updated_at FROM items WHERE id = ? LIMIT 1;',
        [id],
      );
      if (rows.isEmpty) return null;
      final type = ItemType.parse(rows.first['type'] as String);
      // Strictly after the stored state, even if that came from a device
      // whose clock runs ahead: the rating is an edit of this version and
      // must not lose the sync arbitration against it.
      final floor = DateTime.parse(
        rows.first['updated_at'] as String,
      ).toUtc().add(const Duration(milliseconds: 1));
      var updatedAt = (now ?? DateTime.now()).toUtc();
      if (updatedAt.isBefore(floor)) updatedAt = floor;
      _database.execute(
        'UPDATE items SET rating = ?, is_favorite = ?, updated_at = ? '
        'WHERE id = ?;',
        [rating, rating > 0 ? 1 : 0, updatedAt.toIso8601String(), id],
      );
      // The rating does not enter the Skill package hash, so only the item
      // entity changes.
      _journal?.record(SyncEntityType.forItem(type), id, SyncChangeOp.put);
      return getById(id);
    });
  }

  @override
  Future<List<JianheItem>> setSortOrders(
    ItemType type,
    Map<String, int> sortOrders, {
    DateTime? now,
  }) async {
    for (final order in sortOrders.values) {
      if (order < 0) {
        throw ArgumentError.value(
          order,
          'sortOrders',
          'Sort order cannot be negative.',
        );
      }
    }
    if (sortOrders.isEmpty) return const <JianheItem>[];
    return _runQueued(() async {
      final requested = (now ?? DateTime.now()).toUtc();
      final changed = <JianheItem>[];
      for (final MapEntry(key: id, value: order) in sortOrders.entries) {
        final rows = _database.select(
          'SELECT sort_order, updated_at FROM items '
          'WHERE id = ? AND type = ? LIMIT 1;',
          [id, type.name],
        );
        if (rows.isEmpty || rows.first['sort_order'] == order) continue;
        // Same rule as setRating: strictly after the stored version.
        final floor = DateTime.parse(
          rows.first['updated_at'] as String,
        ).toUtc().add(const Duration(milliseconds: 1));
        final updatedAt = requested.isBefore(floor) ? floor : requested;
        _database.execute(
          'UPDATE items SET sort_order = ?, updated_at = ? WHERE id = ?;',
          [order, updatedAt.toIso8601String(), id],
        );
        _journal?.record(SyncEntityType.forItem(type), id, SyncChangeOp.put);
        final stored = await getById(id);
        if (stored != null) changed.add(stored);
      }
      return changed;
    });
  }

  @override
  Future<void> save(JianheItem item) {
    final runner = _transactionRunner;
    if (runner == null) return _saveUnqueued(item);
    return runner(() => _saveUnqueued(item));
  }

  Future<void> _saveUnqueued(JianheItem item) async {
    if (item.category.isNotEmpty) {
      await createCategory(item.type, item.category);
    }
    final priorRows = _database.select(
      'SELECT updated_at, type FROM items WHERE id = ? LIMIT 1;',
      [item.id],
    );
    final priorExists = priorRows.isNotEmpty;
    final priorUpdatedAt = priorExists
        ? priorRows.first['updated_at'] as String
        : null;
    final priorType = priorExists
        ? ItemType.parse(priorRows.first['type'] as String)
        : null;
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
        use_count = excluded.use_count,
        last_used_at = excluded.last_used_at,
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
        item.useCount,
        item.lastUsedAt?.toIso8601String(),
        item.createdAt.toIso8601String(),
        item.updatedAt.toIso8601String(),
        item.contentHash,
      ],
    );
    // The sync protocol keys items by (type, id): `item:prompt/X` and
    // `item:snippet/X` are distinct server entities. A type change must
    // retire the old-type entity explicitly, otherwise it stays live in the
    // cloud forever and resurrects on any device that later runs a full
    // snapshot recovery (even after the item itself was deleted). Recorded
    // before the new-type put so the tombstone carries the lower seq.
    if (priorType != null && priorType != item.type) {
      _journal?.record(
        SyncEntityType.forItem(priorType),
        item.id,
        SyncChangeOp.delete,
        changedAt: item.updatedAt,
      );
    }
    // Only sync-visible state changes journal: a fresh entity, or an
    // updated_at bump. markUsed keeps updated_at (device-local fields only,
    // protocol §3.1) and therefore never journals.
    if (!priorExists || priorUpdatedAt != item.updatedAt.toIso8601String()) {
      _journal?.record(
        SyncEntityType.forItem(item.type),
        item.id,
        SyncChangeOp.put,
      );
    }
    if (item.type != ItemType.skill) {
      _database.execute('DELETE FROM skill_packages WHERE skill_id = ?;', [
        item.id,
      ]);
      if (_database.updatedRows > 0) {
        _journal?.record(
          SyncEntityType.skillPackage,
          item.id,
          SyncChangeOp.delete,
        );
      }
      return;
    }
    final packageRows = _database.select(
      'SELECT 1 FROM skill_packages WHERE skill_id = ? LIMIT 1;',
      [item.id],
    );
    if (packageRows.isEmpty) return;
    final fileRows = _database.select(
      '''
      SELECT relative_path, content_hash
      FROM skill_files
      WHERE skill_id = ?;
      ''',
      [item.id],
    );
    final packageHash =
        SkillPackage.calculatePackageHash(item.content, <String, String>{
          for (final row in fileRows)
            row['relative_path'] as String: row['content_hash'] as String,
        });
    final previousHash =
        _database
            .select(
              'SELECT package_hash FROM skill_packages WHERE skill_id = ?;',
              [item.id],
            )
            .first['package_hash'] as String;
    _database.execute(
      'UPDATE skill_packages SET package_hash = ? WHERE skill_id = ?;',
      [packageHash, item.id],
    );
    if (packageHash != previousHash) {
      _journal?.record(SyncEntityType.skillPackage, item.id, SyncChangeOp.put);
    }
  }

  @override
  Future<void> renameCategory(
    ItemType type,
    String oldName,
    String newName,
  ) {
    final runner = _transactionRunner;
    if (runner == null) {
      return _renameCategoryUnqueued(type, oldName, newName);
    }
    return runner(() => _renameCategoryUnqueued(type, oldName, newName));
  }

  Future<void> _renameCategoryUnqueued(
    ItemType type,
    String oldName,
    String newName,
  ) async {
    final oldCategory = _normalizeCategory(oldName);
    final nextCategory = _normalizeCategory(newName);
    if (oldCategory == nextCategory) return;

    final changedAt = DateTime.now().toUtc().toIso8601String();
    final oldExists =
        _database
            .select(
              'SELECT 1 FROM item_categories WHERE type = ? AND name = ?;',
              [type.name, oldCategory],
            )
            .isNotEmpty;
    final affectedIds = _database
        .select(
          'SELECT id FROM items WHERE type = ? AND category = ?;',
          [type.name, oldCategory],
        )
        .map((row) => row['id'] as String)
        .toList(growable: false);
    _database.execute(
      '''
      INSERT OR IGNORE INTO item_categories (
        type, name, sort_order, created_at
      )
      SELECT type, ?, sort_order, created_at
      FROM item_categories
      WHERE type = ? AND name = ?;
    ''',
      [nextCategory, type.name, oldCategory],
    );
    final createdNew = _database.updatedRows > 0;
    _database.execute(
      '''
      UPDATE items
      SET category = ?, updated_at = ?
      WHERE type = ? AND category = ?;
    ''',
      [nextCategory, changedAt, type.name, oldCategory],
    );
    _database.execute(
      'DELETE FROM item_categories WHERE type = ? AND name = ?;',
      [type.name, oldCategory],
    );
    // Rename = create-new + delete-old + every moved item re-pushed, so
    // other devices materialize the same two category entities (protocol
    // §3.2) and no item keeps a dangling reference.
    for (final id in affectedIds) {
      _journal?.record(SyncEntityType.forItem(type), id, SyncChangeOp.put);
    }
    if (createdNew) {
      _journal?.record(
        SyncEntityType.forCategory(type),
        nextCategory,
        SyncChangeOp.put,
      );
    }
    if (oldExists) {
      _journal?.record(
        SyncEntityType.forCategory(type),
        oldCategory,
        SyncChangeOp.delete,
      );
    }
  }

  @override
  Future<List<JianheItem>> search(
    String query, {
    ItemType? type,
    bool favoritesOnly = false,
    int? rating,
    String? category,
    ItemSortMode sortMode = ItemSortMode.smart,
    int limit = 50,
  }) async {
    _validateLimit(limit);
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return const <JianheItem>[];

    final clauses = <String>[
      "(title LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\' OR category LIKE ? ESCAPE '\\')",
    ];
    final pattern = _toLikePattern(normalizedQuery);
    final whereParameters = <Object?>[pattern, pattern, pattern];
    if (type != null) {
      clauses.add('type = ?');
      whereParameters.add(type.name);
    }
    if (rating != null) {
      _validateRating(rating);
      clauses.add('rating = ?');
      whereParameters.add(rating);
    } else if (favoritesOnly) {
      clauses.add('rating > 0');
    }
    if (category != null) {
      clauses.add('category = ?');
      whereParameters.add(category.trim());
    }

    final rows = _database.select(
      '''
      SELECT * FROM items
      WHERE ${clauses.join(' AND ')}
      ORDER BY
        CASE
          WHEN lower(title) = lower(?) THEN 0
          WHEN title LIKE ? ESCAPE '\\' THEN 1
          WHEN category LIKE ? ESCAPE '\\' THEN 2
          ELSE 3
        END,
        ${_orderBy(sortMode)}
      LIMIT ?;
    ''',
      <Object?>[...whereParameters, normalizedQuery, pattern, pattern, limit],
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  JianheItem _fromRow(Row row) {
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

  static String _toLikePattern(String query) {
    final escaped = query
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    return '%$escaped%';
  }

  static String _normalizeCategory(String name) {
    final normalized = name.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Category cannot be empty.');
    }
    if (!JianheItem.isValidCategoryName(normalized)) {
      throw ArgumentError.value(
        name,
        'name',
        'Category cannot exceed ${JianheItem.maxCategoryLength} characters '
            'or contain control characters.',
      );
    }
    return normalized;
  }

  static String _orderBy(ItemSortMode sortMode) => switch (sortMode) {
    ItemSortMode.smart =>
      '''
      rating DESC,
      CASE WHEN last_used_at IS NULL THEN 1 ELSE 0 END,
      last_used_at DESC,
      use_count DESC,
      updated_at DESC
    ''',
    ItemSortMode.custom =>
      '''
      sort_order ASC,
      rating DESC,
      updated_at DESC
    ''',
    ItemSortMode.recentlyUsed =>
      '''
      CASE WHEN last_used_at IS NULL THEN 1 ELSE 0 END,
      last_used_at DESC,
      updated_at DESC
    ''',
    ItemSortMode.mostUsed =>
      '''
      use_count DESC,
      CASE WHEN last_used_at IS NULL THEN 1 ELSE 0 END,
      last_used_at DESC,
      updated_at DESC
    ''',
    ItemSortMode.rating => 'rating DESC, updated_at DESC',
    ItemSortMode.recentlyUpdated => 'updated_at DESC',
    ItemSortMode.title => 'title COLLATE NOCASE ASC, updated_at DESC',
  };

  static void _validateLimit(int limit) {
    if (limit < 1 || limit > 1000) {
      throw RangeError.range(limit, 1, 1000, 'limit');
    }
  }

  static void _validateRating(int rating) {
    if (rating < 0 || rating > 5) {
      throw RangeError.range(rating, 0, 5, 'rating');
    }
  }
}
