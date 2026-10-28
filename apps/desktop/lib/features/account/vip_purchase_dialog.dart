import 'package:flutter/material.dart';

import 'account_session_controller.dart';
import 'vip_billing.dart';
import 'vip_purchase_controller.dart';

const _accent = Color(0xFFEA6A39);
const _ink = Color(0xFF2F2A25);
const _muted = Color(0xFF81786E);
const _border = Color(0xFFE5DCD0);
const _paper = Color(0xFFFFFCF5);
const _green = Color(0xFF32765B);

/// 开通 / 续费 VIP 的对话框：套餐选择 → 模拟收银台 → 支付结果。
class VipPurchaseDialog extends StatefulWidget {
  const VipPurchaseDialog({
    super.key,
    required this.account,
    required this.billing,
  });

  final AccountSessionController account;
  final VipBillingRemote billing;

  @override
  State<VipPurchaseDialog> createState() => _VipPurchaseDialogState();
}

class _VipPurchaseDialogState extends State<VipPurchaseDialog> {
  late final VipPurchaseController _controller;

  @override
  void initState() {
    super.initState();
    _controller = VipPurchaseController(
      account: widget.account,
      billing: widget.billing,
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
    final title = switch (stage) {
      VipPurchaseStage.awaitingPayment ||
      VipPurchaseStage.paying => '模拟收银台',
      VipPurchaseStage.paid => '支付成功',
      _ => _isRenewal ? '续费 VIP' : '开通 VIP',
    };
    return Dialog(
      key: const Key('vip-purchase-dialog'),
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
                    tooltip: '关闭',
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
          label: const Text('重新加载'),
        ),
      ],
    );
  }

  Widget _buildPlanPicker() {
    final catalog = _controller.catalog!;
    final selected = _controller.selectedPlan;
    final creating = _controller.stage == VipPurchaseStage.creatingOrder;
    final account = widget.account.account;
    final expiresAt = account?.entitlement.vipExpiresAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          _isRenewal && expiresAt != null
              ? '当前 VIP 有效期至 ${_formatDate(expiresAt)}，续费时长将自动顺延。'
              : '开通后素材和 Skill 会自动同步到你的其他设备。',
          style: const TextStyle(color: _muted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        for (final plan in catalog.plans) ...<Widget>[
          _PlanTile(
            plan: plan,
            selected: plan.id == selected?.id,
            enabled: !creating,
            onTap: () => _controller.selectPlan(plan.id),
          ),
          const SizedBox(height: 8),
        ],
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
              : Text(selected == null ? '请选择套餐' : '去支付 ¥${selected.amount}'),
        ),
      ],
    );
  }

  Widget _buildCashier() {
    final order = _controller.order!;
    final paying = _controller.stage == VipPurchaseStage.paying;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF2E8),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            '测试支付 · 不会产生任何真实扣款',
            key: Key('vip-mock-banner'),
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF9A4A22), fontSize: 11),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          '¥${order.amount}',
          key: const Key('vip-cashier-amount'),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w800,
            color: _ink,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _paper,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _border),
          ),
          child: Column(
            children: <Widget>[
              _InfoRow(label: '商品', value: order.planName),
              _InfoRow(label: '订单号', value: order.orderNo, selectable: true),
              _InfoRow(
                label: '支付截止',
                value: _formatDateTime(order.expiresAt),
              ),
            ],
          ),
        ),
        if (_controller.message case final message?) ...<Widget>[
          const SizedBox(height: 10),
          _Notice(message),
        ],
        const SizedBox(height: 14),
        FilledButton.icon(
          key: const Key('vip-mock-pay-success'),
          onPressed: paying
              ? null
              : () => _controller.mockPay(VipMockPaymentOutcome.success),
          icon: paying
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.check_circle_outline_rounded),
          label: const Text('模拟支付成功'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
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
          label: const Text('模拟支付失败'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(42),
            foregroundColor: const Color(0xFFA53E36),
          ),
        ),
        TextButton(
          key: const Key('vip-order-cancel'),
          onPressed: paying ? null : _controller.cancelOrder,
          child: const Text('取消订单，重新选择套餐'),
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
          '${order.planName} 已开通',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          order.vipLifetime
              ? '你已是永久 VIP，感谢支持！'
              : expiresAt == null
              ? '权益已生效。'
              : 'VIP 有效期至 ${_formatDate(expiresAt)}',
          key: const Key('vip-paid-summary'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: _muted, fontSize: 12),
        ),
        const SizedBox(height: 4),
        Text(
          '订单号 ${order.orderNo}',
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
          child: const Text('完成'),
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
    final hint = plan.monthlyLabel;
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
                    Text(
                      plan.name,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      hint == null
                          ? plan.durationLabel
                          : '${plan.durationLabel} · $hint',
                      style: const TextStyle(color: _muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Text(
                '¥${plan.amount}',
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
            width: 64,
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
