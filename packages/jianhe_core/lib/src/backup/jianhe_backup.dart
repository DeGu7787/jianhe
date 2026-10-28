import 'dart:convert';
import 'dart:typed_data';

import '../items/item_type.dart';
import '../items/jianhe_item.dart';
import '../skills/skill_package.dart';

class JianheBackup {
  const JianheBackup({
    required this.exportedAt,
    required this.items,
    required this.categories,
    this.skillPackages = const <SkillPackage>[],
    this.settings = const <String, Object?>{},
  });

  static const formatName = 'jianhe-offline-backup';
  static const formatVersion = 2;

  final DateTime exportedAt;
  final List<JianheItem> items;
  final Map<ItemType, List<String>> categories;
  final List<SkillPackage> skillPackages;
  final Map<String, Object?> settings;

  SkillPackage? packageForSkill(String skillId) {
    for (final package in skillPackages) {
      if (package.skillId == skillId) return package;
    }
    return null;
  }

  static DateTime? _laterOf(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  JianheBackupMergeResult mergeItems(List<JianheItem> localItems) {
    final merged = List<JianheItem>.from(localItems);
    // id -> position in [merged]; the linear indexWhere per imported item
    // made merging a few thousand items quadratic on the UI isolate.
    final indexById = <String, int>{
      for (var i = 0; i < merged.length; i++) merged[i].id: i,
    };
    final created = <JianheItem>[];
    final updated = <JianheItem>[];
    var skipped = 0;
    for (final imported in items) {
      final index = indexById[imported.id] ?? -1;
      if (index < 0) {
        indexById[imported.id] = merged.length;
        merged.add(imported);
        created.add(imported);
      } else if (imported.updatedAt.isAfter(merged[index].updatedAt)) {
        // Imported content wins, but the usage counters are local runtime
        // state: a wholesale replacement would reset them to whatever the
        // exporting device last saw.
        final local = merged[index];
        merged[index] = imported.copyWith(
          useCount:
              imported.useCount > local.useCount
                  ? imported.useCount
                  : local.useCount,
          lastUsedAt: _laterOf(local.lastUsedAt, imported.lastUsedAt),
          updatedAt: imported.updatedAt,
        );
        updated.add(merged[index]);
      } else {
        skipped++;
      }
    }
    return JianheBackupMergeResult(
      items: merged,
      created: created,
      updated: updated,
      skipped: skipped,
    );
  }

  String encode() {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(<String, Object?>{
      'format': formatName,
      'version': formatVersion,
      'exported_at': exportedAt.toUtc().toIso8601String(),
      'data': _dataJson(),
    });
  }

  /// Stable identity of the backup contents, independent of when the
  /// snapshot happened to be taken. The cloud upload retry cache compares
  /// this to decide whether a new attempt can replay the failed one,
  /// because [encode] alone always differs: every fresh snapshot carries a
  /// new [exportedAt].
  String contentFingerprint() {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(<String, Object?>{
      'format': formatName,
      'version': formatVersion,
      'data': _dataJson(),
    });
  }

  Map<String, Object?> _dataJson() {
    return <String, Object?>{
      'items': items.map((item) => item.toJson()).toList(growable: false),
      'categories': <String, Object?>{
        for (final type in ItemType.values)
          type.name: categories[type] ?? const <String>[],
      },
      'skill_packages': skillPackages
          .map(_packageToJson)
          .toList(growable: false),
      'settings': settings,
    };
  }

  factory JianheBackup.decode(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Backup root must be a JSON object.');
    }
    final root = Map<String, Object?>.from(decoded);
    final version = root['version'];
    if (root['format'] != formatName ||
        version is! int ||
        (version != 1 && version != formatVersion)) {
      throw const FormatException('Unsupported Jianhe backup format.');
    }
    final rawData = root['data'];
    if (rawData is! Map) {
      throw const FormatException('Backup data is missing.');
    }
    final data = Map<String, Object?>.from(rawData);
    final rawItems = data['items'];
    if (rawItems is! List) {
      throw const FormatException('Backup items are missing.');
    }
    final rawCategories = data['categories'];
    final categoryMap = rawCategories is Map
        ? Map<String, Object?>.from(rawCategories)
        : const <String, Object?>{};
    final rawSettings = data['settings'];

    final items = rawItems
        .map(
          (value) =>
              JianheItem.fromJson(Map<String, Object?>.from(value as Map)),
        )
        .toList(growable: false);
    final packages = version == 1
        ? const <SkillPackage>[]
        : _decodePackages(data['skill_packages'], items);

    return JianheBackup(
      exportedAt: DateTime.parse(root['exported_at'] as String).toUtc(),
      items: items,
      categories: <ItemType, List<String>>{
        for (final type in ItemType.values)
          type: _stringList(categoryMap[type.name]),
      },
      skillPackages: packages,
      settings: rawSettings is Map
          ? Map<String, Object?>.from(rawSettings)
          : const <String, Object?>{},
    );
  }

  static Map<String, Object?> _packageToJson(SkillPackage package) {
    return <String, Object?>{
      'skill_id': package.skillId,
      'entrypoint': package.entrypoint,
      'source_format': package.sourceFormat.storageValue,
      'imported_at': package.importedAt.toUtc().toIso8601String(),
      'files': package.files
          .map(
            (file) => <String, Object?>{
              'path': file.relativePath,
              'media_type': file.mediaType,
              'byte_length': file.byteLength,
              'sha256': file.contentHash,
              'content_base64': base64Encode(file.content),
            },
          )
          .toList(growable: false),
    };
  }

  static List<SkillPackage> _decodePackages(
    Object? value,
    List<JianheItem> items,
  ) {
    if (value == null) return const <SkillPackage>[];
    if (value is! List) {
      throw const FormatException('Backup Skill packages are invalid.');
    }
    final skillIds = items
        .where((item) => item.type == ItemType.skill)
        .map((item) => item.id)
        .toSet();
    final seenIds = <String>{};
    final packages = <SkillPackage>[];
    for (final rawPackage in value) {
      if (rawPackage is! Map) {
        throw const FormatException('A backup Skill package is invalid.');
      }
      final package = Map<String, Object?>.from(rawPackage);
      final skillId = package['skill_id'] as String? ?? '';
      if (!skillIds.contains(skillId) || !seenIds.add(skillId)) {
        throw const FormatException(
          'A backup Skill package does not match a unique Skill.',
        );
      }
      final rawFiles = package['files'];
      if (rawFiles is! List) {
        throw const FormatException('Backup Skill files are missing.');
      }
      final files = <SkillFile>[];
      for (final rawFile in rawFiles) {
        if (rawFile is! Map) {
          throw const FormatException('A backup Skill file is invalid.');
        }
        final file = Map<String, Object?>.from(rawFile);
        final encoded = file['content_base64'];
        if (encoded is! String) {
          throw const FormatException('Backup Skill file content is missing.');
        }
        late final Uint8List bytes;
        try {
          bytes = base64Decode(encoded);
        } on FormatException {
          throw const FormatException('Backup Skill file content is invalid.');
        }
        final expectedLength = (file['byte_length'] as num?)?.toInt();
        if (expectedLength == null || expectedLength != bytes.length) {
          throw const FormatException(
            'A backup Skill file failed its size check.',
          );
        }
        files.add(
          SkillFile(
            relativePath: file['path'] as String? ?? '',
            content: bytes,
            mediaType: file['media_type'] as String?,
            contentHash: file['sha256'] as String?,
          ),
        );
      }
      packages.add(
        SkillPackage(
          skillId: skillId,
          entrypoint: package['entrypoint'] as String? ?? '',
          sourceFormat: SkillSourceFormat.fromStorage(
            package['source_format'] as String? ?? '',
          ),
          importedAt: DateTime.parse(package['imported_at'] as String).toUtc(),
          files: files,
        ),
      );
    }
    return List<SkillPackage>.unmodifiable(packages);
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) return const <String>[];
    final categories = value
        .whereType<String>()
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (categories.any((name) => !JianheItem.isValidCategoryName(name))) {
      throw const FormatException('A backup category name is invalid.');
    }
    return categories;
  }
}

class JianheBackupMergeResult {
  const JianheBackupMergeResult({
    required this.items,
    required this.created,
    required this.updated,
    required this.skipped,
  });

  final List<JianheItem> items;
  final List<JianheItem> created;
  final List<JianheItem> updated;
  final int skipped;
}
