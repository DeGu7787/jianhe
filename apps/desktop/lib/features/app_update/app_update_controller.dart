import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../l10n/app_strings.dart';
import 'app_update_models.dart';

export 'app_update_models.dart';

enum AppUpdateStatus {
  /// Nothing checked yet (or the last background check failed quietly).
  idle,
  checking,
  upToDate,

  /// A newer version is published; the user has not asked to download it.
  available,
  downloading,

  /// The installer is downloaded and verified; one more tap installs it.
  ready,
  installing,

  /// A user-started check or download failed; [AppUpdateController.message]
  /// says why and tapping the entry retries.
  error,
}

/// Drives the "检查更新" entry on the 更多 page. Updates are never forced:
/// a check only reports, the user starts the background download, and the
/// user starts the install once the download is verified.
class AppUpdateController extends ChangeNotifier {
  AppUpdateController({
    required AppUpdatePlatform platform,
    required String currentVersion,
    bool Function()? isSyncing,
    this.firstCheckDelay = const Duration(minutes: 1),
    this.checkInterval = const Duration(hours: 24),
  }) : _platform = platform,
       _isSyncing = isSyncing,
       currentVersion =
           AppVersion.tryParse(currentVersion) ?? AppVersion.tryParse('0')!;

  final AppUpdatePlatform _platform;
  final bool Function()? _isSyncing;
  final AppVersion currentVersion;
  final Duration firstCheckDelay;
  final Duration checkInterval;

  AppUpdateStatus _status = AppUpdateStatus.idle;
  UpdateManifest? _manifest;
  String? _installerPath;
  String? _message;
  int _receivedBytes = 0;
  Timer? _firstCheck;
  Timer? _periodicCheck;
  bool _disposed = false;

  AppUpdateStatus get status => _status;

  /// The newer release being offered, downloaded or installed.
  UpdateManifest? get manifest => _manifest;

  /// Error text in [AppUpdateStatus.error], or why an install cannot start
  /// yet while [AppUpdateStatus.ready].
  String? get message => _message;

  /// Download progress in 0..1 while [AppUpdateStatus.downloading].
  double get progress {
    final total = _manifest?.size ?? 0;
    if (total <= 0) return 0;
    return (_receivedBytes / total).clamp(0, 1).toDouble();
  }

  bool get busy =>
      _status == AppUpdateStatus.checking ||
      _status == AppUpdateStatus.downloading ||
      _status == AppUpdateStatus.installing;

  /// Starts the quiet background checks: one shortly after launch, then one
  /// every [checkInterval].
  void start() {
    if (_disposed || _firstCheck != null) return;
    _firstCheck = Timer(firstCheckDelay, () => unawaited(checkNow()));
    _periodicCheck = Timer.periodic(
      checkInterval,
      (_) => unawaited(checkNow()),
    );
  }

  /// Checks for a newer release. Background checks ([userInitiated] false)
  /// never surface errors and never interrupt a download or a ready install.
  Future<void> checkNow({bool userInitiated = false}) async {
    if (_disposed || busy) return;
    final previous = _status;
    // A background check must not replace an error the user has not seen
    // or acted on yet; tapping the entry retries.
    if (!userInitiated && previous == AppUpdateStatus.error) return;
    _set(AppUpdateStatus.checking, message: null);
    UpdateManifest? latest;
    try {
      latest = await _platform.fetchManifest();
    } on Object catch (error) {
      if (_disposed) return;
      if (userInitiated) {
        _set(
          AppUpdateStatus.error,
          message: _describe(error, AppStrings.current.updateCheckFailedShort),
        );
      } else {
        _restoreAfterQuietFailure(previous);
      }
      return;
    }
    if (_disposed) return;
    if (latest == null || !(latest.version > currentVersion)) {
      _manifest = null;
      _installerPath = null;
      _set(AppUpdateStatus.upToDate, message: null);
      return;
    }
    if (_installerPath != null &&
        _manifest != null &&
        _manifest!.version == latest.version &&
        _manifest!.sha256 == latest.sha256) {
      _set(AppUpdateStatus.ready, message: null);
      return;
    }
    _manifest = latest;
    _installerPath = null;
    // A download finished in an earlier session can be installed directly.
    String? existing;
    try {
      existing = await _platform.findDownloaded(latest);
    } on Object {
      existing = null;
    }
    if (_disposed) return;
    if (existing != null) {
      _installerPath = existing;
      _set(AppUpdateStatus.ready, message: null);
    } else {
      _set(AppUpdateStatus.available, message: null);
    }
  }

  /// Downloads the offered release in the background.
  Future<void> download() async {
    final manifest = _manifest;
    if (_disposed || manifest == null || busy) return;
    _receivedBytes = 0;
    _set(AppUpdateStatus.downloading, message: null);
    var lastPercent = -1;
    try {
      final path = await _platform.download(
        manifest,
        onProgress: (received) {
          if (_disposed) return;
          _receivedBytes = received;
          final percent = (progress * 100).floor();
          if (percent != lastPercent) {
            lastPercent = percent;
            notifyListeners();
          }
        },
      );
      if (_disposed) return;
      _installerPath = path;
      _set(AppUpdateStatus.ready, message: null);
    } on Object catch (error) {
      if (_disposed) return;
      _set(
        AppUpdateStatus.error,
        message: _describe(error, AppStrings.current.updateDownloadFailedShort),
      );
    }
  }

  /// Launches the verified installer and quits through [quit], which lets
  /// the app flush unsaved drafts first. Returns false (with [message]) when
  /// the install cannot start right now.
  Future<bool> install({required Future<void> Function() quit}) async {
    final manifest = _manifest;
    final path = _installerPath;
    if (_disposed ||
        _status != AppUpdateStatus.ready ||
        manifest == null ||
        path == null) {
      return false;
    }
    if (_isSyncing?.call() ?? false) {
      _set(AppUpdateStatus.ready, message: AppStrings.current.updateWaitForSync);
      return false;
    }
    try {
      if (await _platform.isCliRunning()) {
        _set(
          AppUpdateStatus.ready,
          message: AppStrings.current.updateWaitForCli,
        );
        return false;
      }
    } on Object {
      // Detection is best effort; the installer still closes the CLI.
    }
    bool intact;
    try {
      intact = await _platform.verify(path, manifest);
    } on Object {
      intact = false;
    }
    if (_disposed) return false;
    if (!intact) {
      _installerPath = null;
      _set(
        AppUpdateStatus.available,
        message: AppStrings.current.updateInstallerDamaged,
      );
      return false;
    }
    _set(AppUpdateStatus.installing, message: null);
    try {
      await _platform.launchInstaller(path);
    } on Object catch (error) {
      if (_disposed) return false;
      _set(
        AppUpdateStatus.ready,
        message: _describe(error, AppStrings.current.updateCannotLaunchShort),
      );
      return false;
    }
    // The installer waits for this process to exit before replacing files
    // and reopens the app once it is done.
    await quit();
    return true;
  }

  void _restoreAfterQuietFailure(AppUpdateStatus previous) {
    switch (previous) {
      case AppUpdateStatus.available when _manifest != null:
        _set(AppUpdateStatus.available, message: null);
      case AppUpdateStatus.ready when _installerPath != null:
        _set(AppUpdateStatus.ready, message: null);
      case AppUpdateStatus.upToDate:
        _set(AppUpdateStatus.upToDate, message: null);
      default:
        _set(AppUpdateStatus.idle, message: null);
    }
  }

  static String _describe(Object error, String fallback) {
    if (error is AppUpdateException && error.message.isNotEmpty) {
      return error.message;
    }
    return AppStrings.current.updateCheckNetwork(fallback);
  }

  void _set(AppUpdateStatus status, {required String? message}) {
    _status = status;
    _message = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _firstCheck?.cancel();
    _periodicCheck?.cancel();
    super.dispose();
  }
}
