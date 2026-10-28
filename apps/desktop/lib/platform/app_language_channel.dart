import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:jianhe_core/jianhe_core.dart';

/// Native side of the interface language: the installer's language choice
/// and the natively painted orbit labels (windows/runner).
class AppLanguageChannel {
  const AppLanguageChannel();

  static const _channel = MethodChannel('jianhe/window');

  /// The language picked in the installer's language dialog, if a fresh
  /// choice is waiting. Reading it consumes it, so it applies only once per
  /// install; afterwards the in-app setting is the source of truth.
  Future<AppLanguage?> consumeInstallerLanguage() async {
    try {
      final raw = await _channel.invokeMethod<String>(
        'consumeInstallerLanguage',
      );
      return AppLanguage.tryParse(raw);
    } on Object catch (error) {
      // Older runners, tests and non-Windows hosts have no handler.
      debugPrint('Installer language unavailable: $error');
      return null;
    }
  }

  /// Tells the native orbit which language to draw its hover labels in.
  Future<void> setLanguage(AppLanguage language) async {
    try {
      await _channel.invokeMethod<void>('setLanguage', language.storageValue);
    } on Object catch (error) {
      debugPrint('Failed to set native language: $error');
    }
  }
}
