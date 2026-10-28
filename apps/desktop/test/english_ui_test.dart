import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_core/jianhe_core.dart';
import 'package:jianhe_desktop/app.dart';
import 'package:jianhe_desktop/l10n/app_strings.dart';
import 'package:jianhe_desktop/platform/ball_window_controller.dart';

import 'english_test_support.dart';

void main() {
  NativeTestWindowController useDesktopSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(640, 720);
    tester.view.devicePixelRatio = 1;
    final window = NativeTestWindowController();
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => AppStrings.setCurrentLanguage(AppLanguage.zh));
    addTearDown(window.dispose);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
    return window;
  }

  testWidgets('composes in English with the English separator', (
    tester,
  ) async {
    final window = useDesktopSurface(tester);
    await tester.pumpWidget(
      JianheApp(initialLanguage: AppLanguage.en, windowController: window),
    );
    await tester.pumpAndSettle();
    window.selectAction(BallWindowEventType.compose);
    await tester.pumpAndSettle();

    expect(find.text('Choose a prompt'), findsOneWidget);
    expect(find.text('Text to process'), findsOneWidget);

    // An English demo prompt without {{input}}, so JianHe adds its separator.
    final chip = find.ancestor(
      of: find.text('Natural polish'),
      matching: find.byType(ChoiceChip),
    );
    tester.widget<ChoiceChip>(chip).onSelected!(true);
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('ball-composer-input')),
      'Body',
    );
    await tester.pump();

    final result = tester.widget<SelectableText>(
      find.byKey(const Key('ball-composer-result')),
    );
    expect(
      result.data,
      startsWith('Polish the text below.'),
      reason: 'the selected prompt is used',
    );
    expect(result.data, endsWith('\n\n---\nInput:\nBody'));
  });

  testWidgets('shows the More panel in English', (tester) async {
    final window = useDesktopSurface(tester);
    await tester.pumpWidget(
      JianheApp(initialLanguage: AppLanguage.en, windowController: window),
    );
    await tester.pumpAndSettle();
    window.selectAction(BallWindowEventType.more);
    await tester.pumpAndSettle();

    expect(find.text('AI CLI access'), findsOneWidget);
    await scrollMorePanelTo(tester, find.text('Auto-collapse'));
    expect(
      tester.widget<Text>(find.byKey(const Key('auto-collapse-value'))).data,
      '4 sec',
    );
    await scrollMorePanelTo(tester, find.text('Export everything'));
    expect(find.text('导出全部内容'), findsNothing);
  });

  testWidgets('shows the AI & Skill setup guide in English', (tester) async {
    final window = useDesktopSurface(tester);
    await tester.pumpWidget(
      JianheApp(initialLanguage: AppLanguage.en, windowController: window),
    );
    await tester.pumpAndSettle();
    window.selectAction(BallWindowEventType.more);
    await tester.pumpAndSettle();
    await tester.tap(find.text('AI & Skill setup guide'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('cli-help-scroll')), findsOneWidget);
    expect(find.text('Copy request for AI'), findsOneWidget);
    expect(find.text('Export reference (.md)'), findsOneWidget);
    expect(find.textContaining('AI CLI access is off'), findsOneWidget);
    expect(find.text('复制给 AI 的请求'), findsNothing);
  });

  testWidgets('switches language from More and reports the choice', (
    tester,
  ) async {
    final window = useDesktopSurface(tester);
    final saved = <AppLanguage>[];
    await tester.pumpWidget(
      JianheApp(windowController: window, onLanguageChanged: saved.add),
    );
    await tester.pumpAndSettle();
    window.selectAction(BallWindowEventType.more);
    await tester.pumpAndSettle();
    await scrollMorePanelTo(tester, find.byKey(const Key('language-switch')));

    expect(find.text('界面语言 · Language'), findsOneWidget);
    await tester.tap(find.byKey(const Key('language-en')));
    await tester.pumpAndSettle();

    expect(saved, <AppLanguage>[AppLanguage.en]);
    expect(AppStrings.current.language, AppLanguage.en);
    await scrollMorePanelTo(tester, find.text('Language · 界面语言'));
    await scrollMorePanelTo(tester, find.text('Quit JianHe'));
    expect(find.text('Quit JianHe'), findsOneWidget);

    await scrollMorePanelTo(tester, find.byKey(const Key('language-switch')));
    await tester.tap(find.byKey(const Key('language-zh')));
    await tester.pumpAndSettle();

    expect(saved, <AppLanguage>[AppLanguage.en, AppLanguage.zh]);
    await scrollMorePanelTo(tester, find.text('退出笺盒'));
    expect(find.text('退出笺盒'), findsOneWidget);
  });

  testWidgets('hides the language switch when the choice cannot be saved', (
    tester,
  ) async {
    final window = useDesktopSurface(tester);
    await tester.pumpWidget(JianheApp(windowController: window));
    await tester.pumpAndSettle();
    window.selectAction(BallWindowEventType.more);
    await tester.pumpAndSettle();
    await scrollMorePanelTo(tester, find.text('退出笺盒'));

    expect(find.byKey(const Key('language-setting')), findsNothing);
  });
}
