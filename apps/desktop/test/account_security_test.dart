import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/features/account/account_api.dart';
import 'package:jianhe_desktop/features/account/account_models.dart';
import 'package:jianhe_desktop/features/account/account_panel.dart';
import 'package:jianhe_desktop/features/account/account_session_controller.dart';
import 'package:jianhe_desktop/features/account/refresh_token_store.dart';

void main() {
  void useAccountWindow(WidgetTester tester) {
    tester.view.physicalSize = const Size(450, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<AccountSessionController> pumpPanel(
    WidgetTester tester,
    _SecurityApi api, {
    bool signIn = false,
  }) async {
    useAccountWindow(tester);
    final controller = AccountSessionController(
      api: api,
      tokenStore: _MemoryTokenStore(),
      deviceName: 'DESKTOP-TEST',
    );
    addTearDown(controller.dispose);
    if (signIn) {
      await controller.login(
        email: 'user@example.com',
        password: 'a long password',
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AccountPanel(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> scrollTo(WidgetTester tester, Key key) async {
    await tester.dragUntilVisible(
      find.byKey(key),
      find.byType(Scrollable).first,
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('registration sends a code and registers with it', (
    tester,
  ) async {
    final api = _SecurityApi();
    final controller = await pumpPanel(tester, api);

    await tester.tap(find.byKey(const Key('account-mode-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('创建笺盒账号'), findsOneWidget);
    expect(find.byKey(const Key('account-email-code-field')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('account-email-field')),
      'new@example.com',
    );
    await tester.enterText(
      find.byKey(const Key('account-password-field')),
      'a long password',
    );
    // Without a code the form explains what is missing.
    await tester.tap(find.byKey(const Key('account-submit')));
    await tester.pumpAndSettle();
    expect(find.text('请先获取并填写邮箱验证码。'), findsOneWidget);
    expect(api.registeredWithCode, isNull);

    await tester.tap(find.byKey(const Key('account-send-code')));
    await tester.pump();
    expect(api.codeRequests, <String>['register:new@example.com']);
    expect(find.textContaining('验证码已发送到 new@example.com'), findsOneWidget);
    expect(find.text('2 秒后重发'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('获取验证码'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('account-email-code-field')),
      '123456',
    );
    await tester.tap(find.byKey(const Key('account-submit')));
    await tester.pumpAndSettle();
    expect(api.registeredWithCode, '123456');
    expect(controller.signedIn, isTrue);
  });

  testWidgets('a cooldown refusal still starts the countdown', (tester) async {
    final api = _SecurityApi()..cooldownRefusal = true;
    await pumpPanel(tester, api);
    await tester.tap(find.byKey(const Key('account-mode-toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('account-email-field')),
      'new@example.com',
    );
    await tester.tap(find.byKey(const Key('account-send-code')));
    await tester.pump();
    expect(find.text('验证码发送过于频繁，请 2 秒后再试。'), findsOneWidget);
    expect(find.text('2 秒后重发'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('forgot password resets with a code and returns to login', (
    tester,
  ) async {
    final api = _SecurityApi();
    await pumpPanel(tester, api);

    await tester.tap(find.byKey(const Key('account-forgot-password')));
    await tester.pumpAndSettle();
    expect(find.text('重设密码'), findsWidgets);

    await tester.enterText(
      find.byKey(const Key('account-email-field')),
      'user@example.com',
    );
    await tester.tap(find.byKey(const Key('account-send-code')));
    await tester.pump();
    expect(api.codeRequests, <String>['reset_password:user@example.com']);
    await tester.enterText(
      find.byKey(const Key('account-email-code-field')),
      '654321',
    );
    await tester.enterText(
      find.byKey(const Key('account-password-field')),
      'a brand new password',
    );
    await tester.tap(find.byKey(const Key('account-submit')));
    await tester.pumpAndSettle();

    expect(api.resets, <String>[
      'user@example.com|654321|a brand new password',
    ]);
    expect(find.text('登录笺盒账号'), findsOneWidget);
    expect(find.textContaining('密码已重设'), findsOneWidget);
  });

  testWidgets('the panel hides security features for an API without them', (
    tester,
  ) async {
    useAccountWindow(tester);
    final controller = AccountSessionController(
      api: _PlainApi(),
      tokenStore: _MemoryTokenStore(),
      deviceName: 'DESKTOP-TEST',
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AccountPanel(controller: controller)),
      ),
    );
    expect(find.byKey(const Key('account-forgot-password')), findsNothing);
    await tester.tap(find.byKey(const Key('account-mode-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account-email-code-field')), findsNothing);
  });

  testWidgets('an unverified account verifies its email', (tester) async {
    final api = _SecurityApi();
    final controller = await pumpPanel(tester, api, signIn: true);
    expect(find.text('邮箱未验证'), findsOneWidget);

    await scrollTo(tester, const Key('account-verify-email'));
    await tester.tap(find.byKey(const Key('account-verify-email')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('verify-email-dialog')), findsOneWidget);

    await tester.tap(find.byKey(const Key('verify-email-send')));
    await tester.pump();
    expect(api.codeRequests, <String>['account:verify_email']);
    await tester.enterText(
      find.byKey(const Key('verify-email-code')),
      '111111',
    );
    await tester.tap(find.byKey(const Key('verify-email-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('verify-email-dialog')), findsNothing);
    expect(controller.account!.emailVerified, isTrue);
    expect(find.text('邮箱已验证'), findsWidgets);
    expect(find.byKey(const Key('account-verify-email')), findsNothing);
  });

  testWidgets('change password checks confirmation and the current password', (
    tester,
  ) async {
    final api = _SecurityApi();
    await pumpPanel(tester, api, signIn: true);

    await scrollTo(tester, const Key('account-change-password'));
    await tester.tap(find.byKey(const Key('account-change-password')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('change-password-current')),
      'wrong password',
    );
    await tester.enterText(
      find.byKey(const Key('change-password-new')),
      'a brand new password',
    );
    await tester.enterText(
      find.byKey(const Key('change-password-confirm')),
      'something else entirely',
    );
    await tester.tap(find.byKey(const Key('change-password-submit')));
    await tester.pumpAndSettle();
    expect(find.text('两次输入的新密码不一致。'), findsOneWidget);
    expect(api.passwordChanges, isEmpty);

    await tester.enterText(
      find.byKey(const Key('change-password-confirm')),
      'a brand new password',
    );
    await tester.tap(find.byKey(const Key('change-password-submit')));
    await tester.pumpAndSettle();
    expect(find.text('当前密码不正确。'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('change-password-current')),
      'a long password',
    );
    await tester.tap(find.byKey(const Key('change-password-submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('change-password-dialog')), findsNothing);
    expect(api.passwordChanges, <String>[
      'a long password|a brand new password',
    ]);
    expect(find.textContaining('密码已修改'), findsOneWidget);
  });

  testWidgets('deleting the account needs confirmation and signs out', (
    tester,
  ) async {
    final api = _SecurityApi();
    final store = _MemoryTokenStore();
    useAccountWindow(tester);
    final controller = AccountSessionController(
      api: api,
      tokenStore: store,
      deviceName: 'DESKTOP-TEST',
    );
    addTearDown(controller.dispose);
    await controller.login(
      email: 'user@example.com',
      password: 'a long password',
    );
    expect(store.value, isNotNull);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AccountPanel(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    await scrollTo(tester, const Key('account-delete'));
    await tester.tap(find.byKey(const Key('account-delete')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('delete-account-dialog')), findsOneWidget);

    FilledButton submit() => tester.widget<FilledButton>(
      find.byKey(const Key('delete-account-submit')),
    );
    expect(submit().onPressed, isNull);
    await tester.enterText(
      find.byKey(const Key('delete-account-password')),
      'a long password',
    );
    await tester.pump();
    expect(submit().onPressed, isNull, reason: 'not yet confirmed');
    await tester.tap(find.byKey(const Key('delete-account-confirm')));
    await tester.pump();
    expect(submit().onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('delete-account-submit')));
    await tester.pumpAndSettle();
    expect(api.deletions, <String>['password:a long password']);
    expect(find.byKey(const Key('delete-account-dialog')), findsNothing);
    expect(controller.signedIn, isFalse);
    expect(store.value, isNull);
    expect(find.textContaining('账号已注销'), findsOneWidget);
  });

  testWidgets('account deletion can be confirmed with an email code', (
    tester,
  ) async {
    final api = _SecurityApi();
    final controller = await pumpPanel(tester, api, signIn: true);
    await scrollTo(tester, const Key('account-delete'));
    await tester.tap(find.byKey(const Key('account-delete')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('delete-account-use-code')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-account-send-code')));
    await tester.pump();
    expect(api.codeRequests, <String>['account:delete_account']);
    await tester.enterText(
      find.byKey(const Key('delete-account-code')),
      '222222',
    );
    await tester.tap(find.byKey(const Key('delete-account-confirm')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('delete-account-submit')));
    await tester.pumpAndSettle();
    expect(api.deletions, <String>['code:222222']);
    expect(controller.signedIn, isFalse);
  });
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

AuthSession _session(String email, {bool verified = false}) => AuthSession(
  accessToken: 'access',
  accessTokenExpiresAt: DateTime.utc(2099),
  refreshToken: 'refresh',
  refreshTokenExpiresAt: DateTime.utc(2099, 2),
  account: JianheAccount(
    id: 'account-1',
    email: email,
    emailVerified: verified,
    entitlement: const AccountEntitlement(
      plan: 'free',
      vipExpiresAt: null,
      cloudBackupUploadAllowed: false,
      cloudBackupDownloadAllowed: false,
    ),
  ),
  device: const AccountDevice(id: 'device-1', name: 'TEST'),
);

class _PlainApi implements AccountRemoteDataSource {
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
  }) async => _session(email);

  @override
  Future<AuthSession> refresh({
    required String refreshToken,
    required String idempotencyKey,
  }) async => _session('user@example.com');

  @override
  Future<void> logout({
    required String refreshToken,
    required String idempotencyKey,
  }) async {}

  @override
  Future<CurrentAccount> currentAccount({required String accessToken}) async {
    final session = _session('user@example.com');
    return CurrentAccount(account: session.account, device: session.device);
  }
}

class _SecurityApi extends _PlainApi implements AccountSecurityRemote {
  final codeRequests = <String>[];
  final resets = <String>[];
  final passwordChanges = <String>[];
  final deletions = <String>[];
  String? registeredWithCode;
  bool cooldownRefusal = false;

  static const _ticket = EmailCodeTicket(
    cooldown: Duration(seconds: 2),
    expiresIn: Duration(minutes: 10),
  );

  @override
  Future<EmailCodeTicket> requestEmailCode({
    required String email,
    required EmailCodePurpose purpose,
  }) async {
    if (cooldownRefusal) {
      throw const AccountApiException(
        code: 'EMAIL_CODE_COOLDOWN',
        message: '验证码发送过于频繁，请 2 秒后再试。',
        retryable: true,
        retryAfter: Duration(seconds: 2),
      );
    }
    codeRequests.add('${purpose.wireValue}:$email');
    return _ticket;
  }

  @override
  Future<AuthSession> registerWithCode({
    required String email,
    required String password,
    required String emailCode,
    required String deviceName,
    required String platform,
    required String appVersion,
  }) async {
    registeredWithCode = emailCode;
    return _session(email, verified: true);
  }

  @override
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    resets.add('$email|$code|$newPassword');
  }

  @override
  Future<EmailCodeTicket> requestAccountEmailCode({
    required String accessToken,
    required EmailCodePurpose purpose,
  }) async {
    codeRequests.add('account:${purpose.wireValue}');
    return _ticket;
  }

  @override
  Future<CurrentAccount> verifyEmail({
    required String accessToken,
    required String code,
  }) async {
    final session = _session('user@example.com', verified: true);
    return CurrentAccount(account: session.account, device: session.device);
  }

  @override
  Future<void> changePassword({
    required String accessToken,
    required String currentPassword,
    required String newPassword,
  }) async {
    if (currentPassword != 'a long password') {
      throw const AccountApiException(
        code: 'CURRENT_PASSWORD_INCORRECT',
        message: '当前密码不正确。',
      );
    }
    passwordChanges.add('$currentPassword|$newPassword');
  }

  @override
  Future<void> deleteAccount({
    required String accessToken,
    String? password,
    String? emailCode,
  }) async {
    deletions.add(password != null ? 'password:$password' : 'code:$emailCode');
  }
}
