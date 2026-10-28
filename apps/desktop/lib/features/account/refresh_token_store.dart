import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StoredRefreshSession {
  const StoredRefreshSession({
    required this.refreshToken,
    this.pendingRefreshIdempotencyKey,
  });

  final String refreshToken;
  final String? pendingRefreshIdempotencyKey;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'refresh_token': refreshToken,
    'pending_refresh_idempotency_key': pendingRefreshIdempotencyKey,
  };

  factory StoredRefreshSession.fromJson(Map<String, Object?> json) {
    final token = json['refresh_token'];
    final pending = json['pending_refresh_idempotency_key'];
    if (json['version'] != 1 || token is! String || token.isEmpty) {
      throw const FormatException('Invalid stored refresh session.');
    }
    if (pending != null && (pending is! String || pending.isEmpty)) {
      throw const FormatException('Invalid pending idempotency key.');
    }
    return StoredRefreshSession(
      refreshToken: token,
      pendingRefreshIdempotencyKey: pending as String?,
    );
  }
}

abstract interface class RefreshTokenStore {
  Future<StoredRefreshSession?> read();
  Future<void> write(StoredRefreshSession session);
  Future<void> delete();
}

class SecureRefreshTokenStore implements RefreshTokenStore {
  const SecureRefreshTokenStore([this._storage = const FlutterSecureStorage()]);

  static const _storageKey = 'jianhe_cloud_refresh_session_v1';
  final FlutterSecureStorage _storage;

  @override
  Future<StoredRefreshSession?> read() async {
    final encoded = await _storage.read(key: _storageKey);
    if (encoded == null || encoded.isEmpty) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) throw const FormatException('Invalid session.');
      return StoredRefreshSession.fromJson(decoded.cast<String, Object?>());
    } on FormatException {
      await delete();
      return null;
    }
  }

  @override
  Future<void> write(StoredRefreshSession session) {
    return _storage.write(
      key: _storageKey,
      value: jsonEncode(session.toJson()),
    );
  }

  @override
  Future<void> delete() => _storage.delete(key: _storageKey);
}
