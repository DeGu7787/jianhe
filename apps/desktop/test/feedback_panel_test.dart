import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianhe_desktop/features/account/account_session_controller.dart';
import 'package:jianhe_desktop/features/feedback/feedback_api.dart';
import 'package:jianhe_desktop/features/feedback/feedback_controller.dart';
import 'package:jianhe_desktop/features/feedback/feedback_models.dart';
import 'package:jianhe_desktop/features/feedback/feedback_panel.dart';

void main() {
  testWidgets('signed-out feedback panel shows login guidance', (tester) async {
    final account = AccountSessionController.unconfigured();
    final controller = FeedbackController(api: _NeverApi(), account: account);
    addTearDown(controller.dispose);
    addTearDown(account.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeedbackPanel(
            controller: controller,
            account: account,
            onLogin: () {},
          ),
        ),
      ),
    );

    expect(find.text('登录后提交问题反馈'), findsOneWidget);
    expect(find.byKey(const Key('feedback-content')), findsNothing);
  });
}

class _NeverApi implements FeedbackRemoteDataSource {
  @override
  Future<FeedbackCreated> create({
    required String accessToken,
    required String content,
  }) => throw StateError('must not submit while signed out');
}
