import 'dart:convert';
import 'dart:typed_data';

import 'package:jianhe_core/jianhe_core.dart';
import 'package:test/test.dart';

void main() {
  test('normalizes portable relative paths and rejects traversal', () {
    expect(
      SkillPackage.normalizeRelativePath(r'references\guide.md'),
      'references/guide.md',
    );
    expect(
      () => SkillPackage.normalizeRelativePath('../secret.txt'),
      throwsFormatException,
    );
    expect(
      () => SkillPackage.normalizeRelativePath(r'C:\secret.txt'),
      throwsFormatException,
    );
    expect(
      () => SkillPackage.normalizeRelativePath('assets/NUL.txt'),
      throwsFormatException,
    );
  });

  test('sync blob estimate covers the encoded blob and flags oversized packages',
      () {
    const manifest = '# 技能\n\n"引号" 与换行\n';
    final package = SkillPackage(
      skillId: 'skill-1',
      sourceFormat: SkillSourceFormat.zip,
      importedAt: DateTime.utc(2026, 9, 10, 8),
      files: <SkillFile>[
        SkillFile(
          relativePath: 'assets/图标.bin',
          content: Uint8List.fromList(List<int>.generate(1001, (i) => i % 256)),
          mediaType: 'application/octet-stream',
        ),
        SkillFile(
          relativePath: 'notes.md',
          content: Uint8List.fromList(utf8.encode('说明')),
        ),
      ],
    );
    // The same JSON shape the desktop sync encoder uploads.
    final encoded = utf8.encode(
      jsonEncode(<String, Object?>{
        'entrypoint': package.entrypoint,
        'source_format': package.sourceFormat.storageValue,
        'manifest': manifest,
        'imported_at': package.importedAt.toUtc().toIso8601String(),
        'files': <Object?>[
          for (final file in package.files)
            <String, Object?>{
              'relative_path': file.relativePath,
              if (file.mediaType != null) 'media_type': file.mediaType,
              'content_base64': base64Encode(file.content),
            },
        ],
      }),
    );
    final estimate = package.syncBlobBytes(manifest);
    expect(estimate, greaterThanOrEqualTo(encoded.length));
    expect(estimate - encoded.length, lessThan(512));
    expect(package.exceedsSyncBlobLimit(manifest), isFalse);

    // Within the 50 MiB import limit, but base64 pushes it past 64 MiB.
    final large = SkillPackage(
      skillId: 'skill-2',
      sourceFormat: SkillSourceFormat.zip,
      importedAt: DateTime.utc(2026, 9, 10, 8),
      files: <SkillFile>[
        for (var i = 0; i < 5; i++)
          SkillFile(
            relativePath: 'assets/part-$i.bin',
            content: Uint8List(SkillPackage.maximumFileBytes - 1024),
          ),
      ],
    );
    expect(large.totalBytes(manifest), lessThan(SkillPackage.maximumExpandedBytes));
    expect(large.exceedsSyncBlobLimit(manifest), isTrue);
  });

  test('package hash is stable regardless of auxiliary file ordering', () {
    SkillFile file(String path, String content) => SkillFile(
      relativePath: path,
      content: Uint8List.fromList(utf8.encode(content)),
    );
    final first = SkillPackage(
      skillId: 'skill-1',
      sourceFormat: SkillSourceFormat.directory,
      importedAt: DateTime.utc(2026, 8, 21),
      files: <SkillFile>[file('b.txt', 'B'), file('a.txt', 'A')],
    );
    final second = SkillPackage(
      skillId: 'skill-2',
      sourceFormat: SkillSourceFormat.zip,
      importedAt: DateTime.utc(2026, 8, 22),
      files: <SkillFile>[file('a.txt', 'A'), file('b.txt', 'B')],
    );

    expect(first.packageHash('# Skill'), second.packageHash('# Skill'));
  });

  test('file metadata validates paths and lengths without loading content', () {
    final metadata = SkillFileMetadata(
      relativePath: r'references\guide.md',
      mediaType: 'text/markdown',
      byteLength: 42,
      contentHash: 'abc123',
    );

    expect(metadata.relativePath, 'references/guide.md');
    expect(metadata.byteLength, 42);
    expect(
      () => SkillFileMetadata(
        relativePath: 'assets/icon.bin',
        byteLength: -1,
        contentHash: 'abc123',
      ),
      throwsFormatException,
    );
  });

  test('rejects paths that collide on case-insensitive filesystems', () {
    expect(
      () => SkillPackage(
        skillId: 'skill-1',
        sourceFormat: SkillSourceFormat.zip,
        importedAt: DateTime.utc(2026, 8, 21),
        files: <SkillFile>[
          SkillFile(relativePath: 'assets/Icon.png', content: Uint8List(1)),
          SkillFile(relativePath: 'assets/icon.png', content: Uint8List(1)),
        ],
      ),
      throwsFormatException,
    );
  });
}
