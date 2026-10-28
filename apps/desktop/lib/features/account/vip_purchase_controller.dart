import 'package:flutter/foundation.dart';

import 'account_api.dart';
import 'account_session_controller.dart';
import 'vip_billing.dart';

enum VipPurchaseStage {
  /// 正在拉取套餐列表。
  loadingPlans,

  /// 套餐列表加载失败，可重试。
  plansUnavailable,

  /// 用户正在选择套餐。
  choosingPlan,

  /// 正在创建订单。
  creatingOrder,

  /// 订单已创建，等待在收银台支付。
  awaitingPayment,

  /// 正在提交支付 / 取消订单。
  paying,

  /// 支付成功，VIP 已开通或续期。
  paid,
}

/// 驱动“选择套餐 → 下单 → 收银台支付 → 开通”的完整流程。
///
/// 当前收银台是模拟支付；接入真实渠道后，只需把 [mockPay] 换成
/// “拉起渠道支付 + 轮询 [refreshOrder]”，其余状态流转保持不变。
class VipPurchaseController extends ChangeNotifier {
  VipPurchaseController({
    required AccountSessionController account,
    required VipBillingRemote billing,
  }) : _account = account,
       _billing = billing;

  final AccountSessionController _account;
  final VipBillingRemote _billing;

  VipPurchaseStage _stage = VipPurchaseStage.loadingPlans;
  VipPlanCatalog? _catalog;
  String? _selectedPlanId;
  VipOrder? _order;
  String? _message;
  bool _disposed = false;

  VipPurchaseStage get stage => _stage;
  VipPlanCatalog? get catalog => _catalog;
  VipOrder? get order => _order;
  String? get message => _message;
  String? get selectedPlanId => _selectedPlanId;

  VipPlan? get selectedPlan {
    final plans = _catalog?.plans ?? const <VipPlan>[];
    for (final plan in plans) {
      if (plan.id == _selectedPlanId) return plan;
    }
    return null;
  }

  bool get busy =>
      _stage == VipPurchaseStage.loadingPlans ||
      _stage == VipPurchaseStage.creatingOrder ||
      _stage == VipPurchaseStage.paying;

  /// 当前服务端是否开放了客户端能处理的支付渠道。
  bool get canCheckout {
    final catalog = _catalog;
    return catalog != null &&
        catalog.paymentAvailable &&
        catalog.isMock &&
        selectedPlan != null &&
        !busy;
  }

  /// 收银台不可用时给用户的说明；可用时为 null。
  String? get checkoutUnavailableReason {
    final catalog = _catalog;
    if (catalog == null) return null;
    if (!catalog.paymentAvailable) return '支付通道暂未开放，请稍后再试。';
    if (!catalog.isMock) return '当前版本暂不支持该支付方式，请更新笺盒。';
    return null;
  }

  Future<void> loadPlans() async {
    // The first load runs from the dialog's initState; skip the redundant
    // notification when nothing visible changes.
    if (_stage != VipPurchaseStage.loadingPlans || _message != null) {
      _update(stage: VipPurchaseStage.loadingPlans, clearMessage: true);
    }
    try {
      final catalog = await _billing.fetchVipPlans();
      _catalog = catalog;
      final stillValid = catalog.plans.any(
        (plan) => plan.id == _selectedPlanId,
      );
      if (!stillValid) {
        _selectedPlanId = catalog.plans.isEmpty
            ? null
            : catalog.plans.first.id;
      }
      _update(stage: VipPurchaseStage.choosingPlan);
    } on Object catch (error) {
      _update(
        stage: VipPurchaseStage.plansUnavailable,
        message: _messageFor(error),
      );
    }
  }

  void selectPlan(String planId) {
    if (busy || _stage != VipPurchaseStage.choosingPlan) return;
    _selectedPlanId = planId;
    _update(clearMessage: true);
  }

  Future<void> checkout() async {
    final plan = selectedPlan;
    if (!canCheckout || plan == null) return;
    _update(stage: VipPurchaseStage.creatingOrder, clearMessage: true);
    try {
      final order = await _account.authorizedRequest(
        (token) =>
            _billing.createVipOrder(accessToken: token, planId: plan.id),
      );
      _order = order;
      _update(stage: VipPurchaseStage.awaitingPayment);
    } on Object catch (error) {
      _update(
        stage: VipPurchaseStage.choosingPlan,
        message: _messageFor(error),
      );
    }
  }

  /// 在模拟收银台上完成支付。[outcome] 为失败时订单保持待支付，可以重试。
  Future<void> mockPay(VipMockPaymentOutcome outcome) async {
    final order = _order;
    if (order == null || _stage != VipPurchaseStage.awaitingPayment) return;
    _update(stage: VipPurchaseStage.paying, clearMessage: true);
    try {
      final paid = await _account.authorizedRequest(
        (token) => _billing.mockPayVipOrder(
          accessToken: token,
          orderNo: order.orderNo,
          outcome: outcome,
        ),
      );
      await _completeIfPaid(paid);
    } on AccountApiException catch (error) {
      switch (error.code) {
        case 'ORDER_ALREADY_PAID':
          await refreshOrder();
        case 'ORDER_CLOSED':
        case 'ORDER_NOT_FOUND':
          _order = null;
          _update(
            stage: VipPurchaseStage.choosingPlan,
            message: _messageFor(error),
          );
        default:
          _update(
            stage: VipPurchaseStage.awaitingPayment,
            message: _messageFor(error),
          );
      }
    } on Object catch (error) {
      _update(
        stage: VipPurchaseStage.awaitingPayment,
        message: _messageFor(error),
      );
    }
  }

  /// 重新查询订单状态（真实渠道下用于支付后的轮询）。
  Future<void> refreshOrder() async {
    final order = _order;
    if (order == null) return;
    try {
      final latest = await _account.authorizedRequest(
        (token) =>
            _billing.fetchVipOrder(accessToken: token, orderNo: order.orderNo),
      );
      if (latest.status == VipOrderStatus.closed) {
        _order = null;
        _update(
          stage: VipPurchaseStage.choosingPlan,
          message: '订单已关闭，请重新下单。',
        );
        return;
      }
      if (latest.status == VipOrderStatus.pending) {
        _order = latest;
        _update(stage: VipPurchaseStage.awaitingPayment);
        return;
      }
      await _completeIfPaid(latest);
    } on Object catch (error) {
      _update(
        stage: VipPurchaseStage.awaitingPayment,
        message: _messageFor(error),
      );
    }
  }

  /// 取消当前订单并回到套餐选择。
  Future<void> cancelOrder() async {
    final order = _order;
    if (order == null || _stage != VipPurchaseStage.awaitingPayment) return;
    _update(stage: VipPurchaseStage.paying, clearMessage: true);
    try {
      await _account.authorizedRequest(
        (token) =>
            _billing.cancelVipOrder(accessToken: token, orderNo: order.orderNo),
      );
      _order = null;
      _update(stage: VipPurchaseStage.choosingPlan, message: '订单已取消。');
    } on AccountApiException catch (error) {
      if (error.code == 'ORDER_ALREADY_PAID') {
        await refreshOrder();
        return;
      }
      _update(
        stage: VipPurchaseStage.awaitingPayment,
        message: _messageFor(error),
      );
    } on Object catch (error) {
      _update(
        stage: VipPurchaseStage.awaitingPayment,
        message: _messageFor(error),
      );
    }
  }

  Future<void> _completeIfPaid(VipOrder order) async {
    _order = order;
    if (order.status != VipOrderStatus.paid) {
      _update(stage: VipPurchaseStage.awaitingPayment);
      return;
    }
    // 订单以服务端结果为准；刷新账号只是为了让面板立即显示新的权益，
    // 失败也不影响已经完成的支付。
    await _account.refreshAccount();
    _update(stage: VipPurchaseStage.paid, clearMessage: true);
  }

  String _messageFor(Object error) {
    if (error is AccountApiException) {
      // 请求 ID 只用于排查，不展示给用户。
      if (error.requestId != null) {
        debugPrint(
          'VIP purchase request failed (${error.code}, '
          'requestId: ${error.requestId})',
        );
      }
      return error.message;
    }
    if (error is FormatException) return '云服务返回了无法识别的数据。';
    return '支付处理失败，请重试。';
  }

  void _update({
    VipPurchaseStage? stage,
    String? message,
    bool clearMessage = false,
  }) {
    if (_disposed) return;
    if (stage != null) _stage = stage;
    if (clearMessage) {
      _message = null;
    } else if (message != null) {
      _message = message;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
