import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/features/account/account_api.dart';
import 'package:jianhe_desktop/features/account/account_models.dart';
import 'package:jianhe_desktop/features/account/account_panel.dart';
import 'package:jianhe_desktop/features/account/account_session_controller.dart';
import 'package:jianhe_desktop/features/account/refresh_token_store.dart';
import 'package:jianhe_desktop/features/cloud_sync/sync_controller.dart';
import 'package:jianhe_desktop/features/cloud_sync/sync_engine.dart';
import 'package:jianhe_desktop/features/cloud_sync/sync_schedule.dart';
import 'package:jianhe_storage/jianhe_storage.dart';

import 'fake_sync_api.dart';

void main() {
  testWidgets(
    'user can switch to registration and see a signed-in VIP account',
    (tester) async {
      tester.view.physicalSize = const Size(450, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = AccountSessionController(
        api: _VipAccountApi(),
        tokenStore: _MemoryTokenStore(),
        deviceName: 'DESKTOP-TEST',
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AccountPanel(controller: controller)),
        ),
      );

      expect(find.text('登录笺盒账号'), findsOneWidget);
      expect(find.byKey(const Key('account-google-login')), findsNothing);
      expect(find.text('使用微信扫码登录'), findsNothing);
      await tester.tap(find.byKey(const Key('account-mode-toggle')));
      await tester.pump();
      expect(find.text('创建笺盒账号'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('account-email-field')),
        'vip@example.com',
      );
      await tester.enterText(
        find.byKey(const Key('account-password-field')),
        'long-password',
      );
      await tester.tap(find.byKey(const Key('account-submit')));
      await tester.pumpAndSettle();

      expect(find.text('vip@example.com'), findsOneWidget);
      expect(find.text('绑定 Google 账号'), findsNothing);
      expect(find.text('绑定微信账号'), findsNothing);
      expect(find.text('VIP 服务已开通'), findsOneWidget);
      // The retired cloud-backup card and the dropped sync-key card must
      // not come back.
      expect(find.byKey(const Key('cloud-backup-card')), findsNothing);
      expect(find.byKey(const Key('sync-key-card')), findsNothing);
      expect(find.textContaining('恢复密钥'), findsNothing);
    },
  );

  testWidgets('logout signs out directly without a backup dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(450, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AccountSessionController(
      api: _VipAccountApi(),
      tokenStore: _MemoryTokenStore(),
      deviceName: 'DESKTOP-TEST',
    );
    addTearDown(controller.dispose);
    await controller.register(
      email: 'vip@example.com',
      password: 'long-password',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AccountPanel(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.dragUntilVisible(
      find.byKey(const Key('account-logout')),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-logout')));
    await tester.pumpAndSettle();
    expect(controller.signedIn, isFalse);
    expect(find.byKey(const Key('cloud-backup-logout-dialog')), findsNothing);
  });

  testWidgets('Google-linked account does not offer redundant binding', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(450, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AccountSessionController(
      api: _VipAccountApi(googleLinked: true),
      tokenStore: _MemoryTokenStore(),
      deviceName: 'DESKTOP-TEST',
    );
    addTearDown(controller.dispose);
    await controller.login(
      email: 'google@example.com',
      password: 'long-password',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AccountPanel(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('google@example.com'), findsOneWidget);
    expect(find.text('绑定 Google 账号'), findsNothing);
  });

  testWidgets('the sync card exposes the auto sync switch', (tester) async {
    tester.view.physicalSize = const Size(450, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AccountSessionController(
      api: _VipAccountApi(),
      tokenStore: _MemoryTokenStore(),
      deviceName: 'DESKTOP-TEST',
    );
    addTearDown(controller.dispose);
    await controller.login(email: 'vip@example.com', password: 'long-password');
    var autoEnabled = true;
    final syncController = SyncController(
      accountSession: controller,
      engine: SyncEngine(
        storage: JianheStorageDatabase.inMemory(),
        api: FakeSyncApi(),
        authorizedRequest: <T>(Future<T> Function(String accessToken) action) =>
            action('access'),
      ),
      autoSyncEnabled: () => autoEnabled,
      setAutoSyncEnabled: (value) => autoEnabled = value,
    );
    addTearDown(syncController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountPanel(
            controller: controller,
            syncController: syncController,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('auto-sync-switch')));
    await tester.pumpAndSettle();
    expect(find.text('自动同步'), findsOneWidget);
    expect(
      tester.widget<Switch>(find.byKey(const Key('auto-sync-switch'))).value,
      isTrue,
    );
    expect(find.byKey(const Key('sync-schedule')), findsOneWidget);
    expect(find.text('每 15 分钟'), findsOneWidget);

    await tester.tap(find.byKey(const Key('auto-sync-switch')));
    await tester.pump();
    expect(autoEnabled, isFalse);
    expect(
      tester.widget<Switch>(find.byKey(const Key('auto-sync-switch'))).value,
      isFalse,
    );
  });

  testWidgets('switching back to daily sync restores the saved time', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(450, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AccountSessionController(
      api: _VipAccountApi(),
      tokenStore: _MemoryTokenStore(),
      deviceName: 'DESKTOP-TEST',
    );
    addTearDown(controller.dispose);
    await controller.login(email: 'vip@example.com', password: 'long-password');
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    var schedule = const SyncSchedule.interval(30);
    var savedDailyTime = (hour: 8, minute: 45);
    final navigatorKey = GlobalKey<NavigatorState>();
    final dialogPresenter = _RecordingDialogPresenter(navigatorKey);
    final syncController = SyncController(
      accountSession: controller,
      engine: SyncEngine(
        storage: storage,
        api: FakeSyncApi(),
        authorizedRequest: <T>(Future<T> Function(String accessToken) action) =>
            action('access'),
      ),
      autoSyncEnabled: () => true,
      syncSchedule: () => schedule,
      setSyncSchedule: (value) {
        schedule = value;
        if (value.mode == SyncScheduleMode.daily) {
          savedDailyTime = (hour: value.dailyHour!, minute: value.dailyMinute!);
        }
      },
      dailySyncTime: () => savedDailyTime,
      startupDelay: Duration.zero,
    );
    addTearDown(syncController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: AccountPanel(
            controller: controller,
            syncController: syncController,
            dialogPresenter: dialogPresenter.call,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('sync-schedule')));
    await tester.tap(find.byKey(const Key('sync-schedule')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每天定时').last);
    await tester.pumpAndSettle();

    expect(dialogPresenter.callCount, 1);
    expect(dialogPresenter.frameKey, const Key('sync-daily-time-dialog-frame'));
    expect(find.byKey(const Key('sync-daily-time-dialog')), findsOneWidget);
    expect(find.byType(CupertinoDatePicker), findsOneWidget);
    expect(find.byType(TimePickerDialog), findsNothing);
    expect(schedule, const SyncSchedule.interval(30));

    final picker = tester.widget<CupertinoDatePicker>(
      find.byKey(const Key('sync-daily-time-picker')),
    );
    expect(picker.use24hFormat, isTrue);
    expect(picker.initialDateTime.hour, 8);
    expect(picker.initialDateTime.minute, 45);
    picker.onDateTimeChanged(DateTime(2000, 1, 1, 9, 20));
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    expect(schedule, const SyncSchedule.daily(hour: 9, minute: 20));
    expect(find.text('09:20'), findsOneWidget);
  });

  testWidgets('daily time picker wheel accepts mouse dragging', (tester) async {
    tester.view.physicalSize = const Size(450, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AccountSessionController(
      api: _VipAccountApi(),
      tokenStore: _MemoryTokenStore(),
      deviceName: 'DESKTOP-TEST',
    );
    addTearDown(controller.dispose);
    await controller.login(email: 'vip@example.com', password: 'long-password');
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    var schedule = const SyncSchedule.interval(30);
    var savedDailyTime = (hour: 8, minute: 45);
    final navigatorKey = GlobalKey<NavigatorState>();
    final dialogPresenter = _RecordingDialogPresenter(navigatorKey);
    final syncController = SyncController(
      accountSession: controller,
      engine: SyncEngine(
        storage: storage,
        api: FakeSyncApi(),
        authorizedRequest: <T>(Future<T> Function(String accessToken) action) =>
            action('access'),
      ),
      autoSyncEnabled: () => true,
      syncSchedule: () => schedule,
      setSyncSchedule: (value) {
        schedule = value;
        if (value.mode == SyncScheduleMode.daily) {
          savedDailyTime = (hour: value.dailyHour!, minute: value.dailyMinute!);
        }
      },
      dailySyncTime: () => savedDailyTime,
      startupDelay: Duration.zero,
    );
    addTearDown(syncController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: AccountPanel(
            controller: controller,
            syncController: syncController,
            dialogPresenter: dialogPresenter.call,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('sync-schedule')));
    await tester.tap(find.byKey(const Key('sync-schedule')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每天定时').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sync-daily-time-dialog')), findsOneWidget);

    // ScrollBehavior 默认不把鼠标算作拖动设备；慢速逐帧上拖小时滚轮三行。
    final hourPicker = find.byType(CupertinoPicker).first;
    final itemExtent = tester.widget<CupertinoPicker>(hourPicker).itemExtent;
    final dragDistance = itemExtent * 3;
    final gesture = await tester.startGesture(
      tester.getCenter(hourPicker),
      kind: PointerDeviceKind.mouse,
    );
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(Offset(0, -dragDistance / 6));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();
    expect(schedule, const SyncSchedule.daily(hour: 11, minute: 45));
    expect(find.text('11:45'), findsOneWidget);
  });

  testWidgets('free accounts see a friendly VIP sync explanation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(450, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AccountSessionController(
      api: _VipAccountApi(vip: false, downloadAllowed: false),
      tokenStore: _MemoryTokenStore(),
      deviceName: 'DESKTOP-TEST',
    );
    addTearDown(controller.dispose);
    await controller.login(
      email: 'free@example.com',
      password: 'long-password',
    );
    final syncController = SyncController(
      accountSession: controller,
      engine: SyncEngine(
        storage: JianheStorageDatabase.inMemory(),
        api: FakeSyncApi(),
        authorizedRequest: <T>(Future<T> Function(String accessToken) action) =>
            action('access'),
      ),
    );
    addTearDown(syncController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountPanel(
            controller: controller,
            syncController: syncController,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('多设备同步'), findsOneWidget);
    expect(find.text('VIP 专享'), findsOneWidget);
    expect(find.textContaining('自动同步到你的其他设备'), findsOneWidget);
    expect(find.byKey(const Key('auto-sync-switch')), findsNothing);
    expect(find.byKey(const Key('sync-now')), findsNothing);
  });

  testWidgets('read-only grace only offers cloud content download', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(450, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AccountSessionController(
      api: _VipAccountApi(vip: false, downloadAllowed: true),
      tokenStore: _MemoryTokenStore(),
      deviceName: 'DESKTOP-TEST',
    );
    addTearDown(controller.dispose);
    await controller.login(
      email: 'grace@example.com',
      password: 'long-password',
    );
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('pull_cursor:account-grace@example.com', '0');
    final api = FakeSyncApi();
    final syncController = SyncController(
      accountSession: controller,
      engine: SyncEngine(
        storage: storage,
        api: api,
        authorizedRequest: <T>(Future<T> Function(String accessToken) action) =>
            action('access'),
      ),
    );
    addTearDown(syncController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountPanel(
            controller: controller,
            syncController: syncController,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('sync-download')));
    await tester.tap(find.byKey(const Key('sync-download')));
    await tester.pumpAndSettle();

    expect(find.text('仅可恢复'), findsOneWidget);
    expect(api.pullCalls, hasLength(1));
    expect(api.pushCalls, isEmpty);
    expect(find.byKey(const Key('auto-sync-switch')), findsNothing);
  });
}

class _RecordingDialogPresenter {
  _RecordingDialogPresenter(this.navigatorKey);

  final GlobalKey<NavigatorState> navigatorKey;
  int callCount = 0;
  Key? frameKey;

  Future<T?> call<T>({
    required WidgetBuilder builder,
    required bool barrierDismissible,
    Key? frameKey,
  }) {
    callCount++;
    this.frameKey = frameKey;
    return showDialog<T>(
      context: navigatorKey.currentContext!,
      barrierDismissible: barrierDismissible,
      builder: builder,
    );
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

class _VipAccountApi implements AccountRemoteDataSource {
  _VipAccountApi({
    this.vip = true,
    this.downloadAllowed = true,
    this.googleLinked = false,
  });

  final bool vip;
  final bool downloadAllowed;
  final bool googleLinked;

  AuthSession _session(String email) => _vipSession(
    email,
    vip: vip,
    downloadAllowed: downloadAllowed,
    googleLinked: googleLinked,
  );

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
    required String deviceName,
    required String platform,
    required String appVersion,
  }) async => _session(email);

  @override
  Future<AuthSession> register({
    required String email,
    required String password,
    required String deviceName,
    required String platform,
    required String appVersion,
  }) => login(
    email: email,
    password: password,
    deviceName: deviceName,
    platform: platform,
    appVersion: appVersion,
  );

  @override
  Future<AuthSession> refresh({
    required String refreshToken,
    required String idempotencyKey,
  }) async => _session('vip@example.com');

  @override
  Future<void> logout({
    required String refreshToken,
    required String idempotencyKey,
  }) async {}

  @override
  Future<CurrentAccount> currentAccount({required String accessToken}) async {
    final session = _session('vip@example.com');
    return CurrentAccount(account: session.account, device: session.device);
  }
}

AuthSession _vipSession(
  String email, {
  bool vip = true,
  bool downloadAllowed = true,
  bool googleLinked = false,
}) => AuthSession(
  accessToken: 'access',
  accessTokenExpiresAt: DateTime.utc(2099),
  refreshToken: 'refresh',
  refreshTokenExpiresAt: DateTime.utc(2099, 2),
  account: JianheAccount(
    id: 'account-$email',
    email: email,
    emailVerified: false,
    googleLinked: googleLinked,
    entitlement: AccountEntitlement(
      plan: vip ? 'vip' : 'free',
      vipExpiresAt: vip ? DateTime.utc(2099, 1, 1) : null,
      cloudBackupUploadAllowed: vip,
      cloudBackupDownloadAllowed: downloadAllowed,
    ),
  ),
  device: const AccountDevice(id: 'device-id', name: 'TEST'),
);
