import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/features/account/account_api.dart';
import 'package:jianhe_desktop/features/account/external_browser_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('jianhe/window');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Google authorization uses the Windows default browser', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return true;
        });
    final uri = Uri.parse('https://accounts.google.com/o/oauth2/v2/auth?state=abc');

    await openExternalBrowser(uri);

    expect(received?.method, 'openExternalUrl');
    expect(received?.arguments, uri.toString());
  });

  test('reports when Windows cannot open the default browser', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => false);

    await expectLater(
      openExternalBrowser(Uri.parse('https://accounts.google.com/')),
      throwsA(
        isA<AccountApiException>().having(
          (error) => error.code,
          'code',
          'BROWSER_UNAVAILABLE',
        ),
      ),
    );
  });
}
