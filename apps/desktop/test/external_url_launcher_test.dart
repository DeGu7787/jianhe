import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/platform/external_url_launcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('jianhe/window');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('opens only an HTTPS portal URL through the native host', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return true;
        });

    final launcher = const ExternalUrlLauncher();
    expect(
      await launcher.open('https://jianhe.neodaas.com/jianhecloud/'),
      isTrue,
    );
    expect(received?.method, 'openExternalUrl');
    expect(received?.arguments, 'https://jianhe.neodaas.com/jianhecloud/');
    expect(await launcher.open('http://example.com'), isFalse);
  });
}
