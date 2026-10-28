import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/platform/ball_window_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final channel = const MethodChannel('jianhe/window');
  var nativeMethods = <String>[];

  void mockNative() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          nativeMethods.add(call.method);
          return null;
        });
    addTearDown(() {
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      nativeMethods = <String>[];
    });
  }

  Future<void> deliverNativeMethod(MethodCall call) async {
    await TestWidgetsFlutterBinding
        .instance.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(call),
      (ByteData? reply) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  test('close request flushes through the handler then confirms the close',
      () async {
    mockNative();
    final controller = NativeBallWindowController();
    var flushes = 0;
    controller.setCloseRequestHandler(() async => flushes++);

    await deliverNativeMethod(const MethodCall('closeRequested'));

    expect(flushes, 1);
    expect(nativeMethods, contains('confirmClose'));
    controller.setCloseRequestHandler(null);
  });

  test('a failing flush still confirms the close', () async {
    mockNative();
    final controller = NativeBallWindowController();
    controller.setCloseRequestHandler(
      () async => throw StateError('storage write failed'),
    );

    await deliverNativeMethod(const MethodCall('closeRequested'));

    expect(nativeMethods, contains('confirmClose'));
    controller.setCloseRequestHandler(null);
  });

  test('without a handler the close is confirmed immediately', () async {
    mockNative();
    final controller = NativeBallWindowController();

    await deliverNativeMethod(const MethodCall('closeRequested'));

    expect(nativeMethods, contains('confirmClose'));
    controller.setCloseRequestHandler(null);
  });

  test('the first event listener announces background sync readiness', () async {
    mockNative();
    final controller = NativeBallWindowController();
    final events = <BallWindowEventType>[];

    final subscription = controller.events.listen((event) {
      events.add(event.type);
    });
    await Future<void>.delayed(Duration.zero);

    expect(nativeMethods.where((method) => method == 'backgroundSyncReady'), [
      'backgroundSyncReady',
    ]);
    await deliverNativeMethod(const MethodCall('backgroundSyncRequested'));
    expect(events, [BallWindowEventType.backgroundSync]);
    await subscription.cancel();
  });
}
