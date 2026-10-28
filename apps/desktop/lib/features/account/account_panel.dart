import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:jianhe_core/jianhe_core.dart';

import '../../l10n/app_strings.dart';
import '../cloud_sync/sync_controller.dart';
import '../cloud_sync/sync_models.dart';
import '../cloud_sync/sync_schedule.dart';
import 'account_api.dart';
import 'account_models.dart';
import 'account_security_dialogs.dart';
import 'account_session_controller.dart';
import 'vip_purchase_dialog.dart';

/// Google 登录/绑定入口开关。暂时隐藏；改为 true 即可恢复。
const bool kGoogleSignInEnabled = false;

typedef AccountDialogPresenter =
    Future<T?> Function<T>({
      required WidgetBuilder builder,
      required bool barrierDismissible,
      Key? frameKey,
    });

class AccountPanel extends StatefulWidget {
  const AccountPanel({
    super.key,
    required this.controller,
    this.syncController,
    this.createBackup,
    this.dialogPresenter,
  });

  final AccountSessionController controller;
  final SyncController? syncController;
  final Future<JianheBackup> Function()? createBackup;
  final AccountDialogPresenter? dialogPresenter;

  @override
  State<AccountPanel> createState() => _AccountPanelState();
}

class _AccountPanelState extends State<AccountPanel> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _codeController = TextEditingController();
  bool _registerMode = false;
  // 找回密码：邮箱 + 验证码 + 新密码。
  bool _resetMode = false;
  bool _resetting = false;
  // Local status line for code requests, password reset and account
  // security dialogs; the controller's message covers sign-in itself.
  AccountActionResult? _notice;
  bool _obscurePassword = true;
  String? _observedAccountId;

  @override
  void initState() {
    super.initState();
    _observedAccountId = widget.controller.account?.id;
    widget.controller.addListener(_refresh);
    widget.syncController?.addListener(_refresh);
  }

  @override
  void didUpdateWidget(covariant AccountPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_refresh);
      widget.controller.addListener(_refresh);
      _observedAccountId = widget.controller.account?.id;
    }
    if (oldWidget.syncController != widget.syncController) {
      oldWidget.syncController?.removeListener(_refresh);
      widget.syncController?.addListener(_refresh);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    widget.syncController?.removeListener(_refresh);
    _emailController.dispose();
    _passwordController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  /// Strings for the build helpers below (they run during build).
  AppStrings get _s => AppStrings.of(context);

  void _refresh() {
    final nextAccountId = widget.controller.account?.id;
    if (nextAccountId != _observedAccountId) {
      _observedAccountId = nextAccountId;
      // A notice belongs to the account it was shown for.
      _notice = null;
    }
    if (mounted) setState(() {});
  }

  Future<void> _submit() async {
    if (_resetMode) {
      await _submitReset();
      return;
    }
    final succeeded = _registerMode
        ? await widget.controller.register(
            email: _emailController.text,
            password: _passwordController.text,
            emailCode: _codeController.text,
          )
        : await widget.controller.login(
            email: _emailController.text,
            password: _passwordController.text,
          );
    // The request can outlive this panel (dialog closed mid-flight); the
    // controller is disposed with it.
    if (succeeded && mounted) {
      _passwordController.clear();
      _codeController.clear();
      setState(() => _notice = null);
    }
  }

  Future<void> _submitReset() async {
    setState(() {
      _resetting = true;
      _notice = null;
    });
    final result = await widget.controller.resetPassword(
      email: _emailController.text,
      code: _codeController.text,
      newPassword: _passwordController.text,
    );
    if (!mounted) return;
    setState(() {
      _resetting = false;
      _notice = result;
      if (result.succeeded) {
        _resetMode = false;
        _registerMode = false;
        _passwordController.clear();
        _codeController.clear();
      }
    });
  }

  void _switchMode({required bool register, required bool reset}) {
    widget.controller.clearMessage();
    setState(() {
      _registerMode = register;
      _resetMode = reset;
      _notice = null;
      _codeController.clear();
    });
  }

  Future<AccountActionResult> _sendFormCode() {
    return widget.controller.sendEmailCode(
      email: _emailController.text,
      purpose: _resetMode
          ? EmailCodePurpose.resetPassword
          : EmailCodePurpose.register,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (!controller.configured) return const _UnconfiguredAccount();
    if (controller.status == AccountSessionStatus.restoring) {
      return _AccountProgress(label: _s.accountRestoringProgress);
    }
    if (controller.signedIn) return _buildSignedIn(controller);
    return _buildSignedOut(controller);
  }

  Widget _buildSignedOut(AccountSessionController controller) {
    final security = controller.supportsAccountSecurity;
    final busy = controller.busy || _resetting;
    final needsCode = security && (_registerMode || _resetMode);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 24),
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Icon(
              Icons.cloud_outlined,
              size: 42,
              color: Color(0xFFEA6A39),
            ),
            const SizedBox(height: 10),
            Text(
              _resetMode
                  ? _s.resetPasswordTitle
                  : _registerMode
                  ? _s.createAccountTitle
                  : _s.signInTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 5),
            Text(
              _resetMode
                  ? _s.resetPasswordIntro
                  : _registerMode
                  ? _s.createAccountIntro
                  : _s.signInIntro,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF81786E), fontSize: 12),
            ),
            const SizedBox(height: 20),
            TextField(
              key: const Key('account-email-field'),
              controller: _emailController,
              enabled: !busy,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const <String>[AutofillHints.email],
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: _s.emailLabel,
                prefixIcon: const Icon(Icons.alternate_email_rounded),
                border: const OutlineInputBorder(),
              ),
            ),
            if (needsCode) ...<Widget>[
              const SizedBox(height: 12),
              EmailCodeField(
                fieldKey: const Key('account-email-code-field'),
                sendKey: const Key('account-send-code'),
                controller: _codeController,
                enabled: !busy,
                onSend: _sendFormCode,
                onResult: (result) => setState(() => _notice = result),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const Key('account-password-field'),
              controller: _passwordController,
              enabled: !busy,
              obscureText: _obscurePassword,
              autofillHints: <String>[
                _registerMode || _resetMode
                    ? AutofillHints.newPassword
                    : AutofillHints.password,
              ],
              onSubmitted: (_) => busy ? null : _submit(),
              decoration: InputDecoration(
                labelText: _resetMode ? _s.newPasswordLabel : _s.passwordLabel,
                helperText: _registerMode || _resetMode
                    ? _s.passwordLengthHelper
                    : null,
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: _obscurePassword
                      ? _s.showPassword
                      : _s.hidePassword,
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
            ),
            if (_notice case final notice?
                when notice.message != null) ...<Widget>[
              const SizedBox(height: 12),
              AccountNotice(
                key: const Key('account-notice'),
                message: notice.message!,
                success: notice.succeeded,
              ),
            ],
            if (controller.message case final message?) ...<Widget>[
              const SizedBox(height: 12),
              _AccountMessage(message: message),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('account-submit'),
              onPressed: busy ? null : _submit,
              icon: busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      _resetMode
                          ? Icons.lock_reset_rounded
                          : _registerMode
                          ? Icons.person_add_alt_1_rounded
                          : Icons.login_rounded,
                    ),
              label: Text(
                busy
                    ? _s.pleaseWait
                    : _resetMode
                    ? _s.resetPasswordTitle
                    : _registerMode
                    ? _s.registerAndSignIn
                    : _s.signIn,
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                backgroundColor: const Color(0xFFEA6A39),
              ),
            ),
            TextButton(
              key: const Key('account-mode-toggle'),
              onPressed: busy
                  ? null
                  : () => _switchMode(
                      register: !_registerMode && !_resetMode,
                      reset: false,
                    ),
              child: Text(
                _resetMode
                    ? _s.backToSignIn
                    : _registerMode
                    ? _s.haveAccountSignIn
                    : _s.noAccountCreate,
              ),
            ),
            if (security && !_registerMode && !_resetMode)
              TextButton(
                key: const Key('account-forgot-password'),
                onPressed: busy
                    ? null
                    : () => _switchMode(register: false, reset: true),
                child: Text(_s.forgotPassword),
              ),
            if (kGoogleSignInEnabled) ...<Widget>[
              const SizedBox(height: 8),
              OutlinedButton(
                key: const Key('account-google-login'),
                onPressed: controller.busy
                    ? null
                    : () => controller.authenticateExternal('google'),
                child: Text(_s.signInWithGoogle),
              ),
            ],
            if (controller.externalInProgress)
              TextButton(
                onPressed: controller.cancelExternal,
                child: Text(_s.cancelAuthorizationWait),
              ),
            if (controller.restoreRetryAvailable)
              TextButton.icon(
                key: const Key('account-retry-restore'),
                onPressed: controller.busy ? null : controller.retryRestore,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(_s.retryRestoreSignIn),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSignedIn(AccountSessionController controller) {
    final account = controller.account!;
    final entitlement = account.entitlement;
    final readOnlyGrace = entitlement.isCloudBackupReadOnly;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE5DCD0)),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFFEA6A39).withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(
                  Icons.person_outline_rounded,
                  color: Color(0xFFEA6A39),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      account.displayLabel,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      account.email.isEmpty
                          ? _s.thirdPartyAccount
                          : account.emailVerified
                          ? _s.emailVerified
                          : controller.supportsAccountSecurity
                          ? _s.emailNotVerified
                          : _s.privateBetaAccount,
                      style: const TextStyle(
                        color: Color(0xFF81786E),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              _PlanBadge(
                isVip: entitlement.isVip,
                readOnlyGrace: readOnlyGrace,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _AccountInfoCard(
          icon: Icons.workspace_premium_outlined,
          title: entitlement.vipLifetime
              ? _s.vipLifetimeActive
              : entitlement.isVip
              ? _s.vipActive
              : readOnlyGrace
              ? _s.vipExpiredGrace
              : _s.freeAccount,
          body: entitlement.isVip
              ? _s.vipActiveBody
              : readOnlyGrace
              ? _s.vipGraceBody
              : _s.freeAccountBody,
          detail: entitlement.vipLifetime
              ? _s.vipLifetimeDetail
              : entitlement.vipExpiresAt == null
              ? null
              : _s.vipValidUntil(_formatDate(entitlement.vipExpiresAt!)),
        ),
        // Purchase is offered in the Chinese interface only for now.
        if (controller.billing != null &&
            !entitlement.vipLifetime &&
            _s.language != AppLanguage.en) ...<Widget>[
          const SizedBox(height: 10),
          FilledButton.icon(
            key: const Key('vip-purchase'),
            onPressed: controller.busy ? null : _openVipPurchase,
            icon: const Icon(Icons.workspace_premium_rounded),
            label: Text(entitlement.isVip ? _s.renewVip : _s.getVip),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
              backgroundColor: const Color(0xFFEA6A39),
            ),
          ),
        ],
        if (widget.syncController case final syncController?) ...<Widget>[
          const SizedBox(height: 10),
          _buildSyncCard(syncController, entitlement),
        ],
        if (controller.message case final message?) ...<Widget>[
          const SizedBox(height: 12),
          _AccountMessage(message: message),
        ],
        if (_notice case final notice? when notice.message != null) ...<Widget>[
          const SizedBox(height: 12),
          AccountNotice(
            key: const Key('account-notice'),
            message: notice.message!,
            success: notice.succeeded,
          ),
        ],
        if (controller.supportsAccountSecurity) ...<Widget>[
          const SizedBox(height: 12),
          _buildSecurityCard(controller, account),
        ],
        const SizedBox(height: 16),
        if (kGoogleSignInEnabled && !account.googleLinked)
          OutlinedButton(
            onPressed: controller.busy
                ? null
                : () => controller.authenticateExternal('google'),
            child: Text(_s.linkGoogleAccount),
          ),
        if (controller.externalInProgress)
          TextButton(
            onPressed: controller.cancelExternal,
            child: Text(_s.cancelAuthorizationWait),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('account-refresh'),
          onPressed: controller.busy ? null : controller.refreshAccount,
          icon: controller.busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh_rounded),
          label: Text(_s.refreshAccount),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          key: const Key('account-logout'),
          onPressed: controller.busy ? null : _requestLogout,
          icon: const Icon(Icons.logout_rounded),
          label: Text(_s.signOut),
          style: TextButton.styleFrom(foregroundColor: const Color(0xFFA53E36)),
        ),
        if (controller.supportsAccountSecurity)
          TextButton(
            key: const Key('account-delete'),
            onPressed: controller.busy ? null : _openDeleteAccount,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF9A8F84),
              textStyle: const TextStyle(fontSize: 12),
            ),
            child: Text(_s.deleteAccount),
          ),
      ],
    );
  }

  Widget _buildSecurityCard(
    AccountSessionController controller,
    JianheAccount account,
  ) {
    final needsVerification =
        account.email.isNotEmpty && !account.emailVerified;
    return Container(
      key: const Key('account-security-card'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFCF5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5DCD0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.shield_outlined,
                color: Color(0xFF32765B),
                size: 22,
              ),
              const SizedBox(width: 10),
              Text(
                _s.accountSecurity,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          if (needsVerification) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              _s.emailNotVerifiedHint,
              style: const TextStyle(fontSize: 12, color: Color(0xFF7E4932)),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              if (needsVerification)
                OutlinedButton.icon(
                  key: const Key('account-verify-email'),
                  onPressed: controller.busy ? null : _openVerifyEmail,
                  icon: const Icon(Icons.mark_email_read_outlined, size: 18),
                  label: Text(_s.verifyEmail),
                ),
              if (account.email.isNotEmpty)
                OutlinedButton.icon(
                  key: const Key('account-change-password'),
                  onPressed: controller.busy ? null : _openChangePassword,
                  icon: const Icon(Icons.password_rounded, size: 18),
                  label: Text(_s.changePassword),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openChangePassword() async {
    final message = await _showAccountDialog<String>(
      frameKey: const Key('change-password-dialog-frame'),
      barrierDismissible: false,
      builder: (_) => ChangePasswordDialog(account: widget.controller),
    );
    if (message == null || !mounted) return;
    setState(() => _notice = AccountActionResult.success(message: message));
  }

  Future<void> _openVerifyEmail() async {
    final message = await _showAccountDialog<String>(
      frameKey: const Key('verify-email-dialog-frame'),
      barrierDismissible: false,
      builder: (_) => VerifyEmailDialog(account: widget.controller),
    );
    if (message == null || !mounted) return;
    setState(() => _notice = AccountActionResult.success(message: message));
  }

  Future<void> _openDeleteAccount() async {
    await _showAccountDialog<bool>(
      frameKey: const Key('delete-account-dialog-frame'),
      barrierDismissible: false,
      builder: (_) => DeleteAccountDialog(account: widget.controller),
    );
  }

  Widget _buildSyncCard(
    SyncController controller,
    AccountEntitlement entitlement,
  ) {
    final busy = controller.syncing;
    final lastSync = controller.lastSyncAt;
    final pending = controller.pendingCount;
    final isVip = entitlement.isVip;
    final readOnlyGrace = entitlement.isCloudBackupReadOnly;
    final updatedCount = switch (controller.lastResult) {
      final result? => result.pushedCount + result.pulledCount,
      null => 0,
    };
    final status = !isVip && !readOnlyGrace
        ? _s.syncStatusNeedsVip
        : readOnlyGrace
        ? _s.syncStatusGrace
        : busy
        ? _s.syncStatusUpdating
        : pending > 0
        ? _s.syncStatusPending(pending)
        : lastSync != null && updatedCount > 0
        ? _s.syncStatusUpdated(updatedCount, _formatDateTime(lastSync))
        : lastSync != null
        ? _s.syncStatusSynced(_formatDateTime(lastSync))
        : controller.autoSyncEnabled
        ? _s.syncStatusAuto
        : _s.syncStatusManual;
    return Container(
      key: const Key('sync-card'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5DCD0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.sync_rounded,
                color: Color(0xFF32765B),
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _s.multiDeviceSync,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (busy)
                const SizedBox.square(
                  dimension: 17,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              if (!busy && !isVip)
                _SyncAccessBadge(
                  label: readOnlyGrace
                      ? _s.syncBadgeRestoreOnly
                      : _s.syncBadgeVipOnly,
                ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            status,
            style: const TextStyle(color: Color(0xFF6E675F), fontSize: 12),
          ),
          if (isVip) ...<Widget>[
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    _s.autoSync,
                    style: const TextStyle(
                      color: Color(0xFF6E675F),
                      fontSize: 12,
                    ),
                  ),
                ),
                SizedBox(
                  height: 28,
                  child: Switch(
                    key: const Key('auto-sync-switch'),
                    value: controller.autoSyncEnabled,
                    onChanged: busy ? null : controller.setAutoSyncEnabled,
                  ),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  key: const Key('sync-now'),
                  onPressed: busy ? null : _startSync,
                  icon: const Icon(Icons.sync_rounded, size: 18),
                  label: Text(_s.syncNow),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF32765B),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
            if (controller.autoSyncEnabled) ...<Widget>[
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _s.syncFrequency,
                      style: const TextStyle(
                        color: Color(0xFF6E675F),
                        fontSize: 12,
                      ),
                    ),
                  ),
                  DropdownButton<String>(
                    key: const Key('sync-schedule'),
                    value: controller.schedule.mode == SyncScheduleMode.daily
                        ? 'daily'
                        : '${controller.schedule.intervalMinutes}',
                    isDense: true,
                    items: <DropdownMenuItem<String>>[
                      DropdownMenuItem(
                        value: '15',
                        child: Text(_s.everyMinutes(15)),
                      ),
                      DropdownMenuItem(
                        value: '30',
                        child: Text(_s.everyMinutes(30)),
                      ),
                      DropdownMenuItem(value: '60', child: Text(_s.everyHour)),
                      DropdownMenuItem(
                        value: 'daily',
                        child: Text(_s.dailyAtTime),
                      ),
                    ],
                    onChanged: busy
                        ? null
                        : (value) async {
                            if (value == null) return;
                            if (value == 'daily') {
                              await _pickDailySyncTime(controller);
                            } else {
                              controller.setSchedule(
                                SyncSchedule.interval(int.parse(value)),
                              );
                            }
                          },
                  ),
                ],
              ),
              if (controller.schedule.mode == SyncScheduleMode.daily)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('sync-daily-time'),
                    onPressed: busy
                        ? null
                        : () => _pickDailySyncTime(controller),
                    icon: const Icon(Icons.schedule_rounded, size: 17),
                    label: Text(
                      '${controller.schedule.dailyHour!.toString().padLeft(2, '0')}:'
                      '${controller.schedule.dailyMinute!.toString().padLeft(2, '0')}',
                    ),
                  ),
                ),
              if (controller.scheduleError != null)
                Text(
                  controller.scheduleError!,
                  style: const TextStyle(
                    color: Color(0xFFB44D3A),
                    fontSize: 11,
                  ),
                )
              else if (controller.nextScheduledAt != null)
                Text(
                  _s.nextSync(_formatDateTime(controller.nextScheduledAt!)),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: Color(0xFF8A8178),
                    fontSize: 11,
                  ),
                ),
            ],
          ] else if (readOnlyGrace) ...<Widget>[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const Key('sync-download'),
              onPressed: busy
                  ? null
                  : () => _startSync(mode: SyncMode.pullOnly),
              icon: const Icon(Icons.cloud_download_outlined),
              label: Text(_s.downloadCloudContent),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF32765B),
              ),
            ),
          ],
          if (controller.message case final message?) ...<Widget>[
            const SizedBox(height: 8),
            _AccountMessage(message: message),
          ],
        ],
      ),
    );
  }

  Future<void> _pickDailySyncTime(SyncController controller) async {
    final dailyTime = controller.preferredDailySyncTime;
    var selectedTime = TimeOfDay(
      hour: dailyTime.hour,
      minute: dailyTime.minute,
    );
    final confirmed = await _showAccountDialog<bool>(
      frameKey: const Key('sync-daily-time-dialog-frame'),
      builder: (dialogContext) => AlertDialog(
        key: const Key('sync-daily-time-dialog'),
        insetPadding: EdgeInsets.zero,
        constraints: const BoxConstraints(maxWidth: 320),
        title: Text(AppStrings.of(dialogContext).chooseSyncTime),
        content: SizedBox(
          width: 280,
          height: 200,
          // ScrollBehavior 默认把鼠标排除在拖动设备之外，滚轮只能滚不能拖；
          // 时间选择器内部没有可选文本，可以安全地放行鼠标拖动。
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(dialogContext).copyWith(
              dragDevices: {
                ...ScrollConfiguration.of(dialogContext).dragDevices,
                PointerDeviceKind.mouse,
              },
            ),
            child: CupertinoDatePicker(
              key: const Key('sync-daily-time-picker'),
              mode: CupertinoDatePickerMode.time,
              use24hFormat: true,
              minuteInterval: 1,
              showTimeSeparator: true,
              initialDateTime: DateTime(
                2000,
                1,
                1,
                selectedTime.hour,
                selectedTime.minute,
              ),
              onDateTimeChanged: (value) {
                selectedTime = TimeOfDay(
                  hour: value.hour,
                  minute: value.minute,
                );
              },
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(AppStrings.of(dialogContext).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(AppStrings.of(dialogContext).ok),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    controller.setSchedule(
      SyncSchedule.daily(hour: selectedTime.hour, minute: selectedTime.minute),
    );
  }

  Future<void> _startSync({SyncMode mode = SyncMode.pushAndPull}) async {
    final syncController = widget.syncController;
    if (syncController == null || syncController.syncing) return;
    await syncController.synchronize(mode: mode);
  }

  Future<void> _openVipPurchase() async {
    final billing = widget.controller.billing;
    if (billing == null) return;
    await _showAccountDialog<bool>(
      frameKey: const Key('vip-purchase-dialog-frame'),
      barrierDismissible: false,
      builder: (_) =>
          VipPurchaseDialog(account: widget.controller, billing: billing),
    );
  }

  Future<void> _requestLogout() async {
    await widget.controller.logout();
  }

  Future<T?> _showAccountDialog<T>({
    required WidgetBuilder builder,
    bool barrierDismissible = true,
    Key? frameKey,
  }) {
    final presenter = widget.dialogPresenter;
    if (presenter != null) {
      return presenter<T>(
        builder: builder,
        barrierDismissible: barrierDismissible,
        frameKey: frameKey,
      );
    }
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: builder,
    );
  }
}

class _UnconfiguredAccount extends StatelessWidget {
  const _UnconfiguredAccount();

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.cloud_off_outlined,
              size: 44,
              color: Color(0xFF81786E),
            ),
            const SizedBox(height: 12),
            Text(
              strings.cloudNotConfiguredTitle,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              strings.cloudNotConfiguredBody,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF81786E), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountProgress extends StatelessWidget {
  const _AccountProgress({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const CircularProgressIndicator(),
          const SizedBox(height: 14),
          Text(label, style: const TextStyle(color: Color(0xFF81786E))),
        ],
      ),
    );
  }
}

class _AccountMessage extends StatelessWidget {
  const _AccountMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF2E8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFF1C9AF)),
      ),
      child: Text(
        message,
        style: const TextStyle(color: Color(0xFF7E4932), fontSize: 12),
      ),
    );
  }
}

class _PlanBadge extends StatelessWidget {
  const _PlanBadge({required this.isVip, required this.readOnlyGrace});

  final bool isVip;
  final bool readOnlyGrace;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isVip
            ? const Color(0xFFFFE5A3)
            : readOnlyGrace
            ? const Color(0xFFFFEED1)
            : const Color(0xFFF0ECE6),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        isVip
            ? 'VIP'
            : readOnlyGrace
            ? AppStrings.of(context).planBadgeReadOnly
            : AppStrings.of(context).planBadgeFree,
        style: TextStyle(
          color: isVip || readOnlyGrace
              ? const Color(0xFF875B00)
              : const Color(0xFF6E675F),
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _SyncAccessBadge extends StatelessWidget {
  const _SyncAccessBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEED1),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF875B00),
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AccountInfoCard extends StatelessWidget {
  const _AccountInfoCard({
    required this.icon,
    required this.title,
    required this.body,
    this.detail,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFCF5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5DCD0)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: const Color(0xFF32765B), size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(body, style: const TextStyle(fontSize: 12)),
                if (detail case final value?) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    value,
                    style: const TextStyle(
                      color: Color(0xFF81786E),
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)}';
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${_formatDate(value)} '
      '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}
