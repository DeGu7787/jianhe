/// Release manifest and version handling for the desktop self-updater.
///
/// The manifest is the `windows` object of `download.json`, which is
/// published with the official website. The server's
/// download resolver reads only `primary` / `fallback` from the same object
/// and ignores the update fields, so both can share one file.
library;

/// A dotted numeric version such as `0.1.7`. Build metadata (`+8`) and
/// pre-release suffixes (`-beta`) are ignored for ordering.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion._(this.parts, this.text);

  final List<int> parts;
  final String text;

  static final _pattern = RegExp(r'^\d{1,6}(\.\d{1,6}){0,3}$');

  static AppVersion? tryParse(String? raw) {
    if (raw == null) return null;
    var value = raw.trim();
    if (value.startsWith('v') || value.startsWith('V')) {
      value = value.substring(1);
    }
    final cut = value.indexOf(RegExp('[+-]'));
    if (cut >= 0) value = value.substring(0, cut);
    if (!_pattern.hasMatch(value)) return null;
    return AppVersion._(
      List<int>.unmodifiable(value.split('.').map(int.parse)),
      value,
    );
  }

  @override
  int compareTo(AppVersion other) {
    final length = parts.length > other.parts.length
        ? parts.length
        : other.parts.length;
    for (var index = 0; index < length; index++) {
      final left = index < parts.length ? parts[index] : 0;
      final right = index < other.parts.length ? other.parts[index] : 0;
      if (left != right) return left.compareTo(right);
    }
    return 0;
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hashAll(
    // Trailing zeros do not change ordering, so they must not change the
    // hash either (0.1 == 0.1.0).
    () {
      final trimmed = List<int>.of(parts);
      while (trimmed.isNotEmpty && trimmed.last == 0) {
        trimmed.removeLast();
      }
      return trimmed;
    }(),
  );

  @override
  String toString() => text;
}

/// The newest published Windows installer.
class UpdateManifest {
  const UpdateManifest({
    required this.version,
    required this.sha256,
    required this.size,
    this.notes = '',
  });

  /// Installers larger than this are rejected as a malformed manifest.
  static const maxInstallerBytes = 512 * 1024 * 1024;

  static final _digest = RegExp(r'^[0-9a-f]{64}$');

  final AppVersion version;

  /// Lower-case hex SHA-256 of the installer.
  final String sha256;

  /// Exact installer size in bytes.
  final int size;

  /// Short release notes shown next to the update entry; may be empty.
  final String notes;

  /// Reads the `windows` entry of `download.json`. Returns null when the
  /// file carries no (or an unusable) update description, e.g. a manifest
  /// published before the self-updater existed.
  static UpdateManifest? fromDownloadJson(Object? json) {
    if (json is! Map) return null;
    final windows = json['windows'];
    if (windows is! Map) return null;
    final version = AppVersion.tryParse(windows['version'] as String?);
    final digest = windows['sha256'];
    final size = windows['size'];
    final notes = windows['notes'];
    if (version == null ||
        digest is! String ||
        !_digest.hasMatch(digest.trim().toLowerCase()) ||
        size is! int ||
        size <= 0 ||
        size > maxInstallerBytes) {
      return null;
    }
    return UpdateManifest(
      version: version,
      sha256: digest.trim().toLowerCase(),
      size: size,
      notes: notes is String ? notes.trim() : '',
    );
  }
}

/// Raised by [AppUpdatePlatform] with a message fit for the settings entry.
class AppUpdateException implements Exception {
  const AppUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Everything the updater needs from the operating system and network.
/// The desktop build supplies `IoAppUpdatePlatform`; tests use fakes.
abstract interface class AppUpdatePlatform {
  /// Fetches the published manifest; null when it carries no update info.
  Future<UpdateManifest?> fetchManifest();

  /// Path of an already downloaded, verified installer for [manifest], or
  /// null. Lets a restart reuse the earlier download.
  Future<String?> findDownloaded(UpdateManifest manifest);

  /// Downloads the installer and verifies its size and SHA-256 against
  /// [manifest]; returns the local path. Throws [AppUpdateException].
  Future<String> download(
    UpdateManifest manifest, {
    required void Function(int receivedBytes) onProgress,
  });

  /// Re-checks the downloaded file right before it is launched.
  Future<bool> verify(String path, UpdateManifest manifest);

  /// Whether the jianhe CLI is running (an AI agent may be mid-command);
  /// the installer would terminate it.
  Future<bool> isCliRunning();

  /// Starts the installer in update mode, detached from this process.
  Future<void> launchInstaller(String path);
}
