import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jianhe_core/jianhe_core.dart';
import 'package:jianhe_desktop/features/account/account_api.dart';
import 'package:jianhe_desktop/features/cloud_sync/sync_api.dart';
import 'package:jianhe_desktop/features/cloud_sync/sync_models.dart';

void main() {
  final baseUri = Uri.parse('https://api.example');

  SyncApi apiFor(MockClient handler) =>
      SyncApi(baseUri: baseUri, client: handler);

  test('baseUri accepts https and loopback http, rejects other http', () {
    expect(
      () => SyncApi(baseUri: Uri.parse('https://api.example.com')),
      returnsNormally,
    );
    expect(
      () => SyncApi(baseUri: Uri.parse('http://localhost:8080')),
      returnsNormally,
    );
    expect(
      () => SyncApi(baseUri: Uri.parse('http://127.0.0.1:9000')),
      returnsNormally,
    );
    expect(
      () => SyncApi(baseUri: Uri.parse('http://[::1]:9000')),
      returnsNormally,
    );
    // A host that merely starts with "127." is not a loopback address.
    expect(
      () => SyncApi(baseUri: Uri.parse('http://127.0.0.1.evil.com')),
      throwsArgumentError,
    );
    expect(
      () => SyncApi(baseUri: Uri.parse('http://999.999.999.999')),
      throwsArgumentError,
    );
    expect(
      () => SyncApi(baseUri: Uri.parse('http://api.example.com')),
      throwsArgumentError,
    );

    expect(
      () => AccountApi(baseUri: Uri.parse('http://localhost:8080')),
      returnsNormally,
    );
    expect(
      () => AccountApi(baseUri: Uri.parse('http://api.example.com')),
      throwsArgumentError,
    );
  });

  test('state parses head, window and quota', () async {
    late http.Request captured;
    final api = apiFor(
      MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'head_seq': 1042,
            'window_start': 930,
            'quota': <String, Object?>{
              'used_bytes': 5242880,
              'max_bytes': 209715200,
            },
            'format_versions': <String, Object?>{'envelope': 1},
          }),
          200,
        );
      }),
    );

    final state = await api.state(accessToken: 'token-1');

    expect(captured.method, 'GET');
    expect(captured.url.path, '/v1/sync/state');
    expect(captured.headers['Authorization'], 'Bearer token-1');
    expect(state.headSeq, 1042);
    expect(state.windowStart, 930);
    expect(state.quotaUsedBytes, 5242880);
    expect(state.quotaMaxBytes, 209715200);
  });

  test('push sends device, idempotency key and base64 envelopes', () async {
    late http.Request captured;
    final api = apiFor(
      MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'head_seq': 1043,
            'results': <Object?>[
              <String, Object?>{
                'entity_type': 'item:snippet',
                'entity_id': 'entity-1',
                'accepted': true,
                'change_seq': 1043,
              },
              <String, Object?>{
                'entity_type': 'item:snippet',
                'entity_id': 'entity-2',
                'accepted': false,
                'reason': 'LOST_LWW',
              },
            ],
          }),
          200,
        );
      }),
    );

    final response = await api.push(
      accessToken: 'token-1',
      idempotencyKey: '11111111-1111-4111-8111-111111111111',
      deviceId: 'device-1',
      changes: [
        SyncPushChange(
          entityType: SyncEntityType.itemSnippet,
          entityId: 'entity-1',
          updatedAt: DateTime.utc(2026, 9, 10, 8),
          envelope: utf8.encode('envelope-bytes'),
        ),
        SyncPushChange(
          entityType: SyncEntityType.itemSnippet,
          entityId: 'entity-2',
          updatedAt: DateTime.utc(2026, 9, 10, 8),
          deleted: true,
        ),
      ],
    );

    expect(captured.method, 'POST');
    expect(captured.url.path, '/v1/sync/changes');
    expect(
      captured.headers['Idempotency-Key'],
      '11111111-1111-4111-8111-111111111111',
    );
    final body = jsonDecode(captured.body) as Map<String, Object?>;
    expect(body['device_id'], 'device-1');
    final changes = body['changes']! as List<Object?>;
    expect(changes, hasLength(2));
    expect(
      (changes.first! as Map<String, Object?>)['envelope'],
      base64Encode(utf8.encode('envelope-bytes')),
    );
    expect((changes.last! as Map<String, Object?>)['deleted'], isTrue);
    expect(response.headSeq, 1043);
    expect(response.results.first.accepted, isTrue);
    expect(response.results.first.changeSeq, 1043);
    expect(response.results.last.accepted, isFalse);
    expect(response.results.last.reason, 'LOST_LWW');
  });

  test('pull carries cursor and limit query parameters', () async {
    late http.Request captured;
    final api = apiFor(
      MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'changes': <Object?>[
                <String, Object?>{
                  'change_seq': 1041,
                  'entity_type': 'category:prompt',
                  'entity_id': '工作',
                  'updated_at': '2026-09-10T08:30:00.000Z',
                  'deleted': false,
                  'origin_device_id': 'device-2',
                  'envelope': base64Encode(utf8.encode('cat')),
                },
              ],
              'next_cursor': 1043,
              'head_seq': 1043,
            }),
          ),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );

    final response = await api.pull(accessToken: 'token-1', cursor: 930);

    expect(captured.url.path, '/v1/sync/changes');
    expect(captured.url.queryParameters['cursor'], '930');
    expect(captured.url.queryParameters['limit'], '200');
    expect(response.changes.single.entityType, SyncEntityType.categoryPrompt);
    expect(response.changes.single.entityId, '工作');
    expect(response.changes.single.envelope, utf8.encode('cat'));
    expect(response.nextCursor, 1043);
    expect(response.headSeq, 1043);
  });

  test('snapshot pages carry the keyset cursor and parse records', () async {
    late http.Request captured;
    final api = apiFor(
      MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'changes': <Object?>[
                <String, Object?>{
                  'change_seq': 1041,
                  'entity_type': 'item:snippet',
                  'entity_id': 'entity-1',
                  'updated_at': '2026-09-10T08:30:00.000Z',
                  'deleted': false,
                  'origin_device_id': 'device-2',
                  'envelope': base64Encode(utf8.encode('envelope')),
                },
              ],
              'next_entity_type': 'item:snippet',
              'next_entity_id': 'entity-1',
              'head_seq': 1043,
            }),
          ),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );

    final response = await api.snapshot(
      accessToken: 'token-1',
      afterType: 'category:prompt',
      afterId: '工作',
      limit: 50,
    );

    expect(captured.url.path, '/v1/sync/state');
    expect(captured.url.queryParameters['snapshot'], 'full');
    expect(captured.url.queryParameters['after_type'], 'category:prompt');
    expect(captured.url.queryParameters['after_id'], '工作');
    expect(captured.url.queryParameters['limit'], '50');
    expect(response.changes.single.entityType, SyncEntityType.itemSnippet);
    expect(response.changes.single.envelope, utf8.encode('envelope'));
    expect(response.nextEntityType, 'item:snippet');
    expect(response.nextEntityId, 'entity-1');
    expect(response.headSeq, 1043);
  });

  test('blob channel round trips through HEAD, PUT and GET', () async {
    final container = utf8.encode('blob-container');
    final requests = <http.Request>[];
    final api = apiFor(
      MockClient((request) async {
        requests.add(request);
        if (request.method == 'HEAD' && requests.length == 1) {
          return http.Response('', 404);
        }
        if (request.method == 'PUT') {
          expect(request.bodyBytes, container);
          return http.Response(
            jsonEncode(<String, Object?>{'byte_length': container.length}),
            201,
          );
        }
        if (request.method == 'HEAD') {
          return http.Response('', 200);
        }
        return http.Response.bytes(
          container,
          200,
          headers: <String, String>{'ETag': '"sha-1"'},
        );
      }),
    );

    expect(await api.headBlob(accessToken: 't', sha256: 'sha-1'), isFalse);
    await api.putBlob(accessToken: 't', sha256: 'sha-1', container: container);
    expect(await api.headBlob(accessToken: 't', sha256: 'sha-1'), isTrue);
    expect(await api.getBlob(accessToken: 't', sha256: 'sha-1'), container);

    expect(requests.map((request) => request.method).toList(), <String>[
      'HEAD',
      'PUT',
      'HEAD',
      'GET',
    ]);
    expect(requests[1].url.path, '/v1/sync/blobs/sha-1');
    // The server rejects any other media type as INVALID_REQUEST.
    expect(
      requests[1].headers['Content-Type'],
      'application/vnd.jianhe.sync-envelope.v1',
    );
  });

  test('server error codes surface as AccountApiException', () async {
    final api = apiFor(
      MockClient((request) async {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'error': <String, Object?>{
                'code': 'CURSOR_EXPIRED',
                'message': 'cursor 已滑出窗口',
                'retryable': false,
                'request_id': 'req-1',
              },
            }),
          ),
          410,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );

    await expectLater(
      api.pull(accessToken: 't', cursor: 3),
      throwsA(
        isA<AccountApiException>()
            .having((error) => error.code, 'code', 'CURSOR_EXPIRED')
            .having((error) => error.retryable, 'retryable', isFalse)
            .having((error) => error.requestId, 'requestId', 'req-1'),
      ),
    );
  });

  test('response body connection failures remain retryable', () async {
    final api = SyncApi(baseUri: baseUri, client: _StreamFailureClient());

    await expectLater(
      api.state(accessToken: 'token-1'),
      throwsA(
        isA<AccountApiException>()
            .having((error) => error.code, 'code', 'NETWORK_ERROR')
            .having((error) => error.retryable, 'retryable', isTrue),
      ),
    );
  });

  test('cursor heartbeat posts the reported position', () async {
    late http.Request captured;
    final api = apiFor(
      MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'cursor': 1043,
            'reported_at': '2026-09-10T08:30:00.000Z',
          }),
          200,
        );
      }),
    );

    await api.reportCursor(accessToken: 't', cursor: 1043);

    expect(captured.method, 'POST');
    expect(captured.url.path, '/v1/sync/cursor');
    expect(jsonDecode(captured.body), <String, Object?>{'cursor': 1043});
  });
}

class _StreamFailureClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.error(
        http.ClientException('connection reset while reading', request.url),
      ),
      200,
    );
  }
}
