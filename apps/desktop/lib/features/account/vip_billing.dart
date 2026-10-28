/// VIP 购买相关的数据模型与远端接口。
///
/// 价格、套餐与支付渠道全部由服务端下发；客户端只负责展示与驱动流程，
/// 因此调整价格或切换到真实支付渠道时不必重新发布客户端。
library;

/// 服务端当前启用的模拟支付渠道标识。
const String vipMockPaymentProvider = 'mock';

class VipPlan {
  const VipPlan({
    required this.id,
    required this.name,
    required this.amountCents,
    required this.amount,
    required this.months,
    required this.lifetime,
  });

  factory VipPlan.fromJson(Map<String, Object?> json) {
    return VipPlan(
      id: _string(json, 'id'),
      name: _string(json, 'name'),
      amountCents: _int(json, 'amount_cents'),
      amount: _string(json, 'amount'),
      months: _int(json, 'months'),
      lifetime: _bool(json, 'lifetime'),
    );
  }

  final String id;
  final String name;
  final int amountCents;

  /// 以“元”为单位的展示金额，例如 `5.98`。
  final String amount;
  final int months;
  final bool lifetime;

  /// 套餐时长的人类可读描述。
  String get durationLabel {
    if (lifetime) return '一次购买，永久有效';
    if (months % 12 == 0) return '${months ~/ 12} 年';
    return '$months 个月';
  }

  /// 折算后的月均价格（仅多月套餐有意义）。
  String? get monthlyLabel {
    if (lifetime || months <= 1) return null;
    final perMonth = amountCents / months / 100;
    return '约 ¥${perMonth.toStringAsFixed(2)}/月';
  }
}

class VipPlanCatalog {
  const VipPlanCatalog({
    required this.plans,
    required this.provider,
    required this.paymentAvailable,
  });

  factory VipPlanCatalog.fromJson(Map<String, Object?> json) {
    final rawPlans = json['plans'];
    if (rawPlans is! List) throw const FormatException('Missing plans.');
    return VipPlanCatalog(
      plans: <VipPlan>[
        for (final item in rawPlans) VipPlan.fromJson(_map(item, 'plans')),
      ],
      provider: (json['provider'] as String?) ?? '',
      paymentAvailable: _bool(json, 'payment_available'),
    );
  }

  final List<VipPlan> plans;
  final String provider;
  final bool paymentAvailable;

  bool get isMock => provider == vipMockPaymentProvider;
}

enum VipOrderStatus { pending, paid, closed }

class VipOrder {
  const VipOrder({
    required this.orderNo,
    required this.plan,
    required this.planName,
    required this.amountCents,
    required this.amount,
    required this.provider,
    required this.status,
    required this.createdAt,
    required this.expiresAt,
    this.paidAt,
    this.closedAt,
    this.vipExpiresAfter,
    this.vipLifetime = false,
  });

  factory VipOrder.fromJson(Map<String, Object?> json) {
    final status = switch (_string(json, 'status')) {
      'pending' => VipOrderStatus.pending,
      'paid' => VipOrderStatus.paid,
      'closed' => VipOrderStatus.closed,
      _ => throw const FormatException('Invalid order status.'),
    };
    return VipOrder(
      orderNo: _string(json, 'order_no'),
      plan: _string(json, 'plan'),
      planName: (json['plan_name'] as String?) ?? '',
      amountCents: _int(json, 'amount_cents'),
      amount: _string(json, 'amount'),
      provider: _string(json, 'provider'),
      status: status,
      createdAt: _dateTime(json, 'created_at')!,
      expiresAt: _dateTime(json, 'expires_at')!,
      paidAt: _dateTime(json, 'paid_at', optional: true),
      closedAt: _dateTime(json, 'closed_at', optional: true),
      vipExpiresAfter: _dateTime(json, 'vip_expires_after', optional: true),
      vipLifetime: (json['vip_lifetime'] as bool?) ?? false,
    );
  }

  final String orderNo;
  final String plan;
  final String planName;
  final int amountCents;
  final String amount;
  final String provider;
  final VipOrderStatus status;
  final DateTime createdAt;

  /// 未支付订单的关闭时间。
  final DateTime expiresAt;
  final DateTime? paidAt;
  final DateTime? closedAt;

  /// 支付成功后账号的 VIP 到期时间。
  final DateTime? vipExpiresAfter;
  final bool vipLifetime;
}

/// 模拟收银台上用户选择的支付结果；接入真实渠道后由渠道回调替代。
enum VipMockPaymentOutcome { success, fail }

abstract interface class VipBillingRemote {
  Future<VipPlanCatalog> fetchVipPlans();

  Future<VipOrder> createVipOrder({
    required String accessToken,
    required String planId,
  });

  Future<VipOrder> fetchVipOrder({
    required String accessToken,
    required String orderNo,
  });

  Future<VipOrder> cancelVipOrder({
    required String accessToken,
    required String orderNo,
  });

  Future<VipOrder> mockPayVipOrder({
    required String accessToken,
    required String orderNo,
    required VipMockPaymentOutcome outcome,
  });
}

Map<String, Object?> _map(Object? value, String key) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  throw FormatException('Missing or invalid $key.');
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('Missing or invalid $key.');
}

int _int(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) return value;
  throw FormatException('Missing or invalid $key.');
}

bool _bool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  throw FormatException('Missing or invalid $key.');
}

DateTime? _dateTime(
  Map<String, Object?> json,
  String key, {
  bool optional = false,
}) {
  final value = json[key];
  if (value == null && optional) return null;
  if (value is! String) throw FormatException('Missing or invalid $key.');
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('Invalid $key.');
  return parsed.toUtc();
}
