import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/app.dart';
import 'package:jianhe_desktop/features/app_update/app_update_controller.dart';

import 'app_update_controller_test.dart' show FakeUpdatePlatform, manifest;

void main() {
  late FakeUpdatePlatform platform;
  late AppUpdateController controller;

  setUp(() {
    platform = FakeUpdatePlatform();
    controller = AppUpdateController(
      platform: platform,
      currentVersion: '0.1.7',
    );
  });
  tearDown(() => controller.dispose());

  Future<void> openMore(WidgetTester tester) async {
    tester.view.physicalSize = const Size(520, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(JianheApp(appUpdateController: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('jianhe-ball')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
  }

  Finder entryText(String text) => find.descendant(
    of: find.byKey(const Key('app-update-entry')),
    matching: find.textContaining(text),
  );

  testWidgets('shows the current version below the other settings', (
    tester,
  ) async {
    await openMore(tester);
    final entry = find.byKey(const Key('app-update-entry'));
    await tester.dragUntilVisible(
      entry,
      find.ancestor(of: find.text('导出全部内容'), matching: find.byType(ListView)),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(entry).dy,
      greaterThan(tester.getTopLeft(find.text('问题反馈')).dy),
    );
    expect(entryText('检查更新'), findsOneWidget);
    expect(entryText('当前版本 0.1.7'), findsOneWidget);

    // dragUntilVisible leaves the entry at the panel's bottom edge, partly
    // under the panel chrome, so a pointer tap may land on the chrome.
    // Invoke the entry's own tap handler instead.
    platform.published = manifest('0.1.7');
    tester
        .widget<ListTile>(
          find.descendant(of: entry, matching: find.byType(ListTile)),
        )
        .onTap!();
    await tester.pumpAndSettle();
    expect(entryText('已是最新版本（0.1.7）'), findsOneWidget);
    expect(find.text('✓  已是最新版本（0.1.7）'), findsOneWidget);
  });

  testWidgets('offers, downloads, then installs a new version on tap', (
    tester,
  ) async {
    platform.published = manifest('0.1.8');
    await controller.checkNow();
    await openMore(tester);

    // An offered update leads the list.
    final list = find.byType(ListView);
    expect(
      tester.getTopLeft(find.byKey(const Key('app-update-entry'))).dy,
      lessThan(tester.getTopLeft(find.text('AI 命令行接口')).dy),
    );
    expect(list, findsOneWidget);
    expect(entryText('发现新版本 0.1.8'), findsOneWidget);
    expect(platform.downloadCalls, 0);

    await tester.tap(find.byKey(const Key('app-update-entry')));
    await tester.pumpAndSettle();
    expect(platform.downloadCalls, 1);
    expect(entryText('新版本 0.1.8 已下载，点击安装'), findsOneWidget);
    expect(platform.launched, isEmpty);

    await tester.tap(find.byKey(const Key('app-update-entry')));
    await tester.pump();
    await tester.pump();
    expect(platform.launched, hasLength(1));
  });

  Finder entry() => find.byKey(const Key('app-update-entry'));

  Future<void> scrollToEntry(WidgetTester tester) async {
    await tester.dragUntilVisible(
      entry(),
      find.ancestor(of: find.text('导出全部内容'), matching: find.byType(ListView)),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
  }

  // dragUntilVisible leaves the entry at the panel's bottom edge, partly
  // under the panel chrome, so call the entry's own tap handler.
  void tapEntry(WidgetTester tester) => tester
      .widget<ListTile>(
        find.descendant(of: entry(), matching: find.byType(ListTile)),
      )
      .onTap!();

  bool entryBelowFeedback(WidgetTester tester) =>
      tester.getTopLeft(entry()).dy >
      tester.getTopLeft(find.text('问题反馈')).dy;

  Future<void> reopenMore(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('panel-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
  }

  testWidgets('a check the user starts answers in place, then leads later', (
    tester,
  ) async {
    await openMore(tester);
    await scrollToEntry(tester);
    expect(entryBelowFeedback(tester), isTrue);

    platform.published = manifest('0.1.8');
    tapEntry(tester);
    await tester.pumpAndSettle();

    // Still where the user tapped, now offering the release, with a notice.
    expect(entryBelowFeedback(tester), isTrue);
    expect(entryText('发现新版本 0.1.8'), findsOneWidget);
    expect(find.text('✓  发现新版本 0.1.8'), findsOneWidget);

    // The next visit puts the offer first.
    await reopenMore(tester);
    expect(
      tester.getTopLeft(entry()).dy,
      lessThan(tester.getTopLeft(find.text('AI 命令行接口')).dy),
    );
  });

  testWidgets('a background check does not move the entry under the user', (
    tester,
  ) async {
    await openMore(tester);
    await scrollToEntry(tester);
    final before = tester.getTopLeft(entry());

    platform.published = manifest('0.1.8');
    await controller.checkNow();
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(entry()), before);
    expect(entryText('发现新版本 0.1.8'), findsOneWidget);
  });

  testWidgets('a failed check stays in place with a notice', (tester) async {
    await openMore(tester);
    await scrollToEntry(tester);

    platform.fetchError = Exception('offline');
    tapEntry(tester);
    await tester.pumpAndSettle();

    expect(entryBelowFeedback(tester), isTrue);
    expect(
      find.descendant(of: entry(), matching: find.text('检查更新失败')),
      findsOneWidget,
    );
    expect(find.text('检查更新失败'), findsNWidgets(2));

    // An error is an answer, not an offer: it does not lead the next visit.
    await reopenMore(tester);
    await scrollToEntry(tester);
    expect(entryBelowFeedback(tester), isTrue);
  });

  testWidgets('the 更多 action carries a dot while a release waits', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(520, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(JianheApp(appUpdateController: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('jianhe-ball')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('more-update-badge')), findsNothing);

    platform.published = manifest('0.1.8');
    await controller.checkNow();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('more-update-badge')), findsOneWidget);

    platform.published = manifest('0.1.7');
    await controller.checkNow();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('more-update-badge')), findsNothing);
  });

  testWidgets('without an updater the entry is absent', (tester) async {
    tester.view.physicalSize = const Size(520, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const JianheApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('jianhe-ball')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-update-entry')), findsNothing);
  });
}
