import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_core/jianhe_core.dart';
import 'package:jianhe_desktop/features/account/account_api.dart';
import 'package:jianhe_desktop/features/account/account_models.dart';
import 'package:jianhe_desktop/features/account/account_session_controller.dart';
import 'package:jianhe_desktop/features/account/refresh_token_store.dart';
import 'package:jianhe_desktop/features/cloud_sync/sync_controller.dart';
import 'package:jianhe_desktop/features/cloud_sync/sync_engine.dart';
import 'package:jianhe_desktop/features/cloud_sync/sync_models.dart';
import 'package:jianhe_desktop/features/cloud_sync/sync_schedule.dart';
import 'package:jianhe_storage/jianhe_storage.dart';

import 'fake_sync_api.dart';

void main() {
  Future<SyncController> buildReadyController(
    AccountSessionController account, {
    required FakeSyncApi api,
    required JianheStorageDatabase storage,
    bool Function()? autoSyncEnabled,
    void Function(bool value)? setAutoSyncEnabled,
    SyncSchedule Function()? syncSchedule,
    void Function(SyncSchedule value)? setSyncSchedule,
    ({int hour, int minute}) Function()? dailySyncTime,
    Future<DateTime?> Function(SyncSchedule value)? configureSystemSchedule,
    Future<void> Function()? cancelSystemSchedule,
    SyncCriticalSection? syncCriticalSection,
    SyncErrorLog? errorLog,
    Duration startupDelay = const Duration(hours: 1),
    List<Duration> retryDelays = const <Duration>[Duration(seconds: 30)],
  }) async {
    final engine = SyncEngine(
      storage: storage,
      api: api,
      authorizedRequest: <T>(Future<T> Function(String accessToken) action) =>
          action('access'),
    );
    final controller = SyncController(
      accountSession: account,
      engine: engine,
      autoSyncEnabled: autoSyncEnabled,
      setAutoSyncEnabled: setAutoSyncEnabled,
      syncSchedule: syncSchedule,
      setSyncSchedule: setSyncSchedule,
      dailySyncTime: dailySyncTime,
      configureSystemSchedule: configureSystemSchedule,
      cancelSystemSchedule: cancelSystemSchedule,
      syncCriticalSection: syncCriticalSection,
      errorLog: errorLog,
      startupDelay: startupDelay,
      retryDelays: retryDelays,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  test('synchronization while signed out is blocked with a hint', () async {
    final account = await _signedOut();
    addTearDown(account.dispose);
    final api = FakeSyncApi();
    final engine = SyncEngine(
      storage: JianheStorageDatabase.inMemory(),
      api: api,
      authorizedRequest: <T>(Future<T> Function(String accessToken) action) =>
          action('access'),
    );
    final controller = SyncController(accountSession: account, engine: engine);
    addTearDown(controller.dispose);

    expect(controller.canSync, isFalse);
    expect(controller.missingPrerequisite, isNotNull);
    await controller.synchronize();

    expect(controller.status, SyncControllerStatus.signedOut);
    expect(api.stateCalls, 0);
  });

  test('free accounts do not start unavailable cloud sync', () async {
    final account = await _signedIn(vip: false);
    addTearDown(account.dispose);
    final api = FakeSyncApi();
    final controller = await buildReadyController(
      account,
      api: api,
      storage: JianheStorageDatabase.inMemory(),
    );

    expect(controller.canSync, isFalse);
    expect(controller.missingPrerequisite, '开通 VIP 后即可使用多设备同步。');
    await controller.synchronize();

    expect(controller.status, SyncControllerStatus.idle);
    expect(api.stateCalls, 0);
  });

  test('successful run reports counts and returns to idle', () async {
    final account = await _signedIn(vip: true);
    addTearDown(account.dispose);
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('pull_cursor:account-id', '10');
    await storage.items.save(
      JianheItem.create(
        type: ItemType.snippet,
        title: '本地条目',
        content: '正文',
        now: DateTime.utc(2026, 9, 10, 8),
      ),
    );
    final api = FakeSyncApi();
    final controller = await buildReadyController(
      account,
      api: api,
      storage: storage,
    );

    await controller.synchronize();

    expect(controller.status, SyncControllerStatus.idle);
    expect(controller.syncing, isFalse);
    expect(controller.lastResult!.pushedCount, 1);
    expect(controller.message, isNull);
    expect(controller.pendingCount, 0);
    expect(controller.lastSyncAt, isNotNull);
    expect(api.pushCalls, hasLength(1));
  });

  test('out-of-window account recovers with a completion message', () async {
    final account = await _signedIn(vip: true);
    addTearDown(account.dispose);
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('pull_cursor:account-id', '100');
    final api = FakeSyncApi()
      ..stateResponse = SyncStateInfo(
        headSeq: 1042,
        windowStart: 930,
        quotaUsedBytes: 0,
        quotaMaxBytes: 200 << 20,
      )
      ..snapshotQueue.add(
        SyncSnapshotResponse(changes: const <SyncPullChange>[], headSeq: 1042),
      );
    final controller = await buildReadyController(
      account,
      api: api,
      storage: storage,
    );

    await controller.synchronize();

    expect(controller.status, SyncControllerStatus.idle);
    expect(controller.message, isNull);
    expect(controller.lastResult, isNotNull);
    expect(api.snapshotCalls, hasLength(1));
  });

  test('logout during a run cancels it silently', () async {
    final account = await _signedIn(vip: true);
    addTearDown(account.dispose);
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('pull_cursor:account-id', '10');
    await storage.items.save(
      JianheItem.create(
        type: ItemType.snippet,
        title: '本地条目',
        content: '正文',
        now: DateTime.utc(2026, 9, 10, 8),
      ),
    );
    final gate = Completer<void>();
    final api = FakeSyncApi()
      ..pushHook = (changes) async {
        await gate.future;
        return SyncPushResponse(
          headSeq: 11,
          results: <SyncPushResult>[
            for (final change in changes)
              SyncPushResult(
                entityType: change.entityType,
                entityId: change.entityId,
                accepted: true,
                changeSeq: 12,
              ),
          ],
        );
      };
    final controller = await buildReadyController(
      account,
      api: api,
      storage: storage,
    );

    final running = controller.synchronize();
    await _waitFor(() => controller.syncing);
    await account.logout();
    gate.complete();
    await running;

    expect(controller.status, SyncControllerStatus.signedOut);
    expect(controller.message, isNull);
    expect(controller.canSync, isFalse);
  });

  group('automatic triggers', () {
    test('debounced local changes collapse into one automatic run', () {
      fakeAsync((async) async {
        final account = await _signedIn(vip: true);
        addTearDown(account.dispose);
        final storage = JianheStorageDatabase.inMemory();
        storage.sync.writeState('pull_cursor:account-id', '10');
        await storage.items.save(
          JianheItem.create(
            type: ItemType.snippet,
            title: '本地条目',
            content: '正文',
            now: DateTime.utc(2026, 9, 10, 8),
          ),
        );
        final api = FakeSyncApi();
        var enabled = true;
        final controller = await buildReadyController(
          account,
          api: api,
          storage: storage,
          autoSyncEnabled: () => enabled,
          setAutoSyncEnabled: (value) => enabled = value,
        );

        controller.notifyLocalChanged();
        controller.notifyLocalChanged();
        controller.notifyLocalChanged();
        async.elapse(const Duration(seconds: 20));
        expect(api.stateCalls, 0);
        async.elapse(const Duration(seconds: 15));
        await _settle(controller, async);

        expect(controller.syncing, isFalse);
        expect(controller.message, isNull);
        expect(api.pushCalls, hasLength(1));
        expect(api.pullCalls, hasLength(1));
        expect(controller.pendingCount, 0);
      });
    });

    test('a change landing while a run is busy re-arms the debounce', () {
      fakeAsync((async) async {
        final account = await _signedIn(vip: true);
        addTearDown(account.dispose);
        final storage = JianheStorageDatabase.inMemory();
        storage.sync.writeState('pull_cursor:account-id', '10');
        final first = JianheItem.create(
          type: ItemType.snippet,
          title: '第一条',
          content: 'a',
          now: DateTime.utc(2026, 9, 10, 8),
        );
        await storage.items.save(first);
        final gate = Completer<void>();
        final api = FakeSyncApi()
          ..pushHook = (changes) async {
            await gate.future;
            return SyncPushResponse(
              headSeq: 20,
              results: <SyncPushResult>[
                for (final change in changes)
                  SyncPushResult(
                    entityType: change.entityType,
                    entityId: change.entityId,
                    accepted: true,
                    changeSeq: 21,
                  ),
              ],
            );
          };
        var enabled = true;
        final controller = await buildReadyController(
          account,
          api: api,
          storage: storage,
          autoSyncEnabled: () => enabled,
          setAutoSyncEnabled: (value) => enabled = value,
        );

        controller.notifyLocalChanged();
        async.elapse(const Duration(seconds: 30));
        await _settle(controller, async);
        expect(controller.syncing, isTrue);

        final second = JianheItem.create(
          type: ItemType.snippet,
          title: '第二条',
          content: 'b',
          now: DateTime.utc(2026, 9, 10, 8, 1),
        );
        await storage.items.save(second);
        controller.notifyLocalChanged();
        gate.complete();
        await _settle(controller, async);
        expect(controller.syncing, isFalse);
        expect(api.pushCalls, hasLength(1));
        expect(api.pushCalls.single.changes.map((change) => change.entityId), [
          first.id,
        ]);

        async.elapse(const Duration(seconds: 30));
        await _settle(controller, async);
        expect(controller.syncing, isFalse);
        expect(api.pushCalls, hasLength(2));
        expect(api.pushCalls.last.changes.map((change) => change.entityId), [
          second.id,
        ]);
        expect(controller.pendingCount, 0);
      });
    });

    test('foreground wakes throttle to one pull per interval', () {
      fakeAsync((async) async {
        final account = await _signedIn(vip: true);
        addTearDown(account.dispose);
        final api = FakeSyncApi();
        var enabled = true;
        final foregroundStorage = JianheStorageDatabase.inMemory();
        foregroundStorage.sync.writeState('pull_cursor:account-id', '10');
        final controller = await buildReadyController(
          account,
          api: api,
          storage: foregroundStorage,
          autoSyncEnabled: () => enabled,
          setAutoSyncEnabled: (value) => enabled = value,
        );

        controller.notifyForeground();
        await _settle(controller, async);
        expect(api.pullCalls, hasLength(1));
        expect(api.pushCalls, isEmpty);

        controller.notifyForeground();
        controller.notifyForeground();
        await _settle(controller, async);
        expect(api.pullCalls, hasLength(1));

        async.elapse(const Duration(minutes: 5, seconds: 1));
        controller.notifyForeground();
        await _settle(controller, async);
        expect(api.pullCalls, hasLength(2));
      });
    });

    test('switching auto sync off silences every trigger', () {
      fakeAsync((async) async {
        final account = await _signedIn(vip: true);
        addTearDown(account.dispose);
        final api = FakeSyncApi();
        var enabled = true;
        final controller = await buildReadyController(
          account,
          api: api,
          storage: JianheStorageDatabase.inMemory(),
          autoSyncEnabled: () => enabled,
          setAutoSyncEnabled: (value) => enabled = value,
        );

        controller.setAutoSyncEnabled(false);
        expect(enabled, isFalse);
        expect(controller.autoSyncEnabled, isFalse);

        controller.notifyLocalChanged();
        controller.notifyForeground();
        unawaited(controller.requestAutomaticSync());
        async.elapse(const Duration(minutes: 10));
        await _settle(controller, async);
        expect(api.stateCalls, 0);
        expect(api.pullCalls, isEmpty);
        expect(api.pushCalls, isEmpty);
      });
    });

    test('a queued automatic run honors an opt-out before starting', () async {
      final account = await _signedIn(vip: true);
      addTearDown(account.dispose);
      final storage = JianheStorageDatabase.inMemory();
      addTearDown(storage.close);
      storage.sync.writeState('pull_cursor:account-id', '10');
      final api = FakeSyncApi();
      final lockEntered = Completer<void>();
      final releaseLock = Completer<void>();
      var enabled = true;

      Future<T> waitForLock<T>(Future<T> Function() action) async {
        lockEntered.complete();
        await releaseLock.future;
        return action();
      }

      final controller = await buildReadyController(
        account,
        api: api,
        storage: storage,
        autoSyncEnabled: () => enabled,
        setAutoSyncEnabled: (value) => enabled = value,
        syncCriticalSection: waitForLock,
      );

      final run = controller.requestAutomaticSync();
      await lockEntered.future;
      controller.setAutoSyncEnabled(false);
      releaseLock.complete();
      await run;

      expect(controller.status, SyncControllerStatus.idle);
      expect(controller.message, isNull);
      expect(api.stateCalls, 0);
      expect(api.pullCalls, isEmpty);
      expect(api.pushCalls, isEmpty);
    });

    test('an opt-out does not cancel a queued manual run', () async {
      final account = await _signedIn(vip: true);
      addTearDown(account.dispose);
      final storage = JianheStorageDatabase.inMemory();
      addTearDown(storage.close);
      storage.sync.writeState('pull_cursor:account-id', '10');
      final api = FakeSyncApi();
      final lockEntered = Completer<void>();
      final releaseLock = Completer<void>();
      var enabled = true;

      Future<T> waitForLock<T>(Future<T> Function() action) async {
        lockEntered.complete();
        await releaseLock.future;
        return action();
      }

      final controller = await buildReadyController(
        account,
        api: api,
        storage: storage,
        autoSyncEnabled: () => enabled,
        setAutoSyncEnabled: (value) => enabled = value,
        syncCriticalSection: waitForLock,
      );

      final run = controller.synchronize();
      await lockEntered.future;
      controller.setAutoSyncEnabled(false);
      releaseLock.complete();
      await run;

      expect(controller.status, SyncControllerStatus.idle);
      expect(controller.message, isNull);
      expect(api.stateCalls, 1);
      expect(api.pullCalls, hasLength(1));
    });

    test('a manual run cancels the pending debounce', () {
      fakeAsync((async) async {
        final account = await _signedIn(vip: true);
        addTearDown(account.dispose);
        final storage = JianheStorageDatabase.inMemory();
        storage.sync.writeState('pull_cursor:account-id', '10');
        await storage.items.save(
          JianheItem.create(
            type: ItemType.snippet,
            title: '本地条目',
            content: '正文',
            now: DateTime.utc(2026, 9, 10, 8),
          ),
        );
        final api = FakeSyncApi();
        var enabled = true;
        final controller = await buildReadyController(
          account,
          api: api,
          storage: storage,
          autoSyncEnabled: () => enabled,
          setAutoSyncEnabled: (value) => enabled = value,
        );

        controller.notifyLocalChanged();
        await controller.synchronize();
        expect(api.stateCalls, 1);
        expect(api.pushCalls, hasLength(1));

        async.elapse(const Duration(minutes: 2));
        await _settle(controller, async);
        expect(api.stateCalls, 1);
        expect(api.pushCalls, hasLength(1));
      });
    });

    test('the system scheduler is the only periodic trigger', () {
      fakeAsync((async) async {
        final account = await _signedIn(vip: true);
        addTearDown(account.dispose);
        final storage = JianheStorageDatabase.inMemory();
        storage.sync.writeState('pull_cursor:account-id', '10');
        final api = FakeSyncApi();
        var enabled = true;
        final configured = <SyncSchedule>[];
        final controller = await buildReadyController(
          account,
          api: api,
          storage: storage,
          autoSyncEnabled: () => enabled,
          setAutoSyncEnabled: (value) => enabled = value,
          syncSchedule: () => const SyncSchedule.interval(30),
          configureSystemSchedule: (value) async {
            configured.add(value);
            return DateTime(2026, 9, 10, 9);
          },
        );

        await _settle(controller, async);
        expect(configured, const <SyncSchedule>[SyncSchedule.interval(30)]);
        expect(controller.nextScheduledAt, DateTime(2026, 9, 10, 9));

        async.elapse(const Duration(hours: 2));
        await _settle(controller, async);
        expect(api.pullCalls, isEmpty);
      });
    });

    test('an older schedule result cannot overwrite the latest one', () async {
      final account = await _signedIn(vip: true);
      addTearDown(account.dispose);
      final storage = JianheStorageDatabase.inMemory();
      addTearDown(storage.close);
      final requests =
          <({SyncSchedule schedule, Completer<DateTime?> completion})>[];
      var schedule = const SyncSchedule.interval(15);
      final controller = await buildReadyController(
        account,
        api: FakeSyncApi(),
        storage: storage,
        autoSyncEnabled: () => true,
        syncSchedule: () => schedule,
        setSyncSchedule: (value) => schedule = value,
        configureSystemSchedule: (value) {
          final completion = Completer<DateTime?>();
          requests.add((schedule: value, completion: completion));
          return completion.future;
        },
      );
      await pumpEventQueue();

      controller.setSchedule(const SyncSchedule.daily(hour: 8, minute: 45));
      await pumpEventQueue();
      expect(requests.map((request) => request.schedule), <SyncSchedule>[
        const SyncSchedule.interval(15),
        const SyncSchedule.daily(hour: 8, minute: 45),
      ]);

      final latestRun = DateTime.now().add(const Duration(days: 1));
      requests.last.completion.complete(latestRun);
      await pumpEventQueue();
      expect(controller.nextScheduledAt, latestRun);

      requests.first.completion.complete(DateTime(2026, 9, 17, 10, 15));
      await pumpEventQueue();
      expect(controller.nextScheduledAt, latestRun);
    });

    test('disabling sync invalidates an unfinished configuration', () async {
      final account = await _signedIn(vip: true);
      addTearDown(account.dispose);
      final storage = JianheStorageDatabase.inMemory();
      addTearDown(storage.close);
      final configuration = Completer<DateTime?>();
      var enabled = true;
      var cancellations = 0;
      final controller = await buildReadyController(
        account,
        api: FakeSyncApi(),
        storage: storage,
        autoSyncEnabled: () => enabled,
        setAutoSyncEnabled: (value) => enabled = value,
        configureSystemSchedule: (_) => configuration.future,
        cancelSystemSchedule: () async {
          cancellations++;
        },
      );
      await pumpEventQueue();

      controller.setAutoSyncEnabled(false);
      await pumpEventQueue();
      expect(cancellations, 1);
      expect(controller.nextScheduledAt, isNull);

      configuration.complete(DateTime(2026, 9, 17, 10, 15));
      await pumpEventQueue();
      expect(controller.nextScheduledAt, isNull);
      expect(controller.scheduleError, isNull);
    });

    test(
      'a retryable session restore failure preserves the system task',
      () async {
        final accountApi = _RetryableRestoreAccountApi();
        final account = AccountSessionController(
          api: accountApi,
          tokenStore: _MemoryTokenStore()
            ..value = const StoredRefreshSession(refreshToken: 'refresh'),
          deviceName: 'TEST-PC',
        );
        addTearDown(account.dispose);
        await account.initialize();
        expect(account.restoreRetryAvailable, isTrue);

        final storage = JianheStorageDatabase.inMemory();
        addTearDown(storage.close);
        var cancellations = 0;
        var configurations = 0;
        final nextRun = DateTime.now().add(const Duration(days: 1));
        final controller = await buildReadyController(
          account,
          api: FakeSyncApi(),
          storage: storage,
          autoSyncEnabled: () => true,
          configureSystemSchedule: (_) async {
            configurations++;
            return nextRun;
          },
          cancelSystemSchedule: () async {
            cancellations++;
          },
        );
        await pumpEventQueue();

        expect(cancellations, 0);
        expect(configurations, 0);

        await account.retryRestore();
        await pumpEventQueue();

        expect(account.signedIn, isTrue);
        expect(configurations, 1);
        expect(cancellations, 0);
        expect(controller.nextScheduledAt, nextRun);
      },
    );

    test('explicit opt-out cancels a task during retryable restore', () async {
      final account = AccountSessionController(
        api: _RetryableRestoreAccountApi(),
        tokenStore: _MemoryTokenStore()
          ..value = const StoredRefreshSession(refreshToken: 'refresh'),
        deviceName: 'TEST-PC',
      );
      addTearDown(account.dispose);
      await account.initialize();
      expect(account.restoreRetryAvailable, isTrue);

      final storage = JianheStorageDatabase.inMemory();
      addTearDown(storage.close);
      var enabled = true;
      var cancellations = 0;
      final controller = await buildReadyController(
        account,
        api: FakeSyncApi(),
        storage: storage,
        autoSyncEnabled: () => enabled,
        setAutoSyncEnabled: (value) => enabled = value,
        cancelSystemSchedule: () async {
          cancellations++;
        },
      );
      await pumpEventQueue();
      expect(cancellations, 0);

      controller.setAutoSyncEnabled(false);
      await pumpEventQueue();

      expect(enabled, isFalse);
      expect(cancellations, 1);
    });

    test('a terminal restore failure cancels the system task', () async {
      final account = AccountSessionController(
        api: _TerminalRestoreAccountApi(),
        tokenStore: _MemoryTokenStore()
          ..value = const StoredRefreshSession(refreshToken: 'refresh'),
        deviceName: 'TEST-PC',
      );
      addTearDown(account.dispose);
      await account.initialize();
      expect(account.signedIn, isFalse);
      expect(account.restoreRetryAvailable, isFalse);

      final storage = JianheStorageDatabase.inMemory();
      addTearDown(storage.close);
      var cancellations = 0;
      await buildReadyController(
        account,
        api: FakeSyncApi(),
        storage: storage,
        autoSyncEnabled: () => true,
        cancelSystemSchedule: () async {
          cancellations++;
        },
      );
      await pumpEventQueue();

      expect(cancellations, 1);
    });

    test('a scheduled IPC request pushes pending changes before pulling', () {
      fakeAsync((async) async {
        final account = await _signedIn(vip: true);
        addTearDown(account.dispose);
        final storage = JianheStorageDatabase.inMemory();
        storage.sync.writeState('pull_cursor:account-id', '10');
        await storage.items.save(
          JianheItem.create(
            type: ItemType.snippet,
            title: 'CLI 写入',
            content: '等待周期任务发现',
            now: DateTime.utc(2026, 9, 10, 8),
          ),
        );
        final api = FakeSyncApi();
        var enabled = true;
        final controller = await buildReadyController(
          account,
          api: api,
          storage: storage,
          autoSyncEnabled: () => enabled,
          setAutoSyncEnabled: (value) => enabled = value,
        );

        unawaited(controller.requestAutomaticSync());
        await _settle(controller, async);

        expect(api.pushCalls, hasLength(1));
        expect(api.pullCalls, hasLength(1));
        expect(controller.pendingCount, 0);
      });
    });

    test('enabling automatic sync starts an immediate run', () {
      fakeAsync((async) async {
        final account = await _signedIn(vip: true);
        addTearDown(account.dispose);
        final storage = JianheStorageDatabase.inMemory();
        storage.sync.writeState('pull_cursor:account-id', '10');
        final api = FakeSyncApi();
        var enabled = false;
        final controller = await buildReadyController(
          account,
          api: api,
          storage: storage,
          autoSyncEnabled: () => enabled,
          setAutoSyncEnabled: (value) => enabled = value,
        );

        controller.setAutoSyncEnabled(true);
        async.elapse(Duration.zero);
        await _settle(controller, async);

        expect(enabled, isTrue);
        expect(api.pullCalls, hasLength(1));
      });
    });

    test('retryable automatic failures retry with backoff', () {
      fakeAsync((async) async {
        final account = await _signedIn(vip: true);
        addTearDown(account.dispose);
        final storage = JianheStorageDatabase.inMemory();
        storage.sync.writeState('pull_cursor:account-id', '10');
        final api = FakeSyncApi()
          ..pullQueue.add(
            const AccountApiException(
              code: 'NETWORK_ERROR',
              message: '暂时断网',
              retryable: true,
            ),
          );
        var enabled = true;
        final controller = await buildReadyController(
          account,
          api: api,
          storage: storage,
          autoSyncEnabled: () => enabled,
          setAutoSyncEnabled: (value) => enabled = value,
          retryDelays: const <Duration>[Duration(seconds: 30)],
        );

        controller.notifyForeground();
        await _settle(controller, async);
        expect(api.pullCalls, hasLength(1));
        expect(controller.message, isNull);

        async.elapse(const Duration(seconds: 29));
        await _settle(controller, async);
        expect(api.pullCalls, hasLength(1));

        async.elapse(const Duration(seconds: 2));
        await _settle(controller, async);
        expect(api.pullCalls, hasLength(2));
        expect(controller.lastResult, isNotNull);
      });
    });

    test('logout cancels scheduled automatic runs', () {
      fakeAsync((async) async {
        final account = await _signedIn(vip: true);
        addTearDown(account.dispose);
        final storage = JianheStorageDatabase.inMemory();
        await storage.items.save(
          JianheItem.create(
            type: ItemType.snippet,
            title: '本地条目',
            content: '正文',
            now: DateTime.utc(2026, 9, 10, 8),
          ),
        );
        final api = FakeSyncApi();
        var enabled = true;
        var cancellations = 0;
        final controller = await buildReadyController(
          account,
          api: api,
          storage: storage,
          autoSyncEnabled: () => enabled,
          setAutoSyncEnabled: (value) => enabled = value,
          cancelSystemSchedule: () async {
            cancellations++;
          },
        );

        controller.notifyLocalChanged();
        await account.logout();
        async.elapse(const Duration(minutes: 2));
        await _settle(controller, async);
        expect(api.stateCalls, 0);
        expect(controller.status, SyncControllerStatus.signedOut);
        expect(cancellations, 1);
      });
    });

    test('automatic runs fail silently, manual runs surface the error', () {
      fakeAsync((async) async {
        final account = await _signedIn(vip: true);
        addTearDown(account.dispose);
        final api = FakeSyncApi()
          ..pullQueue.add(
            AccountApiException(code: 'SERVER', message: '服务器打盹'),
          );
        var enabled = true;
        final silentStorage = JianheStorageDatabase.inMemory();
        silentStorage.sync.writeState('pull_cursor:account-id', '10');
        final controller = await buildReadyController(
          account,
          api: api,
          storage: silentStorage,
          autoSyncEnabled: () => enabled,
          setAutoSyncEnabled: (value) => enabled = value,
        );

        controller.notifyForeground();
        await _settle(controller, async);
        expect(controller.status, SyncControllerStatus.idle);
        expect(controller.message, isNull);

        api.pullQueue.add(
          AccountApiException(code: 'SERVER', message: '服务器打盹'),
        );
        await controller.synchronize();
        expect(controller.status, SyncControllerStatus.idle);
        expect(controller.message, '服务器打盹');
      });
    });

    test('manual failures show the request id and reach the error log', () {
      fakeAsync((async) async {
        final account = await _signedIn(vip: true);
        addTearDown(account.dispose);
        final storage = JianheStorageDatabase.inMemory();
        storage.sync.writeState('pull_cursor:account-id', '10');
        final api = FakeSyncApi()
          ..pullQueue.add(
            AccountApiException(
              code: 'SYNC_QUOTA_EXCEEDED',
              message: '同步空间已达到上限。',
              requestId: 'req-42',
            ),
          );
        final logged = <String>[];
        final controller = await buildReadyController(
          account,
          api: api,
          storage: storage,
          errorLog: logged.add,
        );

        await controller.synchronize();
        expect(controller.message, '同步空间已达到上限。');
        expect(logged, hasLength(1));
        expect(logged.single, contains('[manual]'));
        expect(logged.single, contains('SYNC_QUOTA_EXCEEDED'));
        expect(logged.single, contains('req-42'));
      });
    });

    test('a full cloud space is explained instead of a generic warning', () {
      fakeAsync((async) async {
        final account = await _signedIn(vip: true);
        addTearDown(account.dispose);
        final storage = JianheStorageDatabase.inMemory();
        storage.sync.writeState('pull_cursor:account-id', '10');
        await storage.items.save(
          JianheItem.create(
            type: ItemType.snippet,
            title: '新条目',
            content: '正文',
            now: DateTime.utc(2026, 9, 10, 8),
          ),
        );
        final api = FakeSyncApi()
          ..stateResponse = SyncStateInfo(
            headSeq: 10,
            windowStart: 0,
            quotaUsedBytes: 200 << 20,
            quotaMaxBytes: 200 << 20,
          )
          ..pushQueue.add(
            const AccountApiException(
              code: 'SYNC_QUOTA_EXCEEDED',
              message: '同步空间已达到上限。',
            ),
          );
        final logged = <String>[];
        final controller = await buildReadyController(
          account,
          api: api,
          storage: storage,
          errorLog: logged.add,
        );

        await controller.synchronize();
        expect(controller.message, startsWith('云同步空间已满（已用 200 MB / 200 MB）'));
        expect(controller.message, contains('有 1 项修改暂未上传'));
        expect(controller.pendingCount, 1);
        expect(logged.join(), contains('Cloud sync warning [manual] 云同步空间已满'));
      });
    });

    test('manual format errors name the malformed data', () {
      fakeAsync((async) async {
        final account = await _signedIn(vip: true);
        addTearDown(account.dispose);
        final storage = JianheStorageDatabase.inMemory();
        storage.sync.writeState('pull_cursor:account-id', '10');
        final api = FakeSyncApi()
          ..pullQueue.add(const FormatException('条目信封不是 JSON 对象。'));
        final logged = <String>[];
        final controller = await buildReadyController(
          account,
          api: api,
          storage: storage,
          errorLog: logged.add,
        );

        await controller.synchronize();
        expect(controller.message, '同步数据格式异常，请稍后重试。');
        expect(logged.single, contains('FormatException'));
      });
    });

    test('startup run pushes pending changes after the delay', () {
      fakeAsync((async) async {
        final account = await _signedIn(vip: true);
        addTearDown(account.dispose);
        final storage = JianheStorageDatabase.inMemory();
        storage.sync.writeState('pull_cursor:account-id', '10');
        await storage.items.save(
          JianheItem.create(
            type: ItemType.snippet,
            title: '本地条目',
            content: '正文',
            now: DateTime.utc(2026, 9, 10, 8),
          ),
        );
        final api = FakeSyncApi();
        var enabled = true;
        final controller = await buildReadyController(
          account,
          api: api,
          storage: storage,
          autoSyncEnabled: () => enabled,
          setAutoSyncEnabled: (value) => enabled = value,
          startupDelay: const Duration(seconds: 8),
        );

        async.elapse(const Duration(seconds: 9));
        await _settle(controller, async);
        expect(api.pushCalls, hasLength(1));
        expect(api.pullCalls, hasLength(1));
        expect(controller.pendingCount, 0);
      });
    });

    test('startup with a clean store only pulls', () {
      fakeAsync((async) async {
        final account = await _signedIn(vip: true);
        addTearDown(account.dispose);
        final api = FakeSyncApi();
        var enabled = true;
        final cleanStorage = JianheStorageDatabase.inMemory();
        cleanStorage.sync.writeState('pull_cursor:account-id', '10');
        final controller = await buildReadyController(
          account,
          api: api,
          storage: cleanStorage,
          autoSyncEnabled: () => enabled,
          setAutoSyncEnabled: (value) => enabled = value,
          startupDelay: const Duration(seconds: 8),
        );

        async.elapse(const Duration(seconds: 9));
        await _settle(controller, async);
        expect(api.pullCalls, hasLength(1));
        expect(api.pushCalls, isEmpty);
      });
    });

    test('a sign-in completing after startup schedules its own sync', () {
      fakeAsync((async) async {
        final account = await _signedOut();
        addTearDown(account.dispose);
        final api = FakeSyncApi();
        var enabled = true;
        final controller = await buildReadyController(
          account,
          api: api,
          storage: JianheStorageDatabase.inMemory(),
          autoSyncEnabled: () => enabled,
          setAutoSyncEnabled: (value) => enabled = value,
          startupDelay: const Duration(seconds: 8),
        );

        // The constructor's startup timer fires while still signed out and
        // must be a silent no-op.
        async.elapse(const Duration(seconds: 9));
        await _settle(controller, async);
        expect(api.stateCalls, 0);

        // The login (or a late session restore) flips the account id; the
        // controller must schedule a fresh startup run instead of relying
        // on the already-fired timer.
        await account.login(
          email: 'vip@example.com',
          password: 'long-password',
        );
        async.elapse(const Duration(seconds: 9));
        await _settle(controller, async);
        expect(api.stateCalls, 1);
      });
    });

    test('automatic pull applies remote changes and bumps the epoch', () {
      fakeAsync((async) async {
        final account = await _signedIn(vip: true);
        addTearDown(account.dispose);
        final storage = JianheStorageDatabase.inMemory();
        storage.sync.writeState('pull_cursor:account-id', '10');
        final remote = JianheItem.create(
          type: ItemType.snippet,
          title: '远端条目',
          content: '远端正文',
          now: DateTime.utc(2026, 9, 9),
        );
        final api = FakeSyncApi()
          ..pullQueue.add(
            SyncPullResponse(
              changes: <SyncPullChange>[
                SyncPullChange(
                  changeSeq: 12,
                  entityType: SyncEntityType.itemSnippet,
                  entityId: remote.id,
                  updatedAt: remote.updatedAt,
                  deleted: false,
                  originDeviceId: 'device-B',
                  envelope: utf8.encode(
                    jsonEncode(<String, Object?>{
                      'id': remote.id,
                      'type': remote.type.name,
                      'title': remote.title,
                      'content': remote.content,
                      'is_favorite': remote.isFavorite,
                      'rating': remote.rating,
                      'category': remote.category,
                      'sort_order': remote.sortOrder,
                      'created_at': remote.createdAt.toUtc().toIso8601String(),
                      'updated_at': remote.updatedAt.toUtc().toIso8601String(),
                    }),
                  ),
                ),
              ],
              nextCursor: 12,
              headSeq: 12,
            ),
          );
        var enabled = true;
        final controller = await buildReadyController(
          account,
          api: api,
          storage: storage,
          autoSyncEnabled: () => enabled,
          setAutoSyncEnabled: (value) => enabled = value,
        );
        expect(controller.remoteDataEpoch, 0);

        controller.notifyForeground();
        await _settle(controller, async);

        expect(controller.remoteDataEpoch, 1);
        expect(
          (await storage.items.list(type: ItemType.snippet)).single.id,
          remote.id,
        );
      });
    });
  });
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var i = 0; i < 500 && !predicate(); i++) {
    await pumpEventQueue();
  }
}

/// Drains the fake zone until the controller leaves the syncing state. The
/// engine chain is microtask-based (in-memory storage + fake api), so
/// flushing microtasks is enough; timers must be elapsed by the caller.
Future<void> _settle(SyncController controller, FakeAsync async) async {
  for (var i = 0; i < 100 && controller.syncing; i++) {
    async.flushMicrotasks();
  }
}

class _MemoryTokenStore implements RefreshTokenStore {
  StoredRefreshSession? value;

  @override
  Future<void> delete() async => value = null;

  @override
  Future<StoredRefreshSession?> read() async => value;

  @override
  Future<void> write(StoredRefreshSession session) async => value = session;
}

class _AccountApi implements AccountRemoteDataSource {
  _AccountApi({required this.vip});

  final bool vip;

  AuthSession get session => AuthSession(
    accessToken: 'access',
    accessTokenExpiresAt: DateTime.utc(2099),
    refreshToken: 'refresh',
    refreshTokenExpiresAt: DateTime.utc(2099, 2),
    account: JianheAccount(
      id: 'account-id',
      email: 'vip@example.com',
      emailVerified: false,
      entitlement: AccountEntitlement(
        plan: vip ? 'vip' : 'free',
        vipExpiresAt: vip ? DateTime.utc(2099) : null,
        cloudBackupUploadAllowed: vip,
        cloudBackupDownloadAllowed: vip,
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

class _RetryableRestoreAccountApi extends _AccountApi {
  _RetryableRestoreAccountApi() : super(vip: true);

  var _failNextRefresh = true;

  @override
  Future<AuthSession> refresh({
    required String refreshToken,
    required String idempotencyKey,
  }) async {
    if (_failNextRefresh) {
      _failNextRefresh = false;
      throw const AccountApiException(
        code: 'NETWORK_ERROR',
        message: '暂时无法连接云同步服务。',
        retryable: true,
      );
    }
    return super.refresh(
      refreshToken: refreshToken,
      idempotencyKey: idempotencyKey,
    );
  }
}

class _TerminalRestoreAccountApi extends _AccountApi {
  _TerminalRestoreAccountApi() : super(vip: true);

  @override
  Future<AuthSession> refresh({
    required String refreshToken,
    required String idempotencyKey,
  }) async {
    throw const AccountApiException(code: 'AUTH_REQUIRED', message: '登录状态已失效。');
  }
}

Future<AccountSessionController> _signedOut() async {
  return AccountSessionController(
    api: _AccountApi(vip: true),
    tokenStore: _MemoryTokenStore(),
    deviceName: 'TEST-PC',
  );
}

Future<AccountSessionController> _signedIn({required bool vip}) async {
  final controller = AccountSessionController(
    api: _AccountApi(vip: vip),
    tokenStore: _MemoryTokenStore(),
    deviceName: 'TEST-PC',
  );
  final succeeded = await controller.login(
    email: 'vip@example.com',
    password: 'long-password',
  );
  if (!succeeded) {
    fail('Test account login failed.');
  }
  return controller;
}
