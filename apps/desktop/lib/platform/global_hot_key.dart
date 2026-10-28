import 'package:flutter/services.dart';

/// A Windows global hotkey that can be persisted independently of UI text.
class GlobalHotKey {
  const GlobalHotKey({
    required this.virtualKey,
    required this.keyLabel,
    this.control = false,
    this.alt = false,
    this.shift = false,
    this.win = false,
  });

  static const defaultWake = GlobalHotKey(
    virtualKey: 0x20,
    keyLabel: 'Space',
    control: true,
    shift: true,
  );

  final int virtualKey;
  final String keyLabel;
  final bool control;
  final bool alt;
  final bool shift;
  final bool win;

  bool get hasModifier => control || alt || shift || win;

  int get windowsModifiers =>
      (alt ? 0x0001 : 0) |
      (control ? 0x0002 : 0) |
      (shift ? 0x0004 : 0) |
      (win ? 0x0008 : 0);

  String get displayLabel => <String>[
    if (control) 'Ctrl',
    if (alt) 'Alt',
    if (shift) 'Shift',
    if (win) 'Win',
    keyLabel,
  ].join(' + ');

  String get storageValue => <String>[
    if (control) 'ctrl',
    if (alt) 'alt',
    if (shift) 'shift',
    if (win) 'win',
    _tokenForVirtualKey(virtualKey),
  ].join('+');

  Map<String, Object> toPlatformArguments() => <String, Object>{
    'modifiers': windowsModifiers,
    'virtualKey': virtualKey,
  };

  static GlobalHotKey? fromKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent || isModifierKey(event.logicalKey)) return null;
    final key = _keyFromLogicalKey(event.logicalKey);
    if (key == null) return null;
    final keyboard = HardwareKeyboard.instance;
    return GlobalHotKey(
      virtualKey: key.$1,
      keyLabel: key.$2,
      control: keyboard.isControlPressed,
      alt: keyboard.isAltPressed,
      shift: keyboard.isShiftPressed,
      win: keyboard.isMetaPressed,
    );
  }

  static bool isModifierKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.controlLeft ||
      key == LogicalKeyboardKey.controlRight ||
      key == LogicalKeyboardKey.altLeft ||
      key == LogicalKeyboardKey.altRight ||
      key == LogicalKeyboardKey.shiftLeft ||
      key == LogicalKeyboardKey.shiftRight ||
      key == LogicalKeyboardKey.metaLeft ||
      key == LogicalKeyboardKey.metaRight;

  static GlobalHotKey parseOrDefault(String? value) {
    if (value == null || value.trim().isEmpty) return defaultWake;
    final tokens = value.toLowerCase().split('+');
    if (tokens.isEmpty) return defaultWake;
    final virtualKey = _virtualKeyForToken(tokens.last);
    if (virtualKey == null) return defaultWake;
    final hotKey = GlobalHotKey(
      virtualKey: virtualKey,
      keyLabel: _labelForVirtualKey(virtualKey),
      control: tokens.contains('ctrl'),
      alt: tokens.contains('alt'),
      shift: tokens.contains('shift'),
      win: tokens.contains('win'),
    );
    return hotKey.hasModifier ? hotKey : defaultWake;
  }

  static (int, String)? _keyFromLogicalKey(LogicalKeyboardKey key) {
    final label = key.keyLabel;
    if (label.length == 1) {
      final code = label.toUpperCase().codeUnitAt(0);
      if ((code >= 0x41 && code <= 0x5A) || (code >= 0x30 && code <= 0x39)) {
        return (code, label.toUpperCase());
      }
    }

    for (var index = 0; index < _functionKeys.length; index++) {
      if (key == _functionKeys[index]) return (0x70 + index, 'F${index + 1}');
    }

    final special = _specialLogicalKeys[key];
    return special == null ? null : (special.$1, special.$2);
  }

  static String _tokenForVirtualKey(int virtualKey) {
    if (virtualKey >= 0x41 && virtualKey <= 0x5A) {
      return String.fromCharCode(virtualKey).toLowerCase();
    }
    if (virtualKey >= 0x30 && virtualKey <= 0x39) {
      return String.fromCharCode(virtualKey);
    }
    if (virtualKey >= 0x70 && virtualKey <= 0x87) {
      return 'f${virtualKey - 0x6F}';
    }
    return _specialVirtualKeys.entries
        .firstWhere((entry) => entry.value.$1 == virtualKey)
        .key;
  }

  static int? _virtualKeyForToken(String token) {
    if (token.length == 1) {
      final code = token.toUpperCase().codeUnitAt(0);
      if ((code >= 0x41 && code <= 0x5A) || (code >= 0x30 && code <= 0x39)) {
        return code;
      }
    }
    if (token.startsWith('f')) {
      final number = int.tryParse(token.substring(1));
      if (number != null && number >= 1 && number <= 24) {
        return 0x6F + number;
      }
    }
    return _specialVirtualKeys[token]?.$1;
  }

  static String _labelForVirtualKey(int virtualKey) {
    if ((virtualKey >= 0x41 && virtualKey <= 0x5A) ||
        (virtualKey >= 0x30 && virtualKey <= 0x39)) {
      return String.fromCharCode(virtualKey);
    }
    if (virtualKey >= 0x70 && virtualKey <= 0x87) {
      return 'F${virtualKey - 0x6F}';
    }
    return _specialVirtualKeys.values
        .firstWhere((value) => value.$1 == virtualKey)
        .$2;
  }

  static const _functionKeys = <LogicalKeyboardKey>[
    LogicalKeyboardKey.f1,
    LogicalKeyboardKey.f2,
    LogicalKeyboardKey.f3,
    LogicalKeyboardKey.f4,
    LogicalKeyboardKey.f5,
    LogicalKeyboardKey.f6,
    LogicalKeyboardKey.f7,
    LogicalKeyboardKey.f8,
    LogicalKeyboardKey.f9,
    LogicalKeyboardKey.f10,
    LogicalKeyboardKey.f11,
    LogicalKeyboardKey.f12,
    LogicalKeyboardKey.f13,
    LogicalKeyboardKey.f14,
    LogicalKeyboardKey.f15,
    LogicalKeyboardKey.f16,
    LogicalKeyboardKey.f17,
    LogicalKeyboardKey.f18,
    LogicalKeyboardKey.f19,
    LogicalKeyboardKey.f20,
    LogicalKeyboardKey.f21,
    LogicalKeyboardKey.f22,
    LogicalKeyboardKey.f23,
    LogicalKeyboardKey.f24,
  ];

  static final _specialLogicalKeys = <LogicalKeyboardKey, (int, String)>{
    LogicalKeyboardKey.space: (0x20, 'Space'),
    LogicalKeyboardKey.enter: (0x0D, 'Enter'),
    LogicalKeyboardKey.tab: (0x09, 'Tab'),
    LogicalKeyboardKey.escape: (0x1B, 'Esc'),
    LogicalKeyboardKey.backspace: (0x08, 'Backspace'),
    LogicalKeyboardKey.delete: (0x2E, 'Delete'),
    LogicalKeyboardKey.insert: (0x2D, 'Insert'),
    LogicalKeyboardKey.home: (0x24, 'Home'),
    LogicalKeyboardKey.end: (0x23, 'End'),
    LogicalKeyboardKey.pageUp: (0x21, 'Page Up'),
    LogicalKeyboardKey.pageDown: (0x22, 'Page Down'),
    LogicalKeyboardKey.arrowLeft: (0x25, '←'),
    LogicalKeyboardKey.arrowUp: (0x26, '↑'),
    LogicalKeyboardKey.arrowRight: (0x27, '→'),
    LogicalKeyboardKey.arrowDown: (0x28, '↓'),
  };

  static const _specialVirtualKeys = <String, (int, String)>{
    'space': (0x20, 'Space'),
    'enter': (0x0D, 'Enter'),
    'tab': (0x09, 'Tab'),
    'esc': (0x1B, 'Esc'),
    'backspace': (0x08, 'Backspace'),
    'delete': (0x2E, 'Delete'),
    'insert': (0x2D, 'Insert'),
    'home': (0x24, 'Home'),
    'end': (0x23, 'End'),
    'pageup': (0x21, 'Page Up'),
    'pagedown': (0x22, 'Page Down'),
    'left': (0x25, '←'),
    'up': (0x26, '↑'),
    'right': (0x27, '→'),
    'down': (0x28, '↓'),
  };
}
