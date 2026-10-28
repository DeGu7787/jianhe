import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/global_error_file_sink.dart';
import 'package:jianhe_desktop/global_error_handlers.dart';

void main() {
  // Installs the handlers with a capturing sink and restores every global
  // the installer overwrites, so other tests keep their original nets.
  void installWithCapture(List<String> captured) {
    final originalFlutterOnError = FlutterError.onError;
    final originalPlatformOnError = PlatformDispatcher.instance.onError;
    final originalErrorWidget = ErrorWidget.builder;
    addTearDown(() {
      FlutterError.onError = originalFlutterOnError;
      PlatformDispatcher.instance.onError = originalPlatformOnError;
      ErrorWidget.builder = originalErrorWidget;
    });
    installGlobalErrorHandlers(log: captured.add);
  }

  testWidgets('the error widget placeholder renders a friendly message', (
    tester,
  ) async {
    final captured = <String>[];
    installWithCapture(captured);

    // Pumped bare, above MaterialApp: proves the placeholder brings its own
    // Directionality and styles instead of throwing a second error.
    await tester.pumpWidget(
      ErrorWidget.builder(
        FlutterErrorDetails(exception: StateError('render boom')),
      ),
    );
    await tester.pump();

    expect(find.text('界面出现异常'), findsOneWidget);
    expect(find.text('已记录该问题，内容不受影响，可重启笺盒继续使用。'), findsOneWidget);
  });

  test('framework errors are logged through the installed sink', () {
    final captured = <String>[];
    installWithCapture(captured);

    FlutterError.onError!(
      FlutterErrorDetails(exception: StateError('boom-framework')),
    );

    expect(captured, hasLength(1));
    expect(captured.single, contains('framework'));
    expect(captured.single, contains('boom-framework'));
  });

  test('layout diagnostics from informationCollector land in the log', () {
    final captured = <String>[];
    installWithCapture(captured);

    // RenderFlex 溢出的组件创建链只挂在 informationCollector 上。
    FlutterError.onError!(
      FlutterErrorDetails(
        exception: 'A RenderFlex overflowed by 125 pixels on the bottom.',
        informationCollector: () => <DiagnosticsNode>[
          ErrorDescription('creator: Column ← _buildAccount ← BallHomePage'),
          ErrorHint('overflowed by 125px'),
        ],
      ),
    );

    expect(captured, hasLength(1));
    expect(captured.single, contains('A RenderFlex overflowed by 125 pixels'));
    expect(captured.single, contains('creator: Column ← _buildAccount'));
    expect(captured.single, contains('overflowed by 125px'));
  });

  test('uncaught async errors are logged and reported as handled', () {
    final captured = <String>[];
    installWithCapture(captured);

    final handled = PlatformDispatcher.instance.onError!(
      StateError('boom-async'),
      StackTrace.current,
    );

    expect(handled, isTrue);
    expect(captured, hasLength(1));
    expect(captured.single, contains('async'));
    expect(captured.single, contains('boom-async'));
  });

  test('file sink appends, creates missing directories, and caps the file', () async {
    final temp = await Directory.systemTemp.createTemp('jianhe-error-test');
    addTearDown(() => temp.delete(recursive: true));
    final nested = '${temp.path}/nested';
    final log = File('$nested/error.log');

    final sink = fileErrorSink(nested);
    sink('first entry\n');
    sink('second entry\n');

    var content = log.readAsStringSync();
    expect(content, contains('first entry'));
    expect(content, contains('second entry'));

    log.writeAsStringSync('x' * (512 * 1024 + 1));
    sink('fresh start\n');

    content = log.readAsStringSync();
    expect(content.length, lessThan(512 * 1024));
    expect(content, contains('fresh start'));
    expect(content, isNot(contains('first entry')));
  });
}
