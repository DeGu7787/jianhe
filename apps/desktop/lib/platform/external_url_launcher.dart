import 'package:flutter/services.dart';

class ExternalUrlLauncher {
  const ExternalUrlLauncher();

  static const _channel = MethodChannel('jianhe/window');

  Future<bool> open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('openExternalUrl', url) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
