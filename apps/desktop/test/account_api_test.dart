import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jianhe_desktop/features/account/account_api.dart';

void main() {
  test('login sends the documented credentials and device payload', () async {
    late http.Request captured;
    final api = AccountApi(
      baseUri: Uri.parse('https://jianhe.neodaas.com'),
      client: MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode(_sessionJson()), 200);
      }),
    );

    final session = await api.login(
      email: 'person@example.com',
      password: 'long-password',
      deviceName: 'DESKTOP-TEST',
      platform: 'windows',
      appVersion: '0.1.0',
    );

    expect(captured.method, 'POST');
    expect(captured.url.toString(), 'https://jianhe.neodaas.com/v1/auth/login');
    expect(jsonDecode(captured.body), <String, Object?>{
      'email': 'person@example.com',
      'password': 'long-password',
      'device': <String, Object?>{
        'name': 'DESKTOP-TEST',
        'platform': 'windows',
        'app_version': '0.1.0',
      },
    });
    expect(session.account.email, 'person@example.com');
    expect(session.account.entitlement.isVip, isFalse);
  });

  test('refresh sends idempotency key and parses rotated tokens', () async {
    final api = AccountApi(
      baseUri: Uri.parse('https://jianhe.neodaas.com'),
      client: MockClient((request) async {
        expect(request.headers['idempotency-key'], 'refresh-operation');
        expect(jsonDecode(request.body), <String, Object?>{
          'refresh_token': 'old-refresh',
        });
        return http.Response(jsonEncode(_sessionJson()), 200);
      }),
    );

    final session = await api.refresh(
      refreshToken: 'old-refresh',
      idempotencyKey: 'refresh-operation',
    );

    expect(session.refreshToken, 'refresh-token');
  });

  test('server errors retain stable code, message, and request id', () async {
    final api = AccountApi(
      baseUri: Uri.parse('https://jianhe.neodaas.com'),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(<String, Object?>{
            'error': <String, Object?>{
              'code': 'INVALID_CREDENTIALS',
              'message': '邮箱或密码错误。',
              'request_id': 'request-123',
              'retryable': false,
            },
          }),
          401,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        ),
      ),
    );

    expect(
      () => api.login(
        email: 'person@example.com',
        password: 'long-password',
        deviceName: 'DESKTOP-TEST',
        platform: 'windows',
        appVersion: '0.1.0',
      ),
      throwsA(
        isA<AccountApiException>()
            .having((error) => error.code, 'code', 'INVALID_CREDENTIALS')
            .having((error) => error.requestId, 'requestId', 'request-123')
            .having((error) => error.retryable, 'retryable', isFalse),
      ),
    );
  });
}

Map<String, Object?> _sessionJson() => <String, Object?>{
  'access_token': 'access-token',
  'access_token_expires_at': '2026-09-03T10:15:00Z',
  'refresh_token': 'refresh-token',
  'refresh_token_expires_at': '2026-10-03T10:00:00Z',
  'account': <String, Object?>{
    'id': 'account-id',
    'email': 'person@example.com',
    'email_verified': false,
    'entitlement': <String, Object?>{
      'plan': 'free',
      'vip_expires_at': null,
      'cloud_backup_upload_allowed': false,
      'cloud_backup_download_allowed': false,
    },
  },
  'device': <String, Object?>{'id': 'device-id', 'name': 'DESKTOP-TEST'},
};
