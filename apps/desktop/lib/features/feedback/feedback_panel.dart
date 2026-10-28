import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../account/account_session_controller.dart';
import 'feedback_controller.dart';

class FeedbackPanel extends StatefulWidget {
  const FeedbackPanel({
    super.key,
    required this.controller,
    required this.account,
    required this.onLogin,
  });

  final FeedbackController controller;
  final AccountSessionController account;
  final VoidCallback onLogin;

  @override
  State<FeedbackPanel> createState() => _FeedbackPanelState();
}

class _FeedbackPanelState extends State<FeedbackPanel> {
  final _content = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
    widget.account.addListener(_refresh);
    _content.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    widget.account.removeListener(_refresh);
    _content.removeListener(_refresh);
    _content.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    if (!widget.account.signedIn) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.login_rounded,
                size: 40,
                color: Color(0xFFE96B3A),
              ),
              const SizedBox(height: 14),
              Text(
                strings.feedbackSignInTitle,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                strings.feedbackSignInBody,
                style: const TextStyle(color: Color(0xFF756D64)),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: widget.onLogin,
                icon: const Icon(Icons.account_circle_outlined),
                label: Text(strings.goToAccount),
              ),
            ],
          ),
        ),
      );
    }
    if (widget.controller.state == FeedbackSubmissionState.success) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.check_circle_outline_rounded,
                size: 48,
                color: Color(0xFF32765B),
              ),
              const SizedBox(height: 14),
              Text(
                strings.feedbackSentTitle,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                strings.feedbackSentBody,
                style: const TextStyle(color: Color(0xFF756D64)),
              ),
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: () {
                  _content.clear();
                  widget.controller.startAnother();
                },
                child: Text(strings.sendMoreFeedback),
              ),
            ],
          ),
        ),
      );
    }
    final count = widget.controller.runeCount(_content.text.trim());
    final overLimit = count > FeedbackController.maxContentRunes;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text(strings.feedbackIntro),
        const SizedBox(height: 14),
        TextField(
          key: const Key('feedback-content'),
          controller: _content,
          enabled: !widget.controller.busy,
          minLines: 7,
          maxLines: 12,
          decoration: InputDecoration(
            hintText: strings.feedbackHint,
            alignLabelWithHint: true,
            errorText: overLimit
                ? strings.feedbackTooLong(FeedbackController.maxContentRunes)
                : null,
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            '$count / ${FeedbackController.maxContentRunes}',
            style: TextStyle(
              fontSize: 12,
              color: overLimit
                  ? const Color(0xFFA53E36)
                  : const Color(0xFF756D64),
            ),
          ),
        ),
        if (widget.controller.message case final message?) ...[
          const SizedBox(height: 10),
          Text(message, style: const TextStyle(color: Color(0xFFA53E36))),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('submit-feedback'),
          onPressed: widget.controller.canSubmit(_content.text)
              ? () => widget.controller.submit(_content.text)
              : null,
          icon: widget.controller.busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send_outlined),
          label: Text(
            widget.controller.busy ? strings.submitting : strings.submitFeedback,
          ),
        ),
      ],
    );
  }
}
