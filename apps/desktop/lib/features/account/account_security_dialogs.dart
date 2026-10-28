import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_strings.dart';
import 'account_api.dart';
import 'account_session_controller.dart';

const _accent = Color(0xFFEA6A39);
const _ink = Color(0xFF2F2A25);
const _muted = Color(0xFF81786E);
const _danger = Color(0xFFA53E36);

/// A verification-code input with a "获取验证码" button that counts down the
/// server's cooldown after each request.
class EmailCodeField extends StatefulWidget {
  const EmailCodeField({
    super.key,
    required this.controller,
    required this.onSend,
    this.enabled = true,
    this.onResult,
    this.fieldKey,
    this.sendKey,
    this.decoration,
    this.sendButtonStyle,
  });

  final TextEditingController controller;
  final Future<AccountActionResult> Function() onSend;
  final bool enabled;

  /// Receives the outcome of each send so the caller can show its message.
  final ValueChanged<AccountActionResult>? onResult;
  final Key? fieldKey;
  final Key? sendKey;

  /// Replaces the default outlined decoration (e.g. to follow a page theme).
  final InputDecoration? decoration;

  /// Replaces the default style of the send button.
  final ButtonStyle? sendButtonStyle;

  @override
  State<EmailCodeField> createState() => _EmailCodeFieldState();
}

class _EmailCodeFieldState extends State<EmailCodeField> {
  Timer? _timer;
  int _remaining = 0;
  bool _sending = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    final result = await widget.onSend();
    if (!mounted) return;
    setState(() => _sending = false);
    widget.onResult?.call(result);
    final cooldown = result.cooldown;
    if (cooldown != null && cooldown > Duration.zero) _startCountdown(cooldown);
  }

  void _startCountdown(Duration cooldown) {
    _timer?.cancel();
    setState(() => _remaining = (cooldown.inMilliseconds / 1000).ceil());
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _remaining--);
      if (_remaining <= 0) timer.cancel();
    });
  }

  @override
  Widget build(BuildContext context) {
    final canSend = widget.enabled && !_sending && _remaining <= 0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: TextField(
            key: widget.fieldKey,
            controller: widget.controller,
            enabled: widget.enabled,
            keyboardType: TextInputType.number,
            autofillHints: const <String>[AutofillHints.oneTimeCode],
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            decoration:
                widget.decoration ??
                InputDecoration(
                  labelText: AppStrings.of(context).emailCodeLabel,
                  prefixIcon: const Icon(Icons.mark_email_read_outlined),
                  border: const OutlineInputBorder(),
                ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          height: 56,
          width: 104,
          child: OutlinedButton(
            key: widget.sendKey,
            onPressed: canSend ? _send : null,
            style:
                widget.sendButtonStyle ??
                OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
            child: Text(
              _sending
                  ? AppStrings.of(context).sendingCode
                  : _remaining > 0
                  ? AppStrings.of(context).resendInSeconds(_remaining)
                  : AppStrings.of(context).getCode,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }
}

/// Inline status line used inside the account dialogs and forms.
class AccountNotice extends StatelessWidget {
  const AccountNotice({super.key, required this.message, this.success = false});

  final String message;
  final bool success;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: success ? const Color(0xFFEAF5EF) : const Color(0xFFFFF2E8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: success ? const Color(0xFFB9DCC8) : const Color(0xFFF1C9AF),
        ),
      ),
      child: Text(
        message,
        style: TextStyle(
          color: success ? const Color(0xFF2C6047) : const Color(0xFF7E4932),
          fontSize: 12,
        ),
      ),
    );
  }
}

class _AccountDialogFrame extends StatelessWidget {
  const _AccountDialogFrame({
    required this.dialogKey,
    required this.icon,
    required this.title,
    required this.onClose,
    required this.child,
    this.iconColor = _accent,
  });

  final Key dialogKey;
  final IconData icon;
  final Color iconColor;
  final String title;
  final VoidCallback? onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: dialogKey,
      insetPadding: EdgeInsets.zero,
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 6, 0),
              child: Row(
                children: <Widget>[
                  Icon(icon, color: iconColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: _ink,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: AppStrings.of(context).close,
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PasswordField extends StatefulWidget {
  const _PasswordField({
    super.key,
    required this.controller,
    required this.label,
    required this.enabled,
    this.helperText,
    this.newPassword = false,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;
  final String? helperText;
  final bool newPassword;

  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: _obscure,
      autofillHints: <String>[
        widget.newPassword ? AutofillHints.newPassword : AutofillHints.password,
      ],
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: widget.helperText,
        prefixIcon: const Icon(Icons.lock_outline_rounded),
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          tooltip: _obscure
              ? AppStrings.of(context).showPassword
              : AppStrings.of(context).hidePassword,
          onPressed: () => setState(() => _obscure = !_obscure),
          icon: Icon(
            _obscure
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
          ),
        ),
      ),
    );
  }
}

Widget _primaryButton({
  required Key key,
  required String label,
  required bool working,
  required VoidCallback? onPressed,
  Color color = _accent,
}) {
  return FilledButton(
    key: key,
    onPressed: working ? null : onPressed,
    style: FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(44),
      backgroundColor: color,
    ),
    child: working
        ? const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          )
        : Text(label),
  );
}

/// 修改密码。成功时以提示文字关闭。
class ChangePasswordDialog extends StatefulWidget {
  const ChangePasswordDialog({super.key, required this.account});

  final AccountSessionController account;

  @override
  State<ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<ChangePasswordDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _working = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_next.text != _confirm.text) {
      setState(() => _error = AppStrings.current.passwordsDoNotMatch);
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    final result = await widget.account.changePassword(
      currentPassword: _current.text,
      newPassword: _next.text,
    );
    if (!mounted) return;
    if (result.succeeded) {
      Navigator.of(context).pop(result.message);
      return;
    }
    setState(() {
      _working = false;
      _error = result.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return _AccountDialogFrame(
      dialogKey: const Key('change-password-dialog'),
      icon: Icons.password_rounded,
      title: strings.changePassword,
      onClose: _working ? null : () => Navigator.of(context).pop(),
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              strings.changePasswordIntro,
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
            const SizedBox(height: 14),
            _PasswordField(
              key: const Key('change-password-current'),
              controller: _current,
              label: strings.currentPasswordLabel,
              enabled: !_working,
            ),
            const SizedBox(height: 12),
            _PasswordField(
              key: const Key('change-password-new'),
              controller: _next,
              label: strings.newPasswordLabel,
              helperText: strings.passwordLengthHelper,
              enabled: !_working,
              newPassword: true,
            ),
            const SizedBox(height: 12),
            _PasswordField(
              key: const Key('change-password-confirm'),
              controller: _confirm,
              label: strings.repeatNewPasswordLabel,
              enabled: !_working,
              newPassword: true,
            ),
            if (_error case final error?) ...<Widget>[
              const SizedBox(height: 12),
              AccountNotice(message: error),
            ],
            const SizedBox(height: 16),
            _primaryButton(
              key: const Key('change-password-submit'),
              label: strings.confirmChange,
              working: _working,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

/// 验证邮箱。成功时以提示文字关闭。
class VerifyEmailDialog extends StatefulWidget {
  const VerifyEmailDialog({super.key, required this.account});

  final AccountSessionController account;

  @override
  State<VerifyEmailDialog> createState() => _VerifyEmailDialogState();
}

class _VerifyEmailDialogState extends State<VerifyEmailDialog> {
  final _code = TextEditingController();
  bool _working = false;
  AccountActionResult? _notice;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _working = true;
      _notice = null;
    });
    final result = await widget.account.verifyEmail(_code.text);
    if (!mounted) return;
    if (result.succeeded) {
      Navigator.of(context).pop(result.message);
      return;
    }
    setState(() {
      _working = false;
      _notice = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final email = widget.account.account?.email ?? '';
    final strings = AppStrings.of(context);
    return _AccountDialogFrame(
      dialogKey: const Key('verify-email-dialog'),
      icon: Icons.mark_email_read_outlined,
      title: strings.verifyEmail,
      onClose: _working ? null : () => Navigator.of(context).pop(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            strings.verifyEmailIntro(email),
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
          const SizedBox(height: 14),
          EmailCodeField(
            fieldKey: const Key('verify-email-code'),
            sendKey: const Key('verify-email-send'),
            controller: _code,
            enabled: !_working,
            onSend: () => widget.account.sendAccountEmailCode(
              EmailCodePurpose.verifyEmail,
            ),
            onResult: (result) => setState(() => _notice = result),
          ),
          if (_notice case final notice?
              when notice.message != null) ...<Widget>[
            const SizedBox(height: 12),
            AccountNotice(message: notice.message!, success: notice.succeeded),
          ],
          const SizedBox(height: 16),
          _primaryButton(
            key: const Key('verify-email-submit'),
            label: strings.verify,
            working: _working,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}

/// 注销账号。成功后控制器已退出登录，对话框返回 true。
class DeleteAccountDialog extends StatefulWidget {
  const DeleteAccountDialog({super.key, required this.account});

  final AccountSessionController account;

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _useEmailCode = false;
  bool _confirmed = false;
  bool _working = false;
  AccountActionResult? _notice;

  @override
  void initState() {
    super.initState();
    _password.addListener(_refresh);
    _code.addListener(_refresh);
  }

  @override
  void dispose() {
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  bool get _hasEmail => (widget.account.account?.email ?? '').isNotEmpty;

  bool get _ready {
    if (!_confirmed || _working) return false;
    if (!_hasEmail) return true;
    return _useEmailCode
        ? _code.text.trim().length == 6
        : _password.text.isNotEmpty;
  }

  Future<void> _submit() async {
    setState(() {
      _working = true;
      _notice = null;
    });
    final result = await widget.account.deleteAccount(
      password: _hasEmail && !_useEmailCode ? _password.text : null,
      emailCode: _hasEmail && _useEmailCode ? _code.text : null,
    );
    if (!mounted) return;
    if (result.succeeded) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _working = false;
      _notice = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final email = widget.account.account?.email ?? '';
    final strings = AppStrings.of(context);
    return _AccountDialogFrame(
      dialogKey: const Key('delete-account-dialog'),
      icon: Icons.warning_amber_rounded,
      iconColor: _danger,
      title: strings.deleteAccount,
      onClose: _working ? null : () => Navigator.of(context).pop(false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF0EE),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFF0C4BE)),
            ),
            child: Text(
              strings.deleteAccountWarning,
              style: const TextStyle(color: _danger, fontSize: 12, height: 1.5),
            ),
          ),
          const SizedBox(height: 14),
          if (_hasEmail && !_useEmailCode) ...<Widget>[
            _PasswordField(
              key: const Key('delete-account-password'),
              controller: _password,
              label: strings.confirmWithCurrentPassword,
              enabled: !_working,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('delete-account-use-code'),
                onPressed: _working
                    ? null
                    : () => setState(() {
                        _useEmailCode = true;
                        _notice = null;
                      }),
                child: Text(strings.useEmailCodeInstead),
              ),
            ),
          ],
          if (_hasEmail && _useEmailCode) ...<Widget>[
            Text(
              strings.codeWillBeSentTo(email),
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
            const SizedBox(height: 8),
            EmailCodeField(
              fieldKey: const Key('delete-account-code'),
              sendKey: const Key('delete-account-send-code'),
              controller: _code,
              enabled: !_working,
              onSend: () => widget.account.sendAccountEmailCode(
                EmailCodePurpose.deleteAccount,
              ),
              onResult: (result) => setState(() => _notice = result),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _working
                    ? null
                    : () => setState(() {
                        _useEmailCode = false;
                        _notice = null;
                      }),
                child: Text(strings.usePasswordInstead),
              ),
            ),
          ],
          CheckboxListTile(
            key: const Key('delete-account-confirm'),
            value: _confirmed,
            onChanged: _working
                ? null
                : (value) => setState(() => _confirmed = value ?? false),
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(
              strings.deleteAccountAcknowledge,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          if (_notice case final notice?
              when notice.message != null) ...<Widget>[
            const SizedBox(height: 8),
            AccountNotice(message: notice.message!, success: notice.succeeded),
          ],
          const SizedBox(height: 12),
          _primaryButton(
            key: const Key('delete-account-submit'),
            label: strings.deleteAccountPermanently,
            working: _working,
            onPressed: _ready ? _submit : null,
            color: _danger,
          ),
        ],
      ),
    );
  }
}
