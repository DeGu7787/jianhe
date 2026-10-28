import 'package:jianhe_desktop/features/account/account_api.dart';
import 'package:jianhe_desktop/features/cloud_sync/sync_api.dart';
import 'package:jianhe_desktop/features/cloud_sync/sync_models.dart';

class PushCall {
  PushCall(this.idempotencyKey, this.deviceId, this.changes);

  final String idempotencyKey;
  final String deviceId;
  final List<SyncPushChange> changes;
}

class PullCall {
  PullCall(this.cursor, this.limit);

  final int cursor;
  final int limit;
}

class SnapshotCall {
  SnapshotCall(this.afterType, this.afterId, this.limit);

  final String? afterType;
  final String? afterId;
  final int limit;
}

/// Scriptable SyncRemoteDataSource double shared by engine and controller
/// tests. Queues hold SyncPushResponse/SyncPullResponse values or
/// AccountApiException throws; when exhausted, pushes default to
/// all-accepted and pulls to an empty page.
class FakeSyncApi implements SyncRemoteDataSource {
  int stateCalls = 0;
  final pushCalls = <PushCall>[];
  final pullCalls = <PullCall>[];
  final snapshotCalls = <SnapshotCall>[];
  final reportCursorCalls = <int>[];
  final putBlobCalls = <({String sha256, List<int> container})>[];
  final blobs = <String, List<int>>{};

  final pushQueue = <Object?>[];
  final pullQueue = <Object?>[];
  final snapshotQueue = <Object?>[];

  /// When set, replaces the queued/default push behaviour entirely (used to
  /// mutate local state between send and ack).
  Future<SyncPushResponse> Function(List<SyncPushChange> changes)? pushHook;
  bool Function(String sha256)? headHook;

  /// When set, replaces the blob store lookup (used to gate downloads).
  Future<List<int>> Function(String sha256)? getBlobHook;

  /// When set, replaces the blob upload entirely (used to fail puts).
  Future<void> Function(String sha256, List<int> container)? putBlobHook;

  SyncStateInfo stateResponse = SyncStateInfo(
    headSeq: 10,
    windowStart: 0,
    quotaUsedBytes: 0,
    quotaMaxBytes: 200 << 20,
  );

  SyncSnapshotResponse snapshotResponse = SyncSnapshotResponse(
    changes: const <SyncPullChange>[],
    headSeq: 10,
  );

  SyncPushResponse _defaultPush(List<SyncPushChange> changes) {
    return SyncPushResponse(
      headSeq: 10 + changes.length,
      results: <SyncPushResult>[
        for (final change in changes)
          SyncPushResult(
            entityType: change.entityType,
            entityId: change.entityId,
            accepted: true,
            changeSeq: 11,
          ),
      ],
    );
  }

  @override
  Future<SyncStateInfo> state({required String accessToken}) async {
    stateCalls++;
    return stateResponse;
  }

  @override
  Future<SyncSnapshotResponse> snapshot({
    required String accessToken,
    String? afterType,
    String? afterId,
    int limit = 200,
  }) async {
    snapshotCalls.add(SnapshotCall(afterType, afterId, limit));
    if (snapshotQueue.isNotEmpty) {
      final next = snapshotQueue.removeAt(0);
      if (next is SyncSnapshotResponse) return next;
      if (next is Exception) throw next;
    }
    return snapshotResponse;
  }

  @override
  Future<SyncPushResponse> push({
    required String accessToken,
    required String idempotencyKey,
    required String deviceId,
    required List<SyncPushChange> changes,
  }) async {
    pushCalls.add(PushCall(idempotencyKey, deviceId, changes));
    if (pushHook != null) return pushHook!(changes);
    if (pushQueue.isNotEmpty) {
      final next = pushQueue.removeAt(0);
      if (next is SyncPushResponse) return next;
      if (next is Exception) throw next;
    }
    return _defaultPush(changes);
  }

  @override
  Future<SyncPullResponse> pull({
    required String accessToken,
    required int cursor,
    int limit = 200,
  }) async {
    pullCalls.add(PullCall(cursor, limit));
    if (pullQueue.isNotEmpty) {
      final next = pullQueue.removeAt(0);
      if (next is SyncPullResponse) return next;
      if (next is Exception) throw next;
    }
    return SyncPullResponse(
      changes: const <SyncPullChange>[],
      nextCursor: cursor,
      headSeq: cursor,
    );
  }

  @override
  Future<bool> headBlob({
    required String accessToken,
    required String sha256,
  }) async {
    final hook = headHook;
    if (hook != null) return hook(sha256);
    return blobs.containsKey(sha256);
  }

  @override
  Future<void> putBlob({
    required String accessToken,
    required String sha256,
    required List<int> container,
  }) async {
    final hook = putBlobHook;
    if (hook != null) return hook(sha256, container);
    putBlobCalls.add((sha256: sha256, container: container));
    blobs[sha256] = container;
  }

  @override
  Future<List<int>> getBlob({
    required String accessToken,
    required String sha256,
  }) async {
    final hook = getBlobHook;
    if (hook != null) return hook(sha256);
    final blob = blobs[sha256];
    if (blob == null) {
      throw AccountApiException(
        code: 'BLOB_NOT_FOUND',
        message: 'blob 缺失',
      );
    }
    return blob;
  }

  @override
  Future<void> reportCursor({
    required String accessToken,
    required int cursor,
  }) async {
    reportCursorCalls.add(cursor);
  }
}
