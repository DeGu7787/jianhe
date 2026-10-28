import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../l10n/app_strings.dart';
import '../../l10n/server_error_text.dart';
import '../account/account_api.dart';
import 'feedback_models.dart';

abstract interface class FeedbackRemoteDataSource {
  Future<FeedbackCreated> create({
    required String accessToken,
    required String content,
  });
}

class FeedbackApi implements FeedbackRemoteDataSource {
  FeedbackApi({
    required Uri baseUri,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _baseUri = baseUri.replace(path: '', query: null, fragment: null),
       _client = client ?? http.Client();

  final Uri _baseUri;
  final http.Client _client;
  final Duration timeout;

  @override
  Future<FeedbackCreated> create({
    required String accessToken,
    required String content,
  }) async {
    late http.Response response;
    try {
      response = await _client
          .post(
            _baseUri.replace(path: '/v1/feedback'),
            headers: <String, String>{
              'Accept': 'application/json',
              'Accept-Language': cloudAcceptLanguage(),
              'Content-Type': 'application/json; charset=utf-8',
              'Authorization': 'Bearer $accessToken',
            },
            body: jsonEncode(<String, Object?>{'content': content}),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw AccountApiException(
        code: 'NETWORK_TIMEOUT',
        message: AppStrings.current.feedbackTimeout,
        retryable: true,
      );
    } on http.ClientException {
      throw AccountApiException(
        code: 'NETWORK_ERROR',
        message: AppStrings.current.cloudUnreachable,
        retryable: true,
      );
    }
    final body = _decode(response);
    if (response.statusCode == 201) {
      return FeedbackCreated.fromJson(body);
    }
    final rawError = body['error'];
    final error = rawError is Map
        ? rawError.cast<String, Object?>()
        : const <String, Object?>{};
    // Soft type checks: a proxy or a different server version may shape
    // these differently, and a hard cast would drop the request id and the
    // retryable semantics with a TypeError.
    final code = error['code'] is String ? error['code'] as String : 'SERVER_ERROR';
    if (response.statusCode == 404 && code == 'NOT_FOUND') {
      throw AccountApiException(
        code: 'FEEDBACK_UNSUPPORTED',
        message: AppStrings.current.feedbackUnsupported,
      );
    }
    throw AccountApiException(
      code: code,
      message: error['message'] is String
          ? localizeServerError(
              code: code,
              serverMessage: error['message'] as String,
            )
          : AppStrings.current.feedbackFailed,
      requestId: error['request_id'] is String
          ? error['request_id'] as String?
          : null,
      retryable: error['retryable'] is bool
          ? error['retryable'] as bool
          : response.statusCode >= 500,
    );
  }

  Map<String, Object?> _decode(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // Stable error below.
    }
    throw AccountApiException(
      code: 'INVALID_SERVER_RESPONSE',
      message: AppStrings.current.cloudBadResponse,
      requestId: response.headers['x-request-id'],
    );
  }
}
