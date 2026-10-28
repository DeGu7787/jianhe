import 'dart:convert';
import 'dart:typed_data';

import 'package:jianhe_core/jianhe_core.dart';
import 'package:test/test.dart';

void main() {
  test('round-trips every portable item field, category, and setting', () {
    final item =
        JianheItem.create(
          id: 'prompt-1',
          type: ItemType.prompt,
          title: '结构化总结',
          content: '总结：{{input}}',
          category: '内容写作',
          rating: 4,
          sortOrder: 3,
          now: DateTime.utc(2026, 7, 29, 8),
        ).copyWith(
          useCount: 7,
          lastUsedAt: DateTime.utc(2026, 7, 29, 9),
          updatedAt: DateTime.utc(2026, 7, 29, 10),
        );
    final backup = JianheBackup(
      exportedAt: DateTime.utc(2026, 7, 29, 11),
      items: <JianheItem>[item],
      categories: <ItemType, List<String>>{
        ItemType.prompt: <String>['内容写作', '空分类'],
        ItemType.skill: <String>['开发'],
        ItemType.snippet: const <String>[],
      },
      settings: const <String, Object?>{
        'auto_collapse_seconds': 15,
        'cli_access_mode': 'read_write',
      },
    );

    final restored = JianheBackup.decode(backup.encode());
    final restoredItem = restored.items.single;

    expect(restoredItem.id, item.id);
    expect(restoredItem.content, item.content);
    expect(restoredItem.category, item.category);
    expect(restoredItem.rating, 4);
    expect(restoredItem.sortOrder, 3);
    expect(restoredItem.useCount, 7);
    expect(restored.categories[ItemType.prompt], contains('空分类'));
    expect(restored.settings['auto_collapse_seconds'], 15);
  });

  test('content fingerprint ignores exported_at but not the data', () {
    JianheItem item(String title) => JianheItem.create(
      type: ItemType.prompt,
      title: title,
      content: 'c',
      id: title,
      now: DateTime.utc(2026, 9, 3),
    );

    final first = JianheBackup(
      exportedAt: DateTime.utc(2026, 9, 3),
      items: <JianheItem>[item('item-1')],
      categories: const <ItemType, List<String>>{},
    );
    final resnapped = JianheBackup(
      exportedAt: DateTime.utc(2026, 9, 3, 0, 0, 1),
      items: <JianheItem>[item('item-1')],
      categories: const <ItemType, List<String>>{},
    );
    final changed = JianheBackup(
      exportedAt: DateTime.utc(2026, 9, 3),
      items: <JianheItem>[item('item-2')],
      categories: const <ItemType, List<String>>{},
    );

    expect(resnapped.contentFingerprint(), first.contentFingerprint());
    expect(changed.contentFingerprint(), isNot(first.contentFingerprint()));
    // The full encoding still differs so stored snapshots stay distinct.
    expect(resnapped.encode(), isNot(first.encode()));
  });

  test('merge keeps the newer copy and reports created and skipped items', () {
    JianheItem item(String id, int hour, String content) {
      return JianheItem.create(
        id: id,
        type: ItemType.skill,
        title: id,
        content: content,
        now: DateTime.utc(2026, 7, 29, hour),
      );
    }

    final localNewer = item('local-newer', 12, '本机较新');
    final importedNewer = item('imported-newer', 13, '备份较新');
    final backup = JianheBackup(
      exportedAt: DateTime.utc(2026, 7, 29, 14),
      items: <JianheItem>[
        item('local-newer', 11, '备份较旧'),
        importedNewer,
        item('brand-new', 10, '新增'),
      ],
      categories: const <ItemType, List<String>>{},
    );

    final result = backup.mergeItems(<JianheItem>[
      localNewer,
      item('imported-newer', 9, '本机较旧'),
    ]);

    expect(result.created.map((item) => item.id), contains('brand-new'));
    expect(result.updated.map((item) => item.id), contains('imported-newer'));
    expect(result.skipped, 1);
    expect(
      result.items.singleWhere((item) => item.id == 'local-newer').content,
      '本机较新',
    );
    expect(
      result.items.singleWhere((item) => item.id == 'imported-newer').content,
      '备份较新',
    );
  });

  test('merge keeps local usage statistics when imported content wins', () {
    JianheItem item(
      String id, {
      required int hour,
      required String content,
      required int useCount,
      required DateTime lastUsedAt,
    }) {
      return JianheItem.create(
        id: id,
        type: ItemType.prompt,
        title: id,
        content: content,
        now: DateTime.utc(2026, 7, 29, hour),
      ).copyWith(
        useCount: useCount,
        lastUsedAt: lastUsedAt,
        updatedAt: DateTime.utc(2026, 7, 29, hour),
      );
    }

    final backup = JianheBackup(
      exportedAt: DateTime.utc(2026, 7, 30, 12),
      items: <JianheItem>[
        item(
          'local-stats',
          hour: 10,
          content: '备份新内容',
          useCount: 3,
          lastUsedAt: DateTime.utc(2026, 7, 28, 8),
        ),
        item(
          'shared-stats',
          hour: 10,
          content: '备份新内容',
          useCount: 9,
          lastUsedAt: DateTime.utc(2026, 7, 27, 8),
        ),
      ],
      categories: const <ItemType, List<String>>{},
    );

    final result = backup.mergeItems(<JianheItem>[
      item(
        'local-stats',
        hour: 9,
        content: '本机旧内容',
        useCount: 12,
        lastUsedAt: DateTime.utc(2026, 7, 30, 8),
      ),
      item(
        'shared-stats',
        hour: 9,
        content: '本机旧内容',
        useCount: 4,
        lastUsedAt: DateTime.utc(2026, 7, 26, 8),
      ),
    ]);

    expect(
      result.updated.map((item) => item.id),
      containsAll(<String>['local-stats', 'shared-stats']),
    );

    final localStats = result.items.singleWhere(
      (item) => item.id == 'local-stats',
    );
    expect(localStats.content, '备份新内容');
    expect(localStats.useCount, 12);
    expect(localStats.lastUsedAt, DateTime.utc(2026, 7, 30, 8));
    expect(localStats.updatedAt, DateTime.utc(2026, 7, 29, 10));

    final sharedStats = result.items.singleWhere(
      (item) => item.id == 'shared-stats',
    );
    expect(sharedStats.content, '备份新内容');
    expect(sharedStats.useCount, 9);
    expect(sharedStats.lastUsedAt, DateTime.utc(2026, 7, 27, 8));
  });

  test('rejects files that are not Jianhe backups', () {
    expect(
      () => JianheBackup.decode('{"format":"other","version":1,"data":{}}'),
      throwsFormatException,
    );
  });

  test('filters empty categories and rejects invalid category names', () {
    String backupWithCategories(List<String> categories) =>
        jsonEncode(<String, Object?>{
          'format': JianheBackup.formatName,
          'version': JianheBackup.formatVersion,
          'exported_at': '2026-09-14T08:00:00.000Z',
          'data': <String, Object?>{
            'items': <Object?>[],
            'categories': <String, Object?>{'prompt': categories},
            'skill_packages': <Object?>[],
            'settings': <String, Object?>{},
          },
        });

    final decoded = JianheBackup.decode(
      backupWithCategories(<String>['', '  ', '工作']),
    );
    expect(decoded.categories[ItemType.prompt], <String>['工作']);
    expect(
      () => JianheBackup.decode(backupWithCategories(<String>['工作\n复盘'])),
      throwsFormatException,
    );
  });

  test('round-trips complete Skill packages with binary files', () {
    final skill = JianheItem.create(
      id: 'skill-1',
      type: ItemType.skill,
      title: '完整 Skill',
      content: '---\nname: 完整 Skill\n---\n# Instructions',
      now: DateTime.utc(2026, 8, 21, 8),
    );
    final package = SkillPackage(
      skillId: skill.id,
      sourceFormat: SkillSourceFormat.zip,
      importedAt: DateTime.utc(2026, 8, 21, 9),
      files: <SkillFile>[
        SkillFile(
          relativePath: 'references/guide.md',
          content: Uint8List.fromList(utf8.encode('# Guide')),
          mediaType: 'text/markdown',
        ),
        SkillFile(
          relativePath: 'assets/icon.png',
          content: Uint8List.fromList(<int>[0, 1, 2, 255]),
          mediaType: 'image/png',
        ),
      ],
    );
    final backup = JianheBackup(
      exportedAt: DateTime.utc(2026, 8, 21, 10),
      items: <JianheItem>[skill],
      categories: const <ItemType, List<String>>{},
      skillPackages: <SkillPackage>[package],
    );

    final restored = JianheBackup.decode(backup.encode());
    final restoredPackage = restored.packageForSkill(skill.id)!;

    expect(restoredPackage.sourceFormat, SkillSourceFormat.zip);
    expect(restoredPackage.files, hasLength(2));
    expect(
      restoredPackage.files
          .singleWhere((file) => file.relativePath == 'assets/icon.png')
          .content,
      <int>[0, 1, 2, 255],
    );
  });

  test('continues to decode version 1 backups as single-file Skills', () {
    final legacy = jsonEncode(<String, Object?>{
      'format': JianheBackup.formatName,
      'version': 1,
      'exported_at': '2026-08-21T10:00:00.000Z',
      'data': <String, Object?>{
        'items': <Object?>[
          JianheItem.create(
            id: 'legacy-skill',
            type: ItemType.skill,
            title: '旧 Skill',
            content: '# Legacy',
            now: DateTime.utc(2026, 8, 21, 9),
          ).toJson(),
        ],
        'categories': <String, Object?>{},
        'settings': <String, Object?>{},
      },
    });

    final restored = JianheBackup.decode(legacy);

    expect(restored.items.single.id, 'legacy-skill');
    expect(restored.skillPackages, isEmpty);
  });
}
