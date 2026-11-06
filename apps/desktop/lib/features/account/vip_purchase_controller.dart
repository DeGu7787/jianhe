import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../l10n/app_strings.dart';
import 'account_api.dart';
import 'account_session_controller.dart';
import 'vip_billing.dart';

enum VipPurchaseStage {
  /// 正在拉取套餐列表。
  loadingPlans,

  /// 套餐列表加载失败，可重试。
  plansUnavailable,

  /// 用户正在选择入口、套餐和支付方式。
  choosingPlan,

  /// 正在创建订单。
  creatingOrder,

  /// 订单已创建，等待在收银台支付。
  awaitingPayment,

  /// 正在提交支付 / 取消订单 / 查询结果。
  paying,

  /// 支付成功，VIP 已开通或续期。
  paid,
}

/// 驱动“选择入口和套餐 → 同意条款 → 下单 → 支付 → 开通”的完整流程。
///
/// 支付方式由服务端下发：二维码类展示二维码，网页类在浏览器中打开收银台。
/// 用户在手机或浏览器中付款后，订单状态由轮询 [refreshOrder] 得到，
/// 以服务端为准；模拟支付方式另外提供应用内的 [mockPay]。
class VipPurchaseController extends ChangeNotifier {
  VipPurchaseController({
    required AccountSessionController account,
    required VipBillingRemote billing,
    String? preferredMarket,
    bool lockMarket = false,
    Duration? pollInterval = const Duration(seconds: 3),
  }) : _account = account,
       _billing = billing,
       _preferredMarket = preferredMarket,
       _lockMarket = lockMarket,
       _pollInterval = pollInterval;

  final AccountSessionController _account;
  final VipBillingRemote _billing;
  final String? _preferredMarket;

  /// 只提供 [_preferredMarket] 这一个入口（购买弹窗按界面语言锁定）。
  /// 服务端没有该入口时显示“支付通道暂未开放”，不会改用其他入口。
  final bool _lockMarket;
  final Duration? _pollInterval;

  VipPurchaseStage _stage = VipPurchaseStage.loadingPlans;
  VipPlanCatalog? _catalog;
  String? _marketId;
  String? _selectedPlanId;
  String? _methodId;
  bool _termsAccepted = false;
  VipOrder? _order;
  String? _message;
  Timer? _pollTimer;
  bool _polling = false;
  bool _disposed = false;

  AppStrings get _s => AppStrings.current;

  VipPurchaseStage get stage => _stage;
  VipPlanCatalog? get catalog => _catalog;
  VipOrder? get order => _order;
  String? get message => _message;
  String? get selectedPlanId => _selectedPlanId;
  bool get termsAccepted => _termsAccepted;

  /// 当前选中的购买入口。
  VipMarket? get market => _catalog?.market(_marketId);

  /// 可以切换到的另一个购买入口；只有一个入口或入口被锁定时为 null。
  VipMarket? get alternativeMarket {
    if (_lockMarket) return null;
    for (final candidate in _catalog?.markets ?? const <VipMarket>[]) {
      if (candidate.id != _marketId) return candidate;
    }
    return null;
  }

  VipPlan? get selectedPlan {
    for (final plan in market?.plans ?? const <VipPlan>[]) {
      if (plan.id == _selectedPlanId) return plan;
    }
    return null;
  }

  VipPayMethod? get selectedMethod => _methodFor(_methodId);

  /// 当前订单使用的支付方式（若仍在目录中）。
  VipPayMethod? get orderMethod => _methodFor(_order?.provider);

  VipPayMethod? _methodFor(String? id) {
    for (final market in _catalog?.markets ?? const <VipMarket>[]) {
      for (final method in market.methods) {
        if (method.id == id) return method;
      }
    }
    return null;
  }

  bool get busy =>
      _stage == VipPurchaseStage.loadingPlans ||
      _stage == VipPurchaseStage.creatingOrder ||
      _stage == VipPurchaseStage.paying;

  /// 是否满足下单条件：选好了套餐和客户端能处理的支付方式，且已同意条款。
  bool get canCheckout =>
      checkoutUnavailableReason == null &&
      selectedPlan != null &&
      _termsAccepted &&
      !busy;

  /// 无法下单时给用户的说明；可以下单（或只差勾选条款）时为 null。
  String? get checkoutUnavailableReason {
    final catalog = _catalog;
    if (catalog == null) return null;
    if (!catalog.paymentAvailable || catalog.markets.isEmpty) {
      return _s.vipPaymentUnavailable;
    }
    // 锁定的入口尚未开放：不改用其他入口。
    if (_lockMarket && catalog.market(_preferredMarket) == null) {
      return _s.vipPaymentUnavailable;
    }
    final method = selectedMethod;
    if (catalog.termsVersion == null ||
        method == null ||
        method.action == VipPayActionType.unsupported) {
      return _s.vipUpdateRequired;
    }
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
      if (_lockMarket) {
        _applyMarket(catalog.market(_preferredMarket));
      } else {
        final keep =
            catalog.market(_marketId) ?? catalog.market(_preferredMarket);
        _applyMarket(
          keep ?? (catalog.markets.isEmpty ? null : catalog.markets.first),
        );
      }
      _update(stage: VipPurchaseStage.choosingPlan);
    } on Object catch (error) {
      _update(
        stage: VipPurchaseStage.plansUnavailable,
        message: _messageFor(error),
      );
    }
  }

  /// 切换购买入口；尽量保留同一个套餐。
  void selectMarket(String marketId) {
    if (busy || _stage != VipPurchaseStage.choosingPlan) return;
    final next = _catalog?.market(marketId);
    if (next == null || next.id == _marketId) return;
    if (_lockMarket && next.id != _preferredMarket) return;
    _applyMarket(next);
    _update(clearMessage: true);
  }

  void _applyMarket(VipMarket? next) {
    _marketId = next?.id;
    final plans = next?.plans ?? const <VipPlan>[];
    if (!plans.any((plan) => plan.id == _selectedPlanId)) {
      final recommended = plans.where((plan) => plan.recommended);
      _selectedPlanId = recommended.isNotEmpty
          ? recommended.first.id
          : plans.isEmpty
          ? null
          : plans.first.id;
    }
    final methods = next?.methods ?? const <VipPayMethod>[];
    if (!methods.any((method) => method.id == _methodId)) {
      _methodId = methods.isEmpty ? null : methods.first.id;
    }
  }

  void selectPlan(String planId) {
    if (busy || _stage != VipPurchaseStage.choosingPlan) return;
    _selectedPlanId = planId;
    _update(clearMessage: true);
  }

  void selectMethod(String methodId) {
    if (busy || _stage != VipPurchaseStage.choosingPlan) return;
    if (!(market?.methods.any((method) => method.id == methodId) ?? false)) {
      return;
    }
    _methodId = methodId;
    _update(clearMessage: true);
  }

  void setTermsAccepted(bool accepted) {
    if (busy || _stage != VipPurchaseStage.choosingPlan) return;
    _termsAccepted = accepted;
    _update();
  }

  Future<void> checkout() async {
    final plan = selectedPlan;
    final method = selectedMethod;
    final termsVersion = _catalog?.termsVersion;
    if (!canCheckout ||
        plan == null ||
        method == null ||
        termsVersion == null) {
      return;
    }
    _update(stage: VipPurchaseStage.creatingOrder, clearMessage: true);
    try {
      final order = await _account.authorizedRequest(
        (token) => _billing.createVipOrder(
          accessToken: token,
          planId: plan.id,
          methodId: method.id,
          termsVersion: termsVersion,
        ),
      );
      _order = order;
      _update(stage: VipPurchaseStage.awaitingPayment);
      _startPolling();
      if (order.payAction?.type == VipPayActionType.url) {
        await openPayPage();
      }
    } on Object catch (error) {
      _update(
        stage: VipPurchaseStage.choosingPlan,
        message: _messageFor(error),
      );
    }
  }

  /// 在浏览器中（重新）打开当前订单的收银台页面。
  Future<void> openPayPage() async {
    final action = _order?.payAction;
    if (action == null || action.type != VipPayActionType.url) return;
    final uri = Uri.tryParse(action.value);
    if (uri == null || !(uri.isScheme('https') || uri.isScheme('http'))) {
      _update(message: _s.vipUpdateRequired);
      return;
    }
    try {
      await _account.openInBrowser(uri);
    } on Object catch (error) {
      _update(message: _messageFor(error));
    }
  }

  /// 在应用内模拟支付结果（仅模拟支付方式）。[outcome] 为失败时订单
  /// 保持待支付，可以重试。
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
          _orderGone(_messageFor(error));
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

  /// 用户点“我已完成支付”：查询一次订单；还没到账时提示用户。
  Future<void> confirmPaid() async {
    if (_order == null || _stage != VipPurchaseStage.awaitingPayment) return;
    _update(stage: VipPurchaseStage.paying, clearMessage: true);
    await refreshOrder();
    if (_stage == VipPurchaseStage.awaitingPayment && _message == null) {
      _update(message: _s.vipNotPaidYet);
    }
  }

  /// 重新查询订单状态，以服务端为准。
  Future<void> refreshOrder() async {
    final order = _order;
    if (order == null) return;
    try {
      final latest = await _account.authorizedRequest(
        (token) =>
            _billing.fetchVipOrder(accessToken: token, orderNo: order.orderNo),
      );
      if (_order?.orderNo != order.orderNo) return;
      if (latest.status == VipOrderStatus.closed) {
        _orderGone(_s.vipOrderClosed);
        return;
      }
      if (latest.status == VipOrderStatus.pending) {
        // Keep the pay action handed out at checkout if a later read omits it.
        _order = latest.payAction == null ? order : latest;
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
      _orderGone(_s.vipOrderCancelled);
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

  void _orderGone(String message) {
    _stopPolling();
    _order = null;
    _update(stage: VipPurchaseStage.choosingPlan, message: message);
  }

  /// Payment happens on a phone or in the browser, so the order is polled
  /// while the cashier is open. A poll that finds nothing new stays silent.
  void _startPolling() {
    final interval = _pollInterval;
    _stopPolling();
    if (interval == null) return;
    _pollTimer = Timer.periodic(interval, (_) => _poll());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _poll() async {
    final order = _order;
    if (_polling ||
        order == null ||
        _stage != VipPurchaseStage.awaitingPayment) {
      return;
    }
    _polling = true;
    try {
      final latest = await _account.authorizedRequest(
        (token) =>
            _billing.fetchVipOrder(accessToken: token, orderNo: order.orderNo),
      );
      if (_disposed ||
          _order?.orderNo != order.orderNo ||
          _stage != VipPurchaseStage.awaitingPayment) {
        return;
      }
      if (latest.status == VipOrderStatus.paid) {
        await _completeIfPaid(latest);
      } else if (latest.status == VipOrderStatus.closed) {
        _orderGone(_s.vipOrderClosed);
      }
    } on Object {
      // Transient poll failures are ignored; the next poll or the user's
      // "I've paid" tap tries again.
    } finally {
      _polling = false;
    }
  }

  Future<void> _completeIfPaid(VipOrder order) async {
    _order = order;
    if (order.status != VipOrderStatus.paid) {
      _update(stage: VipPurchaseStage.awaitingPayment);
      return;
    }
    _stopPolling();
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
    if (error is FormatException) return _s.vipBadResponse;
    return _s.vipPaymentFailed;
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
    _stopPolling();
    super.dispose();
  }
}
