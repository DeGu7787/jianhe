import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:jianhe_core/jianhe_core.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

export 'imported_skill_package.dart';
import 'imported_skill_package.dart';

class SkillPackageIo {
  const SkillPackageIo();

  Future<ImportedSkillPackage> importPath(String sourcePath) async {
    final normalizedPath = p.normalize(p.absolute(sourcePath));
    final type = await FileSystemEntity.type(
      normalizedPath,
      followLinks: false,
    );
    return switch (type) {
      FileSystemEntityType.directory => _importDirectory(
        Directory(normalizedPath),
      ),
      FileSystemEntityType.file => _importFile(File(normalizedPath)),
      FileSystemEntityType.link => throw const SkillPackageFormatException(
        'Symbolic links cannot be imported as Skill packages.',
      ),
      _ => throw SkillPackageFormatException(
        'Skill package path does not exist: $sourcePath',
      ),
    };
  }

  Future<void> exportDirectory({
    required JianheItem skill,
    required SkillPackage? package,
    required String outputPath,
    bool force = false,
  }) async {
    final directory = Directory(p.normalize(p.absolute(outputPath)));
    final entityType = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (entityType == FileSystemEntityType.link ||
        entityType == FileSystemEntityType.file) {
      throw SkillPackageFormatException(
        'Output path is not a safe directory: ${directory.path}',
      );
    }
    if (await directory.exists()) {
      final hasEntries =
          (await directory.list(followLinks: false).take(1).toList())
              .isNotEmpty;
      if (hasEntries && !force) {
        throw const SkillPackageFormatException(
          'Output directory is not empty. Use --force to overwrite files.',
        );
      }
    } else {
      await directory.create(recursive: true);
    }

    for (final entry in _packageFiles(skill, package).entries) {
      final relativePath = SkillPackage.normalizeRelativePath(entry.key);
      final destination = File(
        p.joinAll(<String>[directory.path, ...relativePath.split('/')]),
      );
      final absoluteDestination = p.normalize(p.absolute(destination.path));
      if (!p.isWithin(directory.path, absoluteDestination)) {
        throw const SkillPackageFormatException(
          'A Skill file would escape the output directory.',
        );
      }
      await _rejectOutputLinks(directory.path, destination.path);
      if (await destination.exists() && !force) {
        throw SkillPackageFormatException(
          'Output file already exists: $relativePath',
        );
      }
      await destination.parent.create(recursive: true);
      await destination.writeAsBytes(entry.value, flush: true);
    }
  }

  /// Validates a single-file output target and returns it normalized.
  ///
  /// Refuses a symbolic link (including a dangling one, which
  /// `File.exists` reports as absent while a write would still follow it),
  /// an existing directory, and an existing file unless [force] is set.
  /// Only the target itself is checked, not its parent directories: on
  /// Windows a user's own folders are often links (OneDrive-managed
  /// Documents, junctions), and refusing those would break ordinary paths.
  Future<File> prepareOutputFile(
    String outputPath, {
    required bool force,
  }) async {
    final output = File(p.normalize(p.absolute(outputPath)));
    final type = await FileSystemEntity.type(output.path, followLinks: false);
    switch (type) {
      case FileSystemEntityType.link:
        throw const SkillPackageFormatException(
          'Output file cannot be a symbolic link.',
        );
      case FileSystemEntityType.directory:
        throw SkillPackageFormatException(
          'Output path is a directory: ${output.path}',
        );
      case FileSystemEntityType.file when !force:
        throw const SkillPackageFormatException(
          'Output file already exists. Use --force to overwrite it.',
        );
      default:
        return output;
    }
  }

  Future<void> exportZip({
    required JianheItem skill,
    required SkillPackage? package,
    required String outputPath,
    bool force = false,
  }) async {
    final output = await prepareOutputFile(outputPath, force: force);
    final archive = Archive();
    for (final entry in _packageFiles(skill, package).entries) {
      archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    final encoded = ZipEncoder().encode(archive);
    if (encoded == null) {
      throw const SkillPackageFormatException(
        'The Skill ZIP could not be created.',
      );
    }
    await output.parent.create(recursive: true);
    // Write next to the target and rename, so an interrupted export never
    // leaves a truncated ZIP under the name the user chose.
    final temporary = File(
      '${output.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsBytes(encoded, flush: true);
      await temporary.rename(output.path);
    } on Object {
      try {
        if (temporary.existsSync()) temporary.deleteSync();
      } on FileSystemException {
        // Best effort only; the original error matters more.
      }
      rethrow;
    }
  }

  static final _unsafeFileNameCharacters = RegExp(r'[\\/:*?"<>|\x00-\x1F]');
  static final _reservedWindowsNames = RegExp(
    r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])$',
    caseSensitive: false,
  );

  /// Default file name for exporting [title] as a ZIP, safe on Windows:
  /// reserved characters become `_`, trailing dots and spaces are dropped,
  /// reserved device names are prefixed, and the name is length-limited.
  static String suggestedZipFileName(String title) {
    var name = title
        .replaceAll(_unsafeFileNameCharacters, '_')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (name.isEmpty) name = 'skill';
    if (_reservedWindowsNames.hasMatch(name.split('.').first)) {
      name = '_$name';
    }
    if (name.length > 120) name = name.substring(0, 120).trimRight();
    return '$name.zip';
  }

  Future<ImportedSkillPackage> _importFile(File file) async {
    final extension = p.extension(file.path).toLowerCase();
    if (extension == '.zip') return _importZip(file);
    if (extension != '.md') {
      throw const SkillPackageFormatException(
        'A Skill file must be Markdown (.md) or ZIP (.zip).',
      );
    }
    final length = await file.length();
    if (length > SkillPackage.maximumFileBytes) {
      throw const SkillPackageFormatException('SKILL.md is too large.');
    }
    final content = _decodeEntrypoint(await file.readAsBytes());
    return ImportedSkillPackage(
      title: _skillTitle(content, p.basenameWithoutExtension(file.path)),
      entrypointContent: content,
      sourceFormat: SkillSourceFormat.markdown,
      files: const <SkillFile>[],
    );
  }

  Future<ImportedSkillPackage> _importDirectory(Directory directory) async {
    final entries = <String, Uint8List>{};
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const SkillPackageFormatException(
          'Skill packages cannot contain symbolic links.',
        );
      }
      if (type != FileSystemEntityType.file) continue;
      final relativePath = SkillPackage.normalizeRelativePath(
        p.relative(entity.path, from: directory.path),
      );
      final file = File(entity.path);
      final length = await file.length();
      _checkFileLimits(relativePath, length, entries);
      entries[relativePath] = await file.readAsBytes();
    }
    return _buildImported(
      entries,
      sourceFormat: SkillSourceFormat.directory,
      fallbackTitle: p.basename(directory.path),
    );
  }

  Future<ImportedSkillPackage> _importZip(File file) async {
    if (await file.length() > SkillPackage.maximumArchiveBytes) {
      throw const SkillPackageFormatException('Skill ZIP is too large.');
    }
    final bytes = await file.readAsBytes();
    // The decoder decompresses Unix symlink targets while parsing, so links
    // must be rejected before decoding.
    _rejectZipSymlinkEntries(bytes);
    late final Archive archive;
    try {
      // verify: true would decompress every entry up front; the extraction
      // below bounds the actual output instead.
      archive = ZipDecoder().decodeBytes(bytes, verify: false);
    } on Object {
      throw const SkillPackageFormatException(
        'Skill ZIP is invalid or corrupted.',
      );
    }
    if (archive.length > SkillPackage.maximumFileCount) {
      throw const SkillPackageFormatException(
        'A Skill package contains too many entries.',
      );
    }

    final rawEntries = <String, Uint8List>{};
    var extractedBytes = 0;
    for (final archived in archive.files) {
      if (archived.isSymbolicLink) {
        throw const SkillPackageFormatException(
          'Skill ZIP cannot contain symbolic links.',
        );
      }
      if (!archived.isFile) continue;
      final relativePath = SkillPackage.normalizeRelativePath(archived.name);
      _checkFileLimits(relativePath, archived.size, rawEntries);
      if (rawEntries.keys.any(
        (path) => path.toLowerCase() == relativePath.toLowerCase(),
      )) {
        throw SkillPackageFormatException(
          'Skill ZIP contains duplicate file paths: $relativePath',
        );
      }
      final content = _extractZipEntry(archived, relativePath);
      rawEntries[relativePath] = content;
      extractedBytes += content.length;
      if (extractedBytes > SkillPackage.maximumExpandedBytes) {
        throw const SkillPackageFormatException(
          'The expanded Skill package is too large.',
        );
      }
    }

    final entries = _stripSingleWrapperDirectory(rawEntries);
    return _buildImported(
      entries,
      sourceFormat: SkillSourceFormat.zip,
      fallbackTitle: p.basenameWithoutExtension(file.path),
    );
  }

  /// Decompresses one entry while counting the actual output bytes, so a
  /// forged size header cannot expand a small archive into memory.  The
  /// decoder's own lazy path (`ArchiveFile.content`) decompresses without a
  /// cap, so the raw compressed slice is inflated here instead.
  Uint8List _extractZipEntry(ArchiveFile archived, String relativePath) {
    final raw = archived.rawContent;
    if (raw == null) {
      throw const SkillPackageFormatException(
        'Skill ZIP is invalid or corrupted.',
      );
    }
    final output = _BoundedOutputStream(SkillPackage.maximumFileBytes);
    try {
      if (archived.compressionType == ArchiveFile.DEFLATE) {
        Inflate.stream(raw, output);
      } else {
        output.writeInputStream(raw);
      }
    } on _ZipEntryTooLarge {
      throw SkillPackageFormatException(
        'A Skill file is too large: $relativePath',
      );
    } on Object {
      throw const SkillPackageFormatException(
        'Skill ZIP is invalid or corrupted.',
      );
    }
    final bytes = output.takeBytes();
    final expectedCrc = archived.crc32;
    if (expectedCrc != null &&
        expectedCrc != 0 &&
        getCrc32(bytes) != expectedCrc) {
      throw const SkillPackageFormatException(
        'Skill ZIP is invalid or corrupted.',
      );
    }
    return bytes;
  }

  /// Scans the central directory for Unix symlink entries, which the decoder
  /// would otherwise decompress before the per-entry checks can reject them.
  /// Malformed structures are left for the decoder to report.
  void _rejectZipSymlinkEntries(Uint8List bytes) {
    final directory = ByteData.sublistView(bytes);
    final scanStart = bytes.length - 22 - 65535;
    var eocd = -1;
    for (var i = bytes.length - 22; i >= (scanStart < 0 ? 0 : scanStart); i--) {
      if (bytes[i] == 0x50 &&
          bytes[i + 1] == 0x4B &&
          bytes[i + 2] == 0x05 &&
          bytes[i + 3] == 0x06) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) return;
    final entryCount = directory.getUint16(eocd + 10, Endian.little);
    var offset = directory.getUint32(eocd + 16, Endian.little);
    for (var index = 0; index < entryCount; index++) {
      if (offset < 0 ||
          offset + 46 > bytes.length ||
          bytes[offset] != 0x50 ||
          bytes[offset + 1] != 0x4B ||
          bytes[offset + 2] != 0x01 ||
          bytes[offset + 3] != 0x02) {
        return;
      }
      final versionMadeBy = directory.getUint16(offset + 4, Endian.little);
      final externalAttributes = directory.getUint32(offset + 38, Endian.little);
      final posixMode = (externalAttributes >> 16) & 0xF000;
      if ((versionMadeBy >> 8) == 3 && posixMode == 0xA000) {
        throw const SkillPackageFormatException(
          'Skill ZIP cannot contain symbolic links.',
        );
      }
      offset +=
          46 +
          directory.getUint16(offset + 28, Endian.little) +
          directory.getUint16(offset + 30, Endian.little) +
          directory.getUint16(offset + 32, Endian.little);
    }
  }

  ImportedSkillPackage _buildImported(
    Map<String, Uint8List> entries, {
    required SkillSourceFormat sourceFormat,
    required String fallbackTitle,
  }) {
    _validateEntrySet(entries);
    final entrypointBytes = entries[SkillPackage.defaultEntrypoint];
    if (entrypointBytes == null) {
      throw const SkillPackageFormatException(
        'A Skill package must contain SKILL.md at its root.',
      );
    }
    final entrypointContent = _decodeEntrypoint(entrypointBytes);
    final files = <SkillFile>[
      for (final entry in entries.entries)
        if (entry.key != SkillPackage.defaultEntrypoint)
          SkillFile(
            relativePath: entry.key,
            content: entry.value,
            mediaType: _mediaType(entry.key),
          ),
    ]..sort((left, right) => left.relativePath.compareTo(right.relativePath));
    return ImportedSkillPackage(
      title: _skillTitle(entrypointContent, fallbackTitle),
      entrypointContent: entrypointContent,
      sourceFormat: sourceFormat,
      files: List<SkillFile>.unmodifiable(files),
    );
  }

  Map<String, Uint8List> _stripSingleWrapperDirectory(
    Map<String, Uint8List> entries,
  ) {
    final candidates = entries.keys
        .where(
          (path) =>
              path == SkillPackage.defaultEntrypoint ||
              path.endsWith('/${SkillPackage.defaultEntrypoint}'),
        )
        .toList();
    if (candidates.isEmpty) return entries;
    candidates.sort(
      (left, right) =>
          left.split('/').length.compareTo(right.split('/').length),
    );
    final depth = candidates.first.split('/').length;
    final shallowest = candidates
        .where((candidate) => candidate.split('/').length == depth)
        .toList();
    if (shallowest.length != 1) {
      throw const SkillPackageFormatException(
        'Skill ZIP contains more than one package root.',
      );
    }
    final entrypoint = shallowest.single;
    if (entrypoint == SkillPackage.defaultEntrypoint) return entries;
    final prefix = entrypoint.substring(
      0,
      entrypoint.length - SkillPackage.defaultEntrypoint.length,
    );
    if (entries.keys.any((path) => !path.startsWith(prefix))) {
      throw const SkillPackageFormatException(
        'Skill ZIP contains files outside its package root.',
      );
    }
    return <String, Uint8List>{
      for (final entry in entries.entries)
        entry.key.substring(prefix.length): entry.value,
    };
  }

  void _checkFileLimits(
    String relativePath,
    int byteLength,
    Map<String, Uint8List> existing,
  ) {
    if (byteLength > SkillPackage.maximumFileBytes) {
      throw SkillPackageFormatException(
        'A Skill file is too large: $relativePath',
      );
    }
    if (existing.length + 1 > SkillPackage.maximumFileCount) {
      throw const SkillPackageFormatException(
        'A Skill package contains too many files.',
      );
    }
    final expandedBytes =
        existing.values.fold<int>(0, (total, bytes) => total + bytes.length) +
        byteLength;
    if (expandedBytes > SkillPackage.maximumExpandedBytes) {
      throw const SkillPackageFormatException(
        'The expanded Skill package is too large.',
      );
    }
  }

  void _validateEntrySet(Map<String, Uint8List> entries) {
    if (entries.isEmpty) {
      throw const SkillPackageFormatException('Skill package is empty.');
    }
    final caseInsensitivePaths = <String>{};
    var totalBytes = 0;
    for (final entry in entries.entries) {
      final path = SkillPackage.normalizeRelativePath(entry.key);
      if (!caseInsensitivePaths.add(path.toLowerCase())) {
        throw SkillPackageFormatException(
          'Skill package contains duplicate file paths: $path',
        );
      }
      totalBytes += entry.value.length;
    }
    if (totalBytes > SkillPackage.maximumExpandedBytes) {
      throw const SkillPackageFormatException(
        'The expanded Skill package is too large.',
      );
    }
  }

  String _decodeEntrypoint(Uint8List bytes) {
    late final String decoded;
    try {
      decoded = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const SkillPackageFormatException('SKILL.md must be valid UTF-8.');
    }
    final content = decoded.startsWith('\uFEFF')
        ? decoded.substring(1)
        : decoded;
    if (content.trim().isEmpty) {
      throw const SkillPackageFormatException('SKILL.md cannot be empty.');
    }
    if (content.length > JianheItem.maxContentLength) {
      throw const SkillPackageFormatException('SKILL.md is too long.');
    }
    return content;
  }

  String _skillTitle(String content, String fallback) {
    var title = fallback.trim();
    final lines = const LineSplitter().convert(content);
    if (lines.isNotEmpty && lines.first.trim() == '---') {
      final closing = lines.indexWhere((line) => line.trim() == '---', 1);
      if (closing > 1) {
        try {
          final yaml = loadYaml(lines.sublist(1, closing).join('\n'));
          if (yaml is YamlMap && yaml['name'] is String) {
            final name = (yaml['name'] as String).trim();
            if (name.isNotEmpty) title = name;
          }
        } on YamlException {
          throw const SkillPackageFormatException(
            'SKILL.md frontmatter is invalid YAML.',
          );
        }
      }
    }
    if (title.isEmpty) title = 'Imported Skill';
    if (title.length > JianheItem.maxTitleLength) {
      title = title.substring(0, JianheItem.maxTitleLength);
    }
    return title;
  }

  Map<String, Uint8List> _packageFiles(
    JianheItem skill,
    SkillPackage? package,
  ) {
    // Files read from storage skip re-hashing (SkillFile.trusted); bytes
    // leaving the app are checked once here, on an explicit user action.
    for (final file in package?.files ?? const <SkillFile>[]) {
      file.verifyIntegrity();
    }
    return <String, Uint8List>{
      SkillPackage.defaultEntrypoint: Uint8List.fromList(
        utf8.encode(skill.content),
      ),
      if (package != null)
        for (final file in package.files) file.relativePath: file.content,
    };
  }

  String? _mediaType(String path) {
    return switch (p.extension(path).toLowerCase()) {
      '.md' => 'text/markdown',
      '.txt' => 'text/plain',
      '.json' => 'application/json',
      '.yaml' || '.yml' => 'application/yaml',
      '.png' => 'image/png',
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.gif' => 'image/gif',
      '.svg' => 'image/svg+xml',
      '.pdf' => 'application/pdf',
      '.js' => 'text/javascript',
      '.ts' => 'text/typescript',
      '.py' => 'text/x-python',
      '.sh' => 'text/x-shellscript',
      _ => null,
    };
  }

  Future<void> _rejectOutputLinks(String rootPath, String filePath) async {
    var current = File(filePath).parent;
    final root = p.normalize(p.absolute(rootPath));
    while (p.isWithin(root, current.path)) {
      if (await FileSystemEntity.type(current.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const SkillPackageFormatException(
          'Output directories cannot contain symbolic links.',
        );
      }
      current = current.parent;
    }
    if (await FileSystemEntity.type(filePath, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const SkillPackageFormatException(
        'Output files cannot be symbolic links.',
      );
    }
  }
}

/// Counts decompressed bytes and fails once they exceed the cap, so a forged
/// size header cannot expand a small archive into memory.  Extends the
/// concrete [OutputStream] because inflate reads back through `subset` for
/// LZ77 back-references, which the OutputStreamBase interface lacks.
class _BoundedOutputStream extends OutputStream {
  _BoundedOutputStream(this.cap);

  final int cap;

  Uint8List takeBytes() => Uint8List.fromList(getBytes());

  void _enforce(int additional) {
    if (length + additional > cap) throw const _ZipEntryTooLarge();
  }

  @override
  void writeByte(int value) {
    _enforce(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, [int? len]) {
    _enforce(len ?? bytes.length);
    super.writeBytes(bytes, len);
  }

  @override
  void writeInputStream(InputStreamBase stream) {
    // The base implementation appends the whole stream in one shot, so the
    // cap must be checked before it can grow the buffer.
    _enforce(stream.length);
    super.writeInputStream(stream);
  }
}

class _ZipEntryTooLarge implements Exception {
  const _ZipEntryTooLarge();
}
