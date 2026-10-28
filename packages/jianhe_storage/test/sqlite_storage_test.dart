import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:jianhe_core/jianhe_core.dart';
import 'package:jianhe_storage/jianhe_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late JianheStorageDatabase storage;

  setUp(() {
    storage = JianheStorageDatabase.inMemory();
  });

  tearDown(() {
    storage.close();
  });

  test('skill file reads trust the stored hash; verifyIntegrity rechecks',
      () async {
    final skill = JianheItem.create(
      id: 'trusted-skill',
      type: ItemType.skill,
      title: '技能',
      content: '# 入口',
    );
    await storage.skills.replaceSkill(
      skill,
      SkillPackage(
        skillId: skill.id,
        sourceFormat: SkillSourceFormat.directory,
        importedAt: DateTime.utc(2026, 9, 9),
        files: <SkillFile>[
          SkillFile(
            relativePath: 'notes.md',
            content: Uint8List.fromList(utf8.encode('original')),
          ),
        ],
      ),
    );
    // Simulate storage corruption behind the recorded hash.
    storage.database.execute(
      "UPDATE skill_files SET content = ? WHERE skill_id = ?;",
      [Uint8List.fromList(utf8.encode('tampered')), skill.id],
    );

    // Reads no longer re-hash (that cost a full sha256 pass per open)...
    final package = await storage.skills.getBySkillId(skill.id);
    final file = package!.files.single;
    expect(utf8.decode(file.content), 'tampered');
    final single = await storage.skills.readFile(skill.id, 'notes.md');
    expect(single, isNotNull);
    // ...but bytes about to leave the app are still checked.
    expect(file.verifyIntegrity, throwsA(isA<SkillPackageFormatException>()));
  });

  test('a settings save made while a yielding transaction is open survives '
      'its rollback', () async {
    storage.settings.setCliAccessMode(CliAccessMode.readWrite);
    final yielded = Completer<void>();
    final release = Completer<void>();

    final failing = storage.writeTransaction(() async {
      await storage.items.save(
        JianheItem.create(
          id: 'rolled-back',
          type: ItemType.prompt,
          title: '回滚',
          content: '内容',
        ),
      );
      // Like a sync apply or backup import handing the event loop a turn.
      yielded.complete();
      await release.future;
      throw StateError('import failed');
    });

    await yielded.future;
    // The user switches the CLI off while the transaction is open.
    storage.settings.setCliAccessMode(CliAccessMode.disabled);
    storage.settings.write('ball_dock_edge', 'left');
    // Read-after-write still sees the new values before they hit the disk.
    expect(storage.settings.cliAccessMode, CliAccessMode.disabled);
    expect(storage.settings.read('ball_dock_edge'), 'left');

    release.complete();
    await expectLater(failing, throwsStateError);
    // Let the deferred write transaction run.
    await Future<void>.delayed(Duration.zero);
    await storage.writeTransaction(() async {});

    expect(await storage.items.getById('rolled-back'), isNull);
    final raw = storage.database
        .select("SELECT value FROM app_settings WHERE key = 'cli_access_mode';")
        .single['value'];
    expect(raw, CliAccessMode.disabled.storageValue);
    expect(storage.settings.cliAccessMode, CliAccessMode.disabled);
    expect(storage.settings.read('ball_dock_edge'), 'left');
  });

  test('readPendingChanges pages past a given seq', () {
    for (final id in <String>['a', 'b', 'c']) {
      storage.journal.record(SyncEntityType.categoryPrompt, id, SyncChangeOp.put);
    }
    final all = storage.sync.readPendingChanges();
    expect(all.map((row) => row.entityId), <String>['a', 'b', 'c']);
    final rest = storage.sync.readPendingChanges(afterSeq: all.first.seq);
    expect(rest.map((row) => row.entityId), <String>['b', 'c']);
    expect(
      storage.sync.readPendingChanges(afterSeq: all.first.seq, limit: 1)
          .map((row) => row.entityId),
      <String>['b'],
    );
    expect(storage.sync.readPendingChanges(afterSeq: all.last.seq), isEmpty);
  });

  test('settings saves inside a transaction stay part of it', () async {
    await expectLater(
      storage.writeTransaction(() async {
        storage.settings.write('inside_tx', '1');
        throw StateError('roll back');
      }),
      throwsStateError,
    );
    expect(storage.settings.read('inside_tx'), isNull);
  });

  group('write lock held by another process', () {
    late Directory directory;
    late String path;
    late JianheStorageDatabase desktop;
    late Database other;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('jianhe-lock-');
      path = '${directory.path}${Platform.pathSeparator}jianhe.db';
      desktop = JianheStorageDatabase.open(path, busyTimeoutMs: 1000);
      other = sqlite3.open(path);
      other.execute('BEGIN IMMEDIATE;');
    });

    tearDown(() {
      try {
        other.execute('ROLLBACK;');
      } on Object {
        // Already released by the test.
      }
      other.close();
      desktop.close();
      directory.deleteSync(recursive: true);
    });

    test('a transaction waits on the event loop and reports the wait',
        () async {
      final waits = <bool>[];
      final subscription = desktop.writeLockWaits.listen(waits.add);
      var ticks = 0;
      final ticker = Timer.periodic(
        const Duration(milliseconds: 20),
        (_) => ticks++,
      );
      Timer(const Duration(milliseconds: 400), () {
        other.execute('ROLLBACK;');
      });

      await desktop.writeTransaction(() async {
        desktop.settings.write('lock_probe', 'saved');
      });
      ticker.cancel();
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(desktop.settings.read('lock_probe'), 'saved');
      expect(waits, <bool>[true, false]);
      // The isolate kept running timers while the lock was held; a blocking
      // BEGIN IMMEDIATE would have produced no ticks at all.
      expect(ticks, greaterThan(5));
    });

    test('startup waits for an upgrade lock on the event loop', () async {
      // Force the next open to run a schema upgrade, which needs the write
      // lock the other process holds.
      other.execute('ROLLBACK;');
      desktop.database.execute('PRAGMA user_version = 6;');
      other.execute('BEGIN IMMEDIATE;');

      var ticks = 0;
      final ticker = Timer.periodic(
        const Duration(milliseconds: 20),
        (_) => ticks++,
      );
      Timer(const Duration(milliseconds: 600), () {
        other.execute('ROLLBACK;');
      });

      final reopened = await JianheStorageDatabase.openWhenAvailable(path);
      ticker.cancel();
      addTearDown(reopened.close);

      expect(
        reopened.database.select('PRAGMA user_version;').first['user_version'],
        JianheStorageDatabase.schemaVersion,
      );
      // A blocking busy_timeout would have starved the timer entirely.
      expect(ticks, greaterThan(10));
    });

    test('startup gives up after maxWait while the lock stays held', () async {
      other.execute('ROLLBACK;');
      desktop.database.execute('PRAGMA user_version = 6;');
      other.execute('BEGIN IMMEDIATE;');

      await expectLater(
        JianheStorageDatabase.openWhenAvailable(
          path,
          maxWait: const Duration(milliseconds: 500),
        ),
        throwsA(
          predicate<Object>(JianheStorageDatabase.isLockedError, 'locked'),
        ),
      );
    });

    test('a transaction gives up with BUSY after writeLockMaxWait', () async {
      desktop.writeLockMaxWait = const Duration(milliseconds: 300);
      final waits = <bool>[];
      final subscription = desktop.writeLockWaits.listen(waits.add);

      await expectLater(
        desktop.writeTransaction(() async {
          desktop.settings.write('lock_probe', 'never');
        }),
        throwsA(
          predicate<Object>(JianheStorageDatabase.isLockedError, 'locked'),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(waits, <bool>[true, false]);
      // The connection is usable again once the other process lets go.
      other.execute('ROLLBACK;');
      await desktop.writeTransaction(() async {
        desktop.settings.write('lock_probe', 'later');
      });
      expect(desktop.settings.read('lock_probe'), 'later');
    });
  });

  test('write transaction rolls back all backup merge writes', () async {
    final item = JianheItem.create(
      id: 'transaction-item',
      type: ItemType.prompt,
      title: '事务测试',
      content: '不会保留',
    );

    await expectLater(
      storage.writeTransaction(() async {
        await storage.items.save(item);
        throw StateError('stop');
      }),
      throwsStateError,
    );

    expect(await storage.items.getById(item.id), isNull);
  });

  test('a failing save leaves no partial state behind', () async {
    final skill = JianheItem.create(
      id: 'skill-partial',
      type: ItemType.skill,
      title: '原子性',
      content: '# v1',
    );
    await storage.skills.replaceSkill(
      skill,
      SkillPackage(
        skillId: skill.id,
        sourceFormat: SkillSourceFormat.markdown,
        importedAt: DateTime.utc(2026, 9, 7),
      ),
    );
    // Abort the very last write of save() so the earlier upsert must be
    // rolled back with it.
    storage.database.execute(
      "CREATE TRIGGER force_fail BEFORE UPDATE ON skill_packages "
      "BEGIN SELECT RAISE(ABORT, 'forced'); END;",
    );

    await expectLater(
      storage.items.save(skill.copyWith(content: '# v2')),
      throwsA(anything),
    );

    expect((await storage.items.getById(skill.id))?.content, '# v1');
  });

  test('concurrent write transactions queue instead of interleaving', () async {
    final gate = Completer<void>();
    final order = <String>[];
    final first = storage.writeTransaction(() async {
      order.add('first-start');
      await gate.future;
      order.add('first-end');
    });
    await Future<void>.delayed(Duration.zero);
    final second = storage.writeTransaction(() async {
      order.add('second');
    });
    await Future<void>.delayed(Duration.zero);

    // The second transaction must not have slipped into the open first
    // one; it starts only after the first commits.
    expect(order, <String>['first-start']);
    gate.complete();
    await first;
    await second;
    expect(order, <String>['first-start', 'first-end', 'second']);
  });

  test('a nested transaction failure rolls back only the nested writes',
      () async {
    final outer = JianheItem.create(
      id: 'outer-tx',
      type: ItemType.prompt,
      title: '外层保留',
      content: '保留',
    );
    final inner = JianheItem.create(
      id: 'inner-tx',
      type: ItemType.prompt,
      title: '内层丢弃',
      content: '丢弃',
    );

    await storage.writeTransaction(() async {
      await storage.items.save(outer);
      await expectLater(
        storage.writeTransaction(() async {
          await storage.items.save(inner);
          throw StateError('inner stop');
        }),
        throwsStateError,
      );
    });

    expect(await storage.items.getById(outer.id), isNotNull);
    expect(await storage.items.getById(inner.id), isNull);
  });

  test('a queued replaceSkill does not join the transaction ahead of it',
      () async {
    final gate = Completer<void>();
    final skill = JianheItem.create(
      id: 'skill-race',
      type: ItemType.skill,
      title: '并发包',
      content: '# 并发',
    );

    final first = storage.writeTransaction(() async {
      await gate.future;
      throw StateError('first fails');
    });
    await Future<void>.delayed(Duration.zero);
    final replace = storage.skills.replaceSkill(
      skill,
      SkillPackage(
        skillId: skill.id,
        sourceFormat: SkillSourceFormat.markdown,
        importedAt: DateTime.utc(2026, 9, 7),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    gate.complete();
    await expectLater(first, throwsStateError);
    await replace;

    // replaceSkill must commit in its own transaction, not ride along in
    // the failing one ahead of it.
    expect(await storage.skills.getBySkillId(skill.id), isNotNull);
  });

  test('replaceSkill issued inside a transaction commits with the outer one',
      () async {
    final skill = JianheItem.create(
      id: 'skill-nested',
      type: ItemType.skill,
      title: '嵌套包',
      content: '# v1',
    );
    await storage.skills.replaceSkill(
      skill,
      SkillPackage(
        skillId: skill.id,
        sourceFormat: SkillSourceFormat.markdown,
        importedAt: DateTime.utc(2026, 9, 7),
      ),
    );

    await expectLater(
      storage.writeTransaction(() async {
        await storage.skills.replaceSkill(
          skill.copyWith(content: '# v2'),
          SkillPackage(
            skillId: skill.id,
            sourceFormat: SkillSourceFormat.markdown,
            importedAt: DateTime.utc(2026, 9, 8),
          ),
        );
        throw StateError('outer stop');
      }),
      throwsStateError,
    );

    expect((await storage.items.getById(skill.id))?.content, '# v1');
    expect(await storage.skills.getBySkillId(skill.id), isNotNull);
  });

  test('saves, retrieves, searches, and marks items as used', () async {
    final prompt = JianheItem.create(
      id: 'prompt-1',
      type: ItemType.prompt,
      title: '会议总结',
      content: '总结会议内容：{{input}}',
      now: DateTime.utc(2026, 7, 20, 8),
    );
    final skill = JianheItem.create(
      id: 'skill-1',
      type: ItemType.skill,
      title: '内容诊断',
      content: '# 内容诊断 Skill',
      now: DateTime.utc(2026, 7, 20, 9),
    );

    await storage.items.save(prompt);
    await storage.items.save(skill);

    expect((await storage.items.getById('prompt-1'))?.title, '会议总结');
    expect(await storage.items.listAll(), hasLength(2));
    expect(await storage.items.search('内容'), hasLength(2));
    expect(await storage.items.list(type: ItemType.skill), hasLength(1));

    final used = await storage.items.markUsed(
      'prompt-1',
      now: DateTime.utc(2026, 7, 20, 10),
    );
    expect(used?.useCount, 1);
    expect((await storage.items.list()).first.id, 'prompt-1');
  });

  test(
    'moves all items and empty categories through an offline backup',
    () async {
      await storage.items.createCategory(ItemType.prompt, '空分类');
      await storage.items.save(
        JianheItem.create(
          id: 'portable-prompt',
          type: ItemType.prompt,
          title: '跨终端 Prompt',
          content: '请处理：{{input}}',
          category: '内容写作',
          rating: 4,
          sortOrder: 8,
          now: DateTime.utc(2026, 7, 29, 8),
        ),
      );

      final categories = <ItemType, List<String>>{
        for (final type in ItemType.values)
          type: await storage.items.listCategories(type),
      };
      final source = JianheBackup(
        exportedAt: DateTime.utc(2026, 7, 29, 9),
        items: await storage.items.listAll(),
        categories: categories,
        settings: const <String, Object?>{
          'auto_collapse_seconds': 18,
          'cli_access_mode': 'read_write',
        },
      );

      final destination = JianheStorageDatabase.inMemory();
      try {
        final imported = JianheBackup.decode(source.encode());
        final merge = imported.mergeItems(await destination.items.listAll());
        for (final item in <JianheItem>[...merge.created, ...merge.updated]) {
          await destination.items.save(item);
        }
        for (final entry in imported.categories.entries) {
          for (final category in entry.value) {
            await destination.items.createCategory(entry.key, category);
          }
        }

        final moved = await destination.items.getById('portable-prompt');
        expect(moved?.content, '请处理：{{input}}');
        expect(moved?.rating, 4);
        expect(moved?.sortOrder, 8);
        expect(
          await destination.items.listCategories(ItemType.prompt),
          containsAll(<String>['内容写作', '空分类']),
        );
        expect(imported.settings['auto_collapse_seconds'], 18);
      } finally {
        destination.close();
      }
    },
  );

  test('escapes SQL wildcard characters in search', () async {
    await storage.items.save(
      JianheItem.create(
        type: ItemType.snippet,
        title: '百分号',
        content: '折扣为 50%_off',
      ),
    );

    expect(await storage.items.search('50%_off'), hasLength(1));
    expect(await storage.items.search('50Xoff'), isEmpty);
  });

  test(
    'filters categories and favorites and searches category names',
    () async {
      await storage.items.save(
        JianheItem.create(
          id: 'writing',
          type: ItemType.prompt,
          title: '自然润色',
          content: '润色正文',
          category: '内容写作',
          isFavorite: true,
        ),
      );
      await storage.items.save(
        JianheItem.create(
          id: 'coding',
          type: ItemType.prompt,
          title: '检查代码',
          content: '审阅程序',
          category: '软件开发',
          rating: 2,
        ),
      );

      expect(await storage.items.search('内容写作'), hasLength(1));
      expect(
        await storage.items.list(type: ItemType.prompt, category: '内容写作'),
        hasLength(1),
      );
      expect(
        (await storage.items.search('润色', favoritesOnly: true)).single.id,
        'writing',
      );
      expect(
        (await storage.items.search('代码', favoritesOnly: true)).single.id,
        'coding',
      );
      expect((await storage.items.list(rating: 2)).single.id, 'coding');
      expect((await storage.items.list(rating: 5)).single.id, 'writing');
      await expectLater(storage.items.list(rating: 6), throwsRangeError);
    },
  );

  test('supports smart, usage, title, and custom sorting', () async {
    final now = DateTime.utc(2026, 7, 20, 8);
    final alpha =
        JianheItem.create(
          id: 'alpha',
          type: ItemType.skill,
          title: 'Alpha',
          content: '# Alpha',
          sortOrder: 2,
          now: now,
        ).copyWith(
          useCount: 8,
          lastUsedAt: now.add(const Duration(hours: 1)),
          updatedAt: now,
        );
    final beta = JianheItem.create(
      id: 'beta',
      type: ItemType.skill,
      title: 'Beta',
      content: '# Beta',
      isFavorite: true,
      sortOrder: 1,
      now: now.add(const Duration(minutes: 1)),
    );
    await storage.items.save(alpha);
    await storage.items.save(beta);

    expect((await storage.items.list()).first.id, 'beta');
    expect(
      (await storage.items.list(sortMode: ItemSortMode.mostUsed)).first.id,
      'alpha',
    );
    expect(
      (await storage.items.list(sortMode: ItemSortMode.title)).first.id,
      'alpha',
    );
    expect(
      (await storage.items.list(sortMode: ItemSortMode.custom)).first.id,
      'beta',
    );
    expect(
      (await storage.items.list(sortMode: ItemSortMode.rating)).first.id,
      'beta',
    );
  });

  test('creates empty categories and persists rename and removal', () async {
    await storage.items.createCategory(ItemType.prompt, '研究分析');

    expect(
      await storage.items.listCategories(ItemType.prompt),
      contains('研究分析'),
    );
    expect(await storage.items.list(category: '研究分析'), isEmpty);

    await storage.items.save(
      JianheItem.create(
        id: 'research',
        type: ItemType.prompt,
        title: '研究框架',
        content: '分析下面的问题',
        category: '研究分析',
      ),
    );
    await storage.items.renameCategory(ItemType.prompt, '研究分析', '深度研究');

    expect(
      await storage.items.listCategories(ItemType.prompt),
      contains('深度研究'),
    );
    expect((await storage.items.getById('research'))?.category, '深度研究');

    await storage.items.deleteCategory(ItemType.prompt, '深度研究');

    expect(
      await storage.items.listCategories(ItemType.prompt),
      isNot(contains('深度研究')),
    );
    expect((await storage.items.getById('research'))?.category, '');
  });

  test('category writes enforce the cloud category-id rules', () async {
    final fortyNonBmpCharacters = List.filled(40, '😀').join();

    await storage.items.createCategory(
      ItemType.prompt,
      fortyNonBmpCharacters,
    );
    expect(
      await storage.items.listCategories(ItemType.prompt),
      contains(fortyNonBmpCharacters),
    );
    await expectLater(
      storage.items.createCategory(ItemType.prompt, '工作\n复盘'),
      throwsArgumentError,
    );
    await expectLater(
      storage.items.createCategory(
        ItemType.prompt,
        '$fortyNonBmpCharacters😀',
      ),
      throwsArgumentError,
    );
  });

  test('CLI access defaults to disabled and can be enabled', () {
    expect(storage.settings.cliAccessMode, CliAccessMode.disabled);

    storage.settings.setCliAccessMode(CliAccessMode.readWrite);

    expect(storage.settings.cliAccessMode, CliAccessMode.readWrite);
  });

  test('data_version changes only for commits from other connections', () {
    final directory = Directory.systemTemp.createTempSync('jianhe-dv-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}jianhe.db';
    final other = JianheStorageDatabase.open(path);
    addTearDown(other.close);
    final own = JianheStorageDatabase.open(path);
    addTearDown(own.close);

    final initial = own.readDataVersion();
    other.settings.write('probe', '1');
    final afterOtherCommit = own.readDataVersion();
    expect(afterOtherCommit, isNot(initial));

    own.settings.write('probe', '2');
    expect(own.readDataVersion(), afterOtherCommit);
  });

  test('CLI import permission mirrors the unified access switch', () {
    expect(storage.settings.cliSkillImportEnabled, isFalse);

    storage.settings.setCliSkillImportEnabled(true);

    expect(storage.settings.cliSkillImportEnabled, isTrue);
    expect(storage.settings.cliAccessMode, CliAccessMode.readWrite);

    storage.settings.setCliAccessMode(CliAccessMode.disabled);

    expect(storage.settings.cliSkillImportEnabled, isFalse);
  });

  test('does not upgrade a legacy read-only consent to read-write', () {
    storage.settings.write('cli_access_mode', 'read_only');

    expect(storage.settings.cliAccessMode, CliAccessMode.disabled);
    expect(storage.settings.cliSkillImportEnabled, isFalse);

    storage.settings.write('cli_skill_import_enabled', 'false');
    expect(storage.settings.cliAccessMode, CliAccessMode.disabled);
  });

  test('keeps legacy read-only plus Skill import consent as read-write', () {
    storage.settings.write('cli_access_mode', 'read_only');
    storage.settings.write('cli_skill_import_enabled', 'true');

    expect(storage.settings.cliAccessMode, CliAccessMode.readWrite);
    expect(storage.settings.cliSkillImportEnabled, isTrue);
  });

  test('stores complete Skill packages and keeps their hash current', () async {
    final skill = JianheItem.create(
      id: 'complete-skill',
      type: ItemType.skill,
      title: '完整 Skill',
      content: '# Original',
    );
    final package = SkillPackage(
      skillId: skill.id,
      sourceFormat: SkillSourceFormat.directory,
      importedAt: DateTime.utc(2026, 8, 21),
      files: <SkillFile>[
        SkillFile(
          relativePath: 'assets/icon.bin',
          content: Uint8List.fromList(<int>[0, 1, 255]),
        ),
      ],
    );

    await storage.skills.replaceSkill(skill, package);
    final restored = await storage.skills.getBySkillId(skill.id);
    final fileMetadata = await storage.skills.listFiles(skill.id);
    final selectedFile = await storage.skills.readFile(
      skill.id,
      'assets/icon.bin',
    );

    expect(restored?.files.single.content, <int>[0, 1, 255]);
    expect(fileMetadata, hasLength(1));
    expect(fileMetadata.single.relativePath, 'assets/icon.bin');
    expect(fileMetadata.single.byteLength, 3);
    expect(fileMetadata.single.contentHash, package.files.single.contentHash);
    expect(selectedFile?.content, <int>[0, 1, 255]);
    expect(await storage.skills.readFile(skill.id, 'missing.txt'), isNull);
    expect(
      await storage.skills.findSkillIdByPackageHash(
        package.packageHash(skill.content),
      ),
      skill.id,
    );

    final edited = skill.copyWith(content: '# Edited');
    await storage.items.save(edited);

    expect(
      await storage.skills.findSkillIdByPackageHash(
        package.packageHash(edited.content),
      ),
      skill.id,
    );
    expect(
      await storage.skills.findSkillIdByPackageHash(
        package.packageHash(skill.content),
      ),
      isNull,
    );
  });

  test('changing a Skill to another item type removes its package', () async {
    final skill = JianheItem.create(
      id: 'convert-skill',
      type: ItemType.skill,
      title: '待转换',
      content: '# Skill',
    );
    await storage.skills.replaceSkill(
      skill,
      SkillPackage(
        skillId: skill.id,
        sourceFormat: SkillSourceFormat.markdown,
        importedAt: DateTime.utc(2026, 8, 21),
      ),
    );

    await storage.items.save(skill.copyWith(type: ItemType.prompt));

    expect(await storage.skills.getBySkillId(skill.id), isNull);
  });

  test('auto collapse defaults to four seconds and persists changes', () {
    expect(
      storage.settings.autoCollapseSeconds,
      SqliteSettingsStore.defaultAutoCollapseSeconds,
    );

    storage.settings.setAutoCollapseSeconds(25);

    expect(storage.settings.autoCollapseSeconds, 25);
    expect(() => storage.settings.setAutoCollapseSeconds(-1), throwsRangeError);
    expect(() => storage.settings.setAutoCollapseSeconds(0), throwsRangeError);
    storage.settings.setAutoCollapseSeconds(1);
    expect(storage.settings.autoCollapseSeconds, 1);
  });

  test('interface language defaults to Chinese and persists changes', () {
    expect(storage.settings.uiLanguage, AppLanguage.zh);

    storage.settings.setUiLanguage(AppLanguage.en);
    expect(storage.settings.uiLanguage, AppLanguage.en);
    expect(storage.settings.read('ui_language'), 'en');

    storage.settings.write('ui_language', 'unknown');
    expect(storage.settings.uiLanguage, AppLanguage.zh);
  });

  test('reads the interface language without opening for writes', () {
    final directory = Directory.systemTemp.createTempSync('jianhe-lang-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}jianhe.db';
    final bare = sqlite3.open(path);
    bare.execute('CREATE TABLE unrelated (id INTEGER);');
    bare.close();
    expect(JianheStorageDatabase.readUiLanguage(path), AppLanguage.zh);

    final desktopPath = '${directory.path}${Platform.pathSeparator}app.db';
    final desktop = JianheStorageDatabase.open(desktopPath);
    expect(JianheStorageDatabase.readUiLanguage(desktopPath), AppLanguage.zh);
    desktop.settings.setUiLanguage(AppLanguage.en);
    desktop.close();
    expect(JianheStorageDatabase.readUiLanguage(desktopPath), AppLanguage.en);
  });

  test('backs up and migrates the legacy unversioned desktop schema', () async {
    final directory = Directory.systemTemp.createTempSync('jianhe-v0-');
    final path = '${directory.path}${Platform.pathSeparator}jianhe.db';
    final legacy = sqlite3.open(path);
    legacy.execute('''
      CREATE TABLE folders (
        id TEXT NOT NULL PRIMARY KEY,
        entity_type TEXT NOT NULL DEFAULT 'folder',
        name TEXT NOT NULL,
        parent_id TEXT,
        account_id TEXT,
        local_revision INTEGER NOT NULL DEFAULT 0,
        server_revision INTEGER,
        base_server_revision INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted_at INTEGER,
        origin_device_id TEXT,
        crypto_version INTEGER NOT NULL DEFAULT 1
      );
      CREATE TABLE items (
        id TEXT NOT NULL PRIMARY KEY,
        entity_type TEXT NOT NULL,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        folder_id TEXT,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        sort_key TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        account_id TEXT,
        local_revision INTEGER NOT NULL DEFAULT 0,
        server_revision INTEGER,
        base_server_revision INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted_at INTEGER,
        origin_device_id TEXT,
        crypto_version INTEGER NOT NULL DEFAULT 1,
        FOREIGN KEY (folder_id) REFERENCES folders(id)
      );
    ''');
    legacy.execute(
      'INSERT INTO folders (id, name, created_at, updated_at) '
      'VALUES (?, ?, ?, ?);',
      ['folder-1', '工作复盘', 1784534400000000, 1784534400000000],
    );
    legacy.execute(
      '''
      INSERT INTO items (
        id, entity_type, title, content, folder_id, is_favorite,
        sort_key, content_hash, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
      [
        'legacy-prompt',
        'prompt',
        '旧 Prompt',
        '请整理：{{input}}',
        'folder-1',
        1,
        'a',
        JianheItem.calculateContentHash('请整理：{{input}}'),
        1784534400000000,
        1784538000000000,
      ],
    );
    legacy.close();

    final migrated = JianheStorageDatabase.open(path);
    addTearDown(() {
      migrated.close();
      directory.deleteSync(recursive: true);
    });

    final item = await migrated.items.getById('legacy-prompt');
    expect(item?.type, ItemType.prompt);
    expect(item?.title, '旧 Prompt');
    expect(item?.category, '工作复盘');
    expect(item?.rating, 5);
    expect(
      migrated.database.select('PRAGMA user_version;').first['user_version'],
      JianheStorageDatabase.schemaVersion,
    );
    expect(
      directory.listSync().whereType<File>().where(
        (file) => file.path.contains('.legacy-v0-'),
      ),
      hasLength(1),
    );

    final created = JianheItem.create(
      id: 'new-snippet',
      type: ItemType.snippet,
      title: '新文本',
      content: '迁移后仍可保存',
    );
    await migrated.items.save(created);
    expect((await migrated.items.getById('new-snippet'))?.content, '迁移后仍可保存');
  });

  test('migrates schema v1 items without losing existing data', () async {
    final directory = Directory.systemTemp.createTempSync('jianhe-v1-');
    final path = '${directory.path}${Platform.pathSeparator}jianhe.db';
    final legacy = sqlite3.open(path);
    legacy.execute('''
      CREATE TABLE items (
        id TEXT PRIMARY KEY NOT NULL,
        type TEXT NOT NULL,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        use_count INTEGER NOT NULL DEFAULT 0,
        last_used_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        content_hash TEXT NOT NULL
      );
    ''');
    legacy.execute(
      '''
      INSERT INTO items (
        id, type, title, content, is_favorite, use_count,
        last_used_at, created_at, updated_at, content_hash
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
    ''',
      [
        'legacy',
        'prompt',
        '旧素材',
        '原有内容',
        1,
        2,
        null,
        '2026-07-20T08:00:00.000Z',
        '2026-07-20T08:00:00.000Z',
        JianheItem.calculateContentHash('原有内容'),
      ],
    );
    legacy.execute('PRAGMA user_version = 1;');
    legacy.close();

    final migrated = JianheStorageDatabase.open(path);
    final item = await migrated.items.getById('legacy');
    final version = migrated.database
        .select('PRAGMA user_version;')
        .first['user_version'];
    final categories = await migrated.items.listCategories(ItemType.prompt);
    migrated.close();
    directory.deleteSync(recursive: true);

    expect(version, JianheStorageDatabase.schemaVersion);
    expect(item?.title, '旧素材');
    expect(item?.category, '');
    expect(item?.sortOrder, 0);
    expect(item?.rating, 5);
    expect(categories, isEmpty);
  });

  test(
    'migrates schema v2 categories into persistent category records',
    () async {
      final directory = Directory.systemTemp.createTempSync('jianhe-v2-');
      final path = '${directory.path}${Platform.pathSeparator}jianhe.db';
      final legacy = sqlite3.open(path);
      legacy.execute('''
      CREATE TABLE items (
        id TEXT PRIMARY KEY NOT NULL,
        type TEXT NOT NULL,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        category TEXT NOT NULL DEFAULT '',
        sort_order INTEGER NOT NULL DEFAULT 0,
        use_count INTEGER NOT NULL DEFAULT 0,
        last_used_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        content_hash TEXT NOT NULL
      );
    ''');
      legacy.execute(
        '''
      INSERT INTO items (
        id, type, title, content, is_favorite, category, sort_order,
        use_count, last_used_at, created_at, updated_at, content_hash
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
    ''',
        [
          'v2-item',
          'skill',
          '旧 Skill',
          '# Skill',
          0,
          '内容工作',
          0,
          0,
          null,
          '2026-07-20T08:00:00.000Z',
          '2026-07-20T08:00:00.000Z',
          JianheItem.calculateContentHash('# Skill'),
        ],
      );
      legacy.execute('PRAGMA user_version = 2;');
      legacy.close();

      final migrated = JianheStorageDatabase.open(path);
      addTearDown(() {
        migrated.close();
        directory.deleteSync(recursive: true);
      });

      expect(
        await migrated.items.listCategories(ItemType.skill),
        contains('内容工作'),
      );
      expect((await migrated.items.getById('v2-item'))?.rating, 0);
      expect(
        migrated.database.select('PRAGMA user_version;').first['user_version'],
        JianheStorageDatabase.schemaVersion,
      );
    },
  );

  test('migrates legacy favorites in schema v3 to five stars', () async {
    final directory = Directory.systemTemp.createTempSync('jianhe-v3-');
    final path = '${directory.path}${Platform.pathSeparator}jianhe.db';
    final legacy = sqlite3.open(path);
    legacy.execute('''
      CREATE TABLE items (
        id TEXT PRIMARY KEY NOT NULL,
        type TEXT NOT NULL,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        category TEXT NOT NULL DEFAULT '',
        sort_order INTEGER NOT NULL DEFAULT 0,
        use_count INTEGER NOT NULL DEFAULT 0,
        last_used_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        content_hash TEXT NOT NULL
      );
    ''');
    legacy.execute(
      '''
      INSERT INTO items (
        id, type, title, content, is_favorite, category, sort_order,
        use_count, last_used_at, created_at, updated_at, content_hash
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
    ''',
      [
        'favorite',
        'prompt',
        '旧收藏',
        '内容',
        1,
        '',
        0,
        0,
        null,
        '2026-07-20T08:00:00.000Z',
        '2026-07-20T08:00:00.000Z',
        JianheItem.calculateContentHash('内容'),
      ],
    );
    legacy.execute('PRAGMA user_version = 3;');
    legacy.close();

    final migrated = JianheStorageDatabase.open(path);
    final item = await migrated.items.getById('favorite');
    migrated.close();
    directory.deleteSync(recursive: true);

    expect(item?.rating, 5);
    expect(item?.isFavorite, isTrue);
  });

  test('migrates schema v4 by adding complete Skill package tables', () async {
    final directory = Directory.systemTemp.createTempSync('jianhe-v4-');
    final path = '${directory.path}${Platform.pathSeparator}jianhe.db';
    final legacy = sqlite3.open(path);
    legacy.execute('''
      CREATE TABLE items (
        id TEXT PRIMARY KEY NOT NULL,
        type TEXT NOT NULL,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        rating INTEGER NOT NULL DEFAULT 0,
        category TEXT NOT NULL DEFAULT '',
        sort_order INTEGER NOT NULL DEFAULT 0,
        use_count INTEGER NOT NULL DEFAULT 0,
        last_used_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        content_hash TEXT NOT NULL
      );
    ''');
    legacy.execute('PRAGMA user_version = 4;');
    legacy.close();

    final migrated = JianheStorageDatabase.open(path);
    final tables = migrated.database
        .select(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name IN ('skill_packages', 'skill_files');",
        )
        .map((row) => row['name'])
        .toSet();
    final version = migrated.database
        .select('PRAGMA user_version;')
        .first['user_version'];
    migrated.close();
    directory.deleteSync(recursive: true);

    expect(version, JianheStorageDatabase.schemaVersion);
    expect(tables, containsAll(<String>['skill_packages', 'skill_files']));
  });

  test('creates app_settings for upgraded and damaged v5 databases', () async {
    final directory = Directory.systemTemp.createTempSync('jianhe-settings-');
    final path = '${directory.path}${Platform.pathSeparator}jianhe.db';
    final legacy = sqlite3.open(path);
    legacy.execute('''
      CREATE TABLE items (
        id TEXT PRIMARY KEY NOT NULL,
        type TEXT NOT NULL,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        rating INTEGER NOT NULL DEFAULT 0,
        category TEXT NOT NULL DEFAULT '',
        sort_order INTEGER NOT NULL DEFAULT 0,
        use_count INTEGER NOT NULL DEFAULT 0,
        last_used_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        content_hash TEXT NOT NULL
      );
    ''');
    legacy.execute('PRAGMA user_version = 4;');
    legacy.close();

    var migrated = JianheStorageDatabase.open(path);
    migrated.settings.write('ball_dock_edge', 'left');
    expect(migrated.settings.read('ball_dock_edge'), 'left');
    migrated.close();

    // Databases upgraded by older builds kept user_version = 5 without the
    // app_settings table, so the repair must not depend on migrating again.
    final damaged = sqlite3.open(path);
    damaged.execute('DROP TABLE app_settings;');
    damaged.close();

    migrated = JianheStorageDatabase.open(path);
    expect(migrated.settings.read('ball_dock_edge'), isNull);
    migrated.settings.write('ball_dock_edge', 'right');
    expect(migrated.settings.read('ball_dock_edge'), 'right');
    final version = migrated.database
        .select('PRAGMA user_version;')
        .first['user_version'];
    migrated.close();
    directory.deleteSync(recursive: true);

    expect(version, JianheStorageDatabase.schemaVersion);
  });

  group('repairs databases whose structure disagrees with user_version', () {
    late Directory directory;
    late String path;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('jianhe-repair-');
      path = '${directory.path}${Platform.pathSeparator}jianhe.db';
    });

    tearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    int userVersion(JianheStorageDatabase storage) =>
        storage.database.select('PRAGMA user_version;').first['user_version']
            as int;

    test('v1 that already has category and sort_order', () async {
      final legacy = sqlite3.open(path);
      legacy.execute('''
        CREATE TABLE items (
          id TEXT PRIMARY KEY NOT NULL,
          type TEXT NOT NULL,
          title TEXT NOT NULL,
          content TEXT NOT NULL,
          is_favorite INTEGER NOT NULL DEFAULT 0,
          category TEXT NOT NULL DEFAULT '',
          sort_order INTEGER NOT NULL DEFAULT 0,
          use_count INTEGER NOT NULL DEFAULT 0,
          last_used_at TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          content_hash TEXT NOT NULL
        );
      ''');
      legacy.execute(
        '''
        INSERT INTO items (
          id, type, title, content, is_favorite, category, sort_order,
          created_at, updated_at, content_hash
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''',
        [
          'v1-debug',
          'prompt',
          '调试版素材',
          '内容',
          1,
          '调试分类',
          3,
          '2026-07-20T08:00:00.000Z',
          '2026-07-20T08:00:00.000Z',
          JianheItem.calculateContentHash('内容'),
        ],
      );
      legacy.execute('PRAGMA user_version = 1;');
      legacy.close();

      final migrated = JianheStorageDatabase.open(path);
      addTearDown(migrated.close);

      expect(userVersion(migrated), JianheStorageDatabase.schemaVersion);
      final item = await migrated.items.getById('v1-debug');
      expect(item?.category, '调试分类');
      expect(item?.sortOrder, 3);
      expect(item?.rating, 5);
      expect(
        await migrated.items.listCategories(ItemType.prompt),
        contains('调试分类'),
      );
    });

    test('v3 that already has rating keeps the user ratings', () async {
      final legacy = sqlite3.open(path);
      legacy.execute('''
        CREATE TABLE items (
          id TEXT PRIMARY KEY NOT NULL,
          type TEXT NOT NULL,
          title TEXT NOT NULL,
          content TEXT NOT NULL,
          is_favorite INTEGER NOT NULL DEFAULT 0,
          rating INTEGER NOT NULL DEFAULT 0,
          category TEXT NOT NULL DEFAULT '',
          sort_order INTEGER NOT NULL DEFAULT 0,
          use_count INTEGER NOT NULL DEFAULT 0,
          last_used_at TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          content_hash TEXT NOT NULL
        );
      ''');
      legacy.execute(
        '''
        INSERT INTO items (
          id, type, title, content, is_favorite, rating,
          created_at, updated_at, content_hash
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''',
        [
          'rated',
          'prompt',
          '已评分',
          '内容',
          1,
          3,
          '2026-07-20T08:00:00.000Z',
          '2026-07-20T08:00:00.000Z',
          JianheItem.calculateContentHash('内容'),
        ],
      );
      legacy.execute('PRAGMA user_version = 3;');
      legacy.close();

      final migrated = JianheStorageDatabase.open(path);
      addTearDown(migrated.close);

      expect(userVersion(migrated), JianheStorageDatabase.schemaVersion);
      expect((await migrated.items.getById('rated'))?.rating, 3);
    });

    test('unversioned items table with type but missing later columns', () async {
      final legacy = sqlite3.open(path);
      legacy.execute('''
        CREATE TABLE items (
          id TEXT PRIMARY KEY NOT NULL,
          type TEXT NOT NULL,
          title TEXT NOT NULL,
          content TEXT NOT NULL,
          is_favorite INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''');
      legacy.execute(
        'INSERT INTO items (id, type, title, content, is_favorite, '
        'created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?);',
        [
          'v0-typed',
          'snippet',
          '早期片段',
          '早期内容',
          1,
          '2026-07-20T08:00:00.000Z',
          '2026-07-20T08:00:00.000Z',
        ],
      );
      legacy.close();

      final migrated = JianheStorageDatabase.open(path);
      addTearDown(migrated.close);

      expect(userVersion(migrated), JianheStorageDatabase.schemaVersion);
      final item = await migrated.items.getById('v0-typed');
      expect(item?.title, '早期片段');
      expect(item?.rating, 5);
      expect(item?.category, '');
      expect(item?.lastUsedAt, isNull);
      expect(item?.contentHash, JianheItem.calculateContentHash('早期内容'));
      await migrated.items.markUsed('v0-typed');
      expect((await migrated.items.getById('v0-typed'))?.useCount, 1);
    });

    test('v7 databases missing columns and tables are completed', () async {
      final legacy = sqlite3.open(path);
      legacy.execute('''
        CREATE TABLE items (
          id TEXT PRIMARY KEY NOT NULL,
          type TEXT NOT NULL,
          title TEXT NOT NULL,
          content TEXT NOT NULL,
          is_favorite INTEGER NOT NULL DEFAULT 0,
          category TEXT NOT NULL DEFAULT '',
          sort_order INTEGER NOT NULL DEFAULT 0,
          use_count INTEGER NOT NULL DEFAULT 0,
          last_used_at TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          content_hash TEXT NOT NULL
        );
      ''');
      legacy.execute('PRAGMA user_version = 7;');
      legacy.close();

      var migrated = JianheStorageDatabase.open(path);
      final created = JianheItem.create(
        id: 'after-repair',
        type: ItemType.prompt,
        title: '修复后',
        content: '可以保存',
        rating: 4,
      );
      await migrated.items.save(created);
      migrated.settings.write('ball_dock_edge', 'left');
      migrated.close();

      // A second open is a no-op on a complete database.
      migrated = JianheStorageDatabase.open(path);
      addTearDown(migrated.close);
      expect(userVersion(migrated), JianheStorageDatabase.schemaVersion);
      expect((await migrated.items.getById('after-repair'))?.rating, 4);
      expect(migrated.settings.read('ball_dock_edge'), 'left');
      final tables = migrated.database
          .select("SELECT name FROM sqlite_master WHERE type = 'table';")
          .map((row) => row['name'] as String)
          .toSet();
      expect(
        tables,
        containsAll(<String>[
          'item_categories',
          'skill_packages',
          'skill_files',
          'pending_changes',
          'sync_state',
          'app_settings',
        ]),
      );
    });

    test('legacy v0 without folders, deleted_at or content_hash', () async {
      final legacy = sqlite3.open(path);
      legacy.execute('''
        CREATE TABLE items (
          id TEXT NOT NULL PRIMARY KEY,
          entity_type TEXT NOT NULL,
          title TEXT NOT NULL,
          content TEXT NOT NULL,
          is_favorite INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        );
      ''');
      legacy.execute(
        'INSERT INTO items (id, entity_type, title, content, is_favorite, '
        'created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?);',
        ['bare-legacy', 'text', '最早的文本', '最早的内容', 0,
          1784534400000, 1784534400000],
      );
      legacy.close();

      final migrated = JianheStorageDatabase.open(path);
      addTearDown(migrated.close);

      expect(userVersion(migrated), JianheStorageDatabase.schemaVersion);
      final item = await migrated.items.getById('bare-legacy');
      expect(item?.type, ItemType.snippet);
      expect(item?.category, '');
      expect(item?.rating, 0);
      expect(item?.contentHash, JianheItem.calculateContentHash('最早的内容'));
      expect(
        item?.createdAt,
        DateTime.fromMillisecondsSinceEpoch(1784534400000, isUtc: true),
      );
    });

    test('a failing legacy migration is backed up only once', () {
      final legacy = sqlite3.open(path);
      // No title column: the copy cannot succeed, so every open retries.
      legacy.execute('''
        CREATE TABLE items (
          id TEXT NOT NULL PRIMARY KEY,
          entity_type TEXT NOT NULL,
          content TEXT NOT NULL
        );
      ''');
      legacy.execute(
        "INSERT INTO items (id, entity_type, content) VALUES ('x', 'prompt', 'c');",
      );
      legacy.close();

      expect(() => JianheStorageDatabase.open(path), throwsA(anything));
      // Give the first backup an older name so a duplicate taken by a later
      // attempt cannot hide by overwriting it within the same second.
      final first = directory.listSync().whereType<File>().singleWhere(
        (file) => file.path.endsWith('.bak'),
      );
      first.renameSync('$path.legacy-v0-20000101-000000.bak');
      for (var attempt = 0; attempt < 2; attempt++) {
        expect(() => JianheStorageDatabase.open(path), throwsA(anything));
      }

      final backups = directory.listSync().whereType<File>().where(
        (file) => file.path.endsWith('.bak'),
      );
      expect(backups, hasLength(1));
      // The rollback left the original data in place.
      final check = sqlite3.open(path);
      final content = check
          .select("SELECT content FROM items WHERE id = 'x';")
          .first['content'];
      check.close();
      expect(content, 'c');
    });
  });

  test('skill reads skip legacy entrypoint file rows', () async {
    final skillItem = JianheItem.create(
      id: 'skill-1',
      type: ItemType.skill,
      title: '示例 Skill',
      content: '入口内容',
    );
    await storage.skills.replaceSkill(skillItem, _packageWithAuxFiles());

    storage.database.execute(
      '''
      INSERT INTO skill_files (
        skill_id, relative_path, media_type, byte_length, content_hash, content
      ) VALUES (?, 'SKILL.md', NULL, 12, 'legacy-dirty-hash', ?);
    ''',
      [
        'skill-1',
        Uint8List.fromList(utf8.encode('入口内容重复')),
      ],
    );

    final read = await storage.skills.getBySkillId('skill-1');
    expect(read?.files.map((file) => file.relativePath), ['notes.md']);

    final all = await storage.skills.listAll();
    expect(all, hasLength(1));
    expect(all.single.files.map((file) => file.relativePath), ['notes.md']);
  });

  test('migration v6 purges legacy entrypoint file rows', () async {
    final directory = Directory.systemTemp.createTempSync('jianhe-v6-');
    final path = '${directory.path}${Platform.pathSeparator}jianhe.db';
    final storage = JianheStorageDatabase.open(path);
    final skillItem = JianheItem.create(
      id: 'skill-1',
      type: ItemType.skill,
      title: '示例 Skill',
      content: '入口内容',
    );
    await storage.skills.replaceSkill(skillItem, _packageWithAuxFiles());
    storage.database.execute(
      '''
      INSERT INTO skill_files (
        skill_id, relative_path, media_type, byte_length, content_hash, content
      ) VALUES (?, 'skill.md', NULL, 12, 'legacy-dirty-hash', ?);
    ''',
      [
        'skill-1',
        Uint8List.fromList(utf8.encode('入口内容重复')),
      ],
    );
    storage.database.execute('PRAGMA user_version = 5;');
    storage.close();

    final migrated = JianheStorageDatabase.open(path);
    addTearDown(() {
      migrated.close();
      directory.deleteSync(recursive: true);
    });

    final remaining = migrated.database
        .select(
          "SELECT skill_id FROM skill_files "
          "WHERE relative_path = 'SKILL.md' COLLATE NOCASE;",
        )
        .map((row) => row['skill_id'])
        .toSet();
    expect(remaining, isEmpty);
    expect(
      migrated.database.select('PRAGMA user_version;').first['user_version'],
      JianheStorageDatabase.schemaVersion,
    );

    final read = await migrated.skills.getBySkillId('skill-1');
    expect(read?.files.map((file) => file.relativePath), ['notes.md']);
  });

  test('v6 databases gain the sync capture tables', () async {
    final directory = Directory.systemTemp.createTempSync('jianhe-v7-');
    final path = '${directory.path}${Platform.pathSeparator}jianhe.db';
    final first = JianheStorageDatabase.open(path);
    first.close();
    final raw = sqlite3.open(path);
    raw.execute('DROP TABLE pending_changes;');
    raw.execute('DROP TABLE sync_state;');
    raw.execute('PRAGMA user_version = 6;');
    raw.close();

    final migrated = JianheStorageDatabase.open(path);
    addTearDown(() {
      migrated.close();
      directory.deleteSync(recursive: true);
    });

    expect(
      migrated.database.select('PRAGMA user_version;').first['user_version'],
      JianheStorageDatabase.schemaVersion,
    );
    migrated.sync.writeState('pull_cursor:account-1', '42');
    expect(migrated.sync.readState('pull_cursor:account-1'), '42');
    expect(migrated.sync.pendingCount(), 0);
  });

  group('markUsed and setRating write only their own columns', () {
    JianheItem promptItem({
      required String title,
      required String content,
      required DateTime now,
    }) => JianheItem.create(
      id: 'race-item',
      type: ItemType.prompt,
      title: title,
      content: content,
      now: now,
    );

    void clearPending() {
      for (final row in storage.sync.readPendingChanges()) {
        storage.sync.deletePendingChanges(
          row.entityType,
          row.entityId,
          upToSeq: row.seq,
        );
      }
    }

    test('markUsed issued while a pull transaction is open keeps the '
        'content that transaction writes', () async {
      // A copy during a sync pull used to read the item before the pull
      // applied the newer remote version, then save that stale copy back
      // after the pull committed: content and updated_at went back, and
      // the stale state was journaled for a push the server would drop.
      await storage.items.save(
        promptItem(
          title: '旧标题',
          content: '旧内容',
          now: DateTime.utc(2026, 9, 1),
        ),
      );
      clearPending();
      final remote = promptItem(
        title: '新标题',
        content: '新内容',
        now: DateTime.utc(2026, 9, 2),
      );

      final gate = Completer<void>();
      final pull = storage.writeTransaction(() async {
        await gate.future;
        storage.sync.upsertRemoteItem(remote);
      }, recordChanges: false);
      final used = storage.items.markUsed(
        'race-item',
        now: DateTime.utc(2026, 9, 3),
      );
      gate.complete();
      await pull;
      final returned = await used;

      final stored = await storage.items.getById('race-item');
      for (final item in <JianheItem?>[returned, stored]) {
        expect(item?.title, '新标题');
        expect(item?.content, '新内容');
        expect(item?.updatedAt, remote.updatedAt);
        expect(item?.useCount, 1);
        expect(item?.lastUsedAt, DateTime.utc(2026, 9, 3));
      }
      expect(storage.sync.pendingCount(), 0);
    });

    test('concurrent markUsed calls each count', () async {
      await storage.items.save(
        promptItem(title: '标题', content: '内容', now: DateTime.utc(2026, 9, 1)),
      );
      await Future.wait(<Future<JianheItem?>>[
        storage.items.markUsed('race-item'),
        storage.items.markUsed('race-item'),
        storage.items.markUsed('race-item'),
      ]);
      expect((await storage.items.getById('race-item'))?.useCount, 3);
    });

    test('markUsed and setRating return null for a missing item and do '
        'not create it', () async {
      expect(await storage.items.markUsed('missing'), isNull);
      expect(await storage.items.setRating('missing', 4), isNull);
      expect(await storage.items.getById('missing'), isNull);
      expect(storage.sync.pendingCount(), 0);
    });

    test('setRating issued while a pull transaction is open keeps the '
        'content that transaction writes', () async {
      await storage.items.save(
        promptItem(
          title: '旧标题',
          content: '旧内容',
          now: DateTime.utc(2026, 9, 1),
        ),
      );
      clearPending();
      final remote = promptItem(
        title: '新标题',
        content: '新内容',
        now: DateTime.utc(2026, 9, 2),
      );

      final gate = Completer<void>();
      final pull = storage.writeTransaction(() async {
        await gate.future;
        storage.sync.upsertRemoteItem(remote);
      }, recordChanges: false);
      final rated = storage.items.setRating(
        'race-item',
        4,
        now: DateTime.utc(2026, 9, 3),
      );
      gate.complete();
      await pull;
      final returned = await rated;

      final stored = await storage.items.getById('race-item');
      for (final item in <JianheItem?>[returned, stored]) {
        expect(item?.title, '新标题');
        expect(item?.content, '新内容');
        expect(item?.rating, 4);
        expect(item?.isFavorite, isTrue);
        expect(item?.updatedAt, DateTime.utc(2026, 9, 3));
      }
      final pending = storage.sync.readPendingChanges();
      expect(pending, hasLength(1));
      expect(pending.single.entityType, SyncEntityType.itemPrompt);
      expect(pending.single.op, SyncChangeOp.put);
    });

    test('setRating stamps after the stored version even when that is '
        'ahead of the local clock', () async {
      final ahead = DateTime.utc(2026, 9, 10, 8, 2);
      await storage.items.save(
        promptItem(title: '标题', content: '内容', now: ahead),
      );
      final rated = await storage.items.setRating(
        'race-item',
        0,
        now: DateTime.utc(2026, 9, 10, 8),
      );
      expect(rated?.updatedAt, ahead.add(const Duration(milliseconds: 1)));
      expect(rated?.rating, 0);
      expect(rated?.isFavorite, isFalse);
    });

    test('setRating rejects ratings outside 0-5', () async {
      await storage.items.save(
        promptItem(title: '标题', content: '内容', now: DateTime.utc(2026, 9, 1)),
      );
      await expectLater(
        storage.items.setRating('race-item', 6),
        throwsA(isA<RangeError>()),
      );
      expect((await storage.items.getById('race-item'))?.rating, 0);
    });

    test('rating a Skill keeps its package and journals only the item',
        () async {
      final skill = JianheItem.create(
        id: 'rated-skill',
        type: ItemType.skill,
        title: '技能',
        content: '# 入口',
        now: DateTime.utc(2026, 9, 1),
      );
      await storage.skills.replaceSkill(
        skill,
        SkillPackage(
          skillId: skill.id,
          sourceFormat: SkillSourceFormat.directory,
          importedAt: DateTime.utc(2026, 9, 1),
          files: <SkillFile>[
            SkillFile(
              relativePath: 'notes.md',
              content: Uint8List.fromList(utf8.encode('附件')),
            ),
          ],
        ),
      );
      clearPending();
      final hashBefore = storage.sync.readPackageHash(skill.id);

      await storage.items.markUsed(skill.id);
      expect(storage.sync.pendingCount(), 0);
      await storage.items.setRating(skill.id, 5);

      expect(storage.sync.readPackageHash(skill.id), hashBefore);
      expect(
        (await storage.skills.getBySkillId(skill.id))?.files.single.content,
        utf8.encode('附件'),
      );
      final pending = storage.sync.readPendingChanges();
      expect(pending, hasLength(1));
      expect(pending.single.entityType, SyncEntityType.itemSkill);
    });
  });

  group('setSortOrders writes only the order', () {
    JianheItem prompt(String id, {int sortOrder = 0, DateTime? now}) =>
        JianheItem.create(
          id: id,
          type: ItemType.prompt,
          title: '标题 $id',
          content: '内容 $id',
          sortOrder: sortOrder,
          now: now ?? DateTime.utc(2026, 9, 1),
        );

    void clearPending() {
      for (final row in storage.sync.readPendingChanges()) {
        storage.sync.deletePendingChanges(
          row.entityType,
          row.entityId,
          upToSeq: row.seq,
        );
      }
    }

    test('a reorder issued while a pull transaction is open keeps the '
        'content that transaction writes', () async {
      await storage.items.save(prompt('race-item'));
      clearPending();
      final remote = JianheItem.create(
        id: 'race-item',
        type: ItemType.prompt,
        title: '新标题',
        content: '新内容',
        now: DateTime.utc(2026, 9, 2),
      );

      final gate = Completer<void>();
      final pull = storage.writeTransaction(() async {
        await gate.future;
        storage.sync.upsertRemoteItem(remote);
      }, recordChanges: false);
      final reordered = storage.items.setSortOrders(
        ItemType.prompt,
        <String, int>{'race-item': 3},
        now: DateTime.utc(2026, 9, 3),
      );
      gate.complete();
      await pull;
      final returned = await reordered;

      final stored = await storage.items.getById('race-item');
      for (final item in <JianheItem?>[returned.single, stored]) {
        expect(item?.title, '新标题');
        expect(item?.content, '新内容');
        expect(item?.sortOrder, 3);
        expect(item?.updatedAt, DateTime.utc(2026, 9, 3));
      }
      expect(storage.sync.pendingCount(), 1);
    });

    test('only items whose order changes are written and journaled',
        () async {
      await storage.items.save(prompt('keep', sortOrder: 0));
      await storage.items.save(prompt('move', sortOrder: 1));
      clearPending();

      final changed = await storage.items.setSortOrders(
        ItemType.prompt,
        <String, int>{'keep': 0, 'move': 5},
        now: DateTime.utc(2026, 9, 3),
      );

      expect(changed.map((item) => item.id), <String>['move']);
      expect(changed.single.sortOrder, 5);
      expect(
        (await storage.items.getById('keep'))?.updatedAt,
        DateTime.utc(2026, 9, 1),
      );
      final pending = storage.sync.readPendingChanges();
      expect(pending.map((row) => row.entityId), <String>['move']);
    });

    test('missing ids and items of another type are skipped', () async {
      await storage.items.save(
        JianheItem.create(
          id: 'a-snippet',
          type: ItemType.snippet,
          title: '片段',
          content: '内容',
        ),
      );
      clearPending();
      final changed = await storage.items.setSortOrders(
        ItemType.prompt,
        <String, int>{'a-snippet': 4, 'missing': 2},
      );
      expect(changed, isEmpty);
      expect((await storage.items.getById('a-snippet'))?.sortOrder, 0);
      expect(await storage.items.getById('missing'), isNull);
      expect(storage.sync.pendingCount(), 0);
    });

    test('stamps after the stored version even when that is ahead of the '
        'local clock', () async {
      final ahead = DateTime.utc(2026, 9, 10, 8, 2);
      await storage.items.save(prompt('ahead', now: ahead));
      final changed = await storage.items.setSortOrders(
        ItemType.prompt,
        <String, int>{'ahead': 7},
        now: DateTime.utc(2026, 9, 10, 8),
      );
      expect(
        changed.single.updatedAt,
        ahead.add(const Duration(milliseconds: 1)),
      );
    });

    test('rejects negative orders without writing anything', () async {
      await storage.items.save(prompt('item', sortOrder: 2));
      clearPending();
      await expectLater(
        storage.items.setSortOrders(ItemType.prompt, <String, int>{
          'item': -1,
        }),
        throwsA(isA<ArgumentError>()),
      );
      expect((await storage.items.getById('item'))?.sortOrder, 2);
      expect(storage.sync.pendingCount(), 0);
    });
  });

  test('save journals an item put once per state change', () async {
    final item = JianheItem.create(
      id: 'journal-save',
      type: ItemType.prompt,
      title: '记账',
      content: '内容',
    );
    await storage.items.save(item);
    expect(storage.sync.pendingCount(), 1);

    // markUsed only bumps device-local fields and must not journal.
    await storage.items.markUsed(item.id, now: DateTime.utc(2026, 9, 10));
    expect(storage.sync.pendingCount(), 1);

    await storage.items.save(
      item.copyWith(updatedAt: DateTime.utc(2026, 9, 10, 12)),
    );
    expect(storage.sync.pendingCount(), 2);
  });

  test('delete journals tombstones, linking the skill package', () async {
    final prompt = JianheItem.create(
      id: 'journal-prompt',
      type: ItemType.prompt,
      title: '普通',
      content: '内容',
    );
    await storage.items.save(prompt);
    await storage.items.delete(prompt.id);
    expect(
      storage.sync
          .readPendingChanges()
          .where((row) => row.op == SyncChangeOp.delete),
      hasLength(1),
    );

    final skill = JianheItem.create(
      id: 'journal-skill',
      type: ItemType.skill,
      title: '技能',
      content: '# 入口',
    );
    await storage.skills.replaceSkill(
      skill,
      SkillPackage(
        skillId: skill.id,
        sourceFormat: SkillSourceFormat.markdown,
        importedAt: DateTime.utc(2026, 9, 9),
      ),
    );
    await storage.items.delete(skill.id);
    final deletes = storage.sync
        .readPendingChanges()
        .where(
          (row) =>
              row.entityId == skill.id && row.op == SyncChangeOp.delete,
        )
        .map((row) => row.entityType)
        .toSet();
    expect(
      deletes,
      <SyncEntityType>{SyncEntityType.itemSkill, SyncEntityType.skillPackage},
    );

    // Deleting a missing entity changes nothing and journals nothing.
    await storage.items.delete('missing-id');
    final count = storage.sync.pendingCount();
    await storage.items.delete('missing-id');
    expect(storage.sync.pendingCount(), count);
  });

  test('a skill demoted to another entity journals the package loss',
      () async {
    final skill = JianheItem.create(
      id: 'demote-skill',
      type: ItemType.skill,
      title: '技能',
      content: '# 入口',
    );
    await storage.skills.replaceSkill(
      skill,
      SkillPackage(
        skillId: skill.id,
        sourceFormat: SkillSourceFormat.markdown,
        importedAt: DateTime.utc(2026, 9, 9),
      ),
    );
    final before = storage.sync.pendingCount();

    await storage.items.save(
      skill.copyWith(
        type: ItemType.snippet,
        updatedAt: DateTime.utc(2026, 9, 10),
      ),
    );

    final tombstones = storage.sync
        .readPendingChanges()
        .skip(before)
        .where((row) => row.op == SyncChangeOp.delete)
        .map((row) => row.entityType)
        .toSet();
    expect(
      tombstones,
      <SyncEntityType>{SyncEntityType.skillPackage, SyncEntityType.itemSkill},
    );
  });

  test('a type change retires the old-type item entity before the new put',
      () async {
    final prompt = JianheItem.create(
      id: 'retype-item',
      type: ItemType.prompt,
      title: '换类型',
      content: '内容',
    );
    await storage.items.save(prompt);
    final before = storage.sync.pendingCount();

    final changedAt = DateTime.utc(2026, 9, 11, 8);
    await storage.items.save(
      prompt.copyWith(type: ItemType.snippet, updatedAt: changedAt),
    );

    final added = storage.sync
        .readPendingChanges()
        .skip(before)
        .where((row) => row.entityId == prompt.id)
        .toList();
    expect(
      added.map((row) => (row.entityType, row.op)).toList(),
      <(SyncEntityType, SyncChangeOp)>[
        (SyncEntityType.itemPrompt, SyncChangeOp.delete),
        (SyncEntityType.itemSnippet, SyncChangeOp.put),
      ],
    );
    expect(added.first.changedAt.toUtc(), changedAt);
    expect(added.first.seq, lessThan(added.last.seq));

    // Saving again under the same type journals no further tombstone.
    final count = storage.sync.pendingCount();
    await storage.items.save(
      (await storage.items.getById(prompt.id))!.copyWith(
        title: '只改标题',
        updatedAt: DateTime.utc(2026, 9, 11, 9),
      ),
    );
    final later = storage.sync.readPendingChanges().skip(count).toList();
    expect(later.where((row) => row.op == SyncChangeOp.delete), isEmpty);
  });

  test('deleteCategory journals item puts and the category tombstone',
      () async {
    final first = JianheItem.create(
      id: 'cat-a',
      type: ItemType.prompt,
      title: '甲',
      content: 'a',
      category: '工作',
      // A fixed past stamp: on Windows the wall clock can return the same
      // microsecond for create and deleteCategory, hiding the bump.
      now: DateTime.utc(2026, 9, 1),
    );
    final second = JianheItem.create(
      id: 'cat-b',
      type: ItemType.prompt,
      title: '乙',
      content: 'b',
      category: '工作',
      // A fixed past stamp: on Windows the wall clock can return the same
      // microsecond for create and deleteCategory, hiding the bump.
      now: DateTime.utc(2026, 9, 1),
    );
    await storage.items.save(first);
    await storage.items.save(second);
    final before = storage.sync.pendingCount();

    await storage.items.deleteCategory(ItemType.prompt, '工作');

    expect(storage.sync.pendingCount(), before + 3);
    final added = storage.sync.readPendingChanges().skip(before).toList();
    expect(
      added
          .where((row) => row.entityType == SyncEntityType.itemPrompt)
          .map((row) => row.entityId)
          .toSet(),
      <String>{first.id, second.id},
    );
    expect(
      added
          .where((row) => row.entityType == SyncEntityType.categoryPrompt)
          .map((row) => row.op),
      [SyncChangeOp.delete],
    );
    expect((await storage.items.getById(first.id))!.updatedAt,
        isNot(first.updatedAt));
  });

  test('renameCategory journals create-new, delete-old and item puts',
      () async {
    final item = JianheItem.create(
      id: 'rename-item',
      type: ItemType.snippet,
      title: '片段',
      content: 'c',
      category: '旧分类',
    );
    await storage.items.save(item);
    final before = storage.sync.pendingCount();

    await storage.items.renameCategory(
      ItemType.snippet,
      '旧分类',
      '新分类',
    );

    final added = storage.sync.readPendingChanges().skip(before).toList();
    expect(
      added
          .where((row) => row.entityType == SyncEntityType.categorySnippet)
          .map((row) => '${row.entityId}:${row.op.storageValue}')
          .toSet(),
      <String>{'新分类:put', '旧分类:delete'},
    );
    expect(
      added
          .where((row) => row.entityType == SyncEntityType.itemSnippet)
          .map((row) => row.entityId),
      [item.id],
    );
  });

  test('category capture journals only real insertions', () async {
    await storage.items.createCategory(ItemType.prompt, '新建');
    expect(storage.sync.pendingCount(), 1);
    await storage.items.createCategory(ItemType.prompt, '新建');
    expect(storage.sync.pendingCount(), 1);
  });

  test('repeated saves of one entity inside a transaction collapse',
      () async {
    final item = JianheItem.create(
      id: 'dedup-item',
      type: ItemType.prompt,
      title: '去重',
      content: '第一版',
    );
    await storage.writeTransaction(() async {
      await storage.items.save(item);
      await storage.items.save(
        item.copyWith(updatedAt: DateTime.utc(2026, 9, 10, 8)),
      );
    });
    expect(storage.sync.pendingCount(), 1);
  });

  test('a nested rollback frees the journal slot for re-recording',
      () async {
    final item = JianheItem.create(
      id: 'savepoint-item',
      type: ItemType.prompt,
      title: '保存点',
      content: 'v1',
    );
    await storage.items.save(item);
    final before = storage.sync.pendingCount();

    await storage.writeTransaction(() async {
      await expectLater(
        storage.writeTransaction(() async {
          await storage.items.save(
            item.copyWith(updatedAt: DateTime.utc(2027, 1, 1)),
          );
          throw StateError('nested stop');
        }),
        throwsStateError,
      );
      await storage.items.save(
        item.copyWith(updatedAt: DateTime.utc(2028, 1, 1)),
      );
    });

    expect(storage.sync.pendingCount(), before + 1);
  });

  test('replay transactions capture no journal rows', () async {
    final item = JianheItem.create(
      id: 'remote-item',
      type: ItemType.prompt,
      title: '远端',
      content: '远端内容',
    );
    await storage.writeTransaction(() async {
      await storage.items.save(item);
    }, recordChanges: false);
    expect(storage.sync.pendingCount(), 0);
    expect(await storage.items.getById(item.id), isNotNull);
  });

  test('sync store reads pending rows and acks up to a seq', () async {
    final first = JianheItem.create(
      id: 'store-a',
      type: ItemType.prompt,
      title: '甲',
      content: 'a',
    );
    final second = JianheItem.create(
      id: 'store-b',
      type: ItemType.snippet,
      title: '乙',
      content: 'b',
    );
    await storage.items.save(first);
    await storage.items.save(second);

    final pending = storage.sync.readPendingChanges();
    expect(pending, hasLength(2));
    expect(pending.first.seq, lessThan(pending.last.seq));
    expect(pending.first.entityType, SyncEntityType.itemPrompt);
    expect(pending.last.entityType, SyncEntityType.itemSnippet);
    expect(storage.sync.readItemUpdatedAt(first.id), isNotNull);

    storage.sync.deletePendingChanges(
      SyncEntityType.itemPrompt,
      first.id,
      upToSeq: pending.first.seq,
    );
    final remaining = storage.sync.readPendingChanges();
    expect(remaining.map((row) => row.entityId), ['store-b']);

    storage.sync.writeState('device_id', 'device-1');
    expect(storage.sync.readState('device_id'), 'device-1');
    storage.sync.deleteState('device_id');
    expect(storage.sync.readState('device_id'), isNull);
  });

  test('sync store enumerates survivors and clears covered pending rows',
      () async {
    final item = JianheItem.create(
      id: 'store-a',
      type: ItemType.prompt,
      title: '甲',
      content: 'a',
      category: '工作',
    );
    await storage.items.save(item);
    await storage.items.createCategory(ItemType.prompt, '工作');
    final skill = JianheItem.create(
      id: 'skill-1',
      type: ItemType.skill,
      title: '技能',
      content: '简介',
    );
    await storage.skills.replaceSkill(
      skill,
      _packageWithAuxFiles(),
    );

    expect(storage.sync.readAllItemIds(), ['skill-1', 'store-a']);
    expect(storage.sync.readAllCategoryKeys(), [(ItemType.prompt, '工作')]);
    expect(storage.sync.readAllSkillIds(), ['skill-1']);
    expect(storage.sync.maxPendingSeq(), greaterThan(0));

    storage.sync.deletePendingChangesForEntities(
      const [
        (entityType: SyncEntityType.itemPrompt, entityId: 'store-a'),
        (entityType: SyncEntityType.categoryPrompt, entityId: '工作'),
      ],
      upToSeq: storage.sync.maxPendingSeq(),
    );
    // The skill rows (item + package) survive the cleanup untouched.
    final remaining = storage.sync.readPendingChanges();
    expect(remaining.map((row) => row.entityId), everyElement('skill-1'));
    expect(remaining, hasLength(2));
  });

  test('sync schedule settings use typed defaults and persist both modes', () {
    expect(storage.settings.autoSyncScheduleMode, 'interval');
    expect(storage.settings.autoSyncIntervalMinutes, 15);
    expect(storage.settings.autoSyncDailyTime, (hour: 21, minute: 0));

    storage.settings.setAutoSyncSchedule(
      mode: 'interval',
      intervalMinutes: 30,
    );
    expect(storage.settings.autoSyncScheduleMode, 'interval');
    expect(storage.settings.autoSyncIntervalMinutes, 30);

    storage.settings.setAutoSyncSchedule(
      mode: 'daily',
      dailyHour: 8,
      dailyMinute: 45,
    );
    expect(storage.settings.autoSyncScheduleMode, 'daily');
    expect(storage.settings.autoSyncDailyTime, (hour: 8, minute: 45));
  });
}

SkillPackage _packageWithAuxFiles() {
  return SkillPackage(
    skillId: 'skill-1',
    sourceFormat: SkillSourceFormat.directory,
    importedAt: DateTime.utc(2026, 9, 9),
    files: [
      SkillFile(
        relativePath: 'notes.md',
        content: Uint8List.fromList(utf8.encode('辅助文件内容')),
      ),
    ],
  );
}
