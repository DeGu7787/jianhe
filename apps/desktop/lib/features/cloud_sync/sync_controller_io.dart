import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../l10n/app_strings.dart';
import '../account/account_api.dart';
import '../account/account_session_controller.dart';
import 'sync_engine.dart';
import 'sync_models.dart';
import 'sync_schedule.dart';

export 'sync_models.dart' show SyncRunResult, SyncMode;


/// Receives one preformatted diagnostic entry per failed sync run. Release
/// builds drop debugPrint output, so main.dart routes this to error.log.
typedef SyncErrorLog = void Function(String entry);

String get _genericSyncFailure => AppStrings.current.syncGenericFailure;

typedef SyncCriticalSection =
    Future<T> Function<T>(Future<T> Function() action);

Future<T> _runSyncDirectly<T>(Future<T> Function() action) => action();

enum SyncControllerStatus { signedOut, idle, syncing }

/// Incremental sync state machine for the account panel card. Manual runs
/// report every failure in [message]; the card renders it in its own
/// message slot (SnackBar is invisible in the frameless multi-window
/// panel). Automatic runs — debounced local changes, startup, foreground
/// wake, Windows-scheduled IPC, and retry — fail silently, so background
/// hiccups never surface as scary card errors.
class SyncController extends ChangeNotifier {
  SyncController({
    required AccountSessionController accountSession,
    required SyncEngine engine,
    bool Function()? autoSyncEnabled,
    void Function(bool value)? setAutoSyncEnabled,
    SyncSchedule Function()? syncSchedule,
    void Function(SyncSchedule value)? setSyncSchedule,
    ({int hour, int minute}) Function()? dailySyncTime,
    Future<DateTime?> Function(SyncSchedule value)? configureSystemSchedule,
    Future<void> Function()? cancelSystemSchedule,
    SyncCriticalSection? syncCriticalSection,
    SyncErrorLog? errorLog,
    Duration autoPushDebounce = const Duration(seconds: 30),
    Duration foregroundPullInterval = const Duration(minutes: 5),
    Duration startupDelay = const Duration(seconds: 8),
    List<Duration> retryDelays = const <Duration>[
      Duration(seconds: 30),
      Duration(minutes: 1),
      Duration(minutes: 2),
      Duration(minutes: 5),
    ],
  }) : _accountSession = accountSession,
       _engine = engine,
       _autoSyncEnabled = autoSyncEnabled,
       _setAutoSyncEnabled = setAutoSyncEnabled,
       _syncSchedule = syncSchedule,
       _setSyncSchedule = setSyncSchedule,
       _dailySyncTime = dailySyncTime,
       _configureSystemSchedule = configureSystemSchedule,
       _cancelSystemSchedule = cancelSystemSchedule,
       _syncCriticalSection = syncCriticalSection ?? _runSyncDirectly,
       _errorLog = errorLog,
       _autoPushDebounce = autoPushDebounce,
       _foregroundPullInterval = foregroundPullInterval,
       _startupDelay = startupDelay,
       _retryDelays = List.unmodifiable(retryDelays) {
    _accountSession.addListener(_handleAccountChanged);
    _engine.onRemoteChange = _handleRemoteChange;
    _status = _accountSession.signedIn
        ? SyncControllerStatus.idle
        : SyncControllerStatus.signedOut;
    _observedAccountId = _accountSession.account?.id;
    if (autoSyncEnabled != null) {
      _startupTimer = Timer(startupDelay, _runStartupSync);
      unawaited(_reconcileSystemSchedule());
    }
  }

  final AccountSessionController _accountSession;
  final SyncEngine _engine;
  final bool Function()? _autoSyncEnabled;
  final void Function(bool value)? _setAutoSyncEnabled;
  final SyncSchedule Function()? _syncSchedule;
  final void Function(SyncSchedule value)? _setSyncSchedule;
  final ({int hour, int minute}) Function()? _dailySyncTime;
  final Future<DateTime?> Function(SyncSchedule value)?
  _configureSystemSchedule;
  final Future<void> Function()? _cancelSystemSchedule;
  final SyncCriticalSection _syncCriticalSection;
  final SyncErrorLog? _errorLog;
  final Duration _autoPushDebounce;
  final Duration _foregroundPullInterval;
  final List<Duration> _retryDelays;

  Timer? _debounceTimer;
  Timer? _startupTimer;
  Timer? _retryTimer;
  DateTime? _lastAutoPullAt;
  int _retryAttempt = 0;
  int _remoteDataEpoch = 0;
  int _scheduleRevision = 0;

  final Duration _startupDelay;

  SyncControllerStatus _status = SyncControllerStatus.signedOut;
  String? _message;
  SyncRunResult? _lastResult;
  int _generation = 0;
  String? _observedAccountId;
  bool _disposed = false;

  SyncControllerStatus get status => _status;
  bool get syncing => _status == SyncControllerStatus.syncing;
  bool get engineRunning => _engine.running;
  String? get message => _message;
  SyncRunResult? get lastResult => _lastResult;

  /// Increments whenever the engine applies remote changes locally; the
  /// ball home page watches this to refresh its item lists.
  int get remoteDataEpoch => _remoteDataEpoch;

  bool get autoSyncEnabled => _autoSyncEnabled?.call() ?? false;
  SyncSchedule get schedule =>
      _syncSchedule?.call() ?? SyncSchedule.defaultSchedule;
  ({int hour, int minute}) get preferredDailySyncTime {
    final current = schedule;
    if (current.mode == SyncScheduleMode.daily) {
      return (hour: current.dailyHour!, minute: current.dailyMinute!);
    }
    return _dailySyncTime?.call() ?? (hour: 21, minute: 0);
  }

  DateTime? get nextScheduledAt {
    var next = _nextScheduledAt;
    if (next == null || next.isAfter(DateTime.now())) return next;
    final currentSchedule = schedule;
    if (currentSchedule.mode == SyncScheduleMode.daily) {
      return currentSchedule.nextRunAfter(DateTime.now());
    }
    final interval = Duration(minutes: currentSchedule.intervalMinutes!);
    while (!next!.isAfter(DateTime.now())) {
      next = next.add(interval);
    }
    return next;
  }

  String? get scheduleError => _scheduleError;

  DateTime? _nextScheduledAt;
  String? _scheduleError;
  SyncSchedule? _registeredSchedule;
  bool _systemScheduleActive = false;

  void setAutoSyncEnabled(bool enabled) {
    _setAutoSyncEnabled?.call(enabled);
    if (enabled) {
      _retryAttempt = 0;
      if (_autoGateOpen) {
        _startupTimer?.cancel();
        _startupTimer = Timer(Duration.zero, _runStartupSync);
      }
    } else {
      _cancelAutoTimers();
    }
    unawaited(_reconcileSystemSchedule());
    _notify();
  }

  void setSchedule(SyncSchedule value) {
    _setSyncSchedule?.call(value);
    unawaited(_reconcileSystemSchedule());
    _notify();
  }

  /// The full prerequisite set for an automatic run: enabled, signed in,
  /// and still entitled to upload or restore cloud content.
  bool get _autoGateOpen => !_disposed && autoSyncEnabled && canDownload;

  String? get accountId {
    if (!_accountSession.signedIn) return null;
    return _accountSession.account?.id;
  }

  int get pendingCount => _engine.pendingCount;

  DateTime? get lastSyncAt {
    final id = accountId;
    if (id == null) return null;
    return _engine.lastSyncFinishedAt(id);
  }

  bool get canUpload =>
      _accountSession.signedIn &&
      (_accountSession.account?.entitlement.isVip ?? false);

  bool get canDownload =>
      _accountSession.signedIn &&
      (_accountSession.account?.entitlement.hasCloudBackupAccess ?? false);

  /// Client-side convenience gate. The server remains authoritative.
  bool get canSync => canDownload && _status != SyncControllerStatus.syncing;

  String? get missingPrerequisite {
    if (accountId == null) return AppStrings.current.syncNeedsSignIn;
    if (!canDownload) return AppStrings.current.syncNeedsVip;
    return null;
  }

  /// A local write happened; (re)start the auto-push debounce window so a
  /// burst of edits collapses into one run. The manual button stays the
  /// authoritative trigger — this only schedules a background run.
  void notifyLocalChanged() {
    if (!_autoGateOpen) return;
    _armDebounce();
  }

  /// The ball was woken (hotkey or tap) — a cheap pull-only refresh, at
  /// most once per foreground interval so orbiting the ball does not
  /// hammer the API.
  void notifyForeground() {
    if (!_autoGateOpen) return;
    if (_status == SyncControllerStatus.syncing || _engine.running) return;
    final last = _lastAutoPullAt;
    if (last != null &&
        DateTime.now().difference(last) < _foregroundPullInterval) {
      return;
    }
    unawaited(
      synchronize(mode: SyncMode.pullOnly, automatic: true).then((succeeded) {
        // Only a successful wake pull consumes the cooldown; a failed one
        // (network flap) must not enforce a five-minute blackout before
        // the next attempt.
        if (succeeded) _lastAutoPullAt = DateTime.now();
      }),
    );
  }

  /// Executes one automatic cycle. Trigger sources deliberately do not choose
  /// push/pull semantics; pending durable changes make this a full cycle.
  Future<bool> requestAutomaticSync() {
    if (!_autoGateOpen) return Future<bool>.value(false);
    // An automatic trigger must never supersede a manual run in flight —
    // the generation bump would cancel the user's sync at its next safe
    // checkpoint.
    if (_status == SyncControllerStatus.syncing) {
      return Future<bool>.value(false);
    }
    return synchronize(
      mode: _engine.pendingCount > 0 ? SyncMode.pushAndPull : SyncMode.pullOnly,
      automatic: true,
    );
  }

  /// Runs one sync cycle; true when the engine completed successfully.
  /// (Callers like the foreground-wake cooldown only count successes.)
  Future<bool> synchronize({
    SyncMode mode = SyncMode.pushAndPull,
    bool automatic = false,
  }) async {
    // Every automatic source ultimately passes through this method. Recheck
    // the complete gate here so a scheduled IPC message that was already in
    // flight cannot start after the user disables automatic synchronization.
    if (automatic && !_autoGateOpen) return false;
    if (automatic) {
      // An automatic trigger must never supersede a manual run in flight —
      // the generation bump would cancel the user's sync at its next safe
      // checkpoint. Debounced pushes re-arm themselves; startup/scheduled
      // runs simply wait for their next trigger.
      if (_status == SyncControllerStatus.syncing) return false;
      // Any fresh trigger supersedes a queued retry; a new retry is armed
      // below only if this run also ends in a transient failure.
      _retryTimer?.cancel();
      _retryTimer = null;
    } else {
      // A manual run supersedes anything the auto triggers queued up.
      _debounceTimer?.cancel();
      _debounceTimer = null;
      _startupTimer?.cancel();
      _startupTimer = null;
      _retryTimer?.cancel();
      _retryTimer = null;
      _retryAttempt = 0;
    }
    if (_disposed || !canSync) return false;
    final currentAccountId = accountId;
    if (currentAccountId == null) return false;
    final generation = ++_generation;
    _observedAccountId = currentAccountId;
    _message = null;
    _status = SyncControllerStatus.syncing;
    _notify();
    var succeeded = false;
    try {
      final effectiveMode = mode == SyncMode.pushAndPull && !canUpload
          ? SyncMode.pullOnly
          : mode;
      final result = await _syncCriticalSection(() {
        // The process lock can be held by another worker for a while. Honor a
        // late opt-out (or account/entitlement change) before making the first
        // request, and keep checking at the engine's safe cancellation points.
        if (automatic && !_autoGateOpen) {
          throw const SyncCancelledException();
        }
        return _engine.synchronize(
          accountId: currentAccountId,
          mode: effectiveMode,
          cancelled: () =>
              generation != _generation ||
              _accountSession.account?.id != currentAccountId ||
              (automatic && !_autoGateOpen),
        );
      });
      if (generation != _generation) return false;
      _lastResult = result;
      _status = SyncControllerStatus.idle;
      _message = result.quotaNotice ??
          (result.warnings.isEmpty
              ? null
              : AppStrings.current.syncPartialFailure);
      _logWarnings(automatic: automatic, warnings: result.warnings);
      _resetRetry();
      succeeded = true;
    } on SyncCancelledException {
      if (generation != _generation) return false;
      _status = SyncControllerStatus.idle;
      if (!automatic) _message = AppStrings.current.syncCancelled;
    } on SyncEngineException catch (error) {
      if (generation != _generation) return false;
      _status = SyncControllerStatus.idle;
      if (automatic) _resetRetry();
      if (!automatic) {
        _message = error.code == 'SYNC_IN_PROGRESS'
            ? AppStrings.current.syncBusy
            : _userFacing(error.message);
      }
      _logFailure(
        automatic: automatic,
        summary: 'SyncEngineException(${error.code}): ${error.message}',
      );
    } on AccountApiException catch (error) {
      if (generation != _generation) return false;
      _status = SyncControllerStatus.idle;
      if (!automatic) {
        _message = switch (error.code) {
          'VIP_REQUIRED' => AppStrings.current.syncVipExpired,
          'SYNC_DOWNLOAD_NOT_ALLOWED' => AppStrings.current.syncNeedsVip,
          _ => _userFacing(error.message),
        };
      }
      if (automatic) {
        if (error.retryable) {
          _scheduleRetry();
        } else {
          _resetRetry();
        }
      }
      _logFailure(
        automatic: automatic,
        summary:
            'AccountApiException(${error.code}, retryable: ${error.retryable}, '
            'requestId: ${error.requestId ?? '-'}): ${error.message}',
      );
    } on Object catch (error, stackTrace) {
      if (generation != _generation) return false;
      _status = SyncControllerStatus.idle;
      if (automatic) _resetRetry();
      if (!automatic) {
        _message = error is FormatException
            ? AppStrings.current.syncDataMalformed
            : _genericSyncFailure;
      }
      _logFailure(
        automatic: automatic,
        summary: '${error.runtimeType}: $error',
        stackTrace: stackTrace,
      );
    }
    _notify();
    return succeeded;
  }

  /// Server and engine messages are already written for end users; fall
  /// back to the generic text only when one is missing. The request id is
  /// kept out of the UI and only written to the error log by [_logFailure].
  static String _userFacing(String message) {
    final text = message.trim();
    return text.isEmpty ? _genericSyncFailure : text;
  }

  void _logFailure({
    required bool automatic,
    required String summary,
    StackTrace? stackTrace,
  }) {
    final trigger = automatic ? 'automatic' : 'manual';
    final line = 'Cloud sync failed [$trigger] $summary';
    debugPrint(line);
    final log = _errorLog;
    if (log == null) return;
    final buffer = StringBuffer()
      ..writeln('[${DateTime.now().toIso8601String()}] $line');
    if (stackTrace != null) buffer.writeln(stackTrace);
    try {
      log(buffer.toString());
    } on Object {
      // Diagnostics must never turn a handled sync failure into a crash.
    }
  }

  /// The status line only shows a summary; the full warnings go to the error
  /// log so a report can say which records were skipped and why.
  void _logWarnings({required bool automatic, required List<String> warnings}) {
    final log = _errorLog;
    if (log == null || warnings.isEmpty) return;
    final trigger = automatic ? 'automatic' : 'manual';
    final buffer = StringBuffer();
    final now = DateTime.now().toIso8601String();
    for (final warning in warnings) {
      buffer.writeln('[$now] Cloud sync warning [$trigger] $warning');
    }
    try {
      log(buffer.toString());
    } on Object {
      // Diagnostics must never turn a finished sync into a crash.
    }
  }

  void _armDebounce() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_autoPushDebounce, _fireDebouncedSync);
  }

  void _fireDebouncedSync() {
    _debounceTimer = null;
    if (!_autoGateOpen) return;
    if (_status == SyncControllerStatus.syncing || _engine.running) {
      // Another run is in flight; the local changes are still unpushed,
      // so try again after another full window instead of dropping them.
      _armDebounce();
      return;
    }
    unawaited(synchronize(automatic: true));
  }

  void _runStartupSync() {
    _startupTimer = null;
    _runAutomaticSync();
  }

  void _runAutomaticSync() {
    if (!_autoGateOpen) return;
    if (_status == SyncControllerStatus.syncing || _engine.running) return;
    _lastAutoPullAt = DateTime.now();
    unawaited(
      synchronize(
        mode: _engine.pendingCount > 0
            ? SyncMode.pushAndPull
            : SyncMode.pullOnly,
        automatic: true,
      ),
    );
  }

  void _scheduleRetry() {
    if (!_autoGateOpen || _retryDelays.isEmpty) return;
    _retryTimer?.cancel();
    final index = _retryAttempt < _retryDelays.length
        ? _retryAttempt
        : _retryDelays.length - 1;
    _retryAttempt++;
    _retryTimer = Timer(_retryDelays[index], _fireRetry);
  }

  void _fireRetry() {
    _retryTimer = null;
    if (!_autoGateOpen) return;
    if (_status == SyncControllerStatus.syncing || _engine.running) {
      _scheduleRetry();
      return;
    }
    _runAutomaticSync();
  }

  void _resetRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAttempt = 0;
  }

  void _handleRemoteChange() {
    if (_disposed) return;
    _remoteDataEpoch++;
    _notify();
  }

  void _cancelAutoTimers() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _startupTimer?.cancel();
    _startupTimer = null;
    _resetRetry();
  }

  Future<void> _reconcileSystemSchedule() async {
    final revision = ++_scheduleRevision;
    // An explicit opt-out always wins, but a retryable restore failure is not
    // a definitive sign-out. Preserve any existing Windows task while the
    // session is still being resolved so a temporary outage cannot silently
    // disable future background recovery.
    final explicitlyDisabled = !autoSyncEnabled;
    final sessionStillRecoverable =
        _accountSession.status == AccountSessionStatus.restoring ||
        _accountSession.restoreRetryAvailable;
    if (!explicitlyDisabled && sessionStillRecoverable) return;
    final shouldBeActive = _autoGateOpen;
    final desiredSchedule = schedule;
    try {
      if (!shouldBeActive) {
        await _cancelSystemSchedule?.call();
        if (revision != _scheduleRevision || _disposed) return;
        _nextScheduledAt = null;
        _registeredSchedule = null;
        _systemScheduleActive = false;
      } else {
        if (_systemScheduleActive && _registeredSchedule == desiredSchedule) {
          return;
        }
        final nextScheduledAt = await _configureSystemSchedule?.call(
          desiredSchedule,
        );
        if (revision != _scheduleRevision || _disposed) return;
        _nextScheduledAt = nextScheduledAt;
        _registeredSchedule = desiredSchedule;
        _systemScheduleActive = true;
      }
      _scheduleError = null;
    } on Object catch (error) {
      if (revision != _scheduleRevision || _disposed) return;
      _nextScheduledAt = null;
      _registeredSchedule = null;
      _systemScheduleActive = false;
      _scheduleError = AppStrings.current.syncScheduleUnavailable;
      debugPrint('Failed to configure background sync: $error');
    }
    _notify();
  }

  void _handleAccountChanged() {
    if (_disposed) return;
    final nextAccountId = _accountSession.account?.id;
    final switched = nextAccountId != _observedAccountId;
    if (!switched) {
      // Refreshes notify without changing identity; keep the message.
      if (!_autoGateOpen) _cancelAutoTimers();
      unawaited(_reconcileSystemSchedule());
      if (_accountSession.signedIn &&
          _status == SyncControllerStatus.signedOut) {
        _status = SyncControllerStatus.idle;
        _notify();
      }
      return;
    }
    _observedAccountId = nextAccountId;
    // Logout or account switch aborts the in-flight run at its next
    // checkpoint and clears everything the previous account produced.
    _generation++;
    _cancelAutoTimers();
    _lastAutoPullAt = null;
    _status = _accountSession.signedIn
        ? SyncControllerStatus.idle
        : SyncControllerStatus.signedOut;
    _message = null;
    _lastResult = null;
    // A sign-in completed (interactive login or the startup restore
    // finishing): the constructor's startup timer may already have fired
    // while still signed out and silently dropped its run, so schedule a
    // fresh one. _runStartupSync re-validates the gate when it fires.
    if (nextAccountId != null && autoSyncEnabled) {
      _startupTimer = Timer(_startupDelay, _runStartupSync);
    }
    unawaited(_reconcileSystemSchedule());
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _scheduleRevision++;
    _cancelAutoTimers();
    if (identical(_engine.onRemoteChange, _handleRemoteChange)) {
      _engine.onRemoteChange = null;
    }
    _accountSession.removeListener(_handleAccountChanged);
    super.dispose();
  }
}
