/// VIP 购买相关的数据模型与远端接口。
///
/// 购买入口（国内 / 海外）、价格、币种、支付方式全部由服务端下发；
/// 客户端只负责展示与驱动流程，因此调整价格或接入新的支付渠道时不必
/// 重新发布客户端，客户端代码里也不出现任何具体的支付渠道。
library;

/// 国内入口（人民币）。
const String vipMarketCN = 'cn';

/// 海外入口（美元）。
const String vipMarketIntl = 'intl';

/// 金额的展示形式，例如 `¥5.98`、`US$1.49`。
String formatVipPrice(String currency, String amount) => switch (currency) {
  'CNY' => '¥$amount',
  'USD' => 'US\$$amount',
  _ => '$currency $amount',
};

class VipPlan {
  const VipPlan({
    required this.id,
    required this.name,
    required this.market,
    required this.currency,
    required this.amountCents,
    required this.amount,
    required this.months,
    required this.lifetime,
    this.recommended = false,
    this.regularAmount,
    this.regularAmountCents,
  });

  factory VipPlan.fromJson(Map<String, Object?> json) {
    return VipPlan(
      id: _string(json, 'id'),
      name: _string(json, 'name'),
      // Servers before purchase entries only sold in CNY.
      market: (json['market'] as String?) ?? vipMarketCN,
      currency: (json['currency'] as String?) ?? 'CNY',
      amountCents: _int(json, 'amount_cents'),
      amount: _string(json, 'amount'),
      months: _int(json, 'months'),
      lifetime: _bool(json, 'lifetime'),
      // Older servers send neither field.
      recommended: (json['recommended'] as bool?) ?? false,
      regularAmount: switch (json['regular_amount']) {
        final String value when value.isNotEmpty => value,
        _ => null,
      },
      regularAmountCents: switch (json['regular_amount_cents']) {
        final int value when value > 0 => value,
        _ => null,
      },
    );
  }

  final String id;

  /// 服务端给出的套餐名，仅在客户端不认识 [id] 时展示。
  final String name;
  final String market;
  final String currency;

  /// 以币种最小单位（分 / 美分）计的金额。
  final int amountCents;

  /// 展示金额，例如 `5.98`。
  final String amount;
  final int months;
  final bool lifetime;

  /// 服务端推荐的套餐：突出显示，并在打开购买页时默认选中。
  final bool recommended;

  /// 早鸟活动期间的正式价格（不带币种符号）；没有早鸟活动时为 null。
  final String? regularAmount;

  /// 早鸟活动期间的正式价格（分 / 美分）；没有早鸟活动时为 null。
  final int? regularAmountCents;

  /// 是否正在以早鸟价销售。
  bool get earlyBird => regularAmount != null;

  /// 早鸟价比正式价便宜的金额，带币种符号且省略整数后的 `.00`，例如 `¥20`；
  /// 没有早鸟活动时为 null。
  String? get savings {
    final regular = regularAmountCents;
    if (regular == null || regular <= amountCents) return null;
    return formatVipPrice(currency, _trimCents(regular - amountCents));
  }

  /// 早鸟价相对正式价的优惠百分比（向下取整，例如 30 表示 7 折）。
  int? get percentOff {
    final regular = regularAmountCents;
    if (regular == null || regular <= amountCents) return null;
    return ((regular - amountCents) * 100) ~/ regular;
  }

  /// 带币种符号的正式价格，例如 `¥298.00`；不是早鸟套餐时为 null。
  String? get regularPrice =>
      regularAmount == null ? null : formatVipPrice(currency, regularAmount!);

  /// 带币种符号的价格，例如 `¥5.98`。
  String get price => formatVipPrice(currency, amount);

  /// 折算后的月均价格（仅多月套餐有意义），带币种符号。
  String? get monthlyPrice {
    if (lifetime || months <= 1) return null;
    final perMonth = amountCents / months / 100;
    return formatVipPrice(currency, perMonth.toStringAsFixed(2));
  }
}

/// 客户端知道如何处理的支付动作。
enum VipPayActionType {
  /// 展示二维码，用手机扫码支付。
  qr,

  /// 在系统浏览器中打开收银台页面。
  url,

  /// 当前版本不认识的动作，需要更新客户端。
  unsupported;

  static VipPayActionType parse(String? value) => switch (value) {
    'qr' => qr,
    'url' => url,
    _ => unsupported,
  };
}

/// 某个购买入口下的一种支付方式；名称由服务端下发。
class VipPayMethod {
  const VipPayMethod({
    required this.id,
    required this.name,
    required this.action,
    required this.mock,
  });

  factory VipPayMethod.fromJson(Map<String, Object?> json) => VipPayMethod(
    id: _string(json, 'id'),
    name: _string(json, 'name'),
    action: VipPayActionType.parse(json['action'] as String?),
    mock: (json['mock'] as bool?) ?? false,
  );

  final String id;
  final String name;
  final VipPayActionType action;

  /// 模拟支付方式，不会产生真实扣款。
  final bool mock;
}

/// 一个购买入口（国内 / 海外）：独立的币种、价格和支付方式。
class VipMarket {
  const VipMarket({
    required this.id,
    required this.currency,
    required this.plans,
    required this.methods,
  });

  factory VipMarket.fromJson(Map<String, Object?> json) {
    return VipMarket(
      id: _string(json, 'id'),
      currency: _string(json, 'currency'),
      plans: <VipPlan>[
        for (final item in _list(json, 'plans'))
          VipPlan.fromJson(_map(item, 'plans')),
      ],
      methods: <VipPayMethod>[
        for (final item in _list(json, 'methods'))
          VipPayMethod.fromJson(_map(item, 'methods')),
      ],
    );
  }

  final String id;
  final String currency;
  final List<VipPlan> plans;
  final List<VipPayMethod> methods;
}

/// 服务端下发的客服联系方式，用于订单和退款问题；字段均可能为空。
class VipSupportContact {
  const VipSupportContact({this.email, this.wechat, this.phone});

  /// 解析 `support` 字段；缺失或格式不对时返回 null，不影响购买。
  static VipSupportContact? tryParse(Object? json) {
    if (json is! Map) return null;
    String? field(String key) {
      final value = json[key];
      if (value is! String) return null;
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    final contact = VipSupportContact(
      email: field('email'),
      wechat: field('wechat'),
      phone: field('phone'),
    );
    return contact.isEmpty ? null : contact;
  }

  final String? email;
  final String? wechat;
  final String? phone;

  bool get isEmpty => email == null && wechat == null && phone == null;
}

class VipPlanCatalog {
  const VipPlanCatalog({
    required this.markets,
    required this.paymentAvailable,
    this.termsVersion,
    this.termsUrl,
    this.earlyBirdEndsAt,
    this.support,
  });

  factory VipPlanCatalog.fromJson(Map<String, Object?> json) {
    if (json['plans'] is! List) throw const FormatException('Missing plans.');
    final rawMarkets = json['markets'];
    final termsUrl = json['terms_url'];
    return VipPlanCatalog(
      // A server without purchase entries cannot take this client's orders,
      // so it simply offers no entry.
      markets: rawMarkets is List
          ? <VipMarket>[
              for (final item in rawMarkets)
                VipMarket.fromJson(_map(item, 'markets')),
            ]
          : const <VipMarket>[],
      paymentAvailable: _bool(json, 'payment_available'),
      termsVersion: json['terms_version'] as String?,
      termsUrl: termsUrl is String ? Uri.tryParse(termsUrl) : null,
      earlyBirdEndsAt: switch (json['early_bird_ends_at']) {
        final String value => DateTime.tryParse(value),
        _ => null,
      },
      support: VipSupportContact.tryParse(json['support']),
    );
  }

  /// 有可用支付方式的购买入口，按展示顺序排列。
  final List<VipMarket> markets;
  final bool paymentAvailable;

  /// 下单时必须回传的服务条款版本。
  final String? termsVersion;

  /// 含 VIP 会员条款的服务条款页面。
  final Uri? termsUrl;

  /// 早鸟活动的结束时刻（不含）；没有早鸟活动或服务端较旧时为 null。
  final DateTime? earlyBirdEndsAt;

  /// 客服联系方式；服务端未配置或较旧时为 null。
  final VipSupportContact? support;

  VipMarket? market(String? id) {
    for (final market in markets) {
      if (market.id == id) return market;
    }
    return null;
  }
}

enum VipOrderStatus { pending, paid, closed }

/// 服务端告诉客户端如何支付一笔待支付订单。
class VipPayAction {
  const VipPayAction({required this.type, required this.value});

  factory VipPayAction.fromJson(Map<String, Object?> json) => VipPayAction(
    type: VipPayActionType.parse(json['type'] as String?),
    value: _string(json, 'value'),
  );

  final VipPayActionType type;

  /// 二维码内容或收银台地址。
  final String value;
}

class VipOrder {
  const VipOrder({
    required this.orderNo,
    required this.plan,
    required this.planName,
    required this.market,
    required this.currency,
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
    this.payAction,
  });

  factory VipOrder.fromJson(Map<String, Object?> json) {
    final status = switch (_string(json, 'status')) {
      'pending' => VipOrderStatus.pending,
      'paid' => VipOrderStatus.paid,
      'closed' => VipOrderStatus.closed,
      _ => throw const FormatException('Invalid order status.'),
    };
    final payAction = json['pay_action'];
    return VipOrder(
      orderNo: _string(json, 'order_no'),
      plan: _string(json, 'plan'),
      planName: (json['plan_name'] as String?) ?? '',
      market: (json['market'] as String?) ?? vipMarketCN,
      currency: (json['currency'] as String?) ?? 'CNY',
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
      payAction: payAction == null
          ? null
          : VipPayAction.fromJson(_map(payAction, 'pay_action')),
    );
  }

  final String orderNo;
  final String plan;
  final String planName;
  final String market;
  final String currency;
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

  /// 待支付订单的支付动作；已支付或已关闭的订单为 null。
  final VipPayAction? payAction;

  /// 带币种符号的金额，例如 `¥29.98`。
  String get price => formatVipPrice(currency, amount);
}

/// 模拟收银台上用户选择的支付结果；接入真实渠道后由渠道回调替代。
enum VipMockPaymentOutcome { success, fail }

abstract interface class VipBillingRemote {
  Future<VipPlanCatalog> fetchVipPlans();

  /// 下单。[methodId] 决定购买入口，从而决定价格与币种；
  /// [termsVersion] 是用户勾选同意的服务条款版本。
  Future<VipOrder> createVipOrder({
    required String accessToken,
    required String planId,
    required String methodId,
    required String termsVersion,
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

List<Object?> _list(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is List) return value;
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

/// `2000` → `20`，`1999` → `19.99`。
String _trimCents(int cents) {
  final whole = cents ~/ 100;
  final rest = cents % 100;
  return rest == 0 ? '$whole' : '$whole.${rest.toString().padLeft(2, '0')}';
}
