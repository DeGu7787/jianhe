import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_core/jianhe_core.dart';
import 'package:jianhe_storage/jianhe_storage.dart';
import 'package:jianhe_desktop/features/account/account_api.dart';
import 'package:jianhe_desktop/features/cloud_sync/sync_engine.dart';
import 'package:jianhe_desktop/features/cloud_sync/sync_models.dart';

import 'fake_sync_api.dart';

void main() {
  final wireUuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  Future<T> authorized<T>(Future<T> Function(String token) action) =>
      action('token-1');

  SyncEngine buildEngine(
    JianheStorageDatabase storage,
    FakeSyncApi api, {
    Duration? retryDelay,
    Duration? rateLimitDelay,
  }) {
    return SyncEngine(
      storage: storage,
      api: api,
      authorizedRequest: authorized,
      retryDelay: retryDelay ?? Duration.zero,
      rateLimitDelay: rateLimitDelay ?? Duration.zero,
    );
  }

  Future<JianheItem> seedItem(
    JianheStorageDatabase storage, {
    String id = 'item-1',
    ItemType type = ItemType.snippet,
    String title = '条目',
    String content = '正文内容',
    String category = '',
    DateTime? now,
  }) async {
    final item = JianheItem.create(
      type: type,
      title: title,
      content: content,
      id: id,
      category: category,
      now: now ?? DateTime.utc(2026, 9, 10, 8),
    );
    await storage.items.save(item);
    return item;
  }

  List<int> encodeItemEnvelope(JianheItem item) {
    return utf8.encode(
      jsonEncode(<String, Object?>{
        'id': item.id,
        'type': item.type.name,
        'title': item.title,
        'content': item.content,
        'is_favorite': item.isFavorite,
        'rating': item.rating,
        'category': item.category,
        'sort_order': item.sortOrder,
        'created_at': item.createdAt.toUtc().toIso8601String(),
        'updated_at': item.updatedAt.toUtc().toIso8601String(),
      }),
    );
  }

  test('cursor below window triggers snapshot recovery', () async {
    final storage = JianheStorageDatabase.inMemory();
    await seedItem(storage, id: 'local-1');
    storage.sync.writeState('pull_cursor:A', '100');
    final remoteItem = JianheItem.create(
      type: ItemType.snippet,
      title: '远端条目',
      content: '远端内容',
      id: 'remote-1',
      now: DateTime.utc(2026, 9, 11, 9),
    );
    final api = FakeSyncApi()
      ..stateResponse = SyncStateInfo(
        headSeq: 1042,
        windowStart: 930,
        quotaUsedBytes: 0,
        quotaMaxBytes: 200 << 20,
      )
      ..snapshotQueue.addAll(<Object?>[
        SyncSnapshotResponse(
          changes: <SyncPullChange>[
            SyncPullChange(
              changeSeq: 931,
              entityType: SyncEntityType.itemSnippet,
              entityId: 'remote-1',
              updatedAt: remoteItem.updatedAt,
              deleted: false,
              originDeviceId: 'device-remote',
              envelope: encodeItemEnvelope(remoteItem),
            ),
          ],
          nextEntityType: 'item:snippet',
          nextEntityId: 'remote-1',
          headSeq: 1042,
        ),
        SyncSnapshotResponse(changes: const <SyncPullChange>[], headSeq: 1050),
      ]);
    final engine = buildEngine(storage, api);
    var remoteNotifications = 0;
    engine.onRemoteChange = () => remoteNotifications++;

    final result = await engine.synchronize(accountId: 'A');

    expect(api.snapshotCalls, hasLength(2));
    expect(api.snapshotCalls.first.afterType, isNull);
    expect(api.snapshotCalls.last.afterType, 'item:snippet');
    expect(api.pullCalls, isEmpty);
    expect(remoteNotifications, 1);
    expect(result.pulledCount, 1);
    expect(
      storage.sync.readItemUpdatedAt('remote-1'),
      remoteItem.updatedAt.toUtc().toIso8601String(),
    );

    // The re-push carries both the local survivor and the freshly applied
    // remote winner; the incremental cursor resumes at the smallest head.
    expect(api.pushCalls, hasLength(1));
    expect(api.pushCalls.single.changes, hasLength(2));
    expect(storage.sync.pendingCount(), 0);
    expect(storage.sync.readState('pull_cursor:A'), '1042');
    expect(api.reportCursorCalls, [1042]);
    expect(
      storage.sync.readState('last_sync_finished_at:A'),
      isNotNull,
    );
    storage.close();
  });

  test('cursor above head_seq triggers full re-push recovery', () async {
    // The server rewound its tables (plaintext protocol switch wiped sync
    // data): head_seq reset to 0 while the local cursor still sits at 100.
    // The incremental window is empty, so recovery must re-push everything.
    final storage = JianheStorageDatabase.inMemory();
    await seedItem(storage, id: 'local-1');
    storage.sync.writeState('pull_cursor:A', '100');
    final api = FakeSyncApi()
      ..stateResponse = SyncStateInfo(
        headSeq: 0,
        windowStart: 0,
        quotaUsedBytes: 0,
        quotaMaxBytes: 200 << 20,
      )
      ..snapshotQueue.add(
        SyncSnapshotResponse(changes: const <SyncPullChange>[], headSeq: 0),
      );
    final engine = buildEngine(storage, api);

    final result = await engine.synchronize(accountId: 'A');

    expect(api.snapshotCalls, hasLength(1));
    expect(api.pullCalls, isEmpty);
    expect(result.pushedCount, 1);
    expect(api.pushCalls, hasLength(1));
    final record = api.pushCalls.single.changes.single;
    expect(record.entityType, SyncEntityType.itemSnippet);
    // Legacy id maps to a deterministic wire UUID, as always.
    expect(
      storage.sync.readState('legacy_id_map:item:snippet:local-1'),
      record.entityId,
    );
    expect(record.deleted, isFalse);
    expect(storage.sync.pendingCount(), 0);
    expect(storage.sync.readState('pull_cursor:A'), '0');
    expect(api.reportCursorCalls, [0]);
    storage.close();
  });

  test('first sync without a cursor recovers and seeds a legacy library',
      () async {
    // A first sync on this device has no stored cursor and must run the
    // snapshot+re-push recovery: the snapshot seeds the cloud state, and the
    // re-push uploads local entities that have no journal rows (the
    // legacy-v0 migration copies rows with bare SQL) — the pending-only push
    // path would never ship them. Recovery runs for pull-only startup runs
    // too, because it is the one-shot seed.
    final storage = JianheStorageDatabase.inMemory();
    final legacy = await seedItem(storage, id: 'legacy-1');
    // Simulate the migrated library: the row exists but was never journaled.
    storage.sync.deletePendingChanges(
      SyncEntityType.itemSnippet,
      legacy.id,
      upToSeq: 999,
    );
    final remoteItem = JianheItem.create(
      type: ItemType.snippet,
      title: '远端条目',
      content: '远端内容',
      id: 'remote-1',
      now: DateTime.utc(2026, 9, 11, 9),
    );
    final api = FakeSyncApi()
      ..stateResponse = SyncStateInfo(
        headSeq: 0,
        windowStart: 0,
        quotaUsedBytes: 0,
        quotaMaxBytes: 200 << 20,
      )
      ..snapshotQueue.add(
        SyncSnapshotResponse(
          changes: <SyncPullChange>[
            SyncPullChange(
              changeSeq: 1,
              entityType: SyncEntityType.itemSnippet,
              entityId: 'remote-1',
              updatedAt: remoteItem.updatedAt,
              deleted: false,
              originDeviceId: 'device-remote',
              envelope: encodeItemEnvelope(remoteItem),
            ),
          ],
          headSeq: 0,
        ),
      );
    final engine = buildEngine(storage, api);

    final result = await engine.synchronize(
      accountId: 'A',
      mode: SyncMode.pullOnly,
    );

    expect(api.snapshotCalls, hasLength(1));
    expect(api.pullCalls, isEmpty);
    expect(await storage.items.getById('remote-1'), isNotNull);
    expect(result.pulledCount, 1);
    // The re-push ships every surviving local entity: the unjournaled
    // legacy row (absent from any pending queue) alongside the freshly
    // applied remote winner.
    expect(api.pushCalls, hasLength(1));
    expect(api.pushCalls.single.changes, hasLength(2));
    final rePushedIds = api.pushCalls.single.changes
        .map((change) => change.entityId)
        .toSet();
    expect(
      rePushedIds,
      contains(storage.sync.readState('legacy_id_map:item:snippet:legacy-1')),
    );
    expect(result.pushedCount, 2);
    expect(storage.sync.pendingCount(), 0);
    expect(storage.sync.readState('pull_cursor:A'), '0');
    storage.close();
  });

  test('pullOnly mode skips the pending push once a cursor exists', () async {
    final storage = JianheStorageDatabase.inMemory();
    await seedItem(storage);
    storage.sync.writeState('pull_cursor:A', '10');
    final api = FakeSyncApi();
    final engine = buildEngine(storage, api);

    final result = await engine.synchronize(
      accountId: 'A',
      mode: SyncMode.pullOnly,
    );

    expect(api.pushCalls, isEmpty);
    expect(api.pullCalls, hasLength(1));
    expect(result.pushedCount, 0);
    expect(storage.sync.pendingCount(), 1);
    storage.close();
  });

  test('recovery keeps undelivered entities pending and re-pushes the edit',
      () async {
    final storage = JianheStorageDatabase.inMemory();
    final item = await seedItem(storage, content: 'v1');
    storage.sync.writeState('pull_cursor:A', '100');
    final api = FakeSyncApi()
      ..stateResponse = SyncStateInfo(
        headSeq: 1042,
        windowStart: 930,
        quotaUsedBytes: 0,
        quotaMaxBytes: 200 << 20,
      )
      // An empty snapshot page: recovery only re-pushes local state.
      ..snapshotQueue.add(
        SyncSnapshotResponse(changes: const <SyncPullChange>[], headSeq: 1042),
      );
    // Mid-recovery edit: the ack gate sees the moved updated_at and keeps
    // the entity pending; the closing push round ships the edited state.
    api.pushHook = (changes) async {
      if (api.pushCalls.length == 1) {
        await storage.items.save(
          JianheItem(
            id: item.id,
            type: item.type,
            title: item.title,
            content: 'v2',
            isFavorite: item.isFavorite,
            rating: item.rating,
            category: item.category,
            sortOrder: item.sortOrder,
            useCount: item.useCount,
            lastUsedAt: item.lastUsedAt,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt.add(const Duration(minutes: 1)),
            contentHash: JianheItem.calculateContentHash('v2'),
          ),
        );
      }
      return SyncPushResponse(
        headSeq: 1100,
        results: <SyncPushResult>[
          for (final change in changes)
            SyncPushResult(
              entityType: change.entityType,
              entityId: change.entityId,
              accepted: true,
              changeSeq: 1101,
            ),
        ],
      );
    };
    final engine = buildEngine(storage, api);

    final result = await engine.synchronize(accountId: 'A');

    expect(api.pushCalls, hasLength(2));
    final firstEnvelope =
        jsonDecode(utf8.decode(api.pushCalls.first.changes.single.envelope!))
            as Map<String, Object?>;
    final secondEnvelope =
        jsonDecode(utf8.decode(api.pushCalls.last.changes.single.envelope!))
            as Map<String, Object?>;
    expect(firstEnvelope['content'], 'v1');
    expect(secondEnvelope['content'], 'v2');
    expect(result.pushedCount, 1);
    expect(storage.sync.pendingCount(), 0);
    expect(storage.sync.readState('pull_cursor:A'), '1042');
    storage.close();
  });

  test('rate-limited batches back off and retry the same batch', () async {
    final storage = JianheStorageDatabase.inMemory();
    await seedItem(storage);
    final api = FakeSyncApi()
      ..pushQueue.add(
        const AccountApiException(
          code: 'RATE_LIMITED',
          message: '同步上传过于频繁，请稍后重试。',
          retryable: true,
        ),
      );
    final engine = buildEngine(storage, api);

    final result = await engine.synchronize(accountId: 'A');

    expect(api.pushCalls, hasLength(2));
    expect(api.pushCalls.first.idempotencyKey, api.pushCalls.last.idempotencyKey);
    expect(result.pushedCount, 1);
    expect(storage.sync.pendingCount(), 0);
    storage.close();
  });

  test('cancellation stops before any API call', () async {
    final storage = JianheStorageDatabase.inMemory();
    final api = FakeSyncApi();
    final engine = buildEngine(storage, api);
    await expectLater(
      engine.synchronize(accountId: 'A', cancelled: () => true),
      throwsA(isA<SyncCancelledException>()),
    );
    expect(api.pushCalls, isEmpty);
    storage.close();
  });

  test('push sends device id and whitelist envelope, ack clears pending',
      () async {
    final storage = JianheStorageDatabase.inMemory();
    final item = await seedItem(
      storage,
      category: '工作',
    );
    await storage.items.createCategory(ItemType.snippet, '工作');
    final api = FakeSyncApi();
    final engine = buildEngine(storage, api);

    final result = await engine.synchronize(accountId: 'A');

    expect(result.pushedCount, 2);
    expect(api.pushCalls, hasLength(1));
    final call = api.pushCalls.single;
    expect(call.deviceId, storage.sync.readState('device_id'));
    expect(call.changes, hasLength(2));

    final itemRecord = call.changes
        .singleWhere((change) => change.entityType == SyncEntityType.itemSnippet);
    expect(itemRecord.deleted, isFalse);
    expect(itemRecord.updatedAt, item.updatedAt);
    final envelope =
        jsonDecode(utf8.decode(itemRecord.envelope!)) as Map<String, Object?>;
    expect(envelope['id'], item.id);
    expect(envelope['category'], '工作');
    expect(envelope.containsKey('use_count'), isFalse);
    expect(envelope.containsKey('last_used_at'), isFalse);
    expect(envelope.containsKey('content_hash'), isFalse);

    final categoryRecord = call.changes
        .singleWhere(
          (change) => change.entityType == SyncEntityType.categorySnippet,
        );
    final categoryEnvelope =
        jsonDecode(utf8.decode(categoryRecord.envelope!))
            as Map<String, Object?>;
    expect(categoryEnvelope['name'], '工作');
    expect(categoryEnvelope['sort_order'], 0);
    expect(categoryEnvelope['created_at'], isNotEmpty);

    expect(storage.sync.pendingCount(), 0);
    expect(
      storage.sync.readState('last_sync_finished_at:A'),
      isNotNull,
    );
    storage.close();
  });

  test('put-then-delete coalesces into a single tombstone', () async {
    final storage = JianheStorageDatabase.inMemory();
    await seedItem(storage);
    await storage.items.delete('item-1');
    final api = FakeSyncApi();
    final engine = buildEngine(storage, api);

    final result = await engine.synchronize(accountId: 'A');

    expect(result.pushedCount, 1);
    final record = api.pushCalls.single.changes.single;
    expect(record.entityType, SyncEntityType.itemSnippet);
    expect(record.deleted, isTrue);
    expect(storage.sync.pendingCount(), 0);
    storage.close();
  });

  test('legacy non-UUID ids map to stable wire UUIDs on push', () async {
    final storage = JianheStorageDatabase.inMemory();
    await seedItem(storage, id: 'id-1');
    final api = FakeSyncApi();
    final engine = buildEngine(storage, api);

    await engine.synchronize(accountId: 'A');

    final record = api.pushCalls.single.changes
        .singleWhere((change) => change.entityType == SyncEntityType.itemSnippet);
    final wireId = record.entityId;
    expect(wireUuidPattern.hasMatch(wireId), isTrue);
    // Forward mapping recorded in sync_state.
    expect(storage.sync.readState('legacy_id_map:item:snippet:id-1'), wireId);

    // Deterministic: an independent storage computes the same wire id.
    final storage2 = JianheStorageDatabase.inMemory();
    await seedItem(storage2, id: 'id-1');
    final engine2 = buildEngine(storage2, FakeSyncApi());
    await engine2.synchronize(accountId: 'B');
    expect(storage2.sync.readState('legacy_id_map:item:snippet:id-1'), wireId);
    storage.close();
    storage2.close();
  });

  test('legacy id delete pushes a UUID tombstone and acks', () async {
    final storage = JianheStorageDatabase.inMemory();
    await seedItem(storage, id: 'id-legacy');
    await storage.items.delete('id-legacy');
    final api = FakeSyncApi();
    final engine = buildEngine(storage, api);

    final result = await engine.synchronize(accountId: 'A');

    expect(result.pushedCount, 1);
    final record = api.pushCalls.single.changes.single;
    expect(record.entityType, SyncEntityType.itemSnippet);
    expect(record.deleted, isTrue);
    expect(wireUuidPattern.hasMatch(record.entityId), isTrue);
    expect(
      record.entityId,
      isNot('id-legacy'),
    );
    expect(storage.sync.pendingCount(), 0);
    storage.close();
  });

  test('retryable push failure replays the same idempotency key and body',
      () async {
    final storage = JianheStorageDatabase.inMemory();
    await seedItem(storage);
    final api = FakeSyncApi()
      ..pushQueue.addAll(<Object?>[
        const AccountApiException(
          code: 'SERVER_ERROR',
          message: 'boom',
          retryable: true,
        ),
      ]);
    final engine = buildEngine(storage, api);

    final result = await engine.synchronize(accountId: 'A');

    expect(api.pushCalls, hasLength(2));
    expect(api.pushCalls[0].idempotencyKey, api.pushCalls[1].idempotencyKey);
    expect(
      api.pushCalls[0].changes.single.toJson(),
      api.pushCalls[1].changes.single.toJson(),
    );
    expect(result.pushedCount, 1);
    expect(storage.sync.pendingCount(), 0);
    storage.close();
  });

  test('an older server refusing a batch for space keeps it queued',
      () async {
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('pull_cursor:A', '10');
    await seedItem(storage);
    final api = FakeSyncApi()
      ..stateResponse = SyncStateInfo(
        headSeq: 10,
        windowStart: 0,
        quotaUsedBytes: 200 << 20,
        quotaMaxBytes: 200 << 20,
      )
      ..pushQueue.add(
        const AccountApiException(
          code: 'SYNC_QUOTA_EXCEEDED',
          message: '同步空间已达到上限。',
          retryable: false,
        ),
      );
    final engine = buildEngine(storage, api);

    final result = await engine.synchronize(accountId: 'A');

    // Previously the batch was shelved and its pending rows dropped, so the
    // edit never synced even after space was freed.
    expect(result.pushedCount, 0);
    expect(result.quotaBlockedCount, 1);
    expect(result.quotaNotice, contains('云同步空间已满'));
    expect(storage.sync.pendingCount(), 1);
    expect(await storage.items.getById('item-1'), isNotNull);

    api.stateResponse = SyncStateInfo(
      headSeq: 10,
      windowStart: 0,
      quotaUsedBytes: 120 << 20,
      quotaMaxBytes: 200 << 20,
    );
    final retried = await engine.synchronize(accountId: 'A');
    expect(retried.pushedCount, 1);
    expect(retried.quotaBlockedCount, 0);
    expect(storage.sync.pendingCount(), 0);
    storage.close();
  });

  test('a record the server rejects as invalid is isolated and reported',
      () async {
    final storage = JianheStorageDatabase.inMemory();
    const badId = 'bad00000-0000-4000-8000-000000000000';
    await seedItem(storage, id: 'item-1', title: '好条目');
    await seedItem(storage, id: badId, title: '坏条目');
    await seedItem(storage, id: 'item-3', title: '另一条');
    final api = FakeSyncApi();
    api.pushHook = (changes) async {
      if (changes.any((change) => change.entityId.startsWith('bad00000'))) {
        throw const AccountApiException(
          code: 'INVALID_REQUEST',
          message: '同步请求无效。',
        );
      }
      return SyncPushResponse(
        headSeq: 99,
        results: <SyncPushResult>[
          for (final change in changes)
            SyncPushResult(
              entityType: change.entityType,
              entityId: change.entityId,
              accepted: true,
              changeSeq: 99,
            ),
        ],
      );
    };
    final engine = buildEngine(storage, api);

    final result = await engine.synchronize(accountId: 'A');

    expect(result.pushedCount, 2);
    expect(result.warnings, hasLength(1));
    expect(result.warnings.single, contains('坏条目'));
    expect(result.warnings.single, contains('已跳过'));
    expect(storage.sync.pendingCount(), 0);
    expect(await storage.items.getById(badId), isNotNull);
    storage.close();
  });

  test('a systematic INVALID_REQUEST rethrows with the clock hint', () async {
    final storage = JianheStorageDatabase.inMemory();
    await seedItem(storage, category: '工作');
    await storage.items.createCategory(ItemType.snippet, '工作');
    final api = FakeSyncApi();
    api.pushHook = (changes) async {
      throw const AccountApiException(
        code: 'INVALID_REQUEST',
        message: '同步请求无效。',
      );
    };
    final engine = buildEngine(storage, api);

    await expectLater(
      engine.synchronize(accountId: 'A'),
      throwsA(
        isA<AccountApiException>().having(
          (error) => error.message,
          'message',
          contains('时钟'),
        ),
      ),
    );
    expect(storage.sync.pendingCount(), greaterThan(0));
    storage.close();
  });

  test('a future-stamped record is re-stamped and synced on retry', () async {
    final storage = JianheStorageDatabase.inMemory();
    // Server clock ahead of the real clock by a day, so a re-stamp to "now"
    // still lands before the server's horizon. Fixed dates here would rot:
    // once the real clock passes the seeded stamp the record stops looking
    // future-stamped and the engine correctly skips the re-stamp path.
    final serverNow = DateTime.now().toUtc().add(const Duration(days: 1));
    // Created while the local clock ran fast: stamped days ahead of the
    // server's clock, which rejects anything newer than now + 5 minutes.
    await seedItem(storage, now: serverNow.add(const Duration(days: 4)));
    final api = FakeSyncApi();
    api.pushHook = (changes) async {
      final tooNew = changes.any(
        (change) => change.updatedAt.isAfter(serverNow),
      );
      if (tooNew) {
        throw const AccountApiException(
          code: 'INVALID_REQUEST',
          message: '同步请求无效。',
        );
      }
      return SyncPushResponse(
        headSeq: 99,
        results: <SyncPushResult>[
          for (final change in changes)
            SyncPushResult(
              entityType: change.entityType,
              entityId: change.entityId,
              accepted: true,
              changeSeq: 99,
            ),
        ],
      );
    };
    final engine = buildEngine(storage, api);

    final result = await engine.synchronize(accountId: 'A');

    expect(result.pushedCount, 1);
    expect(result.warnings, hasLength(1));
    expect(result.warnings.single, contains('已校正'));
    expect(storage.sync.pendingCount(), 0);
    expect(
      api.pushCalls.last.changes.single.updatedAt,
      predicate<DateTime>((value) => value.isBefore(serverNow), 'before serverNow'),
    );
    storage.close();
  });

  test('VIP_REQUIRED propagates and keeps the pending rows', () async {
    final storage = JianheStorageDatabase.inMemory();
    await seedItem(storage);
    final api = FakeSyncApi()
      ..pushQueue.add(
        const AccountApiException(
          code: 'VIP_REQUIRED',
          message: '需要会员',
          retryable: false,
        ),
      );
    final engine = buildEngine(storage, api);

    await expectLater(
      engine.synchronize(accountId: 'A'),
      throwsA(
        isA<AccountApiException>().having(
          (error) => error.code,
          'code',
          'VIP_REQUIRED',
        ),
      ),
    );
    expect(storage.sync.pendingCount(), 1);
    storage.close();
  });

  test('push failure no longer suppresses the pull phase', () async {
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('device_id', 'device-A');
    storage.sync.writeState('pull_cursor:A', '0');
    await seedItem(storage, id: 'local-1');
    final remote = JianheItem.create(
      type: ItemType.snippet,
      title: '远端条目',
      content: '远端内容',
      id: 'remote-1',
      now: DateTime.utc(2026, 9, 11, 9),
    );
    final api = FakeSyncApi()
      ..pushQueue.add(
        // A non-retryable, non-shelvable code that the diagnosis layer
        // rethrows unchanged (unlike INVALID_REQUEST, which is isolated).
        const AccountApiException(
          code: 'FORBIDDEN',
          message: '没有推送权限。',
        ),
      )
      ..pullQueue.add(
        SyncPullResponse(
          changes: <SyncPullChange>[
            SyncPullChange(
              changeSeq: 101,
              entityType: SyncEntityType.itemSnippet,
              entityId: 'remote-1',
              updatedAt: remote.updatedAt,
              deleted: false,
              originDeviceId: 'device-B',
              envelope: encodeItemEnvelope(remote),
            ),
          ],
          nextCursor: 101,
          headSeq: 101,
        ),
      );
    final engine = buildEngine(storage, api);

    await expectLater(
      engine.synchronize(accountId: 'A'),
      throwsA(
        isA<AccountApiException>().having(
          (error) => error.code,
          'code',
          'FORBIDDEN',
        ),
      ),
    );

    // The pull ran despite the failed push: the remote winner is applied
    // and the cursor advanced, while the unpushed pending rows survive and
    // the run is not marked as a finished sync.
    expect(api.pullCalls, hasLength(1));
    expect(await storage.items.getById('remote-1'), isNotNull);
    expect(storage.sync.readState('pull_cursor:A'), '101');
    expect(storage.sync.pendingCount(), 1);
    expect(storage.sync.readState('last_sync_finished_at:A'), isNull);
    storage.close();
  });

  test('skill push uploads the blob once and caches across retries',
      () async {
    final storage = JianheStorageDatabase.inMemory();
    final skill = await seedItem(
      storage,
      id: 'skill-1',
      type: ItemType.skill,
      title: 'demo-skill',
      content: '# SKILL.md',
    );
    await storage.skills.replaceSkill(
      skill,
      SkillPackage(
        skillId: skill.id,
        sourceFormat: SkillSourceFormat.markdown,
        importedAt: DateTime.utc(2026, 9, 10, 9),
        files: <SkillFile>[
          SkillFile(
            relativePath: 'assets/a.txt',
            content: Uint8List.fromList(utf8.encode('hello')),
          ),
        ],
      ),
    );
    final api = FakeSyncApi()
      ..pushQueue.add(
        const AccountApiException(
          code: 'SERVER_ERROR',
          message: 'boom',
          retryable: true,
        ),
      );
    final engine = buildEngine(storage, api);

    await engine.synchronize(accountId: 'A');

    expect(api.putBlobCalls, hasLength(1));
    final blobCall = api.putBlobCalls.single;
    final payload = jsonDecode(utf8.decode(blobCall.container))
        as Map<String, Object?>;
    expect(payload['entrypoint'], 'SKILL.md');
    expect(payload['source_format'], 'markdown');
    expect(payload['manifest'], '# SKILL.md');
    final payloadFiles = (payload['files']! as List<Object?>).single!
        as Map<String, Object?>;
    expect(payloadFiles['relative_path'], 'assets/a.txt');
    expect(
      payloadFiles['content_base64'],
      base64Encode(utf8.encode('hello')),
    );

    final packageRecord = api.pushCalls.last.changes
        .singleWhere((change) => change.entityType == SyncEntityType.skillPackage);
    expect(packageRecord.packageHash, isNotNull);
    expect(packageRecord.blobSha256, blobCall.sha256);
    expect(packageRecord.byteLength, blobCall.container.length);
    expect(packageRecord.fileCount, 2);
    expect(storage.sync.pendingCount(), 0);
    storage.close();
  });

  test('skill blob already on the server skips the upload', () async {
    final storage = JianheStorageDatabase.inMemory();
    final skill = await seedItem(
      storage,
      id: 'skill-1',
      type: ItemType.skill,
      title: 'demo-skill',
      content: '# SKILL.md',
    );
    await storage.skills.replaceSkill(
      skill,
      SkillPackage(
        skillId: skill.id,
        sourceFormat: SkillSourceFormat.markdown,
        importedAt: DateTime.utc(2026, 9, 10, 9),
      ),
    );
    final api = FakeSyncApi()..headHook = (_) => true;
    final engine = buildEngine(storage, api);

    await engine.synchronize(accountId: 'A');

    expect(api.putBlobCalls, isEmpty);
    storage.close();
  });

  test('LOST_LWW results clear the pending rows without local rollback',
      () async {
    final storage = JianheStorageDatabase.inMemory();
    await seedItem(storage);
    final api = FakeSyncApi()
      ..pushQueue.add(
        SyncPushResponse(
          headSeq: 50,
          results: <SyncPushResult>[
            SyncPushResult(
              entityType: SyncEntityType.itemSnippet,
              entityId: 'item-1',
              accepted: false,
              reason: 'LOST_LWW',
            ),
          ],
        ),
      );
    final engine = buildEngine(storage, api);

    final result = await engine.synchronize(accountId: 'A');

    expect(result.pushedCount, 1);
    expect(storage.sync.pendingCount(), 0);
    expect(await storage.items.getById('item-1'), isNotNull);
    storage.close();
  });

  group('recovery re-push of categories', () {
    // A category this device created long ago and already synced: no
    // pending journal rows, an old created_at.
    Future<JianheStorageDatabase> deviceWithSyncedCategory(String name) async {
      final storage = JianheStorageDatabase.inMemory();
      storage.sync.writeState('device_id', 'device-A');
      await storage.items.createCategory(ItemType.snippet, name);
      storage.database.execute(
        'UPDATE item_categories SET created_at = ? WHERE name = ?;',
        ['2026-09-01T00:00:00.000Z', name],
      );
      storage.sync.deletePendingChanges(
        SyncEntityType.categorySnippet,
        name,
        upToSeq: 1 << 30,
      );
      return storage;
    }

    // The server holds a newer state (a tombstone) for [losing] categories.
    FakeSyncApi apiLosingCategories(Set<String> losing) {
      final api = FakeSyncApi();
      api.pushHook = (changes) async => SyncPushResponse(
        headSeq: 20,
        results: <SyncPushResult>[
          for (final change in changes)
            SyncPushResult(
              entityType: change.entityType,
              entityId: change.entityId,
              accepted: !losing.contains(change.entityId),
              reason: losing.contains(change.entityId) ? 'LOST_LWW' : null,
              changeSeq: 11,
            ),
        ],
      );
      return api;
    }

    test('a stale category deleted elsewhere is stamped by creation time and '
        'retired locally', () async {
      final storage = await deviceWithSyncedCategory('已删除');
      final api = apiLosingCategories(<String>{'已删除'});

      // No cursor for this account: full snapshot recovery + re-push.
      await buildEngine(storage, api).synchronize(accountId: 'A');

      final pushed = api.pushCalls
          .expand((call) => call.changes)
          .singleWhere((change) => change.entityId == '已删除');
      // Stamped with its real creation time, not "now", so the newer
      // tombstone on the server wins instead of being overwritten.
      expect(pushed.updatedAt, DateTime.utc(2026, 9, 1));
      expect(await storage.items.listCategories(ItemType.snippet), isEmpty);
      storage.close();
    });

    test('a category the snapshot reports live survives a lost re-push',
        () async {
      final storage = await deviceWithSyncedCategory('别处改过');
      final api = apiLosingCategories(<String>{'别处改过'})
        ..snapshotQueue.add(
          SyncSnapshotResponse(
            changes: <SyncPullChange>[
              SyncPullChange(
                changeSeq: 15,
                entityType: SyncEntityType.categorySnippet,
                entityId: '别处改过',
                updatedAt: DateTime.utc(2026, 9, 20),
                deleted: false,
                originDeviceId: 'device-B',
                envelope: utf8.encode(
                  jsonEncode(<String, Object?>{
                    'name': '别处改过',
                    'sort_order': 3,
                    'created_at': '2026-09-01T00:00:00.000Z',
                  }),
                ),
              ),
            ],
            headSeq: 20,
          ),
        );

      await buildEngine(storage, api).synchronize(accountId: 'A');

      // The newer server state is a live put, not a tombstone.
      expect(
        await storage.items.listCategories(ItemType.snippet),
        <String>['别处改过'],
      );
      storage.close();
    });

    test('a local-only category is uploaded and kept', () async {
      final storage = await deviceWithSyncedCategory('仅本机');
      final api = apiLosingCategories(const <String>{});

      await buildEngine(storage, api).synchronize(accountId: 'A');

      expect(
        api.pushCalls
            .expand((call) => call.changes)
            .where((change) => change.entityId == '仅本机'),
        hasLength(1),
      );
      expect(
        await storage.items.listCategories(ItemType.snippet),
        <String>['仅本机'],
      );
      storage.close();
    });
  });

  test('ack verification keeps pending rows when local state moved on',
      () async {
    final storage = JianheStorageDatabase.inMemory();
    final original = await seedItem(storage);
    final api = FakeSyncApi();
    var hooked = false;
    api.pushHook = (changes) async {
      if (hooked) {
        return SyncPushResponse(
          headSeq: 60,
          results: <SyncPushResult>[
            for (final change in changes)
              SyncPushResult(
                entityType: change.entityType,
                entityId: change.entityId,
                accepted: true,
                changeSeq: 61,
              ),
          ],
        );
      }
      hooked = true;
      // The user edits the item while the push is in flight; the accepted
      // result refers to the stale snapshot, so the ack gate must keep the
      // pending rows for a second round.
      await storage.items.save(original.copyWith(title: '条目二'));
      return SyncPushResponse(
        headSeq: 51,
        results: <SyncPushResult>[
          SyncPushResult(
            entityType: SyncEntityType.itemSnippet,
            entityId: 'item-1',
            accepted: true,
            changeSeq: 52,
          ),
        ],
      );
    };
    final engine = buildEngine(storage, api);

    await engine.synchronize(accountId: 'A');

    expect(api.pushCalls, hasLength(2));
    expect(storage.sync.pendingCount(), 0);
    final finalItem = await storage.items.getById('item-1');
    expect(finalItem!.title, '条目二');
    storage.close();
  });

  test('pull applies newer remote item and preserves local use stats',
      () async {
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('device_id', 'device-A');
    storage.sync.writeState('pull_cursor:A', '0');
    final local = JianheItem.create(
      type: ItemType.snippet,
      title: '旧标题',
      content: '旧内容',
      id: 'item-1',
      now: DateTime.utc(2026, 9, 9, 8),
    );
    await storage.items.save(local);
    await storage.items.markUsed('item-1', now: DateTime.utc(2026, 9, 9, 9));

    final remote = JianheItem.create(
      type: ItemType.snippet,
      title: '新标题',
      content: '新内容',
      id: 'item-1',
      now: DateTime.utc(2026, 9, 10, 8),
    );
    final api = FakeSyncApi()
      ..pullQueue.add(
        SyncPullResponse(
          changes: <SyncPullChange>[
            SyncPullChange(
              changeSeq: 101,
              entityType: SyncEntityType.itemSnippet,
              entityId: 'item-1',
              updatedAt: remote.updatedAt,
              deleted: false,
              originDeviceId: 'device-B',
              envelope: encodeItemEnvelope(remote),
            ),
          ],
          nextCursor: 101,
          headSeq: 101,
        ),
      );
    final engine = buildEngine(storage, api);

    final result = await engine.synchronize(accountId: 'A');

    expect(result.pulledCount, 1);
    final merged = await storage.items.getById('item-1');
    expect(merged!.title, '新标题');
    expect(merged.content, '新内容');
    expect(merged.updatedAt, remote.updatedAt);
    expect(merged.useCount, 1);
    expect(merged.lastUsedAt, DateTime.utc(2026, 9, 9, 9));
    expect(storage.sync.readState('pull_cursor:A'), '101');
    expect(api.reportCursorCalls, <int>[101]);
    storage.close();
  });

  test('a pull page larger than the yield budget applies every record',
      () async {
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('device_id', 'device-A');
    storage.sync.writeState('pull_cursor:A', '0');
    final remoteItems = <JianheItem>[
      for (var i = 0; i < 150; i++)
        JianheItem.create(
          type: ItemType.snippet,
          title: '远端 $i',
          content: '内容 $i',
          id: '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
          now: DateTime.utc(2026, 9, 11, 9),
        ),
    ];
    final api = FakeSyncApi()
      ..pullQueue.add(
        SyncPullResponse(
          changes: <SyncPullChange>[
            for (var i = 0; i < remoteItems.length; i++)
              SyncPullChange(
                changeSeq: 500 + i,
                entityType: SyncEntityType.itemSnippet,
                entityId: remoteItems[i].id,
                updatedAt: remoteItems[i].updatedAt,
                deleted: false,
                originDeviceId: 'device-B',
                envelope: encodeItemEnvelope(remoteItems[i]),
              ),
          ],
          nextCursor: 649,
          headSeq: 649,
        ),
      );

    // The apply transaction hands the event loop a turn after 100 records;
    // the whole page must still land atomically with its cursor.
    await buildEngine(storage, api).synchronize(accountId: 'A');

    expect(await storage.items.listAll(), hasLength(150));
    expect(storage.sync.readState('pull_cursor:A'), '649');
    expect(storage.sync.pendingCount(), 0);
    storage.close();
  });

  test('older remote item states are skipped by the LWW gate', () async {
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('device_id', 'device-A');
    storage.sync.writeState('pull_cursor:A', '0');
    final local = await seedItem(
      storage,
      title: '本地新标题',
      content: '本地新内容',
      now: DateTime.utc(2026, 9, 10, 10),
    );
    final stale = JianheItem.create(
      type: ItemType.snippet,
      title: '过期标题',
      content: '过期内容',
      id: local.id,
      now: DateTime.utc(2026, 9, 10, 8),
    );
    final api = FakeSyncApi()
      ..pullQueue.add(
        SyncPullResponse(
          changes: <SyncPullChange>[
            SyncPullChange(
              changeSeq: 101,
              entityType: SyncEntityType.itemSnippet,
              entityId: local.id,
              updatedAt: stale.updatedAt,
              deleted: false,
              originDeviceId: 'device-B',
              envelope: encodeItemEnvelope(stale),
            ),
          ],
          nextCursor: 101,
          headSeq: 101,
        ),
      );
    final engine = buildEngine(storage, api);

    await engine.synchronize(accountId: 'A');

    final kept = await storage.items.getById(local.id);
    expect(kept!.title, '本地新标题');
    expect(storage.sync.readState('pull_cursor:A'), '101');
    storage.close();
  });

  test('newer remote tombstones delete, older ones are skipped', () async {
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('device_id', 'device-A');
    storage.sync.writeState('pull_cursor:A', '0');
    final loser = await seedItem(
      storage,
      id: 'item-old',
      now: DateTime.utc(2026, 9, 10, 12),
    );
    await seedItem(storage, id: 'item-gone', now: DateTime.utc(2026, 9, 10, 8));

    final api = FakeSyncApi()
      ..pullQueue.add(
        SyncPullResponse(
          changes: <SyncPullChange>[
            SyncPullChange(
              changeSeq: 101,
              entityType: SyncEntityType.itemSnippet,
              entityId: 'item-gone',
              updatedAt: DateTime.utc(2026, 9, 10, 10),
              deleted: true,
              originDeviceId: 'device-B',
            ),
            SyncPullChange(
              changeSeq: 102,
              entityType: SyncEntityType.itemSnippet,
              entityId: loser.id,
              updatedAt: DateTime.utc(2026, 9, 10, 9),
              deleted: true,
              originDeviceId: 'device-B',
            ),
          ],
          nextCursor: 102,
          headSeq: 102,
        ),
      );
    final engine = buildEngine(storage, api);

    await engine.synchronize(accountId: 'A');

    expect(await storage.items.getById('item-gone'), isNull);
    expect(await storage.items.getById(loser.id), isNotNull);
    expect(storage.sync.readState('pull_cursor:A'), '102');
    storage.close();
  });

  test('a type change pushes the old-type tombstone and both rows ack',
      () async {
    const id = '0b6f6c1e-1f1a-4a3a-9c1b-2a1f3e4d5c6b';
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('device_id', 'device-A');
    storage.sync.writeState('pull_cursor:A', '0');
    final prompt = await seedItem(storage, id: id, type: ItemType.prompt);
    final api = FakeSyncApi();
    final engine = buildEngine(storage, api);
    await engine.synchronize(accountId: 'A');
    expect(storage.sync.pendingCount(), 0);

    await storage.items.save(
      prompt.copyWith(
        type: ItemType.snippet,
        updatedAt: DateTime.utc(2026, 9, 11, 8),
      ),
    );
    final result = await engine.synchronize(accountId: 'A');

    final changes = api.pushCalls.last.changes;
    expect(
      changes.map((change) => (change.entityType, change.deleted)).toSet(),
      <(SyncEntityType, bool)>{
        (SyncEntityType.itemPrompt, true),
        (SyncEntityType.itemSnippet, false),
      },
    );
    expect(changes.every((change) => change.entityId == id), isTrue);
    // The row survives under its new type, yet the old-type tombstone must
    // still verify; otherwise it would be re-pushed on every run.
    expect(result.pushedCount, 2);
    expect(storage.sync.pendingCount(), 0);
    expect((await storage.items.getById(id))?.type, ItemType.snippet);
    storage.close();
  });

  test('a tombstone for an obsolete item type keeps the retyped row',
      () async {
    const id = '5d2c7a10-3b4e-4f6a-8c9d-0e1f2a3b4c5d';
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('device_id', 'device-A');
    storage.sync.writeState('pull_cursor:A', '0');
    await seedItem(
      storage,
      id: id,
      type: ItemType.snippet,
      now: DateTime.utc(2026, 9, 10, 8),
    );
    final api = FakeSyncApi()
      ..pullQueue.add(
        SyncPullResponse(
          changes: <SyncPullChange>[
            // Newer than the local row, but it retires item:prompt/<id>,
            // which this row no longer is.
            SyncPullChange(
              changeSeq: 201,
              entityType: SyncEntityType.itemPrompt,
              entityId: id,
              updatedAt: DateTime.utc(2026, 9, 10, 9),
              deleted: true,
              originDeviceId: 'device-B',
            ),
          ],
          nextCursor: 201,
          headSeq: 201,
        ),
      );
    final engine = buildEngine(storage, api);

    await engine.synchronize(accountId: 'A');

    expect((await storage.items.getById(id))?.type, ItemType.snippet);
    expect(storage.sync.readState('pull_cursor:A'), '201');
    storage.close();
  });

  test('own-device echoes are skipped but still advance the cursor',
      () async {
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('device_id', 'device-A');
    storage.sync.writeState('pull_cursor:A', '0');
    final echoes = <SyncPullChange>[
      for (var i = 0; i < 200; i++)
        SyncPullChange(
          changeSeq: 1000 + i,
          entityType: SyncEntityType.itemSnippet,
          entityId: 'echo-$i',
          updatedAt: DateTime.utc(2026, 9, 10, 8),
          deleted: false,
          originDeviceId: 'device-A',
        ),
    ];
    final api = FakeSyncApi()
      ..pullQueue.addAll(<Object?>[
        SyncPullResponse(
          changes: echoes,
          nextCursor: 1200,
          headSeq: 1201,
        ),
        SyncPullResponse(
          changes: <SyncPullChange>[
            SyncPullChange(
              changeSeq: 1201,
              entityType: SyncEntityType.categorySnippet,
              entityId: '分类',
              updatedAt: DateTime.utc(2026, 9, 10, 8),
              deleted: false,
              originDeviceId: 'device-B',
              envelope: utf8.encode(
                jsonEncode(<String, Object?>{
                  'name': '分类',
                  'sort_order': 3,
                  'created_at': '2026-09-10T08:00:00.000Z',
                }),
              ),
            ),
          ],
          nextCursor: 1201,
          headSeq: 1201,
        ),
      ]);
    final engine = buildEngine(storage, api);

    await engine.synchronize(accountId: 'A');

    expect(api.pullCalls, hasLength(2));
    expect(api.pullCalls[0].cursor, 0);
    expect(api.pullCalls[0].limit, 200);
    expect(api.pullCalls[1].cursor, 1200);
    expect(api.reportCursorCalls, <int>[1200, 1201]);
    expect(storage.sync.readState('pull_cursor:A'), '1201');
    expect(
      await storage.items.listCategories(ItemType.snippet),
      contains('分类'),
    );
    storage.close();
  });

  test('remote category delete clears referencing items locally', () async {
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('device_id', 'device-A');
    storage.sync.writeState('pull_cursor:A', '0');
    await seedItem(storage, category: '工作', now: DateTime.utc(2026, 9, 10, 8));
    await storage.items.createCategory(ItemType.snippet, '工作');
    final api = FakeSyncApi()
      ..pullQueue.add(
        SyncPullResponse(
          changes: <SyncPullChange>[
            SyncPullChange(
              changeSeq: 130,
              entityType: SyncEntityType.categorySnippet,
              entityId: '工作',
              updatedAt: DateTime.utc(2026, 9, 10, 9),
              deleted: true,
              originDeviceId: 'device-B',
            ),
          ],
          nextCursor: 130,
          headSeq: 130,
        ),
      );
    final engine = buildEngine(storage, api);

    await engine.synchronize(accountId: 'A');

    expect(await storage.items.listCategories(ItemType.snippet), isEmpty);
    final item = await storage.items.getById('item-1');
    expect(item!.category, '');
    expect(storage.sync.pendingCount(), 0);
    storage.close();
  });

  group('pull keeps newer unpushed local changes', () {
    SyncPullResponse categoryDelete(DateTime updatedAt) => SyncPullResponse(
      changes: <SyncPullChange>[
        SyncPullChange(
          changeSeq: 140,
          entityType: SyncEntityType.categorySnippet,
          entityId: '工作',
          updatedAt: updatedAt,
          deleted: true,
          originDeviceId: 'device-B',
        ),
      ],
      nextCursor: 140,
      headSeq: 140,
    );

    test('an older remote category tombstone skips a pending local category',
        () async {
      final storage = JianheStorageDatabase.inMemory();
      storage.sync.writeState('device_id', 'device-A');
      storage.sync.writeState('pull_cursor:A', '0');
      // Journaled with the wall clock, i.e. after the remote stamp below.
      await storage.items.createCategory(ItemType.snippet, '工作');
      final api = FakeSyncApi()
        ..pullQueue.add(categoryDelete(DateTime.utc(2026, 9, 10, 9)));

      await buildEngine(storage, api).synchronize(
        accountId: 'A',
        mode: SyncMode.pullOnly,
      );

      expect(
        await storage.items.listCategories(ItemType.snippet),
        contains('工作'),
      );
      expect(
        storage.sync.latestPendingChangedAt(
          SyncEntityType.categorySnippet,
          '工作',
        ),
        isNotNull,
      );
      expect(storage.sync.readState('pull_cursor:A'), '140');
      storage.close();
    });

    test('a newer remote category tombstone still applies', () async {
      final storage = JianheStorageDatabase.inMemory();
      storage.sync.writeState('device_id', 'device-A');
      storage.sync.writeState('pull_cursor:A', '0');
      await storage.items.createCategory(ItemType.snippet, '工作');
      final api = FakeSyncApi()
        ..pullQueue.add(
          categoryDelete(DateTime.now().toUtc().add(const Duration(hours: 1))),
        );

      await buildEngine(storage, api).synchronize(
        accountId: 'A',
        mode: SyncMode.pullOnly,
      );

      expect(await storage.items.listCategories(ItemType.snippet), isEmpty);
      storage.close();
    });

    // Device A publishes a package whose blob device B can download.
    Future<({FakeSyncApi api, String packageHash})> publishRemotePackage(
      String skillId,
    ) async {
      final deviceA = JianheStorageDatabase.inMemory();
      final remoteSkill = JianheItem.create(
        type: ItemType.skill,
        title: 'demo-skill',
        content: '# 远端 SKILL.md',
        id: skillId,
        now: DateTime.utc(2026, 9, 10, 8),
      );
      final remotePackage = SkillPackage(
        skillId: skillId,
        sourceFormat: SkillSourceFormat.zip,
        importedAt: DateTime.utc(2026, 9, 10, 8),
        files: <SkillFile>[
          SkillFile(
            relativePath: 'remote.md',
            content: Uint8List.fromList(utf8.encode('remote')),
          ),
        ],
      );
      await deviceA.skills.replaceSkill(remoteSkill, remotePackage);
      final apiA = FakeSyncApi();
      await buildEngine(deviceA, apiA).synchronize(accountId: 'A');
      deviceA.close();
      return (
        api: apiA,
        packageHash: remotePackage.packageHash(remoteSkill.content),
      );
    }

    Future<JianheStorageDatabase> deviceWithLocalPackage(String skillId) async {
      final storage = JianheStorageDatabase.inMemory();
      storage.sync.writeState('device_id', 'device-B');
      storage.sync.writeState('pull_cursor:A', '0');
      final skill = JianheItem.create(
        type: ItemType.skill,
        title: 'demo-skill',
        content: '# 本地 SKILL.md',
        id: skillId,
        now: DateTime.utc(2026, 9, 12, 8),
      );
      await storage.skills.replaceSkill(
        skill,
        SkillPackage(
          skillId: skillId,
          sourceFormat: SkillSourceFormat.directory,
          importedAt: DateTime.utc(2026, 9, 12, 8),
          files: <SkillFile>[
            SkillFile(
              relativePath: 'local.md',
              content: Uint8List.fromList(utf8.encode('local')),
            ),
          ],
        ),
      );
      return storage;
    }

    SyncPullResponse packagePut(
      FakeSyncApi apiA,
      String skillId,
      String packageHash,
      DateTime updatedAt,
    ) {
      final put = apiA.putBlobCalls.single;
      return SyncPullResponse(
        changes: <SyncPullChange>[
          SyncPullChange(
            changeSeq: 150,
            entityType: SyncEntityType.skillPackage,
            entityId: skillId,
            updatedAt: updatedAt,
            deleted: false,
            originDeviceId: 'device-A',
            packageHash: packageHash,
            blobSha256: put.sha256,
            byteLength: put.container.length,
            fileCount: 2,
          ),
        ],
        nextCursor: 150,
        headSeq: 150,
      );
    }

    test('an older remote package keeps the pending local files', () async {
      const skillId = '7a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d';
      final remote = await publishRemotePackage(skillId);
      final storage = await deviceWithLocalPackage(skillId);
      final api = FakeSyncApi()
        ..blobs.addAll(remote.api.blobs)
        ..pullQueue.add(
          packagePut(
            remote.api,
            skillId,
            remote.packageHash,
            DateTime.utc(2026, 9, 11, 8),
          ),
        );

      await buildEngine(storage, api).synchronize(
        accountId: 'A',
        mode: SyncMode.pullOnly,
      );

      final package = await storage.skills.getBySkillId(skillId);
      expect(package!.files.map((file) => file.relativePath), <String>[
        'local.md',
      ]);
      expect(
        storage.sync.latestPendingChangedAt(
          SyncEntityType.skillPackage,
          skillId,
        ),
        isNotNull,
      );
      storage.close();
    });

    test('a newer remote package still replaces the local files', () async {
      const skillId = '8b2c3d4e-5f6a-4b7c-9d8e-0f1a2b3c4d5e';
      final remote = await publishRemotePackage(skillId);
      final storage = await deviceWithLocalPackage(skillId);
      final api = FakeSyncApi()
        ..blobs.addAll(remote.api.blobs)
        ..pullQueue.add(
          packagePut(
            remote.api,
            skillId,
            remote.packageHash,
            DateTime.utc(2026, 9, 13, 8),
          ),
        );

      await buildEngine(storage, api).synchronize(
        accountId: 'A',
        mode: SyncMode.pullOnly,
      );

      final package = await storage.skills.getBySkillId(skillId);
      expect(package!.files.map((file) => file.relativePath), <String>[
        'remote.md',
      ]);
      storage.close();
    });
  });

  group('large skill blobs are encoded and decoded off the UI isolate', () {
    // Above the 256 KiB threshold, so both directions take Isolate.run.
    final bigContent = Uint8List.fromList(
      List<int>.generate(300 * 1024, (index) => index % 251),
    );

    Future<({FakeSyncApi api, JianheItem skill, SkillPackage package})>
    publishBigSkill(String skillId) async {
      final deviceA = JianheStorageDatabase.inMemory();
      final skill = JianheItem.create(
        type: ItemType.skill,
        title: 'big-skill',
        content: '# 大技能',
        id: skillId,
        now: DateTime.utc(2026, 9, 10, 8),
      );
      final package = SkillPackage(
        skillId: skillId,
        sourceFormat: SkillSourceFormat.zip,
        importedAt: DateTime.utc(2026, 9, 10, 8),
        files: <SkillFile>[
          SkillFile(relativePath: 'assets/big.bin', content: bigContent),
        ],
      );
      await deviceA.skills.replaceSkill(skill, package);
      final apiA = FakeSyncApi();
      await buildEngine(deviceA, apiA).synchronize(accountId: 'A');
      deviceA.close();
      return (api: apiA, skill: skill, package: package);
    }

    SyncPullResponse pullOf(
      ({FakeSyncApi api, JianheItem skill, SkillPackage package}) remote, {
      String? packageHash,
    }) {
      final put = remote.api.putBlobCalls.single;
      return SyncPullResponse(
        changes: <SyncPullChange>[
          SyncPullChange(
            changeSeq: 400,
            entityType: SyncEntityType.itemSkill,
            entityId: remote.skill.id,
            updatedAt: remote.skill.updatedAt,
            deleted: false,
            originDeviceId: 'device-A',
            envelope: encodeItemEnvelope(remote.skill),
          ),
          SyncPullChange(
            changeSeq: 401,
            entityType: SyncEntityType.skillPackage,
            entityId: remote.skill.id,
            updatedAt: remote.skill.updatedAt,
            deleted: false,
            originDeviceId: 'device-A',
            packageHash:
                packageHash ?? remote.package.packageHash(remote.skill.content),
            blobSha256: put.sha256,
            byteLength: put.container.length,
            fileCount: 2,
          ),
        ],
        nextCursor: 401,
        headSeq: 401,
      );
    }

    test('a large package round trips byte for byte', () async {
      const skillId = '9c3d4e5f-6a7b-4c8d-9e0f-1a2b3c4d5e6f';
      final remote = await publishBigSkill(skillId);
      final put = remote.api.putBlobCalls.single;
      // The uploaded digest is computed off-thread; it must still describe
      // exactly the bytes that were sent.
      expect(put.sha256, sha256.convert(put.container).toString());

      final deviceB = JianheStorageDatabase.inMemory();
      deviceB.sync.writeState('device_id', 'device-B');
      deviceB.sync.writeState('pull_cursor:A', '0');
      final apiB = FakeSyncApi()
        ..blobs.addAll(remote.api.blobs)
        ..pullQueue.add(pullOf(remote));

      await buildEngine(deviceB, apiB).synchronize(accountId: 'A');

      final copied = await deviceB.skills.getBySkillId(skillId);
      expect(copied, isNotNull);
      expect(copied!.files.single.relativePath, 'assets/big.bin');
      expect(copied.files.single.content, bigContent);
      deviceB.close();
    });

    test('a corrupt large package is skipped with a warning, not a failure',
        () async {
      const skillId = 'ad4e5f6a-7b8c-4d9e-8f0a-1b2c3d4e5f60';
      final remote = await publishBigSkill(skillId);

      final deviceB = JianheStorageDatabase.inMemory();
      deviceB.sync.writeState('device_id', 'device-B');
      deviceB.sync.writeState('pull_cursor:A', '0');
      final apiB = FakeSyncApi()
        ..blobs.addAll(remote.api.blobs)
        ..pullQueue.add(pullOf(remote, packageHash: 'f' * 64));

      final result = await buildEngine(
        deviceB,
        apiB,
      ).synchronize(accountId: 'A');

      // The FormatException thrown inside the isolate still reaches the
      // per-record skip path; the host item lands, the package does not.
      expect(await deviceB.items.getById(skillId), isNotNull);
      expect(await deviceB.skills.getBySkillId(skillId), isNull);
      expect(
        result.warnings.where((warning) => warning.contains('无法解析')),
        hasLength(1),
      );
      expect(deviceB.sync.readState('pull_cursor:A'), '401');
      deviceB.close();
    });
  });

  test('skill entities round trip through the blob channel', () async {
    final deviceA = JianheStorageDatabase.inMemory();
    final skill = JianheItem.create(
      type: ItemType.skill,
      title: 'demo-skill',
      content: '# SKILL.md',
      id: 'skill-1',
      now: DateTime.utc(2026, 9, 10, 8),
    );
    await deviceA.items.save(skill);
    final package = SkillPackage(
      skillId: skill.id,
      sourceFormat: SkillSourceFormat.zip,
      importedAt: DateTime.utc(2026, 9, 10, 8),
      files: <SkillFile>[
        SkillFile(
          relativePath: 'assets/logo.bin',
          content: Uint8List.fromList(<int>[0, 255, 1, 254]),
        ),
      ],
    );
    await deviceA.skills.replaceSkill(skill, package);

    final apiA = FakeSyncApi();
    await buildEngine(deviceA, apiA).synchronize(accountId: 'A');
    expect(apiA.putBlobCalls, hasLength(1));

    final deviceB = JianheStorageDatabase.inMemory();
    deviceB.sync.writeState('device_id', 'device-B');
    deviceB.sync.writeState('pull_cursor:A', '0');
    final apiB = FakeSyncApi()..blobs.addAll(apiA.blobs);
    apiB.pullQueue.add(
      SyncPullResponse(
        changes: <SyncPullChange>[
          SyncPullChange(
            changeSeq: 200,
            entityType: SyncEntityType.itemSkill,
            entityId: 'skill-1',
            updatedAt: skill.updatedAt,
            deleted: false,
            originDeviceId: 'device-A',
            envelope: encodeItemEnvelope(skill),
          ),
          SyncPullChange(
            changeSeq: 201,
            entityType: SyncEntityType.skillPackage,
            entityId: 'skill-1',
            updatedAt: skill.updatedAt,
            deleted: false,
            originDeviceId: 'device-A',
            packageHash: package.packageHash(skill.content),
            blobSha256: apiA.putBlobCalls.single.sha256,
            byteLength: apiA.putBlobCalls.single.container.length,
            fileCount: 2,
          ),
        ],
        nextCursor: 201,
        headSeq: 201,
      ),
    );

    await buildEngine(deviceB, apiB).synchronize(accountId: 'A');

    final copiedItem = await deviceB.items.getById('skill-1');
    expect(copiedItem, isNotNull);
    expect(copiedItem!.content, '# SKILL.md');
    final copiedPackage = await deviceB.skills.getBySkillId('skill-1');
    expect(copiedPackage, isNotNull);
    expect(
      copiedPackage!.packageHash(copiedItem.content),
      package.packageHash(skill.content),
    );
    expect(copiedPackage.files.single.relativePath, 'assets/logo.bin');
    expect(copiedPackage.files.single.content,
        Uint8List.fromList(<int>[0, 255, 1, 254]));
    expect(deviceB.sync.readState('pull_cursor:A'), '201');
    deviceA.close();
    deviceB.close();
  });

  // The server keys every change by the wire entity id, which for legacy
  // non-UUID rows is the sha256-derived UUID, while the envelope keeps the
  // sender's local row id. These tests model that real wire shape (unlike
  // the round-trip above, whose fake echoes local ids unchanged).
  String deriveWireId(SyncEntityType type, String localId) {
    final digest = sha256
        .convert(
          utf8.encode('jianhe-legacy-entity/${type.storageValue}/$localId'),
        )
        .toString();
    return '${digest.substring(0, 8)}-'
        '${digest.substring(8, 12)}-'
        '3${digest.substring(13, 16)}-'
        '${digest.substring(16, 20)}-'
        '${digest.substring(20, 32)}';
  }

  JianheStorageDatabase legacyDevice(String deviceId) {
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('device_id', deviceId);
    storage.sync.writeState('pull_cursor:A', '0');
    return storage;
  }

  test('a legacy item pulled from another device merges onto the local row',
      () async {
    // Both devices migrated the same legacy-v0 library, so the local row
    // keeps the legacy id while the wire carries its derived UUID. The
    // pulled put must track the local row — apply-if-newer — instead of a
    // phantom wire-id row, and a newer local edit must survive it.
    final storage = legacyDevice('device-B');
    final local = await seedItem(
      storage,
      id: 'id-1',
      content: '本地已更新的内容',
      now: DateTime.utc(2026, 9, 12, 8),
    );
    // The migrated row was never journaled; with no pending change nothing
    // pushes, so the pull side must establish the mapping on its own.
    storage.sync.deletePendingChanges(
      SyncEntityType.itemSnippet,
      local.id,
      upToSeq: 999,
    );
    final remote = JianheItem.create(
      type: ItemType.snippet,
      title: '条目',
      content: '远端旧内容',
      id: 'id-1',
      now: DateTime.utc(2026, 9, 10, 8),
    );
    final wireId = deriveWireId(SyncEntityType.itemSnippet, 'id-1');
    expect(wireUuidPattern.hasMatch(wireId), isTrue);
    final api = FakeSyncApi()
      ..stateResponse = SyncStateInfo(
        headSeq: 20,
        windowStart: 0,
        quotaUsedBytes: 0,
        quotaMaxBytes: 200 << 20,
      )
      ..pullQueue.add(
        SyncPullResponse(
          changes: <SyncPullChange>[
            SyncPullChange(
              changeSeq: 20,
              entityType: SyncEntityType.itemSnippet,
              entityId: wireId,
              updatedAt: remote.updatedAt,
              deleted: false,
              originDeviceId: 'device-A',
              envelope: encodeItemEnvelope(remote),
            ),
          ],
          nextCursor: 20,
          headSeq: 20,
        ),
      );

    await buildEngine(storage, api).synchronize(accountId: 'A');

    // The older remote record loses; the local edit survives.
    final merged = await storage.items.getById('id-1');
    expect(merged!.content, '本地已更新的内容');
    // No phantom row keyed by the wire id, and the mapping is durable.
    expect(await storage.items.getById(wireId), isNull);
    expect(
      storage.sync.readState('legacy_id_reverse:item:snippet:$wireId'),
      'id-1',
    );
    expect(storage.sync.pendingCount(), 0);
    storage.close();
  });

  test('a legacy tombstone deletes the locally migrated row', () async {
    // No envelope travels with a tombstone, so the wire id must reverse
    // through derivation over the local legacy rows.
    final storage = legacyDevice('device-B');
    final local = await seedItem(storage, id: 'id-1');
    storage.sync.deletePendingChanges(
      SyncEntityType.itemSnippet,
      local.id,
      upToSeq: 999,
    );
    final wireId = deriveWireId(SyncEntityType.itemSnippet, 'id-1');
    final api = FakeSyncApi()
      ..stateResponse = SyncStateInfo(
        headSeq: 30,
        windowStart: 0,
        quotaUsedBytes: 0,
        quotaMaxBytes: 200 << 20,
      )
      ..pullQueue.add(
        SyncPullResponse(
          changes: <SyncPullChange>[
            SyncPullChange(
              changeSeq: 30,
              entityType: SyncEntityType.itemSnippet,
              entityId: wireId,
              updatedAt: DateTime.utc(2026, 9, 12, 8),
              deleted: true,
              originDeviceId: 'device-A',
            ),
          ],
          nextCursor: 30,
          headSeq: 30,
        ),
      );

    await buildEngine(storage, api).synchronize(accountId: 'A');

    expect(await storage.items.getById('id-1'), isNull);
    storage.close();
  });

  test('a legacy skill package lands on the locally migrated host', () async {
    // Device A pushes its legacy skill exactly as the wire carries it:
    // entity ids are the derived UUIDs, envelopes keep the legacy local id.
    final deviceA = JianheStorageDatabase.inMemory();
    final skill = JianheItem.create(
      type: ItemType.skill,
      title: 'demo-skill',
      content: '# SKILL.md',
      id: 'skill-legacy-1',
      now: DateTime.utc(2026, 9, 10, 8),
    );
    await deviceA.items.save(skill);
    final package = SkillPackage(
      skillId: skill.id,
      sourceFormat: SkillSourceFormat.zip,
      importedAt: DateTime.utc(2026, 9, 10, 8),
      files: <SkillFile>[
        SkillFile(
          relativePath: 'assets/logo.bin',
          content: Uint8List.fromList(<int>[0, 255, 1, 254]),
        ),
      ],
    );
    await deviceA.skills.replaceSkill(skill, package);
    final apiA = FakeSyncApi();
    await buildEngine(deviceA, apiA).synchronize(accountId: 'A');
    final pushedChanges = apiA.pushCalls
        .expand((call) => call.changes)
        .toList(growable: false);
    final pushedItem = pushedChanges.firstWhere(
      (change) => change.entityType == SyncEntityType.itemSkill,
    );
    final pushedPackage = pushedChanges.firstWhere(
      (change) => change.entityType == SyncEntityType.skillPackage,
    );
    expect(pushedItem.entityId, deriveWireId(SyncEntityType.itemSkill, skill.id));

    // Device B migrated the same library: the host row exists with the
    // legacy id, but the package was never installed here.
    final deviceB = legacyDevice('device-B');
    final localSkill = await seedItem(
      deviceB,
      id: 'skill-legacy-1',
      type: ItemType.skill,
      title: 'demo-skill',
      content: '# SKILL.md',
      now: DateTime.utc(2026, 9, 9, 8),
    );
    deviceB.sync.deletePendingChanges(
      SyncEntityType.itemSkill,
      localSkill.id,
      upToSeq: 999,
    );
    final apiB = FakeSyncApi()
      ..blobs.addAll(apiA.blobs)
      ..stateResponse = SyncStateInfo(
        headSeq: 40,
        windowStart: 0,
        quotaUsedBytes: 0,
        quotaMaxBytes: 200 << 20,
      )
      ..pullQueue.add(
        SyncPullResponse(
          changes: <SyncPullChange>[
            SyncPullChange(
              changeSeq: 40,
              entityType: SyncEntityType.itemSkill,
              entityId: pushedItem.entityId,
              updatedAt: pushedItem.updatedAt,
              deleted: false,
              originDeviceId: 'device-A',
              envelope: pushedItem.envelope,
            ),
            SyncPullChange(
              changeSeq: 41,
              entityType: SyncEntityType.skillPackage,
              entityId: pushedPackage.entityId,
              updatedAt: pushedPackage.updatedAt,
              deleted: false,
              originDeviceId: 'device-A',
              packageHash: pushedPackage.packageHash,
              blobSha256: pushedPackage.blobSha256,
              byteLength: pushedPackage.byteLength,
              fileCount: pushedPackage.fileCount,
            ),
          ],
          nextCursor: 41,
          headSeq: 41,
        ),
      );

    final result = await buildEngine(deviceB, apiB).synchronize(accountId: 'A');

    final copiedItem = await deviceB.items.getById('skill-legacy-1');
    expect(copiedItem, isNotNull);
    expect(copiedItem!.content, '# SKILL.md');
    final copiedPackage = await deviceB.skills.getBySkillId('skill-legacy-1');
    expect(copiedPackage, isNotNull);
    expect(copiedPackage!.files.single.relativePath, 'assets/logo.bin');
    expect(
      copiedPackage.files.single.content,
      Uint8List.fromList(<int>[0, 255, 1, 254]),
    );
    // The host-missing warning must not fire.
    expect(
      result.warnings.where((warning) => warning.contains('宿主条目不存在')),
      isEmpty,
    );
    deviceA.close();
    deviceB.close();
  });

  test('remote package tombstones clean up while the item row stays',
      () async {
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('device_id', 'device-A');
    storage.sync.writeState('pull_cursor:A', '0');
    final skill = await seedItem(
      storage,
      id: 'skill-1',
      type: ItemType.skill,
      title: 'demo-skill',
      content: '# SKILL.md',
      now: DateTime.utc(2026, 9, 10, 8),
    );
    await storage.skills.replaceSkill(
      skill,
      SkillPackage(
        skillId: skill.id,
        sourceFormat: SkillSourceFormat.markdown,
        importedAt: DateTime.utc(2026, 9, 10, 8),
      ),
    );

    final api = FakeSyncApi()
      ..pullQueue.add(
        SyncPullResponse(
          changes: <SyncPullChange>[
            SyncPullChange(
              changeSeq: 300,
              entityType: SyncEntityType.skillPackage,
              entityId: 'skill-1',
              updatedAt: DateTime.utc(2026, 9, 10, 9),
              deleted: true,
              originDeviceId: 'device-B',
            ),
          ],
          nextCursor: 300,
          headSeq: 300,
        ),
      );
    await buildEngine(storage, api).synchronize(accountId: 'A');

    expect(await storage.skills.getBySkillId('skill-1'), isNull);
    expect(await storage.items.getById('skill-1'), isNotNull);
    storage.close();
  });

  group('a remote record that can never be applied is skipped', () {
    final missingBlob = 'a' * 64;

    SyncPullChange missingSkillPackage(int seq) => SyncPullChange(
      changeSeq: seq,
      entityType: SyncEntityType.skillPackage,
      entityId: 'skill-1',
      updatedAt: DateTime.utc(2026, 9, 10, 8),
      deleted: false,
      originDeviceId: 'device-B',
      packageHash: 'b' * 64,
      blobSha256: missingBlob,
      byteLength: 10,
      fileCount: 1,
    );

    SyncPullChange itemChange(int seq, JianheItem item) => SyncPullChange(
      changeSeq: seq,
      entityType: SyncEntityType.forItem(item.type),
      entityId: item.id,
      updatedAt: item.updatedAt,
      deleted: false,
      originDeviceId: 'device-B',
      envelope: encodeItemEnvelope(item),
    );

    JianheItem remoteItem(String id) => JianheItem.create(
      type: ItemType.snippet,
      title: '远端条目 $id',
      content: '远端内容',
      id: id,
      now: DateTime.utc(2026, 9, 10, 9),
    );

    test('pull skips a skill package whose blob the server no longer has '
        'and keeps advancing', () async {
      // A superseded package version was collected while the change log
      // still pointed at it. Failing the run here left the cursor stuck and
      // every later run stopped on the same change.
      final storage = JianheStorageDatabase.inMemory();
      storage.sync.writeState('device_id', 'device-A');
      storage.sync.writeState('pull_cursor:A', '0');
      final api = FakeSyncApi()
        ..pullQueue.add(
          SyncPullResponse(
            changes: <SyncPullChange>[
              missingSkillPackage(101),
              itemChange(102, remoteItem('item-2')),
            ],
            nextCursor: 102,
            headSeq: 102,
          ),
        );

      final result = await buildEngine(storage, api).synchronize(
        accountId: 'A',
      );

      expect(result.warnings, hasLength(1));
      expect(result.warnings.single, contains('skill-1'));
      expect((await storage.items.getById('item-2'))!.content, '远端内容');
      expect(storage.sync.readState('pull_cursor:A'), '102');
      expect(api.reportCursorCalls, <int>[102]);
      storage.close();
    });

    test('pull skips envelopes with missing or invalid fields', () async {
      final storage = JianheStorageDatabase.inMemory();
      storage.sync.writeState('device_id', 'device-A');
      storage.sync.writeState('pull_cursor:A', '0');
      final missingType = Map<String, Object?>.from(
        jsonDecode(utf8.decode(encodeItemEnvelope(remoteItem('item-1'))))
            as Map,
      )..remove('type');
      final overlongTitle = Map<String, Object?>.from(
        jsonDecode(utf8.decode(encodeItemEnvelope(remoteItem('item-2'))))
            as Map,
      )..['title'] = '长' * (JianheItem.maxTitleLength + 1);
      SyncPullChange raw(int seq, String id, Map<String, Object?> envelope) =>
          SyncPullChange(
            changeSeq: seq,
            entityType: SyncEntityType.itemSnippet,
            entityId: id,
            updatedAt: DateTime.utc(2026, 9, 10, 9),
            deleted: false,
            originDeviceId: 'device-B',
            envelope: utf8.encode(jsonEncode(envelope)),
          );
      final api = FakeSyncApi()
        ..pullQueue.add(
          SyncPullResponse(
            changes: <SyncPullChange>[
              raw(101, 'item-1', missingType),
              raw(102, 'item-2', overlongTitle),
              itemChange(103, remoteItem('item-3')),
            ],
            nextCursor: 103,
            headSeq: 103,
          ),
        );

      final result = await buildEngine(storage, api).synchronize(
        accountId: 'A',
      );

      expect(result.warnings, hasLength(2));
      expect(result.warnings[0], contains('item-1'));
      expect(result.warnings[1], contains('item-2'));
      expect(await storage.items.getById('item-1'), isNull);
      expect(await storage.items.getById('item-2'), isNull);
      expect(await storage.items.getById('item-3'), isNotNull);
      expect(storage.sync.readState('pull_cursor:A'), '103');
      storage.close();
    });

    test('a server error while downloading a blob still fails the run',
        () async {
      // Only "this record cannot be applied" is skippable; a transient
      // failure must keep the cursor so the next run retries the record.
      final storage = JianheStorageDatabase.inMemory();
      storage.sync.writeState('device_id', 'device-A');
      storage.sync.writeState('pull_cursor:A', '0');
      final api = FakeSyncApi()
        ..getBlobHook = (_) async {
          throw const AccountApiException(
            code: 'SERVER_ERROR',
            message: '云同步服务暂时不可用，请稍后重试。',
            retryable: true,
          );
        }
        ..pullQueue.add(
          SyncPullResponse(
            changes: <SyncPullChange>[
              missingSkillPackage(101),
              itemChange(102, remoteItem('item-2')),
            ],
            nextCursor: 102,
            headSeq: 102,
          ),
        );

      await expectLater(
        buildEngine(storage, api).synchronize(accountId: 'A'),
        throwsA(
          isA<AccountApiException>().having(
            (error) => error.code,
            'code',
            'SERVER_ERROR',
          ),
        ),
      );
      expect(storage.sync.readState('pull_cursor:A'), '0');
      expect(await storage.items.getById('item-2'), isNull);
      storage.close();
    });

    test('full resync skips a skill package whose blob is missing', () async {
      final storage = JianheStorageDatabase.inMemory();
      storage.sync.writeState('device_id', 'device-A');
      storage.sync.writeState('pull_cursor:A', '100');
      final api = FakeSyncApi()
        ..stateResponse = SyncStateInfo(
          headSeq: 1042,
          windowStart: 930,
          quotaUsedBytes: 0,
          quotaMaxBytes: 200 << 20,
        )
        ..snapshotQueue.add(
          SyncSnapshotResponse(
            changes: <SyncPullChange>[
              missingSkillPackage(931),
              itemChange(932, remoteItem('item-2')),
            ],
            headSeq: 1042,
          ),
        );

      final result = await buildEngine(storage, api).synchronize(
        accountId: 'A',
      );

      expect(result.warnings.where((w) => w.contains('skill-1')), isNotEmpty);
      expect(await storage.items.getById('item-2'), isNotNull);
      storage.close();
    });
  });

  test('pull cursors are namespaced per account', () async {
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('device_id', 'device-A');
    storage.sync.writeState('pull_cursor:A', '5');
    final api = FakeSyncApi()
      ..pullQueue.add(
        SyncPullResponse(
          changes: <SyncPullChange>[
            SyncPullChange(
              changeSeq: 50,
              entityType: SyncEntityType.categorySnippet,
              entityId: '不存在',
              updatedAt: DateTime.utc(2026, 9, 10, 8),
              deleted: true,
              originDeviceId: 'device-B',
            ),
          ],
          nextCursor: 55,
          headSeq: 55,
        ),
      );
    final engine = buildEngine(storage, api);

    await engine.synchronize(accountId: 'A');
    expect(storage.sync.readState('pull_cursor:A'), '55');

    // Account B has no stored cursor: its first sync runs the recovery
    // (snapshot + re-push) and writes its own namespaced cursor instead of
    // resuming from A's position.
    await engine.synchronize(accountId: 'B');
    expect(api.pullCalls.map((call) => call.cursor), <int>[5]);
    expect(storage.sync.readState('pull_cursor:A'), '55');
    expect(storage.sync.readState('pull_cursor:B'), '10');
    storage.close();
  });

  test('pull is skipped when the response page is empty', () async {
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('device_id', 'device-A');
    storage.sync.writeState('pull_cursor:A', '0');
    final api = FakeSyncApi();
    final engine = buildEngine(storage, api);

    final result = await engine.synchronize(accountId: 'A');

    expect(result.pulledCount, 0);
    expect(api.pullCalls, hasLength(1));
    expect(api.reportCursorCalls, isEmpty);
    storage.close();
  });

  String uuidFor(int n) =>
      '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

  SyncStateInfo quotaState(int usedMiB) => SyncStateInfo(
        headSeq: 10,
        windowStart: 0,
        quotaUsedBytes: usedMiB << 20,
        quotaMaxBytes: 200 << 20,
      );

  /// Accepts every record except the ones [rejected] turns away for space.
  SyncPushResponse quotaAnswer(
    List<SyncPushChange> changes,
    bool Function(SyncPushChange change) rejected,
  ) {
    return SyncPushResponse(
      headSeq: 99,
      results: <SyncPushResult>[
        for (final change in changes)
          rejected(change)
              ? SyncPushResult(
                  entityType: change.entityType,
                  entityId: change.entityId,
                  accepted: false,
                  reason: 'QUOTA_EXCEEDED',
                )
              : SyncPushResult(
                  entityType: change.entityType,
                  entityId: change.entityId,
                  accepted: true,
                  changeSeq: 11,
                ),
      ],
    );
  }

  Future<void> seedSkillPackage(JianheStorageDatabase storage) async {
    final skill = await seedItem(
      storage,
      id: 'skill-1',
      type: ItemType.skill,
      title: 'demo-skill',
      content: '# SKILL.md',
    );
    final package = SkillPackage(
      skillId: skill.id,
      sourceFormat: SkillSourceFormat.zip,
      importedAt: DateTime.utc(2026, 9, 10, 8),
      files: <SkillFile>[
        SkillFile(
          relativePath: 'assets/logo.bin',
          content: Uint8List.fromList(<int>[0, 255, 1, 254]),
        ),
      ],
    );
    await storage.skills.replaceSkill(skill, package);
  }

  Set<SyncEntityType> pendingTypes(JianheStorageDatabase storage) => <SyncEntityType>{
        for (final row in storage.sync.readPendingChanges()) row.entityType,
      };

  test('records the full cloud space turns away stay queued until space '
      'frees up', () async {
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('pull_cursor:A', '10');
    await seedItem(storage, id: uuidFor(1), title: '小改动');
    await seedItem(storage, id: uuidFor(2), title: '大改动');
    var full = true;
    final api = FakeSyncApi()..stateResponse = quotaState(200);
    api.pushHook = (changes) async =>
        quotaAnswer(changes, (change) => full && change.entityId == uuidFor(2));
    final engine = buildEngine(storage, api);

    final first = await engine.synchronize(accountId: 'A');
    expect(first.pushedCount, 1);
    expect(first.quotaBlockedCount, 1);
    expect(first.quotaNotice, contains('云同步空间已满'));
    expect(first.quotaNotice, contains('200 MB'));
    expect(first.warnings.first, first.quotaNotice);
    expect(
      storage.sync.readPendingChanges().map((row) => row.entityId),
      <String>[uuidFor(2)],
    );
    expect((await storage.items.getById(uuidFor(2)))?.title, '大改动');

    // Nothing changed on the server: the held record is not offered again.
    final second = await engine.synchronize(accountId: 'A');
    expect(api.pushCalls, hasLength(1));
    expect(second.quotaBlockedCount, 1);

    // Space was freed (from another device): the record goes out.
    full = false;
    api.stateResponse = quotaState(150);
    final third = await engine.synchronize(accountId: 'A');
    expect(api.pushCalls, hasLength(2));
    expect(api.pushCalls.last.changes.single.entityId, uuidFor(2));
    expect(third.quotaBlockedCount, 0);
    expect(third.quotaNotice, isNull);
    expect(storage.sync.pendingCount(), 0);
    storage.close();
  });

  test('deletes queued behind held records still go out and make room in '
      'the same run', () async {
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('pull_cursor:A', '10');
    await seedItem(storage, id: uuidFor(999), title: '旧素材');
    storage.sync.deletePendingChanges(
      SyncEntityType.itemSnippet,
      uuidFor(999),
      upToSeq: storage.sync.maxPendingSeq(),
    );
    for (var i = 1; i <= 100; i++) {
      await seedItem(storage, id: uuidFor(i));
    }
    // The delete sits behind a full page of records that do not fit.
    await storage.items.delete(uuidFor(999));
    expect(storage.sync.pendingCount(), 101);
    var freed = false;
    final api = FakeSyncApi()..stateResponse = quotaState(200);
    api.pushHook = (changes) async {
      if (changes.any((change) => change.deleted)) freed = true;
      return quotaAnswer(changes, (change) => !change.deleted && !freed);
    };

    final result = await buildEngine(storage, api).synchronize(accountId: 'A');

    // 100 puts turned away, then the delete behind them, then the puts again.
    expect(
      api.pushCalls.map((call) => call.changes.length),
      <int>[100, 1, 100],
    );
    expect(api.pushCalls[1].changes.single.deleted, isTrue);
    expect(result.quotaBlockedCount, 0);
    expect(storage.sync.pendingCount(), 0);
    storage.close();
  });

  test('a full resync queues the records the cloud space turned away',
      () async {
    final storage = JianheStorageDatabase.inMemory();
    for (final n in <int>[1, 2]) {
      await seedItem(storage, id: uuidFor(n));
      // Migrated rows carry no journal entries; only the re-push ships them.
      storage.sync.deletePendingChanges(
        SyncEntityType.itemSnippet,
        uuidFor(n),
        upToSeq: storage.sync.maxPendingSeq(),
      );
    }
    var full = true;
    final api = FakeSyncApi()..stateResponse = quotaState(200);
    api.pushHook = (changes) async =>
        quotaAnswer(changes, (change) => full && change.entityId == uuidFor(2));

    final result = await buildEngine(storage, api).synchronize(accountId: 'A');

    expect(storage.sync.readState('pull_cursor:A'), '10');
    // Without a journal row the turned-away entity would never be retried
    // once the recovery cursor moved past it.
    expect(
      storage.sync.readPendingChanges().map((row) => row.entityId).toSet(),
      <String>{uuidFor(2)},
    );
    expect(result.quotaBlockedCount, 1);

    full = false;
    api.stateResponse = quotaState(150);
    final later = await buildEngine(storage, api).synchronize(accountId: 'A');
    expect(later.pushedCount, 1);
    expect(storage.sync.pendingCount(), 0);
    storage.close();
  });

  test('a blob upload refused for space keeps the package queued', () async {
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('pull_cursor:A', '10');
    await seedSkillPackage(storage);
    var putAttempts = 0;
    final api = FakeSyncApi()
      ..stateResponse = quotaState(200)
      ..putBlobHook = (sha256, container) async {
        putAttempts++;
        throw const AccountApiException(
          code: 'SYNC_QUOTA_EXCEEDED',
          message: '同步空间已达到上限。',
          retryable: false,
        );
      };
    final engine = buildEngine(storage, api);

    final result = await engine.synchronize(accountId: 'A');

    // The item itself still syncs; the package waits instead of being
    // shelved for good.
    expect(result.quotaBlockedCount, 1);
    expect(
      api.pushCalls.expand((call) => call.changes).map((c) => c.entityId),
      contains(deriveWireId(SyncEntityType.itemSkill, 'skill-1')),
    );
    expect(pendingTypes(storage), <SyncEntityType>{SyncEntityType.skillPackage});

    // Not retried while nothing changed…
    await engine.synchronize(accountId: 'A');
    expect(putAttempts, 1);

    // …and uploaded once space frees up.
    api
      ..putBlobHook = null
      ..stateResponse = quotaState(100);
    final later = await engine.synchronize(accountId: 'A');
    expect(api.putBlobCalls, hasLength(1));
    expect(later.quotaBlockedCount, 0);
    expect(storage.sync.pendingCount(), 0);
    storage.close();
  });

  test('a busy server defers the package upload to the next run', () async {
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('pull_cursor:A', '10');
    await seedSkillPackage(storage);
    final api = FakeSyncApi()
      ..putBlobHook = (sha256, container) async {
        throw const AccountApiException(
          code: 'SYNC_STORAGE_BUSY',
          message: '云端正在整理同步历史，请稍后重试。',
          retryable: true,
        );
      };
    final engine = buildEngine(storage, api);

    final result = await engine.synchronize(accountId: 'A');

    expect(result.warnings, contains(contains('云端正在整理同步空间')));
    expect(result.quotaBlockedCount, 0);
    expect(pendingTypes(storage), <SyncEntityType>{SyncEntityType.skillPackage});

    api.putBlobHook = null;
    await engine.synchronize(accountId: 'A');
    expect(api.putBlobCalls, hasLength(1));
    expect(storage.sync.pendingCount(), 0);
    storage.close();
  });

  test('a package over the blob size limit is shelved with a message naming '
      'the Skill', () async {
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('pull_cursor:A', '10');
    await seedSkillPackage(storage);
    final api = FakeSyncApi()
      ..putBlobHook = (sha256, container) async {
        throw const AccountApiException(
          code: 'SYNC_BLOB_TOO_LARGE',
          message: '单个同步数据块超过 64 MiB。',
          retryable: false,
        );
      };
    final engine = buildEngine(storage, api);

    final result = await engine.synchronize(accountId: 'A');

    expect(
      result.warnings.any(
        (warning) =>
            warning.contains('demo-skill') && warning.contains('只保存在本机'),
      ),
      isTrue,
    );
    expect(result.quotaBlockedCount, 0);
    expect(storage.sync.pendingCount(), 0);
    // No livelock: a second run also completes without throwing.
    await buildEngine(storage, api).synchronize(accountId: 'A');
    storage.close();
  });

  test('a package upload refused as INVALID_REQUEST keeps it queued without '
      'failing the sync', () async {
    final storage = JianheStorageDatabase.inMemory();
    storage.sync.writeState('pull_cursor:A', '10');
    await seedSkillPackage(storage);
    final api = FakeSyncApi()
      ..putBlobHook = (sha256, container) async {
        throw const AccountApiException(
          code: 'INVALID_REQUEST',
          message: '同步请求无效。',
          retryable: false,
        );
      };
    final engine = buildEngine(storage, api);

    // Must not throw: one refused upload cannot block the rest of the run.
    final result = await engine.synchronize(accountId: 'A');

    expect(
      api.pushCalls.expand((call) => call.changes).map((c) => c.entityId),
      contains(deriveWireId(SyncEntityType.itemSkill, 'skill-1')),
    );
    expect(
      result.warnings.any(
        (warning) =>
            warning.contains('demo-skill') && warning.contains('已保留待下次同步'),
      ),
      isTrue,
    );
    expect(pendingTypes(storage), <SyncEntityType>{SyncEntityType.skillPackage});

    // Once the server accepts the upload, the next run delivers it.
    api.putBlobHook = null;
    await engine.synchronize(accountId: 'A');
    expect(api.putBlobCalls, hasLength(1));
    expect(storage.sync.pendingCount(), 0);
    storage.close();
  });

  test('recovery re-push resumes from the durable cursor', () async {
    // 101 migrated rows re-push as 100+1 batches. Batch 1 delivers, then
    // the run dies; the next run must skip the snapshot and push only the
    // remaining entity instead of starting the whole recovery over.
    final storage = JianheStorageDatabase.inMemory();
    for (var i = 1; i <= 101; i++) {
      final item = await seedItem(storage, id: 'item-${i.toString().padLeft(3, '0')}');
      storage.sync.deletePendingChanges(
        SyncEntityType.itemSnippet,
        item.id,
        upToSeq: 999,
      );
    }
    var pushAttempt = 0;
    final apiRun1 = FakeSyncApi()
      ..pushHook = (changes) async {
        pushAttempt++;
        if (pushAttempt > 1) {
          throw const AccountApiException(
            code: 'AUTH_REQUIRED',
            message: '登录状态已失效。',
            retryable: false,
          );
        }
        return SyncPushResponse(
          headSeq: 1000,
          results: <SyncPushResult>[
            for (final change in changes)
              SyncPushResult(
                entityType: change.entityType,
                entityId: change.entityId,
                accepted: true,
                changeSeq: 1000,
              ),
          ],
        );
      };

    await expectLater(
      buildEngine(storage, apiRun1).synchronize(accountId: 'A'),
      throwsA(isA<AccountApiException>()),
    );

    // The durable resume cursor survived the failed run and points past
    // the first batch (batch 1 = items 001..100 by sorted id).
    expect(apiRun1.snapshotCalls, isNotEmpty);
    expect(
      storage.sync.readState('recovery_repush_cursor:A'),
      '0|item-100',
    );

    final apiRun2 = FakeSyncApi();
    await buildEngine(storage, apiRun2).synchronize(accountId: 'A');

    // Resume: no snapshot, exactly one entity re-pushed (item-101).
    expect(apiRun2.snapshotCalls, isEmpty);
    final repushed = apiRun2.pushCalls
        .expand((call) => call.changes.map((change) => change.entityId))
        .toList();
    expect(repushed, hasLength(1));
    expect(repushed.single, deriveWireId(SyncEntityType.itemSnippet, 'item-101'));
    // Checkpoint cleaned up and the durable cursor landed.
    expect(storage.sync.readState('recovery_repush_cursor:A'), isNull);
    expect(storage.sync.readState('recovery_min_head:A'), isNull);
    expect(storage.sync.readState('pull_cursor:A'), isNotNull);
    storage.close();
  });

  test('a run killed before the first re-push batch resumes without a '
      'second snapshot', () async {
    // The checkpoint written right after the snapshot must be a parseable
    // '0|' cursor; a malformed one decodes as "no checkpoint" and the next
    // run silently starts the whole recovery over.
    final storage = JianheStorageDatabase.inMemory();
    final item = await seedItem(storage, id: 'item-1');
    storage.sync.deletePendingChanges(
      SyncEntityType.itemSnippet,
      item.id,
      upToSeq: 999,
    );
    final apiRun1 = FakeSyncApi()
      ..pushHook = (changes) async {
        throw const AccountApiException(
          code: 'AUTH_REQUIRED',
          message: '登录状态已失效。',
          retryable: false,
        );
      };

    await expectLater(
      buildEngine(storage, apiRun1).synchronize(accountId: 'A'),
      throwsA(isA<AccountApiException>()),
    );
    expect(apiRun1.snapshotCalls, isNotEmpty);
    expect(storage.sync.readState('recovery_repush_cursor:A'), '0|');

    final apiRun2 = FakeSyncApi();
    await buildEngine(storage, apiRun2).synchronize(accountId: 'A');

    expect(apiRun2.snapshotCalls, isEmpty);
    final repushed = apiRun2.pushCalls
        .expand((call) => call.changes.map((change) => change.entityId))
        .toList();
    expect(repushed, [deriveWireId(SyncEntityType.itemSnippet, 'item-1')]);
    expect(storage.sync.readState('recovery_repush_cursor:A'), isNull);
    storage.close();
  });

  test('recovery resume keeps categories of later types whose names sort '
      'before the cursor', () async {
    // 99 items + the prompt category fill batch 1 exactly; the skill
    // category "A" lands in batch 2. With one shared category phase the
    // resume compared "A" against the prompt cursor "工作" and skipped it.
    final storage = JianheStorageDatabase.inMemory();
    for (var i = 1; i <= 99; i++) {
      final item = await seedItem(
        storage,
        id: 'item-${i.toString().padLeft(3, '0')}',
      );
      storage.sync.deletePendingChanges(
        SyncEntityType.itemSnippet,
        item.id,
        upToSeq: 999,
      );
    }
    await storage.items.createCategory(ItemType.prompt, '工作');
    await storage.items.createCategory(ItemType.skill, 'A');
    // Migrated rows carry no journal: only the re-push can ship them.
    storage.sync.deletePendingChanges(
      SyncEntityType.categoryPrompt,
      '工作',
      upToSeq: 999,
    );
    storage.sync.deletePendingChanges(
      SyncEntityType.categorySkill,
      'A',
      upToSeq: 999,
    );
    expect(storage.sync.pendingCount(), 0);

    var pushAttempt = 0;
    final apiRun1 = FakeSyncApi()
      ..pushHook = (changes) async {
        pushAttempt++;
        if (pushAttempt > 1) {
          throw const AccountApiException(
            code: 'AUTH_REQUIRED',
            message: '登录状态已失效。',
            retryable: false,
          );
        }
        return SyncPushResponse(
          headSeq: 1000,
          results: <SyncPushResult>[
            for (final change in changes)
              SyncPushResult(
                entityType: change.entityType,
                entityId: change.entityId,
                accepted: true,
                changeSeq: 1000,
              ),
          ],
        );
      };

    await expectLater(
      buildEngine(storage, apiRun1).synchronize(accountId: 'A'),
      throwsA(isA<AccountApiException>()),
    );
    expect(storage.sync.readState('recovery_repush_cursor:A'), '1|工作');

    final apiRun2 = FakeSyncApi();
    await buildEngine(storage, apiRun2).synchronize(accountId: 'A');

    expect(apiRun2.snapshotCalls, isEmpty);
    final repushed = apiRun2.pushCalls
        .expand(
          (call) => call.changes.map(
            (change) => (change.entityType, change.entityId),
          ),
        )
        .toList();
    expect(repushed, [(SyncEntityType.categorySkill, 'A')]);
    storage.close();
  });
}
