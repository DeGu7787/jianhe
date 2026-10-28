import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/platform/global_hot_key.dart';

void main() {
  test('round-trips a persisted global hotkey', () {
    final hotKey = GlobalHotKey.parseOrDefault('ctrl+alt+f12');

    expect(hotKey.displayLabel, 'Ctrl + Alt + F12');
    expect(hotKey.storageValue, 'ctrl+alt+f12');
    expect(hotKey.windowsModifiers, 0x0003);
    expect(hotKey.virtualKey, 0x7B);
  });

  test('falls back to the default for invalid persisted values', () {
    final hotKey = GlobalHotKey.parseOrDefault('space');

    expect(hotKey.storageValue, GlobalHotKey.defaultWake.storageValue);
  });
}
