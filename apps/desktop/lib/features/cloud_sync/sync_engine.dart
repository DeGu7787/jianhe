import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:jianhe_core/jianhe_core.dart';
import 'package:jianhe_storage/jianhe_storage.dart';

import '../../l10n/app_strings.dart';
import '../account/account_api.dart';
import 'sync_api.dart';
import 'sync_models.dart';

export 'sync_models.dart'
    show SyncEngineException, SyncCancelledException, SyncRunResult, SyncMode;

/// Injection seam for [AccountSessionController.authorizedRequest]: token
/// refresh + one AUTH_REQUIRED retry around every API call.
typedef SyncAuthorizedRequest = Future<T> Function<T>(
  Future<T> Function(String accessToken) action,
);

/// Resolves the device id the server issued for this session (auth session
/// `device.id`). Pushes must present this exact id — the server compares the
/// request body against the access token's device claim and rejects any
/// mismatch as INVALID_REQUEST. Returns null before the first login.
typedef SyncDeviceIdProvider = String? Function();
typedef SyncCancelled = bool Function();

/// One coalesced pending entity: the newest journal row wins.
class _CoalescedChange {
  const _CoalescedChange._(
    this.entityType,
    this.entityId,
    this.maxSeq,
    this.op,
    this.changedAt,
  );

  final SyncEntityType entityType;
  final String entityId;
  final int maxSeq;
  final SyncChangeOp op;
  final DateTime changedAt;
}

/// A pull record with its JSON payload already decoded, so the apply
/// transaction only runs SQL.
class _ResolvedPull {
  _ResolvedPull(this.change, {required this.localEntityId});

  final SyncPullChange change;

  /// Wire id translated back to the local row id via the legacy mapping;
  /// identical for UUID and category ids. Item puts re-assign this from the
  /// envelope id in [_SyncResolvePayload] so legacy entities track and land
  /// on the sender's local row id.
  String localEntityId;
  JianheItem? item;
  CategorySyncSnapshot? category;
  _SkillBlobPayload? blob;
}

class _SkillBlobPayload {
  const _SkillBlobPayload({
    required this.entrypoint,
    required this.sourceFormat,
    required this.importedAt,
    required this.manifest,
    required this.files,
    required this.packageHash,
  });

  final String entrypoint;
  final SkillSourceFormat sourceFormat;
  final DateTime importedAt;
  final String manifest;
  final List<SkillFile> files;
  final String packageHash;

  int get byteLength =>
      files.fold<int>(manifest.length, (total, file) => total + file.byteLength);
}

/// Hands the UI isolate back to the event loop during long synchronous
/// stretches (applying a pull page, building a full re-push), so frames and
/// input keep flowing. It yields after [maxRecords] records or [maxBytes] of
/// payload, whichever comes first; small runs never yield at all.
///
/// Yielding inside a write transaction is safe: this connection's other
/// transactional writes queue behind it, and settings saves issued meanwhile
/// are deferred until it ends (SqliteSettingsStore.attachWriteGuard), so a
/// rollback can never take them along.
class _YieldBudget {
  _YieldBudget({this.maxRecords = 100, this.maxBytes = 2 << 20});

  final int maxRecords;
  final int maxBytes;
  int _records = 0;
  int _bytes = 0;

  Future<void> spend({int bytes = 0}) async {
    _records++;
    _bytes += bytes;
    if (_records < maxRecords && _bytes < maxBytes) return;
    _records = 0;
    _bytes = 0;
    await Future<void>.delayed(Duration.zero);
  }
}

int _pullPayloadBytes(_ResolvedPull entry) =>
    entry.blob?.byteLength ?? entry.change.envelope?.length ?? 0;

/// Skill blob bytes kept until the metadata push that references them is
/// acknowledged. Re-encoding is deterministic, but caching keeps the sha256
/// and the uploaded object consistent with the metadata record.
class _BlobCacheEntry {
  _BlobCacheEntry({
    required this.packageHash,
    required this.bytes,
    required this.sha256,
  });

  final String packageHash;
  final Uint8List bytes;
  final String sha256;
}

/// One batched push record plus the bookkeeping its acknowledgement needs.
class _BuiltRecord {
  const _BuiltRecord({
    required this.entry,
    required this.record,
    this.ackItemUpdatedAt,
  });

  final _CoalescedChange entry;
  final SyncPushChange record;

  /// The item row's updated_at at build time; the ack gate compares it
  /// against the live row so mid-flight edits keep their pending rows.
  final DateTime? ackItemUpdatedAt;
}

final RegExp _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

class SyncEngine {
  SyncEngine({
    required JianheStorageDatabase storage,
    required SyncRemoteDataSource api,
    required SyncAuthorizedRequest authorizedRequest,
    SyncDeviceIdProvider? serverDeviceId,
    Random? secureRandom,
    this.retryDelay = const Duration(seconds: 2),
    this.maxSendAttempts = 3,
    this.rateLimitDelay = const Duration(seconds: 10),
    this.maxRateLimitedAttempts = 6,
  }) : _storage = storage,
       _api = api,
       _authorizedRequest = authorizedRequest,
       _serverDeviceId = serverDeviceId,
       _secureRandom = secureRandom ?? Random.secure();

  final JianheStorageDatabase _storage;
  final SyncRemoteDataSource _api;
  final SyncAuthorizedRequest _authorizedRequest;
  final SyncDeviceIdProvider? _serverDeviceId;
  final Random _secureRandom;

  /// Per-run cache behind [_derivedReverseIndex]; cleared at the start of
  /// every run so rows migrated or merged since the last run show up.
  final Map<SyncEntityType, Map<String, String>> _derivedReverseIndexByType =
      {};
  final Duration retryDelay;
  final int maxSendAttempts;

  /// Recovery re-pushes can easily exceed the server's 30 batches/minute
  /// throttle, so rate-limited batches back off longer than ordinary
  /// retryable failures.
  final Duration rateLimitDelay;
  final int maxRateLimitedAttempts;

  static const _cursorKeyPrefix = 'pull_cursor:';
  static const _lastSyncKeyPrefix = 'last_sync_finished_at:';
  static const _deviceIdKey = 'device_id';
  static const _legacyIdMapKeyPrefix = 'legacy_id_map:';
  static const _legacyIdReverseKeyPrefix = 'legacy_id_reverse:';
  static const _recoveryCursorKeyPrefix = 'recovery_repush_cursor:';
  static const _recoveryMinHeadKeyPrefix = 'recovery_min_head:';
  static const _maxBatchChanges = 100;

  /// Wire-size budget for the envelopes of one batch. Envelopes travel
  /// base64-encoded inside the JSON body (4/3 inflation), so batches are
  /// sized against the encoded form; the margin to the server's 8 MiB body
  /// cap absorbs the JSON wrapper and per-record metadata.
  static const _maxBatchWireBytes = 6 << 20;
  static const _pullPageSize = 200;

  /// A 413 batch that will fail forever (batch / blob size limits), so its
  /// pending rows are dropped instead of retried; local data survives. A
  /// full cloud space (SYNC_QUOTA_EXCEEDED, QUOTA_EXCEEDED) is not in this
  /// set: it clears once the user deletes something, so those edits wait.
  static const _shelveCodes = <String>{
    'SYNC_BLOB_TOO_LARGE',
    'SYNC_BATCH_TOO_LARGE',
  };

  /// Older servers refuse a whole batch with this 413 code when the account
  /// is full; current servers reject the growing records one by one with
  /// [_quotaReason] instead.
  static const _quotaErrorCode = 'SYNC_QUOTA_EXCEEDED';
  static const _quotaReason = 'QUOTA_EXCEEDED';

  /// The server is trimming history to make room for a blob; retry later.
  static const _storageBusyCode = 'SYNC_STORAGE_BUSY';

  /// Held records are offered again after this long even when the quota
  /// numbers did not move, as a cheap safety net.
  static const _quotaHoldLimit = Duration(hours: 1);

  /// Server tolerance is 5 minutes; records newer than the local clock plus
  /// this margin (one minute inside the tolerance) are re-stamped once when
  /// the server rejects them as invalid.
  static const _maxFutureStamp = Duration(minutes: 4);

  /// Invoked after a pull or full-resync apply changed local rows, so the
  /// UI can refresh its lists. Called outside any transaction.
  void Function()? onRemoteChange;

  Future<SyncRunResult>? _activeRun;

  /// Recovery re-push records the server rejected as LOST_LWW, collected
  /// while a full re-push runs (null otherwise).
  List<_BuiltRecord>? _recoveryLostRecords;

  /// Entities the server turned away because the cloud space is full
  /// (entity key → the journal seq that was offered). Their pending rows
  /// stay; push runs skip them until that entity changes again or space
  /// may have been freed (see [_releaseQuotaHolds]).
  final Map<String, int> _quotaHeld = {};
  String? _quotaHeldAccount;
  SyncStateInfo? _quotaHeldAgainst;
  DateTime? _quotaHeldSince;

  /// Account and server state of the current run.
  String? _runAccountId;
  SyncStateInfo? _runState;

  /// Set when the current push run delivered a tombstone, which may have
  /// freed cloud space for held records.
  bool _freedSpaceThisRun = false;

  /// Entities sent in the current push run that were neither cleared nor
  /// held for space (a later attempt in the same run that clears them
  /// removes them again); they stay pending for the next run.
  final Set<String> _unconfirmedThisRun = {};

  bool get running => _activeRun != null;

  int get pendingCount => _storage.sync.pendingCount();

  DateTime? lastSyncFinishedAt(String accountId) {
    final raw = _storage.sync.readState('$_lastSyncKeyPrefix$accountId');
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  Future<SyncRunResult> synchronize({
    required String accountId,
    SyncCancelled? cancelled,
    SyncMode mode = SyncMode.pushAndPull,
  }) {
    if (_activeRun != null) {
      throw SyncEngineException(
        code: 'SYNC_IN_PROGRESS',
        message: AppStrings.current.syncInProgress,
      );
    }
    final run = _run(
      accountId: accountId,
      cancelled: cancelled,
      mode: mode,
    );
    _activeRun = run;
    return run.whenComplete(() => _activeRun = null);
  }

  Future<SyncRunResult> _run({
    required String accountId,
    required SyncCancelled? cancelled,
    required SyncMode mode,
  }) async {
    final warnings = <String>[];
    final deviceId = _resolveDeviceId();
    final cursorKey = '$_cursorKeyPrefix$accountId';
    _derivedReverseIndexByType.clear();

    _checkCancelled(cancelled);
    final state = await _authorizedRequest(
      (token) => _api.state(accessToken: token),
    );
    _runAccountId = accountId;
    _runState = state;
    _releaseQuotaHolds(accountId, state);
    final localCursor = int.tryParse(
      _storage.sync.readState(cursorKey) ?? '',
    );
    // A cursor below the window start means this device fell out of the
    // retention window; a cursor above headSeq means the server rewound
    // (table reset, e.g. plaintext protocol switch): the incremental window
    // is empty while local data survives, so a full re-push is the only way
    // it lands. A null cursor is a first sync for this account on this
    // device and always recovers: the snapshot seeds the cloud state, and —
    // crucially — the full re-push uploads local entities that have no
    // journal rows (the legacy-v0 migration and schema migrations copy rows
    // with bare SQL), which the pending-only push path would never ship.
    // Recovery runs in pullOnly mode too: it is the one-shot seed for a
    // device joining an account, and the durable cursor it writes keeps it
    // from repeating.
    final needsRecovery = localCursor == null ||
        localCursor < state.windowStart ||
        localCursor > state.headSeq;
    if (needsRecovery) {
      return _recoverFull(
        accountId: accountId,
        deviceId: deviceId,
        cursorKey: cursorKey,
        cancelled: cancelled,
        warnings: warnings,
      );
    }

    _checkCancelled(cancelled);
    var pushedCount = 0;
    Object? pushError;
    if (mode == SyncMode.pushAndPull) {
      try {
        pushedCount = await _pushAll(
          deviceId: deviceId,
          cancelled: cancelled,
          warnings: warnings,
        );
      } on Object catch (error) {
        // The push phase failing must not suppress the pull: a persistent
        // push error (invalid device id, VIP lapse, …) would otherwise make
        // every run look like both directions are dead. Remember the error,
        // pull anyway, and rethrow after the pull so the caller still sees
        // the precise push failure.
        pushError = error;
      }
    }
    _checkCancelled(cancelled);
    final pulledCount = await _pullAll(
      deviceId: deviceId,
      cursorKey: cursorKey,
      cancelled: cancelled,
      warnings: warnings,
    );

    if (pushError != null) {
      // Last-sync timestamp stays behind so the card does not present the
      // run as fully healthy while pushes are failing.
      throw pushError;
    }

    _storage.sync.writeState(
      '$_lastSyncKeyPrefix$accountId',
      DateTime.now().toUtc().toIso8601String(),
    );
    return _result(
      pushedCount: pushedCount,
      pulledCount: pulledCount,
      warnings: warnings,
    );
  }

  SyncRunResult _result({
    required int pushedCount,
    required int pulledCount,
    required List<String> warnings,
  }) {
    final held = _quotaHeld.length;
    String? quotaNotice;
    if (held > 0) {
      final state = _runState ?? _quotaHeldAgainst;
      final usage = state == null
          ? ''
          : AppStrings.current.syncQuotaUsage(
              _megabytes(state.quotaUsedBytes),
              _megabytes(state.quotaMaxBytes),
            );
      quotaNotice = AppStrings.current.syncQuotaFull(usage, held);
      warnings.insert(0, quotaNotice);
    }
    return SyncRunResult(
      pushedCount: pushedCount,
      pulledCount: pulledCount,
      warnings: List.unmodifiable(warnings),
      finishedAt: DateTime.now(),
      quotaBlockedCount: held,
      quotaNotice: quotaNotice,
    );
  }

  static String _megabytes(int bytes) {
    final value = bytes / (1 << 20);
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} MB';
  }

  /// Held records get another chance when space may have been freed: the
  /// server reports less used (or a larger limit) than when they were held,
  /// or the hold is older than [_quotaHoldLimit]. Holds never carry over to
  /// another account.
  void _releaseQuotaHolds(String accountId, SyncStateInfo state) {
    if (_quotaHeld.isEmpty) return;
    final against = _quotaHeldAgainst;
    final since = _quotaHeldSince;
    final release = _quotaHeldAccount != accountId ||
        against == null ||
        since == null ||
        state.quotaUsedBytes < against.quotaUsedBytes ||
        state.quotaMaxBytes > against.quotaMaxBytes ||
        DateTime.now().difference(since) >= _quotaHoldLimit;
    if (release) _clearQuotaHolds();
  }

  void _clearQuotaHolds() {
    _quotaHeld.clear();
    _quotaHeldAccount = null;
    _quotaHeldAgainst = null;
    _quotaHeldSince = null;
  }

  bool _isQuotaHeld(_CoalescedChange entry) =>
      _quotaHeld[_entityKey(entry.entityType, entry.entityId)] ==
      entry.maxSeq;

  /// [entry] did not fit into the cloud space. Its local data is untouched
  /// and it must stay queued: a normal push keeps its pending rows (held
  /// until space frees up); a full-resync re-push entry has no pending row
  /// yet, so one is journaled for the normal push path to pick up.
  void _holdForQuota(_CoalescedChange entry) {
    if (entry.maxSeq == 0) {
      _keepQueued(entry);
      return;
    }
    if (_quotaHeld.isEmpty) {
      _quotaHeldAccount = _runAccountId;
      _quotaHeldAgainst = _runState;
      _quotaHeldSince = DateTime.now();
    }
    _quotaHeld[_entityKey(entry.entityType, entry.entityId)] = entry.maxSeq;
  }

  /// Makes sure [entry] is retried by a later push run. Normal entries
  /// already are (their pending rows stay); a full-resync re-push entry
  /// (maxSeq 0) gets a journal row of its own.
  void _keepQueued(_CoalescedChange entry) {
    if (entry.maxSeq != 0) return;
    _storage.journal.record(
      entry.entityType,
      entry.entityId,
      entry.op,
      changedAt: entry.changedAt,
    );
  }

  /// Full resync (protocol §6.6): the local cursor fell out of the server
  /// retention window, the server rewound its tables (head_seq reset — e.g.
  /// the plaintext protocol switch), or this is the device's first sync for
  /// the account (no stored cursor). The snapshot seeds the cloud state, and
  /// the full re-push uploads local entities that have no journal rows (the
  /// legacy-v0 and schema migrations copy rows with bare SQL), which the
  /// pending-only push path would never ship — so recovery also runs for
  /// pull-only startup runs on a first sync. Pull the server's live winning
  /// entities page by page, merge apply-if-newer, re-push every surviving
  /// local entity, then resume incremental pulls from the smallest head_seq
  /// any snapshot page reported — concurrent pushes during paging re-arrive
  /// as increments.
  Future<SyncRunResult> _recoverFull({
    required String accountId,
    required String deviceId,
    required String cursorKey,
    required SyncCancelled? cancelled,
    required List<String> warnings,
  }) async {
    final maxPendingSeqAtStart = _storage.sync.maxPendingSeq();
    // Resume support: the re-push phase can outlive the Windows scheduled
    // task's 10-minute kill (30 batches/minute rate limit, large accounts).
    // A durable cursor lets the next run skip the (already applied) snapshot
    // and continue the re-push where it stopped instead of restarting into
    // the same wall. Absent cursor = fresh recovery.
    final recoveryCursorKey = '$_recoveryCursorKeyPrefix$accountId';
    final recoveryMinHeadKey = '$_recoveryMinHeadKeyPrefix$accountId';
    final resumeCursor = _decodeRecoveryCursor(
      _storage.sync.readState(recoveryCursorKey),
    );
    var minHead = int.tryParse(
          _storage.sync.readState(recoveryMinHeadKey) ?? '',
        ) ??
        -1;
    var appliedCount = 0;
    // Category keys the snapshot reported live. Snapshots never include
    // tombstones, so a category missing here that then loses its re-push
    // was deleted elsewhere (see _retireCategoriesDeletedElsewhere).
    final snapshotLiveCategories = <String>{};
    final snapshotRan = resumeCursor == null;
    if (resumeCursor == null) {
      String? afterType;
      var afterId = '';
      while (true) {
        _checkCancelled(cancelled);
        final page = await _authorizedRequest(
          (token) => _api.snapshot(
            accessToken: token,
            afterType: afterType,
            afterId: afterType == null ? null : afterId,
            limit: _pullPageSize,
          ),
        );
        minHead = minHead < 0 ? page.headSeq : min(minHead, page.headSeq);
        for (final change in page.changes) {
          if (_isCategory(change.entityType)) {
            snapshotLiveCategories.add(
              _entityKey(change.entityType, change.entityId),
            );
          }
        }
        if (page.changes.isNotEmpty) {
          final resolved = <_ResolvedPull>[];
          for (final change in page.changes) {
            if (change.originDeviceId == deviceId) continue;
            final entry = _ResolvedPull(
              change,
              localEntityId: _localEntityId(
                change.entityType,
                change.entityId,
              ),
            );
            if (await _resolveOrSkip(entry, warnings)) resolved.add(entry);
          }
          appliedCount += await _storage.writeTransaction(() async {
            var applied = 0;
            final budget = _YieldBudget();
            for (final entry in resolved) {
              if (_applyResolved(entry, warnings: warnings)) applied++;
              await budget.spend(bytes: _pullPayloadBytes(entry));
            }
            return applied;
          }, recordChanges: false);
        }
        if (page.nextEntityType == null) break;
        afterType = page.nextEntityType;
        afterId = page.nextEntityId ?? '';
      }
      if (appliedCount > 0) _notifyRemoteChange();
      // Snapshot complete: persist the resume point before any pushing so
      // a kill during the re-push resumes instead of re-snapshotting.
      _storage.sync.writeState(recoveryMinHeadKey, '$minHead');
      _storage.sync.writeState(recoveryCursorKey, '${_encodePhase(0)}|');
    }

    // Re-push every surviving local entity as its own put. Acknowledgements
    // are verified as usual, but pending rows clear at the end, in one
    // transaction, only for entities this re-push actually delivered.
    _checkCancelled(cancelled);
    final blobCache = <String, _BlobCacheEntry>{};
    final deliveredKeys =
        <({SyncEntityType entityType, String entityId})>[];
    final records = <_BuiltRecord>[];
    final buildBudget = _YieldBudget();
    for (final entry in _survivingEntities()) {
      if (!_afterRecoveryCursor(entry, resumeCursor)) continue;
      final built = await _buildRecord(
        entry,
        blobCache: blobCache,
        warnings: warnings,
      );
      if (built != null) records.add(built);
      await buildBudget.spend(
        bytes:
            built?.record.envelope?.length ?? built?.record.byteLength ?? 0,
      );
    }
    var pushedCount = 0;
    final lostRecords = <_BuiltRecord>[];
    _recoveryLostRecords = lostRecords;
    try {
      for (final batch in _splitBatches(records)) {
        _checkCancelled(cancelled);
        pushedCount += await _pushBatchDiagnosed(
          batch,
          deviceId: deviceId,
          blobCache: blobCache,
          warnings: warnings,
          clearPending: false,
          deliveredKeys: deliveredKeys,
        );
        // Advance the durable resume cursor past everything this batch
        // covered (delivered, shelved, or rejected alike — none of them
        // should be retried by a resumed run).
        final last = batch.last.entry;
        _storage.sync.writeState(
          recoveryCursorKey,
          '${_encodePhase(_recoveryPhase(last))}|${last.entityId}',
        );
      }
    } finally {
      _recoveryLostRecords = null;
    }
    await _storage.writeTransaction<void>(() async {
      _storage.sync.deletePendingChangesForEntities(
        deliveredKeys,
        upToSeq: maxPendingSeqAtStart,
      );
    });
    if (snapshotRan) {
      appliedCount += await _retireCategoriesDeletedElsewhere(
        lostRecords,
        snapshotLiveCategories,
      );
    }

    // Tombstones and edits journaled mid-recovery go out the normal path.
    _checkCancelled(cancelled);
    pushedCount += await _pushAll(
      deviceId: deviceId,
      cancelled: cancelled,
      warnings: warnings,
    );

    if (minHead >= 0) {
      _storage.sync.writeState(cursorKey, '$minHead');
      try {
        await _authorizedRequest(
          (token) => _api.reportCursor(accessToken: token, cursor: minHead),
        );
      } on Object {
        // ignore — best-effort heartbeat; the local cursor is durable.
      }
    }
    _storage.sync.writeState(
      '$_lastSyncKeyPrefix$accountId',
      DateTime.now().toUtc().toIso8601String(),
    );
    // Recovery finished cleanly: the resume checkpoint is obsolete.
    _storage.sync.deleteState(recoveryCursorKey);
    _storage.sync.deleteState(recoveryMinHeadKey);
    return _result(
      pushedCount: pushedCount,
      pulledCount: appliedCount,
      warnings: warnings,
    );
  }

  /// Re-push order phase for the resume cursor, mirroring the deterministic
  /// order of [_survivingEntities]: items (one id space, `ORDER BY id`),
  /// then categories (`ORDER BY type, name` — prompt < skill < snippet, each
  /// type its own phase because names repeat across types), then packages.
  /// A single shared category phase would compare a skill category's name
  /// against a prompt category's cursor and skip it on resume.
  int _recoveryPhase(_CoalescedChange entry) => switch (entry.entityType) {
    SyncEntityType.itemPrompt ||
    SyncEntityType.itemSkill ||
    SyncEntityType.itemSnippet => 0,
    SyncEntityType.categoryPrompt => 1,
    SyncEntityType.categorySkill => 2,
    SyncEntityType.categorySnippet => 3,
    SyncEntityType.skillPackage => 4,
  };

  String _encodePhase(int phase) => phase.toString();

  /// `'phase|entityId'`; null when the value is absent or malformed.
  (int, String)? _decodeRecoveryCursor(String? raw) {
    if (raw == null) return null;
    final separator = raw.indexOf('|');
    if (separator <= 0) return null;
    final phase = int.tryParse(raw.substring(0, separator));
    if (phase == null) return null;
    return (phase, raw.substring(separator + 1));
  }

  /// True when [entry] sorts strictly after the resume cursor, i.e. the
  /// re-push has not covered it yet.
  bool _afterRecoveryCursor(_CoalescedChange entry, (int, String)? cursor) {
    if (cursor == null) return true;
    final phase = _recoveryPhase(entry);
    if (phase != cursor.$1) return phase > cursor.$1;
    return entry.entityId.compareTo(cursor.$2) > 0;
  }

  /// Every surviving local entity as a synthetic put for the re-push.
  /// Items and skill packages timestamp from their rows; categories carry
  /// no updated_at and take the recovery time — by now the snapshot apply
  /// has merged the server's winners, so local rows ARE the state to ship.
  List<_CoalescedChange> _survivingEntities() {
    final now = DateTime.now();
    final entries = <_CoalescedChange>[];
    for (final id in _storage.sync.readAllItemIds()) {
      final item = _storage.sync.readItem(id);
      if (item == null) continue;
      entries.add(
        _CoalescedChange._(
          switch (item.type) {
            ItemType.prompt => SyncEntityType.itemPrompt,
            ItemType.skill => SyncEntityType.itemSkill,
            ItemType.snippet => SyncEntityType.itemSnippet,
          },
          id,
          0,
          SyncChangeOp.put,
          item.updatedAt,
        ),
      );
    }
    for (final (type, name) in _storage.sync.readAllCategoryKeys()) {
      final entityType = SyncEntityType.forCategory(type);
      entries.add(
        _CoalescedChange._(
          entityType,
          name,
          0,
          SyncChangeOp.put,
          _categoryRecoveryStamp(entityType, type, name),
        ),
      );
    }
    for (final skillId in _storage.sync.readAllSkillIds()) {
      entries.add(
        _CoalescedChange._(
          SyncEntityType.skillPackage,
          skillId,
          0,
          SyncChangeOp.put,
          now,
        ),
      );
    }
    return entries;
  }

  bool _isCategory(SyncEntityType type) =>
      type == SyncEntityType.categoryPrompt ||
      type == SyncEntityType.categorySkill ||
      type == SyncEntityType.categorySnippet;

  /// Last-write-wins stamp for re-pushing a category during recovery.
  /// Categories carry no updated_at. Stamping them "now" made every re-push
  /// newer than any tombstone, so a device holding a stale copy resurrected
  /// categories other devices had deleted. Use the newest real local
  /// change instead: an unpushed edit's journal time, else the creation
  /// time. A category the user re-created after a remote delete still wins.
  DateTime _categoryRecoveryStamp(
    SyncEntityType entityType,
    ItemType type,
    String name,
  ) {
    final pendingAt = _storage.sync.latestPendingChangedAt(entityType, name);
    if (pendingAt != null) return pendingAt;
    final createdAt = DateTime.tryParse(
      _storage.sync.readCategory(type, name)?.createdAt ?? '',
    );
    return createdAt ?? DateTime.utc(1970);
  }

  /// A recovery re-push that loses LWW for a category the snapshot did not
  /// report live means the server holds a newer tombstone: another device
  /// deleted it. Drop the stale local copy so this device converges instead
  /// of keeping a category nobody else has. Skipped when the user changed
  /// the category after the stamp that lost (that edit pushes normally),
  /// and never run on a resumed recovery, which has no snapshot to consult.
  /// If the server state was in fact a newer put that landed after the
  /// snapshot, the incremental pull from the snapshot's head re-creates it.
  Future<int> _retireCategoriesDeletedElsewhere(
    List<_BuiltRecord> lostRecords,
    Set<String> snapshotLiveCategories,
  ) async {
    final stale = <_BuiltRecord>[
      for (final built in lostRecords)
        if (_isCategory(built.entry.entityType) &&
            !snapshotLiveCategories.contains(
              _entityKey(built.entry.entityType, built.entry.entityId),
            ))
          built,
    ];
    if (stale.isEmpty) return 0;
    final removed = await _storage.writeTransaction(() async {
      var count = 0;
      for (final built in stale) {
        final type = built.entry.entityType;
        final name = built.entry.entityId;
        final pendingAt = _storage.sync.latestPendingChangedAt(type, name);
        if (pendingAt != null && pendingAt.isAfter(built.record.updatedAt)) {
          continue;
        }
        if (!_storage.sync.categoryExists(type.itemType, name)) continue;
        _storage.sync.deleteRemoteCategory(type.itemType, name);
        count++;
      }
      return count;
    }, recordChanges: false);
    if (removed > 0) _notifyRemoteChange();
    return removed;
  }

  String _resolveDeviceId() {
    // The server-issued device id (auth session) is authoritative: pushes
    // are validated against the access token's device claim. The locally
    // generated id only survives as a fallback for legacy state and tests;
    // re-login replaces it because a login always issues a new device row.
    final serverId = _serverDeviceId?.call();
    if (serverId != null && serverId.isNotEmpty) return serverId;
    final existing = _storage.sync.readState(_deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final deviceId = _newUUID();
    _storage.sync.writeState(_deviceIdKey, deviceId);
    return deviceId;
  }

  /// Maps a local entity id to the wire id sent to the server. The server
  /// requires UUID-format ids for item:* / skill_package entities, but the
  /// legacy-v0 migration preserved original row ids like "id-1". Those map
  /// deterministically to a UUID derived from sha256(namespace + id), stored
  /// in sync_state so pulls and acks translate back to the local id.
  String _wireEntityId(SyncEntityType type, String localId) {
    if (type == SyncEntityType.categoryPrompt ||
        type == SyncEntityType.categorySkill ||
        type == SyncEntityType.categorySnippet) {
      return localId;
    }
    if (_uuidPattern.hasMatch(localId)) return localId;
    final stateKey = _forwardMapKey(type, localId);
    final mapped = _storage.sync.readState(stateKey);
    if (mapped != null && mapped.isNotEmpty) return mapped;
    final digest = sha256
        .convert(utf8.encode('jianhe-legacy-entity/${type.storageValue}/$localId'))
        .toString();
    final wireId =
        '${digest.substring(0, 8)}-'
        '${digest.substring(8, 12)}-'
        '3${digest.substring(13, 16)}-'
        '${digest.substring(16, 20)}-'
        '${digest.substring(20, 32)}';
    _storage.sync.writeState(stateKey, wireId);
    return wireId;
  }

  /// Reverse lookup: wire id back to the local row id, following the
  /// mapping table in both directions. Unknown wire ids (new remote rows)
  /// pass through unchanged.
  String _localEntityId(SyncEntityType type, String wireId) {
    if (type == SyncEntityType.categoryPrompt ||
        type == SyncEntityType.categorySkill ||
        type == SyncEntityType.categorySnippet) {
      return wireId;
    }
    if (_uuidPattern.hasMatch(wireId)) {
      // A mapped id could round-trip; check the table first.
      final existing = _storage.sync.readState(_reverseMapKey(type, wireId));
      if (existing != null && existing.isNotEmpty) return existing;
      // Legacy rows this device migrated itself but never pushed or pulled
      // have no recorded mapping; their wire ids derive deterministically,
      // so a lazily built index closes that gap (tombstones, packages).
      final derived = _derivedReverseIndex(type)[wireId];
      if (derived != null) return derived;
      return wireId;
    }
    return wireId;
  }

  /// Wire-id index over the local legacy rows for one entity type, built at
  /// most once per sync run. UUID rows are skipped: their wire id is the row
  /// id, so there is nothing to reverse. Deriving here also seeds the
  /// forward map, exactly as a push of the same row would.
  Map<String, String> _derivedReverseIndex(SyncEntityType type) {
    final cached = _derivedReverseIndexByType[type];
    if (cached != null) return cached;
    final index = <String, String>{};
    if (type != SyncEntityType.categoryPrompt &&
        type != SyncEntityType.categorySkill &&
        type != SyncEntityType.categorySnippet) {
      for (final localId in _storage.sync.readAllItemIds()) {
        if (_uuidPattern.hasMatch(localId)) continue;
        index[_wireEntityId(type, localId)] = localId;
      }
    }
    return _derivedReverseIndexByType[type] = index;
  }

  String _forwardMapKey(SyncEntityType type, String localId) =>
      '$_legacyIdMapKeyPrefix${type.storageValue}:$localId';

  String _reverseMapKey(SyncEntityType type, String wireId) =>
      '$_legacyIdReverseKeyPrefix${type.storageValue}:$wireId';

  /// Writes both directions of the mapping after computing a forward entry,
  /// so pulls and ack verification can translate back.
  void _ensureReverseMapping(SyncEntityType type, String localId) {
    if (type == SyncEntityType.categoryPrompt ||
        type == SyncEntityType.categorySkill ||
        type == SyncEntityType.categorySnippet) {
      return;
    }
    if (_uuidPattern.hasMatch(localId)) return;
    final wireId = _wireEntityId(type, localId);
    _storage.sync.writeState(_reverseMapKey(type, wireId), localId);
  }

  // ------------------------------------------------------------------
  // Push
  // ------------------------------------------------------------------

  Future<int> _pushAll({
    required String deviceId,
    required SyncCancelled? cancelled,
    required List<String> warnings,
  }) async {
    final blobCache = <String, _BlobCacheEntry>{};
    // Each pending entity version (entity + newest seq) is offered at most
    // once per run. Rows that stay pending — held for cloud space, waiting
    // on a busy server, or unconfirmed — are paged past, so they can never
    // hide the rows behind them (such as the deletes that would free space).
    final attempted = <String, int>{};
    var delivered = 0;
    var afterSeq = 0;
    var retriedHeld = false;
    _freedSpaceThisRun = false;
    _unconfirmedThisRun.clear();
    while (true) {
      _checkCancelled(cancelled);
      final page = _storage.sync.readPendingChanges(
        limit: _maxBatchChanges,
        afterSeq: afterSeq,
      );
      if (page.isEmpty) {
        // Deletes delivered in this run may have made room: give the held
        // records one more chance before finishing.
        if (_freedSpaceThisRun && !retriedHeld && _quotaHeld.isNotEmpty) {
          retriedHeld = true;
          for (final key in _quotaHeld.keys) {
            attempted.remove(key);
          }
          _clearQuotaHolds();
          afterSeq = 0;
          continue;
        }
        break;
      }
      final coalesced = <_CoalescedChange>[
        for (final entry in _coalescePending(page))
          if (attempted[_entityKey(entry.entityType, entry.entityId)] !=
                  entry.maxSeq &&
              !_isQuotaHeld(entry))
            entry,
      ];
      if (coalesced.isEmpty) {
        afterSeq = page.last.seq;
        continue;
      }

      // Drop journal rows whose local entity already vanished; the newest
      // row per entity would have coalesced a real delete over the put.
      final pushable = <_CoalescedChange>[];
      for (final entry in coalesced) {
        final key = _entityKey(entry.entityType, entry.entityId);
        attempted[key] = entry.maxSeq;
        if (entry.op == SyncChangeOp.put && !_entityExists(entry)) {
          _storage.sync.deletePendingChanges(
            entry.entityType,
            entry.entityId,
            upToSeq: entry.maxSeq,
          );
          _quotaHeld.remove(key);
          continue;
        }
        pushable.add(entry);
      }

      // Metadata records; skill package puts upload their blob first and
      // keep the bytes cached until the push is acknowledged.
      final records = <_BuiltRecord>[];
      for (final entry in pushable) {
        final built = await _buildRecord(
          entry,
          blobCache: blobCache,
          warnings: warnings,
        );
        if (built != null) records.add(built);
      }

      for (final batch in _splitBatches(records)) {
        _checkCancelled(cancelled);
        delivered += await _pushBatchDiagnosed(
          batch,
          deviceId: deviceId,
          blobCache: blobCache,
          warnings: warnings,
        );
      }
    }
    if (_unconfirmedThisRun.isNotEmpty) {
      warnings.add(AppStrings.current.syncUnconfirmed);
    }
    return delivered;
  }

  List<_CoalescedChange> _coalescePending(List<PendingChangeRow> rows) {
    final byEntity = <String, _CoalescedChange>{};
    for (final row in rows) {
      final key = _entityKey(row.entityType, row.entityId);
      final existing = byEntity[key];
      if (existing == null || row.seq > existing.maxSeq) {
        byEntity[key] = _CoalescedChange._(
          row.entityType,
          row.entityId,
          row.seq,
          row.op,
          row.changedAt,
        );
      }
    }
    final entries = byEntity.values.toList()
      ..sort((a, b) => a.maxSeq.compareTo(b.maxSeq));
    return entries;
  }

  bool _entityExists(_CoalescedChange entry) {
    final type = entry.entityType;
    switch (type) {
      case SyncEntityType.itemPrompt:
      case SyncEntityType.itemSkill:
      case SyncEntityType.itemSnippet:
        return _storage.sync.itemExists(entry.entityId);
      case SyncEntityType.categoryPrompt:
      case SyncEntityType.categorySkill:
      case SyncEntityType.categorySnippet:
        return _storage.sync.categoryExists(type.itemType, entry.entityId);
      case SyncEntityType.skillPackage:
        return _storage.sync.skillPackageExists(entry.entityId);
    }
  }

  Future<_BuiltRecord?> _buildRecord(
    _CoalescedChange entry, {
    required Map<String, _BlobCacheEntry> blobCache,
    required List<String> warnings,
  }) async {
    final type = entry.entityType;
    if (entry.op == SyncChangeOp.delete) {
      _ensureReverseMapping(type, entry.entityId);
      return _BuiltRecord(
        entry: entry,
        record: SyncPushChange(
          entityType: type,
          entityId: _wireEntityId(type, entry.entityId),
          updatedAt: entry.changedAt,
          deleted: true,
        ),
      );
    }
    switch (type) {
      case SyncEntityType.itemPrompt:
      case SyncEntityType.itemSkill:
      case SyncEntityType.itemSnippet:
        final item = _storage.sync.readItem(entry.entityId);
        if (item == null) return null;
        _ensureReverseMapping(type, entry.entityId);
        return _BuiltRecord(
          entry: entry,
          record: SyncPushChange(
            entityType: type,
            entityId: _wireEntityId(type, entry.entityId),
            updatedAt: item.updatedAt,
            envelope: _encodeEnvelope(_itemEnvelope(item)),
          ),
          ackItemUpdatedAt: item.updatedAt,
        );
      case SyncEntityType.categoryPrompt:
      case SyncEntityType.categorySkill:
      case SyncEntityType.categorySnippet:
        final category = _storage.sync.readCategory(
          type.itemType,
          entry.entityId,
        );
        if (category == null) return null;
        return _BuiltRecord(
          entry: entry,
          record: SyncPushChange(
            entityType: type,
            entityId: entry.entityId,
            updatedAt: entry.changedAt,
            envelope: _encodeEnvelope(_categoryEnvelope(category)),
          ),
        );
      case SyncEntityType.skillPackage:
        final item = _storage.sync.readItem(entry.entityId);
        final package = _storage.sync.readSkillPackage(entry.entityId);
        if (item == null || package == null) return null;
        final packageHash = package.packageHash(item.content);
        final _BlobCacheEntry blob;
        try {
          blob = await _ensureSkillBlob(
            skillId: entry.entityId,
            item: item,
            package: package,
            packageHash: packageHash,
            blobCache: blobCache,
          );
        } on AccountApiException catch (error) {
          if (error.code == _quotaErrorCode) {
            // The cloud space is full: keep the package queued until space
            // frees up instead of dropping it.
            _holdForQuota(entry);
            return null;
          }
          if (error.code == _storageBusyCode) {
            // The server is trimming history to make room; try next run.
            _keepQueued(entry);
            _addOnce(warnings, AppStrings.current.syncStorageBusy);
            return null;
          }
          if (error.code == 'INVALID_REQUEST') {
            // The server refused this one upload (e.g. a client/server
            // protocol mismatch). Failing here would abort the whole run
            // before anything is pushed, so keep only this package queued
            // for the next run and let everything else sync.
            _keepQueued(entry);
            _addOnce(
              warnings,
              AppStrings.current.syncSkillRejected(
                item.title,
                error.message.isNotEmpty
                    ? error.message
                    : AppStrings.current.syncRequestInvalid,
              ),
            );
            return null;
          }
          if (!_shelveCodes.contains(error.code)) rethrow;
          // A blob over the server's size cap can never upload. Drop the
          // journal rows so the next run cannot livelock on it; local data
          // survives and the warning names the package.
          _storage.sync.deletePendingChanges(
            entry.entityType,
            entry.entityId,
            upToSeq: entry.maxSeq,
          );
          warnings.add(
            error.code == 'SYNC_BLOB_TOO_LARGE'
                ? AppStrings.current.syncSkillTooLarge(
                    item.title,
                    SkillPackage.maximumSyncBlobBytes >> 20,
                  )
                : AppStrings.current.syncSkillShelved(
                    item.title,
                    error.message.isNotEmpty
                        ? error.message
                        : AppStrings.current.syncServerLimit,
                  ),
          );
          return null;
        }
        _ensureReverseMapping(type, entry.entityId);
        return _BuiltRecord(
          entry: entry,
          record: SyncPushChange(
            entityType: type,
            entityId: _wireEntityId(type, entry.entityId),
            updatedAt: item.updatedAt,
            packageHash: packageHash,
            blobSha256: blob.sha256,
            byteLength: blob.bytes.length,
            fileCount: package.fileCount,
          ),
          ackItemUpdatedAt: item.updatedAt,
        );
    }
  }

  static void _addOnce(List<String> warnings, String warning) {
    if (!warnings.contains(warning)) warnings.add(warning);
  }

  Future<_BlobCacheEntry> _ensureSkillBlob({
    required String skillId,
    required JianheItem item,
    required SkillPackage package,
    required String packageHash,
    required Map<String, _BlobCacheEntry> blobCache,
  }) async {
    final cached = blobCache[skillId];
    if (cached != null && cached.packageHash == packageHash) return cached;

    final encoded = await _runPossiblyOffThread(
      _encodeSkillBlob,
      (
        entrypoint: package.entrypoint,
        sourceFormat: package.sourceFormat.storageValue,
        manifest: item.content,
        importedAt: package.importedAt.toUtc().toIso8601String(),
        files: package.files,
      ),
      payloadBytes: package.files.fold<int>(
        item.content.length,
        (total, file) => total + file.byteLength,
      ),
    );
    final plaintext = encoded.bytes;
    final entry = _BlobCacheEntry(
      packageHash: packageHash,
      bytes: plaintext,
      sha256: encoded.sha256,
    );
    blobCache[skillId] = entry;

    final exists = await _authorizedRequest(
      (token) => _api.headBlob(accessToken: token, sha256: entry.sha256),
    );
    if (!exists) {
      await _authorizedRequest(
        (token) => _api.putBlob(
          accessToken: token,
          sha256: entry.sha256,
          container: plaintext,
        ),
      );
    }
    return entry;
  }

  List<List<_BuiltRecord>> _splitBatches(List<_BuiltRecord> records) {
    final batches = <List<_BuiltRecord>>[];
    var current = <_BuiltRecord>[];
    var currentBytes = 0;
    for (final built in records) {
      final envelopeBytes = _base64WireBytes(built.record.envelope?.length ?? 0);
      if (current.isNotEmpty &&
          (current.length >= _maxBatchChanges ||
              currentBytes + envelopeBytes > _maxBatchWireBytes)) {
        batches.add(current);
        current = <_BuiltRecord>[];
        currentBytes = 0;
      }
      current.add(built);
      currentBytes += envelopeBytes;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  /// Size an envelope occupies inside the JSON body once base64-encoded.
  int _base64WireBytes(int rawBytes) => 4 * ((rawBytes + 2) ~/ 3);

  Future<int> _pushBatch(
    List<_BuiltRecord> batch, {
    required String deviceId,
    required Map<String, _BlobCacheEntry> blobCache,
    required List<String> warnings,
    bool clearPending = true,
    List<({SyncEntityType entityType, String entityId})>? deliveredKeys,
  }) async {
    final idempotencyKey = _newUUID();
    SyncPushResponse response;
    var attempt = 0;
    var rateLimitedAttempts = 0;
    while (true) {
      try {
        response = await _authorizedRequest(
          (token) => _api.push(
            accessToken: token,
            idempotencyKey: idempotencyKey,
            deviceId: deviceId,
            changes: <SyncPushChange>[
              for (final built in batch) built.record,
            ],
          ),
        );
        break;
      } on AccountApiException catch (error) {
        if (error.code == 'RATE_LIMITED') {
          rateLimitedAttempts++;
          if (rateLimitedAttempts >= maxRateLimitedAttempts) rethrow;
          await Future<void>.delayed(rateLimitDelay);
          continue;
        }
        final retryable =
            error.retryable || error.code == 'SYNC_PUSH_IN_PROGRESS';
        if (!retryable) {
          if (error.code == _quotaErrorCode) {
            // Older servers refuse the whole batch when the account is
            // full. Keep every record queued until space frees up.
            await _storage.writeTransaction<void>(() async {
              for (final built in batch) {
                _holdForQuota(built.entry);
              }
            });
            return 0;
          }
          if (_shelveCodes.contains(error.code)) {
            return _shelveBatch(
              batch,
              warnings: warnings,
              reason: error.message,
              clearPending: clearPending,
            );
          }
          rethrow;
        }
        attempt++;
        if (attempt >= maxSendAttempts) rethrow;
        await Future<void>.delayed(retryDelay);
      }
    }

    final results = <String, SyncPushResult>{
      for (final result in response.results)
        _entityKey(
          result.entityType,
          // The server echoes wire ids; translate legacy-mapped ones back so
          // the lookup below (keyed by local ids) matches.
          _localEntityId(result.entityType, result.entityId),
        ): result,
    };
    var delivered = 0;
    await _storage.writeTransaction(() async {
      for (final built in batch) {
        final key = _entityKey(
          built.entry.entityType,
          built.entry.entityId,
        );
        final result = results[key];
        if (result == null) {
          warnings.add(AppStrings.current.syncNoPushResult(built.entry.entityId));
          continue;
        }
        if (!result.accepted && result.reason == _quotaReason) {
          // This record would grow the account past its quota; the rest of
          // the batch was applied. Keep it queued until space frees up.
          _holdForQuota(built.entry);
          continue;
        }
        final shouldClear =
            result.reason == 'LOST_LWW' ||
            (result.accepted && _verifyAck(built));
        if (!shouldClear) {
          _unconfirmedThisRun.add(key);
          continue;
        }
        _quotaHeld.remove(key);
        _unconfirmedThisRun.remove(key);
        if (result.accepted && built.record.deleted) _freedSpaceThisRun = true;
        if (result.reason == 'LOST_LWW') _recoveryLostRecords?.add(built);
        if (clearPending) {
          _storage.sync.deletePendingChanges(
            built.entry.entityType,
            built.entry.entityId,
            upToSeq: built.entry.maxSeq,
          );
        } else {
          deliveredKeys?.add((
            entityType: built.entry.entityType,
            entityId: built.entry.entityId,
          ));
        }
        if (built.entry.entityType == SyncEntityType.skillPackage) {
          blobCache.remove(built.entry.entityId);
        }
        delivered++;
      }
    });
    return delivered;
  }

  /// Ack gate: pending rows may only clear when the local entity still
  /// holds the exact state that was pushed, or when the server reports the
  /// push lost last-write-wins arbitration.
  bool _verifyAck(_BuiltRecord built) {
    final entry = built.entry;
    final type = entry.entityType;
    final deleted = built.record.deleted;
    switch (type) {
      case SyncEntityType.itemPrompt:
      case SyncEntityType.itemSkill:
      case SyncEntityType.itemSnippet:
        if (deleted) {
          // A tombstone for `item:<type>/X` is delivered once no local row
          // holds X under that type. After a type change the row survives
          // under the new type, so existence alone would never verify and
          // the pending row would be retried forever.
          final currentType = _storage.sync.readItemType(entry.entityId);
          return currentType == null ||
              SyncEntityType.forItem(currentType) != type;
        }
        return _storage.sync.readItemUpdatedAt(entry.entityId) ==
            built.ackItemUpdatedAt?.toUtc().toIso8601String();
      case SyncEntityType.categoryPrompt:
      case SyncEntityType.categorySkill:
      case SyncEntityType.categorySnippet:
        final exists = _storage.sync.categoryExists(
          type.itemType,
          entry.entityId,
        );
        return deleted ? !exists : exists;
      case SyncEntityType.skillPackage:
        if (deleted) return !_storage.sync.skillPackageExists(entry.entityId);
        return _storage.sync.readPackageHash(entry.entityId) ==
            built.record.packageHash &&
            _storage.sync.readItemUpdatedAt(entry.entityId) ==
                built.ackItemUpdatedAt?.toUtc().toIso8601String();
    }
  }

  /// Shelve a permanently-failing batch (plan rule 3): drop the pending rows
  /// so the push loop cannot livelock; local data is untouched. Recovery
  /// re-pushes (clearPending: false) have no pending rows to drop.
  int _shelveBatch(
    List<_BuiltRecord> batch, {
    required List<String> warnings,
    required String reason,
    bool clearPending = true,
  }) {
    if (clearPending) {
      for (final built in batch) {
        _storage.sync.deletePendingChanges(
          built.entry.entityType,
          built.entry.entityId,
          upToSeq: built.entry.maxSeq,
        );
      }
    }
    warnings.add(
      AppStrings.current.syncBatchShelved(
        reason.isNotEmpty ? reason : AppStrings.current.syncServerLimit,
      ),
    );
    // Shelved records did not sync; counting them as delivered would show
    // "已同步 N 条" over records that never left the device.
    return 0;
  }

  /// Pushes [batch]; when the server rejects the whole batch with
  /// INVALID_REQUEST it isolates the cause instead of failing the sync:
  /// the batch is bisected until each record lands individually. Records
  /// stamped in the future (created while the local clock ran fast — the
  /// server rejects anything newer than its clock + 5 minutes) are
  /// re-stamped to now and retried once; genuinely rejected records are
  /// skipped with a warning naming them. Only when every record in the
  /// batch is rejected does the sync fail, with the likely cause spelled
  /// out — that pattern means an environmental problem (clock skew,
  /// device or protocol mismatch), not one bad record.
  Future<int> _pushBatchDiagnosed(
    List<_BuiltRecord> batch, {
    required String deviceId,
    required Map<String, _BlobCacheEntry> blobCache,
    required List<String> warnings,
    bool clearPending = true,
    List<({SyncEntityType entityType, String entityId})>? deliveredKeys,
  }) async {
    Future<int> send(List<_BuiltRecord> records) => _pushBatch(
          records,
          deviceId: deviceId,
          blobCache: blobCache,
          warnings: warnings,
          clearPending: clearPending,
          deliveredKeys: deliveredKeys,
        );
    try {
      return await send(batch);
    } on AccountApiException catch (error) {
      if (error.code != 'INVALID_REQUEST') rethrow;
    }
    final rejected = <_BuiltRecord>[];
    final delivered = await _isolateInvalid(
      batch,
      rejected: rejected,
      deviceId: deviceId,
      blobCache: blobCache,
      warnings: warnings,
      clearPending: clearPending,
      deliveredKeys: deliveredKeys,
    );
    if (delivered == 0 && rejected.length == batch.length && batch.length > 1) {
      throw AccountApiException(
        code: 'INVALID_REQUEST',
        message: AppStrings.current.syncAllRejected,
      );
    }
    for (final built in rejected) {
      _skipRecord(built, warnings: warnings, clearPending: clearPending);
    }
    return delivered;
  }

  /// [batch] is known to have been rejected as INVALID_REQUEST. Records
  /// that are individually accepted are pushed and counted; the ones still
  /// rejected are collected into [rejected].
  Future<int> _isolateInvalid(
    List<_BuiltRecord> batch, {
    required List<_BuiltRecord> rejected,
    required String deviceId,
    required Map<String, _BlobCacheEntry> blobCache,
    required List<String> warnings,
    required bool clearPending,
    List<({SyncEntityType entityType, String entityId})>? deliveredKeys,
  }) async {
    Future<int> send(List<_BuiltRecord> records) => _pushBatch(
          records,
          deviceId: deviceId,
          blobCache: blobCache,
          warnings: warnings,
          clearPending: clearPending,
          deliveredKeys: deliveredKeys,
        );
    if (batch.length == 1) {
      return _deliverRestampedOrCollect(
        batch.single,
        rejected: rejected,
        deviceId: deviceId,
        blobCache: blobCache,
        warnings: warnings,
        clearPending: clearPending,
        deliveredKeys: deliveredKeys,
      );
    }
    final mid = batch.length ~/ 2;
    var delivered = 0;
    for (final half in <List<_BuiltRecord>>[
      batch.sublist(0, mid),
      batch.sublist(mid),
    ]) {
      try {
        delivered += await send(half);
      } on AccountApiException catch (error) {
        if (error.code != 'INVALID_REQUEST') rethrow;
        delivered += await _isolateInvalid(
          half,
          rejected: rejected,
          deviceId: deviceId,
          blobCache: blobCache,
          warnings: warnings,
          clearPending: clearPending,
          deliveredKeys: deliveredKeys,
        );
      }
    }
    return delivered;
  }

  /// Pushes one record on its own. A future-stamped record is re-stamped to
  /// now and retried once; anything still rejected is collected for the
  /// caller to skip.
  Future<int> _deliverRestampedOrCollect(
    _BuiltRecord built, {
    required List<_BuiltRecord> rejected,
    required String deviceId,
    required Map<String, _BlobCacheEntry> blobCache,
    required List<String> warnings,
    required bool clearPending,
    List<({SyncEntityType entityType, String entityId})>? deliveredKeys,
  }) async {
    final nowUtc = DateTime.now().toUtc();
    if (built.record.updatedAt.isAfter(nowUtc.add(_maxFutureStamp))) {
      final restamped = _BuiltRecord(
        entry: built.entry,
        record: _restampRecord(built.record, nowUtc),
        ackItemUpdatedAt: built.ackItemUpdatedAt,
      );
      try {
        await _pushBatch(
          [restamped],
          deviceId: deviceId,
          blobCache: blobCache,
          warnings: warnings,
          clearPending: clearPending,
          deliveredKeys: deliveredKeys,
        );
        warnings.add(
          AppStrings.current.syncRecordRestamped(_describeRecord(built)),
        );
        return 1;
      } on AccountApiException catch (error) {
        if (error.code != 'INVALID_REQUEST') rethrow;
        // Still rejected after re-stamping: collect it below.
      }
    }
    rejected.add(built);
    return 0;
  }

  SyncPushChange _restampRecord(SyncPushChange change, DateTime updatedAt) =>
      SyncPushChange(
        entityType: change.entityType,
        entityId: change.entityId,
        updatedAt: updatedAt,
        deleted: change.deleted,
        envelope: change.envelope,
        packageHash: change.packageHash,
        blobSha256: change.blobSha256,
        byteLength: change.byteLength,
        fileCount: change.fileCount,
      );

  void _skipRecord(
    _BuiltRecord built, {
    required List<String> warnings,
    required bool clearPending,
  }) {
    if (clearPending) {
      _storage.sync.deletePendingChanges(
        built.entry.entityType,
        built.entry.entityId,
        upToSeq: built.entry.maxSeq,
      );
    }
    // Recovery and the pending retry can both skip the same record in one
    // run; the report only needs to say it once.
    final message = AppStrings.current.syncRecordSkipped(
      _describeRecord(built),
    );
    if (!warnings.contains(message)) warnings.add(message);
  }

  String _describeRecord(_BuiltRecord built) {
    final type = built.entry.entityType;
    final id = built.entry.entityId;
    final strings = AppStrings.current;
    if (type == SyncEntityType.skillPackage) {
      return strings.syncRecordSkillPackage(id);
    }
    if (type == SyncEntityType.categoryPrompt ||
        type == SyncEntityType.categorySkill ||
        type == SyncEntityType.categorySnippet) {
      return strings.syncRecordCategory(id);
    }
    final title = _storage.sync.readItem(id)?.title;
    return title == null || title.isEmpty
        ? strings.syncRecordItem(id)
        : strings.syncRecordItemTitled(title, id);
  }

  // ------------------------------------------------------------------
  // Pull
  // ------------------------------------------------------------------

  Future<int> _pullAll({
    required String deviceId,
    required String cursorKey,
    required SyncCancelled? cancelled,
    required List<String> warnings,
  }) async {
    var cursor = int.tryParse(_storage.sync.readState(cursorKey) ?? '') ?? 0;
    var pulled = 0;
    while (true) {
      _checkCancelled(cancelled);
      final page = await _authorizedRequest(
        (token) => _api.pull(
          accessToken: token,
          cursor: cursor,
          limit: _pullPageSize,
        ),
      );
      if (page.changes.isEmpty) break;

      // Decode and parse outside the write transaction so it stays pure
      // SQL; failures warn and skip instead of wedging the cursor.
      final resolved = <_ResolvedPull>[];
      for (final change in page.changes) {
        if (change.originDeviceId == deviceId) continue;
        final entry = _ResolvedPull(
          change,
          localEntityId: _localEntityId(change.entityType, change.entityId),
        );
        if (await _resolveOrSkip(entry, warnings)) resolved.add(entry);
      }

      final applied = await _storage.writeTransaction(() async {
        var appliedCount = 0;
        final budget = _YieldBudget();
        for (final entry in resolved) {
          if (_applyResolved(entry, warnings: warnings)) appliedCount++;
          await budget.spend(bytes: _pullPayloadBytes(entry));
        }
        _storage.sync.writeState(cursorKey, '${page.nextCursor}');
        return appliedCount;
      }, recordChanges: false);
      if (applied > 0) _notifyRemoteChange();
      pulled += page.changes.length;

      // Heartbeat is best-effort: the durable cursor is the local one.
      try {
        await _authorizedRequest(
          (token) => _api.reportCursor(
            accessToken: token,
            cursor: page.nextCursor,
          ),
        );
      } on Object {
        // ignore — token store hiccups must not fail an applied page.
      }

      // A page short of the limit usually means the log is exhausted, but
      // the server can also cut a page short on its 4 MiB wire budget while
      // more changes remain — that shows as nextCursor still below headSeq.
      if (page.changes.isEmpty ||
          page.nextCursor <= cursor ||
          (page.changes.length < _pullPageSize &&
              page.nextCursor >= page.headSeq)) {
        break;
      }
      cursor = page.nextCursor;
    }
    return pulled;
  }

  /// Resolves one pulled record, or adds a warning and returns false when
  /// this single record cannot be used. A record that can never be applied
  /// must not fail the whole run: the cursor would stay put and every later
  /// run would stop on the same record until it left the server's retention
  /// window. Only per-record problems are skipped; transport, auth and
  /// server errors still fail the run so it is retried.
  Future<bool> _resolveOrSkip(
    _ResolvedPull entry,
    List<String> warnings,
  ) async {
    final entityId = entry.change.entityId;
    try {
      await _resolvePayload(entry);
      return true;
    } on FormatException catch (error) {
      warnings.add(
        AppStrings.current.syncSkipUnparsable(entityId, error.message),
      );
    } on ArgumentError catch (error) {
      // Field values the local model rejects (empty title, over-long
      // content, invalid category, rating out of range, ...), e.g. from a
      // newer client with relaxed limits.
      warnings.add(
        AppStrings.current.syncSkipInvalid(entityId, '${error.message}'),
      );
    } on TypeError {
      // Missing or mistyped envelope fields.
      warnings.add(AppStrings.current.syncSkipMissingFields(entityId));
    } on AccountApiException catch (error) {
      // The server no longer stores this package version: it was
      // superseded and collected after the change log kept pointing at it
      // (older servers), or the file was lost. A later change or a full
      // resync carries the current package.
      if (error.code != 'BLOB_NOT_FOUND') rethrow;
      warnings.add(AppStrings.current.syncSkipOldPackage(entityId));
    }
    return false;
  }

  Future<void> _resolvePayload(_ResolvedPull entry) async {
    final change = entry.change;
    switch (change.entityType) {
      case SyncEntityType.itemPrompt:
      case SyncEntityType.itemSkill:
      case SyncEntityType.itemSnippet:
        if (change.deleted || change.envelope == null) return;
        entry.item = _decodeItem(change.envelope!);
        _adoptPulledLocalId(entry, entry.item!.id);
      case SyncEntityType.categoryPrompt:
      case SyncEntityType.categorySkill:
      case SyncEntityType.categorySnippet:
        if (change.deleted || change.envelope == null) return;
        entry.category = _decodeCategory(change.envelope!);
      case SyncEntityType.skillPackage:
        if (change.deleted) return;
        final sha256Text = change.blobSha256;
        if (sha256Text == null) {
          throw const FormatException('Skill 包记录缺少 blob 摘要。');
        }
        final container = await _authorizedRequest(
          (token) => _api.getBlob(accessToken: token, sha256: sha256Text),
        );
        entry.blob = await _runPossiblyOffThread(
          _decodeSkillBlob,
          (
            container: container is Uint8List
                ? container
                : Uint8List.fromList(container),
            expectedHash: change.packageHash,
            fallbackImportedAt: change.updatedAt,
          ),
          payloadBytes: container.length,
        );
    }
  }

  JianheItem _decodeItem(List<int> container) {
    final decoded = jsonDecode(utf8.decode(container));
    if (decoded is! Map) {
      throw const FormatException('条目信封不是 JSON 对象。');
    }
    return JianheItem.fromJson(Map<String, Object?>.from(decoded));
  }

  /// The envelope carries the sender's local row id; for legacy non-UUID
  /// entities that differs from the wire id the change is keyed by. Adopt
  /// the envelope id as the local tracking id and record both mapping
  /// directions, so the apply-if-newer gate reads the right row, the upsert
  /// lands on the sender's row id, and later pulls (tombstones, skill
  /// packages, ack verification) translate this wire id back correctly.
  void _adoptPulledLocalId(_ResolvedPull entry, String localId) {
    final change = entry.change;
    final type = change.entityType;
    if (type == SyncEntityType.categoryPrompt ||
        type == SyncEntityType.categorySkill ||
        type == SyncEntityType.categorySnippet) {
      return;
    }
    if (change.entityId != localId) {
      _storage.sync.writeState(_reverseMapKey(type, change.entityId), localId);
      _storage.sync.writeState(_forwardMapKey(type, localId), change.entityId);
    }
    entry.localEntityId = localId;
  }

  CategorySyncSnapshot _decodeCategory(List<int> container) {
    final decoded = jsonDecode(utf8.decode(container));
    if (decoded is! Map) {
      throw const FormatException('分类信封不是 JSON 对象。');
    }
    final map = Map<String, Object?>.from(decoded);
    final name = map['name'];
    final sortOrder = map['sort_order'];
    final createdAt = map['created_at'];
    if (name is! String ||
        name.trim().isEmpty ||
        sortOrder is! int ||
        createdAt is! String) {
      throw const FormatException('分类信封缺少字段。');
    }
    return CategorySyncSnapshot(
      name: name,
      sortOrder: sortOrder,
      createdAt: createdAt,
    );
  }

  /// Applies one resolved remote record. Returns true when local rows
  /// actually changed (drives the UI refresh callback).
  bool _applyResolved(_ResolvedPull entry, {required List<String> warnings}) {
    final change = entry.change;
    final type = change.entityType;
    final entityId = entry.localEntityId;
    switch (type) {
      case SyncEntityType.itemPrompt:
      case SyncEntityType.itemSkill:
      case SyncEntityType.itemSnippet:
        final localIso = _storage.sync.readItemUpdatedAt(entityId);
        if (change.deleted) {
          if (localIso == null) return false;
          // The tombstone retires one (type, id) entity. When the local row
          // already lives under another type (a type change on this or the
          // sender's device), the tombstone is for the obsolete entity and
          // must not delete the row that replaced it.
          final localType = _storage.sync.readItemType(entityId);
          if (localType != null && SyncEntityType.forItem(localType) != type) {
            return false;
          }
          // Ties go to the delete: the server only ships winning records.
          if (!change.updatedAt.isBefore(DateTime.parse(localIso))) {
            _storage.sync.deleteRemoteItem(entityId);
            return true;
          }
          return false;
        }
        final item = entry.item;
        if (item == null) return false;
        if (localIso != null &&
            !change.updatedAt.isAfter(DateTime.parse(localIso))) {
          return false;
        }
        _storage.sync.upsertRemoteItem(item);
        return true;
      case SyncEntityType.categoryPrompt:
      case SyncEntityType.categorySkill:
      case SyncEntityType.categorySnippet:
        // Categories carry no local updated_at; an unpushed local change is
        // pushed stamped with its journal time, so that is what the server
        // will arbitrate. Keep a strictly newer local change instead of
        // letting an older remote winner overwrite it before it is pushed
        // (pull-only runs and push failures pull before pushing).
        if (_hasNewerPendingChange(type, entityId, change.updatedAt)) {
          return false;
        }
        if (change.deleted) {
          if (!_storage.sync.categoryExists(type.itemType, entityId)) {
            return false;
          }
          _storage.sync.deleteRemoteCategory(type.itemType, entityId);
          return true;
        }
        final category = entry.category;
        if (category == null) return false;
        _storage.sync.upsertRemoteCategory(
          type.itemType,
          category.name,
          sortOrder: category.sortOrder,
          createdAt: category.createdAt,
        );
        return true;
      case SyncEntityType.skillPackage:
        if (change.deleted) {
          if (!_storage.sync.skillPackageExists(entityId)) return false;
          final itemIso = _storage.sync.readItemUpdatedAt(entityId);
          if (itemIso == null ||
              !change.updatedAt.isBefore(DateTime.parse(itemIso))) {
            _storage.sync.deleteRemotePackage(entityId);
            return true;
          }
          return false;
        }
        final blob = entry.blob;
        if (blob == null) return false;
        // Package puts are stamped with the host item's updated_at. When
        // this device holds an unpushed package change newer than the
        // remote one, applying the remote files would silently replace the
        // local edit (and leave SKILL.md and its files out of step). The
        // pending push wins the server arbitration instead.
        final hostIso = _storage.sync.readItemUpdatedAt(entityId);
        if (hostIso != null &&
            _storage.sync.latestPendingChangedAt(type, entityId) != null &&
            DateTime.parse(hostIso).isAfter(change.updatedAt)) {
          return false;
        }
        if (!_storage.sync.itemExists(entityId)) {
          warnings.add(AppStrings.current.syncSkipOrphanPackage(entityId));
          return false;
        }
        if (_storage.sync.readPackageHash(entityId) == blob.packageHash) {
          return false;
        }
        _storage.sync.replaceRemotePackage(
          skillId: entityId,
          entrypoint: blob.entrypoint,
          sourceFormat: blob.sourceFormat,
          importedAt: blob.importedAt,
          packageHash: blob.packageHash,
          files: blob.files,
        );
        return true;
    }
  }

  /// True when [entityId] has an unpushed local change stamped strictly
  /// after [remoteUpdatedAt]. Ties go to the remote record: the server
  /// breaks them by device id, and a skipped remote winner would never be
  /// shipped again.
  bool _hasNewerPendingChange(
    SyncEntityType type,
    String entityId,
    DateTime remoteUpdatedAt,
  ) {
    final pendingAt = _storage.sync.latestPendingChangedAt(type, entityId);
    return pendingAt != null && pendingAt.isAfter(remoteUpdatedAt);
  }

  void _notifyRemoteChange() {
    final callback = onRemoteChange;
    if (callback != null) callback();
  }

  // ------------------------------------------------------------------
  // Shared helpers
  // ------------------------------------------------------------------

  List<int> _encodeEnvelope(Map<String, Object?> envelope) {
    return utf8.encode(jsonEncode(envelope));
  }

  Map<String, Object?> _itemEnvelope(JianheItem item) {
    return <String, Object?>{
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
    };
  }

  Map<String, Object?> _categoryEnvelope(CategorySyncSnapshot category) {
    return <String, Object?>{
      'name': category.name,
      'sort_order': category.sortOrder,
      'created_at': category.createdAt,
    };
  }

  String _entityKey(SyncEntityType type, String entityId) =>
      '${type.storageValue} $entityId';

  void _checkCancelled(SyncCancelled? cancelled) {
    if (cancelled != null && cancelled()) throw const SyncCancelledException();
  }

  String _newUUID() {
    final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
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
}

// ----------------------------------------------------------------------
// Skill blob codec. Top-level so it can run on a background isolate: a
// package can carry tens of MiB, and JSON + base64 + sha256 over that on
// the UI isolate froze the floating ball for seconds.
// ----------------------------------------------------------------------

/// Payloads at or above this size are encoded/decoded on a background
/// isolate; below it, spawning one costs more than the work itself.
const _offThreadThresholdBytes = 256 << 10;

/// Runs [work] on a fresh isolate for large payloads, inline otherwise.
/// [work] must be a top-level function and [input] sendable data; keeping
/// the closure in this top-level helper guarantees it captures nothing else
/// (no engine, database or API handles).
Future<R> _runPossiblyOffThread<A, R>(
  R Function(A input) work,
  A input, {
  required int payloadBytes,
}) {
  if (payloadBytes < _offThreadThresholdBytes) {
    return Future<R>.sync(() => work(input));
  }
  return Isolate.run(() => work(input), debugName: 'jianhe-skill-blob');
}

({Uint8List bytes, String sha256}) _encodeSkillBlob(
  ({
    String entrypoint,
    String sourceFormat,
    String manifest,
    String importedAt,
    List<SkillFile> files,
  })
  input,
) {
  final plaintext = utf8.encode(
    jsonEncode(<String, Object?>{
      'entrypoint': input.entrypoint,
      'source_format': input.sourceFormat,
      'manifest': input.manifest,
      'imported_at': input.importedAt,
      'files': <Object?>[
        for (final file in input.files)
          <String, Object?>{
            'relative_path': file.relativePath,
            if (file.mediaType != null) 'media_type': file.mediaType,
            'content_base64': base64Encode(file.content),
          },
      ],
    }),
  );
  return (bytes: plaintext, sha256: sha256.convert(plaintext).toString());
}

_SkillBlobPayload _decodeSkillBlob(
  ({Uint8List container, String? expectedHash, DateTime fallbackImportedAt})
  input,
) {
  final jsonText = utf8.decode(input.container);
  final expectedHash = input.expectedHash;
  final fallbackImportedAt = input.fallbackImportedAt;
  final decoded = jsonDecode(jsonText);
  if (decoded is! Map) {
    throw const FormatException('Skill blob 不是 JSON 对象。');
  }
  final map = Map<String, Object?>.from(decoded);
  final entrypoint = map['entrypoint'];
  final sourceFormatText = map['source_format'];
  final manifest = map['manifest'];
  final importedAtText = map['imported_at'];
  final filesText = map['files'];
  if (entrypoint is! String ||
      sourceFormatText is! String ||
      manifest is! String ||
      filesText is! List) {
    throw const FormatException('Skill blob 缺少字段。');
  }
  final sourceFormat = SkillSourceFormat.fromStorage(sourceFormatText);
  final importedAt = importedAtText is String
      ? DateTime.parse(importedAtText).toUtc()
      : fallbackImportedAt;
  final files = <SkillFile>[];
  for (final row in filesText) {
    if (row is! Map) {
      throw const FormatException('Skill blob 文件行无效。');
    }
    final fileMap = Map<String, Object?>.from(row);
    final path = fileMap['relative_path'];
    final contentBase64 = fileMap['content_base64'];
    if (path is! String || contentBase64 is! String) {
      throw const FormatException('Skill blob 文件行缺少字段。');
    }
    files.add(
      SkillFile(
        relativePath: path,
        mediaType: fileMap['media_type'] is String
            ? fileMap['media_type'] as String
            : null,
        content: base64Decode(contentBase64),
      ),
    );
  }
  // Rebuild the hash exactly like the sender did; a mismatch means the
  // blob or the metadata record was corrupted in transit.
  final packageHash = SkillPackage.calculatePackageHash(manifest, <String, String>{
    for (final file in files) file.relativePath: file.contentHash,
  });
  if (expectedHash != null && packageHash != expectedHash) {
    throw const FormatException('Skill blob 与包摘要不一致。');
  }
  return _SkillBlobPayload(
    entrypoint: entrypoint,
    sourceFormat: sourceFormat,
    importedAt: importedAt,
    manifest: manifest,
    files: files,
    packageHash: packageHash,
  );
}
