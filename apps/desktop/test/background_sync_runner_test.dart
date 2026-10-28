import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/features/account/account_api.dart';
import 'package:jianhe_desktop/features/account/account_models.dart';
import 'package:jianhe_desktop/features/account/account_session_controller.dart';
import 'package:jianhe_desktop/features/account/refresh_token_store.dart';
import 'package:jianhe_desktop/features/cloud_sync/background_sync_runner.dart';
import 'package:jianhe_desktop/features/cloud_sync/sync_engine.dart';
import 'package:jianhe_storage/jianhe_storage.dart';

import 'fake_sync_api.dart';

void main() {
  Future<
    ({
      BackgroundSyncRunner runner,
      FakeSyncApi syncApi,
      JianheStorageDatabase storage,
      AccountSessionController account,
      List<Duration> delays,
    })
  >
  buildRunner({
    required List<Object?> pullQueue,
    bool Function()? autoSyncEnabled,
    BackgroundSyncCriticalSection? syncCriticalSection,
    Future<void> Function(Duration duration)? onDelay,
  }) async {
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('pull_cursor:account-id', '10');
    final syncApi = FakeSyncApi()..pullQueue.addAll(pullQueue);
    final account = AccountSessionController(
      api: _AccountApi(),
      tokenStore: _MemoryTokenStore(
        const StoredRefreshSession(refreshToken: 'refresh'),
      ),
      deviceName: 'TEST-PC',
    );
    final engine = SyncEngine(
      storage: storage,
      api: syncApi,
      authorizedRequest: account.authorizedRequest,
      serverDeviceId: () => account.device?.id,
      maxSendAttempts: 1,
      retryDelay: Duration.zero,
    );
    final delays = <Duration>[];
    final runner = BackgroundSyncRunner(
      accountSession: account,
      engine: engine,
      autoSyncEnabled: autoSyncEnabled ?? () => true,
      retryDelays: const <Duration>[
        Duration(seconds: 30),
        Duration(minutes: 1),
      ],
      delay: (duration) async {
        delays.add(duration);
        await onDelay?.call(duration);
      },
      syncCriticalSection: syncCriticalSection,
    );
    addTearDown(account.dispose);
    addTearDown(storage.close);
    return (
      runner: runner,
      syncApi: syncApi,
      storage: storage,
      account: account,
      delays: delays,
    );
  }

  test('retryable failures use the bounded background backoff', () async {
    var lockHeld = false;
    var lockEntries = 0;

    Future<T> guarded<T>(Future<T> Function() action) async {
      expect(lockHeld, isFalse);
      lockHeld = true;
      lockEntries++;
      try {
        return await action();
      } finally {
        lockHeld = false;
      }
    }

    final fixture = await buildRunner(
      pullQueue: const <Object?>[
        AccountApiException(
          code: 'NETWORK_ERROR',
          message: '暂时断网',
          retryable: true,
        ),
        AccountApiException(
          code: 'NETWORK_ERROR',
          message: '仍未恢复',
          retryable: true,
        ),
      ],
      syncCriticalSection: guarded,
      onDelay: (_) async => expect(lockHeld, isFalse),
    );

    final outcome = await fixture.runner.runOnce();

    expect(outcome, BackgroundSyncOutcome.completed);
    expect(fixture.syncApi.pullCalls, hasLength(3));
    expect(fixture.delays, const <Duration>[
      Duration(seconds: 30),
      Duration(minutes: 1),
    ]);
    expect(lockEntries, 3);
  });

  test('terminal failures are not retried', () async {
    final fixture = await buildRunner(
      pullQueue: const <Object?>[
        AccountApiException(code: 'INVALID_REQUEST', message: '请求无效'),
      ],
    );

    final outcome = await fixture.runner.runOnce();

    expect(outcome, BackgroundSyncOutcome.terminalFailure);
    expect(fixture.syncApi.pullCalls, hasLength(1));
    expect(fixture.delays, isEmpty);
  });

  test('a queued worker honors an opt-out after acquiring the lock', () async {
    final lockEntered = Completer<void>();
    final releaseLock = Completer<void>();
    var enabled = true;

    Future<T> waitForLock<T>(Future<T> Function() action) async {
      lockEntered.complete();
      await releaseLock.future;
      return action();
    }

    final fixture = await buildRunner(
      pullQueue: const <Object?>[],
      autoSyncEnabled: () => enabled,
      syncCriticalSection: waitForLock,
    );

    final run = fixture.runner.runOnce();
    await lockEntered.future;
    enabled = false;
    releaseLock.complete();
    final outcome = await run;

    expect(outcome, BackgroundSyncOutcome.skipped);
    expect(fixture.syncApi.stateCalls, 0);
    expect(fixture.syncApi.pullCalls, isEmpty);
    expect(fixture.syncApi.pushCalls, isEmpty);
    expect(fixture.delays, isEmpty);
  });
}

class _MemoryTokenStore implements RefreshTokenStore {
  _MemoryTokenStore(this.value);

  StoredRefreshSession? value;

  @override
  Future<void> delete() async => value = null;

  @override
  Future<StoredRefreshSession?> read() async => value;

  @override
  Future<void> write(StoredRefreshSession session) async => value = session;
}

class _AccountApi implements AccountRemoteDataSource {
  AuthSession get session => AuthSession(
    accessToken: 'access',
    accessTokenExpiresAt: DateTime.utc(2099),
    refreshToken: 'refresh-next',
    refreshTokenExpiresAt: DateTime.utc(2099, 2),
    account: JianheAccount(
      id: 'account-id',
      email: 'vip@example.com',
      emailVerified: false,
      entitlement: AccountEntitlement(
        plan: 'vip',
        vipExpiresAt: DateTime.utc(2099),
        cloudBackupUploadAllowed: true,
        cloudBackupDownloadAllowed: true,
      ),
    ),
    device: const AccountDevice(id: 'device-id', name: 'TEST-PC'),
  );

  @override
  Future<CurrentAccount> currentAccount({required String accessToken}) async =>
      CurrentAccount(account: session.account, device: session.device);

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
    required String deviceName,
    required String platform,
    required String appVersion,
  }) async => session;

  @override
  Future<void> logout({
    required String refreshToken,
    required String idempotencyKey,
  }) async {}

  @override
  Future<AuthSession> refresh({
    required String refreshToken,
    required String idempotencyKey,
  }) async => session;

  @override
  Future<AuthSession> register({
    required String email,
    required String password,
    required String deviceName,
    required String platform,
    required String appVersion,
  }) async => session;
}
