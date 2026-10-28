import 'dart:convert';

import 'package:jianhe_core/jianhe_core.dart';

/// Thrown by the sync engine for every terminal failure. `code`
/// matches the protocol error codes where one exists so the controller can
/// branch without parsing messages.
class SyncEngineException implements Exception {
  const SyncEngineException({required this.code, required this.message});

  final String code;
  final String message;

  @override
  String toString() => 'SyncEngineException($code): $message';
}

/// The run was superseded by a logout or a new manual trigger.
class SyncCancelledException extends SyncEngineException {
  const SyncCancelledException()
    : super(code: 'CANCELLED', message: '同步已取消。');
}

class SyncRunResult {
  const SyncRunResult({
    required this.pushedCount,
    required this.pulledCount,
    required this.warnings,
    required this.finishedAt,
    this.quotaBlockedCount = 0,
    this.quotaNotice,
  });

  /// Records whose pending rows were cleared: accepted pushes and
  /// LOST_LWW arbitrations alike.
  final int pushedCount;
  final int pulledCount;
  final List<String> warnings;
  final DateTime finishedAt;

  /// Local changes waiting because the cloud space is full. They stay
  /// queued and upload once space frees up.
  final int quotaBlockedCount;

  /// User-facing explanation when [quotaBlockedCount] is non-zero (also the
  /// first entry of [warnings]).
  final String? quotaNotice;
}

/// What a run should do: [pushAndPull] is the full cycle (manual sync and
/// the debounced auto push); [pullOnly] skips the pending push for startup
/// and foreground pulls.
enum SyncMode { pushAndPull, pullOnly }

/// `GET /v1/sync/state` response (protocol §6.2).
class SyncStateInfo {
  const SyncStateInfo({
    required this.headSeq,
    required this.windowStart,
    required this.quotaUsedBytes,
    required this.quotaMaxBytes,
  });

  final int headSeq;
  final int windowStart;
  final int quotaUsedBytes;
  final int quotaMaxBytes;

  factory SyncStateInfo.fromJson(Map<String, Object?> json) {
    final headSeq = json['head_seq'];
    final windowStart = json['window_start'];
    final quota = json['quota'];
    if (headSeq is! int || windowStart is! int || quota is! Map) {
      throw const FormatException('Invalid sync state payload.');
    }
    final quotaMap = quota.cast<String, Object?>();
    final usedBytes = quotaMap['used_bytes'];
    final maxBytes = quotaMap['max_bytes'];
    if (usedBytes is! int || maxBytes is! int) {
      throw const FormatException('Invalid sync quota payload.');
    }
    return SyncStateInfo(
      headSeq: headSeq,
      windowStart: windowStart,
      quotaUsedBytes: usedBytes,
      quotaMaxBytes: maxBytes,
    );
  }
}

/// One outgoing record of `POST /v1/sync/changes` (protocol §6.3).
class SyncPushChange {
  const SyncPushChange({
    required this.entityType,
    required this.entityId,
    required this.updatedAt,
    this.deleted = false,
    this.envelope,
    this.packageHash,
    this.blobSha256,
    this.byteLength,
    this.fileCount,
  });

  final SyncEntityType entityType;
  final String entityId;
  final DateTime updatedAt;
  final bool deleted;

  /// JHCLSYN1 container bytes; item/category records only.
  final List<int>? envelope;

  /// skill_package records carry metadata instead of an envelope.
  final String? packageHash;
  final String? blobSha256;
  final int? byteLength;
  final int? fileCount;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'entity_type': entityType.storageValue,
      'entity_id': entityId,
      'updated_at': updatedAt.toUtc().toIso8601String(),
      'deleted': deleted,
      if (envelope != null)
        'envelope': base64Encode(envelope!),
      if (packageHash != null) 'package_hash': packageHash,
      if (blobSha256 != null) 'blob_sha256': blobSha256,
      if (byteLength != null) 'byte_length': byteLength,
      if (fileCount != null) 'file_count': fileCount,
    };
  }
}

/// Per-record arbitration result (protocol §6.3).
class SyncPushResult {
  const SyncPushResult({
    required this.entityType,
    required this.entityId,
    required this.accepted,
    this.changeSeq,
    this.reason,
  });

  final SyncEntityType entityType;
  final String entityId;
  final bool accepted;
  final int? changeSeq;

  /// `LOST_LWW` means the server already had a newer state; the local row
  /// stays as-is and the remote winner arrives via pull.
  final String? reason;

  factory SyncPushResult.fromJson(Map<String, Object?> json) {
    final entityType = json['entity_type'];
    final entityId = json['entity_id'];
    final accepted = json['accepted'];
    if (entityType is! String || entityId is! String || accepted is! bool) {
      throw const FormatException('Invalid push result payload.');
    }
    final changeSeq = json['change_seq'];
    final reason = json['reason'];
    return SyncPushResult(
      entityType: SyncEntityType.parse(entityType),
      entityId: entityId,
      accepted: accepted,
      changeSeq: changeSeq is int ? changeSeq : null,
      reason: reason is String ? reason : null,
    );
  }
}

class SyncPushResponse {
  const SyncPushResponse({required this.headSeq, required this.results});

  final int headSeq;
  final List<SyncPushResult> results;

  factory SyncPushResponse.fromJson(Map<String, Object?> json) {
    final headSeq = json['head_seq'];
    final results = json['results'];
    if (headSeq is! int || results is! List) {
      throw const FormatException('Invalid push response payload.');
    }
    return SyncPushResponse(
      headSeq: headSeq,
      results: results
          .whereType<Map>()
          .map((row) => SyncPushResult.fromJson(row.cast<String, Object?>()))
          .toList(growable: false),
    );
  }
}

/// One accepted record of `GET /v1/sync/changes` (protocol §6.4).
class SyncPullChange {
  const SyncPullChange({
    required this.changeSeq,
    required this.entityType,
    required this.entityId,
    required this.updatedAt,
    required this.deleted,
    required this.originDeviceId,
    this.envelope,
    this.packageHash,
    this.blobSha256,
    this.byteLength,
    this.fileCount,
  });

  final int changeSeq;
  final SyncEntityType entityType;
  final String entityId;
  final DateTime updatedAt;
  final bool deleted;
  final String originDeviceId;
  final List<int>? envelope;
  final String? packageHash;
  final String? blobSha256;
  final int? byteLength;
  final int? fileCount;

  factory SyncPullChange.fromJson(Map<String, Object?> json) {
    final changeSeq = json['change_seq'];
    final entityType = json['entity_type'];
    final entityId = json['entity_id'];
    final updatedAt = json['updated_at'];
    final deleted = json['deleted'];
    final originDeviceId = json['origin_device_id'];
    if (changeSeq is! int ||
        entityType is! String ||
        entityId is! String ||
        updatedAt is! String ||
        deleted is! bool ||
        originDeviceId is! String) {
      throw const FormatException('Invalid pull change payload.');
    }
    final envelopeText = json['envelope'];
    final packageHash = json['package_hash'];
    final blobSha256 = json['blob_sha256'];
    final byteLength = json['byte_length'];
    final fileCount = json['file_count'];
    return SyncPullChange(
      changeSeq: changeSeq,
      entityType: SyncEntityType.parse(entityType),
      entityId: entityId,
      updatedAt: DateTime.parse(updatedAt).toUtc(),
      deleted: deleted,
      originDeviceId: originDeviceId,
      envelope: envelopeText is String ? base64Decode(envelopeText) : null,
      packageHash: packageHash is String ? packageHash : null,
      blobSha256: blobSha256 is String ? blobSha256 : null,
      byteLength: byteLength is int ? byteLength : null,
      fileCount: fileCount is int ? fileCount : null,
    );
  }
}

class SyncPullResponse {
  const SyncPullResponse({
    required this.changes,
    required this.nextCursor,
    required this.headSeq,
  });

  final List<SyncPullChange> changes;
  final int nextCursor;
  final int headSeq;

  factory SyncPullResponse.fromJson(Map<String, Object?> json) {
    final changes = json['changes'];
    final nextCursor = json['next_cursor'];
    final headSeq = json['head_seq'];
    if (changes is! List || nextCursor is! int || headSeq is! int) {
      throw const FormatException('Invalid pull response payload.');
    }
    return SyncPullResponse(
      changes: changes
          .whereType<Map>()
          .map((row) => SyncPullChange.fromJson(row.cast<String, Object?>()))
          .toList(growable: false),
      nextCursor: nextCursor,
      headSeq: headSeq,
    );
  }
}

/// One page of `GET /v1/sync/state?snapshot=full` (protocol §6.6.1): the
/// account's live winning entities. [nextEntityType]/[nextEntityId] are null
/// on the last page; otherwise they form the keyset cursor of the next page.
class SyncSnapshotResponse {
  const SyncSnapshotResponse({
    required this.changes,
    required this.headSeq,
    this.nextEntityType,
    this.nextEntityId,
  });

  final List<SyncPullChange> changes;
  final int headSeq;
  final String? nextEntityType;
  final String? nextEntityId;

  factory SyncSnapshotResponse.fromJson(Map<String, Object?> json) {
    final changes = json['changes'];
    final headSeq = json['head_seq'];
    if (changes is! List || headSeq is! int) {
      throw const FormatException('Invalid snapshot response payload.');
    }
    final nextEntityType = json['next_entity_type'];
    final nextEntityId = json['next_entity_id'];
    return SyncSnapshotResponse(
      changes: changes
          .whereType<Map>()
          .map((row) => SyncPullChange.fromJson(row.cast<String, Object?>()))
          .toList(growable: false),
      headSeq: headSeq,
      nextEntityType: nextEntityType is String && nextEntityType.isNotEmpty
          ? nextEntityType
          : null,
      nextEntityId: nextEntityId is String && nextEntityId.isNotEmpty
          ? nextEntityId
          : null,
    );
  }
}
