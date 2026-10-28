import 'package:flutter/material.dart';
import 'package:jianhe_core/jianhe_core.dart';

import 'features/ball/ball_arc_calculator.dart';
import 'features/ball/ball_home_page.dart';
import 'features/account/account_session_controller.dart';
import 'features/app_update/app_update_controller.dart';
import 'features/cloud_sync/sync_controller.dart';
import 'features/feedback/feedback_api.dart';
import 'l10n/app_language_scope.dart';
import 'l10n/app_strings.dart';
import 'platform/backup_file_service.dart';
import 'platform/ball_window_controller.dart';
import 'platform/global_hot_key.dart';
import 'platform/skill_import_service.dart';

class JianheApp extends StatefulWidget {
  const JianheApp({
    super.key,
    this.repository,
    this.skillPackages,
    this.initialCliAccessMode = CliAccessMode.disabled,
    this.onCliAccessModeChanged,
    this.initialCliSkillImportEnabled = false,
    this.onCliSkillImportEnabledChanged,
    this.initialAutoCollapseSeconds = 4,
    this.onAutoCollapseSecondsChanged,
    this.initialWakeHotKey = GlobalHotKey.defaultWake,
    this.onWakeHotKeyChanged,
    this.startupNotice,
    this.localStorageUnavailable = false,
    this.windowController = const NoopBallWindowController(),
    this.savedBallDockEdge,
    this.savedBallOffset,
    this.onBallPositionChanged,
    this.initialPanelSizes = const {},
    this.onPanelResized,
    this.initialPinnedCategories = const {},
    this.onPinnedCategoryChanged,
    this.skillImportService = const NativeSkillImportService(),
    this.backupFileService = const BackupFileService(),
    this.accountController,
    this.syncController,
    this.storageTransactionRunner,
    this.storageWriteLockWaits,
    this.readStorageDataVersion,
    this.cloudPortalUrl = 'https://jianhe.neodaas.com/jianhecloud/',
    this.feedbackApi,
    this.appUpdateController,
    this.initialLanguage = AppLanguage.fallback,
    this.onLanguageChanged,
  });

  final ItemRepository? repository;
  final SkillPackageRepository? skillPackages;
  final CliAccessMode initialCliAccessMode;
  final ValueChanged<CliAccessMode>? onCliAccessModeChanged;
  final bool initialCliSkillImportEnabled;
  final ValueChanged<bool>? onCliSkillImportEnabledChanged;
  final int initialAutoCollapseSeconds;
  final ValueChanged<int>? onAutoCollapseSecondsChanged;
  final GlobalHotKey initialWakeHotKey;
  final ValueChanged<GlobalHotKey>? onWakeHotKeyChanged;
  final String? startupNotice;
  final bool localStorageUnavailable;
  final BallWindowController windowController;
  final String? savedBallDockEdge;
  final String? savedBallOffset;
  final void Function(BallDockEdge edge, double offset)? onBallPositionChanged;

  /// Persisted panel sizes keyed by [BallWindowStage.name], in logical pixels.
  final Map<String, Size> initialPanelSizes;

  /// Fired when the native layer reports a new panel size.
  final void Function(String stage, Size size)? onPanelResized;

  /// Persisted pinned category for each material type.
  final Map<ItemType, String> initialPinnedCategories;

  /// Fired when a category is pinned or unpinned for a material type.
  final void Function(ItemType type, String? category)? onPinnedCategoryChanged;
  final SkillImportService skillImportService;
  final BackupFileService backupFileService;
  final AccountSessionController? accountController;
  final SyncController? syncController;
  final StorageTransactionRunner? storageTransactionRunner;
  final Stream<bool>? storageWriteLockWaits;

  /// Reads the storage connection's data_version; see
  /// BallHomePage.readStorageDataVersion.
  final int Function()? readStorageDataVersion;
  final String cloudPortalUrl;
  final FeedbackRemoteDataSource? feedbackApi;
  final AppUpdateController? appUpdateController;

  /// Interface language at startup (the device's `ui_language` setting).
  final AppLanguage initialLanguage;

  /// Persists a language picked in the More panel.
  final ValueChanged<AppLanguage>? onLanguageChanged;

  @override
  State<JianheApp> createState() => _JianheAppState();
}

class _JianheAppState extends State<JianheApp> {
  late AppLanguage _language;

  @override
  void initState() {
    super.initState();
    _language = widget.initialLanguage;
    AppStrings.setCurrentLanguage(_language);
  }

  void _setLanguage(AppLanguage language) {
    if (language == _language) return;
    AppStrings.setCurrentLanguage(language);
    setState(() => _language = language);
    widget.onLanguageChanged?.call(language);
  }

  @override
  Widget build(BuildContext context) {
    const transparentKey = Color(0xFF141311);
    const ink = Color(0xFF292620);
    const pencil = Color(0xFFE96B3A);

    return AppLanguageScope(
      language: _language,
      // Switching is offered only where the choice can be saved.
      onLanguageChanged: widget.onLanguageChanged == null
          ? null
          : _setLanguage,
      child: MaterialApp(
        title: AppStrings.forLanguage(_language).appName,
        debugShowCheckedModeBanner: false,
        color: transparentKey,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: pencil,
            brightness: Brightness.light,
          ),
          scaffoldBackgroundColor: transparentKey,
          textTheme: ThemeData.light().textTheme.apply(
            bodyColor: ink,
            displayColor: ink,
            fontFamilyFallback: const <String>[
              'Microsoft YaHei UI',
              'PingFang SC',
              'Noto Sans CJK SC',
            ],
          ),
        ),
        home: BallHomePage(
          repository: widget.repository,
          skillPackages: widget.skillPackages,
          initialCliAccessMode: widget.initialCliAccessMode,
          onCliAccessModeChanged: widget.onCliAccessModeChanged,
          initialCliSkillImportEnabled: widget.initialCliSkillImportEnabled,
          onCliSkillImportEnabledChanged: widget.onCliSkillImportEnabledChanged,
          initialAutoCollapseSeconds: widget.initialAutoCollapseSeconds,
          onAutoCollapseSecondsChanged: widget.onAutoCollapseSecondsChanged,
          initialWakeHotKey: widget.initialWakeHotKey,
          onWakeHotKeyChanged: widget.onWakeHotKeyChanged,
          windowController: widget.windowController,
          startupNotice: widget.startupNotice,
          localStorageUnavailable: widget.localStorageUnavailable,
          savedBallDockEdge: widget.savedBallDockEdge,
          savedBallOffset: widget.savedBallOffset,
          onBallPositionChanged: widget.onBallPositionChanged,
          initialPanelSizes: widget.initialPanelSizes,
          onPanelResized: widget.onPanelResized,
          initialPinnedCategories: widget.initialPinnedCategories,
          onPinnedCategoryChanged: widget.onPinnedCategoryChanged,
          skillImportService: widget.skillImportService,
          backupFileService: widget.backupFileService,
          accountController: widget.accountController,
          syncController: widget.syncController,
          storageTransactionRunner: widget.storageTransactionRunner,
          storageWriteLockWaits: widget.storageWriteLockWaits,
          readStorageDataVersion: widget.readStorageDataVersion,
          cloudPortalUrl: widget.cloudPortalUrl,
          feedbackApi: widget.feedbackApi,
          appUpdateController: widget.appUpdateController,
        ),
      ),
    );
  }
}
