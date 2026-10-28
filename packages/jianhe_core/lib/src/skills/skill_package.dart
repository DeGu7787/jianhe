import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

enum SkillSourceFormat {
  markdown('markdown'),
  directory('directory'),
  zip('zip');

  const SkillSourceFormat(this.storageValue);

  final String storageValue;

  static SkillSourceFormat fromStorage(String value) {
    return SkillSourceFormat.values.firstWhere(
      (format) => format.storageValue == value,
      orElse: () =>
          throw FormatException('Unsupported Skill source format: $value'),
    );
  }
}

class SkillFile {
  SkillFile({
    required String relativePath,
    required Uint8List content,
    this.mediaType,
    String? contentHash,
  }) : relativePath = SkillPackage.normalizeRelativePath(relativePath),
       content = Uint8List.fromList(content),
       contentHash = _verifiedHash(content, contentHash);

  /// Rebuilds a file from local storage without re-hashing its bytes.
  ///
  /// [contentHash] was verified when the file was first written (every
  /// insert goes through the default constructor), and SQLite guards the
  /// stored bytes. Re-hashing every attachment on each read cost the UI
  /// isolate a full sha256 pass over up to 50 MiB per package, on paths as
  /// common as opening a Skill or building a sync record. Callers that hand
  /// bytes to the outside world (export) call [verifyIntegrity] first.
  /// [content] is adopted as is, so pass a buffer nobody else mutates.
  SkillFile.trusted({
    required String relativePath,
    required this.content,
    required this.contentHash,
    this.mediaType,
  }) : relativePath = SkillPackage.normalizeRelativePath(relativePath);

  final String relativePath;
  final Uint8List content;
  final String? mediaType;
  final String contentHash;

  int get byteLength => content.length;

  /// Re-hashes the bytes and throws when they no longer match
  /// [contentHash] (storage corruption on a [SkillFile.trusted] file).
  void verifyIntegrity() => _verifiedHash(content, contentHash);

  static String _verifiedHash(Uint8List content, String? expected) {
    final actual = sha256.convert(content).toString();
    if (expected != null && expected != actual) {
      throw const SkillPackageFormatException(
        'A Skill file failed its integrity check.',
      );
    }
    return actual;
  }
}

class SkillFileMetadata {
  SkillFileMetadata({
    required String relativePath,
    required this.byteLength,
    required this.contentHash,
    this.mediaType,
  }) : relativePath = SkillPackage.normalizeRelativePath(relativePath) {
    if (byteLength < 0) {
      throw const SkillPackageFormatException(
        'A Skill file cannot have a negative byte length.',
      );
    }
    if (contentHash.trim().isEmpty) {
      throw const SkillPackageFormatException(
        'A Skill file content hash cannot be empty.',
      );
    }
  }

  final String relativePath;
  final String? mediaType;
  final int byteLength;
  final String contentHash;
}

class SkillPackage {
  SkillPackage({
    required this.skillId,
    required this.sourceFormat,
    required this.importedAt,
    this.entrypoint = defaultEntrypoint,
    Iterable<SkillFile> files = const <SkillFile>[],
  }) : files = List<SkillFile>.unmodifiable(files) {
    if (skillId.trim().isEmpty) {
      throw const SkillPackageFormatException('Skill id cannot be empty.');
    }
    if (entrypoint != defaultEntrypoint) {
      throw const SkillPackageFormatException(
        'The Skill entrypoint must be SKILL.md.',
      );
    }
    _validateFiles(this.files);
  }

  static const defaultEntrypoint = 'SKILL.md';
  static const maximumArchiveBytes = 25 * 1024 * 1024;
  static const maximumExpandedBytes = 50 * 1024 * 1024;
  static const maximumFileBytes = 10 * 1024 * 1024;
  static const maximumFileCount = 500;
  static const maximumPathDepth = 16;
  static const maximumPathLength = 240;

  final String skillId;
  final SkillSourceFormat sourceFormat;
  final DateTime importedAt;
  final String entrypoint;
  final List<SkillFile> files;

  int get fileCount => files.length + 1;

  int totalBytes(String entrypointContent) {
    return utf8.encode(entrypointContent).length +
        files.fold<int>(0, (total, file) => total + file.byteLength);
  }

  /// Largest single blob the cloud sync server accepts
  /// (SYNC_BLOB_TOO_LARGE above this).
  static const maximumSyncBlobBytes = 64 * 1024 * 1024;

  /// Upper estimate of this package's cloud sync blob, given the SKILL.md
  /// text in [entrypointContent]. The blob is JSON carrying every file
  /// base64-encoded (4/3 of its size), so a package well under
  /// [maximumExpandedBytes] can still be too large to sync.
  int syncBlobBytes(String entrypointContent) {
    var total = 160 + // keys, imported_at, source format, punctuation
        _jsonStringBytes(entrypoint) +
        _jsonStringBytes(entrypointContent);
    for (final file in files) {
      total += 64 +
          _jsonStringBytes(file.relativePath) +
          (file.mediaType == null ? 0 : 16 + _jsonStringBytes(file.mediaType!)) +
          4 * ((file.byteLength + 2) ~/ 3);
    }
    return total;
  }

  /// True when this package cannot be synced to the cloud: it would only
  /// exist on the device that imported it.
  bool exceedsSyncBlobLimit(String entrypointContent) =>
      syncBlobBytes(entrypointContent) > maximumSyncBlobBytes;

  static int _jsonStringBytes(String value) =>
      utf8.encode(jsonEncode(value)).length;

  String packageHash(String entrypointContent) {
    return calculatePackageHash(entrypointContent, <String, String>{
      for (final file in files) file.relativePath: file.contentHash,
    });
  }

  static String calculatePackageHash(
    String entrypointContent,
    Map<String, String> auxiliaryFileHashes,
  ) {
    final sortedPaths = auxiliaryFileHashes.keys.toList()..sort();
    final canonical = <String, Object?>{
      'entrypoint': defaultEntrypoint,
      'entrypoint_sha256': sha256
          .convert(utf8.encode(entrypointContent))
          .toString(),
      'files': <Map<String, String>>[
        for (final path in sortedPaths)
          <String, String>{
            'path': normalizeRelativePath(path),
            'sha256': auxiliaryFileHashes[path]!,
          },
      ],
    };
    return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
  }

  static String normalizeRelativePath(String value) {
    final normalized = value.replaceAll('\\', '/');
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
        normalized.length > maximumPathLength) {
      throw SkillPackageFormatException('Unsafe Skill file path: $value');
    }
    final segments = normalized.split('/');
    if (segments.length > maximumPathDepth ||
        segments.any(
          (segment) =>
              segment.isEmpty ||
              segment == '.' ||
              segment == '..' ||
              segment.endsWith('.') ||
              segment.endsWith(' ') ||
              RegExp(r'[<>:"|?*]').hasMatch(segment) ||
              segment.codeUnits.any((unit) => unit < 32) ||
              _windowsReservedNames.contains(
                segment.split('.').first.toUpperCase(),
              ),
        )) {
      throw SkillPackageFormatException('Unsafe Skill file path: $value');
    }
    return segments.join('/');
  }

  static const _windowsReservedNames = <String>{
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };

  static void _validateFiles(List<SkillFile> files) {
    if (files.length + 1 > maximumFileCount) {
      throw const SkillPackageFormatException(
        'A Skill package contains too many files.',
      );
    }
    var expandedBytes = 0;
    final caseInsensitivePaths = <String>{defaultEntrypoint.toLowerCase()};
    for (final file in files) {
      if (file.relativePath == defaultEntrypoint ||
          !caseInsensitivePaths.add(file.relativePath.toLowerCase())) {
        throw SkillPackageFormatException(
          'A Skill package contains a duplicate file path: '
          '${file.relativePath}',
        );
      }
      if (file.byteLength > maximumFileBytes) {
        throw SkillPackageFormatException(
          'A Skill file is larger than $maximumFileBytes bytes: '
          '${file.relativePath}',
        );
      }
      expandedBytes += file.byteLength;
      if (expandedBytes > maximumExpandedBytes) {
        throw const SkillPackageFormatException(
          'The expanded Skill package is too large.',
        );
      }
    }
  }
}

class SkillPackageFormatException extends FormatException {
  const SkillPackageFormatException(super.message);
}
