import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:jianhe_core/jianhe_core.dart' show AppLanguage, CliAccessMode, JianheItem;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'sqlite_item_repository.dart';
import 'sqlite_settings_store.dart';
import 'sqlite_skill_package_repository.dart';
import 'sqlite_sync_journal.dart';
import 'sqlite_sync_store.dart';

class JianheStorageDatabase {
  static const schemaVersion = 7;

  /// Marks the async chain of a running transaction's action, so a
  /// call issued from inside it nests via a savepoint while a call issued
  /// from anywhere else queues behind the transaction. The autocommit flag
  /// alone cannot tell these apart: it is false for both.
  static const _inWriteTxKey = #jianhe_in_write_transaction;

  /// How long a short-lived read-only probe waits for a lock. A probe without
  /// a busy timeout fails at once with SQLITE_BUSY whenever another
  /// connection (a parallel jianhe process, the desktop app) is closing and
  /// briefly holds the database exclusively to checkpoint the WAL.
  static const _probeBusyTimeoutMs = 5000;

  static Database _openReadOnlyProbe(
    String path, {
    int busyTimeoutMs = _probeBusyTimeoutMs,
  }) {
    final database = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      database.execute('PRAGMA busy_timeout = $busyTimeoutMs;');
    } on Object {
      database.close();
      rethrow;
    }
    return database;
  }

  static int readSchemaVersion(String path) {
    final database = _openReadOnlyProbe(path);
    try {
      return database.select('PRAGMA user_version;').first['user_version']
          as int;
    } finally {
      database.close();
    }
  }

  /// Reads the persisted CLI access switch through a read-only connection,
  /// without migrating, repairing or otherwise writing to the database.
  /// Callers that need write access check this before [open] with
  /// `readOnly: false`, because that open upgrades the schema.
  static CliAccessMode readCliAccessMode(String path) {
    final database = _openReadOnlyProbe(path);
    try {
      return SqliteSettingsStore.readCliAccessMode(database);
    } finally {
      database.close();
    }
  }

  /// Reads the interface language through a read-only connection, without
  /// migrating or writing. Databases without the setting report
  /// [AppLanguage.fallback].
  static AppLanguage readUiLanguage(String path) {
    final database = _openReadOnlyProbe(path);
    try {
      return SqliteSettingsStore.readUiLanguage(database);
    } finally {
      database.close();
    }
  }

  JianheStorageDatabase._(this.database)
    : items = SqliteItemRepository(database),
      skills = SqliteSkillPackageRepository(database),
      settings = SqliteSettingsStore(database),
      sync = SqliteSyncStore(database) {
    journal = SqliteSyncJournal(database);
    items.attachJournal(journal);
    skills.attachJournal(journal);
    items.attachTransactionRunner(writeTransaction);
    skills.attachTransactionRunner(writeTransaction);
    settings.attachWriteGuard((
      // A transaction is open on this connection (it yielded mid-way), and
      // this write does not belong to it.
      shouldDefer: () =>
          !database.autocommit && Zone.current[_inWriteTxKey] != true,
      defer: (write) => writeTransaction(() async => write()),
    ));
  }

  final Database database;
  final SqliteItemRepository items;
  final SqliteSkillPackageRepository skills;
  final SqliteSettingsStore settings;
  final SqliteSyncStore sync;
  late final SqliteSyncJournal journal;

  Future<void> _writeQueue = Future<void>.value();
  int _nestedDepth = 0;

  /// busy_timeout for ordinary statements on this connection, applied after
  /// migration. Each wait blocks the calling isolate inside SQLite.
  int _busyTimeoutMs = 5000;

  /// busy_timeout while [_migrate] waits for the upgrade's write lock.
  int _migrationBusyTimeoutMs = 15000;

  /// Opens [path] like [open], but waits for a write lock another process
  /// holds during a schema upgrade on the event loop instead of inside
  /// SQLite: each attempt gives up after a short busy timeout and is retried
  /// until [maxWait]. The desktop app uses it at startup, where the
  /// blocking 15 s wait left the floating ball visible but unresponsive.
  static Future<JianheStorageDatabase> openWhenAvailable(
    String path, {
    int busyTimeoutMs = 5000,
    Duration maxWait = const Duration(seconds: 15),
    Duration retryInterval = const Duration(milliseconds: 250),
  }) async {
    final stopwatch = Stopwatch()..start();
    while (true) {
      try {
        return JianheStorageDatabase.open(
          path,
          busyTimeoutMs: busyTimeoutMs,
          migrationBusyTimeoutMs: 200,
        );
      } on Object catch (error) {
        if (!isLockedError(error) || stopwatch.elapsed >= maxWait) rethrow;
      }
      await Future<void>.delayed(retryInterval);
    }
  }

  /// How long [writeTransaction] keeps retrying for the write lock another
  /// process (the jianhe CLI, the background sync worker) holds.
  Duration writeLockMaxWait = const Duration(seconds: 30);

  /// Interval between non-blocking write-lock attempts.
  static const _writeLockRetryInterval = Duration(milliseconds: 100);

  final StreamController<bool> _writeLockWaits =
      StreamController<bool>.broadcast();

  /// Emits true when a [writeTransaction] starts waiting for a write lock
  /// held by another process, and false once that wait ends (lock acquired
  /// or given up). The UI uses it to explain a pending save.
  Stream<bool> get writeLockWaits => _writeLockWaits.stream;

  /// [busyTimeoutMs] bounds how long a single statement may block the
  /// calling isolate on a lock another process holds. Headless callers (the
  /// CLI) keep the 5 s default; the desktop UI passes a short value, since
  /// its transactions wait for the lock asynchronously instead.
  factory JianheStorageDatabase.open(
    String path, {
    bool readOnly = false,
    int busyTimeoutMs = 5000,
    int migrationBusyTimeoutMs = 15000,
  }) {
    final file = File(path);
    if (readOnly && !file.existsSync()) {
      throw FileSystemException('Jianhe database does not exist.', path);
    }
    if (!readOnly) {
      file.parent.createSync(recursive: true);
      if (file.existsSync()) {
        // Same wait as the migration: the desktop app passes a short value
        // and retries on the event loop instead of blocking the UI.
        _backupLegacyV0Database(file, busyTimeoutMs: migrationBusyTimeoutMs);
      }
    }

    final database = sqlite3.open(
      path,
      mode: readOnly ? OpenMode.readOnly : OpenMode.readWriteCreate,
    );
    final storage = JianheStorageDatabase._(database)
      .._busyTimeoutMs = busyTimeoutMs
      .._migrationBusyTimeoutMs = migrationBusyTimeoutMs;
    try {
      // Read-only connections never reach _migrate, which is where the busy
      // timeout used to be set, so they failed at once on a transient lock.
      database.execute('PRAGMA busy_timeout = $busyTimeoutMs;');
      if (readOnly) {
        storage._verifySchema();
      } else {
        storage._migrate();
      }
    } on Object {
      // Release the file so a retry, the uninstaller or the user can replace
      // it; the caller only ever sees the exception.
      database.close();
      rethrow;
    }
    return storage;
  }

  factory JianheStorageDatabase.inMemory() {
    final storage = JianheStorageDatabase._(sqlite3.openInMemory());
    storage._migrate();
    return storage;
  }

  /// SQLite's `PRAGMA data_version` for this connection. It changes only
  /// when another connection (the jianhe CLI, a background sync process)
  /// commits; this connection's own writes leave it unchanged. Comparing two
  /// reads therefore tells whether someone else wrote in between.
  int readDataVersion() =>
      database.select('PRAGMA data_version;').first['data_version'] as int;

  void close() {
    unawaited(_writeLockWaits.close());
    database.close();
  }

  /// Serializes top-level write transactions on this connection. Two
  /// hazards this replaces: a second call issued while a transaction was
  /// awaiting inside its action used to slip into that open transaction
  /// and lose control of its own commit, and a nested failure used to
  /// roll back the enclosing restore or merge as a whole. Nested calls now
  /// run under their own savepoint, so only the nested writes are undone.
  ///
  /// [recordChanges] = false suppresses sync journal capture for the whole
  /// transaction; the incremental sync replay path uses it to apply pulled
  /// remote changes without re-echoing them into `pending_changes`.
  Future<T> writeTransaction<T>(
    Future<T> Function() action, {
    bool recordChanges = true,
  }) {
    if (Zone.current[_inWriteTxKey] == true) {
      final depth = ++_nestedDepth;
      final savepoint = 'jianhe_nested_$depth';
      database.execute('SAVEPOINT $savepoint;');
      final guarded = recordChanges
          ? action
          : () => runZoned(
              action,
              zoneValues: <Object?, Object?>{SqliteSyncJournal.skipFlagKey: true},
            );
      Future<T> result;
      try {
        result = guarded();
      } on Object {
        _releaseNested(savepoint);
        rethrow;
      }
      return result.then<T>(
        (value) {
          database.execute('RELEASE SAVEPOINT $savepoint;');
          _nestedDepth--;
          return value;
        },
        onError: (Object error) {
          _releaseNested(savepoint);
          throw error;
        },
      );
    }
    final run = _writeQueue.then((_) => _runQueued(action, recordChanges));
    _writeQueue = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<T> _runQueued<T>(
    Future<T> Function() action,
    bool recordChanges,
  ) async {
    await _beginImmediate();
    Future<T> result;
    try {
      result = runZoned(
        action,
        zoneValues: <Object?, Object?>{
          _inWriteTxKey: true,
          SqliteSyncJournal.txEntriesKey: SqliteSyncJournal.newTxEntries(),
          if (!recordChanges) SqliteSyncJournal.skipFlagKey: true,
        },
      );
    } on Object {
      database.execute('ROLLBACK;');
      rethrow;
    }
    return result.then<T>(
      (value) {
        try {
          database.execute('COMMIT;');
          return value;
        } on Object {
          // A failed COMMIT leaves the transaction open on this connection;
          // without this rollback every later BEGIN IMMEDIATE would fail.
          database.execute('ROLLBACK;');
          rethrow;
        }
      },
      onError: (Object error) {
        database.execute('ROLLBACK;');
        throw error;
      },
    );
  }

  /// Takes the write lock without blocking the isolate while another
  /// process holds it. Each attempt fails fast (busy_timeout 0) and the
  /// retry waits on the event loop, so the UI keeps painting; the previous
  /// single BEGIN IMMEDIATE could freeze it for the whole busy_timeout.
  Future<void> _beginImmediate() async {
    final stopwatch = Stopwatch()..start();
    var waiting = false;
    try {
      while (true) {
        database.execute('PRAGMA busy_timeout = 0;');
        try {
          database.execute('BEGIN IMMEDIATE;');
          return;
        } on SqliteException catch (error) {
          if (!isLockedError(error) ||
              stopwatch.elapsed >= writeLockMaxWait) {
            rethrow;
          }
        } finally {
          database.execute('PRAGMA busy_timeout = $_busyTimeoutMs;');
        }
        if (!waiting) {
          waiting = true;
          if (!_writeLockWaits.isClosed) _writeLockWaits.add(true);
        }
        await Future<void>.delayed(_writeLockRetryInterval);
      }
    } finally {
      if (waiting && !_writeLockWaits.isClosed) _writeLockWaits.add(false);
    }
  }

  void _releaseNested(String savepoint) {
    try {
      database.execute('ROLLBACK TO SAVEPOINT $savepoint;');
      database.execute('RELEASE SAVEPOINT $savepoint;');
    } on Object {
      // A broken connection leaves nothing to release; the enclosing
      // rollback still discards everything.
    } finally {
      _nestedDepth--;
    }
  }

  /// Tables every current build reads or writes.
  static const _requiredTables = <String>[
    'items',
    'item_categories',
    'skill_packages',
    'skill_files',
    'pending_changes',
    'sync_state',
    'app_settings',
  ];

  static const _requiredIndexes = <String>[
    'idx_items_type_updated',
    'idx_items_last_used',
    'idx_items_type_category_order',
    'idx_items_type_rating',
    'idx_item_categories_type_order',
    'idx_skill_packages_hash',
    'idx_skill_files_skill_path',
  ];

  /// `items` columns that older, debug or half-upgraded databases may lack,
  /// with the DDL needed to append each one. Iteration order matters:
  /// `rating` is derived from `is_favorite` when it has to be added.
  /// `id`, `title` and `content` are not listed: a table without them holds
  /// no usable data and cannot be repaired.
  static const _repairableItemColumns = <String, String>{
    'type':
        "TEXT NOT NULL DEFAULT 'snippet' "
        "CHECK (type IN ('prompt', 'skill', 'snippet'))",
    'is_favorite': 'INTEGER NOT NULL DEFAULT 0',
    'rating': 'INTEGER NOT NULL DEFAULT 0 CHECK (rating BETWEEN 0 AND 5)',
    'category': "TEXT NOT NULL DEFAULT ''",
    'sort_order': 'INTEGER NOT NULL DEFAULT 0',
    'use_count': 'INTEGER NOT NULL DEFAULT 0',
    'last_used_at': 'TEXT',
    'created_at': "TEXT NOT NULL DEFAULT '$_epochTimestamp'",
    'updated_at': "TEXT NOT NULL DEFAULT '$_epochTimestamp'",
    'content_hash': "TEXT NOT NULL DEFAULT ''",
  };

  static const _epochTimestamp = '1970-01-01T00:00:00.000Z';

  /// Whether [error] means another process (typically the jianhe CLI driven
  /// by Codex or a terminal) held the database lock past busy_timeout.
  static bool isLockedError(Object error) =>
      error is SqliteException &&
      (error.resultCode == 5 || error.resultCode == 6); // BUSY / LOCKED

  int _readUserVersion() =>
      database.select('PRAGMA user_version;').first['user_version'] as int;

  bool _hasTable(String table) => database.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;",
    [table],
  ).isNotEmpty;

  Set<String> _columns(String table) => database
      .select('PRAGMA table_info("$table");')
      .map((row) => row['name'] as String)
      .toSet();

  void _migrate() {
    database.execute('PRAGMA foreign_keys = ON;');
    // The upgrade needs the write lock, which the CLI may hold briefly while
    // Codex or a terminal drives it; wait longer than ordinary writes do.
    database.execute('PRAGMA busy_timeout = $_migrationBusyTimeoutMs;');
    try {
      database.execute('PRAGMA journal_mode = WAL;');
      database.execute('PRAGMA synchronous = NORMAL;');
      final version = _readUserVersion();
      if (version > schemaVersion) {
        throw StateError('Unsupported Jianhe database schema: $version');
      }
      // Older builds could commit user_version = 5..7 without every table
      // (app_settings, for one), so the version alone never proves the
      // structure. A complete latest database is the only fast path.
      if (version == schemaVersion && !_schemaNeedsRepair()) return;

      database.execute('BEGIN IMMEDIATE;');
      try {
        // Re-read under the write lock: the CLI or the background sync
        // worker may have finished the same upgrade while we waited.
        final lockedVersion = _readUserVersion();
        if (lockedVersion > schemaVersion) {
          throw StateError('Unsupported Jianhe database schema: $lockedVersion');
        }
        if (lockedVersion == 0 && _isLegacyV0Schema()) {
          _migrateLegacyV0Schema();
        } else {
          _upgradeToLatestSchema(fromVersion: lockedVersion);
        }
        database.execute('PRAGMA user_version = $schemaVersion;');
        database.execute('COMMIT;');
      } on Object {
        database.execute('ROLLBACK;');
        rethrow;
      }
    } finally {
      database.execute('PRAGMA busy_timeout = $_busyTimeoutMs;');
    }
  }

  bool _schemaNeedsRepair() {
    final objects = database.select(
      "SELECT type, name FROM sqlite_master WHERE type IN ('table', 'index');",
    );
    Set<String> named(String type) => objects
        .where((row) => row['type'] == type)
        .map((row) => row['name'] as String)
        .toSet();
    if (!named('table').containsAll(_requiredTables)) return true;
    if (!named('index').containsAll(_requiredIndexes)) return true;
    return !_columns('items').containsAll(_repairableItemColumns.keys);
  }

  /// Brings any non-legacy database to the latest schema, judging by the
  /// tables and columns actually present instead of by user_version alone.
  /// Every step is idempotent, so a database whose version number disagrees
  /// with its structure (debug builds, half-applied upgrades, a v0 file
  /// with an older `items` table) is completed instead of failing on
  /// "duplicate column name" and rolling back on every launch.
  void _upgradeToLatestSchema({required int fromVersion}) {
    _createItemsTable();
    _addMissingItemColumns(); // v1→v2 category/sort_order, v3→v4 rating
    _createItemIndexes();
    final hadCategoryTable = _hasTable('item_categories');
    _createCategoryTable();
    // v2→v3 promoted free-text categories into item_categories. Repeat it
    // only for databases that predate it or lost the table, so categories
    // a user removed are not resurrected on a later repair.
    if (fromVersion <= 2 || !hadCategoryTable) _backfillCategories();
    _createSkillPackageSchema(); // v4→v5
    if (fromVersion <= 5) _purgeEntrypointSkillFileRows(); // v5→v6
    _createSyncSchema(); // v6→v7
    _ensureAppSettingsTable();
    _fillMissingContentHashes();
  }

  void _addMissingItemColumns() {
    final existing = _columns('items');
    for (final MapEntry(key: column, value: ddl)
        in _repairableItemColumns.entries) {
      if (existing.contains(column)) continue;
      database.execute('ALTER TABLE items ADD COLUMN $column $ddl;');
      if (column == 'rating') {
        // v3→v4: favourites become five stars. Only when the column is new,
        // so ratings a user already set are never overwritten.
        database.execute('''
          UPDATE items
          SET rating = CASE WHEN is_favorite = 1 THEN 5 ELSE 0 END;
        ''');
      }
    }
  }

  void _fillMissingContentHashes() {
    final rows = database.select(
      "SELECT id, content FROM items "
      "WHERE content_hash IS NULL OR content_hash = '';",
    );
    for (final row in rows) {
      database.execute('UPDATE items SET content_hash = ? WHERE id = ?;', [
        JianheItem.calculateContentHash(row['content'] as String),
        row['id'],
      ]);
    }
  }

  static void _backupLegacyV0Database(
    File file, {
    required int busyTimeoutMs,
  }) {
    final probe = _openReadOnlyProbe(file.path, busyTimeoutMs: busyTimeoutMs);
    final bool isLegacy;
    try {
      isLegacy = _isLegacyV0Database(probe);
    } finally {
      probe.close();
    }
    if (!isLegacy) return;
    // A failed migration rolls back and leaves the file untouched, so a
    // backup already taken of these exact bytes still covers it; without
    // this check every retrying launch added another full copy.
    if (_hasIdenticalLegacyBackup(file)) return;

    final now = DateTime.now().toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    final timestamp =
        '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    // Never overwrite an existing backup: two launches within one second
    // would otherwise share a name and the second copy would replace the
    // first.
    final base = '${file.path}.legacy-v0-$timestamp';
    var backupPath = '$base.bak';
    for (var n = 1; File(backupPath).existsSync(); n++) {
      backupPath = '$base-$n.bak';
    }
    file.copySync(backupPath);
    for (final suffix in const ['-wal', '-shm']) {
      final companion = File('${file.path}$suffix');
      if (companion.existsSync()) {
        companion.copySync('$backupPath$suffix');
      }
    }
  }

  static bool _hasIdenticalLegacyBackup(File file) {
    final prefix = '${p.basename(file.path)}.legacy-v0-';
    final walLength = _walContentLength(File('${file.path}-wal'));
    Uint8List? bytes;
    for (final entry in file.parent.listSync()) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (!name.startsWith(prefix) || !name.endsWith('.bak')) continue;
      if (entry.lengthSync() != file.lengthSync()) continue;
      final backupWalLength = _walContentLength(File('${entry.path}-wal'));
      if (backupWalLength != walLength) continue;
      bytes ??= file.readAsBytesSync();
      if (_sameDatabaseBytes(bytes, entry.readAsBytesSync())) return true;
    }
    return false;
  }

  /// Length of a WAL companion, with a missing file counted as empty. After
  /// a failed attempt has switched the database to WAL, the read-only probe
  /// in [_backupLegacyV0Database] cannot remove the WAL it opens and leaves
  /// a 0-byte `-wal` behind. An empty WAL holds no frames, so it must match
  /// a backup taken before the switch, which has no `-wal` at all.
  static int _walContentLength(File wal) =>
      wal.existsSync() ? wal.lengthSync() : 0;

  /// Byte equality for two SQLite main files, ignoring the header fields a
  /// rolled-back attempt still rewrites:
  ///  * 18-19 file format write/read version (1 = rollback journal, 2 = WAL);
  ///  * 24-27 file change counter;
  ///  * 92-95 version-valid-for number;
  ///  * 96-99 SQLITE_VERSION_NUMBER of the last writer.
  /// `_migrate` switches the file to WAL before the upgrade transaction. That
  /// switch commits on its own in rollback-journal mode, which bumps the
  /// change counter and stamps 92-99, while every row of the failed upgrade
  /// is rolled back. Comparing those bytes made the next launch take a
  /// second, identical backup (hidden only when it landed in the same second
  /// and overwrote the first).
  static bool _sameDatabaseBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (_isVolatileHeaderByte(i)) continue;
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _isVolatileHeaderByte(int i) =>
      i == 18 ||
      i == 19 ||
      (i >= 24 && i <= 27) ||
      (i >= 92 && i <= 99);

  static bool _isLegacyV0Database(Database database) {
    final version =
        database.select('PRAGMA user_version;').first['user_version'] as int;
    if (version != 0) return false;
    final tables = database.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'items';",
    );
    if (tables.isEmpty) return false;
    final columns = database
        .select('PRAGMA table_info(items);')
        .map((row) => row['name'] as String)
        .toSet();
    return columns.contains('entity_type') && !columns.contains('type');
  }

  bool _isLegacyV0Schema() => _isLegacyV0Database(database);

  /// Runs inside the caller's transaction. Builds of the unversioned desktop
  /// schema differ in which optional columns and tables they shipped
  /// (folders, folder_id, deleted_at, content_hash, is_favorite and the
  /// timestamps), so the copy only references what this file really has.
  void _migrateLegacyV0Schema() {
    database.execute('ALTER TABLE items RENAME TO legacy_items_v0;');
    _createItemsTable();
    _createItemIndexes();

    final legacy = _columns('legacy_items_v0');
    final joinFolders =
        legacy.contains('folder_id') &&
        _hasTable('folders') &&
        _columns('folders').containsAll(const ['id', 'name']);
    final hasFavorite = legacy.contains('is_favorite');
    database.execute('''
      INSERT INTO items (
        id, type, title, content, is_favorite, rating, category,
        sort_order, use_count, last_used_at, created_at, updated_at,
        content_hash
      )
      SELECT
        legacy.id,
        CASE lower(legacy.entity_type)
          WHEN 'prompt' THEN 'prompt'
          WHEN 'skill' THEN 'skill'
          WHEN 'snippet' THEN 'snippet'
          WHEN 'text' THEN 'snippet'
          ELSE 'snippet'
        END,
        substr(trim(legacy.title), 1, 100),
        substr(legacy.content, 1, 100000),
        ${hasFavorite ? 'CASE WHEN legacy.is_favorite <> 0 THEN 1 ELSE 0 END' : '0'},
        ${hasFavorite ? 'CASE WHEN legacy.is_favorite <> 0 THEN 5 ELSE 0 END' : '0'},
        ${joinFolders ? "substr(COALESCE(folder.name, ''), 1, 40)" : "''"},
        0,
        0,
        NULL,
        ${_legacyTimestamp(legacy, 'created_at')},
        ${_legacyTimestamp(legacy, 'updated_at')},
        ${legacy.contains('content_hash') ? "COALESCE(legacy.content_hash, '')" : "''"}
      FROM legacy_items_v0 AS legacy
      ${joinFolders ? 'LEFT JOIN folders AS folder ON folder.id = legacy.folder_id' : ''}
      WHERE ${legacy.contains('deleted_at') ? 'legacy.deleted_at IS NULL AND' : ''}
        trim(legacy.title) <> ''
        AND trim(legacy.content) <> '';
    ''');
    // Categories, Skill packages, sync and settings tables, plus content
    // hashes the legacy rows did not carry.
    _upgradeToLatestSchema(fromVersion: 0);
  }

  /// Legacy timestamps are epoch seconds, milliseconds or microseconds;
  /// some builds stored ISO-8601 text, which is kept as is.
  static String _legacyTimestamp(Set<String> legacyColumns, String column) {
    if (!legacyColumns.contains(column)) return "'$_epochTimestamp'";
    final value = 'legacy.$column';
    return '''
      COALESCE(
        CASE
          WHEN typeof($value) = 'text' AND $value GLOB '[0-9][0-9][0-9][0-9]-*'
            THEN $value
          ELSE strftime(
            '%Y-%m-%dT%H:%M:%fZ',
            CASE
              WHEN $value > 100000000000000 THEN $value / 1000000
              WHEN $value > 100000000000 THEN $value / 1000
              ELSE $value
            END,
            'unixepoch'
          )
        END,
        '$_epochTimestamp'
      )''';
  }

  void _createItemsTable() {
    database.execute('''
      CREATE TABLE IF NOT EXISTS items (
        id TEXT PRIMARY KEY NOT NULL,
        type TEXT NOT NULL CHECK (type IN ('prompt', 'skill', 'snippet')),
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        rating INTEGER NOT NULL DEFAULT 0
          CHECK (rating BETWEEN 0 AND 5),
        category TEXT NOT NULL DEFAULT '',
        sort_order INTEGER NOT NULL DEFAULT 0,
        use_count INTEGER NOT NULL DEFAULT 0,
        last_used_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        content_hash TEXT NOT NULL
      );
    ''');
  }

  void _createItemIndexes() {
    database.execute('''
      CREATE INDEX IF NOT EXISTS idx_items_type_updated
      ON items(type, updated_at DESC);
    ''');
    database.execute('''
      CREATE INDEX IF NOT EXISTS idx_items_last_used
      ON items(last_used_at DESC);
    ''');
    database.execute('''
      CREATE INDEX IF NOT EXISTS idx_items_type_category_order
      ON items(type, category, sort_order ASC);
    ''');
    database.execute('''
      CREATE INDEX IF NOT EXISTS idx_items_type_rating
      ON items(type, rating DESC);
    ''');
  }

  // v7: incremental sync capture (docs/cloud-sync-protocol-v1.md §5).
  void _createSyncSchema() {
    database.execute('''
      CREATE TABLE IF NOT EXISTS pending_changes (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        op TEXT NOT NULL CHECK (op IN ('put', 'delete')),
        changed_at TEXT NOT NULL
      );
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS sync_state (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
      );
    ''');
  }

  void _ensureAppSettingsTable() {
    database.execute('''
      CREATE TABLE IF NOT EXISTS app_settings (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
  }

  void _createCategoryTable() {
    database.execute('''
      CREATE TABLE IF NOT EXISTS item_categories (
        type TEXT NOT NULL CHECK (type IN ('prompt', 'skill', 'snippet')),
        name TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        PRIMARY KEY (type, name)
      );
    ''');
    database.execute('''
      CREATE INDEX IF NOT EXISTS idx_item_categories_type_order
      ON item_categories(type, sort_order ASC, name ASC);
    ''');
  }

  void _backfillCategories() {
    database.execute('''
      INSERT OR IGNORE INTO item_categories (
        type, name, sort_order, created_at
      )
      SELECT type, category, 0, MIN(created_at)
      FROM items
      WHERE category <> ''
      GROUP BY type, category;
    ''');
  }

  // 老的调试构建可能把入口文件本身写进 skill_files；入口内容存在 items 表里，
  // 这类行是纯冗余，还会让读端重建 SkillPackage 时触发入口重名校验而全盘失败。
  void _purgeEntrypointSkillFileRows() {
    database.execute(
      "DELETE FROM skill_files WHERE relative_path = 'SKILL.md' COLLATE NOCASE;",
    );
  }

  void _createSkillPackageSchema() {
    database.execute('''
      CREATE TABLE IF NOT EXISTS skill_packages (
        skill_id TEXT PRIMARY KEY NOT NULL,
        entrypoint TEXT NOT NULL DEFAULT 'SKILL.md',
        source_format TEXT NOT NULL
          CHECK (source_format IN ('markdown', 'directory', 'zip')),
        imported_at TEXT NOT NULL,
        package_hash TEXT NOT NULL,
        FOREIGN KEY (skill_id) REFERENCES items(id) ON DELETE CASCADE
      );
    ''');
    database.execute('''
      CREATE INDEX IF NOT EXISTS idx_skill_packages_hash
      ON skill_packages(package_hash);
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS skill_files (
        skill_id TEXT NOT NULL,
        relative_path TEXT NOT NULL,
        media_type TEXT,
        byte_length INTEGER NOT NULL CHECK (byte_length >= 0),
        content_hash TEXT NOT NULL,
        content BLOB NOT NULL,
        PRIMARY KEY (skill_id, relative_path),
        FOREIGN KEY (skill_id) REFERENCES skill_packages(skill_id)
          ON DELETE CASCADE
      );
    ''');
    database.execute('''
      CREATE INDEX IF NOT EXISTS idx_skill_files_skill_path
      ON skill_files(skill_id, relative_path);
    ''');
  }

  void _verifySchema() {
    final version = database
        .select('PRAGMA user_version;')
        .first['user_version'];
    if (version != schemaVersion) {
      throw StateError('Unsupported Jianhe database schema: $version');
    }
  }
}
