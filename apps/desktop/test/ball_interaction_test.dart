import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/app.dart';
import 'package:jianhe_desktop/features/ball/ball_arc_calculator.dart';
import 'package:jianhe_desktop/platform/ball_window_controller.dart';
import 'package:jianhe_desktop/platform/global_hot_key.dart';

class _RecordingWindowController implements BallWindowController {
  final stages = <BallWindowStage>[];
  final savedPositions = <(BallDockEdge, double)>[];

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

void main() {
  void useDesktopSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(520, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }

  Finder ballFinder() => find.byKey(const Key('jianhe-ball'));

  testWidgets('tap toggles the quick action menu from the floating ball', (
    tester,
  ) async {
    useDesktopSurface(tester);
    final window = _RecordingWindowController();
    await tester.pumpWidget(JianheApp(windowController: window));
    await tester.pumpAndSettle();

    await tester.tap(ballFinder());
    await tester.pumpAndSettle();
    expect(window.stages, contains(BallWindowStage.menu));
    expect(find.text('Prompt'), findsOneWidget);

    expect(find.byKey(const Key('quick-menu-action-0')), findsOneWidget);

    // Transparent desktop space is not a dismissal target. The ball remains
    // the explicit, easy-to-discover control for closing the action menu.
    await tester.tap(ballFinder());
    await tester.pumpAndSettle();
    expect(find.text('Prompt'), findsNothing);
  });

  testWidgets('a drag snaps to the nearest edge without opening the menu', (
    tester,
  ) async {
    useDesktopSurface(tester);
    final window = _RecordingWindowController();
    await tester.pumpWidget(JianheApp(windowController: window));
    await tester.pumpAndSettle();

    // Ball starts docked right at (484, 320). Drag it far left.
    await tester.drag(ballFinder(), const Offset(-400, 0));
    await tester.pumpAndSettle();

    // Menu must not open from a drag.
    expect(window.stages, isNot(contains(BallWindowStage.menu)));
    expect(find.text('Prompt'), findsNothing);

    // Ball is now flush to the left edge (center x == ballRadius).
    final center = tester.getCenter(ballFinder());
    expect(center.dx, closeTo(36, 1));
    expect(center.dy, closeTo(320, 1));
  });

  testWidgets('dragging toward the top edge snaps to the top edge', (
    tester,
  ) async {
    useDesktopSurface(tester);
    final window = _RecordingWindowController();
    await tester.pumpWidget(JianheApp(windowController: window));
    await tester.pumpAndSettle();

    await tester.drag(ballFinder(), const Offset(0, -600));
    await tester.pumpAndSettle();

    final center = tester.getCenter(ballFinder());
    expect(center.dy, closeTo(36, 1));
  });

  testWidgets('drag-and-snap persists edge and offset', (tester) async {
    useDesktopSurface(tester);
    final saved = <(BallDockEdge, double)>[];
    await tester.pumpWidget(
      JianheApp(
        onBallPositionChanged: (edge, offset) => saved.add((edge, offset)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(ballFinder(), const Offset(0, -600));
    await tester.pumpAndSettle();

    expect(saved, isNotEmpty);
    final (edge, offset) = saved.last;
    expect(edge, BallDockEdge.top);
    expect(offset, closeTo(484, 1));
  });

  testWidgets('restores a saved dock edge and offset on startup', (
    tester,
  ) async {
    useDesktopSurface(tester);
    await tester.pumpWidget(
      const JianheApp(savedBallDockEdge: 'top', savedBallOffset: '200.0'),
    );
    await tester.pumpAndSettle();

    final center = tester.getCenter(ballFinder());
    expect(center.dx, closeTo(200, 1));
    expect(center.dy, closeTo(36, 1));
  });
}
