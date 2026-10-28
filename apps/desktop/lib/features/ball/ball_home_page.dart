import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jianhe_core/jianhe_core.dart';

import '../../l10n/app_language_scope.dart';
import '../../l10n/app_strings.dart';
import '../../platform/ball_window_controller.dart';
import '../../platform/backup_file_service.dart';
import '../../platform/cli_executable_path.dart';
import '../../platform/global_hot_key.dart';
import '../../platform/skill_import_service.dart';
import '../../platform/external_url_launcher.dart';
import '../account/account_panel.dart';
import '../app_update/app_update_controller.dart';
import '../account/account_session_controller.dart';
import '../cloud_sync/sync_controller.dart';
import '../feedback/feedback_api.dart';
import '../feedback/feedback_controller.dart';
import '../feedback/feedback_panel.dart';
import '../help/cli_help_panel.dart';
import '../skills/skill_package_browser.dart';
import '../workspace/demo_items.dart';
import 'ball_arc_calculator.dart';

typedef StorageTransactionRunner =
    Future<T> Function<T>(Future<T> Function() action);

enum _BallView {
  collapsed,
  menu,
  composer,
  prompts,
  skills,
  materialDetail,
  snippets,
  editor,
  settings,
  account,
  feedback,
  cliHelp,
}

/// Interaction states of the floating ball. Transitions between these states
/// are guarded so that, for example, a drag can never open the menu and the
/// menu cannot be toggled twice while an expand/collapse animation runs.
enum _BallInteractionState { idle, dragging, snapping, expanded, collapsing }

enum _CategoryAction { create, rename, clear }

enum _SkillCreateAction { directory, file, manual }

enum _EditorSaveStatus { saved, modified, deleted, categoryMissing }

/// Lowercased title/category/content of one item, kept alive between
/// keystrokes and invalidated by identity when any source string changes.
class _ItemSearchIndex {
  _ItemSearchIndex(JianheItem item)
    : titleSource = item.title,
      categorySource = item.category,
      contentSource = item.content,
      title = item.title.toLowerCase(),
      category = item.category.toLowerCase(),
      content = item.content.toLowerCase();

  final String titleSource;
  final String categorySource;
  final String contentSource;
  final String title;
  final String category;
  final String content;

  /// Unchanged items keep their exact string instances across rebuilds, so
  /// identity comparison invalidates the cache without re-reading strings.
  bool isStaleFor(JianheItem item) =>
      !identical(titleSource, item.title) ||
      !identical(categorySource, item.category) ||
      !identical(contentSource, item.content);

  /// Relevance rank for [query]; null when nothing matches anywhere.
  int? rankFor(String query) {
    if (title == query) return 0;
    if (title.startsWith(query)) return 1;
    if (title.contains(query)) return 2;
    if (category.contains(query)) return 3;
    if (content.contains(query)) return 4;
    return null;
  }
}

class BallHomePage extends StatefulWidget {
  const BallHomePage({
    super.key,
    required this.windowController,
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
  });

  final BallWindowController windowController;
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
  final String? savedBallDockEdge;
  final String? savedBallOffset;
  final void Function(BallDockEdge edge, double offset)? onBallPositionChanged;

  /// Persisted panel sizes keyed by [BallWindowStage.name] (e.g. "composer"),
  /// in logical pixels. Applied to every panel view that maps to the stage.
  final Map<String, Size> initialPanelSizes;

  /// Fired whenever the native layer reports a new panel size, so the host can
  /// persist it per stage across restarts.
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

  /// True while a save waits for a write lock another process (the jianhe
  /// CLI, the background sync worker) holds; see
  /// JianheStorageDatabase.writeLockWaits.
  final Stream<bool>? storageWriteLockWaits;

  /// Reads the storage connection's `PRAGMA data_version`, which changes only
  /// when another process (the jianhe CLI, a background sync worker)
  /// commits. Polled while a panel is open so their writes show up and get
  /// pushed without waiting for the next scheduled sync.
  final int Function()? readStorageDataVersion;
  final String cloudPortalUrl;
  final FeedbackRemoteDataSource? feedbackApi;

  /// Self-update state shown on the 更多 page; null in builds without it.
  final AppUpdateController? appUpdateController;

  @override
  State<BallHomePage> createState() => _BallHomePageState();
}

class _BallHomePageState extends State<BallHomePage>
    with TickerProviderStateMixin {
  /// Strings for callbacks and helpers. Always the language JianheApp shows;
  /// [didChangeDependencies] subscribes to changes so the panel rebuilds.
  AppStrings get _s => AppStrings.current;
  AppLanguage? _language;
  static const _transparentKey = Color(0xFF141311);
  static const _ink = Color(0xFF2A2722);
  static const _paper = Color(0xFFFFFCF5);
  static const _paperEdge = Color(0xFFE7DDCF);
  static const _orange = Color(0xFFEA6A39);
  static const _green = Color(0xFF32765B);

  static const _arcConfig = BallArcConfig.standard;
  static const _quickMenuWidth = 220.0;
  static const _quickMenuActionHeight = 44.0;
  static const _quickMenuActionGap = 8.0;
  static const _quickMenuEdgeGap = 8.0;
  static const _nativePanelMenuExitDuration = Duration(milliseconds: 180);
  late final String _cliExecutablePath = resolveCliExecutablePath();

  // Panel resize grips. The docked side (where the ball strip sits) never
  // shows a handle: stretching it would detach the host from the screen edge
  // and strand the ball. The 24 px ClipRRect radius of the panel is larger
  // than the grip, so corner handles are inset to stay inside the rounded
  // region that the native layer clips the host to.
  static const _resizeGrip = 8.0;
  static const _resizeCorner = 32.0;
  static const _minPanelWidth = 320.0;
  static const _minPanelHeight = 400.0;
  static const _legacyBrowserPanelSize = Size(440, 570);
  static const _categoryChipWidth = 96.0;
  static const _categoryChipHeight = 34.0;
  static const _categoryChipLabelWidth = 80.0;
  static const _categoryChipGap = 2.0;

  static const _panelViews = <_BallView>[
    _BallView.composer,
    _BallView.prompts,
    _BallView.skills,
    _BallView.materialDetail,
    _BallView.snippets,
    _BallView.editor,
    _BallView.settings,
    _BallView.account,
    _BallView.feedback,
    _BallView.cliHelp,
  ];

  static const _menuActions =
      <({IconData icon, Color color, _BallView target})>[
        (
          icon: Icons.auto_awesome_rounded,
          color: Color(0xFFEA6A39),
          target: _BallView.composer,
        ),
        (
          icon: Icons.chat_bubble_outline_rounded,
          color: Color(0xFFD98C31),
          target: _BallView.prompts,
        ),
        (
          icon: Icons.description_outlined,
          color: Color(0xFF4C72B8),
          target: _BallView.skills,
        ),
        (
          icon: Icons.text_snippet_outlined,
          color: Color(0xFF34785C),
          target: _BallView.snippets,
        ),
        (
          icon: Icons.add_rounded,
          color: Color(0xFF9A5C8F),
          target: _BallView.editor,
        ),
        (
          icon: Icons.more_horiz_rounded,
          color: Color(0xFF5D5952),
          target: _BallView.settings,
        ),
      ];

  /// Same labels as the native orbit (windows/runner/native_orbit_window.cpp).
  String _menuLabel(_BallView target) => switch (target) {
    _BallView.composer => _s.menuCompose,
    _BallView.prompts => _s.typeName(ItemType.prompt),
    _BallView.skills => _s.typeName(ItemType.skill),
    _BallView.snippets => _s.typeName(ItemType.snippet),
    _BallView.editor => _s.menuNew,
    _ => _s.menuMore,
  };

  // --- controllers ---
  final _inputController = TextEditingController();
  final _searchController = TextEditingController();
  final _editorTitleController = TextEditingController();
  final _editorContentController = TextEditingController();
  final _editorCategoryController = TextEditingController();
  final _editorScrollController = ScrollController();
  bool _savingItem = false;
  final _browserScrollController = ScrollController();

  // --- data ---
  List<JianheItem> _items = <JianheItem>[];
  final Map<ItemType, Set<String>> _savedCategories = {
    for (final type in ItemType.values) type: <String>{},
  };

  // --- view state ---
  _BallView _viewState = _BallView.collapsed;

  _BallView get _view => _viewState;

  /// Every view change goes through here so external-change polling runs
  /// exactly while a panel is open.
  set _view(_BallView next) {
    final wasPanel = _panelViews.contains(_viewState);
    if (next == _BallView.settings && _viewState != _BallView.settings) {
      // Decided once per visit: the entry never jumps while the page is open.
      _appUpdateLeadsSettings = _appUpdateNeedsAttention;
    }
    _viewState = next;
    final isPanel = _panelViews.contains(next);
    if (isPanel && !wasPanel) _startExternalChangePolling();
    if (!isPanel && wasPanel) _stopExternalChangePolling();
  }

  // --- external change detection ---
  static const _externalChangePollInterval = Duration(seconds: 2);
  Timer? _externalChangeTimer;
  int? _lastDataVersion;
  bool _externalRefreshPending = false;

  /// Editable fields of the item as the editor loaded it. A save compares
  /// them with the stored row to detect edits made elsewhere meanwhile;
  /// rating and usage are excluded since they change without the editor.
  ({ItemType type, String title, String content, String category})?
  _editingBase;
  CliAccessMode _cliAccessMode = CliAccessMode.disabled;
  ItemType _browserType = ItemType.prompt;
  ItemType _editorType = ItemType.prompt;
  ItemSortMode _sortMode = ItemSortMode.smart;
  int? _ratingFilter;
  String? _selectedCategory;
  bool _categoriesExpanded = false;
  late final Map<ItemType, String> _pinnedCategories;
  String? _editingItemId;
  Future<List<SkillFileMetadata>>? _editingSkillFiles;
  String? _selectedPromptId;
  JianheItem? _selectedMaterial;
  String _result = '';
  String? _notice;
  Timer? _noticeTimer;
  bool _wakeHotKeyAvailable = true;
  bool _wakeHotKeySaving = false;
  late GlobalHotKey _wakeHotKey;
  Timer? _autoCollapseTimer;
  StreamSubscription<BallWindowEvent>? _windowEventSubscription;
  StreamSubscription<bool>? _writeLockWaitSubscription;
  late int _autoCollapseSeconds;
  int _activePopupMenus = 0;
  int _activeModalDialogs = 0;
  int _modalDialogSerial = 0;
  final List<int> _modalDialogTokens = <int>[];
  bool _dialogFramePointerInside = false;
  bool _panelResizing = false;
  bool _pointerInside = false;
  bool _loading = true;
  bool _backupBusy = false;
  bool _skillImportBusy = false;
  late final AccountSessionController _accountController;
  late final bool _ownsAccountController;
  late final FeedbackController? _feedbackController;

  // --- ball position ---
  BallDockEdge _dockEdge = BallDockEdge.right;
  double _dockOffset = 0.0; // position along the docked edge
  Offset _ballCenter = Offset.zero;
  Size _windowSize = Size.zero;

  // --- panel sizes ---
  // User-resized panel sizes per _BallView (logical px). Kept in session
  // memory so navigating away and back keeps the size the user chose; the
  // native layer reports live sizes through the resized event.
  final Map<_BallView, Size> _panelSizes = {};
  Timer? _panelResizePersistTimer;

  // --- drag state ---
  bool _isDragging = false;
  Offset _dragStart = Offset.zero;
  Offset _dragStartBall = Offset.zero;
  double _totalDragDistance = 0.0;

  // --- animation ---
  late AnimationController _menuAnimCtrl;
  late AnimationController _snapAnimCtrl;
  bool _menuExpanded = false;
  bool _panelTransitionInProgress = false;
  _BallInteractionState _interaction = _BallInteractionState.idle;
  Offset _snapFrom = Offset.zero;
  Offset _snapTo = Offset.zero;
  int? _hoveredMenuIndex;

  // --- native ball layout (host-relative geometry reported by the native layer)
  BallLayout? _nativeLayout;

  // --- incremental sync ---
  // Tracks the sync controller's remoteDataEpoch so remote changes applied
  // by a background pull/refresh reload the visible item lists.
  int? _observedRemoteEpoch;

  // --- computed ---
  double get _ballRadius => _arcConfig.ballRadius;

  @override
  void initState() {
    super.initState();
    _cliAccessMode = widget.initialCliAccessMode;
    _autoCollapseSeconds = _clampAutoCollapseSeconds(
      widget.initialAutoCollapseSeconds,
    );
    _wakeHotKey = widget.initialWakeHotKey;
    _ownsAccountController = widget.accountController == null;
    _accountController =
        widget.accountController ?? AccountSessionController.unconfigured();
    _feedbackController = widget.feedbackApi == null
        ? null
        : FeedbackController(
            api: widget.feedbackApi!,
            account: _accountController,
          );
    _accountController.addListener(_handleAccountChanged);
    widget.appUpdateController?.addListener(_handleAppUpdateChanged);
    _syncMoreBadge();
    _observedRemoteEpoch = widget.syncController?.remoteDataEpoch;
    widget.syncController?.addListener(_handleSyncControllerChanged);
    _writeLockWaitSubscription = widget.storageWriteLockWaits?.listen((
      waiting,
    ) {
      // The save itself is still pending, not failed: it waits on the event
      // loop, so the panel stays responsive and can say why.
      if (waiting && mounted) {
        _showNotice(_s.noticeDatabaseBusyWaiting);
      }
    });
    unawaited(_accountController.initialize());
    _pinnedCategories = Map<ItemType, String>.from(
      widget.initialPinnedCategories,
    );
    _windowEventSubscription = widget.windowController.events.listen(
      _handleWindowEvent,
    );
    widget.windowController.setCloseRequestHandler(_flushDraftForClose);
    _inputController.addListener(_refreshResult);
    unawaited(_restoreWakeHotKey());

    // Apply persisted per-stage panel sizes (e.g. "composer" -> 520x640).
    // Sizes from a previous session are clamped so a stale value can never
    // produce a panel narrower/taller than the native minimum.
    for (final view in _panelViews) {
      final stage = _stageFor(view);
      final saved = widget.initialPanelSizes[stage.name];
      // Programmatic native resizes could persist the former browser default.
      // Upgrade only that exact value; preserve every user-resized size.
      final persisted =
          stage == BallWindowStage.browser && saved == _legacyBrowserPanelSize
          ? Size(stage.width, stage.height)
          : saved;
      if (persisted != null) {
        _panelSizes[view] = Size(
          persisted.width.clamp(_minPanelWidth, double.infinity),
          persisted.height.clamp(_minPanelHeight, double.infinity),
        );
      }
    }

    // animation controllers
    _menuAnimCtrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _arcConfig.expandDurationMs),
    );
    _menuAnimCtrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() => _menuExpanded = true);
      } else if (status == AnimationStatus.dismissed) {
        setState(() {
          _menuExpanded = false;
          // A drag (native or Flutter) may still be in flight while the menu
          // finishes retracting; keep its state so the snap logic stays valid.
          if (_interaction != _BallInteractionState.dragging &&
              _interaction != _BallInteractionState.snapping) {
            _interaction = _BallInteractionState.idle;
          }
          if (_view == _BallView.menu || _view == _BallView.collapsed) {
            if (_view == _BallView.menu) {
              _view = _BallView.collapsed;
            }
            // Shrink the host back to the ball-only size. Without this the
            // transparent menu-sized host window stays on screen and swallows
            // clicks over a large desktop region. The call is idempotent, so
            // it is safe even when a panel transition already resized the host.
            unawaited(
              widget.windowController.showStage(BallWindowStage.collapsed),
            );
          }
        });
      }
    });

    _snapAnimCtrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _arcConfig.snapDurationMs),
    );
    _snapAnimCtrl.addListener(() {
      if (!mounted) return;
      setState(() {
        final t = Curves.easeOutCubic.transform(_snapAnimCtrl.value);
        _ballCenter = Offset.lerp(_snapFrom, _snapTo, t)!;
      });
    });
    _snapAnimCtrl.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() {
          _ballCenter = _snapTo;
          _interaction = _BallInteractionState.idle;
        });
      }
    });

    // Baseline for external-change detection; changes after this point are
    // picked up when a panel opens.
    _lastDataVersion = _readDataVersion();
    _loadItems();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final language = AppStrings.of(context).language;
    // The compose separator follows the language; rebuild the result so the
    // panel never shows output composed in the previous language.
    if (_language != null && _language != language) {
      _result = _composeResult();
    }
    _language = language;
  }

  @override
  void dispose() {
    _externalChangeTimer?.cancel();
    widget.windowController.setCloseRequestHandler(null);
    _noticeTimer?.cancel();
    _autoCollapseTimer?.cancel();
    _panelResizePersistTimer?.cancel();
    _windowEventSubscription?.cancel();
    _writeLockWaitSubscription?.cancel();
    _inputController
      ..removeListener(_refreshResult)
      ..dispose();
    _searchController.dispose();
    _editorTitleController.dispose();
    _editorContentController.dispose();
    _editorCategoryController.dispose();
    _editorScrollController.dispose();
    _browserScrollController.dispose();
    _accountController.removeListener(_handleAccountChanged);
    widget.appUpdateController?.removeListener(_handleAppUpdateChanged);
    widget.syncController?.removeListener(_handleSyncControllerChanged);
    if (_ownsAccountController) _accountController.dispose();
    _feedbackController?.dispose();
    _menuAnimCtrl.dispose();
    _snapAnimCtrl.dispose();
    super.dispose();
  }

  // ============================================================
  // data loading
  // ============================================================

  Future<void> _loadItems() async {
    try {
      final repository = widget.repository;
      // Every item, not a capped page: browsing, search, filters and custom
      // ordering all run on this list, so anything left out could not be
      // found or edited here. A 500-item cap used to hide exactly the
      // unrated, unused, oldest items (smart order puts them last).
      final items = repository == null
          ? createDemoItems(_s.language)
          : await repository.listAll();
      final categories = {
        for (final type in ItemType.values)
          type: repository == null
              ? _categoriesFromItems(items, type)
              : (await repository.listCategories(type)).toSet(),
      };
      if (!mounted) return;
      setState(() {
        _items = List<JianheItem>.from(items);
        for (final entry in categories.entries) {
          _savedCategories[entry.key]!
            ..clear()
            ..addAll(entry.value);
        }
        _selectedPromptId = _firstPromptId(items);
        _loading = false;
      });
      _restoreBallPosition();
      if (widget.startupNotice != null) _showNotice(widget.startupNotice!);
    } on Object {
      // A failed read must never surface demo items: editing one would save
      // demo content into the real repository. Demo data stays limited to the
      // repository-less demo mode handled in the try block.
      if (!mounted) return;
      setState(() {
        _items = <JianheItem>[];
        for (final type in ItemType.values) {
          _savedCategories[type]!.clear();
        }
        _selectedPromptId = null;
        _loading = false;
      });
      _restoreBallPosition();
      _showNotice(_s.noticeItemsUnreadable);
    }
  }

  Future<void> _refreshItems() async {
    final repository = widget.repository;
    if (repository == null) return;
    try {
      final items = await repository.listAll();
      final categories = {
        for (final type in ItemType.values)
          type: (await repository.listCategories(type)).toSet(),
      };
      if (!mounted) return;
      var selectedRemoved = false;
      setState(() {
        _items = List<JianheItem>.from(items);
        for (final entry in categories.entries) {
          _savedCategories[entry.key]!
            ..clear()
            ..addAll(entry.value);
        }
        if (_selectedPromptId == null ||
            !items.any((item) => item.id == _selectedPromptId)) {
          _selectedPromptId = _firstPromptId(items);
        }
        // The detail panel holds its own copy; point it at the fresh row.
        final selected = _selectedMaterial;
        if (selected != null) {
          JianheItem? fresh;
          for (final item in items) {
            if (item.id == selected.id) {
              fresh = item;
              break;
            }
          }
          _selectedMaterial = fresh;
          selectedRemoved = fresh == null;
        }
      });
      if (selectedRemoved && _view == _BallView.materialDetail) {
        _showNotice(_s.noticeItemDeletedElsewhere);
        unawaited(_go(_browserViewFor(_browserType)));
      }
    } on Object {
      if (mounted) _showNotice(_s.noticeRefreshFailed);
    }
  }

  int? _readDataVersion() {
    final read = widget.readStorageDataVersion;
    if (read == null) return null;
    try {
      return read();
    } on Object {
      return null; // Transient lock or closed database; try again later.
    }
  }

  void _startExternalChangePolling() {
    if (widget.readStorageDataVersion == null) return;
    _externalChangeTimer?.cancel();
    _externalChangeTimer = Timer.periodic(
      _externalChangePollInterval,
      (_) => _checkExternalChanges(),
    );
    // Catch up on writes made while the panel was closed. Deferred because
    // the view setter runs inside setState.
    scheduleMicrotask(_checkExternalChanges);
  }

  void _stopExternalChangePolling() {
    _externalChangeTimer?.cancel();
    _externalChangeTimer = null;
  }

  void _checkExternalChanges() {
    if (!mounted) return;
    final version = _readDataVersion();
    if (version == null) return;
    final previous = _lastDataVersion;
    _lastDataVersion = version;
    if (previous != null && previous != version) {
      _externalRefreshPending = true;
      // The CLI journals its writes but cannot wake the sync controller;
      // push them now instead of at the next scheduled sync.
      widget.syncController?.notifyLocalChanged();
    }
    if (!_externalRefreshPending) return;
    // Never swap the list under a save, import or backup merge in flight;
    // the pending flag retries on the next tick.
    if (_savingItem || _skillImportBusy || _backupBusy) return;
    _externalRefreshPending = false;
    unawaited(_refreshItems());
  }

  /// A local write just persisted; schedule the debounced auto-push. The
  /// controller side gates on the auto-sync switch and login state.
  void _touchSync() {
    widget.syncController?.notifyLocalChanged();
  }

  void _handleSyncControllerChanged() {
    final controller = widget.syncController;
    if (controller == null || !mounted) return;
    if (_observedRemoteEpoch == controller.remoteDataEpoch) return;
    _observedRemoteEpoch = controller.remoteDataEpoch;
    unawaited(_refreshItems());
  }

  void _restoreBallPosition() {
    final size = _windowSize;
    if (size == Size.zero) {
      // will be restored in didChangeDependencies via _initBallPosition
      return;
    }
    _initBallPosition(size);
    _restoreNativeBallPosition();
  }

  /// Tells the native ball window to restore a saved dock edge/offset so the
  /// ball reappears where it was before the app restarted.
  void _restoreNativeBallPosition() {
    if (!_isNative) return;
    final savedEdge = widget.savedBallDockEdge;
    final savedOffset = widget.savedBallOffset;
    if (savedEdge == null || savedOffset == null) return;
    final side = switch (savedEdge) {
      'left' => BallDockSide.left,
      'right' => BallDockSide.right,
      'top' => BallDockSide.top,
      'bottom' => BallDockSide.bottom,
      _ => null,
    };
    final parsedOffset = double.tryParse(savedOffset);
    if (side == null || parsedOffset == null) return;
    unawaited(widget.windowController.restorePosition(side, parsedOffset));
  }

  void _initBallPosition(Size size) {
    // try restore from widget params first
    BallDockEdge edge = BallDockEdge.right;
    double offset = size.height * 0.5;

    if (widget.savedBallDockEdge != null) {
      edge = BallDockEdge.values.firstWhere(
        (e) => e.name == widget.savedBallDockEdge,
        orElse: () => BallDockEdge.right,
      );
    }
    if (widget.savedBallOffset != null) {
      final parsed = double.tryParse(widget.savedBallOffset!);
      if (parsed != null && parsed > 0) offset = parsed;
    }

    _dockEdge = edge;
    _dockOffset = offset.clamp(_ballRadius, _edgeMax(size, edge));
    _ballCenter = BallArcCalculator.snapToEdge(
      Offset(_dockOffset, _dockOffset),
      _dockEdge,
      size,
      ballRadius: _ballRadius,
    );
    // correct: snapToEdge uses the right coordinate for the edge
    _ballCenter = _snappedCenter(edge, _dockOffset, size);
  }

  Offset _snappedCenter(BallDockEdge edge, double offset, Size size) {
    final r = _ballRadius;
    return switch (edge) {
      BallDockEdge.left => Offset(r, offset.clamp(r, size.height - r)),
      BallDockEdge.right => Offset(
        size.width - r,
        offset.clamp(r, size.height - r),
      ),
      BallDockEdge.top => Offset(offset.clamp(r, size.width - r), r),
      BallDockEdge.bottom => Offset(
        offset.clamp(r, size.width - r),
        size.height - r,
      ),
    };
  }

  double _edgeMax(Size size, BallDockEdge edge) => switch (edge) {
    BallDockEdge.left || BallDockEdge.right => size.height,
    BallDockEdge.top || BallDockEdge.bottom => size.width,
  };

  void _persistPosition() {
    widget.onBallPositionChanged?.call(_dockEdge, _dockOffset);
  }

  // ============================================================
  // helpers (unchanged from original)
  // ============================================================

  Set<String> _categoriesFromItems(List<JianheItem> items, ItemType type) {
    return items
        .where((item) => item.type == type && item.category.isNotEmpty)
        .map((item) => item.category)
        .toSet();
  }

  String? _firstPromptId(List<JianheItem> items) {
    for (final item in items) {
      if (item.type == ItemType.prompt) return item.id;
    }
    return null;
  }

  JianheItem? get _selectedPrompt {
    for (final item in _items) {
      if (item.id == _selectedPromptId && item.type == ItemType.prompt) {
        return item;
      }
    }
    return null;
  }

  List<JianheItem> get _browserItems {
    final query = _searchController.text.trim().toLowerCase();
    // Ranks are computed once per item here instead of inside the sort
    // comparator (~2·n·log₂n calls, each lowercasing title and category).
    final rankById = query.isEmpty ? null : <String, int>{};
    final matched = <JianheItem>[];
    for (final item in _items) {
      if (item.type != _browserType) continue;
      if (_selectedCategory != null && item.category != _selectedCategory) {
        continue;
      }
      if (!_matchesRatingFilter(item.rating)) continue;
      if (query.isEmpty) {
        matched.add(item);
        continue;
      }
      final index = _searchIndexFor(item);
      final rank = index.rankFor(query);
      if (rank == null) continue;
      rankById![item.id] = rank;
      matched.add(item);
    }
    matched.sort((a, b) => _compareBrowserItems(a, b, rankById));
    return matched;
  }

  bool _matchesRatingFilter(int rating) {
    final filter = _ratingFilter;
    if (filter == null) return true;
    if (filter == 0) return rating == 0;
    return rating > 0 && rating <= filter;
  }

  List<String> get _browserCategories {
    final categories = {
      ...?_savedCategories[_browserType],
      ..._categoriesFromItems(_items, _browserType),
    }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final pinned = _pinnedCategories[_browserType];
    if (pinned != null && categories.remove(pinned)) {
      categories.insert(0, pinned);
    }
    return categories;
  }

  List<String> _visibleBrowserCategories(List<String> categories) {
    if (_categoriesExpanded || categories.length <= 3) return categories;
    final selected = _selectedCategory;
    final selectedIndex = selected == null || selected.isEmpty
        ? -1
        : categories.indexOf(selected);
    if (selectedIndex < 0) {
      return categories.take(3).toList();
    }

    // Keep exactly three categories in view and slide the window so the
    // selected category is centered whenever it has neighbors on both sides.
    var start = selectedIndex - 1;
    if (start < 0) start = 0;
    final maxStart = categories.length - 3;
    if (start > maxStart) start = maxStart;
    return categories.sublist(start, start + 3);
  }

  String _categoryDisplayName(String category) {
    final codePoints = category.runes.toList(growable: false);
    if (codePoints.length <= 4) return category;
    return String.fromCharCodes(codePoints.take(4));
  }

  Widget _buildCategoryChip({
    required Key key,
    required String category,
    required bool selected,
    required ValueChanged<bool> onSelected,
    double width = _categoryChipWidth,
    void Function(TapDownDetails)? onSecondaryTapDown,
  }) {
    final isPinned = _pinnedCategories[_browserType] == category;
    final chip = SizedBox(
      width: width,
      height: _categoryChipHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          SizedBox.expand(
            child: ChoiceChip(
              label: SizedBox(
                width: math.min(_categoryChipLabelWidth, width - 12),
                child: Text(
                  _categoryDisplayName(category),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  textAlign: TextAlign.center,
                  style: const TextStyle(letterSpacing: 0.6),
                ),
              ),
              selected: selected,
              showCheckmark: false,
              onSelected: onSelected,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              labelPadding: EdgeInsets.zero,
            ),
          ),
          if (isPinned)
            const Positioned(
              top: -2,
              right: -2,
              child: IgnorePointer(
                child: Icon(Icons.push_pin_rounded, size: 12),
              ),
            ),
        ],
      ),
    );
    return Tooltip(
      message: category,
      waitDuration: const Duration(milliseconds: 450),
      child: GestureDetector(
        key: key,
        onSecondaryTapDown: onSecondaryTapDown,
        child: chip,
      ),
    );
  }

  void _selectBrowserCategory(String? category) {
    setState(() {
      _selectedCategory = category;
      _categoriesExpanded = false;
    });
  }

  bool _blockPersistentMutation() {
    if (!widget.localStorageUnavailable) return false;
    _showNotice(_s.noticeReadOnlyDemo);
    return true;
  }

  void _togglePinnedCategory(String category) {
    if (_blockPersistentMutation()) return;
    final type = _browserType;
    final isPinned = _pinnedCategories[type] == category;
    setState(() {
      if (isPinned) {
        _pinnedCategories.remove(type);
      } else {
        _pinnedCategories[type] = category;
      }
      _categoriesExpanded = false;
    });
    widget.onPinnedCategoryChanged?.call(type, isPinned ? null : category);
    _showNotice(
      isPinned
          ? _s.noticeCategoryUnpinned(category)
          : _s.noticeCategoryPinned(category),
      success: true,
    );
  }

  Future<void> _showCategoryContextMenu(
    String category,
    Offset globalPosition,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = overlay.globalToLocal(globalPosition);
    _beginPopupMenuInteraction();
    final shouldToggle = await showMenu<bool>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      items: [
        PopupMenuItem<bool>(
          key: const Key('toggle-pinned-category'),
          value: true,
          child: Row(
            children: [
              Icon(
                _pinnedCategories[_browserType] == category
                    ? Icons.push_pin_outlined
                    : Icons.push_pin_rounded,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                _pinnedCategories[_browserType] == category
                    ? _s.unpinCategory
                    : _s.pinCategory,
              ),
            ],
          ),
        ),
      ],
    );
    _endPopupMenuInteraction();
    if (mounted && shouldToggle == true) {
      _togglePinnedCategory(category);
    }
  }

  List<String> get _editorCategories {
    final categories = {
      ...?_savedCategories[_editorType],
      ..._categoriesFromItems(_items, _editorType),
    }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return categories;
  }

  int _compareBrowserItems(JianheItem a, JianheItem b, Map<String, int>? rankById) {
    final ratingFilter = _ratingFilter;
    if (ratingFilter != null && ratingFilter > 0) {
      final rating = b.rating.compareTo(a.rating);
      if (rating != 0) return rating;
    }
    if (rankById != null) {
      final relevance = rankById[a.id]!.compareTo(rankById[b.id]!);
      if (relevance != 0) return relevance;
    }
    final result = switch (_sortMode) {
      ItemSortMode.smart => _compareSmart(a, b),
      ItemSortMode.custom => a.sortOrder.compareTo(b.sortOrder),
      ItemSortMode.recentlyUsed => _compareNullableDate(
        a.lastUsedAt,
        b.lastUsedAt,
      ),
      ItemSortMode.mostUsed => b.useCount.compareTo(a.useCount),
      ItemSortMode.rating => b.rating.compareTo(a.rating),
      ItemSortMode.recentlyUpdated => b.updatedAt.compareTo(a.updatedAt),
      ItemSortMode.title => _searchIndexFor(a).title.compareTo(
        _searchIndexFor(b).title,
      ),
    };
    if (result != 0) return result;
    return b.updatedAt.compareTo(a.updatedAt);
  }

  int _compareSmart(JianheItem a, JianheItem b) {
    final rating = b.rating.compareTo(a.rating);
    if (rating != 0) return rating;
    final lastUsed = _compareNullableDate(a.lastUsedAt, b.lastUsedAt);
    if (lastUsed != 0) return lastUsed;
    final usage = b.useCount.compareTo(a.useCount);
    if (usage != 0) return usage;
    return b.updatedAt.compareTo(a.updatedAt);
  }

  int _compareNullableDate(DateTime? first, DateTime? second) {
    if (first == null && second == null) return 0;
    if (first == null) return 1;
    if (second == null) return -1;
    return second.compareTo(first);
  }

  /// Per-item lowercase search index, computed once per item revision.
  /// Search runs on every keystroke over up to 500 items whose content can
  /// be tens of KB; lowercasing everything per keystroke (per comparison,
  /// even) visibly janks the panel.
  final Map<String, _ItemSearchIndex> _searchIndexById = {};

  _ItemSearchIndex _searchIndexFor(JianheItem item) {
    final cached = _searchIndexById[item.id];
    if (cached != null && !cached.isStaleFor(item)) return cached;
    if (_searchIndexById.length > 1000) _searchIndexById.clear();
    final index = _ItemSearchIndex(item);
    _searchIndexById[item.id] = index;
    return index;
  }

  // ============================================================
  // view navigation
  // ============================================================

  BallWindowStage _stageFor(_BallView view) => switch (view) {
    _BallView.collapsed => BallWindowStage.collapsed,
    _BallView.menu => BallWindowStage.menu,
    _BallView.composer => BallWindowStage.composer,
    _BallView.prompts ||
    _BallView.skills ||
    _BallView.materialDetail ||
    _BallView.snippets => BallWindowStage.browser,
    _BallView.editor => BallWindowStage.editor,
    _BallView.settings => BallWindowStage.settings,
    _BallView.account => BallWindowStage.settings,
    _BallView.feedback => BallWindowStage.settings,
    _BallView.cliHelp => BallWindowStage.browser,
  };

  /// The logical size the native host should use for [view]: the user-resized
  /// panel size when one exists, otherwise the stage's default size.
  Size _panelSizeFor(_BallView view) {
    final stage = _stageFor(view);
    return _panelSizes[view] ?? Size(stage.width, stage.height);
  }

  /// Whether [_go] would accept a navigation to [next] right now. Menu and
  /// panel transitions reject concurrent navigations; callers that commit
  /// UI state before navigating must probe first or the state lands without
  /// the navigation ever running.
  bool _canNavigateTo(_BallView next) {
    if (next == _view && next != _BallView.collapsed) return false;
    if (_panelTransitionInProgress) return false;
    if (_interaction == _BallInteractionState.collapsing) return false;
    return true;
  }

  Future<void> _go(_BallView next) async {
    if (!_canNavigateTo(next)) return;

    if (next == _BallView.collapsed) {
      _autoCollapseTimer?.cancel();
    }

    // Open the compact action menu.
    if (next == _BallView.menu) {
      await _expandMenu();
      return;
    }

    // Let the action menu retract before the window shrinks back to the
    // ball-only size, so the animation stays smooth.
    if (next == _BallView.collapsed && _menuVisible) {
      await widget.windowController.setExpanded(false);
      _menuAnimCtrl.reverse();
      if (mounted) {
        setState(() => _interaction = _BallInteractionState.collapsing);
      }
      await Future<void>.delayed(
        Duration(milliseconds: _arcConfig.collapseDurationMs + 40),
      );
    }

    // Navigate to a real panel after the native constellation has reached the
    // main ball.
    final transitioningFromMenu = next != _BallView.collapsed && _menuVisible;
    if (transitioningFromMenu) {
      _panelTransitionInProgress = true;
      if (mounted) {
        setState(() {
          _view = next;
          _interaction = _BallInteractionState.collapsing;
        });
      }
      await widget.windowController.setExpanded(false);
      _menuAnimCtrl.reverse();
      // The native orbit is rendered in the menu-sized host coordinate space.
      // Let it reach the main ball before resizing to the target panel, or its
      // remaining sub-balls would be rescaled by the larger panel host.
      if (_isNative) {
        await Future<void>.delayed(_nativePanelMenuExitDuration);
      }
    }
    if (mounted && _view != next) setState(() => _view = next);
    // Let the target view complete its Flutter frame before asking the native
    // side to expose the D3D host. The native side installs its clip while the
    // host is still transparent, so this frame is ready when the host appears.
    await WidgetsBinding.instance.endOfFrame;
    try {
      await widget.windowController.showStage(
        _stageFor(next),
        size: _panelSizeFor(next),
      );
      if (!mounted) return;
    } on PlatformException {
      // Widget tests and unsupported hosts deliberately have no native channel.
    } finally {
      if (transitioningFromMenu) {
        _panelTransitionInProgress = false;
      }
    }
  }

  bool get _menuVisible => _menuExpanded || _menuAnimCtrl.isAnimating;

  bool get _isNative => widget.windowController.usesNativeBall;

  static BallDockEdge _edgeFromSide(BallDockSide side) => switch (side) {
    BallDockSide.left => BallDockEdge.left,
    BallDockSide.right => BallDockEdge.right,
    BallDockSide.top => BallDockEdge.top,
    BallDockSide.bottom => BallDockEdge.bottom,
  };

  /// Opens the compact action menu. The native stage is resized first so the
  /// menu can stay attached to the real ball position.
  Future<void> _expandMenu() async {
    if (_interaction == _BallInteractionState.dragging ||
        _interaction == _BallInteractionState.snapping) {
      // never expand while the ball is being dragged or snapped
      return;
    }
    if (_menuExpanded || _menuAnimCtrl.isAnimating) return;

    setState(() {
      _view = _BallView.menu;
      _interaction = _BallInteractionState.expanded;
    });
    try {
      await widget.windowController.showStage(BallWindowStage.menu);
    } on PlatformException {
      // Native window not available; the Flutter menu still works.
    }
    // Re-anchor the menu to the real ball position after the stage resize.
    await _syncNativeLayout();
    if (!mounted) return;
    await widget.windowController.setExpanded(true);
    _menuAnimCtrl.forward();
  }

  /// Collapses the action menu.
  Future<void> _collapseMenu() async {
    if (!_menuVisible) return;
    if (mounted) {
      setState(() => _interaction = _BallInteractionState.collapsing);
    }
    await widget.windowController.setExpanded(false);
    _menuAnimCtrl.reverse();
    // keep waiting for the reverse animation in case callers chain awaits
    await Future<void>.delayed(
      Duration(milliseconds: _arcConfig.collapseDurationMs + 60),
    );
  }

  /// Refreshes [_nativeLayout] from the native layer so the Flutter menu can
  /// anchor to the real ball position (host-relative logical pixels).
  Future<void> _syncNativeLayout() async {
    if (!_isNative) return;
    final layout = await widget.windowController.getBallLayout();
    if (!mounted || layout == null) return;
    setState(() {
      _nativeLayout = layout;
      _dockEdge = _edgeFromSide(layout.side);
      _dockOffset = layout.offset;
    });
  }

  // ============================================================
  // drag handling
  // ============================================================

  void _handleBallTap() {
    if (_menuVisible) {
      _collapseMenu();
    } else {
      _expandMenu();
    }
  }

  void _handleBallPanStart(DragStartDetails details) {
    // dragging always retracts an already expanded menu first
    if (_menuVisible) {
      _collapseMenu();
    }
    _snapAnimCtrl.stop();
    setState(() {
      _isDragging = true;
      _interaction = _BallInteractionState.dragging;
      _dragStart = details.globalPosition;
      _dragStartBall = _ballCenter;
      _totalDragDistance = 0.0;
    });
  }

  void _handleBallPanUpdate(DragUpdateDetails details) {
    if (!_isDragging) return;
    final delta = details.globalPosition - _dragStart;
    _totalDragDistance = delta.distance;
    setState(() {
      _ballCenter = Offset(
        (_dragStartBall.dx + delta.dx).clamp(0.0, _windowSize.width),
        (_dragStartBall.dy + delta.dy).clamp(0.0, _windowSize.height),
      );
    });
  }

  void _handleBallPanEnd(DragEndDetails details) {
    if (!_isDragging) return;
    setState(() => _isDragging = false);

    if (_totalDragDistance >= _arcConfig.dragThreshold) {
      _snapToNearestEdge();
    } else {
      // sub-threshold movement is treated as a click: back to idle
      setState(() => _interaction = _BallInteractionState.idle);
    }
  }

  void _snapToNearestEdge() {
    final size = _windowSize;
    if (size == Size.zero) return;

    final edge = BallArcCalculator.nearestEdge(
      _ballCenter,
      size,
      snapThreshold: _arcConfig.snapThreshold,
    );

    final target = BallArcCalculator.snapToEdge(
      _ballCenter,
      edge,
      size,
      ballRadius: _ballRadius,
    );

    setState(() {
      _dockEdge = edge;
      _dockOffset = switch (edge) {
        BallDockEdge.left || BallDockEdge.right => target.dy,
        BallDockEdge.top || BallDockEdge.bottom => target.dx,
      };
      _interaction = _BallInteractionState.snapping;
      _snapFrom = _ballCenter;
      _snapTo = target;
    });

    _snapAnimCtrl
      ..reset()
      ..forward();
    _persistPosition();
  }

  // ============================================================
  // window events from native layer
  // ============================================================

  void _handleWindowEvent(BallWindowEvent event) {
    switch (event.type) {
      case BallWindowEventType.hotkey:
        widget.syncController?.notifyForeground();
        if (_view == _BallView.collapsed && !_menuVisible) {
          _expandMenu();
        }
      case BallWindowEventType.hotkeyUnavailable:
        if (mounted) {
          setState(() => _wakeHotKeyAvailable = false);
        }
        if (_view != _BallView.collapsed && _view != _BallView.menu) {
          // Name the user's actual binding — the default combo would point
          // them at the wrong key when they re-bound the hotkey.
          _showNotice(_s.noticeHotKeyTaken(_wakeHotKey.displayLabel));
        }
      case BallWindowEventType.tap:
        widget.syncController?.notifyForeground();
        if (_interaction == _BallInteractionState.dragging ||
            _interaction == _BallInteractionState.snapping) {
          // A previous drag finished without a matching `moved:` event;
          // recover the state machine so the ball keeps responding.
          _interaction = _BallInteractionState.idle;
        }
        if (_view == _BallView.collapsed && !_menuExpanded) {
          _expandMenu();
        } else if (_menuExpanded || _menuAnimCtrl.isAnimating) {
          _collapseMenu();
        } else {
          _go(_BallView.collapsed);
        }
      case BallWindowEventType.dragStart:
        // native ball started dragging: retract the menu before movement
        _collapseMenu();
        if (mounted) {
          setState(() => _interaction = _BallInteractionState.dragging);
        }
      case BallWindowEventType.secondaryTap:
        _go(_BallView.settings);
      case BallWindowEventType.enter:
        _handlePointerEnter(const PointerEnterEvent());
      case BallWindowEventType.exit:
        _handlePointerExit(const PointerExitEvent());
      case BallWindowEventType.moved:
        _handleNativeMoved(event);
      case BallWindowEventType.resized:
        _handlePanelResized(event.size);
      case BallWindowEventType.resizeStart:
        // The native layer entered a modal move/resize loop (ball drag or
        // panel edge resize); the pointer may no longer be tracked by the
        // Flutter view, so suspend the auto-collapse timer until it exits.
        // Edge resizing is a page interaction: exit events raised from
        // inside the untracked loop must not re-arm the countdown either.
        _panelResizing = true;
        _autoCollapseTimer?.cancel();
      case BallWindowEventType.resizeEnd:
        _panelResizing = false;
        // The sizing loop ends with the cursor riding the dragged edge,
        // over the in-window grip strip — still on the page, not outside.
        // The MouseRegion state went stale during the loop, so treat the
        // pointer as inside; a later real exit restarts the countdown.
        _handlePointerEnter(const PointerEnterEvent());
      case BallWindowEventType.compose:
        _handleMenuAction(0);
      case BallWindowEventType.prompts:
        _handleMenuAction(1);
      case BallWindowEventType.skills:
        _handleMenuAction(2);
      case BallWindowEventType.snippets:
        _handleMenuAction(3);
      case BallWindowEventType.create:
        _handleMenuAction(4);
      case BallWindowEventType.more:
        _handleMenuAction(5);
      case BallWindowEventType.backgroundSync:
        unawaited(widget.syncController?.requestAutomaticSync());
    }
  }

  Future<void> _handleNativeMoved(BallWindowEvent event) async {
    final side = event.side;
    if (side == null) return;
    setState(() {
      final edge = _edgeFromSide(side);
      _dockEdge = edge;
      _interaction = _BallInteractionState.idle;
      if (event.offset != null) {
        _dockOffset = event.offset!;
      }
      // Keep the Flutter-rendered menu anchored to the real ball position even
      // before the native layer reports its layout (used as fallback when
      // getBallLayout is unavailable).
      if (_windowSize != Size.zero) {
        _ballCenter = _snappedCenter(edge, _dockOffset, _windowSize);
      }
    });
    _persistPosition();
    await _syncNativeLayout();
  }

  /// Applies a new host size reported by the native layer after a panel edge
  /// resize, and persists it per stage so the size survives restarts. The
  /// persist is debounced: a resize drag reports every intermediate size, but
  /// the settings write only runs after the drag pauses.
  void _handlePanelResized(Size? size) {
    if (size == null || !mounted) return;
    setState(() {
      _windowSize = size;
      _panelSizes[_view] = size;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(widget.windowController.panelFrameReady(size));
    });
    _panelResizePersistTimer?.cancel();
    final stage = _stageFor(_view).name;
    final latest = size;
    _panelResizePersistTimer = Timer(const Duration(milliseconds: 400), () {
      widget.onPanelResized?.call(stage, latest);
    });
  }

  /// Starts the native modal resize loop for [edge]. The native layer takes
  /// over pointer capture until the user releases, so this is fire-and-forget
  /// from the Flutter side.
  void _beginPanelResize(PanelResizeEdge edge) {
    if (!_isNative) return;
    unawaited(widget.windowController.beginPanelResize(edge));
  }

  void _handleMenuAction(int index) {
    final target = _menuActions[index].target;
    switch (target) {
      case _BallView.composer:
        _go(_BallView.composer);
      case _BallView.prompts:
        _openBrowser(ItemType.prompt);
      case _BallView.skills:
        _openBrowser(ItemType.skill);
      case _BallView.snippets:
        _openBrowser(ItemType.snippet);
      case _BallView.editor:
        _openEditor();
      case _BallView.settings:
        _go(_BallView.settings);
      case _BallView.collapsed ||
          _BallView.menu ||
          _BallView.materialDetail ||
          _BallView.account ||
          _BallView.feedback ||
          _BallView.cliHelp:
        break;
    }
  }

  // ============================================================
  // composition
  // ============================================================

  void _refreshResult() {
    if (!mounted) return;
    setState(() => _result = _composeResult());
  }

  String _composeResult() {
    final prompt = _selectedPrompt;
    if (prompt == null || _inputController.text.trim().isEmpty) return '';
    return CompositionService(
      language: _s.language,
    ).composeItem(prompt: prompt, input: _inputController.text);
  }

  void _selectPrompt(JianheItem item) {
    setState(() => _selectedPromptId = item.id);
    _refreshResult();
  }

  Future<void> _pasteInput() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || data?.text == null) return;
    _inputController.text = data!.text!;
    _inputController.selection = TextSelection.collapsed(
      offset: _inputController.text.length,
    );
  }

  Future<void> _copyResult() async {
    if (_result.isEmpty) {
      _showNotice(_s.noticeComposeNeedsInput);
      return;
    }
    await Clipboard.setData(ClipboardData(text: _result));
    final prompt = _selectedPrompt;
    if (prompt != null) {
      try {
        final used = await widget.repository?.markUsed(prompt.id);
        if (mounted && used != null) {
          setState(() {
            final index = _items.indexWhere((item) => item.id == used.id);
            if (index >= 0) _items[index] = used;
          });
        }
      } on Object catch (error, stackTrace) {
        // The copy itself succeeded; the use-count bump is best-effort.
        debugPrint('markUsed failed: $error\n$stackTrace');
      }
    }
    _showNotice(_s.noticeCopiedToClipboard, success: true);
  }

  Future<void> _copyItem(JianheItem item, {bool showNotice = true}) async {
    await Clipboard.setData(ClipboardData(text: item.content));
    if (showNotice) {
      _showNotice(_s.noticeItemCopied(item.title), success: true);
    }
    try {
      final used = await widget.repository?.markUsed(item.id);
      if (mounted && used != null) {
        setState(() {
          final index = _items.indexWhere((candidate) => candidate.id == item.id);
          if (index >= 0) _items[index] = used;
        });
      }
    } on Object catch (error, stackTrace) {
      // The copy itself succeeded; the use-count bump is best-effort.
      debugPrint('markUsed failed: $error\n$stackTrace');
    }
  }

  Future<void> _setRating(JianheItem item, int rating) async {
    if (_blockPersistentMutation()) return;
    final repository = widget.repository;
    JianheItem? updated;
    try {
      // The repository writes only the rating fields and returns the row as
      // stored. Saving `item` (this list's copy) back whole could overwrite
      // newer content a sync pull applied since the list was loaded, and
      // the bumped updated_at would push that stale content over the other
      // device's edit.
      updated = repository == null
          ? item.copyWith(rating: rating)
          : await repository.setRating(item.id, rating);
    } on Object catch (error, stackTrace) {
      debugPrint('Rating persistence failed: $error\n$stackTrace');
      if (mounted) _showNotice(_s.noticeRatingSaveFailed);
      return;
    }
    final stored = updated;
    if (stored == null) {
      // Deleted meanwhile (another device, the CLI). The old whole-item
      // save silently re-created it.
      if (mounted) {
        _showNotice(_s.noticeItemMissingRefreshed);
        unawaited(_refreshItems());
      }
      return;
    }
    _touchSync();
    if (!mounted) return;
    setState(() {
      final index = _items.indexWhere((candidate) => candidate.id == item.id);
      if (index >= 0) _items[index] = stored;
    });
  }

  void _openBrowser(ItemType type, {bool revealLatest = false}) {
    final next = switch (type) {
      ItemType.prompt => _BallView.prompts,
      ItemType.skill => _BallView.skills,
      ItemType.snippet => _BallView.snippets,
    };
    // Committing the browser state first and letting _go drop the
    // navigation would leave the panel title on the old module while the
    // list shows the new filter; probe the guards before any state lands.
    if (!_canNavigateTo(next)) return;
    if (type == ItemType.skill) unawaited(_refreshItems());
    _searchController.clear();
    setState(() {
      _browserType = type;
      _selectedCategory = null;
      _categoriesExpanded = false;
      _ratingFilter = null;
      _sortMode = revealLatest
          ? ItemSortMode.recentlyUpdated
          : ItemSortMode.smart;
    });
    final navigation = _go(next);
    unawaited(
      navigation.then((_) {
        if (!mounted) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _browserScrollController.hasClients) {
            _browserScrollController.jumpTo(0);
          }
        });
      }),
    );
  }

  Future<void> _openMaterialDetail(JianheItem item) async {
    setState(() => _selectedMaterial = item);
    await _go(_BallView.materialDetail);
  }

  Future<void> _composeWithPrompt(JianheItem prompt) async {
    _selectPrompt(prompt);
    await _go(_BallView.composer);
  }

  void _openEditor([ItemType type = ItemType.prompt, String? initialCategory]) {
    _editingItemId = null;
    _editingBase = null;
    _editingSkillFiles = null;
    _savingItem = false;
    _editorTitleController.clear();
    _editorContentController.clear();
    _editorCategoryController.text = initialCategory ?? '';
    setState(() => _editorType = type);
    _go(_BallView.editor);
  }

  void _selectEditorType(ItemType type) {
    setState(() {
      _editorType = type;
      final category = _editorCategoryController.text;
      if (category.isNotEmpty && !_editorCategories.contains(category)) {
        _editorCategoryController.clear();
      }
    });
  }

  Future<void> _chooseEditorCategory(List<String> categories) async {
    _beginPopupMenuInteraction();
    String? selected;
    try {
      selected = await _showPanelDialog<String>(
        frameKey: const Key('editor-category-picker-frame'),
        builder: (dialogContext) => Padding(
          padding: const EdgeInsets.all(16),
          child: _EditorCategoryPicker(
            categories: categories,
            selectedCategory: _editorCategoryController.text,
          ),
        ),
      );
    } finally {
      if (mounted) _endPopupMenuInteraction();
    }
    if (!mounted || selected == null) return;
    final nextCategory = selected;
    setState(() => _editorCategoryController.text = nextCategory);
  }

  void _editItem(JianheItem item) {
    _editingItemId = item.id;
    _editingBase = _editableFieldsOf(item);
    _editingSkillFiles = item.type == ItemType.skill
        ? widget.skillPackages?.listFiles(item.id) ??
              Future<List<SkillFileMetadata>>.value(const <SkillFileMetadata>[])
        : null;
    _savingItem = false;
    _editorTitleController.text = item.title;
    _editorContentController.text = item.content;
    _editorCategoryController.text = item.category;
    setState(() => _editorType = item.type);
    _go(_BallView.editor);
  }

  Future<void> _chooseSkillCreation() async {
    if (_skillImportBusy) return;
    final action = await _showPanelDialog<_SkillCreateAction>(
      frameKey: const Key('skill-create-dialog-frame'),
      builder: (dialogContext) => _compactAlertDialog(
        key: const Key('skill-create-dialog'),
        scrollable: true,
        title: Text(_s.skillCreateDialogTitle),
        content: SizedBox(
          width: 280,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              OutlinedButton.icon(
                key: const Key('skill-import-directory'),
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop(_SkillCreateAction.directory),
                icon: const Icon(Icons.drive_folder_upload_outlined),
                label: Text(_s.skillImportFolder),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('skill-import-file'),
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_SkillCreateAction.file),
                icon: const Icon(Icons.upload_file_outlined),
                label: Text(_s.skillImportFile),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                key: const Key('skill-create-manual'),
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_SkillCreateAction.manual),
                icon: const Icon(Icons.edit_note_rounded),
                label: Text(_s.skillCreateManual),
              ),
              const SizedBox(height: 6),
              Text(
                _s.skillImportRootHint,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF81796E), fontSize: 11),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(_s.cancel),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == _SkillCreateAction.manual) {
      _openEditor(
        ItemType.skill,
        _selectedCategory?.isNotEmpty == true ? _selectedCategory : null,
      );
      return;
    }
    await _importSkill(directory: action == _SkillCreateAction.directory);
  }

  Future<void> _importSkill({required bool directory}) async {
    final repository = widget.skillPackages;
    if (_skillImportBusy || repository == null) {
      if (repository == null) {
        _showNotice(_s.noticeSkillLibraryUnavailable);
      }
      return;
    }
    _beginPopupMenuInteraction();
    setState(() => _skillImportBusy = true);
    try {
      final imported = directory
          ? await widget.skillImportService.importDirectory()
          : await widget.skillImportService.importFile();
      if (imported == null || !mounted) return;

      final category = _selectedCategory?.isNotEmpty == true
          ? _selectedCategory!
          : '';
      final item = JianheItem.create(
        type: ItemType.skill,
        title: imported.title,
        content: imported.entrypointContent,
        category: category,
        sortOrder: _nextSortOrder(ItemType.skill),
      );
      final package = imported.toPackage(item.id);
      final existingId = await repository.findSkillIdByPackageHash(
        package.packageHash(item.content),
      );
      if (!mounted) return;
      if (existingId != null) {
        final existing = await widget.repository?.getById(existingId);
        _showNotice(
          _s.noticeSkillAlreadyImported(existing?.title ?? imported.title),
        );
        return;
      }

      final confirmed = await _confirmSkillImport(item, package);
      if (confirmed != true || !mounted) return;
      // The check above only spares the user a pointless confirmation. The
      // dialog can stay open indefinitely, and the CLI (an Agent) may import
      // the same package meanwhile, so check again under the write lock and
      // write in the same transaction.
      Future<String?> writeUnlessDuplicate() async {
        final duplicateId = await repository.findSkillIdByPackageHash(
          package.packageHash(item.content),
        );
        if (duplicateId != null) return duplicateId;
        await repository.replaceSkill(item, package);
        return null;
      }

      final runner = widget.storageTransactionRunner;
      final duplicateId = runner == null
          ? await writeUnlessDuplicate()
          : await runner<String?>(writeUnlessDuplicate);
      if (duplicateId != null) {
        if (!mounted) return;
        final existing = await widget.repository?.getById(duplicateId);
        if (!mounted) return;
        _showNotice(
          _s.noticeSkillAlreadyImported(existing?.title ?? imported.title),
        );
        unawaited(_refreshItems());
        return;
      }
      _touchSync();
      if (!mounted) return;
      setState(() {
        _items.add(item);
        if (category.isNotEmpty) {
          _savedCategories[ItemType.skill]!.add(category);
        }
      });
      _refreshResult();
      if (package.exceedsSyncBlobLimit(item.content)) {
        _showNotice(
          _s.noticeSkillImportedLocalOnly(
            item.title,
            package.fileCount,
            SkillPackage.maximumSyncBlobBytes >> 20,
          ),
          duration: const Duration(seconds: 6),
        );
      } else {
        _showNotice(
          _s.noticeSkillImported(item.title, package.fileCount),
          success: true,
        );
      }
    } on SkillPackageFormatException catch (error) {
      debugPrint('Invalid Skill package: ${error.message}');
      if (mounted) {
        _showNotice(_s.noticeSkillPackageInvalid);
      }
    } on SkillImportException catch (error) {
      if (mounted) _showNotice(error.message);
    } on Object catch (error, stackTrace) {
      debugPrint('Skill import failed: $error\n$stackTrace');
      if (mounted) _showNotice(_s.noticeSkillImportFailed);
    } finally {
      _endPopupMenuInteraction();
      if (mounted) {
        setState(() => _skillImportBusy = false);
      }
    }
  }

  Future<bool?> _confirmSkillImport(JianheItem item, SkillPackage package) {
    final sourceLabel = switch (package.sourceFormat) {
      SkillSourceFormat.directory => _s.skillSourceFolder,
      SkillSourceFormat.zip => 'ZIP',
      SkillSourceFormat.markdown => 'Markdown',
    };
    final preview = item.content.trim();
    return _showPanelDialog<bool>(
      frameKey: const Key('confirm-skill-import-frame'),
      builder: (dialogContext) => _compactAlertDialog(
        key: const Key('confirm-skill-import-dialog'),
        title: Text(_s.skillImportConfirmTitle),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 300),
          child: SingleChildScrollView(
            child: SizedBox(
              width: 280,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _ImportDetailRow(label: _s.detailName, value: item.title),
                  const SizedBox(height: 7),
                  _ImportDetailRow(label: _s.detailSource, value: sourceLabel),
                  const SizedBox(height: 7),
                  _ImportDetailRow(
                    label: _s.detailFiles,
                    value: _s.fileCountAndSize(
                      package.fileCount,
                      _formatSkillFileBytes(package.totalBytes(item.content)),
                    ),
                  ),
                  const SizedBox(height: 7),
                  _ImportDetailRow(
                    label: _s.detailCategory,
                    value: item.category.isEmpty
                        ? _s.uncategorized
                        : item.category,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _s.skillMdPreview,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF7F2E9),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      preview,
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(_s.cancel),
          ),
          FilledButton(
            key: const Key('confirm-skill-import'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(_s.confirmImport),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // CRUD operations (unchanged)
  // ============================================================

  Future<T?> _showPanelDialog<T>({
    required WidgetBuilder builder,
    Key? frameKey,
    bool barrierDismissible = true,
  }) async {
    final token = _beginModalDialogInteraction();
    try {
      return await showDialog<T>(
        context: context,
        useSafeArea: false,
        barrierDismissible: barrierDismissible,
        builder: (routeContext) {
          final windowSize = _windowSize == Size.zero
              ? MediaQuery.sizeOf(routeContext)
              : _windowSize;
          // The dialog route spans the whole window, so a translucent
          // MouseRegion here tracks "pointer within the window bounds" for
          // as long as the dialog is up — the panel's own region is blocked
          // by the barrier and cannot tell hovering the dialog apart from
          // leaving the window. Translucent keeps the barrier tappable
          // underneath for dismiss-by-outside-click.
          return MouseRegion(
            key: Key('dialog-frame-region-$token'),
            hitTestBehavior: HitTestBehavior.translucent,
            onEnter: (event) => _handleDialogFrameEnter(token, event),
            onExit: (event) => _handleDialogFrameExit(token, event),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: windowSize.width,
                height: windowSize.height,
                child: Padding(
                  key: frameKey,
                  padding: _panelInsets,
                  child: Align(
                    alignment: Alignment.center,
                    child: Builder(builder: builder),
                  ),
                ),
              ),
            ),
          );
        },
      );
    } finally {
      _endModalDialogInteraction(token);
    }
  }

  static ({ItemType type, String title, String content, String category})
  _editableFieldsOf(JianheItem item) => (
    type: item.type,
    title: item.title,
    content: item.content,
    category: item.category,
  );

  /// [interactive] is false for the best-effort flush while the window
  /// closes: a conflict there is never resolved by overwriting.
  Future<void> _saveItem({bool interactive = true}) async {
    if (_savingItem) return;
    setState(() => _savingItem = true);
    var savedSuccessfully = false;
    try {
      final repository = widget.repository;
      if (repository == null) {
        _showNotice(_s.noticeCannotSaveNoDatabase);
        return;
      }
      final editingId = _editingItemId;
      final base = _editingBase;
      final draftTitle = _editorTitleController.text;
      final draftContent = _editorContentController.text;
      final selectedCategory = _editorCategoryController.text.trim();
      final skillPackages = widget.skillPackages;

      // Runs inside one write transaction: re-read the stored row, refuse
      // to write over an edit or deletion made elsewhere since the editor
      // opened (the CLI, another device via sync), and otherwise apply the
      // editor's fields to the fresh row so rating, usage and order made
      // meanwhile are kept rather than reverted to the editor's snapshot.
      Future<({_EditorSaveStatus status, JianheItem? item})>
      validateAndPersist({required bool overwrite, required bool asNew}) async {
        JianheItem? current;
        if (editingId != null && !asNew) {
          current = await repository.getById(editingId);
          if (current == null) {
            return (status: _EditorSaveStatus.deleted, item: null);
          }
          if (!overwrite &&
              base != null &&
              _editableFieldsOf(current) != base) {
            return (status: _EditorSaveStatus.modified, item: null);
          }
        }
        final editingExistingSkill = current?.type == ItemType.skill;
        final savedType = editingExistingSkill ? ItemType.skill : _editorType;
        if (selectedCategory.isNotEmpty) {
          final availableCategories = await repository.listCategories(
            savedType,
          );
          if (!availableCategories.contains(selectedCategory)) {
            return (status: _EditorSaveStatus.categoryMissing, item: null);
          }
        }
        final item = current == null
            ? JianheItem.create(
                type: savedType,
                title: draftTitle,
                content: draftContent,
                category: selectedCategory,
                sortOrder: _nextSortOrder(savedType),
              )
            : current.copyWith(
                type: savedType,
                title: draftTitle,
                content: draftContent,
                category: selectedCategory,
              );
        if (editingExistingSkill && skillPackages != null) {
          final package = await skillPackages.getBySkillId(item.id);
          await skillPackages.replaceSkill(item, package);
        } else {
          await repository.save(item);
        }
        return (status: _EditorSaveStatus.saved, item: item);
      }

      final runner = widget.storageTransactionRunner;
      var overwrite = false;
      var asNew = false;
      late JianheItem item;
      var persisted = false;
      while (!persisted) {
        Future<({_EditorSaveStatus status, JianheItem? item})> attempt() =>
            validateAndPersist(overwrite: overwrite, asNew: asNew);
        final outcome = runner == null
            ? await attempt()
            : await runner<({_EditorSaveStatus status, JianheItem? item})>(
                attempt,
              );
        switch (outcome.status) {
          case _EditorSaveStatus.saved:
            item = outcome.item!;
            persisted = true;
          case _EditorSaveStatus.categoryMissing:
            if (mounted) _showNotice(_s.noticeCategoryGone);
            return;
          case _EditorSaveStatus.modified:
          case _EditorSaveStatus.deleted:
            final deleted = outcome.status == _EditorSaveStatus.deleted;
            // The dialog waits outside the transaction, so the write lock
            // is never held while the user decides.
            final overwriteChosen =
                interactive && await _confirmEditConflict(deleted: deleted);
            if (!mounted) return;
            if (!overwriteChosen) {
              if (interactive) _discardConflictingEdit();
              return;
            }
            // Deleted elsewhere: save as a new item rather than resurrect
            // the deleted id.
            if (deleted) asNew = true;
            overwrite = true;
        }
      }
      final createdNew = editingId == null || asNew;
      savedSuccessfully = true;
      // From here on the editor edits the row it just saved: if the
      // navigation below is refused and the save button re-arms, a second
      // click must update this item instead of creating a duplicate.
      _editingItemId = item.id;
      _editingBase = _editableFieldsOf(item);
      _touchSync();
      if (!mounted) return;
      setState(() {
        if (item.category.isNotEmpty) {
          _savedCategories[item.type]!.add(item.category);
        }
        final index = _items.indexWhere((candidate) => candidate.id == item.id);
        if (index < 0) {
          _items.insert(0, item);
        } else {
          _items[index] = item;
        }
        if (_selectedMaterial?.id == item.id) _selectedMaterial = item;
        if (item.type == ItemType.prompt) _selectedPromptId = item.id;
      });
      _showNotice(
        createdNew ? _s.noticeItemCreated : _s.noticeItemUpdated,
        success: true,
      );
      _openBrowser(item.type, revealLatest: true);
      if (mounted && _view == _BallView.editor) {
        // The navigation was refused (a panel transition was still in
        // flight), so the editor stays on screen — re-arm the save button
        // instead of leaving it disabled until the user re-enters. On an
        // accepted navigation _view has already switched synchronously and
        // the flag resets the next time the editor opens.
        setState(() => _savingItem = false);
      }
    } on ArgumentError catch (error) {
      // Validation rejects empty fields, over-length title/content and
      // control characters in category names; name the real problem
      // instead of implying the user left something blank.
      _showNotice(switch (error.name) {
        'title' => _s.validationTitle(JianheItem.maxTitleLength),
        'content' => _s.validationContent(JianheItem.maxContentLength),
        'category' => _s.validationCategory(JianheItem.maxCategoryLength),
        _ => _s.validationRequired,
      });
    } on Object catch (error, stackTrace) {
      debugPrint('Failed to save Jianhe item: $error\n$stackTrace');
      _showNotice(_s.noticeSaveFailed);
    } finally {
      if (mounted && !savedSuccessfully) {
        setState(() => _savingItem = false);
      }
    }
  }

  /// Asks how to resolve an edit conflict; true means overwrite.
  Future<bool> _confirmEditConflict({required bool deleted}) async {
    final choice = await _showPanelDialog<bool>(
      frameKey: const Key('edit-conflict-dialog-frame'),
      barrierDismissible: false,
      builder: (dialogContext) => _compactAlertDialog(
        key: const Key('edit-conflict-dialog'),
        title: Text(
          deleted ? _s.conflictDeletedTitle : _s.conflictModifiedTitle,
        ),
        content: Text(
          deleted ? _s.conflictDeletedBody : _s.conflictModifiedBody,
        ),
        actions: [
          TextButton(
            key: const Key('edit-conflict-discard'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(_s.discard),
          ),
          FilledButton(
            key: const Key('edit-conflict-overwrite'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(_s.overwrite),
          ),
        ],
      ),
    );
    return choice == true;
  }

  void _discardConflictingEdit() {
    _editingBase = null;
    _showNotice(_s.noticeEditDiscarded);
    unawaited(_refreshItems());
    _openBrowser(_editorType);
  }

  /// Best-effort persist of an in-progress editor draft when the host window
  /// is closing. Reuses [_saveItem] so the draft follows the exact same
  /// validation and skill-package handling as the save button; a failing or
  /// inapplicable flush must never block the close.
  Future<void> _flushDraftForClose() async {
    if (!mounted || _savingItem || _view != _BallView.editor) return;
    if (widget.repository == null) return;
    final title = _editorTitleController.text.trim();
    final content = _editorContentController.text.trim();
    // The editor itself refuses to save empty fields; a half-filled draft
    // therefore stays unflushed instead of failing validation at close time.
    if (title.isEmpty || content.isEmpty) return;
    try {
      await _saveItem(interactive: false);
    } on Object {
      // Close proceeds regardless; nothing further can be persisted.
    }
  }

  Future<void> _deleteItem(JianheItem item) async {
    if (_blockPersistentMutation()) return;
    final confirmed = await _showPanelDialog<bool>(
      frameKey: const Key('delete-dialog-panel-inset'),
      builder: (dialogContext) => _compactAlertDialog(
        key: const Key('delete-item-dialog'),
        title: Text(_s.deleteItemTitle),
        content: Text(_s.deleteItemBody(item.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(_s.cancel),
          ),
          FilledButton(
            key: const Key('confirm-delete-item'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(_s.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.repository?.delete(item.id);
    } on Object catch (error, stackTrace) {
      debugPrint('Delete persistence failed: $error\n$stackTrace');
      if (mounted) _showNotice(_s.noticeDeleteFailed);
      return;
    }
    _touchSync();
    if (!mounted) return;
    setState(() {
      _items.removeWhere((candidate) => candidate.id == item.id);
      if (item.id == _selectedPromptId) {
        _selectedPromptId = _firstPromptId(_items);
      }
    });
    _showNotice(_s.noticeItemDeleted(item.title), success: true);
    if (_view == _BallView.editor) _openBrowser(item.type);
  }

  int _nextSortOrder(ItemType type) {
    var next = 0;
    for (final item in _items) {
      if (item.type == type && item.sortOrder >= next) {
        next = item.sortOrder + 1;
      }
    }
    return next;
  }

  Future<void> _setSortMode(ItemSortMode mode) async {
    if (mode == ItemSortMode.custom) {
      await _ensureCustomOrder();
    }
    if (mounted) setState(() => _sortMode = mode);
  }

  Future<void> _ensureCustomOrder() async {
    if (_blockPersistentMutation()) return;
    await _applySortOrders(
      _browserType,
      _distinctSortOrders(_browserType),
      failureNotice: _s.noticeSortFailed,
    );
  }

  /// The sort-order changes that make every item of [type] distinct, as
  /// few as possible.
  ///
  /// A type that was never arranged (one shared order, typically all 0) is
  /// seeded from the smart order. Once arranged, the arrangement is kept:
  /// among items sharing an order the earliest created stays and the rest,
  /// usually items imported or synced in with the default 0, move to the
  /// end in creation order. Renumbering the whole type in smart order on
  /// every switch to custom order used to discard the user's arrangement
  /// and rewrite (and push) every item of the type.
  Map<String, int> _distinctSortOrders(ItemType type) {
    final typed = _items.where((item) => item.type == type).toList();
    final orders = typed.map((item) => item.sortOrder).toSet();
    if (typed.length < 2 || orders.length == typed.length) {
      return const <String, int>{};
    }
    if (orders.length == 1) {
      typed.sort(_compareSmart);
      return <String, int>{
        for (var index = 0; index < typed.length; index++)
          if (typed[index].sortOrder != index) typed[index].id: index,
      };
    }
    typed.sort((a, b) {
      final order = a.sortOrder.compareTo(b.sortOrder);
      if (order != 0) return order;
      final created = a.createdAt.compareTo(b.createdAt);
      if (created != 0) return created;
      return a.id.compareTo(b.id);
    });
    var next = typed.last.sortOrder + 1;
    final kept = <int>{};
    return <String, int>{
      for (final item in typed)
        if (!kept.add(item.sortOrder)) item.id: next++,
    };
  }

  Future<void> _moveItem(JianheItem item, int offset) async {
    if (_blockPersistentMutation()) return;
    final visible = _browserItems;
    final from = visible.indexWhere((candidate) => candidate.id == item.id);
    final to = from + offset;
    if (from < 0 || to < 0 || to >= visible.length) return;
    final partner = visible[to];

    // Swap the two items' orders. Items hidden by the active category or
    // rating filter keep theirs, and only these two are written (plus any
    // duplicate orders that arrived since custom order was set up, which
    // are made distinct first so the swap is well defined).
    final changes = Map<String, int>.of(_distinctSortOrders(item.type));
    final itemOrder = changes[item.id] ?? item.sortOrder;
    final partnerOrder = changes[partner.id] ?? partner.sortOrder;
    changes[item.id] = partnerOrder;
    changes[partner.id] = itemOrder;
    await _applySortOrders(
      item.type,
      changes,
      failureNotice: _s.noticeMoveFailed,
    );
  }

  /// Persists [orders] (id → sort order) for items of [type] and puts the
  /// stored rows into the list. The repository writes only sort_order and
  /// updated_at, so this list's possibly outdated copies of title and
  /// content never reach storage or the sync push.
  Future<void> _applySortOrders(
    ItemType type,
    Map<String, int> orders, {
    required String failureNotice,
  }) async {
    if (orders.isEmpty) return;
    final repository = widget.repository;
    var changed = const <JianheItem>[];
    try {
      if (repository == null) {
        final changedAt = DateTime.now().toUtc();
        changed = <JianheItem>[
          for (final item in _items)
            if (item.type == type &&
                orders.containsKey(item.id) &&
                orders[item.id] != item.sortOrder)
              item.copyWith(sortOrder: orders[item.id], updatedAt: changedAt),
        ];
      } else {
        changed = await repository.setSortOrders(type, orders);
      }
    } on Object catch (error, stackTrace) {
      debugPrint('Sort order persistence failed: $error\n$stackTrace');
      if (mounted) _showNotice(failureNotice);
      return;
    }
    if (changed.isEmpty) return;
    _touchSync();
    if (!mounted) return;
    setState(() {
      for (final next in changed) {
        final index = _items.indexWhere((candidate) => candidate.id == next.id);
        if (index >= 0) _items[index] = next;
      }
    });
  }

  // category management (unchanged)
  Future<void> _manageCategories() async {
    if (_blockPersistentMutation()) return;
    final categories = _browserCategories;
    final result =
        await _showPanelDialog<({String category, _CategoryAction action})>(
          builder: (dialogContext) => _compactAlertDialog(
            key: const Key('manage-categories-dialog'),
            title: Text(_s.manageCategoriesTitle(_browserType)),
            content: SizedBox(
              width: 280,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: categories.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        child: Text(
                          _s.noCategoriesHint,
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: categories.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, index) {
                          final category = categories[index];
                          final count = _items
                              .where(
                                (item) =>
                                    item.type == _browserType &&
                                    item.category == category,
                              )
                              .length;
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(
                              category,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(_s.countItems(count)),
                            trailing: PopupMenuButton<_CategoryAction>(
                              tooltip: _s.categoryActions,
                              onOpened: _beginPopupMenuInteraction,
                              onCanceled: _endPopupMenuInteraction,
                              onSelected: (action) {
                                _endPopupMenuInteraction();
                                Navigator.of(
                                  dialogContext,
                                ).pop((category: category, action: action));
                              },
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: _CategoryAction.rename,
                                  child: Text(_s.rename),
                                ),
                                PopupMenuItem(
                                  value: _CategoryAction.clear,
                                  child: Text(_s.removeCategory),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ),
            actions: [
              TextButton.icon(
                key: const Key('create-category-dialog'),
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop((category: '', action: _CategoryAction.create)),
                icon: const Icon(Icons.create_new_folder_outlined),
                label: Text(_s.newCategory),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(_s.done),
              ),
            ],
          ),
        );
    if (!mounted || result == null) return;
    switch (result.action) {
      case _CategoryAction.create:
        await _createCategory();
      case _CategoryAction.rename:
        await _renameCategory(result.category);
      case _CategoryAction.clear:
        await _clearCategory(result.category);
    }
  }

  Future<void> _createCategory() async {
    if (_blockPersistentMutation()) return;
    final category = await _showPanelDialog<String>(
      builder: (_) => _CategoryNameDialog(
        title: _s.newCategoryTitle(_browserType),
        hintText: _s.categoryNameHint,
        confirmKey: const Key('confirm-create-category'),
        fieldKey: const Key('new-category-name'),
      ),
    );
    if (!mounted || category == null || category.isEmpty) return;
    if (_browserCategories.contains(category)) {
      _showNotice(_s.noticeCategoryExists(category));
      return;
    }
    try {
      await widget.repository?.createCategory(_browserType, category);
      _touchSync();
      if (!mounted) return;
      setState(() {
        _savedCategories[_browserType]!.add(category);
        _selectedCategory = category;
        _categoriesExpanded = false;
      });
      _showNotice(_s.noticeCategoryCreated(category), success: true);
    } on ArgumentError {
      _showNotice(_s.invalidCategoryName(JianheItem.maxCategoryLength));
    }
  }

  Future<void> _renameCategory(String oldCategory) async {
    final nextCategory = await _showPanelDialog<String>(
      builder: (_) => _CategoryNameDialog(
        title: _s.renameCategoryTitle,
        initialText: oldCategory,
      ),
    );
    if (!mounted ||
        nextCategory == null ||
        nextCategory.isEmpty ||
        nextCategory == oldCategory) {
      return;
    }
    try {
      await _replaceCategory(oldCategory, nextCategory);
      _showNotice(_s.noticeCategoryRenamed, success: true);
    } on ArgumentError {
      _showNotice(_s.invalidCategoryName(JianheItem.maxCategoryLength));
    }
  }

  Future<void> _clearCategory(String category) async {
    final confirmed = await _showPanelDialog<bool>(
      builder: (dialogContext) => _compactAlertDialog(
        title: Text(_s.removeCategoryTitle),
        content: Text(_s.removeCategoryBody(category)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(_s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(_s.remove),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _replaceCategory(category, '');
    _showNotice(_s.noticeMovedToUncategorized, success: true);
  }

  Future<void> _replaceCategory(String oldCategory, String nextCategory) async {
    if (_blockPersistentMutation()) return;
    final type = _browserType;
    try {
      if (nextCategory.isEmpty) {
        await widget.repository?.deleteCategory(_browserType, oldCategory);
      } else {
        await widget.repository?.renameCategory(
          _browserType,
          oldCategory,
          nextCategory,
        );
      }
    } on Object catch (error, stackTrace) {
      debugPrint('Category persistence failed: $error\n$stackTrace');
      if (mounted) _showNotice(_s.noticeCategoryChangeFailed);
      return;
    }
    _touchSync();
    final updated = <JianheItem>[];
    for (final item in _items.where(
      (item) => item.type == _browserType && item.category == oldCategory,
    )) {
      final next = item.copyWith(
        category: nextCategory,
        updatedAt: item.updatedAt,
      );
      updated.add(next);
    }
    if (!mounted) return;
    final wasPinned = _pinnedCategories[type] == oldCategory;
    setState(() {
      _savedCategories[_browserType]!.remove(oldCategory);
      if (nextCategory.isNotEmpty) {
        _savedCategories[_browserType]!.add(nextCategory);
      }
      for (final next in updated) {
        final index = _items.indexWhere((candidate) => candidate.id == next.id);
        if (index >= 0) _items[index] = next;
      }
      if (_selectedCategory == oldCategory) {
        _selectedCategory = nextCategory.isEmpty ? '' : nextCategory;
      }
      if (wasPinned) {
        if (nextCategory.isEmpty) {
          _pinnedCategories.remove(type);
        } else {
          _pinnedCategories[type] = nextCategory;
        }
      }
      _categoriesExpanded = false;
    });
    if (wasPinned) {
      widget.onPinnedCategoryChanged?.call(
        type,
        nextCategory.isEmpty ? null : nextCategory,
      );
    }
  }

  // ============================================================
  // backup (unchanged)
  // ============================================================

  Future<JianheBackup> _createBackupSnapshot() async {
    if (widget.localStorageUnavailable) {
      throw StateError('本地数据库不可用，无法创建备份快照。');
    }
    final repository = widget.repository;
    final items = repository == null
        ? List<JianheItem>.from(_items)
        : await repository.listAll();
    final categories = <ItemType, List<String>>{};
    for (final type in ItemType.values) {
      categories[type] = repository == null
          ? List<String>.from(_savedCategories[type]!)
          : await repository.listCategories(type);
    }
    return JianheBackup(
      exportedAt: DateTime.now(),
      items: items,
      categories: categories,
      skillPackages:
          await widget.skillPackages?.listAll() ?? const <SkillPackage>[],
      settings: <String, Object?>{
        'auto_collapse_seconds': _autoCollapseSeconds,
        'cli_access_mode': _cliAccessMode.storageValue,
      },
    );
  }

  Future<void> _exportBackup() async {
    if (_backupBusy) return;
    if (widget.localStorageUnavailable) {
      _showNotice(_s.noticeExportUnavailable);
      return;
    }
    setState(() => _backupBusy = true);
    try {
      final backup = await _createBackupSnapshot();
      final now = backup.exportedAt;
      final encoded = _backupPayloadBytes(backup) >= _backupOffThreadBytes
          ? await compute(_encodeBackup, backup)
          : backup.encode();
      final saved = await widget.backupFileService.save(
        encoded,
        suggestedName: _backupFileName(now),
        dialogTitle: _s.backupSaveDialogTitle,
        filter: _s.backupDialogFilter,
      );
      if (mounted && saved) {
        _showNotice(_s.noticeExported(backup.items.length), success: true);
      }
    } on Object {
      if (mounted) _showNotice(_s.noticeExportFailed);
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _importBackup() async {
    if (_backupBusy) return;
    if (widget.localStorageUnavailable) {
      _showNotice(_s.noticeImportUnavailable);
      return;
    }
    setState(() => _backupBusy = true);
    try {
      final selected = await widget.backupFileService.open();
      if (selected == null) return;
      final backup = selected.content.length >= _backupOffThreadBytes
          ? await compute(_decodeBackup, selected.content)
          : JianheBackup.decode(selected.content);
      if (!mounted) return;
      final categoryCount = backup.categories.values.fold<int>(
        0,
        (total, categories) => total + categories.length,
      );
      final confirmed = await _showPanelDialog<bool>(
        builder: (dialogContext) => _compactAlertDialog(
          key: const Key('import-backup-dialog'),
          scrollable: true,
          title: Text(_s.importBackupTitle),
          content: SizedBox(
            width: 280,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ImportDetailRow(label: _s.detailFile, value: selected.name),
                const SizedBox(height: 7),
                _ImportDetailRow(
                  label: _s.detailContents,
                  value: _s.countItems(backup.items.length),
                ),
                const SizedBox(height: 7),
                _ImportDetailRow(
                  label: _s.detailCategory,
                  value: _s.countCategories(categoryCount),
                ),
                const SizedBox(height: 16),
                Text(_s.importBackupMergeHint),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(_s.cancel),
            ),
            FilledButton(
              key: const Key('confirm-import-backup'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(_s.mergeImport),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      final merge = await _applyBackup(backup);
      _showNotice(
        _s.noticeImportDone(
          merge.created.length,
          merge.updated.length,
          merge.skipped,
        ),
        success: true,
      );
    } on FormatException catch (error) {
      if (mounted) _showNotice(_s.noticeImportFormatError(error.message));
    } on Object {
      if (mounted) _showNotice(_s.noticeImportFailed);
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  String _backupFileName(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${_s.backupFileNamePrefix}'
        '${time.year}${two(time.month)}${two(time.day)}-'
        '${two(time.hour)}${two(time.minute)}.jianhe';
  }

  void _setCliAccess(bool enabled) {
    if (_blockPersistentMutation()) return;
    final mode = enabled ? CliAccessMode.readWrite : CliAccessMode.disabled;
    setState(() => _cliAccessMode = mode);
    widget.onCliAccessModeChanged?.call(mode);
    widget.onCliSkillImportEnabledChanged?.call(enabled);
    _showNotice(enabled ? _s.noticeCliEnabled : _s.noticeCliDisabled);
  }

  Future<void> _restoreWakeHotKey() async {
    final registered = await widget.windowController.setWakeHotKey(_wakeHotKey);
    if (mounted) setState(() => _wakeHotKeyAvailable = registered);
  }

  Future<void> _chooseWakeHotKey() async {
    GlobalHotKey? candidate;
    String? validationMessage;
    final selected = await _showPanelDialog<GlobalHotKey>(
      frameKey: const Key('wake-hot-key-dialog-frame'),
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => _compactAlertDialog(
          key: const Key('wake-hot-key-dialog'),
          scrollable: true,
          title: Text(_s.hotKeyDialogTitle),
          content: SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(_s.hotKeyDialogPrompt),
                const SizedBox(height: 12),
                Focus(
                  key: const Key('wake-hot-key-recorder'),
                  autofocus: true,
                  onKeyEvent: (_, event) {
                    if (GlobalHotKey.isModifierKey(event.logicalKey)) {
                      return KeyEventResult.handled;
                    }
                    if (event is! KeyDownEvent) return KeyEventResult.handled;
                    final next = GlobalHotKey.fromKeyEvent(event);
                    setDialogState(() {
                      candidate = next;
                      validationMessage = next == null
                          ? _s.hotKeyUnsupported
                          : next.hasModifier
                          ? null
                          : _s.hotKeyNeedsModifier;
                    });
                    return KeyEventResult.handled;
                  },
                  child: Container(
                    key: const Key('wake-hot-key-preview'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 18,
                    ),
                    decoration: BoxDecoration(
                      color: _paper,
                      border: Border.all(
                        color: validationMessage == null ? _paperEdge : _orange,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      candidate?.displayLabel ?? _wakeHotKey.displayLabel,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  validationMessage ?? _s.hotKeyHelp,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: validationMessage == null ? null : _orange,
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              key: const Key('reset-wake-hot-key'),
              onPressed: () =>
                  Navigator.of(dialogContext).pop(GlobalHotKey.defaultWake),
              child: Text(_s.resetToDefault),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(_s.cancel),
            ),
            FilledButton(
              key: const Key('save-wake-hot-key'),
              onPressed: candidate?.hasModifier == true
                  ? () => Navigator.of(dialogContext).pop(candidate)
                  : null,
              child: Text(_s.apply),
            ),
          ],
        ),
      ),
    );
    if (!mounted || selected == null) return;
    await _applyWakeHotKey(selected);
  }

  Future<void> _applyWakeHotKey(GlobalHotKey hotKey) async {
    if (_wakeHotKeySaving) return;
    setState(() => _wakeHotKeySaving = true);
    var registered = false;
    try {
      registered = await widget.windowController.setWakeHotKey(hotKey);
    } on Object catch (error, stackTrace) {
      // A platform failure must not leave the saving flag up: the settings
      // entry would stay disabled until the panel is rebuilt.
      debugPrint('setWakeHotKey failed: $error\n$stackTrace');
    }
    if (!mounted) return;
    setState(() {
      _wakeHotKeySaving = false;
      if (registered) {
        _wakeHotKey = hotKey;
        _wakeHotKeyAvailable = true;
      }
    });
    if (!registered) {
      _showNotice(_s.noticeHotKeyRejected);
      return;
    }
    widget.onWakeHotKeyChanged?.call(hotKey);
    _showNotice(_s.noticeHotKeyUpdated(hotKey.displayLabel), success: true);
  }

  // ============================================================
  // pointer / auto-collapse
  // ============================================================

  void _handlePointerEnter(PointerEnterEvent event) {
    _autoCollapseTimer?.cancel();
    if (!_pointerInside) setState(() => _pointerInside = true);
  }

  void _handlePointerExit(PointerExitEvent event) {
    if (_pointerInside) setState(() => _pointerInside = false);
    _scheduleAutoCollapse();
  }

  void _beginPopupMenuInteraction() {
    _activePopupMenus++;
    _autoCollapseTimer?.cancel();
  }

  void _endPopupMenuInteraction() {
    if (_activePopupMenus > 0) _activePopupMenus--;
    if (_activePopupMenus == 0) _scheduleAutoCollapse();
  }

  int _beginModalDialogInteraction() {
    _activeModalDialogs++;
    final token = ++_modalDialogSerial;
    _modalDialogTokens.add(token);
    // The frame region reports the real pointer position; until it does, a
    // dialog can only have been opened by a click inside the window.
    _dialogFramePointerInside = true;
    _autoCollapseTimer?.cancel();
    return token;
  }

  void _endModalDialogInteraction(int token) {
    _modalDialogTokens.remove(token);
    if (_activeModalDialogs > 0) _activeModalDialogs--;
    if (mounted && _activeModalDialogs == 0) _scheduleAutoCollapse();
  }

  // While a modal dialog is up, its barrier blocks the panel's MouseRegion,
  // which therefore cannot distinguish "pointer over the dialog" (still
  // inside the window) from "pointer beyond the window bounds". The dialog
  // frame region spans the whole window and owns the signal instead.
  bool get _pointerWithinWindow =>
      _activeModalDialogs > 0 ? _dialogFramePointerInside : _pointerInside;

  // Only the topmost dialog's frame counts: a nested dialog's route steals
  // hit-testing, so the covered wrapper would otherwise report a false exit.
  bool _isTopDialogFrame(int token) =>
      _modalDialogTokens.isNotEmpty && _modalDialogTokens.last == token;

  void _handleDialogFrameEnter(int token, PointerEnterEvent event) {
    if (!_isTopDialogFrame(token)) return;
    _dialogFramePointerInside = true;
    _autoCollapseTimer?.cancel();
  }

  void _handleDialogFrameExit(int token, PointerExitEvent event) {
    if (!_isTopDialogFrame(token)) return;
    _dialogFramePointerInside = false;
    _scheduleAutoCollapse();
  }

  void _scheduleAutoCollapse() {
    _autoCollapseTimer?.cancel();
    if (_view == _BallView.collapsed ||
        _pointerWithinWindow ||
        _activePopupMenus > 0 ||
        _panelResizing ||
        _isDragging ||
        _interaction == _BallInteractionState.dragging ||
        _interaction == _BallInteractionState.snapping) {
      return;
    }
    // 最低 1 秒：舞台缩放、菜单展开以及指针掠过子球之间的透明缝隙时，
    // 原生层/MouseRegion 会报告瞬时的 exit→enter，1 秒足以吸收这些抖动。
    final delay = Duration(
      seconds: _clampAutoCollapseSeconds(_autoCollapseSeconds),
    );
    _autoCollapseTimer = Timer(delay, () {
      // Re-check the full scheduling guard: native drags/snaps only move
      // _interaction, and a timer armed before they started must not
      // collapse the panel mid-drag.
      if (_view == _BallView.collapsed ||
          _panelTransitionInProgress ||
          _pointerWithinWindow ||
          _activePopupMenus > 0 ||
          _panelResizing ||
          _isDragging ||
          _interaction == _BallInteractionState.dragging ||
          _interaction == _BallInteractionState.snapping) {
        return;
      }
      if (_activeModalDialogs > 0) {
        // Dialogs paint at the window size they captured; close them before
        // shrinking the window so their frames cannot overflow the ball.
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      _collapseMenu();
      _go(_BallView.collapsed);
    });
  }

  static const _minAutoCollapseSeconds = 1;
  static const _maxAutoCollapseSeconds = 60;

  static int _clampAutoCollapseSeconds(int seconds) =>
      seconds.clamp(_minAutoCollapseSeconds, _maxAutoCollapseSeconds);

  void _previewAutoCollapseSeconds(double value) {
    setState(
      () => _autoCollapseSeconds = _clampAutoCollapseSeconds(value.round()),
    );
  }

  void _saveAutoCollapseSeconds(double value) {
    final seconds = _clampAutoCollapseSeconds(value.round());
    setState(() => _autoCollapseSeconds = seconds);
    widget.onAutoCollapseSecondsChanged?.call(seconds);
    _showNotice(_s.noticeAutoCollapse(seconds));
  }

  void _showNotice(
    String message, {
    bool success = false,
    Duration duration = const Duration(milliseconds: 1800),
  }) {
    _noticeTimer?.cancel();
    if (!mounted) return;
    setState(() => _notice = '${success ? '✓  ' : ''}$message');
    _noticeTimer = Timer(duration, () {
      if (mounted) setState(() => _notice = null);
    });
  }

  // ============================================================
  // build
  // ============================================================

  @override
  Widget build(BuildContext context) {
    // In native-ball mode the D3D child deliberately stays at the largest
    // backing-buffer size so ANGLE does not rebuild its swap chain on every
    // stage change. That backing size must not become the Flutter layout size:
    // smaller stages would otherwise lay out at the composer size and then be
    // cropped by the smaller native host window.
    final nativeStageSize = _panelSizeFor(_view);
    final size = _isNative ? nativeStageSize : MediaQuery.of(context).size;
    if (size != _windowSize) {
      _windowSize = size;
      // The native layer repositions the ball whenever the host window resizes
      // (collapsed -> menu). Re-anchor the Flutter menu to the real ball position.
      if (_isNative && _menuVisible) {
        unawaited(_syncNativeLayout());
      }
      if (_ballCenter == Offset.zero) {
        _initBallPosition(size);
      }
    }

    // Always render the paper panel rect (with whatever content the current
    // view wants inside it) once we are not in the collapsed stage. The
    // paper-coloured background acts as a placeholder while Flutter is
    // rebuilding the new content: without it the D3D back buffer shows the
    // Scaffold's transparentKey (RGB 20, 19, 17) in the panel rect for the
    // one frame between setState and the first painted frame, which the
    // user sees as a ~90 ms (or longer, if the menu collapse animation is
    // running) black flash on every stage switch. The native orbit window
    // covers the panel rect during the menu stage so the paper colour is
    // invisible there.
    final showPanel = _view != _BallView.collapsed;
    // When the native menu is drawing the actions, the Flutter view is hidden
    // by the C++ side in every stage except the panel stages. The D3D child
    // is still in the widget tree though, so the build method must not paint
    // anything that would show through its transparent areas. The native menu
    // owns hit testing on Windows; the Flutter fallback intentionally renders
    // only the action rows, with no full-window dismissal layer.
    final usesNativeMenu = widget.windowController.usesNativeBall;
    final showQuickActionMenu =
        (_menuExpanded || _menuAnimCtrl.isAnimating) && !usesNativeMenu;

    // Background: paper colour. The original transparentKey made the D3D
    // back buffer start at opaque near-black on every paint, and the user
    // would see a one-frame black flash before Flutter repainted the panel
    // content. With paper as the base colour the buffer is always at least
    // the panel background, so the worst case is a single frame of empty
    // paper, never black. The native ball/orbit windows cover the rest of
    // the surface, so the paper colour is invisible outside the panel rect.
    final surface = Scaffold(
      backgroundColor: _paper,
      body: MouseRegion(
        key: const Key('ball-mouse-region'),
        onEnter: _handlePointerEnter,
        onExit: _handlePointerExit,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (showPanel) _buildPaperPanel(),
            if (showQuickActionMenu) _buildQuickActionMenu(),
            _buildNotice(),
            _buildBall(),
          ],
        ),
      ),
    );

    if (!_isNative) return surface;

    // The native host and its SetWindowRgn use the stage's logical dimensions.
    // Keep Flutter's content in the same coordinate space while allowing the
    // underlying D3D surface to remain fixed at its larger warm-buffer size.
    // Fill the complete warm D3D backing surface with the paper colour. During
    // native resizing the host region changes before Dart receives the next
    // logical size, so pixels just exposed outside the previous SizedBox would
    // otherwise reveal MaterialApp's near-black background for one frame.
    return ColoredBox(
      key: const Key('native-resize-backing'),
      color: _paper,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          key: const Key('ball-logical-surface'),
          width: nativeStageSize.width,
          height: nativeStageSize.height,
          child: surface,
        ),
      ),
    );
  }

  // ball widget
  // ============================================================

  Widget _buildBall() {
    if (widget.windowController.usesNativeBall) {
      return const SizedBox.shrink();
    }

    final positioned = _ballCenter != Offset.zero;

    Widget ballWidget = AnimatedOpacity(
      key: const Key('jianhe-ball-opacity'),
      duration: const Duration(milliseconds: 180),
      opacity: _pointerInside ? 1 : .48,
      child: AnimatedContainer(
        key: const Key('jianhe-ball'),
        duration: const Duration(milliseconds: 180),
        width: _arcConfig.ballDiameter,
        height: _arcConfig.ballDiameter,
        decoration: BoxDecoration(
          color: _ink,
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFFFF5E9), width: 3),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Transform.rotate(
              angle: _menuExpanded ? 0 : -.12,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 29,
                height: 42,
                decoration: BoxDecoration(
                  color: _orange,
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _menuExpanded
                  ? const Icon(
                      Icons.close_rounded,
                      key: Key('ball-close'),
                      color: Colors.white,
                      size: 25,
                    )
                  : const Icon(
                      Icons.edit_rounded,
                      key: Key('ball-edit'),
                      color: Colors.white,
                      size: 25,
                    ),
            ),
            if (_loading)
              const Positioned(
                bottom: 7,
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    if (!positioned) {
      // fallback: bottom-right
      return Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Semantics(
            button: true,
            label: _s.ballSemanticLabel,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _handleBallTap,
              onPanStart: _handleBallPanStart,
              onPanUpdate: _handleBallPanUpdate,
              onPanEnd: _handleBallPanEnd,
              child: ballWidget,
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        Positioned(
          left: _ballCenter.dx - _arcConfig.ballRadius,
          top: _ballCenter.dy - _arcConfig.ballRadius,
          child: Semantics(
            button: true,
            label: _s.ballSemanticLabel,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _handleBallTap,
              onPanStart: _handleBallPanStart,
              onPanUpdate: _handleBallPanUpdate,
              onPanEnd: _handleBallPanEnd,
              child: ballWidget,
            ),
          ),
        ),
      ],
    );
  }

  // ============================================================
  // quick action menu
  // ============================================================

  Widget _buildQuickActionMenu() {
    if (_ballCenter == Offset.zero || _windowSize == Size.zero) {
      return const SizedBox.shrink();
    }

    final bounds = _quickMenuBounds(_ballCenter);
    return Stack(
      children: [
        for (var i = 0; i < _menuActions.length; i++)
          _buildQuickActionRow(
            index: i,
            action: _menuActions[i],
            left: bounds.left,
            top:
                bounds.top + i * (_quickMenuActionHeight + _quickMenuActionGap),
            totalItems: _menuActions.length,
          ),
      ],
    );
  }

  Rect _quickMenuBounds(Offset ballCenter) {
    final menuHeight =
        _menuActions.length * _quickMenuActionHeight +
        (_menuActions.length - 1) * _quickMenuActionGap;
    final rawLeft = switch (_dockEdge) {
      BallDockEdge.left => ballCenter.dx + _ballRadius + _quickMenuEdgeGap,
      BallDockEdge.right =>
        ballCenter.dx - _ballRadius - _quickMenuEdgeGap - _quickMenuWidth,
      BallDockEdge.top ||
      BallDockEdge.bottom => ballCenter.dx - _quickMenuWidth / 2,
    };
    final rawTop = switch (_dockEdge) {
      BallDockEdge.left || BallDockEdge.right => ballCenter.dy - menuHeight / 2,
      BallDockEdge.top => ballCenter.dy + _ballRadius + _quickMenuEdgeGap,
      BallDockEdge.bottom =>
        ballCenter.dy - _ballRadius - _quickMenuEdgeGap - menuHeight,
    };
    final maxLeft = (_windowSize.width - _quickMenuWidth - 8).clamp(
      8.0,
      double.infinity,
    );
    final maxTop = (_windowSize.height - menuHeight - 8).clamp(
      8.0,
      double.infinity,
    );
    return Rect.fromLTWH(
      rawLeft.clamp(8.0, maxLeft),
      rawTop.clamp(8.0, maxTop),
      _quickMenuWidth,
      menuHeight,
    );
  }

  Widget _buildQuickActionRow({
    required int index,
    required ({IconData icon, Color color, _BallView target})
    action,
    required double left,
    required double top,
    required int totalItems,
  }) {
    final staggerStart = index / (totalItems > 1 ? totalItems : 2);
    final itemAnim = CurvedAnimation(
      parent: _menuAnimCtrl,
      curve: Interval(
        staggerStart.clamp(0.0, 0.7),
        1.0,
        curve: Curves.easeOutBack,
      ),
    );

    return AnimatedBuilder(
      animation: itemAnim,
      builder: (context, child) {
        final t = itemAnim.value.clamp(0.0, 1.0).toDouble();
        final entranceOffset = switch (_dockEdge) {
          BallDockEdge.left => const Offset(-18, 0),
          BallDockEdge.right => const Offset(18, 0),
          BallDockEdge.top => const Offset(0, -18),
          BallDockEdge.bottom => const Offset(0, 18),
        };
        final hovered = _hoveredMenuIndex == index;

        return Positioned(
          left: left,
          top: top,
          width: _quickMenuWidth,
          height: _quickMenuActionHeight,
          child: Transform.translate(
            offset: entranceOffset * (1 - t),
            child: Transform.scale(
              alignment: _dockEdge == BallDockEdge.left
                  ? Alignment.centerLeft
                  : Alignment.centerRight,
              scale: .96 + .04 * t,
              child: Opacity(
                opacity: t,
                child: MouseRegion(
                  key: Key('quick-menu-action-$index'),
                  cursor: SystemMouseCursors.click,
                  onEnter: (_) => _setHoveredMenu(index),
                  onExit: (_) => _setHoveredMenu(null),
                  child: Semantics(
                    button: true,
                    label: _menuLabel(action.target),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => _handleMenuAction(index),
                        borderRadius: BorderRadius.circular(14),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 140),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          decoration: BoxDecoration(
                            color: hovered
                                ? Colors.white
                                : const Color(0xFFFFF7EA),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: hovered ? action.color : _paperEdge,
                              width: hovered ? 1.5 : 1,
                            ),
                            boxShadow: hovered
                                ? <BoxShadow>[
                                    BoxShadow(
                                      color: action.color.withValues(
                                        alpha: .28,
                                      ),
                                      blurRadius: 12,
                                      offset: const Offset(0, 3),
                                    ),
                                  ]
                                : const <BoxShadow>[],
                          ),
                          child: Row(
                            children: <Widget>[
                              Stack(
                                clipBehavior: Clip.none,
                                children: <Widget>[
                                  Container(
                                    width: 32,
                                    height: 32,
                                    decoration: BoxDecoration(
                                      color: action.color,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Icon(
                                      action.icon,
                                      color: Colors.white,
                                      size: 20,
                                    ),
                                  ),
                                  if (action.target == _BallView.settings &&
                                      _moreBadgeVisible)
                                    Positioned(
                                      top: -3,
                                      right: -3,
                                      child: Container(
                                        key: const Key('more-update-badge'),
                                        width: 10,
                                        height: 10,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFE5483B),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: Colors.white,
                                            width: 1.5,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _menuLabel(action.target),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: hovered ? action.color : _ink,
                                  ),
                                ),
                              ),
                              const Icon(
                                Icons.chevron_right_rounded,
                                size: 19,
                                color: Color(0xFF847C71),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _setHoveredMenu(int? index) {
    if (_hoveredMenuIndex == index) return;
    setState(() => _hoveredMenuIndex = index);
  }

  // notice toast
  // ============================================================

  Widget _buildNotice() {
    if (_notice == null) return const SizedBox.shrink();
    final isLeft = _dockEdge == BallDockEdge.left;
    return Positioned(
      bottom: 18,
      left: isLeft ? 88 : 12,
      right: isLeft ? 12 : 88,
      child: IgnorePointer(
        child: Align(
          alignment: isLeft ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            decoration: BoxDecoration(
              color: _ink,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(
              _notice!,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // paper panel (content views)
  // ============================================================

  Widget _buildPaperPanel() {
    // position panel based on dock edge
    final ballDiameter = _arcConfig.ballDiameter;
    final isLeft = _dockEdge == BallDockEdge.left;
    final isTop = _dockEdge == BallDockEdge.top;

    return Positioned(
      top: isTop ? ballDiameter + 4 : 8,
      bottom: isTop ? 8 : ballDiameter,
      left: isLeft ? ballDiameter : 8,
      right: isLeft ? 8 : ballDiameter,
      child: Stack(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: _paper,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(isLeft || isTop ? 8 : 26),
                topRight: Radius.circular(isLeft && !isTop ? 26 : 8),
                bottomLeft: Radius.circular(isLeft && !isTop ? 26 : 8),
                bottomRight: Radius.circular(isLeft ? 8 : 26),
              ),
              border: Border.all(color: _paperEdge, width: 1.5),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: switch (_view) {
                _BallView.composer => _buildComposer(),
                _BallView.prompts ||
                _BallView.skills ||
                _BallView.snippets => _buildBrowser(),
                _BallView.materialDetail => _buildMaterialDetail(),
                _BallView.editor => _buildEditor(),
                _BallView.settings => _buildSettings(),
                _BallView.account => _buildAccount(),
                _BallView.feedback => _buildFeedback(),
                _BallView.cliHelp => _buildCliHelp(),
                _BallView.collapsed ||
                _BallView.menu => const SizedBox.shrink(),
              },
            ),
          ),
          // Invisible resize grips along the three non-docked edges (and the
          // two opposite corners). Only the native Windows build resizes; the
          // docked side never gets a handle so the ball stays glued to the
          // screen edge while the panel grows or shrinks.
          if (_isNative)
            LayoutBuilder(
              builder: (context, constraints) => Stack(
                children: _buildResizeHandles(
                  constraints.maxWidth,
                  constraints.maxHeight,
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildResizeHandles(double width, double height) {
    final dock = _dockEdge;
    final canLeft = dock != BallDockEdge.left;
    final canRight = dock != BallDockEdge.right;
    final canTop = dock != BallDockEdge.top;
    final canBottom = dock != BallDockEdge.bottom;
    final handles = <Widget>[];

    void edgeHandle({
      bool left = false,
      bool right = false,
      bool top = false,
      bool bottom = false,
      required PanelResizeEdge edge,
      required SystemMouseCursor cursor,
    }) {
      final horizontal = left || right;
      final vertical = top || bottom;
      // Vertical strips must anchor top+bottom (and vice versa) so the grip
      // gets a tight cross-axis constraint instead of an unbounded one.
      handles.add(
        Positioned(
          left: left ? 0 : (vertical ? 0 : null),
          right: right ? 0 : (vertical ? 0 : null),
          top: top ? 0 : (horizontal ? 0 : null),
          bottom: bottom ? 0 : (horizontal ? 0 : null),
          width: horizontal ? _resizeGrip : null,
          height: vertical ? _resizeGrip : null,
          child: _ResizeGrip(
            key: Key('panel-resize-${edge.name}'),
            edge: edge,
            cursor: cursor,
            onDragStart: _beginPanelResize,
          ),
        ),
      );
    }

    void cornerHandle({
      required bool left,
      required bool top,
      required PanelResizeEdge edge,
      required SystemMouseCursor cursor,
    }) {
      // Anchor the hit target to the real panel corner and add it after the
      // one-axis edge strips so a natural corner grab selects diagonal
      // resizing. The native rounded window region clips only the pixels
      // outside the visible curve; the remaining part stays hit-testable.
      handles.add(
        Positioned(
          left: left ? 0 : null,
          right: left ? null : 0,
          top: top ? 0 : null,
          bottom: top ? null : 0,
          width: _resizeCorner,
          height: _resizeCorner,
          child: _ResizeGrip(
            key: Key('panel-resize-${edge.name}'),
            edge: edge,
            cursor: cursor,
            onDragStart: _beginPanelResize,
          ),
        ),
      );
    }

    if (canLeft) {
      edgeHandle(
        left: true,
        edge: PanelResizeEdge.left,
        cursor: SystemMouseCursors.resizeLeftRight,
      );
    }
    if (canRight) {
      edgeHandle(
        right: true,
        edge: PanelResizeEdge.right,
        cursor: SystemMouseCursors.resizeLeftRight,
      );
    }
    if (canTop) {
      edgeHandle(
        top: true,
        edge: PanelResizeEdge.top,
        cursor: SystemMouseCursors.resizeUpDown,
      );
    }
    if (canBottom) {
      edgeHandle(
        bottom: true,
        edge: PanelResizeEdge.bottom,
        cursor: SystemMouseCursors.resizeUpDown,
      );
    }
    if (canLeft && canTop) {
      cornerHandle(
        left: true,
        top: true,
        edge: PanelResizeEdge.topLeft,
        cursor: SystemMouseCursors.resizeUpLeftDownRight,
      );
    }
    if (canRight && canTop) {
      cornerHandle(
        left: false,
        top: true,
        edge: PanelResizeEdge.topRight,
        cursor: SystemMouseCursors.resizeUpRightDownLeft,
      );
    }
    if (canLeft && canBottom) {
      cornerHandle(
        left: true,
        top: false,
        edge: PanelResizeEdge.bottomLeft,
        cursor: SystemMouseCursors.resizeUpRightDownLeft,
      );
    }
    if (canRight && canBottom) {
      cornerHandle(
        left: false,
        top: false,
        edge: PanelResizeEdge.bottomRight,
        cursor: SystemMouseCursors.resizeUpLeftDownRight,
      );
    }
    return handles;
  }

  EdgeInsets get _panelInsets {
    final ballDiameter = _arcConfig.ballDiameter;
    return switch (_dockEdge) {
      BallDockEdge.left => EdgeInsets.fromLTRB(
        ballDiameter,
        8,
        8,
        ballDiameter,
      ),
      BallDockEdge.top => EdgeInsets.fromLTRB(
        8,
        ballDiameter + 4,
        ballDiameter,
        8,
      ),
      BallDockEdge.right || BallDockEdge.bottom => EdgeInsets.fromLTRB(
        8,
        8,
        ballDiameter,
        ballDiameter,
      ),
    };
  }

  // ============================================================
  // panel header
  // ============================================================

  Widget _panelHeader({
    required String title,
    required String subtitle,
    VoidCallback? onBack,
    int subtitleMaxLines = 1,
  }) {
    final isLeft = _dockEdge == BallDockEdge.left;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 10, 11),
      decoration: const BoxDecoration(
        color: Color(0xFFFFF7EA),
        border: Border(bottom: BorderSide(color: _paperEdge)),
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            key: const Key('panel-back'),
            tooltip: _s.backToMenu,
            visualDensity: VisualDensity.compact,
            onPressed: onBack ?? () => _go(_BallView.menu),
            icon: Icon(
              isLeft ? Icons.arrow_forward_rounded : Icons.arrow_back_rounded,
            ),
          ),
          const SizedBox(width: 5),
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: _orange,
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(
              Icons.edit_note_rounded,
              color: Colors.white,
              size: 19,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  subtitle,
                  maxLines: subtitleMaxLines,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF847C71),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: _s.collapsePanel,
            onPressed: () => _go(_BallView.collapsed),
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // composer view (unchanged)
  // ============================================================

  Widget _buildComposer() {
    final prompts = _items
        .where((item) => item.type == ItemType.prompt)
        .toList(growable: false);
    return Column(
      children: <Widget>[
        _panelHeader(title: _s.menuCompose, subtitle: _s.composerSubtitle),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  _s.choosePrompt,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 7),
                SizedBox(
                  height: 36,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: prompts.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 7),
                    itemBuilder: (context, index) {
                      final prompt = prompts[index];
                      final selected = prompt.id == _selectedPromptId;
                      return ChoiceChip(
                        selected: selected,
                        onSelected: (_) => _selectPrompt(prompt),
                        label: Text(prompt.title),
                        selectedColor: const Color(0xFFFFDDCC),
                        side: BorderSide(
                          color: selected ? _orange : const Color(0xFFDDD4C8),
                        ),
                        showCheckmark: false,
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                _EditorBox(
                  label: _s.inputLabel,
                  height: 130,
                  action: TextButton.icon(
                    onPressed: _pasteInput,
                    icon: const Icon(Icons.content_paste_go_outlined, size: 16),
                    label: Text(_s.paste),
                  ),
                  child: TextField(
                    key: const Key('ball-composer-input'),
                    controller: _inputController,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: _s.inputHint,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: _EditorBox(
                    label: _s.resultLabel,
                    action: TextButton.icon(
                      key: const Key('copy-result'),
                      onPressed: _copyResult,
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      label: Text(_s.copy),
                    ),
                    child: _result.isEmpty
                        ? Center(
                            child: Text(
                              _s.resultPlaceholder,
                              style: const TextStyle(color: Color(0xFFAAA195)),
                            ),
                          )
                        : SingleChildScrollView(
                            child: SelectableText(
                              _result,
                              key: const Key('ball-composer-result'),
                              style: const TextStyle(height: 1.5, fontSize: 13),
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ============================================================
  // browser view (unchanged)
  // ============================================================

  Widget _buildBrowser() {
    final title = _s.typeName(_browserType);
    final subtitle = _s.browserSubtitle(_browserType);
    final hint = _s.searchHint(_browserType);
    final items = _browserItems;
    final categories = _browserCategories;
    final visibleCategories = _visibleBrowserCategories(categories);
    final hasUncategorized = _items.any(
      (item) => item.type == _browserType && item.category.isEmpty,
    );
    List<Widget> buildCategoryChips(double chipWidth) {
      final specialCategoryChips = <Widget>[
        _buildCategoryChip(
          key: const Key('category-all'),
          category: _s.all,
          selected: _selectedCategory == null,
          onSelected: (_) => _selectBrowserCategory(null),
          width: chipWidth,
        ),
        if (hasUncategorized)
          _buildCategoryChip(
            key: const Key('category-uncategorized'),
            category: _s.uncategorized,
            selected: _selectedCategory == '',
            onSelected: (_) => _selectBrowserCategory(''),
            width: chipWidth,
          ),
      ];
      final normalCategoryChips = <Widget>[
        for (final category in visibleCategories)
          _buildCategoryChip(
            key: ValueKey('category-$category'),
            category: category,
            selected: _selectedCategory == category,
            onSelected: (_) => _selectBrowserCategory(category),
            width: chipWidth,
            onSecondaryTapDown: (details) =>
                _showCategoryContextMenu(category, details.globalPosition),
          ),
      ];
      return categories.length > 3
          ? <Widget>[...normalCategoryChips, ...specialCategoryChips]
          : <Widget>[...specialCategoryChips, ...normalCategoryChips];
    }

    final canReorder =
        _sortMode == ItemSortMode.custom &&
        _searchController.text.trim().isEmpty;
    return Column(
      children: <Widget>[
        _panelHeader(title: title, subtitle: subtitle),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 6),
          child: TextField(
            key: const Key('ball-search'),
            controller: _searchController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: hint,
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: _s.clearSearch,
                      onPressed: () {
                        _searchController.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
              isDense: true,
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(13),
                borderSide: const BorderSide(color: _paperEdge),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(13),
                borderSide: const BorderSide(color: _paperEdge),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              const Icon(
                Icons.star_rounded,
                size: 18,
                color: Color(0xFFE4A327),
              ),
              const SizedBox(width: 4),
              Text(_s.ratingLabel, style: const TextStyle(fontSize: 12)),
              const Spacer(),
              Text(
                _s.countItems(items.length),
                style: const TextStyle(color: Color(0xFF81796E), fontSize: 12),
              ),
              const SizedBox(width: 4),
              PopupMenuButton<ItemSortMode>(
                key: const Key('sort-menu'),
                tooltip: _s.sortTooltip,
                onOpened: _beginPopupMenuInteraction,
                onCanceled: _endPopupMenuInteraction,
                onSelected: (mode) {
                  _endPopupMenuInteraction();
                  unawaited(_setSortMode(mode));
                },
                itemBuilder: (_) => ItemSortMode.values
                    .map(
                      (mode) => PopupMenuItem(
                        value: mode,
                        child: Row(
                          children: [
                            if (_sortMode == mode)
                              const Icon(Icons.check_rounded, size: 17)
                            else
                              const SizedBox(width: 17),
                            const SizedBox(width: 8),
                            Text(_sortLabel(mode)),
                          ],
                        ),
                      ),
                    )
                    .toList(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.swap_vert_rounded, size: 18),
                      const SizedBox(width: 3),
                      Text(
                        _sortLabel(_sortMode),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                key: const Key('create-category'),
                tooltip: _s.newCategory,
                visualDensity: VisualDensity.compact,
                onPressed: _createCategory,
                icon: const Icon(Icons.create_new_folder_outlined, size: 19),
              ),
              IconButton(
                key: const Key('manage-categories'),
                tooltip: _s.manageCategories,
                visualDensity: VisualDensity.compact,
                onPressed: _manageCategories,
                icon: const Icon(Icons.folder_open_rounded, size: 19),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 14, 5),
          child: _RatingFilter(
            rating: _ratingFilter,
            onRatingChanged: (rating) => setState(() => _ratingFilter = rating),
          ),
        ),
        if (categories.isNotEmpty || hasUncategorized)
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            alignment: Alignment.topCenter,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final hasToggle = categories.length > 3;
                // Reserve the expand button and scroll padding before sizing
                // the three visible chips. This prevents the third chip from
                // clipping inside the native browser panel.
                final compactChipWidth = math
                    .min(
                      _categoryChipWidth,
                      (constraints.maxWidth -
                              (hasToggle ? 40 : 0) -
                              18 -
                              _categoryChipGap * 2) /
                          3,
                    )
                    .toDouble();
                final categoryChips = buildCategoryChips(
                  _categoriesExpanded ? _categoryChipWidth : compactChipWidth,
                );
                return SizedBox(
                  height: _categoriesExpanded ? 92 : 39,
                  child: Row(
                    children: [
                      Expanded(
                        child: _categoriesExpanded
                            ? SingleChildScrollView(
                                padding: const EdgeInsets.fromLTRB(14, 2, 4, 4),
                                child: Wrap(
                                  spacing: _categoryChipGap,
                                  runSpacing: _categoryChipGap,
                                  children: categoryChips,
                                ),
                              )
                            : SingleChildScrollView(
                                key: const Key('collapsed-category-scroll'),
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsets.fromLTRB(14, 2, 4, 4),
                                child: Row(
                                  children: [
                                    for (
                                      var index = 0;
                                      index < categoryChips.length;
                                      index++
                                    ) ...[
                                      if (index > 0)
                                        const SizedBox(width: _categoryChipGap),
                                      categoryChips[index],
                                    ],
                                  ],
                                ),
                              ),
                      ),
                      if (hasToggle)
                        SizedBox(
                          width: 40,
                          height: 34,
                          child: IconButton(
                            key: const Key('toggle-categories-expanded'),
                            tooltip: _categoriesExpanded
                                ? _s.collapseCategories
                                : _s.expandCategories,
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              _categoriesExpanded
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              size: 20,
                            ),
                            onPressed: () => setState(
                              () => _categoriesExpanded = !_categoriesExpanded,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Text(
                    _searchController.text.trim().isNotEmpty ||
                            _ratingFilter != null ||
                            _selectedCategory != null
                        ? _s.noMatchingItems
                        : _s.emptyType,
                    style: const TextStyle(color: Color(0xFF81796E)),
                  ),
                )
              : ListView.separated(
                  controller: _browserScrollController,
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return _MaterialSlip(
                      key: ValueKey(item.id),
                      item: item,
                      onRating: (rating) => _setRating(item, rating),
                      onEdit: () => _editItem(item),
                      onDelete: () => _deleteItem(item),
                      onMoveUp: canReorder && index > 0
                          ? () => _moveItem(item, -1)
                          : null,
                      onMoveDown: canReorder && index < items.length - 1
                          ? () => _moveItem(item, 1)
                          : null,
                      onPopupOpened: () {
                        _beginPopupMenuInteraction();
                      },
                      onPopupClosed: _endPopupMenuInteraction,
                      secondaryActionLabel: switch (item.type) {
                        ItemType.prompt => _s.actionCompose,
                        ItemType.skill || ItemType.snippet => _s.copy,
                      },
                      secondaryActionNotice:
                          item.type == ItemType.skill ||
                              item.type == ItemType.snippet
                          ? _s.copiedCheck
                          : null,
                      onSecondaryAction: switch (item.type) {
                        ItemType.prompt => () => _composeWithPrompt(item),
                        ItemType.skill || ItemType.snippet => () => _copyItem(
                          item,
                          showNotice: false,
                        ),
                      },
                      actionLabel: _s.actionView,
                      onAction: () => unawaited(_openMaterialDetail(item)),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: OutlinedButton.icon(
            key: Key(
              _browserType == ItemType.skill
                  ? 'create-or-import-skill'
                  : 'create-item',
            ),
            onPressed: _browserType == ItemType.skill
                ? (_skillImportBusy ? null : _chooseSkillCreation)
                : () => _openEditor(
                    _browserType,
                    _selectedCategory?.isNotEmpty == true
                        ? _selectedCategory
                        : null,
                  ),
            icon: _browserType == ItemType.skill && _skillImportBusy
                ? const SizedBox.square(
                    dimension: 17,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_rounded),
            label: Text(
              _browserType == ItemType.skill
                  ? (_skillImportBusy ? _s.readingSkill : _s.newOrImportSkill)
                  : _s.newItemOfType(_browserType),
            ),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(42),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMaterialDetail() {
    final item = _selectedMaterial;
    if (item == null) {
      return Column(
        children: <Widget>[
          _panelHeader(
            title: _s.itemDetailTitle,
            subtitle: _s.noItemSelected,
            onBack: () => _go(_browserViewFor(_browserType)),
          ),
          Expanded(
            child: Center(
              child: Text(
                _s.goBackAndSelect,
                style: const TextStyle(color: Color(0xFF81796E)),
              ),
            ),
          ),
        ],
      );
    }
    if (item.type != ItemType.skill) return _buildTextMaterialDetail(item);
    return Column(
      children: <Widget>[
        _panelHeader(
          title: item.title,
          subtitle: _s.skillDetailSubtitle,
          onBack: () => _go(_browserViewFor(item.type)),
        ),
        Expanded(
          child: SkillPackageBrowser(
            key: ValueKey('skill-package-${item.id}'),
            skill: item,
            repository: widget.skillPackages,
            onNotice: (message) => _showNotice(message, success: true),
          ),
        ),
      ],
    );
  }

  _BallView _browserViewFor(ItemType type) => switch (type) {
    ItemType.prompt => _BallView.prompts,
    ItemType.skill => _BallView.skills,
    ItemType.snippet => _BallView.snippets,
  };

  Widget _buildTextMaterialDetail(JianheItem item) {
    final isPrompt = item.type == ItemType.prompt;
    return Column(
      children: <Widget>[
        _panelHeader(
          title: item.title,
          subtitle: isPrompt
              ? _s.promptDetailSubtitle
              : _s.snippetDetailSubtitle,
          onBack: () => _go(_browserViewFor(item.type)),
        ),
        Expanded(
          child: SingleChildScrollView(
            key: Key('material-detail-scroll-${item.id}'),
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              item.content,
              key: Key('material-detail-content-${item.id}'),
              style: const TextStyle(fontSize: 13, height: 1.55),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
          child: Row(
            children: <Widget>[
              if (isPrompt) ...[
                Expanded(
                  child: OutlinedButton.icon(
                    key: Key('material-detail-compose-${item.id}'),
                    onPressed: () => _composeWithPrompt(item),
                    icon: const Icon(Icons.auto_awesome_rounded, size: 17),
                    label: Text(_s.openInComposer),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: FilledButton.icon(
                  key: Key('material-detail-copy-${item.id}'),
                  onPressed: () => _copyItem(item),
                  icon: const Icon(Icons.copy_rounded, size: 17),
                  label: Text(_s.copyContent),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(42),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _sortLabel(ItemSortMode mode) => _s.sortLabel(mode);

  // ============================================================
  // editor view (unchanged)
  // ============================================================

  Widget _buildEditor() {
    final editingIndex = _items.indexWhere((item) => item.id == _editingItemId);
    final editingItem = editingIndex < 0 ? null : _items[editingIndex];
    final editingSkill = editingItem?.type == ItemType.skill;
    final creatingSkill = editingItem == null && _editorType == ItemType.skill;
    final skillForm = editingSkill || creatingSkill;
    final editorCategories = _editorCategories;
    final selectedEditorCategory =
        editorCategories.contains(_editorCategoryController.text)
        ? _editorCategoryController.text
        : '';
    return Column(
      children: <Widget>[
        _panelHeader(
          title: editingSkill
              ? _s.editSkill
              : creatingSkill
              ? _s.newSkill
              : _editingItemId == null
              ? _s.newItem
              : _s.editItem,
          subtitle: editingSkill
              ? _s.editSkillSubtitle
              : creatingSkill
              ? _s.newSkillSubtitle
              : _editingItemId == null
              ? _s.newItemSubtitle
              : _s.editItemSubtitle,
          onBack: skillForm ? () => _openBrowser(ItemType.skill) : null,
          subtitleMaxLines: skillForm ? 2 : 1,
        ),
        Expanded(
          child: Scrollbar(
            controller: _editorScrollController,
            thumbVisibility: skillForm,
            child: ListView(
              key: const Key('editor-scroll'),
              controller: _editorScrollController,
              padding: EdgeInsets.fromLTRB(16, 16, skillForm ? 22 : 16, 16),
              children: <Widget>[
                if (skillForm)
                  Container(
                    key: const Key('skill-type-locked'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEAF0FA),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFC9D6EC)),
                    ),
                    child: Row(
                      children: <Widget>[
                        const Icon(
                          Icons.lock_outline_rounded,
                          size: 18,
                          color: Color(0xFF476FB8),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            editingSkill
                                ? _s.skillTypeLocked
                                : _s.creatingSingleFileSkill,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  SegmentedButton<ItemType>(
                    segments: <ButtonSegment<ItemType>>[
                      const ButtonSegment(
                        value: ItemType.prompt,
                        label: Text('Prompt'),
                      ),
                      const ButtonSegment(
                        value: ItemType.skill,
                        label: Text('Skill'),
                      ),
                      ButtonSegment(
                        value: ItemType.snippet,
                        label: Text(_s.segmentSnippet),
                      ),
                    ],
                    selected: <ItemType>{_editorType},
                    onSelectionChanged: (selection) {
                      _selectEditorType(selection.single);
                    },
                  ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('editor-title'),
                  controller: _editorTitleController,
                  maxLength: JianheItem.maxTitleLength,
                  decoration: InputDecoration(
                    labelText: skillForm ? _s.skillNameLabel : _s.detailName,
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                InputDecorator(
                  decoration: InputDecoration(
                    labelText: _s.categoryOptionalLabel,
                    helperText: _s.categoryHelper,
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                  child: Tooltip(
                    message: _s.chooseExistingCategory,
                    child: InkWell(
                      key: const Key('editor-category'),
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _chooseEditorCategory(editorCategories),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              selectedEditorCategory.isEmpty
                                  ? _s.uncategorized
                                  : selectedEditorCategory,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const Icon(Icons.arrow_drop_down_rounded),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('editor-content'),
                  controller: _editorContentController,
                  minLines: skillForm ? 5 : 9,
                  maxLines: skillForm ? 10 : 14,
                  decoration: InputDecoration(
                    labelText: skillForm ? 'SKILL.md' : _s.contentLabel,
                    alignLabelWithHint: true,
                    hintText: skillForm
                        ? editingSkill
                              ? _s.skillEditHint
                              : _s.skillCreateHint
                        : _editorType == ItemType.prompt
                        ? _s.promptHint
                        : _s.snippetHint,
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                ),
                if (editingSkill) ...[
                  const SizedBox(height: 14),
                  _buildReadOnlySkillFiles(),
                ],
                if (!skillForm) ...[
                  const SizedBox(height: 14),
                  _buildSaveItemButton(),
                ],
                if (_editingItemId != null) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const Key('delete-item'),
                    onPressed: () {
                      final editingIndex = _items.indexWhere(
                        (candidate) => candidate.id == _editingItemId,
                      );
                      if (editingIndex < 0) return;
                      _deleteItem(_items[editingIndex]);
                    },
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: Text(editingSkill ? _s.deleteSkill : _s.deleteItem),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                      minimumSize: const Size.fromHeight(42),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (skillForm)
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            decoration: const BoxDecoration(
              color: Color(0xFFFFF7EA),
              border: Border(top: BorderSide(color: _paperEdge)),
            ),
            child: _buildSaveItemButton(
              label: creatingSkill ? _s.createSkill : null,
            ),
          ),
      ],
    );
  }

  Widget _buildSaveItemButton({String? label}) {
    return FilledButton.icon(
      key: const Key('save-item'),
      onPressed: _savingItem ? null : _saveItem,
      icon: _savingItem
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.archive_outlined),
      label: Text(
        _savingItem
            ? _s.saving
            : label ??
                  (_editingItemId == null ? _s.saveToJianhe : _s.saveChanges),
      ),
      style: FilledButton.styleFrom(
        backgroundColor: _orange,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(46),
      ),
    );
  }

  Widget _buildReadOnlySkillFiles() {
    final files = _editingSkillFiles;
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(13),
        side: const BorderSide(color: Color(0xFFE5DCD0)),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: const Key('skill-auxiliary-files-readonly'),
        initiallyExpanded: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        leading: const Icon(
          Icons.folder_copy_outlined,
          size: 18,
          color: Color(0xFF476FB8),
        ),
        title: Text(
          _s.supportingFilesReadOnly,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          _s.supportingFilesHint,
          style: const TextStyle(color: Color(0xFF81796E), fontSize: 11),
        ),
        children: <Widget>[
          if (files == null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _s.supportingFilesNoStorage,
                style: const TextStyle(color: Color(0xFF81796E), fontSize: 12),
              ),
            )
          else
            FutureBuilder<List<SkillFileMetadata>>(
              future: files,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                if (snapshot.hasError) {
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _s.supportingFilesUnreadableKept,
                      style: const TextStyle(
                        color: Color(0xFF81796E),
                        fontSize: 12,
                      ),
                    ),
                  );
                }
                final metadata = snapshot.data ?? const <SkillFileMetadata>[];
                if (metadata.isEmpty) {
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _s.supportingFilesNone,
                      style: const TextStyle(
                        color: Color(0xFF81796E),
                        fontSize: 12,
                      ),
                    ),
                  );
                }
                return ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 190),
                  child: ListView.separated(
                    key: const Key('skill-auxiliary-file-list'),
                    shrinkWrap: true,
                    itemCount: metadata.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final file = metadata[index];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.insert_drive_file_outlined,
                          size: 18,
                        ),
                        title: Tooltip(
                          message: file.relativePath,
                          child: Text(
                            file.relativePath,
                            key: Key(
                              'readonly-skill-file-${file.relativePath}',
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        subtitle: Text(
                          '${file.mediaType ?? _s.binaryFile} · '
                          '${_formatSkillFileBytes(file.byteLength)}',
                          style: const TextStyle(fontSize: 10),
                        ),
                        trailing: const Icon(
                          Icons.lock_outline_rounded,
                          size: 15,
                          color: Color(0xFF9A9186),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  String _formatSkillFileBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // ============================================================
  // settings view (unchanged)
  // ============================================================

  Widget _buildSettings() {
    return Column(
      children: <Widget>[
        _panelHeader(title: _s.menuMore, subtitle: _s.moreSubtitle),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(14),
            children: <Widget>[
              if (widget.appUpdateController != null &&
                  _appUpdateLeadsSettings) ...<Widget>[
                _buildAppUpdateSlip(widget.appUpdateController!),
                const SizedBox(height: 9),
              ],
              _SettingSlip(
                icon: Icons.terminal_rounded,
                color: const Color(0xFF476FB8),
                title: _s.cliAccessTitle,
                subtitle: _s.cliAccessSubtitle,
                trailing: Switch(
                  key: const Key('command-line-interface-switch'),
                  value: _cliAccessMode == CliAccessMode.readWrite,
                  onChanged: _setCliAccess,
                ),
              ),
              const SizedBox(height: 9),
              _SettingSlip(
                icon: Icons.menu_book_outlined,
                color: const Color(0xFF476FB8),
                title: _s.cliGuideTitle,
                subtitle: _s.cliGuideEntrySubtitle,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _go(_BallView.cliHelp),
              ),
              const SizedBox(height: 9),
              _AutoCollapseSetting(
                seconds: _autoCollapseSeconds,
                onChanged: _previewAutoCollapseSeconds,
                onChangeEnd: _saveAutoCollapseSeconds,
              ),
              const SizedBox(height: 9),
              _SettingSlip(
                key: const Key('export-backup-setting'),
                icon: Icons.archive_outlined,
                color: _orange,
                title: _s.exportAllTitle,
                subtitle: widget.localStorageUnavailable
                    ? _s.exportDisabled
                    : _s.exportSubtitle,
                trailing: _backupBusy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.file_download_outlined),
                onTap: _backupBusy || widget.localStorageUnavailable
                    ? null
                    : _exportBackup,
              ),
              const SizedBox(height: 9),
              _SettingSlip(
                key: const Key('import-backup-setting'),
                icon: Icons.unarchive_outlined,
                color: _green,
                title: _s.importTransferTitle,
                subtitle: widget.localStorageUnavailable
                    ? _s.importDisabled
                    : _s.importSubtitle,
                trailing: const Icon(Icons.file_upload_outlined),
                onTap: _backupBusy || widget.localStorageUnavailable
                    ? null
                    : _importBackup,
              ),
              const SizedBox(height: 9),
              _SettingSlip(
                icon: Icons.keyboard_command_key_rounded,
                color: _green,
                title: _s.wakeHotKeyTitle,
                subtitle: _wakeHotKeyAvailable
                    ? _s.hotKeyRegistered(_wakeHotKey.displayLabel)
                    : _s.hotKeyRegistrationFailed(_wakeHotKey.displayLabel),
                trailing: Icon(
                  _wakeHotKeyAvailable
                      ? Icons.check_circle_outline_rounded
                      : Icons.warning_amber_rounded,
                  color: _wakeHotKeyAvailable ? _green : _orange,
                ),
                onTap: _wakeHotKeySaving ? null : _chooseWakeHotKey,
              ),
              const SizedBox(height: 9),
              _SettingSlip(
                key: const Key('account-settings-entry'),
                icon: Icons.account_circle_outlined,
                color: _green,
                title: _s.accountTitle,
                subtitle: _accountSettingsSubtitle,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _go(_BallView.account),
              ),
              const SizedBox(height: 9),
              _SettingSlip(
                key: const Key('cloud-portal-entry'),
                icon: Icons.open_in_browser_rounded,
                color: const Color(0xFF476FB8),
                title: _s.cloudConsoleTitle,
                subtitle: _s.cloudConsoleSubtitle,
                trailing: const Icon(Icons.open_in_new_rounded),
                onTap: _openCloudPortal,
              ),
              const SizedBox(height: 9),
              _SettingSlip(
                key: const Key('feedback-settings-entry'),
                icon: Icons.feedback_outlined,
                color: _orange,
                title: _s.feedbackTitle,
                subtitle: _s.feedbackEntrySubtitle,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _go(_BallView.feedback),
              ),
              if (widget.appUpdateController != null &&
                  !_appUpdateLeadsSettings) ...<Widget>[
                const SizedBox(height: 9),
                _buildAppUpdateSlip(widget.appUpdateController!),
              ],
              ..._buildLanguageSetting(),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: widget.windowController.quit,
                icon: const Icon(Icons.power_settings_new_rounded),
                label: Text(_s.quitJianhe),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFA53E36),
                  minimumSize: const Size.fromHeight(44),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// The language switch, offered only where the choice can be saved.
  List<Widget> _buildLanguageSetting() {
    final changeLanguage = AppLanguageScope.read(context)?.onLanguageChanged;
    if (changeLanguage == null || widget.localStorageUnavailable) {
      return const <Widget>[];
    }
    return <Widget>[
      const SizedBox(height: 9),
      _SettingSlip(
        key: const Key('language-setting'),
        icon: Icons.translate_rounded,
        color: const Color(0xFF476FB8),
        title: _s.languageTitle,
        subtitle: _s.languageSubtitle,
        trailing: SegmentedButton<AppLanguage>(
          key: const Key('language-switch'),
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          segments: const <ButtonSegment<AppLanguage>>[
            ButtonSegment(
              value: AppLanguage.zh,
              label: Text('中', key: Key('language-zh')),
            ),
            ButtonSegment(
              value: AppLanguage.en,
              label: Text('EN', key: Key('language-en')),
            ),
          ],
          selected: <AppLanguage>{_s.language},
          onSelectionChanged: (selection) => changeLanguage(selection.single),
        ),
      ),
    ];
  }

  Future<void> _openCloudPortal() async {
    final url = cloudPortalUrlFor(widget.cloudPortalUrl, _s.language);
    final opened = await const ExternalUrlLauncher().open(url);
    if (!opened && mounted) {
      _showNotice(_s.noticeBrowserUnavailable(url));
    }
  }

  Widget _buildFeedback() {
    final controller = _feedbackController;
    return Column(
      children: <Widget>[
        _panelHeader(
          title: _s.feedbackTitle,
          subtitle: _s.feedbackPanelSubtitle,
          onBack: () => _go(_BallView.settings),
        ),
        Expanded(
          child: controller == null
              ? Center(child: Text(_s.feedbackNotConfigured))
              : FeedbackPanel(
                  controller: controller,
                  account: _accountController,
                  onLogin: () => _go(_BallView.account),
                ),
        ),
      ],
    );
  }

  Widget _buildAccount() {
    return Column(
      children: <Widget>[
        _panelHeader(
          title: _s.accountTitle,
          subtitle: widget.localStorageUnavailable
              ? _s.accountPanelSubtitleDisabled
              : _s.accountPanelSubtitle,
          onBack: () => _go(_BallView.settings),
        ),
        Expanded(
          child: AccountPanel(
            controller: _accountController,
            syncController: widget.localStorageUnavailable
                ? null
                : widget.syncController,
            createBackup: widget.localStorageUnavailable
                ? null
                : _createBackupSnapshot,
            dialogPresenter: _showPanelDialog,
          ),
        ),
      ],
    );
  }

  String get _accountSettingsSubtitle {
    if (!_accountController.configured) return _s.accountNotConfigured;
    if (_accountController.status == AccountSessionStatus.restoring) {
      return _s.accountRestoring;
    }
    final account = _accountController.account;
    if (account == null) return _s.accountSignedOut;
    final planLabel = account.entitlement.isVip
        ? 'VIP'
        : account.entitlement.isCloudBackupReadOnly
        ? _s.planReadOnlyGrace
        : _s.planFree;
    final label = account.displayLabel;
    return '$label · $planLabel';
  }

  void _handleAccountChanged() {
    if (mounted) setState(() {});
  }

  void _handleAppUpdateChanged() {
    _syncMoreBadge();
    if (mounted) setState(() {});
  }

  /// Whether the update entry leads the 更多 list. Captured when the page is
  /// entered (see [_view]) rather than read live: an entry that moved while
  /// the user was looking at it would leave the row under the pointer to
  /// the next setting (问题反馈), and a second tap would open that instead.
  bool _appUpdateLeadsSettings = false;

  /// True while a release is offered, downloading, waiting to install or
  /// installing. Errors stay where the user tapped: they answer that tap.
  bool get _appUpdateNeedsAttention {
    final status = widget.appUpdateController?.status;
    return _appUpdateRecheckingKnownRelease ||
        status == AppUpdateStatus.available ||
        status == AppUpdateStatus.downloading ||
        status == AppUpdateStatus.ready ||
        status == AppUpdateStatus.installing;
  }

  /// A periodic check passing over an already offered release: it still
  /// counts as waiting, so neither the dot nor the entry blinks meanwhile.
  bool get _appUpdateRecheckingKnownRelease {
    final controller = widget.appUpdateController;
    return controller != null &&
        controller.status == AppUpdateStatus.checking &&
        controller.manifest != null;
  }

  /// Red dot on the 更多 action while a new version waits for the user.
  bool get _moreBadgeVisible {
    final status = widget.appUpdateController?.status;
    return _appUpdateRecheckingKnownRelease ||
        status == AppUpdateStatus.available ||
        status == AppUpdateStatus.ready;
  }

  bool? _sentMoreBadge;

  /// Mirrors [_moreBadgeVisible] to the native orbit menu, once per change.
  void _syncMoreBadge() {
    final visible = _moreBadgeVisible;
    if (_sentMoreBadge == visible) return;
    _sentMoreBadge = visible;
    unawaited(widget.windowController.setMoreBadge(visible));
  }

  /// A check the user asked for: the entry updates in place, and a notice
  /// says how it ended so the result is noticed even at a glance.
  Future<void> _checkAppUpdateNow(AppUpdateController controller) async {
    if (controller.busy) return;
    await controller.checkNow(userInitiated: true);
    if (!mounted) return;
    final next = controller.manifest?.version.toString();
    switch (controller.status) {
      case AppUpdateStatus.upToDate:
        _showNotice(
          _s.updateUpToDate(controller.currentVersion.toString()),
          success: true,
        );
      case AppUpdateStatus.available:
        _showNotice(_s.updateAvailable(next), success: true);
      case AppUpdateStatus.ready:
        _showNotice(_s.updateReady(next), success: true);
      case AppUpdateStatus.error:
        _showNotice(_s.updateCheckFailed);
      case AppUpdateStatus.idle ||
          AppUpdateStatus.checking ||
          AppUpdateStatus.downloading ||
          AppUpdateStatus.installing:
        break;
    }
  }

  Widget _buildAppUpdateSlip(AppUpdateController controller) {
    final current = controller.currentVersion.toString();
    final next = controller.manifest?.version.toString();
    final notes = controller.manifest?.notes ?? '';
    const spinner = SizedBox(
      width: 20,
      height: 20,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
    late final String title;
    late final String subtitle;
    late final Widget trailing;
    VoidCallback? onTap;
    var highlight = false;
    switch (controller.status) {
      case AppUpdateStatus.idle:
        title = _s.updateCheck;
        subtitle = _s.updateCurrentVersion(current);
        trailing = const Icon(Icons.refresh_rounded);
        onTap = () => unawaited(_checkAppUpdateNow(controller));
      case AppUpdateStatus.checking:
        title = _s.updateChecking;
        subtitle = _s.updateCurrentVersion(current);
        trailing = spinner;
      case AppUpdateStatus.upToDate:
        title = _s.updateCheck;
        subtitle = _s.updateUpToDate(current);
        trailing = const Icon(Icons.refresh_rounded);
        onTap = () => unawaited(_checkAppUpdateNow(controller));
      case AppUpdateStatus.available:
        highlight = true;
        title = _s.updateAvailable(next);
        subtitle =
            controller.message ??
            (notes.isNotEmpty ? notes : _s.updateAvailableHint(current));
        trailing = const Icon(Icons.download_rounded);
        onTap = () => unawaited(controller.download());
      case AppUpdateStatus.downloading:
        highlight = true;
        title = _s.updateDownloading(next);
        subtitle = _s.updateDownloadingHint(
          (controller.progress * 100).floor(),
        );
        trailing = SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            value: controller.progress == 0 ? null : controller.progress,
          ),
        );
      case AppUpdateStatus.ready:
        highlight = true;
        title = _s.updateReady(next);
        subtitle = controller.message ?? _s.updateReadyHint;
        trailing = const Icon(Icons.system_update_alt_rounded);
        onTap = () => unawaited(_installAppUpdate(controller));
      case AppUpdateStatus.installing:
        highlight = true;
        title = _s.updateInstalling;
        subtitle = _s.updateInstallingHint;
        trailing = spinner;
      case AppUpdateStatus.error:
        highlight = true;
        final retryDownload = controller.manifest != null;
        title = retryDownload
            ? _s.updateDownloadFailed(next)
            : _s.updateCheckFailed;
        subtitle = _s.updateRetryHint(controller.message);
        trailing = const Icon(Icons.refresh_rounded);
        onTap = retryDownload
            ? () => unawaited(controller.download())
            : () => unawaited(_checkAppUpdateNow(controller));
    }
    return _SettingSlip(
      key: const Key('app-update-entry'),
      icon: Icons.system_update_alt_rounded,
      color: highlight ? _orange : const Color(0xFF476FB8),
      title: title,
      subtitle: subtitle,
      trailing: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: KeyedSubtree(
          key: ValueKey<AppUpdateStatus>(controller.status),
          child: trailing,
        ),
      ),
      onTap: onTap,
    );
  }

  Future<void> _installAppUpdate(AppUpdateController controller) async {
    // quit() runs the normal close path, so an unsaved editor draft is
    // flushed before the installer replaces the app.
    await controller.install(quit: widget.windowController.quit);
  }

  Widget _buildCliHelp() {
    return Column(
      children: <Widget>[
        _panelHeader(
          title: _s.cliGuideTitle,
          subtitle: _s.cliGuidePanelSubtitle,
          onBack: () => _go(_BallView.settings),
        ),
        Expanded(
          child: CliHelpPanel(
            cliEnabled: _cliAccessMode == CliAccessMode.readWrite,
            cliExecutablePath: _cliExecutablePath,
            onCopy: _copyCliCommand,
            onCopyRequest: _copyCliRequest,
            onExportGuide: _exportCliGuide,
          ),
        ),
      ],
    );
  }

  Future<void> _copyCliCommand(String command) async {
    await Clipboard.setData(ClipboardData(text: command));
    if (mounted) _showNotice(_s.noticeCommandCopied, success: true);
  }

  Future<void> _copyCliRequest(String request) async {
    await Clipboard.setData(ClipboardData(text: request));
    if (mounted) _showNotice(_s.noticeAiRequestCopied, success: true);
  }

  Future<void> _exportCliGuide() async {
    try {
      final saved = await widget.backupFileService.save(
        buildCliGuideMarkdown(_cliExecutablePath, language: _s.language),
        suggestedName: _s.cliGuideFileName,
        dialogTitle: _s.cliGuideExportDialogTitle,
        filter: _s.cliGuideExportFilter,
      );
      if (mounted && saved) {
        _showNotice(_s.noticeCliGuideExported, success: true);
      }
    } on Object {
      if (mounted) _showNotice(_s.noticeExportFailed);
    }
  }

  Future<JianheBackupMergeResult> _applyBackup(JianheBackup backup) async {
    if (widget.localStorageUnavailable) {
      throw StateError('本地数据库不可用，无法合并备份。');
    }
    final rawSeconds = backup.settings['auto_collapse_seconds'];
    final importedSeconds = rawSeconds is num ? rawSeconds.toInt() : null;
    // 旧备份里的 0 秒归到最低的 1 秒。
    final nextSeconds =
        importedSeconds != null && importedSeconds >= 0 && importedSeconds <= 60
        ? _clampAutoCollapseSeconds(importedSeconds)
        : _autoCollapseSeconds;
    // The backup's `cli_access_mode` is deliberately ignored. It is a
    // per-machine security consent (it lets AI agents read and write the
    // library through the CLI); a .jianhe file from elsewhere must never
    // grant or revoke it silently. Users change it only in settings.

    final repository = widget.repository;
    Future<JianheBackupMergeResult> mergeIntoStorage() async {
      final localItems = repository == null
          ? List<JianheItem>.from(_items)
          : await repository.listAll();
      final merge = backup.mergeItems(localItems);
      final packagesBySkill = <String, SkillPackage>{
        for (final package in backup.skillPackages) package.skillId: package,
      };
      var writtenSinceYield = 0;
      var bytesSinceYield = 0;
      for (final imported in <JianheItem>[...merge.created, ...merge.updated]) {
        // A large backup is written in one transaction (all or nothing), but
        // the panel must keep painting: hand the event loop a turn every
        // 100 items or ~2 MiB of Skill attachments.
        if (writtenSinceYield >= 100 || bytesSinceYield >= 2 << 20) {
          writtenSinceYield = 0;
          bytesSinceYield = 0;
          await Future<void>.delayed(Duration.zero);
        }
        writtenSinceYield++;
        bytesSinceYield += imported.content.length;
        // Only hand the package layer a package the backup actually carries.
        // A missing entry means "this backup has no files for the Skill"
        // (v1 exports never do), not "delete the local files"; saving the
        // item alone keeps the local package and save() refreshes its hash.
        final package = packagesBySkill[imported.id];
        if (imported.type == ItemType.skill &&
            package != null &&
            widget.skillPackages != null) {
          bytesSinceYield += package.files.fold<int>(
            0,
            (total, file) => total + file.byteLength,
          );
          await widget.skillPackages!.replaceSkill(imported, package);
        } else {
          await repository?.save(imported);
        }
      }

      for (final entry in backup.categories.entries) {
        for (final category in entry.value) {
          await repository?.createCategory(entry.key, category);
        }
      }
      return merge;
    }

    final merge = widget.storageTransactionRunner == null
        ? await mergeIntoStorage()
        : await widget.storageTransactionRunner!(mergeIntoStorage);
    _touchSync();
    for (final entry in backup.categories.entries) {
      _savedCategories[entry.key]!.addAll(entry.value);
    }
    for (final item in merge.items) {
      if (item.category.isNotEmpty) {
        _savedCategories[item.type]!.add(item.category);
      }
    }

    if (!mounted) return merge;
    setState(() {
      _items = merge.items;
      _autoCollapseSeconds = nextSeconds;
      _selectedPromptId ??= _firstPromptId(merge.items);
    });
    widget.onAutoCollapseSecondsChanged?.call(nextSeconds);
    _refreshResult();
    return merge;
  }
}

// ============================================================
Widget _compactAlertDialog({
  Key? key,
  Widget? title,
  Widget? content,
  List<Widget>? actions,
  bool scrollable = false,
}) {
  return SizedBox(
    key: key,
    width: 320,
    child: AlertDialog(
      insetPadding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 320),
      scrollable: scrollable,
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
      actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      title: title,
      content: content,
      actions: actions,
    ),
  );
}

class _EditorCategoryPicker extends StatefulWidget {
  const _EditorCategoryPicker({
    required this.categories,
    required this.selectedCategory,
  });

  final List<String> categories;
  final String selectedCategory;

  @override
  State<_EditorCategoryPicker> createState() => _EditorCategoryPickerState();
}

class _EditorCategoryPickerState extends State<_EditorCategoryPicker> {
  final ScrollController _scrollController = ScrollController();
  late int _focusedIndex;

  List<String> get _options => <String>['', ...widget.categories];

  @override
  void initState() {
    super.initState();
    final selectedIndex = _options.indexOf(widget.selectedCategory);
    _focusedIndex = selectedIndex < 0 ? 0 : selectedIndex;
    _revealIndex(_focusedIndex);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _revealIndex(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      final itemTop = index * 48.0;
      final itemBottom = itemTop + 48.0;
      var target = position.pixels;
      if (itemTop < target) {
        target = itemTop;
      } else if (itemBottom > target + position.viewportDimension) {
        target = itemBottom - position.viewportDimension;
      }
      _scrollController.jumpTo(
        target.clamp(0.0, position.maxScrollExtent).toDouble(),
      );
    });
  }

  void _moveFocus(int delta) {
    final nextIndex = (_focusedIndex + delta).clamp(0, _options.length - 1);
    if (nextIndex == _focusedIndex) return;
    setState(() => _focusedIndex = nextIndex);
    _revealIndex(nextIndex);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _moveFocus(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveFocus(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      Navigator.of(context).pop(_options[_focusedIndex]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final options = _options;
    final colors = Theme.of(context).colorScheme;
    final strings = AppStrings.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : 297.0;
        final maxVisibleRows = ((availableHeight - 57.0) / 48.0).floor().clamp(
          1,
          5,
        );
        final visibleRowCount = options.length.clamp(1, maxVisibleRows).toInt();
        final desiredHeight = 57.0 + visibleRowCount * 48.0;
        return Focus(
          autofocus: true,
          onKeyEvent: _handleKeyEvent,
          child: SizedBox(
            key: const Key('editor-category-picker'),
            width: double.infinity,
            height: desiredHeight,
            child: Material(
              elevation: 10,
              color: colors.surface,
              shadowColor: Colors.black26,
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: <Widget>[
                  SizedBox(
                    height: 56,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16, right: 6),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              strings.chooseCategory,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            key: const Key('close-editor-category-picker'),
                            tooltip: strings.close,
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close_rounded, size: 20),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: Scrollbar(
                      key: const Key('editor-category-scrollbar'),
                      controller: _scrollController,
                      thumbVisibility: true,
                      child: ListView.builder(
                        key: const Key('editor-category-options-scroll'),
                        controller: _scrollController,
                        padding: EdgeInsets.zero,
                        itemCount: options.length,
                        itemExtent: 48,
                        itemBuilder: (context, index) {
                          final category = options[index];
                          final label = category.isEmpty
                              ? strings.uncategorized
                              : category;
                          final selected = category == widget.selectedCategory;
                          final focused = index == _focusedIndex;
                          return Material(
                            color: selected
                                ? colors.primaryContainer.withValues(alpha: .55)
                                : focused
                                ? colors.surfaceContainerHighest
                                : Colors.transparent,
                            child: InkWell(
                              key: ValueKey('editor-category-option-$category'),
                              onTap: () => Navigator.of(context).pop(category),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: Row(
                                  children: <Widget>[
                                    Expanded(
                                      child: Tooltip(
                                        message: label,
                                        waitDuration: const Duration(
                                          milliseconds: 450,
                                        ),
                                        child: Text(
                                          label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                    if (selected) ...<Widget>[
                                      const SizedBox(width: 8),
                                      Icon(
                                        Icons.check_rounded,
                                        size: 19,
                                        color: colors.primary,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ImportDetailRow extends StatelessWidget {
  const _ImportDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          // English labels ("Category", "Source") need more room.
          width: AppStrings.of(context).language == AppLanguage.en ? 66 : 42,
          child: Text(
            label,
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ),
        Expanded(
          child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}

// ============================================================
/// Owns the name field of the create/rename category dialog so the
/// TextEditingController lives as long as the dialog route (including its exit
/// transition) instead of being disposed while the field is still in the tree.
class _CategoryNameDialog extends StatefulWidget {
  const _CategoryNameDialog({
    required this.title,
    this.initialText,
    this.hintText,
    this.confirmKey,
    this.fieldKey,
  });

  final String title;
  final String? initialText;
  final String? hintText;
  final Key? confirmKey;
  final Key? fieldKey;

  @override
  State<_CategoryNameDialog> createState() => _CategoryNameDialogState();
}

class _CategoryNameDialogState extends State<_CategoryNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return _compactAlertDialog(
      key: const Key('category-name-dialog'),
      title: Text(widget.title),
      content: TextField(
        key: widget.fieldKey,
        controller: _controller,
        autofocus: true,
        maxLength: JianheItem.maxCategoryLength,
        decoration: InputDecoration(
          labelText: strings.categoryNameLabel,
          hintText: widget.hintText,
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: widget.confirmKey,
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(strings.categoryDialogConfirm),
        ),
      ],
    );
  }
}

class _EditorBox extends StatelessWidget {
  const _EditorBox({
    required this.label,
    required this.action,
    required this.child,
    this.height,
  });

  final String label;
  final Widget action;
  final Widget child;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      padding: const EdgeInsets.fromLTRB(12, 5, 12, 11),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE3D9CD)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
              action,
            ],
          ),
          const Divider(height: 1),
          const SizedBox(height: 6),
          Expanded(child: child),
        ],
      ),
    );
    return height == null ? box : SizedBox(height: height, child: box);
  }
}

class _MaterialSlip extends StatefulWidget {
  const _MaterialSlip({
    super.key,
    required this.item,
    required this.onRating,
    required this.onEdit,
    required this.onDelete,
    required this.actionLabel,
    required this.onAction,
    required this.onPopupOpened,
    required this.onPopupClosed,
    this.secondaryActionLabel,
    this.onSecondaryAction,
    this.secondaryActionNotice,
    this.onMoveUp,
    this.onMoveDown,
  });

  final JianheItem item;
  final ValueChanged<int> onRating;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final String actionLabel;
  final VoidCallback onAction;
  final VoidCallback onPopupOpened;
  final VoidCallback onPopupClosed;
  final String? secondaryActionLabel;
  final Future<void> Function()? onSecondaryAction;
  final String? secondaryActionNotice;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  @override
  State<_MaterialSlip> createState() => _MaterialSlipState();
}

class _MaterialSlipState extends State<_MaterialSlip> {
  static const _contentPreviewDelay = Duration(milliseconds: 800);

  final _copyNoticeController = OverlayPortalController();
  final _copyNoticeLink = LayerLink();
  final _contentPreviewController = OverlayPortalController();
  Timer? _copyNoticeTimer;
  Timer? _contentPreviewTimer;
  bool _pointerInside = false;

  void _handlePointerEnter(PointerEnterEvent event) {
    _pointerInside = true;
    _contentPreviewTimer?.cancel();
    if (widget.item.content.trim().isEmpty) return;
    _contentPreviewTimer = Timer(_contentPreviewDelay, () {
      if (mounted && _pointerInside) _contentPreviewController.show();
    });
  }

  void _handlePointerExit(PointerExitEvent event) {
    _pointerInside = false;
    _hideContentPreview();
  }

  void _hideContentPreview() {
    _contentPreviewTimer?.cancel();
    _contentPreviewTimer = null;
    _contentPreviewController.hide();
  }

  Future<void> _runSecondaryAction() async {
    _hideContentPreview();
    await widget.onSecondaryAction?.call();
    if (!mounted || widget.secondaryActionNotice == null) return;
    _copyNoticeTimer?.cancel();
    _copyNoticeController.show();
    _copyNoticeTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) _copyNoticeController.hide();
    });
  }

  @override
  void dispose() {
    _copyNoticeTimer?.cancel();
    _contentPreviewTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final card = MouseRegion(
      key: Key('material-slip-hover-${item.id}'),
      onEnter: _handlePointerEnter,
      onExit: _handlePointerExit,
      child: Container(
        padding: const EdgeInsets.fromLTRB(13, 11, 9, 11),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE5DCD0)),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: widget.onAction,
                  borderRadius: BorderRadius.circular(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 3),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final showInlinePreview =
                              item.type != ItemType.skill &&
                              constraints.maxWidth >= 154;
                          return Row(
                            children: <Widget>[
                              _StarRating(
                                rating: item.rating,
                                onChanged: widget.onRating,
                              ),
                              if (showInlinePreview) ...[
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _materialInlinePreviewText(item.content),
                                    key: Key(
                                      'material-inline-preview-${item.id}',
                                    ),
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Color(0xFF81796E),
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          );
                        },
                      ),
                      if (item.category.isNotEmpty || item.useCount > 0) ...[
                        const SizedBox(height: 5),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            if (item.category.isNotEmpty)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF3EEE6),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  item.category,
                                  style: const TextStyle(
                                    color: Color(0xFF665E54),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            if (item.useCount > 0)
                              Text(
                                AppStrings.of(context).usedTimes(item.useCount),
                                style: const TextStyle(
                                  color: Color(0xFF9A9186),
                                  fontSize: 10,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (widget.secondaryActionLabel != null &&
                widget.onSecondaryAction != null) ...[
              _buildSecondaryAction(item),
              const SizedBox(width: 4),
            ],
            FilledButton(
              key: Key('material-action-${item.id}'),
              onPressed: widget.onAction,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                backgroundColor: const Color(0xFF38342E),
                foregroundColor: Colors.white,
              ),
              child: Text(widget.actionLabel),
            ),
            SizedBox.square(
              dimension: 36,
              child: PopupMenuButton<String>(
                tooltip: AppStrings.of(context).moreActions,
                padding: EdgeInsets.zero,
                offset: const Offset(-64, 0),
                constraints: const BoxConstraints(minWidth: 112, maxWidth: 168),
                menuPadding: const EdgeInsets.symmetric(vertical: 4),
                onOpened: () {
                  _hideContentPreview();
                  widget.onPopupOpened();
                },
                onCanceled: widget.onPopupClosed,
                onSelected: (action) {
                  widget.onPopupClosed();
                  switch (action) {
                    case 'edit':
                      widget.onEdit();
                    case 'up':
                      widget.onMoveUp?.call();
                    case 'down':
                      widget.onMoveDown?.call();
                    case 'delete':
                      widget.onDelete();
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'edit',
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      widget.item.type == ItemType.skill
                          ? AppStrings.of(context).editSkill
                          : AppStrings.of(context).edit,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  if (widget.onMoveUp != null)
                    PopupMenuItem(
                      value: 'up',
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        AppStrings.of(context).moveUpInCustomOrder,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  if (widget.onMoveDown != null)
                    PopupMenuItem(
                      value: 'down',
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        AppStrings.of(context).moveDownInCustomOrder,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  const PopupMenuDivider(height: 8),
                  PopupMenuItem(
                    value: 'delete',
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      AppStrings.of(context).delete,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
                icon: const Icon(Icons.more_vert_rounded, size: 19),
              ),
            ),
          ],
        ),
      ),
    );
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _contentPreviewController,
      overlayChildBuilder: (context, layoutInfo) {
        if (layoutInfo.childPaintTransform.determinant() == 0) {
          return const SizedBox.shrink();
        }
        final target = MatrixUtils.transformPoint(
          layoutInfo.childPaintTransform,
          layoutInfo.childSize.center(Offset.zero),
        );
        return Positioned.fill(
          child: CustomSingleChildLayout(
            delegate: _MaterialPreviewPositionDelegate(
              target: target,
              targetSize: layoutInfo.childSize,
            ),
            child: IgnorePointer(child: _buildContentPreview(item)),
          ),
        );
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _hideContentPreview(),
        child: card,
      ),
    );
  }

  Widget _buildContentPreview(JianheItem item) {
    final preview = _materialPreviewText(item.content);
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 140),
      tween: Tween<double>(begin: 0, end: 1),
      builder: (context, opacity, child) => Opacity(
        opacity: opacity,
        child: Transform.translate(
          offset: Offset(0, 4 * (1 - opacity)),
          child: child,
        ),
      ),
      child: Material(
        key: Key('material-content-preview-${item.id}'),
        elevation: 10,
        shadowColor: const Color(0x55000000),
        color: const Color(0xFFFFFCF7),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          constraints: const BoxConstraints(
            minWidth: 300,
            maxWidth: 390,
            maxHeight: 190,
          ),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFDCCFC1)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF38342E),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 5),
              const Divider(height: 1, color: Color(0xFFE5DCD0)),
              const SizedBox(height: 6),
              Flexible(
                child: Text(
                  preview,
                  key: Key('material-content-preview-body-${item.id}'),
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF514A42),
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                AppStrings.of(context).clickCardForFullContent,
                style: const TextStyle(color: Color(0xFF9A9186), fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSecondaryAction(JianheItem item) {
    final button = FilledButton(
      key: Key('material-secondary-action-${item.id}'),
      onPressed: _runSecondaryAction,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        backgroundColor: const Color(0xFF38342E),
        foregroundColor: Colors.white,
      ),
      child: Text(widget.secondaryActionLabel!),
    );
    final notice = widget.secondaryActionNotice;
    if (notice == null) return button;
    return OverlayPortal(
      controller: _copyNoticeController,
      overlayChildBuilder: (context) => UnconstrainedBox(
        child: CompositedTransformFollower(
          link: _copyNoticeLink,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topCenter,
          followerAnchor: Alignment.bottomCenter,
          offset: const Offset(0, -6),
          child: IgnorePointer(
            child: Container(
              key: Key('copy-notice-${item.id}'),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFF292620),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                notice,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ),
      ),
      child: CompositedTransformTarget(link: _copyNoticeLink, child: button),
    );
  }
}

class _MaterialPreviewPositionDelegate extends SingleChildLayoutDelegate {
  const _MaterialPreviewPositionDelegate({
    required this.target,
    required this.targetSize,
  });

  final Offset target;
  final Size targetSize;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    return positionDependentBox(
      size: size,
      childSize: childSize,
      target: target,
      preferBelow: true,
      verticalOffset: targetSize.height / 2 + 8,
      margin: 12,
    );
  }

  @override
  bool shouldRelayout(_MaterialPreviewPositionDelegate oldDelegate) =>
      target != oldDelegate.target || targetSize != oldDelegate.targetSize;
}

String _materialPreviewText(String content) {
  const softLimit = 240;
  const hardLimit = 360;
  const sentenceEndings = <int>{
    0x3002, // 。
    0xFF01, // ！
    0xFF1F, // ？
    0x002E, // .
    0x0021, // !
    0x003F, // ?
    0x000A, // newline
  };
  final normalized = content.trim();
  final runes = normalized.runes.toList(growable: false);
  if (runes.length <= hardLimit) return normalized;

  var cutoff = hardLimit;
  for (var index = hardLimit - 1; index >= softLimit; index--) {
    if (sentenceEndings.contains(runes[index])) {
      cutoff = index + 1;
      break;
    }
  }
  return String.fromCharCodes(runes.take(cutoff)).trimRight();
}

String _materialInlinePreviewText(String content) =>
    content.trim().replaceAll(RegExp(r'\s+'), ' ');

class _RatingFilter extends StatelessWidget {
  const _RatingFilter({required this.rating, required this.onRatingChanged});

  static const _gold = Color(0xFFE4A327);
  static const _muted = Color(0xFFAAA094);
  static const _selectedFill = Color(0xFFFFDED4);
  static const _border = Color(0xFFDCCFC1);

  final int? rating;
  final ValueChanged<int?> onRatingChanged;

  Widget _quickFilter({
    required Key key,
    required String label,
    required String semanticLabel,
    required bool selected,
    required VoidCallback onPressed,
    double width = 48,
  }) {
    return Semantics(
      button: true,
      selected: selected,
      label: semanticLabel,
      child: SizedBox(
        width: width,
        height: 32,
        child: TextButton(
          key: key,
          onPressed: onPressed,
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: const Color(0xFF4E4740),
            backgroundColor: selected ? _selectedFill : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          child: Text(label),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final positiveRating = rating != null && rating! > 0 ? rating! : 0;
    return Container(
      key: const Key('rating-filter'),
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F0E9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Row(
        children: [
          _quickFilter(
            key: const Key('rating-filter-all'),
            label: strings.all,
            semanticLabel: strings.ratingAllSemantic,
            selected: rating == null,
            onPressed: () => onRatingChanged(null),
          ),
          const SizedBox(width: 2),
          _quickFilter(
            key: const Key('rating-filter-0'),
            label: strings.unrated,
            semanticLabel: strings.unratedOnlySemantic,
            selected: rating == 0,
            onPressed: () => onRatingChanged(0),
            width: 58,
          ),
          Container(
            width: 1,
            height: 22,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: _border,
          ),
          for (var star = 1; star <= 5; star++)
            Semantics(
              button: true,
              selected: rating == star,
              label: strings.starsOrFewer(star),
              child: SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  key: Key('rating-filter-$star'),
                  tooltip: strings.starsOrFewer(star),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      onRatingChanged(rating == star ? null : star),
                  icon: Icon(
                    star <= positiveRating
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                    size: 21,
                    color: star <= positiveRating ? _gold : _muted,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StarRating extends StatelessWidget {
  const _StarRating({required this.rating, required this.onChanged});

  final int rating;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Semantics(
      label: rating == 0 ? strings.unrated : strings.starCount(rating),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var star = 1; star <= 5; star++)
            SizedBox(
              width: 22,
              height: 22,
              child: IconButton(
                key: Key('set-rating-$star'),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                tooltip: rating == star
                    ? strings.clearRating
                    : strings.setRating(star),
                onPressed: () => onChanged(rating == star ? 0 : star),
                icon: Icon(
                  star <= rating
                      ? Icons.star_rounded
                      : Icons.star_border_rounded,
                  size: 19,
                  color: star <= rating
                      ? const Color(0xFFE4A327)
                      : const Color(0xFFB4AA9D),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AutoCollapseSetting extends StatelessWidget {
  const _AutoCollapseSetting({
    required this.seconds,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final int seconds;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 7),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5DCD0)),
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xFF9A5C8F).withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(
                  Icons.timer_outlined,
                  color: Color(0xFF9A5C8F),
                  size: 21,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      strings.autoCollapseTitle,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      strings.autoCollapseSubtitle,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
              Text(
                strings.secondsValue(seconds),
                key: const Key('auto-collapse-value'),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          Slider(
            key: const Key('auto-collapse-slider'),
            value: seconds.toDouble(),
            min: 1,
            max: 60,
            divisions: 59,
            label: strings.secondsValue(seconds),
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ],
      ),
    );
  }
}

class _SettingSlip extends StatelessWidget {
  const _SettingSlip({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // 外部 key 只留在 slip 本身；再挂到 Material 会让 find.byKey 匹配到
    // 两个元素，测试里的 tap/滚动 finder 都会因此报 Too many elements。
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFE5DCD0)),
      ),
      child: ListTile(
        onTap: onTap,
        leading: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: color.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon, color: color, size: 21),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
        trailing: trailing,
      ),
    );
  }
}

/// An invisible hit target laid along a panel edge (or corner). Pressing the
/// primary button hands the pointer over to the native modal resize loop, so
/// the resize follows the OS size grips exactly.
class _ResizeGrip extends StatelessWidget {
  const _ResizeGrip({
    super.key,
    required this.edge,
    required this.cursor,
    required this.onDragStart,
  });

  final PanelResizeEdge edge;
  final SystemMouseCursor cursor;
  final ValueChanged<PanelResizeEdge> onDragStart;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: cursor,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          if (event.kind == PointerDeviceKind.mouse &&
              event.buttons & kPrimaryButton != 0) {
            onDragStart(edge);
          }
        },
        child: const SizedBox.expand(),
      ),
    );
  }
}

// ============================================================
// Offline backup codec, run on a background isolate for large libraries:
// a backup can reach 100 MiB of JSON with base64 Skill attachments, and
// encoding or decoding it inline froze the panel. Small backups stay
// inline, where spawning an isolate would cost more than the work.
// ============================================================
const _backupOffThreadBytes = 1 << 20;

String _encodeBackup(JianheBackup backup) => backup.encode();

JianheBackup _decodeBackup(String content) => JianheBackup.decode(content);

int _backupPayloadBytes(JianheBackup backup) {
  var total = 0;
  for (final item in backup.items) {
    total += item.content.length;
  }
  for (final package in backup.skillPackages) {
    for (final file in package.files) {
      total += file.byteLength;
    }
  }
  return total;
}

/// The cloud console address with `?lang=` set, so the web page opens in
/// the same language as the app instead of guessing from the browser.
@visibleForTesting
String cloudPortalUrlFor(String base, AppLanguage language) {
  final uri = Uri.tryParse(base);
  if (uri == null) return base;
  final query = Map<String, String>.of(uri.queryParameters)
    ..['lang'] = language.storageValue;
  return uri.replace(queryParameters: query).toString();
}
