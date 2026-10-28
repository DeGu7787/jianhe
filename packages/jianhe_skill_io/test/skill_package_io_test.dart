import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:jianhe_core/jianhe_core.dart';
import 'package:jianhe_skill_io/jianhe_skill_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  final io = const SkillPackageIo();

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('jianhe-skill-io-');
  });

  tearDown(() {
    temporary.deleteSync(recursive: true);
  });

  test('imports a directory package with frontmatter title', () async {
    Directory(p.join(temporary.path, 'pkg', 'assets')).createSync(
      recursive: true,
    );
    File(p.join(temporary.path, 'pkg', 'SKILL.md')).writeAsStringSync(
      '---\nname: Demo Skill\n---\n\nBody.',
    );
    File(
      p.join(temporary.path, 'pkg', 'assets', 'note.txt'),
    ).writeAsStringSync('hello');

    final imported = await io.importPath(p.join(temporary.path, 'pkg'));

    expect(imported.title, 'Demo Skill');
    expect(imported.sourceFormat, SkillSourceFormat.directory);
    expect(imported.files.single.relativePath, 'assets/note.txt');
    expect(imported.files.single.mediaType, 'text/plain');
  });

  test('imports a valid zip and strips a single wrapper directory', () async {
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          'pkg/SKILL.md',
          utf8.encode('# Wrapped\n\nContent.').length,
          utf8.encode('# Wrapped\n\nContent.'),
        ),
      )
      ..addFile(
        ArchiveFile(
          'pkg/scripts/run.py',
          utf8.encode('print("hi")').length,
          utf8.encode('print("hi")'),
        ),
      );
    final zipPath = p.join(temporary.path, 'wrapped.zip');
    File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive)!);

    final imported = await io.importPath(zipPath);

    expect(imported.sourceFormat, SkillSourceFormat.zip);
    expect(imported.entrypointContent, '# Wrapped\n\nContent.');
    expect(imported.files.single.relativePath, 'scripts/run.py');
  });

  test('rejects an entry whose declared size hides an inflated bomb',
      () async {
    // 11 MiB of zeros deflates to a few KB; the forged header then claims a
    // 1 KiB entry so the declared-size limits pass, while the real output
    // exceeds the per-file cap.
    final zeros = Uint8List(11 * 1024 * 1024);
    final archive = Archive()
      ..addFile(ArchiveFile('SKILL.md', zeros.length, zeros));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
    _patchUncompressedSize(bytes, 1024);
    final zipPath = p.join(temporary.path, 'bomb.zip');
    File(zipPath).writeAsBytesSync(bytes);

    await expectLater(
      io.importPath(zipPath),
      throwsA(
        isA<SkillPackageFormatException>().having(
          (error) => error.message,
          'message',
          'A Skill file is too large: SKILL.md',
        ),
      ),
    );
  });

  test('rejects an entry that declares an oversized uncompressed size',
      () async {
    final payload = utf8.encode('tiny');
    final zipPath = p.join(temporary.path, 'declared.zip');
    File(zipPath).writeAsBytesSync(
      _buildZip(
        name: 'SKILL.md',
        payload: payload,
        method: 0,
        crc: getCrc32(payload),
        declaredUncompressedSize: SkillPackage.maximumFileBytes + 1,
      ),
    );

    await expectLater(
      io.importPath(zipPath),
      throwsA(
        isA<SkillPackageFormatException>().having(
          (error) => error.message,
          'message',
          'A Skill file is too large: SKILL.md',
        ),
      ),
    );
  });

  test('rejects unix symlink entries before the decoder decompresses them',
      () async {
    final payload = utf8.encode('/etc/passwd');
    final zipPath = p.join(temporary.path, 'symlink.zip');
    File(zipPath).writeAsBytesSync(
      _buildZip(
        name: 'SKILL.md',
        payload: payload,
        method: 0,
        crc: getCrc32(payload),
        declaredUncompressedSize: payload.length,
        versionMadeBy: 0x0314,
        externalAttributes: 0xA1FF0000,
      ),
    );

    await expectLater(
      io.importPath(zipPath),
      throwsA(
        isA<SkillPackageFormatException>().having(
          (error) => error.message,
          'message',
          'Skill ZIP cannot contain symbolic links.',
        ),
      ),
    );
  });

  test('stored entries without unix attributes still import as files',
      () async {
    final entrypoint = utf8.encode('# Stored\n\nBody.');
    final extra = utf8.encode('stored bytes');
    final archive = Archive()
      ..addFile(
        ArchiveFile.noCompress('SKILL.md', entrypoint.length, entrypoint),
      )
      ..addFile(
        ArchiveFile.noCompress('data.bin', extra.length, extra),
      );
    final zipPath = p.join(temporary.path, 'stored.zip');
    File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive)!);

    final imported = await io.importPath(zipPath);

    expect(imported.entrypointContent, '# Stored\n\nBody.');
    expect(imported.files.single.relativePath, 'data.bin');
  });
}

/// Rewrites the uncompressed-size fields of every entry, as an attacker
/// would, to hide the real inflated size from the declared-size limits.
void _patchUncompressedSize(Uint8List bytes, int declaredSize) {
  final view = ByteData.sublistView(bytes);
  final eocd = bytes.length - 22;
  final entryCount = view.getUint16(eocd + 10, Endian.little);
  var offset = view.getUint32(eocd + 16, Endian.little);
  for (var index = 0; index < entryCount; index++) {
    final localOffset = view.getUint32(offset + 42, Endian.little);
    view.setUint32(localOffset + 22, declaredSize, Endian.little);
    view.setUint32(offset + 24, declaredSize, Endian.little);
    offset +=
        46 +
        view.getUint16(offset + 28, Endian.little) +
        view.getUint16(offset + 30, Endian.little) +
        view.getUint16(offset + 32, Endian.little);
  }
}

Uint8List _buildZip({
  required String name,
  required List<int> payload,
  required int method,
  required int crc,
  required int declaredUncompressedSize,
  int versionMadeBy = 20,
  int externalAttributes = 0,
}) {
  final nameBytes = utf8.encode(name);
  final local = BytesBuilder()
    ..add(<int>[0x50, 0x4B, 0x03, 0x04])
    ..add(_uint16(20))
    ..add(_uint16(0))
    ..add(_uint16(method))
    ..add(_uint16(0))
    ..add(_uint16(0))
    ..add(_uint32(crc))
    ..add(_uint32(payload.length))
    ..add(_uint32(declaredUncompressedSize))
    ..add(_uint16(nameBytes.length))
    ..add(_uint16(0))
    ..add(nameBytes)
    ..add(payload);

  final central = BytesBuilder()
    ..add(<int>[0x50, 0x4B, 0x01, 0x02])
    ..add(_uint16(versionMadeBy))
    ..add(_uint16(20))
    ..add(_uint16(0))
    ..add(_uint16(method))
    ..add(_uint16(0))
    ..add(_uint16(0))
    ..add(_uint32(crc))
    ..add(_uint32(payload.length))
    ..add(_uint32(declaredUncompressedSize))
    ..add(_uint16(nameBytes.length))
    ..add(_uint16(0))
    ..add(_uint16(0))
    ..add(_uint16(0))
    ..add(_uint16(0))
    ..add(_uint32(externalAttributes))
    ..add(_uint32(0))
    ..add(nameBytes);

  final eocd = BytesBuilder()
    ..add(<int>[0x50, 0x4B, 0x05, 0x06])
    ..add(_uint16(0))
    ..add(_uint16(0))
    ..add(_uint16(1))
    ..add(_uint16(1))
    ..add(_uint32(central.length))
    ..add(_uint32(local.length))
    ..add(_uint16(0));

  final output = BytesBuilder();
  output.add(local.toBytes());
  output.add(central.toBytes());
  output.add(eocd.toBytes());
  return output.toBytes();
}

Uint8List _uint16(int value) =>
    Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.little);

Uint8List _uint32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);
