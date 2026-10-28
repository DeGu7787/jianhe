import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../l10n/app_strings.dart';
import '../../l10n/server_error_text.dart';
import '../account/account_api.dart';
import 'sync_models.dart';

/// Media type the server requires on `PUT /v1/sync/blobs/{sha256}`
/// (`cloudsync.BlobContentType`); any other type is rejected as
/// INVALID_REQUEST.
const syncBlobContentType = 'application/vnd.jianhe.sync-envelope.v1';

/// Incremental sync protocol v1 endpoints (docs/cloud-sync-protocol-v1.md
/// §6). Errors surface as [AccountApiException] with the server's `code`
/// (e.g. `CURSOR_EXPIRED`, `SYNC_QUOTA_EXCEEDED`) so callers can branch on
/// protocol semantics.
abstract interface class SyncRemoteDataSource {
  Future<SyncStateInfo> state({required String accessToken});

  /// One page of the account's live winning entities for a full resync
  /// (protocol §6.6). [afterType]/[afterId] form the keyset cursor; both
  /// null starts from the beginning.
  Future<SyncSnapshotResponse> snapshot({
    required String accessToken,
    String? afterType,
    String? afterId,
    int limit,
  });

  Future<SyncPushResponse> push({
    required String accessToken,
    required String idempotencyKey,
    required String deviceId,
    required List<SyncPushChange> changes,
  });

  Future<SyncPullResponse> pull({
    required String accessToken,
    required int cursor,
    int limit,
  });

  /// Returns true when the blob already exists on the server.
  Future<bool> headBlob({required String accessToken, required String sha256});

  Future<void> putBlob({
    required String accessToken,
    required String sha256,
    required List<int> container,
  });

  Future<List<int>> getBlob({
    required String accessToken,
    required String sha256,
  });

  Future<void> reportCursor({required String accessToken, required int cursor});
}

class SyncApi implements SyncRemoteDataSource {
  SyncApi({
    required Uri baseUri,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 60),
    this.blobTimeout = const Duration(minutes: 10),
  }) : _baseUri = _validateBaseUri(baseUri),
       _client = client ?? http.Client();

  final Uri _baseUri;
  final http.Client _client;
  final Duration requestTimeout;
  final Duration blobTimeout;

  @override
  Future<SyncStateInfo> state({required String accessToken}) async {
    final response = await _send(
      _request('GET', '/v1/sync/state', accessToken),
    );
    return SyncStateInfo.fromJson(await _successJson(response, 200));
  }

  @override
  Future<SyncSnapshotResponse> snapshot({
    required String accessToken,
    String? afterType,
    String? afterId,
    int limit = 200,
  }) async {
    final endpoint = _endpoint('/v1/sync/state').replace(
      queryParameters: <String, String>{
        'snapshot': 'full',
        if (afterType != null) 'after_type': afterType,
        if (afterType != null && afterId != null) 'after_id': afterId,
        'limit': '$limit',
      },
    );
    final response = await _send(
      http.Request('GET', endpoint)
        ..headers.addAll(<String, String>{
          'Accept': 'application/json',
          'Accept-Language': cloudAcceptLanguage(),
          'Authorization': 'Bearer $accessToken',
        }),
    );
    return SyncSnapshotResponse.fromJson(await _successJson(response, 200));
  }

  @override
  Future<SyncPushResponse> push({
    required String accessToken,
    required String idempotencyKey,
    required String deviceId,
    required List<SyncPushChange> changes,
  }) async {
    final request = _request('POST', '/v1/sync/changes', accessToken)
      ..headers['Idempotency-Key'] = idempotencyKey
      ..body = jsonEncode(<String, Object?>{
        'device_id': deviceId,
        'changes': [for (final change in changes) change.toJson()],
      });
    final response = await _send(request);
    return SyncPushResponse.fromJson(await _successJson(response, 200));
  }

  @override
  Future<SyncPullResponse> pull({
    required String accessToken,
    required int cursor,
    int limit = 200,
  }) async {
    final endpoint = _endpoint('/v1/sync/changes').replace(
      queryParameters: <String, String>{'cursor': '$cursor', 'limit': '$limit'},
    );
    final response = await _send(
      http.Request('GET', endpoint)
        ..headers.addAll(<String, String>{
          'Accept': 'application/json',
          'Accept-Language': cloudAcceptLanguage(),
          'Authorization': 'Bearer $accessToken',
        }),
    );
    return SyncPullResponse.fromJson(await _successJson(response, 200));
  }

  @override
  Future<bool> headBlob({
    required String accessToken,
    required String sha256,
  }) async {
    final response = await _send(
      _request('HEAD', '/v1/sync/blobs/$sha256', accessToken),
    );
    if (response.statusCode == 200) return true;
    if (response.statusCode == 404) return false;
    await _throwResponseError(response);
  }

  @override
  Future<void> putBlob({
    required String accessToken,
    required String sha256,
    required List<int> container,
  }) async {
    final request = _request('PUT', '/v1/sync/blobs/$sha256', accessToken)
      ..bodyBytes = container
      ..headers['Content-Type'] = syncBlobContentType;
    final response = await _send(request, timeout: blobTimeout);
    await _successBody(response, 201);
  }

  @override
  Future<List<int>> getBlob({
    required String accessToken,
    required String sha256,
  }) async {
    final response = await _send(
      _request('GET', '/v1/sync/blobs/$sha256', accessToken),
      timeout: blobTimeout,
    );
    if (response.statusCode != 200) await _throwResponseError(response);
    final etag = response.headers['etag']?.replaceAll('"', '');
    if (etag != null && etag != sha256) {
      throw AccountApiException(
        code: 'INVALID_SERVER_RESPONSE',
        message: AppStrings.current.skillBlobMismatch,
        requestId: response.headers['x-request-id'],
      );
    }
    // Blob bodies can be tens of MiB; they need the blob timeout, not the
    // 60s request timeout (which only covered the response headers).
    return _readBodyBytes(response, timeout: blobTimeout);
  }

  @override
  Future<void> reportCursor({
    required String accessToken,
    required int cursor,
  }) async {
    final request = _request('POST', '/v1/sync/cursor', accessToken)
      ..body = jsonEncode(<String, Object?>{'cursor': cursor});
    final response = await _send(request);
    await _successBody(response, 200);
  }

  http.Request _request(String method, String path, String accessToken) {
    return http.Request(method, _endpoint(path))
      ..headers.addAll(<String, String>{
        'Accept': 'application/json',
        'Accept-Language': cloudAcceptLanguage(),
        'Authorization': 'Bearer $accessToken',
      });
  }

  Future<http.StreamedResponse> _send(
    http.BaseRequest request, {
    Duration? timeout,
  }) async {
    try {
      return await _client.send(request).timeout(timeout ?? requestTimeout);
    } on TimeoutException {
      throw _networkTimeout();
    } on http.ClientException {
      throw _networkError();
    }
  }

  Future<List<int>> _readBodyBytes(
    http.StreamedResponse response, {
    Duration? timeout,
  }) async {
    try {
      return await response.stream
          .toBytes()
          .timeout(timeout ?? requestTimeout);
    } on TimeoutException {
      throw _networkTimeout();
    } on http.ClientException {
      // A connection can fail after the response headers have arrived. The
      // request itself then succeeds, but consuming the body stream reports
      // the network failure. Keep it in the same retryable error contract as
      // failures raised by Client.send.
      throw _networkError();
    }
  }

  Future<Map<String, Object?>> _successJson(
    http.StreamedResponse response,
    int expected,
  ) async {
    if (response.statusCode != expected) await _throwResponseError(response);
    try {
      final decoded = jsonDecode(utf8.decode(await _readBodyBytes(response)));
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // Converted to a stable client-side protocol error below.
    }
    throw _invalidResponse(response.headers['x-request-id']);
  }

  Future<void> _successBody(
    http.StreamedResponse response,
    int expected,
  ) async {
    if (response.statusCode != expected) await _throwResponseError(response);
    await _readBodyBytes(response);
  }

  Future<Never> _throwResponseError(http.StreamedResponse response) async {
    var code = 'SERVER_ERROR';
    var message = AppStrings.current.syncServiceUnavailable;
    var fromServer = false;
    var retryable = response.statusCode >= 500;
    var requestId = response.headers['x-request-id'];
    try {
      final decoded = jsonDecode(utf8.decode(await _readBodyBytes(response)));
      final root = decoded is Map ? decoded.cast<String, Object?>() : null;
      final error = root?['error'];
      final errorMap = error is Map ? error.cast<String, Object?>() : null;
      if (errorMap?['code'] case final String value when value.isNotEmpty) {
        code = value;
      }
      if (errorMap?['message'] case final String value when value.isNotEmpty) {
        message = value;
        fromServer = true;
      }
      if (errorMap?['retryable'] case final bool value) retryable = value;
      if (errorMap?['request_id'] case final String value
          when value.isNotEmpty) {
        requestId = value;
      }
    } on FormatException {
      // Keep the stable fallback.
    }
    throw AccountApiException(
      code: code,
      message: fromServer
          ? localizeServerError(code: code, serverMessage: message)
          : message,
      requestId: requestId,
      retryable: retryable,
    );
  }

  AccountApiException _networkTimeout() => AccountApiException(
    code: 'NETWORK_TIMEOUT',
    message: AppStrings.current.syncServiceTimeout,
    retryable: true,
  );

  AccountApiException _networkError() => AccountApiException(
    code: 'NETWORK_ERROR',
    message: AppStrings.current.syncServiceUnreachable,
    retryable: true,
  );

  AccountApiException _invalidResponse([String? requestId]) {
    return AccountApiException(
      code: 'INVALID_SERVER_RESPONSE',
      message: AppStrings.current.syncServiceBadResponse,
      requestId: requestId,
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
