import 'dart:async';

import 'package:flutter/services.dart';

import 'global_hot_key.dart';

/// Dock sides supported by the native window layer.
enum BallDockSide { left, right, top, bottom }

enum BallWindowEventType {
  hotkey,
  hotkeyUnavailable,
  tap,
  secondaryTap,
  dragStart,
  enter,
  exit,
  moved,
  compose,
  prompts,
  skills,
  snippets,
  create,
  more,
  backgroundSync,

  /// The native layer resized the host while a panel stage was visible.
  /// Carries the new host size in logical pixels via [BallWindowEvent.size].
  resized,

  /// The native layer entered a modal move/resize loop (ball drag or panel
  /// edge resize). Dart uses it to suspend the auto-collapse timer.
  resizeStart,

  /// The native layer left the modal move/resize loop.
  resizeEnd,
}

/// Edge/corner a panel resize grip maps to. Sent to the native layer which
/// translates it into the matching Win32 hit-test code (HTLEFT, HTTOPRIGHT...).
enum PanelResizeEdge {
  left,
  right,
  top,
  bottom,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

class BallWindowEvent {
  const BallWindowEvent(this.type, {this.side, this.offset, this.size});

  final BallWindowEventType type;

  /// Dock side the ball moved to (only for [BallWindowEventType.moved]).
  final BallDockSide? side;

  /// Position of the ball center along the docked edge, in logical pixels.
  final double? offset;

  /// New host size in logical pixels (only for [BallWindowEventType.resized]).
  final Size? size;
}

enum BallWindowStage {
  collapsed(88, 88),
  menu(390, 360),
  composer(520, 640),
  browser(500, 650),
  editor(470, 610),
  settings(450, 540);

  const BallWindowStage(this.width, this.height);

  final double width;
  final double height;
}

/// Current geometry of the floating ball as reported by the native layer.
class BallLayout {
  const BallLayout({
    required this.side,
    required this.ballCenter,
    required this.offset,
  });

  final BallDockSide side;

  /// Ball center relative to the Flutter host window, in logical pixels.
  final Offset ballCenter;

  /// Ball center position along the docked edge, in logical pixels.
  final double offset;
}

abstract interface class BallWindowController {
  bool get usesNativeBall;

  Stream<BallWindowEvent> get events;

  Future<BallDockSide> showStage(BallWindowStage stage, {Size? size});

  /// Starts a native modal resize loop for the given panel edge/corner. The
  /// native layer enters the system size loop; [resizeStart] / [resizeEnd]
  /// events bracket it and [resized] events report the live panel size.
  Future<void> beginPanelResize(PanelResizeEdge edge);

  /// Confirms that Flutter has completed a frame for a native resize size.
  /// The Windows layer waits for this before exposing newly added D3D pixels.
  Future<void> panelFrameReady(Size size);

  Future<BallDockSide> startDrag();

  /// Queries the ball geometry from the native layer (used only when
  /// [usesNativeBall] is true so the Flutter arc menu can anchor to the real
  /// ball position). Returns null when the native layer cannot answer.
  Future<BallLayout?> getBallLayout();

  /// Tells the native ball to render its expanded (active) state.
  Future<void> setExpanded(bool expanded);

  /// Shows or hides the red dot on the 更多 action of the native orbit menu
  /// (a new version is waiting for the user).
  Future<void> setMoreBadge(bool visible);

  /// Restores the native ball to a previously saved docked position on startup.
  Future<void> restorePosition(BallDockSide side, double offset);

  /// Replaces the active Windows wake hotkey. Returns false when Windows
  /// rejects the new binding; the native layer keeps the previous one active.
  Future<bool> setWakeHotKey(GlobalHotKey hotKey);

  /// Registers the handler the native layer invokes when the host window is
  /// asked to close (X button, Alt+F4, or quit). The handler flushes
  /// in-memory state (e.g. an unsaved editor draft); once it completes, the
  /// controller confirms the close back to the native layer, which then
  /// destroys the window. Pass null to unregister. The native layer runs a
  /// watchdog, so a handler that never completes only delays the close.
  void setCloseRequestHandler(Future<void> Function()? handler);

  Future<void> quit();
}

class NativeBallWindowController implements BallWindowController {
  NativeBallWindowController() {
    _events = StreamController<BallWindowEvent>.broadcast(
      onListen: _announceBackgroundSyncReady,
    );
    _channel.setMethodCallHandler(_handleNativeMethod);
  }

  static const _channel = MethodChannel('jianhe/window');
  late final StreamController<BallWindowEvent> _events;
  Future<void> Function()? _closeRequestHandler;
  bool _backgroundSyncReadyAnnounced = false;

  @override
  bool get usesNativeBall => true;

  @override
  Stream<BallWindowEvent> get events => _events.stream;

  void _announceBackgroundSyncReady() {
    if (_backgroundSyncReadyAnnounced) return;
    _backgroundSyncReadyAnnounced = true;
    unawaited(_sendBackgroundSyncReady());
  }

  Future<void> _sendBackgroundSyncReady() async {
    try {
      await _channel.invokeMethod<void>('backgroundSyncReady');
    } on PlatformException {
      // The foreground window remains usable even if a non-Windows host does
      // not implement scheduled background synchronization.
    } on MissingPluginException {
      // See above; this controller is also used by widget tests.
    }
  }

  @override
  void setCloseRequestHandler(Future<void> Function()? handler) {
    _closeRequestHandler = handler;
  }

  Future<void> _handleNativeMethod(MethodCall call) async {
    if (call.method == 'panelResized') {
      final arguments = call.arguments;
      if (arguments is Map) {
        final width = (arguments['width'] as num?)?.toDouble();
        final height = (arguments['height'] as num?)?.toDouble();
        if (width != null && height != null && width > 0 && height > 0) {
          _events.add(
            BallWindowEvent(
              BallWindowEventType.resized,
              size: Size(width, height),
            ),
          );
        }
      }
      return;
    }
    if (call.method == 'closeRequested') {
      final handler = _closeRequestHandler;
      if (handler != null) {
        try {
          await handler();
        } on Object {
          // A failing flush must never keep the window from closing.
        }
      }
      try {
        await _channel.invokeMethod<void>('confirmClose');
      } on PlatformException {
        // The native layer destroys the window anyway when this reply is
        // lost; its watchdog bounds how long a missing answer can delay it.
      }
      return;
    }
    if (call.method == 'backgroundSyncRequested') {
      _events.add(const BallWindowEvent(BallWindowEventType.backgroundSync));
      return;
    }
    if (call.method != 'ballEvent') return;
    final event = call.arguments as String?;
    if (event == null) return;
    switch (event) {
      case 'hotkey':
        _events.add(const BallWindowEvent(BallWindowEventType.hotkey));
      case 'hotkeyUnavailable':
        _events.add(
          const BallWindowEvent(BallWindowEventType.hotkeyUnavailable),
        );
      case 'tap':
        _events.add(const BallWindowEvent(BallWindowEventType.tap));
      case 'secondaryTap':
        _events.add(const BallWindowEvent(BallWindowEventType.secondaryTap));
      case 'dragStart':
        _events.add(const BallWindowEvent(BallWindowEventType.dragStart));
      case 'enter':
        _events.add(const BallWindowEvent(BallWindowEventType.enter));
      case 'exit':
        _events.add(const BallWindowEvent(BallWindowEventType.exit));
      case 'resizeStart':
        _events.add(const BallWindowEvent(BallWindowEventType.resizeStart));
      case 'resizeEnd':
        _events.add(const BallWindowEvent(BallWindowEventType.resizeEnd));
      default:
        if (event.startsWith('moved:')) {
          final parts = event.split(':');
          final side = switch (parts.length > 1 ? parts[1] : '') {
            'left' => BallDockSide.left,
            'right' => BallDockSide.right,
            'top' => BallDockSide.top,
            'bottom' => BallDockSide.bottom,
            _ => null,
          };
          if (side == null) return;
          final offset = parts.length > 2 ? double.tryParse(parts[2]) : null;
          _events.add(
            BallWindowEvent(
              BallWindowEventType.moved,
              side: side,
              offset: offset,
            ),
          );
          return;
        }
        if (event == 'compose') {
          _events.add(const BallWindowEvent(BallWindowEventType.compose));
        } else if (event == 'prompts') {
          _events.add(const BallWindowEvent(BallWindowEventType.prompts));
        } else if (event == 'skills') {
          _events.add(const BallWindowEvent(BallWindowEventType.skills));
        } else if (event == 'snippets') {
          _events.add(const BallWindowEvent(BallWindowEventType.snippets));
        } else if (event == 'create') {
          _events.add(const BallWindowEvent(BallWindowEventType.create));
        } else if (event == 'more') {
          _events.add(const BallWindowEvent(BallWindowEventType.more));
        }
    }
  }

  @override
  Future<BallDockSide> showStage(BallWindowStage stage, {Size? size}) async {
    final side = await _channel
        .invokeMethod<String>('setSize', <String, Object?>{
          'width': size?.width ?? stage.width,
          'height': size?.height ?? stage.height,
          'edge': _lastKnownSide.name,
          'stage': stage.name,
        });
    final parsed = _sideFromString(side);
    _lastKnownSide = parsed;
    return parsed;
  }

  @override
  Future<void> beginPanelResize(PanelResizeEdge edge) async {
    try {
      await _channel.invokeMethod<void>('beginPanelResize', <String, Object?>{
        'edge': edge.name,
      });
    } on PlatformException {
      // Ignored: the native layer is optional in widget tests.
    }
  }

  @override
  Future<void> panelFrameReady(Size size) async {
    try {
      await _channel.invokeMethod<void>('panelFrameReady', <String, Object?>{
        'width': size.width,
        'height': size.height,
      });
    } on PlatformException {
      // Ignored: the native layer is optional in widget tests.
    }
  }

  @override
  Future<BallDockSide> startDrag() async {
    final side = await _channel.invokeMethod<String>('startDrag');
    return _sideFromString(side);
  }

  @override
  Future<BallLayout?> getBallLayout() async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getBallLayout',
      );
      if (result == null) return null;
      final side = _sideFromString(result['edge'] as String?);
      final x = (result['ballX'] as num?)?.toDouble();
      final y = (result['ballY'] as num?)?.toDouble();
      final offset = (result['offset'] as num?)?.toDouble();
      if (x == null || y == null || offset == null) return null;
      _lastKnownSide = side;
      return BallLayout(side: side, ballCenter: Offset(x, y), offset: offset);
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> setExpanded(bool expanded) async {
    try {
      await _channel.invokeMethod<void>('setExpanded', <String, Object?>{
        'expanded': expanded,
      });
    } on PlatformException {
      // Ignored: the native layer is optional in widget tests.
    }
  }

  @override
  Future<void> setMoreBadge(bool visible) async {
    try {
      await _channel.invokeMethod<void>('setMoreBadge', visible);
    } on PlatformException {
      // Ignored: the native layer is optional in widget tests.
    } on MissingPluginException {
      // Ignored: hosts without the native orbit have no badge to draw.
    }
  }

  @override
  Future<void> restorePosition(BallDockSide side, double offset) async {
    try {
      await _channel.invokeMethod<void>('setInitialPosition', <String, Object?>{
        'edge': side.name,
        'offset': offset,
      });
    } on PlatformException {
      // Ignored: the native layer is optional in widget tests.
    }
  }

  @override
  Future<bool> setWakeHotKey(GlobalHotKey hotKey) async {
    try {
      return await _channel.invokeMethod<bool>(
            'setWakeHotKey',
            hotKey.toPlatformArguments(),
          ) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> quit() => _channel.invokeMethod<void>('quit');

  static BallDockSide _sideFromString(String? value) => switch (value) {
    'left' => BallDockSide.left,
    'right' => BallDockSide.right,
    'top' => BallDockSide.top,
    'bottom' => BallDockSide.bottom,
    _ => BallDockSide.right,
  };

  BallDockSide _lastKnownSide = BallDockSide.right;
}

class NoopBallWindowController implements BallWindowController {
  const NoopBallWindowController({this.side = BallDockSide.right});

  final BallDockSide side;

  @override
  bool get usesNativeBall => false;

  @override
  Stream<BallWindowEvent> get events => const Stream<BallWindowEvent>.empty();

  @override
  Future<BallDockSide> showStage(BallWindowStage stage, {Size? size}) async =>
      side;

  @override
  Future<void> beginPanelResize(PanelResizeEdge edge) async {}

  @override
  Future<void> panelFrameReady(Size size) async {}

  @override
  Future<BallDockSide> startDrag() async => side;

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
