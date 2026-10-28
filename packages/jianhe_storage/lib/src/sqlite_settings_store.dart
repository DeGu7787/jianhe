import 'dart:async';

import 'package:jianhe_core/jianhe_core.dart';
import 'package:sqlite3/sqlite3.dart';

/// Decides whether a settings write must not run on the connection right
/// now, and queues it to run later in its own transaction.
typedef SettingsWriteGuard = ({
  bool Function() shouldDefer,
  Future<void> Function(void Function() write) defer,
});

class SqliteSettingsStore {
  SqliteSettingsStore(this._database);

  static const _cliAccessKey = 'cli_access_mode';
  static const _cliSkillImportKey = 'cli_skill_import_enabled';
  static const _autoCollapseSecondsKey = 'auto_collapse_seconds';
  static const _autoSyncScheduleModeKey = 'auto_sync_schedule_mode';
  static const _autoSyncIntervalMinutesKey = 'auto_sync_interval_minutes';
  static const _autoSyncDailyTimeKey = 'auto_sync_daily_time';
  static const _uiLanguageKey = 'ui_language';
  static const defaultAutoCollapseSeconds = 4;
  static const minimumAutoCollapseSeconds = 1;
  static const maximumAutoCollapseSeconds = 60;

  final Database _database;
  SettingsWriteGuard? _writeGuard;

  /// Values written while their database write is deferred; reads see them
  /// immediately so callers keep read-after-write consistency.
  final Map<String, String> _deferredValues = <String, String>{};

  /// Installed by JianheStorageDatabase. Long write transactions (sync
  /// apply, backup import) yield to the event loop while open; a bare
  /// autocommit write issued meanwhile would silently join that transaction
  /// and be undone if it rolls back. That is unacceptable for consent
  /// settings such as the CLI access switch, so such writes are queued
  /// behind the open transaction and committed on their own instead.
  void attachWriteGuard(SettingsWriteGuard guard) {
    _writeGuard = guard;
  }

  CliAccessMode get cliAccessMode {
    return CliAccessMode.fromStorage(
      _read(_cliAccessKey),
      legacySkillImportEnabled: _read(_cliSkillImportKey),
    );
  }

  /// Reads the CLI access switch from [database] without requiring the
  /// current schema: a database without `app_settings` (older schemas) has
  /// never granted access. Used to authorize a CLI write before the
  /// connection that would migrate the database is opened.
  static CliAccessMode readCliAccessMode(Database database) {
    final hasSettings = database.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' "
      "AND name = 'app_settings';",
    ).isNotEmpty;
    if (!hasSettings) return CliAccessMode.disabled;
    String? read(String key) {
      final rows = database.select(
        'SELECT value FROM app_settings WHERE key = ? LIMIT 1;',
        [key],
      );
      return rows.isEmpty ? null : rows.first['value'] as String?;
    }

    return CliAccessMode.fromStorage(
      read(_cliAccessKey),
      legacySkillImportEnabled: read(_cliSkillImportKey),
    );
  }

  static AppLanguage readUiLanguage(Database database) {
    final hasSettings = database.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' "
      "AND name = 'app_settings';",
    ).isNotEmpty;
    if (!hasSettings) return AppLanguage.fallback;
    final rows = database.select(
      'SELECT value FROM app_settings WHERE key = ? LIMIT 1;',
      [_uiLanguageKey],
    );
    return AppLanguage.fromStorage(
      rows.isEmpty ? null : rows.first['value'] as String?,
    );
  }

  void setCliAccessMode(CliAccessMode mode) {
    _write(_cliAccessKey, mode.storageValue);
    // Kept as a persisted mirror for installations created before CLI access
    // became a single switch.  New callers must use cliAccessMode only.
    _write(_cliSkillImportKey, (mode == CliAccessMode.readWrite).toString());
  }

  /// Compatibility projection of the unified CLI access switch.
  ///
  /// Older databases can have a stale `cli_skill_import_enabled` value.  It
  /// must not override an enabled command-line interface.
  bool get cliSkillImportEnabled => cliAccessMode == CliAccessMode.readWrite;

  /// Compatibility setter for callers compiled against the old split setting.
  void setCliSkillImportEnabled(bool enabled) {
    setCliAccessMode(
      enabled ? CliAccessMode.readWrite : CliAccessMode.disabled,
    );
  }

  /// Interface language of this device. Also read by the CLI so composed
  /// output uses the same separator as the desktop app.
  AppLanguage get uiLanguage => AppLanguage.fromStorage(_read(_uiLanguageKey));

  void setUiLanguage(AppLanguage language) {
    _write(_uiLanguageKey, language.storageValue);
  }

  int get autoCollapseSeconds {
    final seconds = int.tryParse(_read(_autoCollapseSecondsKey) ?? '');
    if (seconds == null ||
        seconds < 0 ||
        seconds > maximumAutoCollapseSeconds) {
      return defaultAutoCollapseSeconds;
    }
    // 旧版本允许 0（移出即收回）；最低值提到 1 秒后，把这些旧值归到最快的
    // 1 秒，而不是退回默认值，保留用户“尽快收回”的意图。
    if (seconds < minimumAutoCollapseSeconds) return minimumAutoCollapseSeconds;
    return seconds;
  }

  void setAutoCollapseSeconds(int seconds) {
    if (seconds < minimumAutoCollapseSeconds ||
        seconds > maximumAutoCollapseSeconds) {
      throw RangeError.range(
        seconds,
        minimumAutoCollapseSeconds,
        maximumAutoCollapseSeconds,
        'seconds',
      );
    }
    _write(_autoCollapseSecondsKey, seconds.toString());
  }

  String get autoSyncScheduleMode {
    final value = _read(_autoSyncScheduleModeKey);
    return value == 'daily' ? 'daily' : 'interval';
  }

  int get autoSyncIntervalMinutes {
    final value = int.tryParse(_read(_autoSyncIntervalMinutesKey) ?? '');
    return const <int>[15, 30, 60].contains(value) ? value! : 15;
  }

  ({int hour, int minute}) get autoSyncDailyTime {
    final parts = (_read(_autoSyncDailyTimeKey) ?? '').split(':');
    final hour = parts.isNotEmpty ? int.tryParse(parts[0]) : null;
    final minute = parts.length > 1 ? int.tryParse(parts[1]) : null;
    if (hour == null ||
        minute == null ||
        hour < 0 ||
        hour > 23 ||
        minute < 0 ||
        minute > 59) {
      return (hour: 21, minute: 0);
    }
    return (hour: hour, minute: minute);
  }

  void setAutoSyncSchedule({
    required String mode,
    int? intervalMinutes,
    int? dailyHour,
    int? dailyMinute,
  }) {
    if (mode != 'interval' && mode != 'daily') {
      throw ArgumentError.value(mode, 'mode');
    }
    if (mode == 'interval') {
      if (!const <int>[15, 30, 60].contains(intervalMinutes)) {
        throw ArgumentError.value(intervalMinutes, 'intervalMinutes');
      }
      _write(_autoSyncScheduleModeKey, mode);
      _write(_autoSyncIntervalMinutesKey, '$intervalMinutes');
      return;
    }
    if (dailyHour == null ||
        dailyMinute == null ||
        dailyHour < 0 ||
        dailyHour > 23 ||
        dailyMinute < 0 ||
        dailyMinute > 59) {
      throw ArgumentError('Invalid daily sync time.');
    }
    _write(_autoSyncScheduleModeKey, mode);
    _write(
      _autoSyncDailyTimeKey,
      '${dailyHour.toString().padLeft(2, '0')}:${dailyMinute.toString().padLeft(2, '0')}',
    );
  }

  String? read(String key) => _read(key);

  void write(String key, String value) => _write(key, value);

  String? _read(String key) {
    final deferred = _deferredValues[key];
    if (deferred != null) return deferred;
    final rows = _database.select(
      'SELECT value FROM app_settings WHERE key = ? LIMIT 1;',
      [key],
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  void _write(String key, String value) {
    final guard = _writeGuard;
    if (guard != null && guard.shouldDefer()) {
      _deferredValues[key] = value;
      unawaited(
        guard.defer(() => _writeNow(key, value)).whenComplete(() {
          // A newer deferred value for the same key keeps its overlay.
          if (_deferredValues[key] == value) _deferredValues.remove(key);
        }),
      );
      return;
    }
    _writeNow(key, value);
  }

  void _writeNow(String key, String value) {
    _database.execute(
      '''
      INSERT INTO app_settings (key, value, updated_at)
      VALUES (?, ?, ?)
      ON CONFLICT(key) DO UPDATE SET
        value = excluded.value,
        updated_at = excluded.updated_at;
      ''',
      [key, value, DateTime.now().toUtc().toIso8601String()],
    );
  }
}
