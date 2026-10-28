import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/platform/ball_window_controller.dart';
import 'package:jianhe_desktop/platform/global_hot_key.dart';

/// Native-ball window controller for tests: panels open through orbit
/// events (no pixel taps) and lay out at the real native panel size.
class NativeTestWindowController implements BallWindowController {
  final _events = StreamController<BallWindowEvent>.broadcast();

  @override
  bool get usesNativeBall => true;

  @override
  Stream<BallWindowEvent> get events => _events.stream;

  void selectAction(BallWindowEventType type) {
    _events.add(BallWindowEvent(type));
  }

  void dispose() {
    _events.close();
  }

  @override
  Future<BallDockSide> showStage(BallWindowStage stage, {Size? size}) async =>
      BallDockSide.right;

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

/// Scrolls the More panel until [target] is on screen.
Future<void> scrollMorePanelTo(WidgetTester tester, Finder target) async {
  // The More panel is a single ListView (only the open panel is built).
  // Its rows are built lazily, so the list itself is the stable anchor.
  final list = find
      .descendant(
        of: find.byType(ListView).first,
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(target, 120, scrollable: list);
  await tester.pumpAndSettle();
}
