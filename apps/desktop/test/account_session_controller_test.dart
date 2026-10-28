import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/features/account/account_api.dart';
import 'package:jianhe_desktop/features/account/account_models.dart';
import 'package:jianhe_desktop/features/account/account_session_controller.dart';
import 'package:jianhe_desktop/features/account/refresh_token_store.dart';

void main() {
  group('credential format checks', () {
    test('login accepts a short existing password', () async {
      final api = _FakeAccountApi();
      final controller = _controller(api, _MemoryTokenStore());
      addTearDown(controller.dispose);

      final ok = await controller.login(
        email: 'user@example.com',
        password: 'short',
      );

      expect(ok, isTrue);
      expect(api.lastEmail, 'user@example.com');
    });

    test('register still requires 10–128 characters', () async {
      final api = _FakeAccountApi();
      final controller = _controller(api, _MemoryTokenStore());
      addTearDown(controller.dispose);

      final ok = await controller.register(
        email: 'user@example.com',
        password: 'short',
      );

      expect(ok, isFalse);
      expect(api.lastEmail, isNull);
      expect(controller.message, '密码长度需为 10–128 个字符。');
    });

    for (final email in <String>['a b@x.com', '张三 <a@x.com>', 'a@x.com.']) {
      test('malformed email "$email" is rejected locally', () async {
        final api = _FakeAccountApi();
        final controller = _controller(api, _MemoryTokenStore());
        addTearDown(controller.dispose);

        final ok = await controller.login(
          email: email,
          password: 'long-password',
        );

        expect(ok, isFalse);
        expect(api.lastEmail, isNull);
        expect(controller.message, contains('有效的邮箱地址'));
      });
    }

    test('empty login password asks for the password', () async {
      final api = _FakeAccountApi();
      final controller = _controller(api, _MemoryTokenStore());
      addTearDown(controller.dispose);

      await controller.login(email: 'user@example.com', password: '');

      expect(api.lastEmail, isNull);
      expect(controller.message, '请输入密码。');
    });
  });

  group('login failure messages', () {
    for (final code in <String>['INVALID_CREDENTIALS', 'RATE_LIMITED']) {
      test('$code shows the server guidance without a request ID', () async {
        final api = _FakeAccountApi()
          ..loginError = AccountApiException(
            code: code,
            message: '登录尝试过于频繁，请 2 分钟后再试。',
            requestId: 'req-123',
          );
        final controller = _controller(api, _MemoryTokenStore());
        addTearDown(controller.dispose);

        await controller.login(
          email: 'user@example.com',
          password: 'long-password',
        );

        expect(controller.message, '登录尝试过于频繁，请 2 分钟后再试。');
      });
    }

    test('unexpected failures do not show the request ID', () async {
      final api = _FakeAccountApi()
        ..loginError = const AccountApiException(
          code: 'INTERNAL_ERROR',
          message: '云服务暂时不可用，请稍后重试。',
          requestId: 'req-456',
        );
      final controller = _controller(api, _MemoryTokenStore());
      addTearDown(controller.dispose);

      await controller.login(
        email: 'user@example.com',
        password: 'long-password',
      );

      expect(controller.message, '云服务暂时不可用，请稍后重试。');
    });
  });

  test(
    'startup retries an interrupted refresh with the same operation key',
    () async {
      final api = _FakeAccountApi();
      final store = _MemoryTokenStore(
        const StoredRefreshSession(
          refreshToken: 'old-refresh',
          pendingRefreshIdempotencyKey: 'pending-operation',
        ),
      );
      final controller = _controller(api, store);

      await controller.initialize();

      expect(api.lastRefreshToken, 'old-refresh');
      expect(api.lastIdempotencyKey, 'pending-operation');
      expect(store.value?.refreshToken, 'new-refresh');
      expect(store.value?.pendingRefreshIdempotencyKey, isNull);
      expect(controller.signedIn, isTrue);
    },
  );

  test('rotation reloads the token after entering the process lock', () async {
    final api = _FakeAccountApi();
    final store = _MemoryTokenStore(
      const StoredRefreshSession(refreshToken: 'stale-refresh'),
    );
    final lockEntered = Completer<void>();
    final releaseLock = Completer<void>();

    Future<T> guarded<T>(Future<T> Function() action) async {
      lockEntered.complete();
      await releaseLock.future;
      return action();
    }

    final controller = AccountSessionController(
      api: api,
      tokenStore: store,
      deviceName: 'DESKTOP-TEST',
      idempotencyKeyFactory: () => 'unused-operation',
      accountCriticalSection: guarded,
    );

    final initialization = controller.initialize();
    await lockEntered.future;
    store.value = const StoredRefreshSession(
      refreshToken: 'latest-refresh',
      pendingRefreshIdempotencyKey: 'latest-operation',
    );
    releaseLock.complete();
    await initialization;

    expect(api.lastRefreshToken, 'latest-refresh');
    expect(api.lastIdempotencyKey, 'latest-operation');
    expect(controller.signedIn, isTrue);
  });

  test(
    'login persists only the refresh session and exposes account status',
    () async {
      final api = _FakeAccountApi();
      final store = _MemoryTokenStore();
      final controller = _controller(api, store);

      expect(
        await controller.login(
          email: ' person@example.com ',
          password: 'long-password',
        ),
        isTrue,
      );

      expect(api.lastEmail, 'person@example.com');
      expect(store.value?.refreshToken, 'new-refresh');
      expect(controller.account?.email, 'person@example.com');
    },
  );

  test('invalid refresh clears local credentials and requires login', () async {
    final api = _FakeAccountApi()
      ..refreshError = const AccountApiException(
        code: 'AUTH_REQUIRED',
        message: '登录状态已失效，请重新登录。',
      );
    final store = _MemoryTokenStore(
      const StoredRefreshSession(refreshToken: 'expired-refresh'),
    );
    final controller = _controller(api, store);

    await controller.initialize();

    expect(store.value, isNull);
    expect(controller.signedIn, isFalse);
    expect(controller.message, contains('重新登录'));
  });

  test('logout signs out locally even when server revocation fails', () async {
    final api = _FakeAccountApi();
    final store = _MemoryTokenStore();
    final controller = _controller(api, store);
    await controller.login(
      email: 'person@example.com',
      password: 'long-password',
    );
    api.logoutError = const AccountApiException(
      code: 'NETWORK_ERROR',
      message: '暂时无法连接云服务。',
    );

    await controller.logout();

    expect(store.value, isNull);
    expect(controller.signedIn, isFalse);
    expect(controller.message, contains('云端撤销暂时失败'));
  });

  test(
    'authorized request refreshes once after access token rejection',
    () async {
      final api = _FakeAccountApi();
      final store = _MemoryTokenStore();
      final controller = _controller(api, store);
      await controller.login(
        email: 'person@example.com',
        password: 'long-password',
      );
      var attempts = 0;

      final result = await controller.authorizedRequest((token) async {
        attempts++;
        if (attempts == 1) {
          throw const AccountApiException(
            code: 'AUTH_REQUIRED',
            message: 'expired',
          );
        }
        return token;
      });

      expect(attempts, 2);
      expect(result, 'new-access');
      expect(api.lastRefreshToken, 'new-refresh');
    },
  );

  test('concurrent authorized requests share one token rotation', () async {
    final api = _FakeAccountApi()..refreshGate = Completer<void>();
    final store = _MemoryTokenStore();
    final controller = AccountSessionController(
      api: api,
      tokenStore: store,
      deviceName: 'DESKTOP-TEST',
      now: () => DateTime.utc(2100),
      idempotencyKeyFactory: () => 'shared-operation',
    );
    await controller.login(
      email: 'person@example.com',
      password: 'long-password',
    );

    final first = controller.authorizedRequest((token) async => token);
    final second = controller.authorizedRequest((token) async => token);
    await Future<void>.delayed(Duration.zero);

    expect(api.refreshCalls, 1);
    api.refreshGate!.complete();
    expect(await Future.wait([first, second]), ['new-access', 'new-access']);
    expect(api.refreshCalls, 1);
  });

  test(
    'logout during a background rotation revokes the rotated token',
    () async {
      final api = _FakeAccountApi()
        ..refreshGate = Completer<void>()
        ..rotatedRefreshToken = 'rotated-refresh';
      final store = _MemoryTokenStore();
      final controller = AccountSessionController(
        api: api,
        tokenStore: store,
        deviceName: 'DESKTOP-TEST',
        now: () => DateTime.utc(2100),
        idempotencyKeyFactory: () => 'logout-race-operation',
      );
      await controller.login(
        email: 'person@example.com',
        password: 'long-password',
      );

      controller.authorizedRequest((token) async => token).ignore();
      await pumpEventQueue();
      expect(api.refreshCalls, 1);

      final signingOut = controller.logout();
      await pumpEventQueue();
      api.refreshGate!.complete();
      await signingOut;
      await pumpEventQueue();

      expect(api.lastLogoutRefreshToken, 'rotated-refresh');
      expect(store.value, isNull);
      expect(controller.signedIn, isFalse);
      expect(controller.message, contains('已安全退出账号'));
    },
  );

  test('a stale background rotation cannot override a newer login', () async {
    final api = _FakeAccountApi()
      ..refreshGate = Completer<void>()
      ..rotatedRefreshToken = 'stale-rotation-token';
    final store = _MemoryTokenStore();
    final controller = AccountSessionController(
      api: api,
      tokenStore: store,
      deviceName: 'DESKTOP-TEST',
      now: () => DateTime.utc(2100),
      idempotencyKeyFactory: () => 'relogin-race-operation',
    );
    await controller.login(email: 'a@example.com', password: 'long-password');

    controller.authorizedRequest((token) async => token).ignore();
    await pumpEventQueue();
    expect(api.refreshCalls, 1);

    expect(
      await controller.login(email: 'b@example.com', password: 'long-password'),
      isTrue,
    );
    expect(store.value?.refreshToken, 'new-refresh');

    api.refreshGate!.complete();
    await pumpEventQueue();

    expect(store.value?.refreshToken, 'new-refresh');
    expect(controller.signedIn, isTrue);
    expect(api.lastRefreshToken, 'new-refresh');
  });

  test('a request started during logout cannot rotate or persist', () async {
    final api = _FakeAccountApi()..rotatedRefreshToken = 'raced-refresh';
    final store = _MemoryTokenStore()..readGate = Completer<void>();
    final controller = AccountSessionController(
      api: api,
      tokenStore: store,
      deviceName: 'DESKTOP-TEST',
      now: () => DateTime.utc(2100),
      idempotencyKeyFactory: () => 'logout-window-operation',
    );
    await controller.login(
      email: 'person@example.com',
      password: 'long-password',
    );

    // Park logout right after its generation bump, on the store read.
    final signingOut = controller.logout();
    await pumpEventQueue();

    final requestOutcome = controller
        .authorizedRequest((token) async => token)
        .then((_) => 'completed', onError: (Object error) => '$error');
    await pumpEventQueue();

    // The session is already gone, so the request is refused outright and
    // no rotation that could outlive the logout is ever started.
    expect(api.refreshCalls, 0);
    expect(await requestOutcome, contains('AUTH_REQUIRED'));

    store.readGate!.complete();
    await signingOut;
    await pumpEventQueue();

    expect(api.lastLogoutRefreshToken, 'new-refresh');
    expect(store.value, isNull);
    expect(controller.signedIn, isFalse);
    expect(controller.message, contains('已安全退出账号'));
  });

  test(
    'a request parked on its store read cannot rotate after logout',
    () async {
      final api = _FakeAccountApi()..rotatedRefreshToken = 'raced-refresh';
      final store = _MemoryTokenStore()..readGate = Completer<void>();
      final controller = AccountSessionController(
        api: api,
        tokenStore: store,
        deviceName: 'DESKTOP-TEST',
        now: () => DateTime.utc(2100),
        idempotencyKeyFactory: () => 'logout-prewindow-operation',
      );
      await controller.login(
        email: 'person@example.com',
        password: 'long-password',
      );

      // The access token is stale, so the request parks on its store read
      // before any logout has started.
      final requestOutcome = controller
          .authorizedRequest((token) async => token)
          .then((_) => 'completed', onError: (Object error) => '$error');
      await pumpEventQueue();

      // Logout runs to completion while the request is still parked.
      final signingOut = controller.logout();
      await pumpEventQueue();
      store.readGate!.complete();
      await signingOut;
      await pumpEventQueue();

      expect(controller.signedIn, isFalse);
      expect(store.value, isNull);
      expect(api.lastLogoutRefreshToken, 'new-refresh');

      // Releasing the parked read must not start a rotation that could
      // outlive the logout and persist a token the revocation never saw.
      expect(api.refreshCalls, 0);
      expect(await requestOutcome, contains('AUTH_REQUIRED'));
      expect(store.value, isNull);
      expect(controller.signedIn, isFalse);
    },
  );

  test(
    'a failed store read still deletes locally and admits no revocation',
    () async {
      final api = _FakeAccountApi();
      final store = _MemoryTokenStore(
        const StoredRefreshSession(refreshToken: 'unreadable-refresh'),
      )..readError = StateError('secure storage unavailable');
      final controller = _controller(api, store);
      await controller.login(
        email: 'person@example.com',
        password: 'long-password',
      );

      await controller.logout();

      // The revocation never ran because the token could not be read...
      expect(api.lastLogoutRefreshToken, isNull);
      // ...but the local deletion did, and the message no longer claims a
      // fully safe sign-out.
      expect(store.value, isNull);
      expect(controller.signedIn, isFalse);
      expect(controller.message, contains('云端撤销暂时失败'));
      expect(controller.message, isNot(contains('已安全退出账号')));
    },
  );

  test(
    'read and delete failures together report the storage problem',
    () async {
      final api = _FakeAccountApi();
      final store =
          _MemoryTokenStore(
              const StoredRefreshSession(refreshToken: 'unreadable-refresh'),
            )
            ..readError = StateError('secure storage unavailable')
            ..deleteError = StateError('secure storage unavailable');
      final controller = _controller(api, store);
      await controller.login(
        email: 'person@example.com',
        password: 'long-password',
      );

      await controller.logout();

      expect(store.value?.refreshToken, 'new-refresh');
      expect(controller.signedIn, isFalse);
      expect(controller.message, contains('安全存储清理失败'));
      expect(controller.message, isNot(contains('已安全退出账号')));
    },
  );

  test(
    'external login opens browser and stores the returned Jianhe session',
    () async {
      final api = _ExternalAccountApi();
      final store = _MemoryTokenStore();
      Uri? opened;
      final controller = AccountSessionController(
        api: api,
        tokenStore: store,
        deviceName: 'DESKTOP-TEST',
        externalBrowserOpener: (uri) async => opened = uri,
        externalPollDelay: Duration.zero,
      );

      expect(await controller.authenticateExternal('google'), isTrue);
      expect(opened.toString(), 'https://accounts.google.com/example');
      expect(api.provider, 'google');
      expect(api.verifierHash, isNotEmpty);
      expect(api.verifier, isNotEmpty);
      expect(store.value?.refreshToken, 'new-refresh');
      expect(controller.account?.id, 'account-id');
    },
  );

  test('external binding sends the active Jianhe token', () async {
    final api = _ExternalAccountApi();
    final controller = AccountSessionController(
      api: api,
      tokenStore: _MemoryTokenStore(),
      deviceName: 'DESKTOP-TEST',
      externalBrowserOpener: (_) async {},
      externalPollDelay: Duration.zero,
    );
    await controller.login(
      email: 'person@example.com',
      password: 'long-password',
    );

    expect(await controller.authenticateExternal('wechat'), isTrue);
    expect(api.linkAccessToken, 'new-access');
    expect(controller.account?.id, 'account-id');
  });

  test(
    'a background rotation during an in-flight bind keeps the working status',
    () async {
      // The bind flow holds `working` while polling; the auto-sync timer
      // firing in that window rotates the (short-lived) access token via
      // authorizedRequest. That rotation must swap the session without
      // flipping the flow back to `signedIn` (which would re-enable the
      // logout/bind buttons and clear the in-flight message).
      // The rotation hands out a token distinct from the login's, so the
      // revoke assertion below can tell the consumed pre-rotation token
      // apart from the family that is actually still live.
      final api = _ExpiringExternalApi()
        ..rotatedRefreshToken = 'rotated-refresh';
      final store = _MemoryTokenStore();
      final controller = AccountSessionController(
        api: api,
        tokenStore: store,
        deviceName: 'DESKTOP-TEST',
        externalBrowserOpener: (_) async {},
        externalPollDelay: Duration.zero,
      );
      await controller.login(
        email: 'person@example.com',
        password: 'long-password',
      );
      api.controller = controller;

      expect(await controller.authenticateExternal('google'), isTrue);

      // The rotation really ran inside the bind...
      expect(api.refreshCalls, greaterThan(0));
      // ...and while it ran, the flow still owned the working status.
      expect(api.statusAtBegin, AccountSessionStatus.working);
      // The finished bind lands signed in, and the superseded family is
      // revoked through its *live* (post-rotation) token — revoking the
      // login's already-rotated token would leave the family orphaned.
      expect(controller.status, AccountSessionStatus.signedIn);
      expect(controller.account?.id, 'account-id');
      expect(api.lastLogoutRefreshToken, 'rotated-refresh');
    },
  );
}

class _ExternalAccountApi extends _FakeAccountApi
    implements ExternalAuthRemote {
  String? provider;
  String? verifierHash;
  String? verifier;
  String? linkAccessToken;

  @override
  Future<ExternalAuthStart> beginExternal({
    required String provider,
    required String verifierHash,
    String? accessToken,
  }) async {
    this.provider = provider;
    this.verifierHash = verifierHash;
    linkAccessToken = accessToken;
    return ExternalAuthStart(
      'flow-id',
      Uri.parse('https://accounts.google.com/example'),
    );
  }

  @override
  Future<AuthSession> finishExternal({
    required String provider,
    required String flowId,
    required String verifier,
    required String deviceName,
    required String platform,
    required String appVersion,
  }) async {
    this.verifier = verifier;
    return _session();
  }
}

/// Bind-flow api whose login session carries an expired access token, so
/// the authorizedRequest inside the bind rotates before reaching
/// beginExternal; the controller status is probed at that exact point.
class _ExpiringExternalApi extends _ExternalAccountApi {
  AccountSessionController? controller;
  AccountSessionStatus? statusAtBegin;

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
    required String deviceName,
    required String platform,
    required String appVersion,
  }) async {
    lastEmail = email;
    return AuthSession(
      accessToken: 'stale-access',
      accessTokenExpiresAt: DateTime.utc(2020),
      refreshToken: 'new-refresh',
      refreshTokenExpiresAt: DateTime.utc(2099, 2),
      account: _session().account,
      device: _session().device,
    );
  }

  @override
  Future<ExternalAuthStart> beginExternal({
    required String provider,
    required String verifierHash,
    String? accessToken,
  }) async {
    statusAtBegin = controller?.status;
    return super.beginExternal(
      provider: provider,
      verifierHash: verifierHash,
      accessToken: accessToken,
    );
  }
}

AccountSessionController _controller(
  _FakeAccountApi api,
  _MemoryTokenStore store,
) {
  return AccountSessionController(
    api: api,
    tokenStore: store,
    deviceName: 'DESKTOP-TEST',
    idempotencyKeyFactory: () => 'new-operation',
  );
}

class _MemoryTokenStore implements RefreshTokenStore {
  _MemoryTokenStore([this.value]);

  StoredRefreshSession? value;
  Completer<void>? readGate;
  Object? readError;
  Object? deleteError;

  @override
  Future<void> delete() async {
    if (deleteError case final error?) throw error;
    value = null;
  }

  @override
  Future<StoredRefreshSession?> read() async {
    final gate = readGate;
    if (gate != null) await gate.future;
    if (readError case final error?) throw error;
    return value;
  }

  @override
  Future<void> write(StoredRefreshSession session) async => value = session;
}

class _FakeAccountApi implements AccountRemoteDataSource {
  String? lastEmail;
  String? lastRefreshToken;
  String? lastIdempotencyKey;
  String? lastLogoutRefreshToken;
  String? rotatedRefreshToken;
  Object? refreshError;
  Object? logoutError;
  Object? loginError;
  Completer<void>? refreshGate;
  int refreshCalls = 0;

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
    required String deviceName,
    required String platform,
    required String appVersion,
  }) async {
    lastEmail = email;
    if (loginError case final error?) throw error;
    return _session();
  }

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
  }) async {
    refreshCalls++;
    await refreshGate?.future;
    if (refreshError case final error?) throw error;
    lastRefreshToken = refreshToken;
    lastIdempotencyKey = idempotencyKey;
    return _session(refreshToken: rotatedRefreshToken ?? 'new-refresh');
  }

  @override
  Future<void> logout({
    required String refreshToken,
    required String idempotencyKey,
  }) async {
    lastLogoutRefreshToken = refreshToken;
    if (logoutError case final error?) throw error;
  }

  @override
  Future<CurrentAccount> currentAccount({required String accessToken}) async {
    final session = _session();
    return CurrentAccount(account: session.account, device: session.device);
  }
}

AuthSession _session({String refreshToken = 'new-refresh'}) => AuthSession(
  accessToken: 'new-access',
  accessTokenExpiresAt: DateTime.utc(2099),
  refreshToken: refreshToken,
  refreshTokenExpiresAt: DateTime.utc(2099, 2),
  account: const JianheAccount(
    id: 'account-id',
    email: 'person@example.com',
    emailVerified: false,
    entitlement: AccountEntitlement(
      plan: 'free',
      vipExpiresAt: null,
      cloudBackupUploadAllowed: false,
      cloudBackupDownloadAllowed: false,
    ),
  ),
  device: const AccountDevice(id: 'device-id', name: 'DESKTOP-TEST'),
);
