import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/app.dart';
import 'package:jianhe_desktop/features/account/account_api.dart';
import 'package:jianhe_desktop/features/account/account_models.dart';
import 'package:jianhe_desktop/features/account/account_session_controller.dart';
import 'package:jianhe_desktop/features/account/refresh_token_store.dart';
import 'package:jianhe_desktop/platform/ball_window_controller.dart';
import 'package:jianhe_desktop/platform/global_hot_key.dart';
import 'package:jianhe_core/jianhe_core.dart';
import 'package:jianhe_desktop/l10n/app_strings.dart';

import 'english_test_support.dart';

class _RecordingWindowController implements BallWindowController {
  @override
  bool get usesNativeBall => false;

  @override
  Stream<BallWindowEvent> get events => const Stream<BallWindowEvent>.empty();

  @override
  Future<BallDockSide> showStage(BallWindowStage stage, {Size? size}) async =>
      BallDockSide.right;

  @override
  Future<void> beginPanelResize(PanelResizeEdge edge) async {}

  @override
  Future<void> panelFrameReady(Size size) async {}

  @override
  Future<BallDockSide> startDrag() async => BallDockSide.right;

  @override
  Future<BallLayout?> getBallLayout() async => null;

  @override
  Future<void> setExpanded(bool expanded) async {}

  @override
  Future<void> setMoreBadge(bool visible) async {}

  @override
  Future<void> restorePosition(BallDockSide side, double offset) async {}

  @override
  Future<bool> setWakeHotKey(GlobalHotKey hotKey) async => true;

  @override
  void setCloseRequestHandler(Future<void> Function()? handler) {}

  @override
  Future<void> quit() async {}
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
  @override
  Future<AuthSession> login({
    required String email,
    required String password,
    required String deviceName,
    required String platform,
    required String appVersion,
  }) async => _vipSession(email);

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
  }) async => _vipSession('vip@example.com');

  @override
  Future<void> logout({
    required String refreshToken,
    required String idempotencyKey,
  }) async {}

  @override
  Future<CurrentAccount> currentAccount({required String accessToken}) async {
    final session = _vipSession('vip@example.com');
    return CurrentAccount(account: session.account, device: session.device);
  }
}

AuthSession _vipSession(String email) => AuthSession(
  accessToken: 'access',
  accessTokenExpiresAt: DateTime.utc(2099),
  refreshToken: 'refresh',
  refreshTokenExpiresAt: DateTime.utc(2099, 2),
  account: JianheAccount(
    id: 'account-$email',
    email: email,
    emailVerified: false,
    entitlement: AccountEntitlement(
      plan: 'vip',
      vipExpiresAt: DateTime.utc(2099, 1, 1),
      cloudBackupUploadAllowed: true,
      cloudBackupDownloadAllowed: true,
    ),
  ),
  device: const AccountDevice(id: 'device-id', name: 'TEST'),
);

void main() {
  Future<void> pumpPanel(WidgetTester tester) async {
    tester.view.physicalSize = const Size(583, 536);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
    final account = AccountSessionController(
      api: _VipAccountApi(),
      tokenStore: _MemoryTokenStore(),
      deviceName: 'TEST',
    );
    addTearDown(account.dispose);
    await tester.pumpWidget(
      JianheApp(
        windowController: _RecordingWindowController(),
        accountController: account,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openAccountView(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('jianhe-ball')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.byKey(const Key('account-settings-entry')),
      find.ancestor(of: find.text('导入离线备份'), matching: find.byType(ListView)),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-settings-entry')));
    await tester.pumpAndSettle();
  }

  Future<void> signIn(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('account-mode-toggle')));
    await tester.pump();
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
  }

  testWidgets('account flow at real panel size has no overflow', (
    tester,
  ) async {
    // 默认 Ahem 字体的行高/换行与真机的微软雅黑不同，真机才有的
    // 文字高度溢出只有加载真字体才能暴露。
    final fontFile = File('C:/Windows/Fonts/msyh.ttc');
    if (fontFile.existsSync()) {
      final bytes = fontFile.readAsBytesSync();
      final loader = FontLoader('Microsoft YaHei UI')
        ..addFont(
          Future<ByteData>.value(
            ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length),
          ),
        );
      await loader.load();
    }

    await pumpPanel(tester);
    await openAccountView(tester);

    await signIn(tester);
    expect(find.text('VIP 服务已开通'), findsOneWidget);
    // The sync-key card is gone; the signed-in view must not resurrect it.
    expect(find.textContaining('恢复密钥'), findsNothing);
    expect(tester.takeException(), isNull);

    // Logout. 已登录视图是懒加载 ListView，先滚动到按钮；直接登出，
    // 不再有云备份确认框。
    await tester.dragUntilVisible(
      find.byKey(const Key('account-logout')),
      find.ancestor(of: find.text('刷新账号状态'), matching: find.byType(ListView)),
      const Offset(0, -120),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const Key('account-logout')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('account flow at default panel size has no overflow', (
    tester,
  ) async {
    final fontFile = File('C:/Windows/Fonts/msyh.ttc');
    if (fontFile.existsSync()) {
      final bytes = fontFile.readAsBytesSync();
      final loader = FontLoader('Microsoft YaHei UI')
        ..addFont(
          Future<ByteData>.value(
            ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length),
          ),
        );
      await loader.load();
    }

    // 小尺寸下点击导航会落错位置（harness 限制），先在 583×536 完成导航
    // 再缩到默认 450×540，让真实尺寸承担登录视图的渲染验证。
    await pumpPanel(tester);
    await openAccountView(tester);
    tester.view.physicalSize = const Size(450, 540);
    await tester.pumpAndSettle();
    await signIn(tester);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'English account flow has no overflow',
    (tester) async {
      // Real Windows fonts: Segoe UI serves the default (Roboto) family.
      Future<void> load(String family, List<String> paths) async {
        final loader = FontLoader(family);
        for (final path in paths) {
          final file = File(path);
          if (!file.existsSync()) continue;
          final bytes = file.readAsBytesSync();
          loader.addFont(
            Future<ByteData>.value(
              ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length),
            ),
          );
        }
        await loader.load();
      }

      await load('Roboto', <String>[
        'C:/Windows/Fonts/segoeui.ttf',
        'C:/Windows/Fonts/segoeuib.ttf',
        'C:/Windows/Fonts/seguisb.ttf',
      ]);
      await load('Microsoft YaHei UI', <String>['C:/Windows/Fonts/msyh.ttc']);

      tester.view.physicalSize = const Size(640, 720);
      tester.view.devicePixelRatio = 1;
      final window = NativeTestWindowController();
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => AppStrings.setCurrentLanguage(AppLanguage.zh));
      addTearDown(window.dispose);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
      final account = AccountSessionController(
        api: _VipAccountApi(),
        tokenStore: _MemoryTokenStore(),
        deviceName: 'TEST',
      );
      addTearDown(account.dispose);
      await tester.pumpWidget(
        JianheApp(
          initialLanguage: AppLanguage.en,
          windowController: window,
          accountController: account,
        ),
      );
      await tester.pumpAndSettle();

      window.selectAction(BallWindowEventType.more);
      await tester.pumpAndSettle();
      await scrollMorePanelTo(
        tester,
        find.byKey(const Key('account-settings-entry')),
      );
      await tester.tap(find.byKey(const Key('account-settings-entry')));
      await tester.pumpAndSettle();
      expect(find.text('Sign in to JianHe'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'sign-in form');

      await tester.tap(find.byKey(const Key('account-mode-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Create a JianHe account'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'sign-up form');

      await tester.tap(find.byKey(const Key('account-mode-toggle')));
      await tester.pumpAndSettle();
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
      expect(find.text('VIP is active'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'signed-in account');
    },
    skip: !File('C:/Windows/Fonts/segoeui.ttf').existsSync(),
  );
}
