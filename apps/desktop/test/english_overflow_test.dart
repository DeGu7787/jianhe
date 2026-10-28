import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_core/jianhe_core.dart';
import 'package:jianhe_desktop/app.dart';
import 'package:jianhe_desktop/l10n/app_strings.dart';
import 'package:jianhe_desktop/platform/ball_window_controller.dart';

import 'english_test_support.dart';

/// English text is wider than Chinese. The test font draws every Latin
/// letter one em wide, so overflow is only meaningful with the real Windows
/// UI font; the sweep runs on Windows and is skipped elsewhere.
final _segoe = File('C:/Windows/Fonts/segoeui.ttf');

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  var added = false;
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final bytes = file.readAsBytesSync();
    loader.addFont(
      Future<ByteData>.value(
        ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length),
      ),
    );
    added = true;
  }
  if (added) await loader.load();
}

void main() {
  testWidgets(
    'English panels fit the native panel sizes without overflow',
    (tester) async {
      // The default text family in tests is Roboto; serve it from Segoe UI,
      // the font Windows actually renders the app with.
      await _loadFont('Roboto', <String>[
        'C:/Windows/Fonts/segoeui.ttf',
        'C:/Windows/Fonts/segoeuib.ttf',
        'C:/Windows/Fonts/seguisb.ttf',
      ]);
      await _loadFont('Microsoft YaHei UI', <String>[
        'C:/Windows/Fonts/msyh.ttc',
      ]);

      // In native-ball mode every panel lays out at its native stage size,
      // so the test surface only needs to be large enough to hold it.
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

      await tester.pumpWidget(
        JianheApp(
          initialLanguage: AppLanguage.en,
          onLanguageChanged: (_) {},
          windowController: window,
        ),
      );
      await tester.pumpAndSettle();

      Future<void> open(BallWindowEventType action) async {
        window.selectAction(action);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: action.name);
      }

      await open(BallWindowEventType.compose);
      await open(BallWindowEventType.prompts);
      await open(BallWindowEventType.skills);
      await open(BallWindowEventType.snippets);
      await open(BallWindowEventType.create);

      // Category management and the skill creation dialog.
      await open(BallWindowEventType.prompts);
      await tester.tap(find.byKey(const Key('manage-categories')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'manage categories');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      await open(BallWindowEventType.skills);
      await tester.tap(find.byKey(const Key('create-or-import-skill')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'skill create dialog');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // The AI & Skill setup guide is long prose; scroll through all of it.
      await open(BallWindowEventType.more);
      await tester.tap(find.text('AI & Skill setup guide'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('6 skill package or output validation failed'),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('cli-help-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'setup guide');

      await open(BallWindowEventType.more);
      await scrollMorePanelTo(tester, find.text('Quit JianHe'));
      expect(tester.takeException(), isNull, reason: 'More panel');
    },
    skip: !_segoe.existsSync(),
  );
}
