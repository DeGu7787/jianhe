import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:jianhe_core/jianhe_core.dart';
import 'package:jianhe_storage/jianhe_storage.dart';

import 'app.dart';
import 'features/account/account_api.dart';
import 'features/account/account_session_controller.dart';
import 'features/account/refresh_token_store.dart';
import 'features/app_update/app_update_controller.dart';
import 'features/app_update/app_update_platform_io.dart';
import 'features/cloud_sync/sync_api.dart';
import 'features/cloud_sync/background_sync_runner.dart';
import 'features/cloud_sync/sync_controller.dart';
import 'features/cloud_sync/sync_engine.dart';
import 'features/cloud_sync/sync_schedule.dart';
import 'features/feedback/feedback_api.dart';
import 'global_error_file_sink.dart';
import 'global_error_handlers.dart';
import 'l10n/app_strings.dart';
import 'platform/app_language_channel.dart';
import 'platform/ball_window_controller.dart';
import 'platform/background_sync_scheduler.dart';
import 'platform/global_hot_key.dart';
import 'platform/process_file_lock.dart';

JianheStorageDatabase? _database;
SyncController? _syncController;
const _backgroundSyncScheduler = BackgroundSyncScheduler();
const _languageChannel = AppLanguageChannel();
final _accountProcessLock = ProcessFileLock(
  File(
    '${JianheDataPaths.dataDirectory().path}${Platform.pathSeparator}account-session.lock',
  ),
);
final _cloudSyncProcessLock = ProcessFileLock(
  File(
    '${JianheDataPaths.dataDirectory().path}${Platform.pathSeparator}cloud-sync.lock',
  ),
);

SyncEngine _createSyncEngine(
  AccountSessionController accountController,
  JianheStorageDatabase database,
) => SyncEngine(
  storage: database,
  api: SyncApi(baseUri: Uri.parse(_apiBaseUrl)),
  authorizedRequest: accountController.authorizedRequest,
  serverDeviceId: () => accountController.device?.id,
);

SyncSchedule _readSyncSchedule(JianheStorageDatabase database) {
  if (database.settings.autoSyncScheduleMode == 'daily') {
    final time = database.settings.autoSyncDailyTime;
    return SyncSchedule.daily(hour: time.hour, minute: time.minute);
  }
  return SyncSchedule.interval(database.settings.autoSyncIntervalMinutes);
}

void _writeSyncSchedule(JianheStorageDatabase database, SyncSchedule schedule) {
  database.settings.setAutoSyncSchedule(
    mode: schedule.mode.name,
    intervalMinutes: schedule.intervalMinutes,
    dailyHour: schedule.dailyHour,
    dailyMinute: schedule.dailyMinute,
  );
}

/// Built after the local database opens; null while storage is unavailable
/// (the account panel then hides the sync card entirely).
SyncController? _createSyncController(
  AccountSessionController accountController,
  JianheStorageDatabase database,
) {
  try {
    return SyncController(
      accountSession: accountController,
      engine: _createSyncEngine(accountController, database),
      // Auto sync defaults on; the setting stores '0' to switch it off.
      autoSyncEnabled: () => database.settings.read('auto_sync_enabled') != '0',
      setAutoSyncEnabled: (value) =>
          database.settings.write('auto_sync_enabled', value ? '1' : '0'),
      syncSchedule: () => _readSyncSchedule(database),
      setSyncSchedule: (value) => _writeSyncSchedule(database, value),
      dailySyncTime: () => database.settings.autoSyncDailyTime,
      configureSystemSchedule: _backgroundSyncScheduler.configure,
      cancelSystemSchedule: _backgroundSyncScheduler.cancel,
      syncCriticalSection: _cloudSyncProcessLock.runExclusive,
      errorLog: fileErrorSink(JianheDataPaths.dataDirectory().path),
    );
  } on Object catch (error) {
    debugPrint('Failed to configure Jianhe incremental sync: $error');
    return null;
  }
}

const _apiBaseUrl = String.fromEnvironment(
  'JIANHE_API_BASE_URL',
  defaultValue: 'https://jianhe.neodaas.com',
);
const _appVersion = String.fromEnvironment(
  'JIANHE_APP_VERSION',
  defaultValue: '0.1.10',
);
const _cloudPortalUrl = String.fromEnvironment(
  'JIANHE_CLOUD_PORTAL_URL',
  defaultValue: 'https://jianhe.neodaas.com/jianhecloud/',
);

/// Self-updater for release builds on Windows. Debug and non-Windows runs
/// have no installer to replace, so they get no update entry.
AppUpdateController? _createAppUpdateController() {
  if (!Platform.isWindows || !const bool.fromEnvironment('dart.vm.product')) {
    return null;
  }
  try {
    return AppUpdateController(
      platform: IoAppUpdatePlatform(siteUri: Uri.parse(_apiBaseUrl)),
      currentVersion: _appVersion,
      isSyncing: () => _syncController?.syncing ?? false,
    )..start();
  } on Object catch (error) {
    debugPrint('Failed to configure Jianhe self-update: $error');
    return null;
  }
}

AccountSessionController _createAccountController() {
  try {
    final hostname = Platform.localHostname.trim();
    return AccountSessionController(
      api: AccountApi(baseUri: Uri.parse(_apiBaseUrl)),
      tokenStore: const SecureRefreshTokenStore(),
      deviceName: hostname.isEmpty ? 'Windows PC' : hostname,
      appVersion: _appVersion,
      accountCriticalSection: _accountProcessLock.runExclusive,
    );
  } on Object catch (error) {
    debugPrint('Failed to configure Jianhe cloud service: $error');
    return AccountSessionController.unconfigured();
  }
}

/// Reads the persisted per-stage panel sizes (e.g. "composer" -> "520,640")
/// into the map BallHomePage expects, keyed by BallWindowStage.name.
Map<String, Size> _readPanelSizes(JianheStorageDatabase database) {
  Size? parse(String? raw) {
    if (raw == null) return null;
    final parts = raw.split(',');
    if (parts.length != 2) return null;
    final width = double.tryParse(parts[0]);
    final height = double.tryParse(parts[1]);
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return Size(width, height);
  }

  return {
    for (final stage in const ['composer', 'browser', 'editor', 'settings'])
      stage: ?parse(database.settings.read('panel_size_$stage')),
  };
}

void _writePanelSize(String stage, Size size) {
  _database?.settings.write(
    'panel_size_$stage',
    '${size.width.toStringAsFixed(1)},${size.height.toStringAsFixed(1)}',
  );
}

Map<ItemType, String> _readPinnedCategories(JianheStorageDatabase database) {
  final categories = <ItemType, String>{};
  for (final type in ItemType.values) {
    final category = database.settings
        .read('pinned_category_${type.name}')
        ?.trim();
    if (category != null && category.isNotEmpty) {
      categories[type] = category;
    }
  }
  return categories;
}

void _writePinnedCategory(ItemType type, String? category) {
  _database?.settings.write('pinned_category_${type.name}', category ?? '');
}

void _logStartupError(String origin, Object error, StackTrace stackTrace) {
  fileErrorSink(
    JianheDataPaths.dataDirectory().path,
  )(formatGlobalError(origin, error, stackTrace));
}

String _errorLogPath() =>
    '${JianheDataPaths.dataDirectory().path}${Platform.pathSeparator}error.log';

Future<void> _runBackgroundSyncOnce() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The foreground path logs every uncaught error to error.log; give the
  // headless worker the same net so field failures are diagnosable from the
  // exit code alone.
  installGlobalErrorHandlers(
    log: fileErrorSink(JianheDataPaths.dataDirectory().path),
  );
  var exitCode = BackgroundSyncOutcome.terminalFailure.exitCode;
  JianheStorageDatabase? database;
  AccountSessionController? accountController;
  try {
    database = JianheStorageDatabase.open(JianheDataPaths.databaseFile().path);
    // Messages this run logs follow the interface language.
    AppStrings.setCurrentLanguage(database.settings.uiLanguage);
    accountController = _createAccountController();
    final runner = BackgroundSyncRunner(
      accountSession: accountController,
      engine: _createSyncEngine(accountController, database),
      autoSyncEnabled: () =>
          database!.settings.read('auto_sync_enabled') != '0',
      syncCriticalSection: _cloudSyncProcessLock.runExclusive,
    );
    exitCode = (await runner.runOnce()).exitCode;
  } on Object catch (error, stackTrace) {
    debugPrint('Background sync failed: $error\n$stackTrace');
    _logStartupError('Background sync failed', error, stackTrace);
  } finally {
    accountController?.dispose();
    database?.close();
    try {
      await _backgroundSyncScheduler.complete(exitCode);
    } on Object {
      exit(exitCode);
    }
  }
}

Future<void> main(List<String> args) async {
  if (args.contains('--sync-once')) {
    await _runBackgroundSyncOnce();
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  installGlobalErrorHandlers(
    log: fileErrorSink(JianheDataPaths.dataDirectory().path),
  );
  // A language picked in the installer applies once, then the in-app
  // setting (ui_language) is the source of truth. Read before the database
  // opens so even the read-only fallback below shows the chosen language.
  final installerLanguage = await _languageChannel.consumeInstallerLanguage();
  final accountController = _createAccountController();
  unawaited(accountController.initialize());
  // Created before the database opens so even the read-only fallback (a
  // failed schema upgrade) can still update to a fixed release.
  final appUpdateController = _createAppUpdateController();

  try {
    // A short per-statement busy timeout: transactions wait for another
    // process's write lock asynchronously (writeLockWaits), so only a rare
    // single autocommit write can still block the UI, and for at most 1 s.
    // A schema upgrade blocked by the CLI is likewise awaited on the event
    // loop, so account restore keeps running meanwhile.
    _database = await JianheStorageDatabase.openWhenAvailable(
      JianheDataPaths.databaseFile().path,
      busyTimeoutMs: 1000,
    );
    _syncController = _createSyncController(accountController, _database!);
    final repository = _database!.items;
    if (installerLanguage != null) {
      try {
        _database!.settings.setUiLanguage(installerLanguage);
      } on Object catch (error) {
        // Still shown for this session; the setting keeps its old value.
        debugPrint('Failed to save the installer language: $error');
      }
    }
    final language = installerLanguage ?? _database!.settings.uiLanguage;
    AppStrings.setCurrentLanguage(language);
    unawaited(_languageChannel.setLanguage(language));

    final savedEdge = _database!.settings.read('ball_dock_edge');
    final savedOffset = _database!.settings.read('ball_dock_offset');
    final savedWakeHotKey = _database!.settings.read('wake_hot_key');

    runApp(
      JianheApp(
        repository: repository,
        skillPackages: _database!.skills,
        initialCliAccessMode: _database!.settings.cliAccessMode,
        onCliAccessModeChanged: _database!.settings.setCliAccessMode,
        initialCliSkillImportEnabled: _database!.settings.cliSkillImportEnabled,
        onCliSkillImportEnabledChanged:
            _database!.settings.setCliSkillImportEnabled,
        initialAutoCollapseSeconds: _database!.settings.autoCollapseSeconds,
        onAutoCollapseSecondsChanged:
            _database!.settings.setAutoCollapseSeconds,
        initialWakeHotKey: GlobalHotKey.parseOrDefault(savedWakeHotKey),
        onWakeHotKeyChanged: (hotKey) =>
            _database!.settings.write('wake_hot_key', hotKey.storageValue),
        // Native GDI+ path: the host grows/shrinks between the 88x88 ball
        // and the 390x360 menu through the C++ layer, the 6 sub-balls
        // paint through native_orbit_window.cpp::Render, and the
        // angle-constrained ComputeArcLayout keeps them from overlapping
        // when the main ball sits in a host corner.
        windowController: NativeBallWindowController(),
        savedBallDockEdge: savedEdge,
        savedBallOffset: savedOffset,
        onBallPositionChanged: (edge, offset) {
          _database?.settings.write('ball_dock_edge', edge.name);
          _database?.settings.write(
            'ball_dock_offset',
            offset.toStringAsFixed(1),
          );
        },
        // Panel edge resizing: restore each panel's user-chosen size on
        // startup and persist changes while it is open.
        initialPanelSizes: _readPanelSizes(_database!),
        onPanelResized: _writePanelSize,
        initialPinnedCategories: _readPinnedCategories(_database!),
        onPinnedCategoryChanged: _writePinnedCategory,
        accountController: accountController,
        syncController: _syncController,
        storageTransactionRunner: _database!.writeTransaction,
        storageWriteLockWaits: _database!.writeLockWaits,
        readStorageDataVersion: _database!.readDataVersion,
        cloudPortalUrl: _cloudPortalUrl,
        feedbackApi: FeedbackApi(baseUri: Uri.parse(_apiBaseUrl)),
        appUpdateController: appUpdateController,
        initialLanguage: language,
        onLanguageChanged: (language) {
          _database?.settings.setUiLanguage(language);
          unawaited(_languageChannel.setLanguage(language));
        },
      ),
    );
  } on Object catch (error, stackTrace) {
    debugPrint('Failed to open Jianhe database: $error\n$stackTrace');
    // debugPrint is invisible in release builds; without error.log a failed
    // upgrade looked like "the new version never took effect".
    _logStartupError('Failed to open Jianhe database', error, stackTrace);
    // The setting is unreadable here; only a fresh installer choice is known.
    // The switch in More is not offered because it could not be saved.
    final language = installerLanguage ?? AppLanguage.fallback;
    final strings = AppStrings.forLanguage(language);
    unawaited(_languageChannel.setLanguage(language));
    runApp(
      JianheApp(
        initialLanguage: language,
        startupNotice: JianheStorageDatabase.isLockedError(error)
            ? strings.startupDatabaseLocked
            : strings.startupDatabaseFailed(_errorLogPath()),
        localStorageUnavailable: true,
        windowController: NativeBallWindowController(),
        accountController: accountController,
        cloudPortalUrl: _cloudPortalUrl,
        feedbackApi: FeedbackApi(baseUri: Uri.parse(_apiBaseUrl)),
        appUpdateController: appUpdateController,
      ),
    );
  }
}
