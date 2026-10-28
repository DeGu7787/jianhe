import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../l10n/app_strings.dart';
import '../../l10n/server_error_text.dart';
import 'account_models.dart';
import 'vip_billing.dart';

abstract interface class ExternalAuthRemote {
  Future<ExternalAuthStart> beginExternal({
    required String provider,
    required String verifierHash,
    String? accessToken,
  });
  Future<AuthSession> finishExternal({
    required String provider,
    required String flowId,
    required String verifier,
    required String deviceName,
    required String platform,
    required String appVersion,
  });
}

class ExternalAuthStart {
  const ExternalAuthStart(this.flowId, this.authorizationUrl);
  final String flowId;
  final Uri authorizationUrl;
}

String _requiredExternalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw const FormatException('Invalid external auth response.');
}

class AccountApiException implements Exception {
  const AccountApiException({
    required this.code,
    required this.message,
    this.requestId,
    this.retryable = false,
    this.retryAfter,
  });

  final String code;
  final String message;
  final String? requestId;
  final bool retryable;

  /// How long to wait before retrying, from `details.retry_after_seconds`.
  final Duration? retryAfter;

  @override
  String toString() => 'AccountApiException($code, requestId: $requestId)';
}

/// Purposes of a mailed verification code (server contract §7.6).
enum EmailCodePurpose {
  register('register'),
  resetPassword('reset_password'),
  verifyEmail('verify_email'),
  deleteAccount('delete_account');

  const EmailCodePurpose(this.wireValue);
  final String wireValue;
}

/// Answer to a successful code request.
class EmailCodeTicket {
  const EmailCodeTicket({required this.cooldown, required this.expiresIn});

  factory EmailCodeTicket.fromJson(Map<String, Object?> json) {
    final cooldown = json['cooldown_seconds'];
    final expiresIn = json['expires_in_seconds'];
    return EmailCodeTicket(
      cooldown: Duration(
        seconds: cooldown is int && cooldown > 0 ? cooldown : 60,
      ),
      expiresIn: Duration(
        seconds: expiresIn is int && expiresIn > 0 ? expiresIn : 600,
      ),
    );
  }

  /// How long before another code may be requested.
  final Duration cooldown;

  /// How long the mailed code stays valid.
  final Duration expiresIn;
}

/// Email codes, password reset and change, email verification and account
/// deletion. A separate interface so data sources without it (older test
/// doubles) keep compiling; the UI hides these features for them.
abstract interface class AccountSecurityRemote {
  /// register or resetPassword, before signing in.
  Future<EmailCodeTicket> requestEmailCode({
    required String email,
    required EmailCodePurpose purpose,
  });

  Future<AuthSession> registerWithCode({
    required String email,
    required String password,
    required String emailCode,
    required String deviceName,
    required String platform,
    required String appVersion,
  });

  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  });

  /// verifyEmail or deleteAccount, sent to the signed-in account's email.
  Future<EmailCodeTicket> requestAccountEmailCode({
    required String accessToken,
    required EmailCodePurpose purpose,
  });

  Future<CurrentAccount> verifyEmail({
    required String accessToken,
    required String code,
  });

  Future<void> changePassword({
    required String accessToken,
    required String currentPassword,
    required String newPassword,
  });

  /// Confirms with [password] when given, otherwise with [emailCode].
  Future<void> deleteAccount({
    required String accessToken,
    String? password,
    String? emailCode,
  });
}

abstract interface class AccountRemoteDataSource {
  Future<AuthSession> register({
    required String email,
    required String password,
    required String deviceName,
    required String platform,
    required String appVersion,
  });

  Future<AuthSession> login({
    required String email,
    required String password,
    required String deviceName,
    required String platform,
    required String appVersion,
  });

  Future<AuthSession> refresh({
    required String refreshToken,
    required String idempotencyKey,
  });

  Future<void> logout({
    required String refreshToken,
    required String idempotencyKey,
  });

  Future<CurrentAccount> currentAccount({required String accessToken});
}

class AccountApi
    implements
        AccountRemoteDataSource,
        AccountSecurityRemote,
        ExternalAuthRemote,
        VipBillingRemote {
  AccountApi({
    required Uri baseUri,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _baseUri = _validateBaseUri(baseUri),
       _client = client ?? http.Client();

  final Uri _baseUri;
  final http.Client _client;
  final Duration timeout;

  @override
  Future<ExternalAuthStart> beginExternal({
    required String provider,
    required String verifierHash,
    String? accessToken,
  }) async {
    final response = await _post(
      '/v1/auth/external/$provider/start',
      body: <String, Object?>{'verifier_hash': verifierHash},
      accessToken: accessToken,
    );
    final json = _successJson(response, 200);
    return ExternalAuthStart(
      _requiredExternalString(json, 'flow_id'),
      Uri.parse(_requiredExternalString(json, 'authorization_url')),
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
    final response = await _post(
      '/v1/auth/external/$provider/finish',
      body: <String, Object?>{
        'flow_id': flowId,
        'verifier': verifier,
        'device': <String, Object?>{
          'name': deviceName,
          'platform': platform,
          'app_version': appVersion,
        },
      },
    );
    return AuthSession.fromJson(_successJson(response, 200));
  }

  @override
  Future<AuthSession> register({
    required String email,
    required String password,
    required String deviceName,
    required String platform,
    required String appVersion,
  }) async {
    final response = await _post(
      '/v1/auth/register',
      body: _credentialsBody(email, password, deviceName, platform, appVersion),
    );
    return AuthSession.fromJson(_successJson(response, 201));
  }

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
    required String deviceName,
    required String platform,
    required String appVersion,
  }) async {
    final response = await _post(
      '/v1/auth/login',
      body: _credentialsBody(email, password, deviceName, platform, appVersion),
    );
    return AuthSession.fromJson(_successJson(response, 200));
  }

  @override
  Future<AuthSession> refresh({
    required String refreshToken,
    required String idempotencyKey,
  }) async {
    final response = await _post(
      '/v1/auth/refresh',
      body: <String, Object?>{'refresh_token': refreshToken},
      idempotencyKey: idempotencyKey,
    );
    return AuthSession.fromJson(_successJson(response, 200));
  }

  @override
  Future<void> logout({
    required String refreshToken,
    required String idempotencyKey,
  }) async {
    final response = await _post(
      '/v1/auth/logout',
      body: <String, Object?>{'refresh_token': refreshToken},
      idempotencyKey: idempotencyKey,
    );
    if (response.statusCode != 204) _throwResponseError(response);
  }

  @override
  Future<CurrentAccount> currentAccount({required String accessToken}) async {
    final response = await _send(
      () => _client.get(
        _endpoint('/v1/account/me'),
        headers: <String, String>{
          'Accept': 'application/json',
          'Accept-Language': cloudAcceptLanguage(),
          'Authorization': 'Bearer $accessToken',
        },
      ),
    );
    return CurrentAccount.fromJson(_successJson(response, 200));
  }

  @override
  Future<EmailCodeTicket> requestEmailCode({
    required String email,
    required EmailCodePurpose purpose,
  }) async {
    final response = await _post(
      '/v1/auth/email-code',
      body: <String, Object?>{'email': email, 'purpose': purpose.wireValue},
    );
    return EmailCodeTicket.fromJson(_successJson(response, 202));
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
    final response = await _post(
      '/v1/auth/register',
      body: <String, Object?>{
        ..._credentialsBody(email, password, deviceName, platform, appVersion),
        'email_code': emailCode,
      },
    );
    return AuthSession.fromJson(_successJson(response, 201));
  }

  @override
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    final response = await _post(
      '/v1/auth/password/reset',
      body: <String, Object?>{
        'email': email,
        'code': code,
        'new_password': newPassword,
      },
    );
    if (response.statusCode != 204) _throwResponseError(response);
  }

  @override
  Future<EmailCodeTicket> requestAccountEmailCode({
    required String accessToken,
    required EmailCodePurpose purpose,
  }) async {
    final response = await _post(
      '/v1/account/email-code',
      body: <String, Object?>{'purpose': purpose.wireValue},
      accessToken: accessToken,
    );
    return EmailCodeTicket.fromJson(_successJson(response, 202));
  }

  @override
  Future<CurrentAccount> verifyEmail({
    required String accessToken,
    required String code,
  }) async {
    final response = await _post(
      '/v1/account/email/verify',
      body: <String, Object?>{'code': code},
      accessToken: accessToken,
    );
    return CurrentAccount.fromJson(_successJson(response, 200));
  }

  @override
  Future<void> changePassword({
    required String accessToken,
    required String currentPassword,
    required String newPassword,
  }) async {
    final response = await _post(
      '/v1/account/password',
      body: <String, Object?>{
        'current_password': currentPassword,
        'new_password': newPassword,
      },
      accessToken: accessToken,
    );
    if (response.statusCode != 204) _throwResponseError(response);
  }

  @override
  Future<void> deleteAccount({
    required String accessToken,
    String? password,
    String? emailCode,
  }) async {
    final response = await _post(
      '/v1/account/delete',
      body: <String, Object?>{
        if (password != null && password.isNotEmpty) 'password': password,
        if (emailCode != null && emailCode.isNotEmpty) 'email_code': emailCode,
      },
      accessToken: accessToken,
    );
    if (response.statusCode != 204) _throwResponseError(response);
  }

  @override
  Future<VipPlanCatalog> fetchVipPlans() async {
    final response = await _get('/v1/billing/plans');
    return VipPlanCatalog.fromJson(_successJson(response, 200));
  }

  @override
  Future<VipOrder> createVipOrder({
    required String accessToken,
    required String planId,
  }) async {
    final response = await _post(
      '/v1/billing/orders',
      body: <String, Object?>{'plan': planId},
      accessToken: accessToken,
    );
    return VipOrder.fromJson(_successJson(response, 201));
  }

  @override
  Future<VipOrder> fetchVipOrder({
    required String accessToken,
    required String orderNo,
  }) async {
    final response = await _get(
      '/v1/billing/orders/${Uri.encodeComponent(orderNo)}',
      accessToken: accessToken,
    );
    return VipOrder.fromJson(_successJson(response, 200));
  }

  @override
  Future<VipOrder> cancelVipOrder({
    required String accessToken,
    required String orderNo,
  }) async {
    final response = await _post(
      '/v1/billing/orders/${Uri.encodeComponent(orderNo)}/cancel',
      body: const <String, Object?>{},
      accessToken: accessToken,
    );
    return VipOrder.fromJson(_successJson(response, 200));
  }

  @override
  Future<VipOrder> mockPayVipOrder({
    required String accessToken,
    required String orderNo,
    required VipMockPaymentOutcome outcome,
  }) async {
    final response = await _post(
      '/v1/billing/orders/${Uri.encodeComponent(orderNo)}/mock-pay',
      body: <String, Object?>{'outcome': outcome.name},
      accessToken: accessToken,
    );
    return VipOrder.fromJson(_successJson(response, 200));
  }

  Future<http.Response> _get(String path, {String? accessToken}) {
    return _send(
      () => _client.get(
        _endpoint(path),
        headers: <String, String>{
          'Accept': 'application/json',
          'Accept-Language': cloudAcceptLanguage(),
          if (accessToken != null) 'Authorization': 'Bearer $accessToken',
        },
      ),
    );
  }

  Future<http.Response> _post(
    String path, {
    required Map<String, Object?> body,
    String? idempotencyKey,
    String? accessToken,
  }) {
    return _send(
      () => _client.post(
        _endpoint(path),
        headers: <String, String>{
          'Accept': 'application/json',
          'Accept-Language': cloudAcceptLanguage(),
          'Content-Type': 'application/json; charset=utf-8',
          'Idempotency-Key': ?idempotencyKey,
          if (accessToken != null) 'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode(body),
      ),
    );
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(timeout);
    } on TimeoutException {
      throw AccountApiException(
        code: 'NETWORK_TIMEOUT',
        message: AppStrings.current.cloudTimeout,
        retryable: true,
      );
    } on http.ClientException {
      throw AccountApiException(
        code: 'NETWORK_ERROR',
        message: AppStrings.current.cloudUnreachable,
        retryable: true,
      );
    }
  }

  Map<String, Object?> _successJson(http.Response response, int expected) {
    if (response.statusCode != expected) _throwResponseError(response);
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // Converted to a stable client-side protocol error below.
    }
    throw AccountApiException(
      code: 'INVALID_SERVER_RESPONSE',
      message: AppStrings.current.cloudBadResponse,
      requestId: response.headers['x-request-id'],
    );
  }

  Never _throwResponseError(http.Response response) {
    String code = 'SERVER_ERROR';
    String message = AppStrings.current.cloudUnavailable;
    var fromServer = false;
    bool retryable = response.statusCode >= 500;
    String? requestId = response.headers['x-request-id'];
    Duration? retryAfter;
    int? remainingAttempts;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final root = decoded is Map ? decoded.cast<String, Object?>() : null;
      final rawError = root?['error'];
      final error = rawError is Map ? rawError.cast<String, Object?>() : null;
      if (error != null) {
        if (error['code'] case final String value when value.isNotEmpty) {
          code = value;
        }
        if (error['message'] case final String value when value.isNotEmpty) {
          message = value;
          fromServer = true;
        }
        if (error['retryable'] case final bool value) retryable = value;
        if (error['request_id'] case final String value when value.isNotEmpty) {
          requestId = value;
        }
        if (error['details'] case final Map<Object?, Object?> details) {
          if (details['retry_after_seconds'] case final int seconds
              when seconds > 0) {
            retryAfter = Duration(seconds: seconds);
          }
          if (details['remaining_attempts'] case final int remaining) {
            remainingAttempts = remaining;
          }
        }
      }
    } on FormatException {
      // Keep the stable fallback error.
    }
    throw AccountApiException(
      code: code,
      message: fromServer
          ? localizeServerError(
              code: code,
              serverMessage: message,
              retryAfter: retryAfter,
              remainingAttempts: remainingAttempts,
            )
          : message,
      requestId: requestId,
      retryable: retryable,
      retryAfter: retryAfter,
    );
  }

  Uri _endpoint(String path) => _baseUri.replace(path: path);

  static Uri _validateBaseUri(Uri value) {
    // `flutter run -d chrome` serves on loopback http, so local development
    // is allowed there; everything else must stay a genuine HTTPS origin.
    final secure =
        value.scheme == 'https' ||
        (value.scheme == 'http' && _isLoopbackHost(value.host));
    if (!secure ||
        value.host.isEmpty ||
        value.hasQuery ||
        value.hasFragment ||
        (value.path.isNotEmpty && value.path != '/')) {
      throw ArgumentError.value(
        value,
        'baseUri',
        'Must be an HTTPS origin (loopback http is allowed for development).',
      );
    }
    return value.replace(path: '', query: null, fragment: null);
  }

  static bool _isLoopbackHost(String host) {
    if (host == 'localhost' || host == '::1') return true;
    // Exact 127.x.x.x only; a prefix match would also admit hosts like
    // 127.0.0.1.evil.com.
    final parts = host.split('.');
    if (parts.length != 4 || parts.first != '127') return false;
    return parts.skip(1).every((part) {
      final octet = int.tryParse(part);
      return octet != null && octet >= 0 && octet <= 255;
    });
  }
}

Map<String, Object?> _credentialsBody(
  String email,
  String password,
  String deviceName,
  String platform,
  String appVersion,
) {
  return <String, Object?>{
    'email': email,
    'password': password,
    'device': <String, Object?>{
      'name': deviceName,
      'platform': platform,
      'app_version': appVersion,
    },
  };
}
