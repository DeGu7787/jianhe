import 'dart:math';
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:flutter/foundation.dart';

import '../../l10n/app_strings.dart';
import 'account_api.dart';
import 'account_models.dart';
import 'credential_rules.dart';
import 'refresh_token_store.dart';
import 'vip_billing.dart';
import 'external_browser_io.dart'
    if (dart.library.html) 'external_browser_web.dart';

enum AccountSessionStatus {
  unconfigured,
  restoring,
  signedOut,
  working,
  signedIn,
}

typedef AccountCriticalSection =
    Future<T> Function<T>(Future<T> Function() action);
typedef ExternalBrowserOpener = Future<void> Function(Uri uri);

Future<T> _runDirectly<T>(Future<T> Function() action) => action();

/// Outcome of an account security action (email code, password, deletion).
/// [message] is ready to show; [cooldown] is how long the "send code" button
/// stays disabled (set on success and on a cooldown refusal).
class AccountActionResult {
  const AccountActionResult.success({this.message, this.cooldown})
    : succeeded = true;
  const AccountActionResult.failure(String this.message, {this.cooldown})
    : succeeded = false;

  final bool succeeded;
  final String? message;
  final Duration? cooldown;
}

class AccountSessionController extends ChangeNotifier {
  factory AccountSessionController({
    required AccountRemoteDataSource api,
    required RefreshTokenStore tokenStore,
    required String deviceName,
    String platform = 'windows',
    String appVersion = '0.1.0',
    DateTime Function()? now,
    String Function()? idempotencyKeyFactory,
    AccountCriticalSection? accountCriticalSection,
    ExternalBrowserOpener? externalBrowserOpener,
    Duration externalPollDelay = const Duration(seconds: 2),
  }) {
    return AccountSessionController._(
      api,
      tokenStore,
      now ?? DateTime.now,
      idempotencyKeyFactory ?? _newUUID,
      accountCriticalSection ?? _runDirectly,
      externalBrowserOpener ?? openExternalBrowser,
      externalPollDelay,
      AccountSessionStatus.signedOut,
      deviceName: deviceName,
      platform: platform,
      appVersion: appVersion,
    );
  }

  AccountSessionController.unconfigured()
    : this._(
        null,
        null,
        DateTime.now,
        _newUUID,
        _runDirectly,
        openExternalBrowser,
        const Duration(seconds: 2),
        AccountSessionStatus.unconfigured,
        deviceName: '',
        platform: 'windows',
        appVersion: '0.1.0',
      );

  AccountSessionController._(
    this._api,
    this._tokenStore,
    this._now,
    this._idempotencyKeyFactory,
    this._accountCriticalSection,
    this._externalBrowserOpener,
    this._externalPollDelay,
    this._status, {
    required this.deviceName,
    required this.platform,
    required this.appVersion,
  });

  final AccountRemoteDataSource? _api;
  final RefreshTokenStore? _tokenStore;
  final String deviceName;
  final String platform;
  final String appVersion;
  final DateTime Function() _now;
  final String Function() _idempotencyKeyFactory;
  final AccountCriticalSection _accountCriticalSection;
  final ExternalBrowserOpener _externalBrowserOpener;
  final Duration _externalPollDelay;

  AccountSessionStatus _status;
  AuthSession? _session;
  String? _message;
  bool _initialized = false;
  bool _restoreRetryAvailable = false;
  Future<AuthSession>? _rotationInFlight;
  int _generation = 0;
  bool _logoutBarrierUp = false;
  bool _externalInProgress = false;

  AccountSessionStatus get status => _status;
  AuthSession? get session => _session;
  JianheAccount? get account => _session?.account;
  AccountDevice? get device => _session?.device;
  String? get message => _message;
  bool get configured => _api != null && _tokenStore != null;
  bool get busy =>
      _status == AccountSessionStatus.restoring ||
      _status == AccountSessionStatus.working;
  bool get signedIn => _session != null;
  bool get restoreRetryAvailable => _restoreRetryAvailable;
  bool get externalInProgress => _externalInProgress;

  AccountSecurityRemote? get _security {
    final api = _api;
    // Same reason as [billing]: an explicit cast is needed after the check.
    return api is AccountSecurityRemote ? api as AccountSecurityRemote : null;
  }

  /// Whether email codes, password reset/change and account deletion are
  /// available (the production API client supports them).
  bool get supportsAccountSecurity => configured && _security != null;

  /// VIP 购买接口；未配置云服务或数据源不支持购买时为 null。
  VipBillingRemote? get billing {
    final api = _api;
    // VipBillingRemote is not a subtype of AccountRemoteDataSource, so the
    // `is` check cannot promote and an explicit cast is required.
    return api is VipBillingRemote ? api as VipBillingRemote : null;
  }

  Future<T> authorizedRequest<T>(
    Future<T> Function(String accessToken) request,
  ) async {
    if (!configured || _session == null) throw _freshLoginRequired();
    final generation = _generation;
    try {
      var active = _session!;
      if (!active.accessTokenExpiresAt.isAfter(
        _now().toUtc().add(const Duration(seconds: 30)),
      )) {
        final stored = await _tokenStore!.read();
        if (stored == null) throw _freshLoginRequired();
        active = await _rotateShared();
        if (generation != _generation) throw _freshLoginRequired();
        _applyRotatedSession(active);
      }
      try {
        return await request(active.accessToken);
      } on AccountApiException catch (error) {
        if (error.code != 'AUTH_REQUIRED') rethrow;
        final stored = await _tokenStore!.read();
        if (stored == null) throw _freshLoginRequired();
        active = await _rotateShared();
        if (generation != _generation) throw _freshLoginRequired();
        _applyRotatedSession(active);
        return await request(active.accessToken);
      }
    } on Object catch (error) {
      if (_requiresFreshLogin(error) && generation == _generation) {
        await _deleteStoredTokenBestEffort(
          expectedRefreshToken: _session?.refreshToken,
        );
        _setState(
          status: AccountSessionStatus.signedOut,
          clearSession: true,
          message: _messageFor(error),
        );
      }
      rethrow;
    }
  }

  Future<void> initialize() async {
    if (_initialized || !configured) return;
    _initialized = true;
    _restoreRetryAvailable = false;
    _setState(status: AccountSessionStatus.restoring, clearMessage: true);
    String? storedRefreshToken;
    try {
      final stored = await _tokenStore!.read();
      if (stored == null) {
        _setState(status: AccountSessionStatus.signedOut);
        return;
      }
      storedRefreshToken = stored.refreshToken;
      final restored = await _rotateShared();
      _setState(
        status: AccountSessionStatus.signedIn,
        session: restored,
        clearMessage: true,
      );
    } on Object catch (error) {
      final requiresFreshLogin = _requiresFreshLogin(error);
      if (requiresFreshLogin) {
        await _deleteStoredTokenBestEffort(
          expectedRefreshToken: storedRefreshToken,
        );
      }
      _restoreRetryAvailable = !requiresFreshLogin;
      _setState(
        status: AccountSessionStatus.signedOut,
        clearSession: true,
        message: _messageFor(error),
      );
    }
  }

  Future<void> retryRestore() async {
    if (busy || !configured) return;
    _initialized = false;
    await initialize();
  }

  Future<bool> login({required String email, required String password}) {
    return _authenticate(email: email, password: password, register: false);
  }

  /// Registers. With [supportsAccountSecurity], [emailCode] is required: the
  /// server only registers addresses whose owner received the code.
  Future<bool> register({
    required String email,
    required String password,
    String? emailCode,
  }) {
    return _authenticate(
      email: email,
      password: password,
      register: true,
      emailCode: emailCode,
    );
  }

  Future<bool> authenticateExternal(String provider) async {
    if (!configured ||
        busy ||
        _api is! ExternalAuthRemote ||
        (provider != 'google' && provider != 'wechat')) {
      return false;
    }
    final previous = _session;
    _externalInProgress = true;
    _setState(status: AccountSessionStatus.working, clearMessage: true);
    final generation = ++_generation;
    AuthSession? issuedSession;
    try {
      final random = Random.secure();
      final bytes = List<int>.generate(32, (_) => random.nextInt(256));
      final verifier = base64UrlEncode(bytes).replaceAll('=', '');
      final verifierHash = base64UrlEncode(
        sha256.convert(utf8.encode(verifier)).bytes,
      ).replaceAll('=', '');
      final api = _api as ExternalAuthRemote;
      final start = previous == null
          ? await api.beginExternal(
              provider: provider,
              verifierHash: verifierHash,
            )
          : await authorizedRequest(
              (token) => api.beginExternal(
                provider: provider,
                verifierHash: verifierHash,
                accessToken: token,
              ),
            );
      if (generation != _generation) return false;
      await _externalBrowserOpener(start.authorizationUrl);
      final deadline = _now().add(const Duration(minutes: 5));
      while (_now().isBefore(deadline)) {
        if (generation != _generation) return false;
        await Future<void>.delayed(_externalPollDelay);
        try {
          issuedSession = await api.finishExternal(
            provider: provider,
            flowId: start.flowId,
            verifier: verifier,
            deviceName: deviceName,
            platform: platform,
            appVersion: appVersion,
          );
          break;
        } on AccountApiException catch (error) {
          if (error.code == 'EXTERNAL_PENDING') continue;
          rethrow;
        }
      }
      if (issuedSession == null) {
        throw AccountApiException(
          code: 'EXTERNAL_EXPIRED',
          message: AppStrings.current.authorizationExpired,
        );
      }
      if (generation != _generation) {
        await _revokeSessionBestEffort(issuedSession.refreshToken);
        return false;
      }
      await _persistSession(issuedSession);
      if (generation != _generation) {
        // A cancel/logout bumped the generation while the persist was in
        // flight and this write re-armed the store it had wiped. Undo the
        // write and revoke, or the next startup would silently restore the
        // session the user just cancelled.
        await _deleteStoredTokenBestEffort(
          expectedRefreshToken: issuedSession.refreshToken,
        );
        await _revokeSessionBestEffort(issuedSession.refreshToken);
        return false;
      }
      // The bind replaced this device's session with a fresh token family;
      // the previous family stays live server-side for its full refresh TTL
      // unless revoked here. Revoke the session that is live *now*, not the
      // one captured at the start: a background rotation during the bind
      // (auto-sync) already consumed `previous.refreshToken`, and logout
      // only revokes the exact token row it is given.
      final superseded = _session;
      if (previous != null &&
          superseded != null &&
          superseded.refreshToken != issuedSession.refreshToken) {
        await _revokeSessionBestEffort(superseded.refreshToken);
      }
      _externalInProgress = false;
      _setState(
        status: AccountSessionStatus.signedIn,
        session: issuedSession,
        clearMessage: true,
      );
      return true;
    } on Object catch (error) {
      _externalInProgress = false;
      if (issuedSession != null) {
        await _revokeSessionBestEffort(issuedSession.refreshToken);
      }
      final active = _session;
      _setState(
        status: active == null
            ? AccountSessionStatus.signedOut
            : AccountSessionStatus.signedIn,
        session: active,
        clearSession: active == null,
        message: _messageFor(error),
      );
      return false;
    }
  }

  void cancelExternal() {
    if (!_externalInProgress) return;
    _externalInProgress = false;
    _generation++;
    _setState(
      status: _session == null
          ? AccountSessionStatus.signedOut
          : AccountSessionStatus.signedIn,
      message: AppStrings.current.signInCancelled,
    );
  }

  Future<bool> _authenticate({
    required String email,
    required String password,
    required bool register,
    String? emailCode,
  }) async {
    if (!configured || busy) return false;
    _restoreRetryAvailable = false;
    final normalizedEmail = email.trim();
    final formatError = _credentialFormatError(
      normalizedEmail,
      password,
      register: register,
    );
    if (formatError != null) {
      _setState(status: AccountSessionStatus.signedOut, message: formatError);
      return false;
    }
    final code = emailCode?.trim() ?? '';
    final security = _security;
    if (register && security != null && code.isEmpty) {
      _setState(
        status: AccountSessionStatus.signedOut,
        message: AppStrings.current.emailCodeRequired,
      );
      return false;
    }

    _setState(status: AccountSessionStatus.working, clearMessage: true);
    _generation++;
    AuthSession? issuedSession;
    try {
      issuedSession = register && security != null
          ? await security.registerWithCode(
              email: normalizedEmail,
              password: password,
              emailCode: code,
              deviceName: deviceName,
              platform: platform,
              appVersion: appVersion,
            )
          : register
          ? await _api!.register(
              email: normalizedEmail,
              password: password,
              deviceName: deviceName,
              platform: platform,
              appVersion: appVersion,
            )
          : await _api!.login(
              email: normalizedEmail,
              password: password,
              deviceName: deviceName,
              platform: platform,
              appVersion: appVersion,
            );
      await _persistSession(issuedSession);
      _setState(
        status: AccountSessionStatus.signedIn,
        session: issuedSession,
        clearMessage: true,
      );
      return true;
    } on Object catch (error) {
      if (issuedSession != null) {
        await _revokeSessionBestEffort(issuedSession.refreshToken);
      }
      _setState(
        status: AccountSessionStatus.signedOut,
        clearSession: true,
        message: _messageFor(error),
      );
      return false;
    }
  }

  /// Mails a registration or password-reset code to [email].
  Future<AccountActionResult> sendEmailCode({
    required String email,
    required EmailCodePurpose purpose,
  }) async {
    final security = _security;
    if (!configured || security == null) {
      return AccountActionResult.failure(
        AppStrings.current.emailCodeUnsupported,
      );
    }
    final normalized = email.trim();
    if (!CredentialRules.isValidEmail(normalized)) {
      return AccountActionResult.failure(CredentialRules.invalidEmailMessage);
    }
    try {
      final ticket = await security.requestEmailCode(
        email: normalized,
        purpose: purpose,
      );
      return AccountActionResult.success(
        message: AppStrings.current.codeSent(
          normalized,
          ticket.expiresIn.inMinutes,
        ),
        cooldown: ticket.cooldown,
      );
    } on Object catch (error) {
      return _failure(error);
    }
  }

  /// Sets a new password with a reset code. Every device of the account is
  /// signed out by the server; this device is signed out already.
  Future<AccountActionResult> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    final security = _security;
    if (!configured || security == null) {
      return AccountActionResult.failure(
        AppStrings.current.passwordResetUnsupported,
      );
    }
    final normalized = email.trim();
    if (!CredentialRules.isValidEmail(normalized)) {
      return AccountActionResult.failure(CredentialRules.invalidEmailMessage);
    }
    if (code.trim().isEmpty) {
      return AccountActionResult.failure(AppStrings.current.enterEmailCode);
    }
    if (!CredentialRules.isValidNewPassword(newPassword)) {
      return AccountActionResult.failure(
        CredentialRules.newPasswordRuleMessage,
      );
    }
    try {
      await security.resetPassword(
        email: normalized,
        code: code.trim(),
        newPassword: newPassword,
      );
      return AccountActionResult.success(
        message: AppStrings.current.passwordResetDone,
      );
    } on Object catch (error) {
      return _failure(error);
    }
  }

  /// Mails a verify-email or delete-account code to the signed-in account.
  Future<AccountActionResult> sendAccountEmailCode(
    EmailCodePurpose purpose,
  ) async {
    final security = _security;
    if (security == null || _session == null) {
      return AccountActionResult.failure(AppStrings.current.signInFirst);
    }
    final email = _session!.account.email;
    try {
      final ticket = await authorizedRequest(
        (token) => security.requestAccountEmailCode(
          accessToken: token,
          purpose: purpose,
        ),
      );
      return AccountActionResult.success(
        message: AppStrings.current.codeSent(
          email,
          ticket.expiresIn.inMinutes,
        ),
        cooldown: ticket.cooldown,
      );
    } on Object catch (error) {
      return _failure(error);
    }
  }

  /// Confirms the signed-in account's email with a verify-email code.
  Future<AccountActionResult> verifyEmail(String code) async {
    final security = _security;
    if (security == null || _session == null) {
      return AccountActionResult.failure(AppStrings.current.signInFirst);
    }
    if (code.trim().isEmpty) {
      return AccountActionResult.failure(AppStrings.current.enterEmailCode);
    }
    try {
      final current = await authorizedRequest(
        (token) => security.verifyEmail(accessToken: token, code: code.trim()),
      );
      final active = _session;
      if (active != null && active.account.id == current.account.id) {
        _setState(
          status: _status,
          session: AuthSession(
            accessToken: active.accessToken,
            accessTokenExpiresAt: active.accessTokenExpiresAt,
            refreshToken: active.refreshToken,
            refreshTokenExpiresAt: active.refreshTokenExpiresAt,
            account: current.account,
            device: current.device,
          ),
        );
      }
      return AccountActionResult.success(
        message: AppStrings.current.emailVerifiedDone,
      );
    } on Object catch (error) {
      return _failure(error);
    }
  }

  /// Changes the password; the server signs out the account's other devices.
  Future<AccountActionResult> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final security = _security;
    if (security == null || _session == null) {
      return AccountActionResult.failure(AppStrings.current.signInFirst);
    }
    if (currentPassword.isEmpty) {
      return AccountActionResult.failure(
        AppStrings.current.enterCurrentPassword,
      );
    }
    if (!CredentialRules.isValidNewPassword(newPassword)) {
      return AccountActionResult.failure(
        CredentialRules.newPasswordRuleMessage,
      );
    }
    try {
      await authorizedRequest(
        (token) => security.changePassword(
          accessToken: token,
          currentPassword: currentPassword,
          newPassword: newPassword,
        ),
      );
      return AccountActionResult.success(
        message: AppStrings.current.passwordChangedDone,
      );
    } on Object catch (error) {
      return _failure(error);
    }
  }

  /// Permanently deletes the signed-in account (confirmed with [password],
  /// or with a delete-account [emailCode] when it has no password) and
  /// signs this device out. Local data on this computer is kept.
  Future<AccountActionResult> deleteAccount({
    String? password,
    String? emailCode,
  }) async {
    final security = _security;
    if (security == null || _session == null) {
      return AccountActionResult.failure(AppStrings.current.signInFirst);
    }
    if (busy) {
      return AccountActionResult.failure(AppStrings.current.tryAgainShortly);
    }
    try {
      await authorizedRequest(
        (token) => security.deleteAccount(
          accessToken: token,
          password: password,
          emailCode: emailCode?.trim(),
        ),
      );
    } on Object catch (error) {
      return _failure(error);
    }
    // The account and all its tokens are gone server-side; only local
    // state is left to clear. Stop rotations first, exactly like logout.
    _restoreRetryAvailable = false;
    _logoutBarrierUp = true;
    try {
      final inFlight = _rotationInFlight;
      if (inFlight != null) {
        try {
          await inFlight;
        } on Object {
          // The account no longer exists; the rotation failing is expected.
        }
      }
      _generation++;
      try {
        await _accountCriticalSection(() => _tokenStore!.delete());
      } on Object {
        // The stored token is already dead server-side.
      }
      _setState(
        status: AccountSessionStatus.signedOut,
        clearSession: true,
        message: AppStrings.current.accountDeletedWithCloud,
      );
    } finally {
      _logoutBarrierUp = false;
    }
    return AccountActionResult.success(
      message: AppStrings.current.accountDeleted,
    );
  }

  AccountActionResult _failure(Object error) {
    return AccountActionResult.failure(
      _messageFor(error),
      cooldown: error is AccountApiException ? error.retryAfter : null,
    );
  }

  /// Mirrors the server's format checks so malformed input gets a precise
  /// message. Registration applies the new-password policy; a login only
  /// needs a non-empty password within the length cap.
  static String? _credentialFormatError(
    String email,
    String password, {
    required bool register,
  }) {
    if (!CredentialRules.isValidEmail(email)) {
      return CredentialRules.invalidEmailMessage;
    }
    if (register) {
      return CredentialRules.isValidNewPassword(password)
          ? null
          : CredentialRules.newPasswordLengthMessage;
    }
    if (password.isEmpty) return CredentialRules.loginPasswordMessage;
    return CredentialRules.isAcceptableLoginPassword(password)
        ? null
        : CredentialRules.loginPasswordTooLongMessage;
  }

  Future<bool> refreshAccount() async {
    if (!configured || busy || _session == null) return false;
    _setState(status: AccountSessionStatus.working, clearMessage: true);
    try {
      var active = _session!;
      if (!active.accessTokenExpiresAt.isAfter(
        _now().toUtc().add(const Duration(seconds: 30)),
      )) {
        final stored = await _tokenStore!.read();
        if (stored == null) throw _freshLoginRequired();
        active = await _rotateShared();
      }

      CurrentAccount current;
      try {
        current = await _api!.currentAccount(accessToken: active.accessToken);
      } on AccountApiException catch (error) {
        if (error.code != 'AUTH_REQUIRED') rethrow;
        final stored = await _tokenStore!.read();
        if (stored == null) throw _freshLoginRequired();
        active = await _rotateShared();
        current = await _api!.currentAccount(accessToken: active.accessToken);
      }

      final refreshed = AuthSession(
        accessToken: active.accessToken,
        accessTokenExpiresAt: active.accessTokenExpiresAt,
        refreshToken: active.refreshToken,
        refreshTokenExpiresAt: active.refreshTokenExpiresAt,
        account: current.account,
        device: current.device,
      );
      _setState(
        status: AccountSessionStatus.signedIn,
        session: refreshed,
        clearMessage: true,
      );
      return true;
    } on Object catch (error) {
      if (_requiresFreshLogin(error)) {
        await _deleteStoredTokenBestEffort(
          expectedRefreshToken: _session?.refreshToken,
        );
        _setState(
          status: AccountSessionStatus.signedOut,
          clearSession: true,
          message: _messageFor(error),
        );
      } else {
        _setState(
          status: AccountSessionStatus.signedIn,
          message: _messageFor(error),
        );
      }
      return false;
    }
  }

  Future<void> logout() async {
    if (!configured || busy) return;
    _restoreRetryAvailable = false;
    // Raise the barrier first: a request that cleared its session check
    // before logout could otherwise start a rotation after the generation
    // bump, capture the bumped generation, pass the persist gate, and write
    // a live refresh token back after the store is wiped. Rotations already
    // in flight stay allowed and are awaited below.
    _logoutBarrierUp = true;
    try {
      // Drop the session up front: authorizedRequest refuses new work while
      // _session is null, and the barrier raised above stops any request
      // that already got past that check from rotating again.
      _setState(
        status: AccountSessionStatus.working,
        clearSession: true,
        clearMessage: true,
      );
      // Let a background rotation settle first so the revocation below
      // targets the newest refresh token. Rotations started from here on are
      // refused by the barrier until logout finishes.
      final inFlight = _rotationInFlight;
      if (inFlight != null) {
        try {
          await inFlight;
        } on Object {
          // A failed rotation leaves the pre-rotation token in the store; it
          // is revoked below.
        }
      }
      _generation++;
      Object? remoteError;
      Object? storageError;
      await _accountCriticalSection(() async {
        StoredRefreshSession? stored;
        try {
          stored = await _tokenStore!.read();
        } on Object catch (error) {
          // Without the stored token the revocation below cannot target the
          // right session; local deletion still runs.
          remoteError = error;
        }
        if (stored != null) {
          try {
            await _api!.logout(
              refreshToken: stored.refreshToken,
              idempotencyKey: _idempotencyKeyFactory(),
            );
          } on Object catch (error) {
            remoteError = error;
          }
        }
        try {
          await _tokenStore!.delete();
        } on Object catch (error) {
          storageError = error;
        }
      });
      _setState(
        status: AccountSessionStatus.signedOut,
        clearSession: true,
        message: storageError != null
            ? AppStrings.current.signedOutStorageFailed
            : remoteError != null
            ? AppStrings.current.signedOutRemoteFailed
            : AppStrings.current.signedOutSafely,
      );
    } finally {
      _logoutBarrierUp = false;
    }
  }

  void clearMessage() {
    if (_message == null) return;
    _message = null;
    notifyListeners();
  }

  Future<AuthSession> _rotate(int generation) =>
      _accountCriticalSection(() async {
        // Another process may have rotated the token while this process waited
        // for the lock. Always reload it inside the critical section.
        final latest = await _tokenStore!.read();
        if (latest == null) throw _freshLoginRequired();
        final operationKey =
            latest.pendingRefreshIdempotencyKey ?? _idempotencyKeyFactory();
        if (latest.pendingRefreshIdempotencyKey == null) {
          await _tokenStore.write(
            StoredRefreshSession(
              refreshToken: latest.refreshToken,
              pendingRefreshIdempotencyKey: operationKey,
            ),
          );
        }
        try {
          final rotated = await _api!.refresh(
            refreshToken: latest.refreshToken,
            idempotencyKey: operationKey,
          );
          if (generation == _generation) {
            await _persistSessionUnlocked(rotated);
          }
          return rotated;
        } on Object catch (error) {
          if (_requiresFreshLogin(error)) await _tokenStore.delete();
          rethrow;
        }
      });

  Future<AuthSession> _rotateShared() {
    if (_logoutBarrierUp) throw _freshLoginRequired();
    final active = _rotationInFlight;
    if (active != null) return active;
    final generation = _generation;
    final rotation = _rotate(generation);
    _rotationInFlight = rotation;
    return rotation.whenComplete(() {
      if (identical(_rotationInFlight, rotation)) _rotationInFlight = null;
    });
  }

  Future<void> _persistSession(AuthSession session) {
    return _accountCriticalSection(() => _persistSessionUnlocked(session));
  }

  Future<void> _persistSessionUnlocked(AuthSession session) {
    return _tokenStore!.write(
      StoredRefreshSession(refreshToken: session.refreshToken),
    );
  }

  Future<void> _revokeSessionBestEffort(String refreshToken) async {
    try {
      await _api!.logout(
        refreshToken: refreshToken,
        idempotencyKey: _idempotencyKeyFactory(),
      );
    } on Object {
      // The session was never persisted and will expire server-side.
    }
  }

  Future<void> _deleteStoredTokenBestEffort({
    required String? expectedRefreshToken,
  }) async {
    try {
      await _accountCriticalSection(() async {
        final stored = await _tokenStore?.read();
        if (stored == null ||
            (expectedRefreshToken != null &&
                stored.refreshToken != expectedRefreshToken)) {
          return;
        }
        await _tokenStore?.delete();
      });
    } on Object {
      // The UI still signs out; a later logout attempt can retry deletion.
    }
  }

  bool _requiresFreshLogin(Object error) {
    return error is AccountApiException &&
        const <String>{
          'AUTH_REQUIRED',
          'INVALID_CREDENTIALS',
          'REFRESH_TOKEN_REUSED',
        }.contains(error.code);
  }

  AccountApiException _freshLoginRequired() {
    return AccountApiException(
      code: 'AUTH_REQUIRED',
      message: AppStrings.current.sessionExpired,
    );
  }

  String _messageFor(Object error) {
    if (error is AccountApiException) {
      // 请求 ID 只用于排查，不展示给用户；server 端日志可按时间与账号定位。
      if (error.requestId != null) {
        debugPrint(
          'Account request failed (${error.code}, '
          'requestId: ${error.requestId})',
        );
      }
      return error.message;
    }
    // Platform openers throw UnsupportedError with user-facing copy (e.g.
    // "当前平台暂不支持第三方登录。"); pass it through instead of masking
    // it with a generic credential failure.
    if (error is UnsupportedError && error.message != null) {
      return error.message!;
    }
    return AppStrings.current.credentialFailure;
  }

  /// Applies a rotated session after a successful token refresh. Login,
  /// bind and restore flows own the `working`/`restoring` status while they
  /// run; a background refresh (auto-sync firing mid-bind) must not flip
  /// that status back to `signedIn` or clear their message slot — it only
  /// swaps the live session in place.
  void _applyRotatedSession(AuthSession active) {
    final flowOwnsStatus =
        _status == AccountSessionStatus.working ||
        _status == AccountSessionStatus.restoring;
    if (flowOwnsStatus) {
      _session = active;
      notifyListeners();
      return;
    }
    _setState(
      status: AccountSessionStatus.signedIn,
      session: active,
      clearMessage: true,
    );
  }

  void _setState({
    required AccountSessionStatus status,
    AuthSession? session,
    bool clearSession = false,
    String? message,
    bool clearMessage = false,
  }) {
    _status = status;
    if (clearSession) {
      _session = null;
    } else if (session != null) {
      _session = session;
    }
    if (clearMessage) {
      _message = null;
    } else if (message != null) {
      _message = message;
    }
    notifyListeners();
  }
}

String _newUUID() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final encoded = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${encoded.substring(0, 8)}-'
      '${encoded.substring(8, 12)}-'
      '${encoded.substring(12, 16)}-'
      '${encoded.substring(16, 20)}-'
      '${encoded.substring(20)}';
}
