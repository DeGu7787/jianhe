import '../../l10n/app_strings.dart';

class AccountEntitlement {
  const AccountEntitlement({
    required this.plan,
    required this.vipExpiresAt,
    required this.cloudBackupUploadAllowed,
    required this.cloudBackupDownloadAllowed,
    this.vipLifetime = false,
  });

  factory AccountEntitlement.fromJson(Map<String, Object?> json) {
    final vipExpiresAt = _optionalDateTime(json, 'vip_expires_at');
    return AccountEntitlement(
      plan: _requiredString(json, 'plan'),
      vipExpiresAt: vipExpiresAt,
      // Older servers do not send vip_lifetime; the lifetime sentinel is a
      // year-9999 expiry, so fall back to recognising it directly.
      vipLifetime:
          (json['vip_lifetime'] as bool?) ??
          (vipExpiresAt != null && vipExpiresAt.year >= 9998),
      cloudBackupUploadAllowed: _requiredBool(
        json,
        'cloud_backup_upload_allowed',
      ),
      cloudBackupDownloadAllowed: _requiredBool(
        json,
        'cloud_backup_download_allowed',
      ),
    );
  }

  final String plan;
  final DateTime? vipExpiresAt;
  final bool cloudBackupUploadAllowed;
  final bool cloudBackupDownloadAllowed;

  /// 永久 VIP：无需也无法再次购买。
  final bool vipLifetime;

  bool get isVip => plan == 'vip' && cloudBackupUploadAllowed;
  bool get isCloudBackupReadOnly =>
      !cloudBackupUploadAllowed && cloudBackupDownloadAllowed;
  bool get hasCloudBackupAccess =>
      cloudBackupUploadAllowed || cloudBackupDownloadAllowed;
}

class JianheAccount {
  const JianheAccount({
    required this.id,
    required this.email,
    required this.emailVerified,
    required this.entitlement,
    this.isAdmin = false,
    this.googleLinked = false,
  });

  factory JianheAccount.fromJson(Map<String, Object?> json) {
    return JianheAccount(
      id: _requiredString(json, 'id'),
      email: (json['email'] as String?) ?? '',
      emailVerified: _requiredBool(json, 'email_verified'),
      isAdmin: (json['is_admin'] as bool?) ?? false,
      googleLinked: (json['google_linked'] as bool?) ?? false,
      entitlement: AccountEntitlement.fromJson(
        _requiredMap(json, 'entitlement'),
      ),
    );
  }

  final String id;
  final String email;
  final bool emailVerified;
  final bool isAdmin;
  final bool googleLinked;
  final AccountEntitlement entitlement;

  /// 用户侧显示的账号名：优先显示邮箱；仅用第三方登录、没有邮箱的账号
  /// 显示登录方式，不暴露内部账号 ID。
  String get displayLabel {
    if (email.isNotEmpty) return email;
    final strings = AppStrings.current;
    return googleLinked ? strings.googleAccount : strings.jianheAccount;
  }
}

class AccountDevice {
  const AccountDevice({required this.id, required this.name});

  factory AccountDevice.fromJson(Map<String, Object?> json) {
    return AccountDevice(
      id: _requiredString(json, 'id'),
      name: _requiredString(json, 'name'),
    );
  }

  final String id;
  final String name;
}

class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.accessTokenExpiresAt,
    required this.refreshToken,
    required this.refreshTokenExpiresAt,
    required this.account,
    required this.device,
  });

  factory AuthSession.fromJson(Map<String, Object?> json) {
    return AuthSession(
      accessToken: _requiredString(json, 'access_token'),
      accessTokenExpiresAt: _requiredDateTime(json, 'access_token_expires_at'),
      refreshToken: _requiredString(json, 'refresh_token'),
      refreshTokenExpiresAt: _requiredDateTime(
        json,
        'refresh_token_expires_at',
      ),
      account: JianheAccount.fromJson(_requiredMap(json, 'account')),
      device: AccountDevice.fromJson(_requiredMap(json, 'device')),
    );
  }

  final String accessToken;
  final DateTime accessTokenExpiresAt;
  final String refreshToken;
  final DateTime refreshTokenExpiresAt;
  final JianheAccount account;
  final AccountDevice device;
}

class CurrentAccount {
  const CurrentAccount({required this.account, required this.device});

  factory CurrentAccount.fromJson(Map<String, Object?> json) {
    return CurrentAccount(
      account: JianheAccount.fromJson(_requiredMap(json, 'account')),
      device: AccountDevice.fromJson(_requiredMap(json, 'device')),
    );
  }

  final JianheAccount account;
  final AccountDevice device;
}

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  throw FormatException('Missing or invalid $key.');
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('Missing or invalid $key.');
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  throw FormatException('Missing or invalid $key.');
}

DateTime _requiredDateTime(Map<String, Object?> json, String key) {
  final value = _requiredString(json, key);
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('Missing or invalid $key.');
  return parsed.toUtc();
}

DateTime? _optionalDateTime(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('Invalid $key.');
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('Invalid $key.');
  return parsed.toUtc();
}
