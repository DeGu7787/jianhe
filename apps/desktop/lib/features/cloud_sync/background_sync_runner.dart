import '../account/account_session_controller.dart';
import '../account/account_api.dart';
import 'sync_engine.dart';

typedef BackgroundSyncCriticalSection =
    Future<T> Function<T>(Future<T> Function() action);

Future<T> _runBackgroundSyncDirectly<T>(Future<T> Function() action) =>
    action();

enum BackgroundSyncOutcome {
  completed(0),
  skipped(0),
  retryableFailure(2),
  terminalFailure(1);

  const BackgroundSyncOutcome(this.exitCode);
  final int exitCode;
}

class BackgroundSyncRunner {
  BackgroundSyncRunner({
    required AccountSessionController accountSession,
    required SyncEngine engine,
    required bool Function() autoSyncEnabled,
    List<Duration> retryDelays = const <Duration>[
      Duration(seconds: 30),
      Duration(minutes: 1),
      Duration(minutes: 2),
    ],
    Future<void> Function(Duration duration)? delay,
    BackgroundSyncCriticalSection? syncCriticalSection,
  }) : _accountSession = accountSession,
       _engine = engine,
       _autoSyncEnabled = autoSyncEnabled,
       _retryDelays = List.unmodifiable(retryDelays),
       _delay = delay ?? Future<void>.delayed,
       _syncCriticalSection = syncCriticalSection ?? _runBackgroundSyncDirectly;

  final AccountSessionController _accountSession;
  final SyncEngine _engine;
  final bool Function() _autoSyncEnabled;
  final List<Duration> _retryDelays;
  final Future<void> Function(Duration duration) _delay;
  final BackgroundSyncCriticalSection _syncCriticalSection;

  Future<BackgroundSyncOutcome> runOnce() async {
    var outcome = await _runAttempt();
    for (final retryDelay in _retryDelays) {
      if (outcome != BackgroundSyncOutcome.retryableFailure) return outcome;
      await _delay(retryDelay);
      outcome = await _runAttempt(retryingRestore: true);
    }
    return outcome;
  }

  Future<BackgroundSyncOutcome> _runAttempt({
    bool retryingRestore = false,
  }) async {
    if (!_autoSyncEnabled()) return BackgroundSyncOutcome.skipped;
    if (retryingRestore && _accountSession.restoreRetryAvailable) {
      await _accountSession.retryRestore();
    } else {
      await _accountSession.initialize();
    }
    if (!_accountSession.signedIn) {
      return _accountSession.restoreRetryAvailable
          ? BackgroundSyncOutcome.retryableFailure
          : BackgroundSyncOutcome.skipped;
    }
    final account = _accountSession.account;
    if (!(account?.entitlement.hasCloudBackupAccess ?? false)) {
      return BackgroundSyncOutcome.skipped;
    }
    try {
      await _syncCriticalSection(() {
        // The setting can change while this process waits behind another
        // sync. Recheck after acquiring the lock so a queued worker respects
        // the user's opt-out before it performs any network request.
        if (!_autoSyncEnabled()) throw const SyncCancelledException();
        return _engine.synchronize(
          accountId: account!.id,
          mode: _engine.pendingCount > 0 && account.entitlement.isVip
              ? SyncMode.pushAndPull
              : SyncMode.pullOnly,
          cancelled: () => !_autoSyncEnabled(),
        );
      });
      return BackgroundSyncOutcome.completed;
    } on SyncCancelledException {
      return BackgroundSyncOutcome.skipped;
    } on AccountApiException catch (error) {
      return error.retryable
          ? BackgroundSyncOutcome.retryableFailure
          : BackgroundSyncOutcome.terminalFailure;
    } on Object {
      return BackgroundSyncOutcome.terminalFailure;
    }
  }
}
