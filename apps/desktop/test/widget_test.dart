import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/app.dart';
import 'package:jianhe_desktop/platform/backup_file_service.dart';
import 'package:jianhe_desktop/platform/ball_window_controller.dart';
import 'package:jianhe_desktop/platform/global_hot_key.dart';
import 'package:jianhe_core/jianhe_core.dart';
import 'package:jianhe_desktop/platform/skill_export_service.dart';
import 'package:jianhe_desktop/platform/skill_import_service.dart';
import 'package:jianhe_skill_io/jianhe_skill_io.dart';
import 'package:jianhe_storage/jianhe_storage.dart';

class _FixedBackupFileService extends BackupFileService {
  const _FixedBackupFileService(this.selectedBackup);

  final ({String name, String content})? selectedBackup;

  @override
  Future<({String name, String content})?> open() async => selectedBackup;
}

class _RecordingBackupFileService extends BackupFileService {
  int saveCalls = 0;
  int openCalls = 0;

  @override
  Future<bool> save(
    String content, {
    required String suggestedName,
    String dialogTitle = '导出笺盒离线备份',
    String filter = '笺盒备份 (*.jianhe)|*.jianhe|JSON 文件 (*.json)|*.json',
  }) async {
    saveCalls++;
    return true;
  }

  @override
  Future<({String name, String content})?> open() async {
    openCalls++;
    return null;
  }
}

class _RecordingWindowController implements BallWindowController {
  final stages = <BallWindowStage>[];

  @override
  bool get usesNativeBall => false;

  @override
  Stream<BallWindowEvent> get events => const Stream<BallWindowEvent>.empty();

  @override
  Future<BallDockSide> showStage(BallWindowStage stage, {Size? size}) async {
    stages.add(stage);
    return BallDockSide.right;
  }

  @override
  Future<void> beginPanelResize(PanelResizeEdge edge) async {}

  @override
  Future<void> panelFrameReady(Size size) async {}

  @override
  Future<BallDockSide> startDrag() async => BallDockSide.right;

  @override
  Future<BallLayout?> getBallLayout() async => null;

  @override
  Future<void> setExpanded(bool expanded) async {}

  @override
  Future<void> setMoreBadge(bool visible) async {}

  @override
  Future<void> restorePosition(BallDockSide side, double offset) async {}

  @override
  Future<bool> setWakeHotKey(GlobalHotKey hotKey) async => true;

  @override
  void setCloseRequestHandler(Future<void> Function()? handler) {}

  @override
  Future<void> quit() async {}
}

class _FakeSkillImportService implements SkillImportService {
  _FakeSkillImportService({this.directory});

  final ImportedSkillPackage? directory;
  int fileCalls = 0;
  int directoryCalls = 0;

  @override
  Future<ImportedSkillPackage?> importFile() async {
    fileCalls++;
    return null;
  }

  @override
  Future<ImportedSkillPackage?> importDirectory() async {
    directoryCalls++;
    return directory;
  }
}

class _FakeSkillExportService implements SkillExportService {
  _FakeSkillExportService({this.path});

  final String? path;
  final exported = <(JianheItem, SkillPackage?)>[];

  @override
  Future<String?> exportZip({
    required JianheItem skill,
    required SkillPackage? package,
  }) async {
    exported.add((skill, package));
    return path;
  }
}

class _NativeRecordingWindowController implements BallWindowController {
  final stages = <BallWindowStage>[];
  final stageSizes = <(BallWindowStage, Size?)>[];
  final resizeEdges = <PanelResizeEdge>[];
  final frameReadySizes = <Size>[];
  final hotKeys = <GlobalHotKey>[];
  final _events = StreamController<BallWindowEvent>.broadcast();
  bool acceptsHotKeys = true;
  Future<void> Function()? closeRequestHandler;

  @override
  bool get usesNativeBall => true;

  @override
  Stream<BallWindowEvent> get events => _events.stream;

  @override
  void setCloseRequestHandler(Future<void> Function()? handler) {
    closeRequestHandler = handler;
  }

  /// Mimics the native layer asking Dart to flush state before teardown.
  void requestClose() {
    final handler = closeRequestHandler;
    if (handler != null) {
      unawaited(handler());
    }
  }

  void tapBall() {
    _events.add(const BallWindowEvent(BallWindowEventType.tap));
  }

  void triggerHotKey() {
    _events.add(const BallWindowEvent(BallWindowEventType.hotkey));
  }

  void reportHotKeyUnavailable() {
    _events.add(const BallWindowEvent(BallWindowEventType.hotkeyUnavailable));
  }

  void selectAction(BallWindowEventType type) {
    _events.add(BallWindowEvent(type));
  }

  void resizePanelTo(Size size) {
    _events.add(BallWindowEvent(BallWindowEventType.resized, size: size));
  }

  void dispose() {
    _events.close();
  }

  @override
  Future<BallDockSide> showStage(BallWindowStage stage, {Size? size}) async {
    stages.add(stage);
    stageSizes.add((stage, size));
    return BallDockSide.right;
  }

  @override
  Future<void> beginPanelResize(PanelResizeEdge edge) async {
    resizeEdges.add(edge);
  }

  @override
  Future<void> panelFrameReady(Size size) async {
    frameReadySizes.add(size);
  }

  @override
  Future<BallDockSide> startDrag() async => BallDockSide.right;

  @override
  Future<BallLayout?> getBallLayout() async => null;

  @override
  Future<void> setExpanded(bool expanded) async {}

  @override
  Future<void> setMoreBadge(bool visible) async {}

  @override
  Future<void> restorePosition(BallDockSide side, double offset) async {}

  @override
  Future<bool> setWakeHotKey(GlobalHotKey hotKey) async {
    hotKeys.add(hotKey);
    return acceptsHotKeys;
  }

  @override
  Future<void> quit() async {}
}

/// Reads fail like a transiently broken database, while writes succeed and
/// are recorded, so tests can prove no fabricated data gets persisted.
class _FailingListRepository implements ItemRepository {
  final saved = <JianheItem>[];

  @override
  Future<JianheItem?> getById(String id) async => null;

  @override
  Future<List<JianheItem>> listAll() async =>
      throw StateError('list unavailable');

  @override
  Future<List<JianheItem>> list({
    ItemType? type,
    bool favoritesOnly = false,
    int? rating,
    String? category,
    ItemSortMode sortMode = ItemSortMode.smart,
    int limit = 100,
  }) async => throw StateError('list unavailable');

  @override
  Future<List<JianheItem>> search(
    String query, {
    ItemType? type,
    bool favoritesOnly = false,
    int? rating,
    String? category,
    ItemSortMode sortMode = ItemSortMode.smart,
    int limit = 50,
  }) async => const <JianheItem>[];

  @override
  Future<void> save(JianheItem item) async {
    saved.add(item);
  }

  @override
  Future<void> delete(String id) async {}

  @override
  Future<JianheItem?> markUsed(String id, {DateTime? now}) async => null;

  @override
  Future<JianheItem?> setRating(
    String id,
    int rating, {
    DateTime? now,
  }) async => null;

  @override
  Future<List<JianheItem>> setSortOrders(
    ItemType type,
    Map<String, int> sortOrders, {
    DateTime? now,
  }) async => const <JianheItem>[];

  @override
  Future<List<String>> listCategories(ItemType type) async =>
      throw StateError('list unavailable');

  @override
  Future<void> createCategory(ItemType type, String name) async {}

  @override
  Future<void> renameCategory(
    ItemType type,
    String oldName,
    String newName,
  ) async {}

  @override
  Future<void> deleteCategory(ItemType type, String name) async {}
}

void main() {
  void useDesktopSurface(
    WidgetTester tester, {
    Size physicalSize = const Size(520, 640),
  }) {
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Clean up widget tree between tests to prevent state leakage.
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('starts as a floating ball instead of a main window', (
    tester,
  ) async {
    useDesktopSurface(tester);
    await tester.pumpWidget(const JianheApp());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('jianhe-ball')), findsOneWidget);
    expect(find.text('你的 AI 铅笔盒'), findsNothing);
    expect(find.byKey(const Key('ball-composer-input')), findsNothing);
  });

  testWidgets('expands the function orbit around the ball', (tester) async {
    useDesktopSurface(tester);
    final window = _RecordingWindowController();
    await tester.pumpWidget(JianheApp(windowController: window));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();

    expect(window.stages, contains(BallWindowStage.menu));
    expect(find.text('快速拼装'), findsOneWidget);
    expect(find.text('Prompt'), findsOneWidget);
    expect(find.text('Skills'), findsOneWidget);
    expect(find.text('常用文本'), findsOneWidget);
    expect(find.text('新建'), findsOneWidget);
    expect(find.text('更多'), findsOneWidget);
  });

  testWidgets('native ball tap requests the native action menu', (
    tester,
  ) async {
    useDesktopSurface(tester);
    final window = _NativeRecordingWindowController();
    addTearDown(window.dispose);
    await tester.pumpWidget(JianheApp(windowController: window));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('jianhe-ball')), findsNothing);

    window.tapBall();
    await tester.pumpAndSettle();

    expect(window.stages, contains(BallWindowStage.menu));
    // The native per-pixel-alpha window, rather than Flutter, draws the
    // action rows on Windows.
    expect(find.text('Prompt'), findsNothing);
  });

  testWidgets('global hotkey requests the native action menu', (tester) async {
    useDesktopSurface(tester);
    final window = _NativeRecordingWindowController();
    addTearDown(window.dispose);
    await tester.pumpWidget(JianheApp(windowController: window));
    await tester.pumpAndSettle();

    window.triggerHotKey();
    await tester.pumpAndSettle();

    expect(window.stages, contains(BallWindowStage.menu));
  });

  testWidgets('reports a global hotkey registration conflict', (tester) async {
    useDesktopSurface(tester);
    final window = _NativeRecordingWindowController();
    addTearDown(window.dispose);
    await tester.pumpWidget(JianheApp(windowController: window));
    await tester.pumpAndSettle();

    window.reportHotKeyUnavailable();
    await tester.pump();
    window.selectAction(BallWindowEventType.more);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('唤起快捷键'),
      120,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('Ctrl + Shift + Space · 注册失败'), findsOneWidget);
  });

  testWidgets('records and applies a custom global hotkey', (tester) async {
    useDesktopSurface(tester);
    final window = _NativeRecordingWindowController();
    addTearDown(window.dispose);
    GlobalHotKey? savedHotKey;
    await tester.pumpWidget(
      JianheApp(
        windowController: window,
        onWakeHotKeyChanged: (hotKey) => savedHotKey = hotKey,
      ),
    );
    await tester.pumpAndSettle();

    window.selectAction(BallWindowEventType.more);
    await tester.pumpAndSettle();
    final hotKeySetting = find.text('唤起快捷键');
    await tester.scrollUntilVisible(
      hotKeySetting,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(hotKeySetting);
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(find.text('Ctrl + P'), findsOneWidget);
    await tester.tap(find.byKey(const Key('save-wake-hot-key')));
    await tester.pumpAndSettle();

    expect(window.hotKeys.last.storageValue, 'ctrl+p');
    expect(savedHotKey?.storageValue, 'ctrl+p');
    expect(find.text('Ctrl + P · 已注册'), findsOneWidget);

    await tester.tap(hotKeySetting);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reset-wake-hot-key')));
    await tester.pumpAndSettle();

    expect(
      window.hotKeys.last.storageValue,
      GlobalHotKey.defaultWake.storageValue,
    );
    expect(savedHotKey?.storageValue, GlobalHotKey.defaultWake.storageValue);
  });

  testWidgets('does not persist a rejected global hotkey', (tester) async {
    useDesktopSurface(tester);
    final window = _NativeRecordingWindowController();
    addTearDown(window.dispose);
    GlobalHotKey? savedHotKey;
    await tester.pumpWidget(
      JianheApp(
        windowController: window,
        onWakeHotKeyChanged: (hotKey) => savedHotKey = hotKey,
      ),
    );
    await tester.pumpAndSettle();
    window.acceptsHotKeys = false;

    window.selectAction(BallWindowEventType.more);
    await tester.pumpAndSettle();
    final hotKeySetting = find.text('唤起快捷键');
    await tester.scrollUntilVisible(
      hotKeySetting,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(hotKeySetting);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.text('Ctrl + P'), findsOneWidget);
    await tester.tap(find.byKey(const Key('save-wake-hot-key')));
    await tester.pumpAndSettle();

    expect(savedHotKey, isNull);
    expect(find.text('Ctrl + Shift + Space · 已注册'), findsOneWidget);
    expect(window.hotKeys.last.storageValue, 'ctrl+p');
  });

  testWidgets('native action menu events route every function', (tester) async {
    // Mirrors the permanently enlarged D3D child used by the Windows runner.
    // Each page must still lay out at its own smaller native stage size.
    useDesktopSurface(tester, physicalSize: const Size(536, 656));
    final cases =
        <({BallWindowEventType event, BallWindowStage stage, String subtitle})>[
          (
            event: BallWindowEventType.compose,
            stage: BallWindowStage.composer,
            subtitle: '用 Prompt 处理原文并复制结果',
          ),
          (
            event: BallWindowEventType.prompts,
            stage: BallWindowStage.browser,
            subtitle: '管理并使用提示词',
          ),
          (
            event: BallWindowEventType.skills,
            stage: BallWindowStage.browser,
            subtitle: '查看、复制和管理 Skill',
          ),
          (
            event: BallWindowEventType.snippets,
            stage: BallWindowStage.browser,
            subtitle: '保存常用文本，一键复制',
          ),
          (
            event: BallWindowEventType.create,
            stage: BallWindowStage.editor,
            subtitle: '创建 Prompt、Skill 或文本',
          ),
          (
            event: BallWindowEventType.more,
            stage: BallWindowStage.settings,
            subtitle: '管理备份、快捷键和命令行',
          ),
        ];

    for (final testCase in cases) {
      final window = _NativeRecordingWindowController();
      await tester.pumpWidget(JianheApp(windowController: window));
      await tester.pumpAndSettle();

      window.tapBall();
      await tester.pumpAndSettle();
      expect(window.stages.last, BallWindowStage.menu);

      window.selectAction(testCase.event);
      await tester.pumpAndSettle();
      expect(window.stages.last, testCase.stage);
      final subtitle = find.text(testCase.subtitle);
      expect(subtitle, findsOneWidget);
      expect(
        tester.renderObject<RenderParagraph>(subtitle).didExceedMaxLines,
        isFalse,
      );
      expect(
        tester.getSize(find.byKey(const Key('ball-logical-surface'))),
        Size(testCase.stage.width, testCase.stage.height),
      );

      // properly dispose before next iteration
      window.dispose();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  });

  testWidgets('composes content without opening a traditional workspace', (
    tester,
  ) async {
    useDesktopSurface(tester);
    final window = _RecordingWindowController();
    await tester.pumpWidget(JianheApp(windowController: window));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('快速拼装'));
    await tester.pumpAndSettle();

    expect(window.stages, contains(BallWindowStage.composer));
    expect(find.byKey(const Key('ball-composer-input')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('ball-composer-input')),
      '这是从剪贴板放入的原始内容。',
    );
    await tester.pump();

    final result = tester.widget<SelectableText>(
      find.byKey(const Key('ball-composer-result')),
    );
    expect(result.data, contains('这是从剪贴板放入的原始内容。'));
  });

  testWidgets('opens prompt slips from the orbit', (tester) async {
    useDesktopSurface(tester);
    await tester.pumpWidget(const JianheApp());
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prompt'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ball-search')), findsOneWidget);
    expect(find.text('结构化总结'), findsOneWidget);
    expect(find.text('拼装'), findsWidgets);
  });

  testWidgets('copies a Skill before the view action and shows confirmation', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(620, 900));
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    final skill = JianheItem.create(
      id: 'copyable-skill',
      type: ItemType.skill,
      title: '可复制 Skill',
      content: '# Copyable instructions',
    );
    await storage.items.save(skill);

    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(JianheApp(repository: storage.items));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skills'));
    await tester.pumpAndSettle();

    final copyButton = find.byKey(
      const Key('material-secondary-action-copyable-skill'),
    );
    final viewButton = find.byKey(const Key('material-action-copyable-skill'));
    expect(copyButton, findsOneWidget);
    expect(viewButton, findsOneWidget);
    expect(tester.widget(copyButton), isA<FilledButton>());
    expect(tester.widget(viewButton), isA<FilledButton>());
    expect(
      tester.getCenter(copyButton).dx,
      lessThan(tester.getCenter(viewButton).dx),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(copyButton));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('copy-notice-copyable-skill')), findsNothing);

    await tester.tap(copyButton);
    await tester.pump();

    expect(copiedText, '# Copyable instructions');
    final copyNotice = find.text('✓ 已复制');
    expect(copyNotice, findsOneWidget);
    expect(find.byKey(const Key('copy-notice-copyable-skill')), findsOneWidget);
    expect(find.text('✓  "可复制 Skill"已复制'), findsNothing);
    final copyNoticeRect = tester.getRect(copyNotice);
    final copyButtonRect = tester.getRect(copyButton);
    expect(
      (copyNoticeRect.center - copyButtonRect.center).distance,
      lessThan(100),
    );
    expect(find.byKey(const Key('skill-file-SKILL.md')), findsNothing);
  });

  testWidgets('views a Prompt before composing it', (tester) async {
    useDesktopSurface(tester);
    await tester.pumpWidget(const JianheApp());
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prompt'));
    await tester.pumpAndSettle();

    final composeButton = find.byKey(
      const Key('material-secondary-action-demo-summary'),
    );
    final viewButton = find.byKey(const Key('material-action-demo-summary'));
    expect(composeButton, findsOneWidget);
    expect(viewButton, findsOneWidget);
    expect(
      tester.getCenter(composeButton).dx,
      lessThan(tester.getCenter(viewButton).dx),
    );

    await tester.tap(viewButton);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('material-detail-content-demo-summary')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('material-detail-compose-demo-summary')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('copy-notice-demo-summary')), findsNothing);

    await tester.tap(
      find.byKey(const Key('material-detail-compose-demo-summary')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ball-composer-input')), findsOneWidget);
  });

  testWidgets('tapping a slip body opens the material detail', (tester) async {
    useDesktopSurface(tester);
    await tester.pumpWidget(const JianheApp());
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prompt'));
    await tester.pumpAndSettle();

    final slip = find.byKey(const ValueKey('demo-summary'));
    await tester.tap(
      find.descendant(
        of: slip,
        matching: find.byKey(const Key('set-rating-3')),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: slip, matching: find.byTooltip('清除星级')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('material-detail-content-demo-summary')),
      findsNothing,
    );

    await tester.tap(find.text('结构化总结'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-detail-content-demo-summary')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('panel-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('panel-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skills'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('内容诊断 Skill'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('skill-package-demo-skill')), findsOneWidget);

    await tester.tap(find.byKey(const Key('panel-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('panel-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('常用文本'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('个人介绍'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-detail-content-demo-snippet')),
      findsOneWidget,
    );
  });

  testWidgets(
    'shows a balanced content preview after 800ms and hides on exit',
    (tester) async {
      useDesktopSurface(tester, physicalSize: const Size(520, 900));
      final storage = JianheStorageDatabase.inMemory();
      addTearDown(storage.close);
      final content =
          '开头。${List<String>.filled(250, '甲').join()}'
          '这是完整句子的结尾。'
          '${List<String>.filled(180, '乙').join()}';
      await storage.items.save(
        JianheItem.create(
          id: 'hover-preview',
          type: ItemType.prompt,
          title: '悬停预览素材',
          content: content,
          now: DateTime.utc(2026, 9, 16),
        ),
      );
      await tester.pumpWidget(JianheApp(repository: storage.items));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prompt'));
      await tester.pumpAndSettle();

      final hoverTarget = find.byKey(
        const Key('material-slip-hover-hover-preview'),
      );
      final preview = find.byKey(
        const Key('material-content-preview-hover-preview'),
      );
      final cardRect = tester.getRect(hoverTarget);
      final region = tester.widget<MouseRegion>(hoverTarget);

      region.onEnter!(const PointerEnterEvent());
      await tester.pump(const Duration(milliseconds: 799));
      expect(preview, findsNothing);

      region.onExit!(const PointerExitEvent());
      await tester.pump(const Duration(seconds: 1));
      expect(preview, findsNothing);

      region.onEnter!(const PointerEnterEvent());
      await tester.pump(const Duration(milliseconds: 800));
      expect(preview, findsOneWidget);
      expect(tester.getRect(hoverTarget), cardRect);

      final previewRect = tester.getRect(preview);
      expect(previewRect.width, inInclusiveRange(300, 390));
      expect(previewRect.height, lessThanOrEqualTo(190));
      final previewBody = tester.widget<Text>(
        find.byKey(const Key('material-content-preview-body-hover-preview')),
      );
      expect(previewBody.maxLines, 8);
      expect(previewBody.overflow, TextOverflow.ellipsis);
      expect(previewBody.data, endsWith('。'));
      expect(previewBody.data!.runes.length, inInclusiveRange(240, 360));

      region.onExit!(const PointerExitEvent());
      await tester.pump();
      expect(preview, findsNothing);
    },
  );

  testWidgets(
    'shows inline prompt and snippet previews only when card width allows',
    (tester) async {
      useDesktopSurface(tester, physicalSize: const Size(900, 800));
      final storage = JianheStorageDatabase.inMemory();
      final window = _NativeRecordingWindowController();
      addTearDown(storage.close);
      addTearDown(window.dispose);
      final now = DateTime.utc(2026, 9, 16);
      await storage.items.save(
        JianheItem.create(
          id: 'inline-prompt',
          type: ItemType.prompt,
          title: 'Prompt 标题',
          content: '第一行\n第二行   会整理成单行摘要',
          now: now,
        ),
      );
      await storage.items.save(
        JianheItem.create(
          id: 'inline-snippet',
          type: ItemType.snippet,
          title: '常用文本标题',
          content: '常用文本的正文摘要',
          now: now,
        ),
      );
      await storage.items.save(
        JianheItem.create(
          id: 'inline-skill',
          type: ItemType.skill,
          title: 'Skill 标题',
          content: 'Skill 正文不在列表中显示',
          now: now,
        ),
      );
      await tester.pumpWidget(
        JianheApp(repository: storage.items, windowController: window),
      );
      await tester.pumpAndSettle();

      window.selectAction(BallWindowEventType.prompts);
      await tester.pumpAndSettle();
      final promptPreview = find.byKey(
        const Key('material-inline-preview-inline-prompt'),
      );
      expect(promptPreview, findsOneWidget);
      expect(tester.widget<Text>(promptPreview).data, '第一行 第二行 会整理成单行摘要');

      window.selectAction(BallWindowEventType.snippets);
      await tester.pumpAndSettle();
      final snippetPreview = find.byKey(
        const Key('material-inline-preview-inline-snippet'),
      );
      expect(snippetPreview, findsOneWidget);

      window.resizePanelTo(const Size(410, 500));
      await tester.pump();
      await tester.pump();
      expect(snippetPreview, findsNothing);
      expect(tester.takeException(), isNull);

      window.resizePanelTo(const Size(600, 500));
      await tester.pump();
      await tester.pump();
      expect(snippetPreview, findsOneWidget);

      window.selectAction(BallWindowEventType.skills);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('material-inline-preview-inline-skill')),
        findsNothing,
      );
    },
  );

  testWidgets('views a snippet without copying it automatically', (
    tester,
  ) async {
    useDesktopSurface(tester);
    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(const JianheApp());
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('常用文本'));
    await tester.pumpAndSettle();

    final copyButton = find.byKey(
      const Key('material-secondary-action-demo-snippet'),
    );
    final viewButton = find.byKey(const Key('material-action-demo-snippet'));
    expect(
      tester.getCenter(copyButton).dx,
      lessThan(tester.getCenter(viewButton).dx),
    );

    await tester.tap(viewButton);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('material-detail-content-demo-snippet')),
      findsOneWidget,
    );
    expect(copiedText, isNull);

    await tester.tap(
      find.byKey(const Key('material-detail-copy-demo-snippet')),
    );
    await tester.pump();
    expect(copiedText, contains('我是笺盒的创建者'));
  });

  testWidgets('browses complete Skill package files on demand', (tester) async {
    useDesktopSurface(tester, physicalSize: const Size(620, 900));
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    final skill = JianheItem.create(
      id: 'complete-skill',
      type: ItemType.skill,
      title: '完整能力包',
      content: '# Main instructions',
    );
    await storage.skills.replaceSkill(
      skill,
      SkillPackage(
        skillId: skill.id,
        sourceFormat: SkillSourceFormat.directory,
        importedAt: DateTime.utc(2026, 8, 24),
        files: <SkillFile>[
          SkillFile(
            relativePath: 'references/guide.md',
            mediaType: 'text/markdown',
            content: Uint8List.fromList('# Guide'.codeUnits),
          ),
          SkillFile(
            relativePath: 'assets/data.bin',
            content: Uint8List.fromList(<int>[0, 1, 2, 255]),
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      JianheApp(repository: storage.items, skillPackages: storage.skills),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skills'));
    await tester.pumpAndSettle();

    expect(find.text('完整能力包'), findsOneWidget);
    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('skill-file-SKILL.md')), findsOneWidget);
    expect(
      find.byKey(const Key('skill-file-references/guide.md')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('skill-file-assets/data.bin')), findsOneWidget);

    expect(find.byKey(const Key('copy-skill-ai-instructions')), findsNothing);

    await tester.tap(find.byKey(const Key('skill-file-references/guide.md')));
    await tester.pumpAndSettle();
    expect(find.text('复制整个 Skill 的 AI 调用指令'), findsNothing);
    expect(find.byKey(const Key('skill-file-text-preview')), findsOneWidget);
    expect(find.text('# Guide'), findsOneWidget);
    expect(find.byKey(const Key('copy-skill-file')), findsOneWidget);

    await tester.tap(find.byKey(const Key('skill-file-preview-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skill-file-assets/data.bin')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('skill-file-binary-type')), findsOneWidget);
    expect(find.byKey(const Key('copy-skill-file')), findsNothing);
  });

  const conflictSkillId = 'conflict-skill';

  /// Seeds one Skill and pumps the app around an in-memory database.
  Future<JianheStorageDatabase> pumpWithEditableSkill(
    WidgetTester tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(470, 610));
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    await storage.skills.replaceSkill(
      JianheItem.create(
        id: conflictSkillId,
        type: ItemType.skill,
        title: '冲突测试 Skill',
        content: '# Original',
      ),
      null,
    );
    await tester.pumpWidget(
      JianheApp(
        repository: storage.items,
        skillPackages: storage.skills,
        storageTransactionRunner: storage.writeTransaction,
      ),
    );
    await tester.pumpAndSettle();
    return storage;
  }

  /// Opens the editor for the only Skill and returns its scrollable.
  Future<Finder> openSkillEditor(WidgetTester tester) async {
    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skills'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑 Skill'));
    await tester.pumpAndSettle();
    return find
        .descendant(
          of: find.byKey(const Key('editor-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
  }

  /// [expectConflict]: a panel dialog keeps animating, so wait a fixed
  /// time for it like the other dialog tests instead of pumpAndSettle.
  Future<void> saveEditorContent(
    WidgetTester tester,
    Finder scrollable,
    String content, {
    bool expectConflict = false,
  }) async {
    await tester.scrollUntilVisible(
      find.byKey(const Key('editor-content')),
      120,
      scrollable: scrollable,
    );
    await tester.enterText(find.byKey(const Key('editor-content')), content);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-item')));
    if (expectConflict) {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    } else {
      await tester.pumpAndSettle();
    }
  }

  testWidgets('polls for external writes only while a panel is open', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(470, 610));
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    var dataVersion = 1;
    var reads = 0;
    await tester.pumpWidget(
      JianheApp(
        repository: storage.items,
        skillPackages: storage.skills,
        storageTransactionRunner: storage.writeTransaction,
        readStorageDataVersion: () {
          reads++;
          return dataVersion;
        },
      ),
    );
    await tester.pumpAndSettle();
    final readsAtStartup = reads;
    await tester.pump(const Duration(seconds: 6));
    expect(reads, readsAtStartup, reason: 'no polling while collapsed');

    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skills'));
    await tester.pumpAndSettle();
    expect(find.text('CLI 写入的 Skill'), findsNothing);

    // The jianhe CLI imports a Skill through its own connection.
    final cliItem = JianheItem.create(
      type: ItemType.skill,
      title: 'CLI 写入的 Skill',
      content: '# From CLI',
    );
    await storage.skills.replaceSkill(cliItem, null);
    dataVersion++;
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.text('CLI 写入的 Skill'), findsOneWidget);
    expect(reads, greaterThan(readsAtStartup));
  });

  testWidgets('discarding an edit conflict keeps the change made elsewhere', (
    tester,
  ) async {
    final storage = await pumpWithEditableSkill(tester);
    final scrollable = await openSkillEditor(tester);

    // While the editor is open, the CLI rewrites the Skill.
    final current = (await storage.items.getById(conflictSkillId))!;
    await storage.items.save(current.copyWith(content: '# From CLI'));

    await saveEditorContent(
      tester,
      scrollable,
      '# Mine',
      expectConflict: true,
    );
    expect(find.text('素材已在别处被修改'), findsOneWidget);
    await tester.tap(find.byKey(const Key('edit-conflict-discard')));
    await tester.pumpAndSettle();

    final stored = await storage.items.getById(conflictSkillId);
    expect(stored?.content, '# From CLI');
    expect(find.text('已放弃本次修改'), findsOneWidget);
  });

  testWidgets('overwriting an edit conflict keeps fresh rating and usage', (
    tester,
  ) async {
    final storage = await pumpWithEditableSkill(tester);
    final scrollable = await openSkillEditor(tester);

    final current = (await storage.items.getById(conflictSkillId))!;
    await storage.items.save(current.copyWith(content: '# From CLI'));
    await storage.items.setRating(conflictSkillId, 4);

    await saveEditorContent(
      tester,
      scrollable,
      '# Mine',
      expectConflict: true,
    );
    expect(find.text('素材已在别处被修改'), findsOneWidget);
    await tester.tap(find.byKey(const Key('edit-conflict-overwrite')));
    await tester.pumpAndSettle();

    final stored = await storage.items.getById(conflictSkillId);
    expect(stored?.content, '# Mine');
    expect(stored?.rating, 4);
  });

  testWidgets('a rating change made elsewhere is not an edit conflict', (
    tester,
  ) async {
    final storage = await pumpWithEditableSkill(tester);
    final scrollable = await openSkillEditor(tester);

    await storage.items.setRating(conflictSkillId, 4);

    await saveEditorContent(tester, scrollable, '# Mine');
    expect(find.byKey(const Key('edit-conflict-dialog')), findsNothing);
    final stored = await storage.items.getById(conflictSkillId);
    expect(stored?.content, '# Mine');
    expect(stored?.rating, 4, reason: 'the stale editor snapshot had 0');
  });

  testWidgets('saving an item deleted elsewhere creates a new item', (
    tester,
  ) async {
    final storage = await pumpWithEditableSkill(tester);
    final scrollable = await openSkillEditor(tester);

    await storage.items.delete(conflictSkillId);

    await saveEditorContent(
      tester,
      scrollable,
      '# Mine',
      expectConflict: true,
    );
    expect(find.text('素材已在别处被删除'), findsOneWidget);
    await tester.tap(find.byKey(const Key('edit-conflict-overwrite')));
    await tester.pumpAndSettle();

    expect(await storage.items.getById(conflictSkillId), isNull);
    final skills = await storage.items.list(type: ItemType.skill);
    expect(skills, hasLength(1));
    expect(skills.single.content, '# Mine');
    expect(skills.single.id, isNot(conflictSkillId));
  });

  testWidgets(
    'does not duplicate a Skill the CLI imported while confirming',
    (tester) async {
      useDesktopSurface(tester, physicalSize: const Size(470, 610));
      final storage = JianheStorageDatabase.inMemory();
      addTearDown(storage.close);
      final imported = ImportedSkillPackage(
        title: '并发导入 Skill',
        entrypointContent: '# Concurrent import',
        sourceFormat: SkillSourceFormat.directory,
        files: <SkillFile>[
          SkillFile(
            relativePath: 'references/guide.md',
            mediaType: 'text/markdown',
            content: Uint8List.fromList('# Guide'.codeUnits),
          ),
        ],
      );
      final importService = _FakeSkillImportService(directory: imported);

      await tester.pumpWidget(
        JianheApp(
          repository: storage.items,
          skillPackages: storage.skills,
          skillImportService: importService,
          storageTransactionRunner: storage.writeTransaction,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skills'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('create-or-import-skill')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('skill-import-directory')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('确认导入 Skill'), findsOneWidget);

      // While the confirmation is open, an Agent imports the same package
      // through the CLI (same content, different item id). Not inside
      // tester.runAsync: the write queue future it would leave behind belongs
      // to the real zone, and the app's next transaction would wait on it
      // forever under fake async.
      final cliItem = JianheItem.create(
        type: ItemType.skill,
        title: 'CLI 抢先导入',
        content: imported.entrypointContent,
      );
      await storage.skills.replaceSkill(cliItem, imported.toPackage(cliItem.id));

      await tester.tap(find.byKey(const Key('confirm-skill-import')));
      await tester.pumpAndSettle();

      final skills = await storage.items.list(type: ItemType.skill);
      expect(skills, hasLength(1));
      expect(skills.single.title, 'CLI 抢先导入');
      expect(find.text('已经导入过：CLI 抢先导入'), findsOneWidget);
    },
  );

  testWidgets('exports a Skill package as a ZIP from the list and detail', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(470, 610));
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    final skill = JianheItem.create(
      type: ItemType.skill,
      title: '导出用 Skill',
      content: '# Export me',
    );
    final imported = ImportedSkillPackage(
      title: skill.title,
      entrypointContent: skill.content,
      sourceFormat: SkillSourceFormat.directory,
      files: <SkillFile>[
        SkillFile(
          relativePath: 'references/guide.md',
          mediaType: 'text/markdown',
          content: Uint8List.fromList('# Guide'.codeUnits),
        ),
      ],
    );
    await storage.skills.replaceSkill(skill, imported.toPackage(skill.id));
    final exportService = _FakeSkillExportService(
      path: r'C:\Users\me\Downloads\导出用 Skill.zip',
    );

    await tester.pumpWidget(
      JianheApp(
        repository: storage.items,
        skillPackages: storage.skills,
        skillExportService: exportService,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skills'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('导出 ZIP'), findsOneWidget);
    await tester.tap(find.text('导出 ZIP'));
    await tester.pumpAndSettle();

    expect(exportService.exported, hasLength(1));
    final (exportedSkill, exportedPackage) = exportService.exported.single;
    expect(exportedSkill.id, skill.id);
    expect(exportedSkill.content, '# Export me');
    expect(
      exportedPackage?.files.map((file) => file.relativePath),
      <String>['references/guide.md'],
    );
    expect(
      find.text('✓  已导出到 C:\\Users\\me\\Downloads\\导出用 Skill.zip'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(Key('material-action-${skill.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skill-detail-export')));
    await tester.pumpAndSettle();
    expect(exportService.exported, hasLength(2));
    expect(exportService.exported.last.$1.id, skill.id);
  });

  testWidgets('imports a complete Skill package from the Skills browser', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(470, 610));
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    final imported = ImportedSkillPackage(
      title: '桌面导入 Skill',
      entrypointContent: '# Desktop import instructions',
      sourceFormat: SkillSourceFormat.directory,
      files: <SkillFile>[
        SkillFile(
          relativePath: 'references/guide.md',
          mediaType: 'text/markdown',
          content: Uint8List.fromList('# Guide'.codeUnits),
        ),
        SkillFile(
          relativePath: 'scripts/run.py',
          mediaType: 'text/x-python',
          content: Uint8List.fromList('print("ok")'.codeUnits),
        ),
      ],
    );
    final importService = _FakeSkillImportService(directory: imported);

    await tester.pumpWidget(
      JianheApp(
        repository: storage.items,
        skillPackages: storage.skills,
        skillImportService: importService,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skills'));
    await tester.pumpAndSettle();

    expect(find.text('新建 / 导入 Skill'), findsOneWidget);
    await tester.tap(find.byKey(const Key('create-or-import-skill')));
    await tester.pumpAndSettle();
    expect(find.text('导入 Skill 文件夹'), findsOneWidget);
    expect(find.text('导入 ZIP 或 Markdown'), findsOneWidget);
    expect(find.text('手工新建单文件 Skill'), findsOneWidget);

    await tester.tap(find.byKey(const Key('skill-import-directory')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(importService.directoryCalls, 1);
    expect(find.text('确认导入 Skill'), findsOneWidget);
    expect(find.text('桌面导入 Skill'), findsOneWidget);
    expect(find.textContaining('3 个 ·'), findsOneWidget);
    expect(find.text('# Desktop import instructions'), findsOneWidget);

    await tester.tap(find.byKey(const Key('confirm-skill-import')));
    await tester.pumpAndSettle();

    final skills = await storage.items.list(type: ItemType.skill);
    expect(skills, hasLength(1));
    expect(skills.single.title, '桌面导入 Skill');
    final package = await storage.skills.getBySkillId(skills.single.id);
    expect(package?.sourceFormat, SkillSourceFormat.directory);
    expect(
      package?.files.map((file) => file.relativePath),
      containsAll(<String>['references/guide.md', 'scripts/run.py']),
    );
    expect(find.text('桌面导入 Skill'), findsOneWidget);

    await tester.tap(find.byKey(const Key('create-or-import-skill')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AlertDialog>(
            find.descendant(
              of: find.byKey(const Key('skill-create-dialog')),
              matching: find.byType(AlertDialog),
            ),
          )
          .scrollable,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('skill-create-manual')));
    await tester.pumpAndSettle();
    expect(find.text('新建 Skill'), findsOneWidget);
    expect(find.text('创建单文件 Skill'), findsOneWidget);
    expect(find.byType(SegmentedButton<ItemType>), findsNothing);
    expect(find.widgetWithText(FilledButton, '创建 Skill'), findsOneWidget);
  });

  testWidgets('edits a complete Skill without dropping auxiliary files', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(470, 610));
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    final skill = JianheItem.create(
      id: 'editable-complete-skill',
      type: ItemType.skill,
      title: '可编辑完整 Skill',
      content: '# Original instructions',
      category: '原分类',
    );
    final reference = SkillFile(
      relativePath: 'references/guide.md',
      mediaType: 'text/markdown',
      content: Uint8List.fromList('# Preserved guide'.codeUnits),
    );
    await storage.skills.replaceSkill(
      skill,
      SkillPackage(
        skillId: skill.id,
        sourceFormat: SkillSourceFormat.directory,
        importedAt: DateTime.utc(2026, 8, 24),
        files: <SkillFile>[reference],
      ),
    );

    await tester.pumpWidget(
      JianheApp(repository: storage.items, skillPackages: storage.skills),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skills'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    final skillCard = tester.getRect(
      find.byKey(Key('material-slip-hover-${skill.id}')),
    );
    final editMenuItem = tester.getRect(
      find.widgetWithText(PopupMenuItem<String>, '编辑 Skill'),
    );
    expect(editMenuItem.right, lessThanOrEqualTo(skillCard.right));
    await tester.tap(find.text('编辑 Skill'));
    await tester.pumpAndSettle();

    expect(find.text('编辑 Skill'), findsOneWidget);
    expect(find.byKey(const Key('skill-type-locked')), findsOneWidget);
    expect(find.byType(SegmentedButton<ItemType>), findsNothing);
    expect(find.text('SKILL.md'), findsOneWidget);
    expect(find.text('修改 SKILL.md，保留辅助文件'), findsOneWidget);
    expect(find.byKey(const Key('save-item')), findsOneWidget);
    expect(
      find.byKey(const Key('readonly-skill-file-references/guide.md')),
      findsNothing,
    );

    final editorScrollable = find
        .descendant(
          of: find.byKey(const Key('editor-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('skill-auxiliary-files-readonly')),
      180,
      scrollable: editorScrollable,
    );
    await tester.tap(find.byKey(const Key('skill-auxiliary-files-readonly')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('readonly-skill-file-references/guide.md')),
      100,
      scrollable: editorScrollable,
    );
    expect(
      find.byKey(const Key('readonly-skill-file-references/guide.md')),
      findsOneWidget,
    );

    tester.view.physicalSize = const Size(320, 400);
    await tester.pumpAndSettle();
    expect(find.text('编辑 Skill'), findsOneWidget);
    expect(find.text('修改 SKILL.md，保留辅助文件'), findsOneWidget);
    expect(find.byKey(const Key('save-item')), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('editor-title')),
      -220,
      scrollable: editorScrollable,
    );
    await tester.enterText(
      find.byKey(const Key('editor-title')),
      '已更新完整 Skill',
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('editor-content')),
      120,
      scrollable: editorScrollable,
    );
    await tester.enterText(
      find.byKey(const Key('editor-content')),
      '# Updated instructions',
    );
    // The native host switches from the compact editor stage back to the
    // browser stage after saving. Mirror that stage resize in the widget test.
    tester.view.physicalSize = const Size(440, 570);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-item')));
    await tester.pumpAndSettle();

    final updated = await storage.items.getById(skill.id);
    final package = await storage.skills.getBySkillId(skill.id);
    expect(updated?.type, ItemType.skill);
    expect(updated?.title, '已更新完整 Skill');
    expect(updated?.content, '# Updated instructions');
    expect(package?.files, hasLength(1));
    expect(package?.files.single.relativePath, reference.relativePath);
    expect(package?.files.single.content, reference.content);
  });

  // The browser, search and filters all work on the loaded list. A
  // 500-item cap used to hide whatever smart order puts last: unrated,
  // unused, oldest items, the ones most often looked up by search.
  Future<void> seedBeyondFormerCap(
    JianheStorageDatabase storage,
    ItemType type, {
    required int count,
  }) async {
    await storage.writeTransaction(() async {
      for (var index = 0; index < count; index++) {
        await storage.items.save(
          JianheItem.create(
            id: 'bulk-${type.name}-$index',
            type: type,
            title: '批量素材 $index',
            content: '批量内容 $index',
            now: DateTime.utc(2026, 9, 2).add(Duration(minutes: index)),
          ),
        );
      }
      await storage.items.save(
        JianheItem.create(
          id: 'oldest-${type.name}',
          type: type,
          title: '最早的冷门素材',
          content: '只能靠搜索找到',
          now: DateTime.utc(2026, 1, 1),
        ),
      );
    });
  }

  testWidgets('loads every item at startup, not only the first 500', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(620, 900));
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    await seedBeyondFormerCap(storage, ItemType.prompt, count: 519);

    await tester.pumpWidget(JianheApp(repository: storage.items));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prompt'));
    await tester.pumpAndSettle();

    expect(find.text('520 项'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('ball-search')), '最早的冷门素材');
    await tester.pumpAndSettle();
    expect(find.text('1 项'), findsOneWidget);
    expect(find.byKey(const ValueKey('oldest-prompt')), findsOneWidget);
  });

  testWidgets('a refresh after startup also loads every item', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(620, 900));
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    await tester.pumpWidget(
      JianheApp(repository: storage.items, skillPackages: storage.skills),
    );
    await tester.pumpAndSettle();

    // Written after startup (the CLI, a sync pull); opening the Skills
    // browser refreshes the list from storage.
    await seedBeyondFormerCap(storage, ItemType.skill, count: 510);
    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skills'));
    await tester.pumpAndSettle();

    expect(find.text('511 项'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('ball-search')), '最早的冷门素材');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('oldest-skill')), findsOneWidget);
  });

  testWidgets('refreshes Skills imported after desktop startup', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(620, 900));
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    await tester.pumpWidget(
      JianheApp(repository: storage.items, skillPackages: storage.skills),
    );
    await tester.pumpAndSettle();

    await storage.items.save(
      JianheItem.create(
        id: 'late-skill',
        type: ItemType.skill,
        title: 'CLI 后导入',
        content: '# Late Skill',
      ),
    );
    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skills'));
    await tester.pumpAndSettle();

    expect(find.text('CLI 后导入'), findsOneWidget);
  });

  testWidgets('deletes a prompt from the card menu after confirmation', (
    tester,
  ) async {
    useDesktopSurface(tester);
    await tester.pumpWidget(const JianheApp());
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prompt'));
    await tester.pumpAndSettle();

    expect(find.text('3 项'), findsOneWidget);

    await tester.tap(find.byTooltip('更多操作').first);
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.widgetWithText(PopupMenuItem<String>, '编辑')),
      const Size(112, 36),
    );
    expect(
      tester.getSize(find.widgetWithText(PopupMenuItem<String>, '删除')),
      const Size(112, 36),
    );
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('删除素材？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-delete-item')));
    await tester.pumpAndSettle();

    expect(find.text('2 项'), findsOneWidget);
    expect(find.text('删除素材？'), findsNothing);
  });

  testWidgets('keeps the delete dialog inside the native paper panel', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(536, 656));
    final window = _NativeRecordingWindowController();
    addTearDown(window.dispose);
    await tester.pumpWidget(JianheApp(windowController: window));
    await tester.pumpAndSettle();

    window.selectAction(BallWindowEventType.prompts);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    final dialog = tester.getRect(find.byKey(const Key('delete-item-dialog')));
    const panel = Rect.fromLTRB(8, 8, 428, 578);
    expect(dialog.left, greaterThanOrEqualTo(panel.left));
    expect(dialog.top, greaterThanOrEqualTo(panel.top));
    expect(dialog.right, lessThanOrEqualTo(panel.right));
    expect(dialog.bottom, lessThanOrEqualTo(panel.bottom));
  });

  for (final testCase in <({String edge, Rect panel})>[
    (edge: 'left', panel: Rect.fromLTRB(72, 8, 312, 328)),
    (edge: 'right', panel: Rect.fromLTRB(8, 8, 248, 328)),
    (edge: 'top', panel: Rect.fromLTRB(8, 76, 248, 392)),
    (edge: 'bottom', panel: Rect.fromLTRB(8, 8, 248, 328)),
  ]) {
    testWidgets(
      'keeps compact dialogs inside the ${testCase.edge} paper panel',
      (tester) async {
        useDesktopSurface(tester, physicalSize: const Size(536, 656));
        final window = _NativeRecordingWindowController();
        addTearDown(window.dispose);
        await tester.pumpWidget(
          JianheApp(
            windowController: window,
            savedBallDockEdge: testCase.edge,
            savedBallOffset: '200',
          ),
        );
        await tester.pumpAndSettle();

        window.selectAction(BallWindowEventType.more);
        await tester.pumpAndSettle();
        window.resizePanelTo(const Size(320, 400));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('唤起快捷键'),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        final hotKeyTile = tester.widget<ListTile>(
          find.ancestor(
            of: find.text('唤起快捷键'),
            matching: find.byType(ListTile),
          ),
        );
        hotKeyTile.onTap!();
        await tester.pumpAndSettle();

        final dialog = tester.getRect(
          find.byKey(const Key('wake-hot-key-dialog')),
        );
        expect(dialog.width, lessThanOrEqualTo(320));
        expect(dialog.left, greaterThanOrEqualTo(testCase.panel.left));
        expect(dialog.top, greaterThanOrEqualTo(testCase.panel.top));
        expect(dialog.right, lessThanOrEqualTo(testCase.panel.right));
        expect(dialog.bottom, lessThanOrEqualTo(testCase.panel.bottom));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('keeps category management compact and scrollable', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(536, 656));
    final window = _NativeRecordingWindowController();
    addTearDown(window.dispose);
    await tester.pumpWidget(JianheApp(windowController: window));
    await tester.pumpAndSettle();

    window.selectAction(BallWindowEventType.prompts);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manage-categories')));
    await tester.pumpAndSettle();

    final dialog = tester.getRect(
      find.byKey(const Key('manage-categories-dialog')),
    );
    const panel = Rect.fromLTRB(8, 8, 428, 578);
    expect(dialog.width, lessThanOrEqualTo(320));
    expect(dialog.left, greaterThanOrEqualTo(panel.left));
    expect(dialog.top, greaterThanOrEqualTo(panel.top));
    expect(dialog.right, lessThanOrEqualTo(panel.right));
    expect(dialog.bottom, lessThanOrEqualTo(panel.bottom));
    expect(find.byType(ListView), findsWidgets);
  });

  testWidgets('shows three categories and collapses after filtering', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(560, 760));
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    for (final category in const [
      'A分类',
      'B分类',
      'C分类',
      'D分类',
      'E分类',
      'ZABCDE分类',
    ]) {
      await storage.items.save(
        JianheItem.create(
          id: 'item-$category',
          type: ItemType.prompt,
          title: '$category 素材',
          content: '$category 内容',
          category: category,
        ),
      );
    }
    await storage.items.save(
      JianheItem.create(
        id: 'uncategorized-item',
        type: ItemType.prompt,
        title: '未分类素材',
        content: '未分类内容',
      ),
    );
    await tester.pumpWidget(JianheApp(repository: storage.items));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prompt'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('category-A分类')), findsOneWidget);
    expect(find.byKey(const ValueKey('category-B分类')), findsOneWidget);
    expect(find.byKey(const ValueKey('category-C分类')), findsOneWidget);
    expect(find.byKey(const ValueKey('category-D分类')), findsNothing);
    expect(find.byTooltip('展开分类'), findsOneWidget);

    final categorySizes = [
      tester.getSize(find.byKey(const ValueKey('category-A分类'))),
      tester.getSize(find.byKey(const ValueKey('category-B分类'))),
      tester.getSize(find.byKey(const ValueKey('category-C分类'))),
      tester.getSize(find.byKey(const Key('category-all'))),
      tester.getSize(find.byKey(const Key('category-uncategorized'))),
    ];
    expect(categorySizes.map((size) => size.width).toSet(), hasLength(1));
    expect(categorySizes.map((size) => size.height).toSet(), hasLength(1));
    expect(categorySizes.first.width, greaterThanOrEqualTo(96));

    await tester.tap(find.byKey(const Key('toggle-categories-expanded')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('category-D分类')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('category-ZABCDE分类')),
        matching: find.text('ZABC'),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('收起分类'), findsOneWidget);

    final categoryChip = tester.widget<ChoiceChip>(
      find.descendant(
        of: find.byKey(const ValueKey('category-D分类')),
        matching: find.byType(ChoiceChip),
      ),
    );
    categoryChip.onSelected!(true);
    await tester.pumpAndSettle();

    expect(find.byTooltip('展开分类'), findsOneWidget);
    expect(find.text('1 项'), findsOneWidget);
    expect(find.text('D分类 素材'), findsOneWidget);
    expect(find.text('A分类 素材'), findsNothing);
    // Selecting a middle category slides the three-item window so the
    // selected category is centered and both adjacent categories are whole.
    expect(find.byKey(const ValueKey('category-C分类')), findsOneWidget);
    expect(find.byKey(const ValueKey('category-D分类')), findsOneWidget);
    expect(find.byKey(const ValueKey('category-E分类')), findsOneWidget);
    expect(find.byKey(const ValueKey('category-A分类')), findsNothing);
    expect(find.byKey(const ValueKey('category-B分类')), findsNothing);

    // A category at the beginning keeps the window anchored to the first
    // three items.
    await tester.tap(find.byKey(const Key('toggle-categories-expanded')));
    await tester.pumpAndSettle();
    final firstCategoryChip = tester.widget<ChoiceChip>(
      find.descendant(
        of: find.byKey(const ValueKey('category-A分类')),
        matching: find.byType(ChoiceChip),
      ),
    );
    firstCategoryChip.onSelected!(true);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('category-A分类')), findsOneWidget);
    expect(find.byKey(const ValueKey('category-B分类')), findsOneWidget);
    expect(find.byKey(const ValueKey('category-C分类')), findsOneWidget);
    expect(find.byKey(const ValueKey('category-D分类')), findsNothing);

    // A category at the end keeps the window anchored to the last three.
    await tester.tap(find.byKey(const Key('toggle-categories-expanded')));
    await tester.pumpAndSettle();
    final lastCategoryChip = tester.widget<ChoiceChip>(
      find.descendant(
        of: find.byKey(const ValueKey('category-ZABCDE分类')),
        matching: find.byType(ChoiceChip),
      ),
    );
    lastCategoryChip.onSelected!(true);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('category-D分类')), findsOneWidget);
    expect(find.byKey(const ValueKey('category-E分类')), findsOneWidget);
    expect(find.byKey(const ValueKey('category-ZABCDE分类')), findsOneWidget);
    expect(find.byKey(const ValueKey('category-C分类')), findsNothing);
  });

  testWidgets('rating changes update the sync timestamp and journal', (
    tester,
  ) async {
    useDesktopSurface(tester);
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    final original = JianheItem.create(
      id: 'rating-sync-item',
      type: ItemType.prompt,
      title: '星级同步素材',
      content: '正文',
      now: DateTime.utc(2026, 9, 4, 8),
    );
    await storage.items.save(original);
    for (final row in storage.sync.readPendingChanges()) {
      storage.sync.deletePendingChanges(
        row.entityType,
        row.entityId,
        upToSeq: row.seq,
      );
    }
    expect(storage.sync.pendingCount(), 0);

    await tester.pumpWidget(JianheApp(repository: storage.items));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prompt'));
    await tester.pumpAndSettle();

    final slip = find.byKey(const ValueKey('rating-sync-item'));
    await tester.tap(
      find.descendant(
        of: slip,
        matching: find.byKey(const Key('set-rating-3')),
      ),
    );
    await tester.pumpAndSettle();

    final saved = await storage.items.getById(original.id);
    expect(saved?.rating, 3);
    expect(saved?.updatedAt.isAfter(original.updatedAt), isTrue);
    expect(storage.sync.pendingCount(), 1);
  });

  testWidgets(
    'moves items under a category filter without corrupting hidden sort orders',
    (tester) async {
      useDesktopSurface(tester, physicalSize: const Size(560, 760));
      final storage = JianheStorageDatabase.inMemory();
      addTearDown(storage.close);
      final now = DateTime.utc(2026, 9, 4, 8);
      await storage.items.save(
        JianheItem.create(
          id: 'b-1',
          type: ItemType.prompt,
          title: 'B素材',
          content: 'B内容',
          category: 'B分类',
          sortOrder: 0,
          now: now,
        ),
      );
      await storage.items.save(
        JianheItem.create(
          id: 'a-1',
          type: ItemType.prompt,
          title: 'A素材一',
          content: 'A内容一',
          category: 'A分类',
          sortOrder: 1,
          now: now,
        ),
      );
      await storage.items.save(
        JianheItem.create(
          id: 'a-2',
          type: ItemType.prompt,
          title: 'A素材二',
          content: 'A内容二',
          category: 'A分类',
          sortOrder: 2,
          now: now,
        ),
      );
      for (final row in storage.sync.readPendingChanges()) {
        storage.sync.deletePendingChanges(
          row.entityType,
          row.entityId,
          upToSeq: row.seq,
        );
      }
      expect(storage.sync.pendingCount(), 0);
      await tester.pumpWidget(JianheApp(repository: storage.items));
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prompt'));
      await tester.pumpAndSettle();

      tester
          .widget<PopupMenuButton<ItemSortMode>>(
            find.byKey(const Key('sort-menu')),
          )
          .onSelected!(ItemSortMode.custom);
      await tester.pumpAndSettle();

      final categoryChip = tester.widget<ChoiceChip>(
        find.descendant(
          of: find.byKey(const ValueKey('category-A分类')),
          matching: find.byType(ChoiceChip),
        ),
      );
      categoryChip.onSelected!(true);
      await tester.pumpAndSettle();

      expect(find.text('B素材'), findsNothing);
      expect(find.text('A素材一'), findsOneWidget);
      expect(find.text('A素材二'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('a-2')),
          matching: find.byTooltip('更多操作'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('在自定义排序中上移'));
      await tester.pumpAndSettle();

      expect(find.text('A素材二'), findsOneWidget);
      expect(
        tester.getTopRight(find.byKey(const ValueKey('a-2'))).dy,
        lessThan(tester.getTopRight(find.byKey(const ValueKey('a-1'))).dy),
      );

      final rows = await storage.items.listAll();
      final orderedIds = [...rows]
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      expect(orderedIds.map((item) => item.id).toList(), <String>[
        'b-1',
        'a-2',
        'a-1',
      ]);
      expect(
        rows.map((item) => item.sortOrder).toSet(),
        hasLength(rows.length),
      );
      expect(storage.sync.pendingCount(), 2);
      expect(
        rows
            .where((item) => item.id == 'a-1' || item.id == 'a-2')
            .every((item) => item.updatedAt.isAfter(now)),
        isTrue,
      );
    },
  );

  group('custom order writes only what it must', () {
    final base = DateTime.utc(2026, 9, 4, 8);

    Future<void> savePrompt(
      JianheStorageDatabase storage,
      String id, {
      int sortOrder = 0,
      int rating = 0,
      DateTime? now,
    }) {
      return storage.items.save(
        JianheItem.create(
          id: id,
          type: ItemType.prompt,
          title: '素材 $id',
          content: '原内容 $id',
          sortOrder: sortOrder,
          rating: rating,
          now: now ?? base,
        ),
      );
    }

    void clearPending(JianheStorageDatabase storage) {
      for (final row in storage.sync.readPendingChanges()) {
        storage.sync.deletePendingChanges(
          row.entityType,
          row.entityId,
          upToSeq: row.seq,
        );
      }
    }

    Future<void> openPromptsInCustomOrder(
      WidgetTester tester,
      JianheStorageDatabase storage,
    ) async {
      await tester.pumpWidget(JianheApp(repository: storage.items));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prompt'));
      await tester.pumpAndSettle();
      tester
          .widget<PopupMenuButton<ItemSortMode>>(
            find.byKey(const Key('sort-menu')),
          )
          .onSelected!(ItemSortMode.custom);
      await tester.pumpAndSettle();
    }

    Future<void> moveUp(WidgetTester tester, String id) async {
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey(id)),
          matching: find.byTooltip('更多操作'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('在自定义排序中上移'));
      await tester.pumpAndSettle();
    }

    Future<Map<String, int>> storedOrders(JianheStorageDatabase storage) async {
      return <String, int>{
        for (final item in await storage.items.listAll())
          item.id: item.sortOrder,
      };
    }

    testWidgets('an arrangement survives and a new duplicate goes last', (
      tester,
    ) async {
      useDesktopSurface(tester, physicalSize: const Size(560, 760));
      final storage = JianheStorageDatabase.inMemory();
      addTearDown(storage.close);
      await savePrompt(storage, 'p-0', sortOrder: 0);
      await savePrompt(storage, 'p-1', sortOrder: 1);
      await savePrompt(storage, 'p-2', sortOrder: 2);
      // Imported later with the default order 0 and five stars. Switching
      // to custom order used to renumber the whole type by smart order:
      // this item jumped to the top and every item was rewritten.
      await savePrompt(
        storage,
        'imported',
        rating: 5,
        now: base.add(const Duration(days: 1)),
      );
      clearPending(storage);

      await openPromptsInCustomOrder(tester, storage);

      expect(await storedOrders(storage), <String, int>{
        'p-0': 0,
        'p-1': 1,
        'p-2': 2,
        'imported': 3,
      });
      expect(
        storage.sync.readPendingChanges().map((row) => row.entityId),
        <String>['imported'],
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('imported'))).dy,
        greaterThan(tester.getTopLeft(find.byKey(const ValueKey('p-2'))).dy),
      );
    });

    testWidgets('a never-arranged type is seeded from the smart order', (
      tester,
    ) async {
      useDesktopSurface(tester, physicalSize: const Size(560, 760));
      final storage = JianheStorageDatabase.inMemory();
      addTearDown(storage.close);
      await savePrompt(storage, 'one-star', rating: 1);
      await savePrompt(storage, 'five-star', rating: 5);
      await savePrompt(storage, 'three-star', rating: 3);
      clearPending(storage);

      await openPromptsInCustomOrder(tester, storage);

      expect(await storedOrders(storage), <String, int>{
        'five-star': 0,
        'three-star': 1,
        'one-star': 2,
      });
      // five-star already had order 0.
      expect(storage.sync.pendingCount(), 2);
    });

    testWidgets('moving an item swaps exactly two orders', (tester) async {
      useDesktopSurface(tester, physicalSize: const Size(560, 760));
      final storage = JianheStorageDatabase.inMemory();
      addTearDown(storage.close);
      await savePrompt(storage, 'g-0', sortOrder: 0);
      await savePrompt(storage, 'g-3', sortOrder: 3);
      await savePrompt(storage, 'g-5', sortOrder: 5);
      await savePrompt(storage, 'g-9', sortOrder: 9);
      clearPending(storage);

      await openPromptsInCustomOrder(tester, storage);
      await moveUp(tester, 'g-5');

      // Renumbering the list 0..n-1 used to rewrite g-9 as well.
      expect(await storedOrders(storage), <String, int>{
        'g-0': 0,
        'g-3': 5,
        'g-5': 3,
        'g-9': 9,
      });
      expect(storage.sync.pendingCount(), 2);
    });

    testWidgets('moving never writes back an outdated copy of the item', (
      tester,
    ) async {
      useDesktopSurface(tester, physicalSize: const Size(560, 760));
      final storage = JianheStorageDatabase.inMemory();
      addTearDown(storage.close);
      await savePrompt(storage, 'first', sortOrder: 0);
      await savePrompt(storage, 'second', sortOrder: 1);

      await openPromptsInCustomOrder(tester, storage);
      // Changed in storage after the list loaded, e.g. by the CLI; the
      // panel still holds the old content.
      final current = await storage.items.getById('second');
      await storage.items.save(
        current!.copyWith(
          content: '命令行改过的内容',
          updatedAt: base.add(const Duration(days: 1)),
        ),
      );
      clearPending(storage);

      await moveUp(tester, 'second');

      final second = await storage.items.getById('second');
      expect(second?.content, '命令行改过的内容');
      expect(second?.sortOrder, 0);
      expect((await storage.items.getById('first'))?.sortOrder, 1);
      expect(storage.sync.pendingCount(), 2);
    });
  });

  testWidgets(
    'keeps the three selected categories inside the native browser panel',
    (tester) async {
      useDesktopSurface(tester, physicalSize: const Size(560, 760));
      final storage = JianheStorageDatabase.inMemory();
      final window = _NativeRecordingWindowController();
      addTearDown(storage.close);
      addTearDown(window.dispose);
      for (final category in const ['A分类', 'B分类', 'C分类', 'D分类', 'E分类']) {
        await storage.items.createCategory(ItemType.prompt, category);
      }
      await tester.pumpWidget(
        JianheApp(repository: storage.items, windowController: window),
      );
      await tester.pumpAndSettle();
      window.selectAction(BallWindowEventType.prompts);
      await tester.pumpAndSettle();

      void expectFullyVisible(List<String> categories) {
        final scrollRect = tester.getRect(
          find.byKey(const Key('collapsed-category-scroll')),
        );
        for (final category in categories) {
          final chipRect = tester.getRect(
            find.byKey(ValueKey('category-$category')),
          );
          expect(chipRect.left, greaterThanOrEqualTo(scrollRect.left));
          expect(chipRect.right, lessThanOrEqualTo(scrollRect.right));
        }
      }

      expectFullyVisible(const ['A分类', 'B分类', 'C分类']);

      final categoryC = tester.widget<ChoiceChip>(
        find.descendant(
          of: find.byKey(const ValueKey('category-C分类')),
          matching: find.byType(ChoiceChip),
        ),
      );
      categoryC.onSelected!(true);
      await tester.pumpAndSettle();
      expectFullyVisible(const ['B分类', 'C分类', 'D分类']);

      final categoryD = tester.widget<ChoiceChip>(
        find.descendant(
          of: find.byKey(const ValueKey('category-D分类')),
          matching: find.byType(ChoiceChip),
        ),
      );
      categoryD.onSelected!(true);
      await tester.pumpAndSettle();
      expectFullyVisible(const ['C分类', 'D分类', 'E分类']);
    },
  );

  testWidgets('pins a category from the right-click menu', (tester) async {
    useDesktopSurface(tester, physicalSize: const Size(560, 760));
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    for (final category in const ['A分类', 'B分类', 'C分类', 'D分类']) {
      await storage.items.createCategory(ItemType.prompt, category);
    }
    ItemType? savedType;
    String? savedCategory;
    await tester.pumpWidget(
      JianheApp(
        repository: storage.items,
        onPinnedCategoryChanged: (type, category) {
          savedType = type;
          savedCategory = category;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prompt'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('category-B分类')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('置顶分类'), findsOneWidget);
    await tester.tap(find.byKey(const Key('toggle-pinned-category')));
    await tester.pumpAndSettle();

    expect(savedType, ItemType.prompt);
    expect(savedCategory, 'B分类');
    expect(find.byKey(const ValueKey('category-B分类')), findsOneWidget);
    expect(find.byIcon(Icons.push_pin_rounded), findsWidgets);
  });

  testWidgets('restores a pinned category in the first three categories', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(560, 760));
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    for (final category in const ['A分类', 'B分类', 'C分类', 'D分类', 'ZABCDE分类']) {
      await storage.items.createCategory(ItemType.prompt, category);
    }
    await tester.pumpWidget(
      JianheApp(
        repository: storage.items,
        initialPinnedCategories: const {ItemType.prompt: 'ZABCDE分类'},
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prompt'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('category-ZABCDE分类')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('category-ZABCDE分类')),
        matching: find.text('ZABC'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('category-A分类')), findsOneWidget);
    expect(find.byKey(const ValueKey('category-B分类')), findsOneWidget);
    expect(find.byKey(const ValueKey('category-C分类')), findsNothing);
  });

  testWidgets('canceling the delete confirmation keeps the item', (
    tester,
  ) async {
    useDesktopSurface(tester);
    await tester.pumpWidget(const JianheApp());
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prompt'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('3 项'), findsOneWidget);
  });

  testWidgets('deletes from the editor and returns to the browser', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(520, 1000));
    await tester.pumpWidget(const JianheApp());
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prompt'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(find.text('编辑纸笺'), findsOneWidget);
    await tester.tap(find.byKey(const Key('delete-item')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete-item')));
    await tester.pumpAndSettle();

    expect(find.text('编辑纸笺'), findsNothing);
    expect(find.text('2 项'), findsOneWidget);
  });

  testWidgets(
    'filters downward by rating and keeps the selected rating first',
    (tester) async {
      useDesktopSurface(tester);
      final storage = JianheStorageDatabase.inMemory();
      addTearDown(storage.close);
      final now = DateTime.utc(2026, 9, 15);
      for (final item in <({String id, String title, int rating})>[
        (id: 'rating-4', title: '四星素材', rating: 4),
        (id: 'rating-3', title: 'Z 三星素材', rating: 3),
        (id: 'rating-2', title: 'M 二星素材', rating: 2),
        (id: 'rating-1', title: 'A 一星素材', rating: 1),
        (id: 'rating-0', title: '未评级素材', rating: 0),
      ]) {
        await storage.items.save(
          JianheItem.create(
            id: item.id,
            type: ItemType.prompt,
            title: item.title,
            content: '${item.title}的正文',
            rating: item.rating,
            now: now,
          ),
        );
      }
      await tester.pumpWidget(JianheApp(repository: storage.items));
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prompt'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('rating-filter-all')), findsOneWidget);
      expect(find.byKey(const Key('rating-filter')), findsOneWidget);
      expect(find.byKey(const Key('rating-filter-mode')), findsNothing);
      expect(find.byKey(const Key('rating-filter-5')), findsOneWidget);
      expect(find.byKey(const Key('sort-menu')), findsOneWidget);
      expect(find.byKey(const Key('manage-categories')), findsOneWidget);

      await tester.tap(find.byKey(const Key('rating-filter-3')));
      await tester.pump();
      expect(find.text('3 项'), findsOneWidget);
      expect(find.text('Z 三星素材'), findsOneWidget);
      expect(find.text('M 二星素材'), findsOneWidget);
      expect(find.text('A 一星素材'), findsOneWidget);
      expect(find.text('四星素材'), findsNothing);
      expect(find.text('未评级素材'), findsNothing);

      tester
          .widget<PopupMenuButton<ItemSortMode>>(
            find.byKey(const Key('sort-menu')),
          )
          .onSelected!(ItemSortMode.title);
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.byKey(const ValueKey('rating-3'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('rating-2'))).dy),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('rating-2'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('rating-1'))).dy),
      );

      await tester.tap(find.byKey(const Key('rating-filter-all')));
      await tester.pump();
      expect(find.text('5 项'), findsOneWidget);
    },
  );

  testWidgets('creates a standalone category before adding an item', (
    tester,
  ) async {
    useDesktopSurface(tester);
    await tester.pumpWidget(const JianheApp());
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prompt'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-category')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('new-category-name')), '工作复盘');
    await tester.tap(find.byKey(const Key('confirm-create-category')));
    await tester.pumpAndSettle();

    expect(find.text('工作复盘'), findsOneWidget);
    expect(find.text('没有找到匹配的素材'), findsOneWidget);

    await tester.tap(find.text('新建Prompt'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('editor-category')),
        matching: find.text('工作复盘'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('editor only selects categories from the active module', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(520, 1000));
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    await storage.items.createCategory(ItemType.prompt, 'Prompt分类');
    await storage.items.createCategory(ItemType.skill, 'Skill分类');

    await tester.pumpWidget(
      JianheApp(
        repository: storage.items,
        storageTransactionRunner: storage.writeTransaction,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('editor-category')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('editor-category')),
        matching: find.byType(EditableText),
      ),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('editor-category')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('editor-category-option-Prompt分类')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('editor-category-option-Skill分类')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('editor-category-option-Prompt分类')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skill'));
    await tester.pump();

    expect(
      find.descendant(
        of: find.byKey(const Key('editor-category')),
        matching: find.text('未分类'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('editor-category')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('editor-category-option-Prompt分类')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('editor-category-option-Skill分类')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('editor-title')), '分类选择测试');
    await tester.enterText(
      find.byKey(const Key('editor-content')),
      '只能使用已有分类。',
    );
    await tester.tap(find.byKey(const Key('save-item')));
    await tester.pumpAndSettle();

    final saved = await storage.items.list(type: ItemType.skill);
    expect(saved.single.category, 'Skill分类');
    expect(await storage.items.listCategories(ItemType.skill), <String>[
      'Skill分类',
    ]);
  });

  testWidgets(
    'editor category picker stays inside the panel and exposes scroll',
    (tester) async {
      useDesktopSurface(tester, physicalSize: const Size(470, 610));
      final storage = JianheStorageDatabase.inMemory();
      addTearDown(storage.close);
      for (var index = 1; index <= 12; index++) {
        await storage.items.createCategory(
          ItemType.prompt,
          '分类${index.toString().padLeft(2, '0')}',
        );
      }

      await tester.pumpWidget(JianheApp(repository: storage.items));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('editor-category')));
      await tester.pumpAndSettle();

      final picker = find.byKey(const Key('editor-category-picker'));
      final pickerRect = tester.getRect(picker);
      const visiblePanelRect = Rect.fromLTRB(8, 8, 470 - 72, 610 - 72);
      expect(visiblePanelRect.contains(pickerRect.topLeft), isTrue);
      expect(visiblePanelRect.contains(pickerRect.bottomRight), isTrue);
      expect(pickerRect.left, 24);
      expect(pickerRect.right, 470 - 72 - 16);

      final scrollbar = tester.widget<Scrollbar>(
        find.byKey(const Key('editor-category-scrollbar')),
      );
      expect(scrollbar.thumbVisibility, isTrue);
      expect(
        find.byKey(const ValueKey('editor-category-option-分类12')),
        findsNothing,
      );

      await tester.drag(
        find.byKey(const Key('editor-category-options-scroll')),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();

      final lastOption = find.byKey(
        const ValueKey('editor-category-option-分类12'),
      );
      expect(lastOption, findsOneWidget);
      final lastOptionRect = tester.getRect(lastOption);
      final listRect = tester.getRect(
        find.byKey(const Key('editor-category-options-scroll')),
      );
      expect(listRect.height, 5 * 48);
      expect(lastOptionRect.top, greaterThanOrEqualTo(listRect.top));
      expect(lastOptionRect.bottom, lessThanOrEqualTo(listRect.bottom));

      await tester.tap(lastOption);
      await tester.pumpAndSettle();
      expect(picker, findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('editor-category')),
          matching: find.text('分类12'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('editor-category')));
      await tester.pumpAndSettle();
      final selectedOption = find.byKey(
        const ValueKey('editor-category-option-分类12'),
      );
      expect(selectedOption, findsOneWidget);
      expect(
        find.descendant(
          of: selectedOption,
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('editor category picker keeps whole rows at minimum height', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(470, 400));
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    for (var index = 1; index <= 12; index++) {
      await storage.items.createCategory(
        ItemType.prompt,
        '分类${index.toString().padLeft(2, '0')}',
      );
    }

    await tester.pumpWidget(JianheApp(repository: storage.items));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('editor-category')));
    await tester.pumpAndSettle();

    final pickerRect = tester.getRect(
      find.byKey(const Key('editor-category-picker')),
    );
    const visiblePanelRect = Rect.fromLTRB(8, 8, 470 - 72, 400 - 72);
    expect(visiblePanelRect.contains(pickerRect.topLeft), isTrue);
    expect(visiblePanelRect.contains(pickerRect.bottomRight), isTrue);
    final listRect = tester.getRect(
      find.byKey(const Key('editor-category-options-scroll')),
    );
    expect(listRect.height, 4 * 48);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('editor-category')),
        matching: find.text('分类01'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('category selector balances the auto-collapse lifecycle', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(520, 1000));
    final storage = JianheStorageDatabase.inMemory();
    final window = _RecordingWindowController();
    addTearDown(storage.close);
    await storage.items.createCategory(ItemType.prompt, 'Prompt分类');

    await tester.pumpWidget(
      JianheApp(
        repository: storage.items,
        windowController: window,
        initialAutoCollapseSeconds: 1,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('editor-category')));
    await tester.pumpAndSettle();

    final region = tester.widget<MouseRegion>(
      find.byKey(const Key('ball-mouse-region')),
    );
    region.onExit!(const PointerExitEvent());
    await tester.pump(const Duration(milliseconds: 1100));

    expect(window.stages.last, BallWindowStage.editor);
    expect(find.text('Prompt分类'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump(const Duration(milliseconds: 500));

    expect(window.stages.last, BallWindowStage.collapsed);
  });

  testWidgets('editor does not recreate a category missing at save time', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(520, 1000));
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    await storage.items.createCategory(ItemType.prompt, '临时分类');

    await tester.pumpWidget(
      JianheApp(
        repository: storage.items,
        storageTransactionRunner: storage.writeTransaction,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('editor-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-category-option-临时分类')));
    await tester.pumpAndSettle();
    await storage.items.deleteCategory(ItemType.prompt, '临时分类');
    await tester.enterText(find.byKey(const Key('editor-title')), '不会保存的素材');
    await tester.enterText(find.byKey(const Key('editor-content')), '测试内容');
    await tester.tap(find.byKey(const Key('save-item')));
    await tester.pumpAndSettle();

    expect(find.text('所选分类已不存在，请重新选择'), findsOneWidget);
    expect(await storage.items.list(type: ItemType.prompt), isEmpty);
    expect(await storage.items.listCategories(ItemType.prompt), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('creates a new text item and persists it', (tester) async {
    useDesktopSurface(tester, physicalSize: const Size(520, 1000));
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    await storage.items.save(
      JianheItem.create(
        id: 'rated-snippet',
        type: ItemType.snippet,
        title: '五星旧素材',
        content: '已有文本',
        rating: 5,
        now: DateTime.utc(2020),
      ),
    );
    await tester.pumpWidget(JianheApp(repository: storage.items));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文本'));
    await tester.enterText(find.byKey(const Key('editor-title')), '发布说明');
    await tester.enterText(
      find.byKey(const Key('editor-content')),
      '这是刚刚保存的常用文本。',
    );
    await tester.tap(find.byKey(const Key('save-item')));
    await tester.tap(find.byKey(const Key('save-item')));
    await tester.pumpAndSettle();

    final saved = await storage.items.list(type: ItemType.snippet);
    expect(saved, hasLength(2));
    expect(saved.where((item) => item.title == '发布说明'), hasLength(1));
    expect(find.text('常用文本'), findsOneWidget);
    expect(find.text('发布说明'), findsOneWidget);
    expect(find.text('最近修改'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('发布说明')).dy,
      lessThan(tester.getTopLeft(find.text('五星旧素材')).dy),
    );
  });

  testWidgets('fades the ball when the pointer leaves', (tester) async {
    useDesktopSurface(tester);
    await tester.pumpWidget(const JianheApp());
    await tester.pumpAndSettle();

    AnimatedOpacity opacity() => tester.widget<AnimatedOpacity>(
      find.byKey(const Key('jianhe-ball-opacity')),
    );
    final region = tester.widget<MouseRegion>(
      find.byKey(const Key('ball-mouse-region')),
    );

    expect(opacity().opacity, .48);
    region.onEnter!(const PointerEnterEvent());
    await tester.pump();
    expect(opacity().opacity, 1);

    region.onExit!(const PointerExitEvent());
    await tester.pump();
    expect(opacity().opacity, .48);
  });

  testWidgets('collapses expanded content after the configured delay', (
    tester,
  ) async {
    useDesktopSurface(tester);
    final window = _RecordingWindowController();
    await tester.pumpWidget(
      JianheApp(windowController: window, initialAutoCollapseSeconds: 1),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('jianhe-ball')));
    await tester.pumpAndSettle();
    expect(window.stages.last, BallWindowStage.menu);

    final region = tester.widget<MouseRegion>(
      find.byKey(const Key('ball-mouse-region')),
    );
    region.onExit!(const PointerExitEvent());
    await tester.pump(const Duration(milliseconds: 1100));
    // let the arc retract animation finish before the stage collapses
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(window.stages.last, BallWindowStage.collapsed);
  });

  testWidgets('a legacy zero delay is raised to the one second minimum', (
    tester,
  ) async {
    useDesktopSurface(tester);
    final window = _RecordingWindowController();
    await tester.pumpWidget(
      JianheApp(windowController: window, initialAutoCollapseSeconds: 0),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('jianhe-ball')));
    await tester.pumpAndSettle();
    expect(window.stages.last, BallWindowStage.menu);

    final region = tester.widget<MouseRegion>(
      find.byKey(const Key('ball-mouse-region')),
    );

    // A transient exit→enter (stage resize, gap between sub-balls) must not
    // collapse the menu.
    region.onExit!(const PointerExitEvent());
    await tester.pump(const Duration(milliseconds: 50));
    region.onEnter!(const PointerEnterEvent());
    await tester.pump(const Duration(milliseconds: 1200));
    expect(window.stages.last, BallWindowStage.menu);

    // A real exit waits the full minimum second, not an immediate collapse.
    region.onExit!(const PointerExitEvent());
    await tester.pump(const Duration(milliseconds: 500));
    expect(window.stages.last, BallWindowStage.menu);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(window.stages.last, BallWindowStage.collapsed);
  });

  testWidgets('auto collapse slider starts at one second', (tester) async {
    useDesktopSurface(tester);
    await tester.pumpWidget(const JianheApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('jianhe-ball')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();

    final slider = tester.widget<Slider>(
      find.byKey(const Key('auto-collapse-slider')),
    );
    expect(slider.min, 1);
    expect(slider.max, 60);
  });

  testWidgets('keeps expanded content open while a popup menu is active', (
    tester,
  ) async {
    useDesktopSurface(tester);
    final window = _RecordingWindowController();
    await tester.pumpWidget(
      JianheApp(windowController: window, initialAutoCollapseSeconds: 1),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('jianhe-ball')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prompt'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sort-menu')));
    await tester.pumpAndSettle();

    final region = tester.widget<MouseRegion>(
      find.byKey(const Key('ball-mouse-region')),
    );
    region.onExit!(const PointerExitEvent());
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump();

    expect(window.stages.last, BallWindowStage.browser);
    expect(find.text('最近使用'), findsOneWidget);
  });

  testWidgets('keeps expanded content open while a dialog is active', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(536, 656));
    final window = _NativeRecordingWindowController();
    addTearDown(window.dispose);
    await tester.pumpWidget(
      JianheApp(windowController: window, initialAutoCollapseSeconds: 1),
    );
    await tester.pumpAndSettle();

    window.selectAction(BallWindowEventType.prompts);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manage-categories')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manage-categories-dialog')), findsOneWidget);

    final region = tester.widget<MouseRegion>(
      find.byKey(const Key('ball-mouse-region')),
    );
    region.onExit!(const PointerExitEvent());
    await tester.pump(const Duration(milliseconds: 1100));

    expect(window.stages.last, BallWindowStage.browser);
    expect(find.byKey(const Key('manage-categories-dialog')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump(const Duration(milliseconds: 500));

    expect(window.stages.last, BallWindowStage.collapsed);
  });

  testWidgets(
    'collapses the panel with its dialog after the pointer leaves the window',
    (tester) async {
      useDesktopSurface(tester, physicalSize: const Size(536, 656));
      final window = _NativeRecordingWindowController();
      addTearDown(window.dispose);
      await tester.pumpWidget(
        JianheApp(windowController: window, initialAutoCollapseSeconds: 1),
      );
      await tester.pumpAndSettle();

      window.selectAction(BallWindowEventType.prompts);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('manage-categories')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('manage-categories-dialog')),
        findsOneWidget,
      );

      // The panel region exits as soon as the dialog barrier takes over the
      // hit test; that alone must not start the countdown...
      final panelRegion = tester.widget<MouseRegion>(
        find.byKey(const Key('ball-mouse-region')),
      );
      panelRegion.onExit!(const PointerExitEvent());
      await tester.pump(const Duration(milliseconds: 1100));
      expect(window.stages.last, BallWindowStage.browser);
      expect(
        find.byKey(const Key('manage-categories-dialog')),
        findsOneWidget,
      );

      // ...but the dialog frame region reporting the pointer beyond the
      // window bounds does, and takes the dialog down with the panel.
      final frameRegion = tester.widget<MouseRegion>(
        find.byKey(const Key('dialog-frame-region-1')),
      );
      frameRegion.onExit!(const PointerExitEvent());
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.pumpAndSettle();

      expect(window.stages.last, BallWindowStage.collapsed);
      expect(find.byKey(const Key('manage-categories-dialog')), findsNothing);
    },
  );

  testWidgets(
    'dragging the panel edge does not arm the auto collapse', (tester) async {
      useDesktopSurface(tester, physicalSize: const Size(536, 656));
      final window = _NativeRecordingWindowController();
      addTearDown(window.dispose);
      await tester.pumpWidget(
        JianheApp(windowController: window, initialAutoCollapseSeconds: 1),
      );
      await tester.pumpAndSettle();

      window.selectAction(BallWindowEventType.prompts);
      await tester.pumpAndSettle();

      // Enter the native sizing loop: exit events raised while the pointer
      // is untracked (the cursor rides the dragged edge) must not start the
      // countdown...
      window.selectAction(BallWindowEventType.resizeStart);
      window.selectAction(BallWindowEventType.exit);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 1100));
      expect(window.stages.last, BallWindowStage.browser);

      // ...and neither does finishing the drag with the cursor on the edge.
      window.selectAction(BallWindowEventType.resizeEnd);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.pumpAndSettle();
      expect(window.stages.last, BallWindowStage.browser);

      // A real exit afterwards still collapses the panel.
      final region = tester.widget<MouseRegion>(
        find.byKey(const Key('ball-mouse-region')),
      );
      region.onExit!(const PointerExitEvent());
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      expect(window.stages.last, BallWindowStage.collapsed);
    },
  );

  testWidgets('allows the auto collapse delay to be customized', (
    tester,
  ) async {
    useDesktopSurface(tester);
    final savedValues = <int>[];
    await tester.pumpWidget(
      JianheApp(onAutoCollapseSecondsChanged: savedValues.add),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('jianhe-ball')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();

    final slider = tester.widget<Slider>(
      find.byKey(const Key('auto-collapse-slider')),
    );
    slider.onChanged!(25);
    slider.onChangeEnd!(25);
    await tester.pump();

    final value = tester.widget<Text>(
      find.byKey(const Key('auto-collapse-value')),
    );
    expect(value.data, '25 秒');
    expect(savedValues, <int>[25]);
  });

  testWidgets('offers offline export and import from settings', (tester) async {
    useDesktopSurface(tester);
    await tester.pumpWidget(const JianheApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('jianhe-ball')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();

    expect(find.text('导出全部内容'), findsOneWidget);
    expect(find.text('导入离线备份'), findsOneWidget);
    expect(find.textContaining('不需要会员或云服务'), findsOneWidget);
    expect(find.text('悬浮球位置'), findsNothing);
    expect(find.text('本地优先'), findsNothing);
    expect(
      tester
          .widget<ListTile>(
            find.descendant(
              of: find.byKey(const Key('export-backup-setting')),
              matching: find.byType(ListTile),
            ),
          )
          .onTap,
      isNotNull,
    );
    expect(
      tester
          .widget<ListTile>(
            find.descendant(
              of: find.byKey(const Key('import-backup-setting')),
              matching: find.byType(ListTile),
            ),
          )
          .onTap,
      isNotNull,
    );
  });

  testWidgets('database startup failure disables local and cloud backups', (
    tester,
  ) async {
    useDesktopSurface(tester);
    final backupFiles = _RecordingBackupFileService();
    await tester.pumpWidget(
      JianheApp(localStorageUnavailable: true, backupFileService: backupFiles),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('jianhe-ball')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();

    final exportTile = tester.widget<ListTile>(
      find.descendant(
        of: find.byKey(const Key('export-backup-setting')),
        matching: find.byType(ListTile),
      ),
    );
    final importTile = tester.widget<ListTile>(
      find.descendant(
        of: find.byKey(const Key('import-backup-setting')),
        matching: find.byType(ListTile),
      ),
    );
    expect(exportTile.onTap, isNull);
    expect(importTile.onTap, isNull);
    expect(find.text('本地数据库不可用，已停用备份导出'), findsOneWidget);
    expect(find.text('本地数据库不可用，已停用备份导入'), findsOneWidget);
    expect(backupFiles.saveCalls, 0);
    expect(backupFiles.openCalls, 0);

    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('笺盒账号'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('本地存储不可用，云服务已停用'), findsOneWidget);
    expect(find.byKey(const Key('cloud-backup-card')), findsNothing);
    expect(find.byKey(const Key('cloud-backup-security-card')), findsNothing);
  });

  testWidgets('database startup failure keeps demo content read-only', (
    tester,
  ) async {
    useDesktopSurface(tester);
    await tester.pumpWidget(const JianheApp(localStorageUnavailable: true));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('笺盒悬浮球'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prompt'));
    await tester.pumpAndSettle();

    final slip = find.byKey(const ValueKey('demo-summary'));
    await tester.tap(
      find.descendant(
        of: slip,
        matching: find.byKey(const Key('set-rating-3')),
      ),
    );
    await tester.pump();
    expect(
      find.descendant(of: slip, matching: find.byTooltip('设置为 3 星')),
      findsOneWidget,
    );
    expect(find.text('本地数据库不可用，当前演示数据为只读'), findsOneWidget);

    await tester.tap(
      find.descendant(of: slip, matching: find.byTooltip('更多操作')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pump();

    expect(find.byKey(const Key('delete-item-dialog')), findsNothing);
    expect(find.text('结构化总结'), findsWidgets);
  });

  testWidgets('uses one Windows command-line switch for both CLI permissions', (
    tester,
  ) async {
    useDesktopSurface(tester);
    final accessModes = <CliAccessMode>[];
    final skillImportValues = <bool>[];
    await tester.pumpWidget(
      JianheApp(
        onCliAccessModeChanged: accessModes.add,
        onCliSkillImportEnabledChanged: skillImportValues.add,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('jianhe-ball')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();

    expect(find.text('AI 命令行接口'), findsOneWidget);
    expect(
      find.text('允许 Claude Code、Codex 等 AI 助手通过命令行读写笺盒技能。'),
      findsOneWidget,
    );
    expect(find.text('CLI AI 访问'), findsNothing);
    expect(find.text('允许CLI导入Skill'), findsNothing);

    final commandLineSwitch = find.byKey(
      const Key('command-line-interface-switch'),
    );
    await tester.tap(commandLineSwitch);
    await tester.pump();
    expect(accessModes, <CliAccessMode>[CliAccessMode.readWrite]);
    expect(skillImportValues, <bool>[true]);

    await tester.tap(commandLineSwitch);
    await tester.pump();
    expect(accessModes, <CliAccessMode>[
      CliAccessMode.readWrite,
      CliAccessMode.disabled,
    ]);
    expect(skillImportValues, <bool>[true, false]);
  });

  testWidgets('importing a backup never changes CLI access permissions', (
    tester,
  ) async {
    useDesktopSurface(tester);
    final accessModes = <CliAccessMode>[];
    final skillImportValues = <bool>[];
    final backup = JianheBackup(
      exportedAt: DateTime.utc(2026, 8, 31),
      items: const <JianheItem>[],
      categories: const <ItemType, List<String>>{},
      settings: <String, Object?>{
        'cli_access_mode': CliAccessMode.readWrite.storageValue,
      },
    );
    await tester.pumpWidget(
      JianheApp(
        backupFileService: _FixedBackupFileService((
          name: 'backup.jianhe',
          content: backup.encode(),
        )),
        onCliAccessModeChanged: accessModes.add,
        onCliSkillImportEnabledChanged: skillImportValues.add,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('jianhe-ball')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入离线备份'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester
          .widget<AlertDialog>(
            find.descendant(
              of: find.byKey(const Key('import-backup-dialog')),
              matching: find.byType(AlertDialog),
            ),
          )
          .scrollable,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('confirm-import-backup')));
    await tester.pumpAndSettle();

    // A .jianhe file from another machine must not grant AI agents
    // read/write access; the permission is only changed in settings.
    expect(find.textContaining('导入完成'), findsOneWidget);
    expect(accessModes, isEmpty);
    expect(skillImportValues, isEmpty);
  });

  testWidgets(
    'importing a backup without Skill files keeps local attachments',
    (tester) async {
      useDesktopSurface(tester);
      final storage = JianheStorageDatabase.inMemory();
      addTearDown(storage.close);
      final skill = JianheItem.create(
        id: 'attached-skill',
        type: ItemType.skill,
        title: '本机技能',
        content: '# 本机旧内容',
        now: DateTime.utc(2026, 8, 20, 8),
      );
      await storage.skills.replaceSkill(
        skill,
        SkillPackage(
          skillId: skill.id,
          sourceFormat: SkillSourceFormat.directory,
          importedAt: DateTime.utc(2026, 8, 24),
          files: <SkillFile>[
            SkillFile(
              relativePath: 'references/guide.md',
              mediaType: 'text/markdown',
              content: Uint8List.fromList('# Guide'.codeUnits),
            ),
          ],
        ),
      );
      final backup = JianheBackup(
        exportedAt: DateTime.utc(2026, 9, 1, 11),
        items: <JianheItem>[
          skill.copyWith(
            content: '# 备份新内容',
            updatedAt: DateTime.utc(2026, 9, 1, 10),
          ),
        ],
        categories: const <ItemType, List<String>>{},
      );

      await tester.pumpWidget(
        JianheApp(
          repository: storage.items,
          skillPackages: storage.skills,
          backupFileService: _FixedBackupFileService((
            name: 'backup.jianhe',
            content: backup.encode(),
          )),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('jianhe-ball')));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入离线备份'));
      // The busy spinner on the import row animates until the import settles,
      // so a fixed pump replaces pumpAndSettle for the rest of this flow.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('confirm-import-backup')));
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect((await storage.items.list(limit: 10)).single.content, '# 备份新内容');
      final package = await storage.skills.getBySkillId('attached-skill');
      expect(package, isNotNull);
      expect(package!.files.single.relativePath, 'references/guide.md');
      expect(package.files.single.content, '# Guide'.codeUnits);
    },
  );

  testWidgets('shows an offline command-line guide inside the Windows app', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(900, 800));
    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final window = _NativeRecordingWindowController();
    addTearDown(window.dispose);
    await tester.pumpWidget(
      JianheApp(
        windowController: window,
        initialCliAccessMode: CliAccessMode.readWrite,
      ),
    );
    await tester.pumpAndSettle();
    window.selectAction(BallWindowEventType.more);
    await tester.pumpAndSettle();

    final guideEntry = find.text('AI 与 Skill 接入说明');
    expect(guideEntry, findsOneWidget);
    await tester.tap(guideEntry);
    await tester.pumpAndSettle();

    expect(window.stageSizes.last.$1, BallWindowStage.browser);
    expect(find.text('让 AI 调用笺盒 Skill，或将自建、外部 Skill 导入笺盒'), findsOneWidget);
    expect(find.textContaining('AI 命令行接口已开启'), findsOneWidget);
    final copyRequestButton = find.byKey(const Key('cli-help-copy-ai-request'));
    expect(copyRequestButton, findsOneWidget);
    expect(find.text('导出参考说明（.md）'), findsOneWidget);
    await tester.tap(copyRequestButton);
    await tester.pumpAndSettle();
    expect(copiedText, contains('我允许本次执行'));
    expect(copiedText, contains('附件仅是 JianHe CLI'));
    expect(copiedText, endsWith('任务：'));
    expect(find.textContaining('AI 请求已复制'), findsOneWidget);
    final helpScroll = find
        .descendant(
          of: find.byKey(const Key('cli-help-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    final referenceTip = find.textContaining('请求和参考文档要分开', findRichText: true);
    for (var i = 0; i < 4 && referenceTip.evaluate().isEmpty; i++) {
      await tester.drag(helpScroll, const Offset(0, -140));
      await tester.pumpAndSettle();
    }
    expect(referenceTip, findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('把自建或外部 Skill 正式保存到笺盒'),
      450,
      scrollable: helpScroll,
    );
    expect(find.text('此命令会写入笺盒；用户当前任务已要求导入时可直接执行。'), findsOneWidget);
    expect(find.text('会写入笺盒'), findsOneWidget);

    final faqSection = find.text('常见问题');
    for (var i = 0; i < 12 && faqSection.evaluate().isEmpty; i++) {
      await tester.drag(helpScroll, const Offset(0, -400));
      await tester.pumpAndSettle();
    }
    expect(faqSection, findsOneWidget);
    expect(
      find.textContaining('笺盒不会自动执行 Skill 中的脚本', findRichText: true),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('panel-back')));
    await tester.pumpAndSettle();
    expect(window.stages.last, BallWindowStage.settings);
    expect(
      find.text('允许 Claude Code、Codex 等 AI 助手通过命令行读写笺盒技能。'),
      findsOneWidget,
    );
  });

  testWidgets('panel edge resize grips exclude the docked side', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(536, 656));
    final window = _NativeRecordingWindowController();
    addTearDown(window.dispose);
    await tester.pumpWidget(
      JianheApp(
        windowController: window,
        savedBallDockEdge: 'right',
        savedBallOffset: '200',
      ),
    );
    await tester.pumpAndSettle();

    window.selectAction(BallWindowEventType.prompts);
    await tester.pumpAndSettle();

    // Right-docked: the left/top/bottom edges and the two opposite corners
    // resize; the docked side (right) and its corners never show a grip.
    for (final edge in const [
      'left',
      'top',
      'bottom',
      'topLeft',
      'bottomLeft',
    ]) {
      expect(find.byKey(Key('panel-resize-$edge')), findsOneWidget);
    }
    for (final edge in const ['right', 'topRight', 'bottomRight']) {
      expect(find.byKey(Key('panel-resize-$edge')), findsNothing);
    }

    // Pressing the left grip hands the edge over to the native layer.
    final grip = find.byKey(const Key('panel-resize-left'));
    expect(grip, findsOneWidget);
    final gesture = await tester.startGesture(
      tester.getCenter(grip),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(window.resizeEdges, contains(PanelResizeEdge.left));

    // Corner grips must keep their two-axis identity all the way to the
    // native layer; this is the right-docked panel's diagonal resize handle.
    final bottomLeftGrip = find.byKey(const Key('panel-resize-bottomLeft'));
    final bottomGrip = find.byKey(const Key('panel-resize-bottom'));
    final cornerRect = tester.getRect(bottomLeftGrip);
    expect(cornerRect.left, tester.getRect(grip).left);
    expect(cornerRect.bottom, tester.getRect(bottomGrip).bottom);
    final cornerGesture = await tester.startGesture(
      cornerRect.bottomLeft + const Offset(10, -10),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await cornerGesture.up();
    await tester.pump();
    expect(window.resizeEdges, contains(PanelResizeEdge.bottomLeft));
    expect(
      tester.getSize(find.byKey(const Key('native-resize-backing'))),
      const Size(536, 656),
    );
  });

  testWidgets('resized events drive the panel layout and re-open size', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(900, 800));
    final window = _NativeRecordingWindowController();
    addTearDown(window.dispose);
    final persisted = <(String, Size)>[];
    await tester.pumpWidget(
      JianheApp(
        windowController: window,
        onPanelResized: (stage, size) => persisted.add((stage, size)),
      ),
    );
    await tester.pumpAndSettle();

    window.selectAction(BallWindowEventType.prompts);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('ball-logical-surface'))),
      Size(BallWindowStage.browser.width, BallWindowStage.browser.height),
    );

    window.resizePanelTo(const Size(600, 500));
    await tester.pump(); // deliver the stream event (microtask)
    await tester.pump(); // rebuild with the resized panel
    expect(window.frameReadySizes, contains(const Size(600, 500)));
    expect(
      tester.getSize(find.byKey(const Key('ball-logical-surface'))),
      const Size(600, 500),
    );
    // The persistence write is debounced until the drag pauses.
    expect(persisted, isEmpty);
    await tester.pump(const Duration(milliseconds: 450));
    expect(persisted, [(('browser', const Size(600, 500)))]);

    // Collapse, then reopen the same view: the saved size is sent back.
    window.tapBall();
    await tester.pumpAndSettle();
    expect(window.stages.last, BallWindowStage.collapsed);

    window.selectAction(BallWindowEventType.prompts);
    await tester.pumpAndSettle();
    expect(window.stageSizes.last, (
      BallWindowStage.browser,
      const Size(600, 500),
    ));
    expect(
      tester.getSize(find.byKey(const Key('ball-logical-surface'))),
      const Size(600, 500),
    );
  });

  testWidgets('restores persisted panel sizes on startup', (tester) async {
    useDesktopSurface(tester, physicalSize: const Size(900, 800));
    final window = _NativeRecordingWindowController();
    addTearDown(window.dispose);
    await tester.pumpWidget(
      JianheApp(
        windowController: window,
        initialPanelSizes: const {'browser': Size(610, 480)},
      ),
    );
    await tester.pumpAndSettle();

    window.selectAction(BallWindowEventType.prompts);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('ball-logical-surface'))),
      const Size(610, 480),
    );
  });

  testWidgets('upgrades the former default browser panel size', (tester) async {
    useDesktopSurface(tester, physicalSize: const Size(900, 800));
    final window = _NativeRecordingWindowController();
    addTearDown(window.dispose);
    await tester.pumpWidget(
      JianheApp(
        windowController: window,
        initialPanelSizes: const {'browser': Size(440, 570)},
      ),
    );
    await tester.pumpAndSettle();

    window.selectAction(BallWindowEventType.skills);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('ball-logical-surface'))),
      const Size(500, 650),
    );
  });

  testWidgets('flushes an unsaved editor draft when the window closes', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(520, 1000));
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    final window = _NativeRecordingWindowController();
    addTearDown(window.dispose);
    await tester.pumpWidget(
      JianheApp(
        repository: storage.items,
        skillPackages: storage.skills,
        windowController: window,
      ),
    );
    await tester.pumpAndSettle();

    window.selectAction(BallWindowEventType.create);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('editor-title')), '关窗前草稿');
    await tester.enterText(
      find.byKey(const Key('editor-content')),
      '关窗前正在编辑、还没点保存的内容。',
    );

    // The user closes the host window (X button) instead of pressing 保存.
    window.requestClose();
    await tester.pumpAndSettle();

    final rows = await storage.items.listAll();
    final draft = rows.where((item) => item.title == '关窗前草稿').toList();
    expect(draft, hasLength(1));
    expect(draft.single.content, '关窗前正在编辑、还没点保存的内容。');
  });

  testWidgets('a half-filled editor draft is not flushed on close', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(520, 1000));
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    final window = _NativeRecordingWindowController();
    addTearDown(window.dispose);
    await tester.pumpWidget(
      JianheApp(
        repository: storage.items,
        skillPackages: storage.skills,
        windowController: window,
      ),
    );
    await tester.pumpAndSettle();

    window.selectAction(BallWindowEventType.create);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('editor-title')), '只有标题');
    // Content stays empty; the editor refuses to save such a draft itself,
    // so the close flush must not invent different rules.

    window.requestClose();
    await tester.pumpAndSettle();

    expect(
      (await storage.items.listAll()).where((item) => item.title == '只有标题'),
      isEmpty,
    );
    // The editor stays open: the user can still complete the draft, because
    // the window close path only bypasses saving, not the editor lifecycle.
    expect(find.byKey(const Key('editor-title')), findsOneWidget);
  });

  testWidgets('a close request outside the editor saves nothing', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(520, 1000));
    final storage = JianheStorageDatabase.inMemory();
    addTearDown(storage.close);
    final window = _NativeRecordingWindowController();
    addTearDown(window.dispose);
    await tester.pumpWidget(
      JianheApp(
        repository: storage.items,
        skillPackages: storage.skills,
        windowController: window,
      ),
    );
    await tester.pumpAndSettle();

    window.requestClose();
    await tester.pumpAndSettle();

    expect(await storage.items.listAll(), isEmpty);
  });

  testWidgets('a failed list read shows an error instead of demo items', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(500, 650));
    final repo = _FailingListRepository();
    final window = _NativeRecordingWindowController();
    addTearDown(window.dispose);
    await tester.pumpWidget(
      JianheApp(repository: repo, windowController: window),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The prompts browser must open without any fabricated demo entry.
    window.selectAction(BallWindowEventType.prompts);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('结构化总结'), findsNothing);
    expect(find.text('自然语言润色'), findsNothing);
    expect(find.text('反方审阅'), findsNothing);
    expect(find.text('本地素材暂时无法读取，请重启应用后再试。'), findsOneWidget);
    expect(repo.saved, isEmpty);

    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('demo mode without a repository still shows demo items', (
    tester,
  ) async {
    useDesktopSurface(tester, physicalSize: const Size(500, 650));
    final window = _NativeRecordingWindowController();
    addTearDown(window.dispose);
    await tester.pumpWidget(JianheApp(windowController: window));
    await tester.pumpAndSettle();

    window.selectAction(BallWindowEventType.prompts);
    await tester.pumpAndSettle();

    expect(find.text('结构化总结'), findsWidgets);
  });
}
