import 'package:flutter/material.dart';
import 'package:jianhe_core/jianhe_core.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/app_strings.dart';
import 'account_session_controller.dart';
import 'vip_billing.dart';
import 'vip_purchase_controller.dart';

const _accent = Color(0xFFEA6A39);
const _ink = Color(0xFF2F2A25);
const _muted = Color(0xFF81786E);
const _border = Color(0xFFE5DCD0);
const _paper = Color(0xFFFFFCF5);
const _green = Color(0xFF32765B);

/// 开通 / 续费 VIP 的对话框：选择入口与套餐 → 同意条款 → 收银台 → 支付结果。
class VipPurchaseDialog extends StatefulWidget {
  const VipPurchaseDialog({
    super.key,
    required this.account,
    required this.billing,
    this.pollInterval = const Duration(seconds: 3),
  });

  final AccountSessionController account;
  final VipBillingRemote billing;

  /// 收银台打开时查询订单状态的间隔；null 表示不自动查询（测试用）。
  final Duration? pollInterval;

  @override
  State<VipPurchaseDialog> createState() => _VipPurchaseDialogState();
}

class _VipPurchaseDialogState extends State<VipPurchaseDialog> {
  late final VipPurchaseController _controller;

  AppStrings get _s => AppStrings.of(context);

  @override
  void initState() {
    super.initState();
    // 默认选中与界面语言对应的入口，用户可以随时切换。
    final english = AppStrings.read(context).language == AppLanguage.en;
    _controller = VipPurchaseController(
      account: widget.account,
      billing: widget.billing,
      preferredMarket: english ? vipMarketIntl : vipMarketCN,
      pollInterval: widget.pollInterval,
    )..addListener(_refresh);
    _controller.loadPlans();
  }

  @override
  void dispose() {
    _controller.removeListener(_refresh);
    _controller.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _close() {
    // 关闭时若仍有待支付订单则顺手取消，避免留下悬空订单；
    // 失败也无妨，服务端会在超时后自动关闭。
    final paid = _controller.stage == VipPurchaseStage.paid;
    if (_controller.stage == VipPurchaseStage.awaitingPayment) {
      _controller.cancelOrder();
    }
    Navigator.of(context).pop(paid);
  }

  @override
  Widget build(BuildContext context) {
    final stage = _controller.stage;
    final mock = _controller.orderMethod?.mock ?? false;
    final title = switch (stage) {
      VipPurchaseStage.awaitingPayment || VipPurchaseStage.paying =>
        mock ? _s.vipMockCashierTitle : _s.vipCashierTitle,
      VipPurchaseStage.paid => _s.vipPaidTitle,
      _ => _isRenewal ? _s.vipRenewTitle : _s.vipPurchaseTitle,
    };
    return Dialog(
      key: const Key('vip-purchase-dialog'),
      insetPadding: EdgeInsets.zero,
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 6, 0),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.workspace_premium_rounded,
                    color: Color(0xFFC08A00),
                  ),
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
                    key: const Key('vip-purchase-close'),
                    tooltip: _s.close,
                    onPressed: stage == VipPurchaseStage.paying ? null : _close,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
                child: _buildBody(stage),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool get _isRenewal => widget.account.account?.entitlement.isVip ?? false;

  Widget _buildBody(VipPurchaseStage stage) {
    return switch (stage) {
      VipPurchaseStage.loadingPlans => const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      ),
      VipPurchaseStage.plansUnavailable => _buildPlansUnavailable(),
      VipPurchaseStage.choosingPlan ||
      VipPurchaseStage.creatingOrder => _buildPlanPicker(),
      VipPurchaseStage.awaitingPayment ||
      VipPurchaseStage.paying => _buildCashier(),
      VipPurchaseStage.paid => _buildPaid(),
    };
  }

  Widget _buildPlansUnavailable() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 16),
        const Icon(Icons.cloud_off_outlined, size: 40, color: _muted),
        const SizedBox(height: 12),
        if (_controller.message case final message?) _Notice(message),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('vip-plans-retry'),
          onPressed: _controller.loadPlans,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(_s.vipReloadPlans),
        ),
      ],
    );
  }

  Widget _buildPlanPicker() {
    final catalog = _controller.catalog!;
    final market = _controller.market;
    final selected = _controller.selectedPlan;
    final creating = _controller.stage == VipPurchaseStage.creatingOrder;
    final account = widget.account.account;
    final expiresAt = account?.entitlement.vipExpiresAt;
    final methods = market?.methods ?? const <VipPayMethod>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          _isRenewal && expiresAt != null
              ? _s.vipRenewHint(_formatDate(expiresAt))
              : _s.vipBuyHint,
          style: const TextStyle(color: _muted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        if (catalog.markets.length > 1) ...<Widget>[
          SegmentedButton<String>(
            key: const Key('vip-market'),
            showSelectedIcon: false,
            segments: <ButtonSegment<String>>[
              for (final item in catalog.markets)
                ButtonSegment<String>(
                  value: item.id,
                  label: Text(
                    _s.vipMarketName(item.id),
                    key: Key('vip-market-${item.id}'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
            selected: <String>{if (market != null) market.id},
            onSelectionChanged: creating
                ? null
                : (value) => _controller.selectMarket(value.first),
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: const Color(0xFFFFF4EC),
              selectedForegroundColor: _accent,
            ),
          ),
          const SizedBox(height: 12),
        ],
        for (final plan in market?.plans ?? const <VipPlan>[]) ...<Widget>[
          _PlanTile(
            plan: plan,
            selected: plan.id == selected?.id,
            enabled: !creating,
            onTap: () => _controller.selectPlan(plan.id),
          ),
          const SizedBox(height: 8),
        ],
        if (methods.length > 1) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            _s.vipPayMethod,
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: <Widget>[
              for (final method in methods)
                ChoiceChip(
                  key: Key('vip-method-${method.id}'),
                  label: Text(method.name),
                  avatar: Icon(
                    method.action == VipPayActionType.qr
                        ? Icons.qr_code_2_rounded
                        : Icons.open_in_browser_rounded,
                    size: 16,
                  ),
                  selected: method.id == _controller.selectedMethod?.id,
                  onSelected: creating
                      ? null
                      : (_) => _controller.selectMethod(method.id),
                ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        _NoRefundNotice(_s.vipNoRefundNotice),
        const SizedBox(height: 6),
        _buildTermsCheckbox(catalog, enabled: !creating),
        if (_controller.checkoutUnavailableReason case final reason?)
          _Notice(reason)
        else if (_controller.message case final message?)
          _Notice(message),
        const SizedBox(height: 10),
        FilledButton(
          key: const Key('vip-checkout'),
          onPressed: _controller.canCheckout ? _controller.checkout : null,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(46),
            backgroundColor: _accent,
          ),
          child: creating
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(
                  selected == null
                      ? _s.vipChoosePlan
                      : _s.vipPayAmount(selected.price),
                ),
        ),
      ],
    );
  }

  Widget _buildTermsCheckbox(VipPlanCatalog catalog, {required bool enabled}) {
    final accepted = _controller.termsAccepted;
    final termsUrl = catalog.termsUrl;
    const textStyle = TextStyle(fontSize: 12, color: _ink, height: 1.4);
    return InkWell(
      key: const Key('vip-terms-accept'),
      borderRadius: BorderRadius.circular(8),
      onTap: enabled ? () => _controller.setTermsAccepted(!accepted) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 28,
              height: 22,
              child: Checkbox(
                key: const Key('vip-terms-checkbox'),
                value: accepted,
                activeColor: _accent,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: enabled
                    ? (value) => _controller.setTermsAccepted(value ?? false)
                    : null,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text.rich(
                TextSpan(
                  style: textStyle,
                  children: <InlineSpan>[
                    TextSpan(text: _s.vipTermsAgreeBefore),
                    if (termsUrl == null)
                      TextSpan(text: _s.vipTermsLink)
                    else
                      WidgetSpan(
                        alignment: PlaceholderAlignment.baseline,
                        baseline: TextBaseline.alphabetic,
                        child: GestureDetector(
                          key: const Key('vip-terms-link'),
                          onTap: () => _openTerms(termsUrl),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: Text(
                              _s.vipTermsLink,
                              style: textStyle.copyWith(
                                color: _accent,
                                decoration: TextDecoration.underline,
                                decorationColor: _accent,
                              ),
                            ),
                          ),
                        ),
                      ),
                    TextSpan(text: _s.vipTermsAgreeAfter),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openTerms(Uri uri) async {
    try {
      await widget.account.openInBrowser(uri);
    } on Object {
      // Opening the page is a convenience; the address is also on the
      // official website.
    }
  }

  Widget _buildCashier() {
    final order = _controller.order!;
    final paying = _controller.stage == VipPurchaseStage.paying;
    final method = _controller.orderMethod;
    final action = order.payAction;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (method?.mock ?? false) ...<Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF2E8),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _s.vipMockBanner,
              key: const Key('vip-mock-banner'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF9A4A22), fontSize: 11),
            ),
          ),
          const SizedBox(height: 14),
        ],
        Text(
          order.price,
          key: const Key('vip-cashier-amount'),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w800,
            color: _ink,
          ),
        ),
        const SizedBox(height: 12),
        if (action?.type == VipPayActionType.qr) ...<Widget>[
          Center(
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _border),
              ),
              child: QrImageView(
                key: const Key('vip-pay-qr'),
                data: action!.value,
                size: 176,
                backgroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _s.vipScanToPay,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
          const SizedBox(height: 12),
        ] else if (action?.type == VipPayActionType.url) ...<Widget>[
          Text(
            _s.vipPayInBrowser,
            key: const Key('vip-pay-in-browser'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
          TextButton.icon(
            key: const Key('vip-pay-reopen'),
            onPressed: paying ? null : _controller.openPayPage,
            icon: const Icon(Icons.open_in_browser_rounded, size: 18),
            label: Text(_s.vipReopenPayPage),
          ),
          const SizedBox(height: 4),
        ],
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _paper,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _border),
          ),
          child: Column(
            children: <Widget>[
              _InfoRow(
                label: _s.vipInfoProduct,
                value: _s.vipPlanName(order.plan, order.planName),
              ),
              if (method != null)
                _InfoRow(label: _s.vipPayMethod, value: method.name),
              _InfoRow(
                label: _s.vipInfoOrderNo,
                value: order.orderNo,
                selectable: true,
              ),
              _InfoRow(
                label: _s.vipInfoDeadline,
                value: _formatDateTime(order.expiresAt),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _NoRefundNotice(_s.vipNoRefundNotice),
        if (_controller.message case final message?) ...<Widget>[
          const SizedBox(height: 10),
          _Notice(message),
        ],
        const SizedBox(height: 14),
        FilledButton.icon(
          key: const Key('vip-check-paid'),
          onPressed: paying ? null : _controller.confirmPaid,
          icon: paying
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.task_alt_rounded),
          label: Text(_s.vipCheckPaid),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
            backgroundColor: _accent,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _s.vipAutoRefreshHint,
          textAlign: TextAlign.center,
          style: const TextStyle(color: _muted, fontSize: 11),
        ),
        if (method?.mock ?? false) ...<Widget>[
          const SizedBox(height: 10),
          FilledButton.icon(
            key: const Key('vip-mock-pay-success'),
            onPressed: paying
                ? null
                : () => _controller.mockPay(VipMockPaymentOutcome.success),
            icon: const Icon(Icons.check_circle_outline_rounded),
            label: Text(_s.vipMockPaySuccess),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(42),
              backgroundColor: _green,
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('vip-mock-pay-fail'),
            onPressed: paying
                ? null
                : () => _controller.mockPay(VipMockPaymentOutcome.fail),
            icon: const Icon(Icons.error_outline_rounded),
            label: Text(_s.vipMockPayFail),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(40),
              foregroundColor: const Color(0xFFA53E36),
            ),
          ),
        ],
        TextButton(
          key: const Key('vip-order-cancel'),
          onPressed: paying ? null : _controller.cancelOrder,
          child: Text(_s.vipCancelOrder),
        ),
      ],
    );
  }

  Widget _buildPaid() {
    final order = _controller.order!;
    final expiresAt = order.vipExpiresAfter;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 10),
        const Icon(Icons.verified_rounded, size: 52, color: _green),
        const SizedBox(height: 10),
        Text(
          _s.vipPlanActivated(_s.vipPlanName(order.plan, order.planName)),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          order.vipLifetime
              ? _s.vipLifetimeThanks
              : expiresAt == null
              ? _s.vipEntitlementActive
              : _s.vipPaidValidUntil(_formatDate(expiresAt)),
          key: const Key('vip-paid-summary'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: _muted, fontSize: 12),
        ),
        const SizedBox(height: 4),
        Text(
          '${_s.vipOrderNoLine(order.orderNo)} · ${order.price}',
          textAlign: TextAlign.center,
          style: const TextStyle(color: _muted, fontSize: 10),
        ),
        const SizedBox(height: 18),
        FilledButton(
          key: const Key('vip-purchase-done'),
          onPressed: _close,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
            backgroundColor: _accent,
          ),
          child: Text(_s.done),
        ),
      ],
    );
  }
}

class _PlanTile extends StatelessWidget {
  const _PlanTile({
    required this.plan,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final VipPlan plan;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final duration = s.vipPlanDuration(plan.months, plan.lifetime);
    final monthly = plan.monthlyPrice;
    final regular = plan.regularPrice;
    return Material(
      color: selected ? const Color(0xFFFFF4EC) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? _accent : _border,
          width: selected ? 1.6 : 1,
        ),
      ),
      child: InkWell(
        key: Key('vip-plan-${plan.id}'),
        borderRadius: BorderRadius.circular(12),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: <Widget>[
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: selected ? _accent : _muted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            s.vipPlanName(plan.id, plan.name),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (plan.recommended) ...<Widget>[
                          const SizedBox(width: 6),
                          _PlanBadge(
                            key: Key('vip-plan-${plan.id}-recommended'),
                            label: s.vipRecommended,
                          ),
                        ],
                        if (regular != null) ...<Widget>[
                          const SizedBox(width: 6),
                          _PlanBadge(label: s.vipEarlyBird),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      monthly == null
                          ? duration
                          : '$duration · ${s.vipPerMonth(monthly)}',
                      style: const TextStyle(color: _muted, fontSize: 11),
                    ),
                    if (regular != null)
                      Text(
                        s.vipRegularPrice(regular),
                        key: Key('vip-plan-${plan.id}-regular'),
                        style: const TextStyle(color: _muted, fontSize: 11),
                      ),
                  ],
                ),
              ),
              Text(
                plan.price,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: _ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlanBadge extends StatelessWidget {
  const _PlanBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _accent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.selectable = false,
  });

  final String label;
  final String value;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 12, color: _ink);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: _muted),
            ),
          ),
          Expanded(
            child: selectable
                ? SelectableText(value, style: style)
                : Text(value, style: style),
          ),
        ],
      ),
    );
  }
}

/// 固定展示的“不支持退款”提示。
class _NoRefundNotice extends StatelessWidget {
  const _NoRefundNotice(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('vip-no-refund'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F3EC),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.info_outline_rounded, size: 14, color: _muted),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 11, color: _ink, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('vip-purchase-message'),
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
