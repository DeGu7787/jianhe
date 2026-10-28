import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jianhe_desktop/features/account/account_api.dart';
import 'package:jianhe_desktop/features/feedback/feedback_api.dart';

void main() {
  test('creates feedback with bearer token', () async {
    final api = FeedbackApi(
      baseUri: Uri.parse('https://api.example.com'),
      client: MockClient((request) async {
        expect(request.url.path, '/v1/feedback');
        expect(request.headers['Authorization'], 'Bearer access');
        expect(jsonDecode(request.body), <String, Object?>{'content': '应用打不开'});
        return http.Response(
          jsonEncode(<String, Object?>{
            'id': 'feedback-id',
            'status': 'pending',
            'created_at': '2026-09-20T10:00:00Z',
          }),
          201,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );

    final created = await api.create(accessToken: 'access', content: '应用打不开');
    expect(created.id, 'feedback-id');
    expect(created.status, 'pending');
  });

  test('maps missing endpoint to unsupported service', () async {
    final api = FeedbackApi(
      baseUri: Uri.parse('https://api.example.com'),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(<String, Object?>{
            'error': <String, Object?>{
              'code': 'NOT_FOUND',
              'message': 'missing',
            },
          }),
          404,
        ),
      ),
    );

    await expectLater(
      api.create(accessToken: 'access', content: 'test'),
      throwsA(
        isA<AccountApiException>().having(
          (error) => error.code,
          'code',
          'FEEDBACK_UNSUPPORTED',
        ),
      ),
    );
  });
}
