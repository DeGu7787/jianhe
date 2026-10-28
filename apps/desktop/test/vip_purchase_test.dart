import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jianhe_core/jianhe_core.dart';
import 'package:jianhe_desktop/features/account/account_api.dart';
import 'package:jianhe_desktop/features/account/account_models.dart';
import 'package:jianhe_desktop/features/account/account_panel.dart';
import 'package:jianhe_desktop/features/account/account_session_controller.dart';
import 'package:jianhe_desktop/features/account/refresh_token_store.dart';
import 'package:jianhe_desktop/features/account/vip_billing.dart';
import 'package:jianhe_desktop/features/account/vip_purchase_controller.dart';
import 'package:jianhe_desktop/l10n/app_language_scope.dart';
import 'package:jianhe_desktop/l10n/app_strings.dart';

const _orderNo = 'JHVIP20261013080000abcdef012345';

void main() {
  group('AccountApi billing', () {
    http.Response jsonResponse(Object body, int status) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: const <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );

    test('fetches the server price list', () async {
      final api = AccountApi(
        baseUri: Uri.parse('https://jianhe.neodaas.com'),
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/v1/billing/plans');
          expect(request.headers.containsKey('authorization'), isFalse);
          return jsonResponse(_catalogJson(), 200);
        }),
      );
      final catalog = await api.fetchVipPlans();
      expect(catalog.isMock, isTrue);
      expect(catalog.paymentAvailable, isTrue);
      expect(catalog.plans.map((plan) => plan.amount), <String>[
        '5.98',
        '9.98',
        '29.98',
        '59.98',
      ]);
      expect(catalog.plans[1].monthlyLabel, '约 ¥3.33/月');
      expect(catalog.plans[2].durationLabel, '1 年');
      expect(catalog.plans[3].durationLabel, '一次购买，永久有效');
    });

    test('creates orders and posts mock payments with the token', () async {
      final requests = <http.Request>[];
      final api = AccountApi(
        baseUri: Uri.parse('https://jianhe.neodaas.com'),
        client: MockClient((request) async {
          requests.add(request);
          expect(request.headers['authorization'], 'Bearer access');
          if (request.url.path == '/v1/billing/orders') {
            return jsonResponse(_orderJson('pending'), 201);
          }
          if (request.url.path == '/v1/billing/orders/$_orderNo/mock-pay') {
            final outcome = (jsonDecode(request.body) as Map)['outcome'];
            if (outcome == 'fail') {
              return jsonResponse(<String, Object?>{
                'error': <String, Object?>{
                  'code': 'MOCK_PAYMENT_FAILED',
                  'message': '模拟支付失败：订单仍未支付，可以重试。',
                  'request_id': 'req-1',
                  'retryable': true,
                  'details': <String, Object?>{},
                },
              }, 402);
            }
            return jsonResponse(_orderJson('paid'), 200);
          }
          return jsonResponse(<String, Object?>{}, 404);
        }),
      );

      final order = await api.createVipOrder(
        accessToken: 'access',
        planId: 'year',
      );
      expect(jsonDecode(requests.single.body), <String, Object?>{
        'plan': 'year',
      });
      expect(order.status, VipOrderStatus.pending);
      expect(order.amount, '29.98');

      await expectLater(
        api.mockPayVipOrder(
          accessToken: 'access',
          orderNo: _orderNo,
          outcome: VipMockPaymentOutcome.fail,
        ),
        throwsA(
          isA<AccountApiException>().having(
            (error) => error.code,
            'code',
            'MOCK_PAYMENT_FAILED',
          ),
        ),
      );
      final paid = await api.mockPayVipOrder(
        accessToken: 'access',
        orderNo: _orderNo,
        outcome: VipMockPaymentOutcome.success,
      );
      expect(paid.status, VipOrderStatus.paid);
      expect(paid.vipExpiresAfter, DateTime.utc(2027, 10, 13, 8));
    });
  });

  test('entitlement recognises lifetime VIP', () {
    final explicit = AccountEntitlement.fromJson(<String, Object?>{
      'plan': 'vip',
      'vip_expires_at': '9999-01-01T00:00:00Z',
      'vip_lifetime': true,
      'cloud_backup_upload_allowed': true,
      'cloud_backup_download_allowed': true,
    });
    expect(explicit.vipLifetime, isTrue);
    // Older servers omit vip_lifetime; the sentinel date still counts.
    final inferred = AccountEntitlement.fromJson(<String, Object?>{
      'plan': 'vip',
      'vip_expires_at': '9999-01-01T08:00:00+08:00',
      'cloud_backup_upload_allowed': true,
      'cloud_backup_download_allowed': true,
    });
    expect(inferred.vipLifetime, isTrue);
  });

  test('controller keeps the order payable after a failed payment', () async {
    final api = _FakeBillingAccountApi();
    final account = await _signedIn(api);
    final controller = VipPurchaseController(account: account, billing: api);
    addTearDown(controller.dispose);

    await controller.loadPlans();
    expect(controller.stage, VipPurchaseStage.choosingPlan);
    expect(controller.selectedPlanId, 'month');
    controller.selectPlan('quarter');
    await controller.checkout();
    expect(controller.stage, VipPurchaseStage.awaitingPayment);
    expect(api.createdPlans, <String>['quarter']);

    await controller.mockPay(VipMockPaymentOutcome.fail);
    expect(controller.stage, VipPurchaseStage.awaitingPayment);
    expect(controller.message, contains('模拟支付失败'));
    expect(account.account!.entitlement.isVip, isFalse);

    await controller.mockPay(VipMockPaymentOutcome.success);
    expect(controller.stage, VipPurchaseStage.paid);
    expect(controller.message, isNull);
    // The panel reflects the new entitlement without a manual refresh.
    expect(account.account!.entitlement.isVip, isTrue);
  });

  test('controller returns to the plan list when the order closed', () async {
    final api = _FakeBillingAccountApi(closeOrders: true);
    final account = await _signedIn(api);
    final controller = VipPurchaseController(account: account, billing: api);
    addTearDown(controller.dispose);

    await controller.loadPlans();
    await controller.checkout();
    await controller.mockPay(VipMockPaymentOutcome.success);
    expect(controller.stage, VipPurchaseStage.choosingPlan);
    expect(controller.order, isNull);
    expect(controller.message, contains('订单已关闭'));
  });

  test('checkout is blocked when the server has no payment channel', () async {
    final api = _FakeBillingAccountApi(paymentAvailable: false);
    final account = await _signedIn(api);
    final controller = VipPurchaseController(account: account, billing: api);
    addTearDown(controller.dispose);

    await controller.loadPlans();
    expect(controller.canCheckout, isFalse);
    expect(controller.checkoutUnavailableReason, contains('支付通道暂未开放'));
    await controller.checkout();
    expect(api.createdPlans, isEmpty);
  });

  testWidgets('free user buys a year of VIP through the mock cashier', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(450, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeBillingAccountApi();
    final account = await _signedIn(api);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: AccountPanel(controller: account))),
    );
    await tester.pumpAndSettle();
    expect(find.text('当前为免费账号'), findsOneWidget);
    expect(find.text('开通 VIP'), findsOneWidget);

    await tester.tap(find.byKey(const Key('vip-purchase')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('vip-purchase-dialog')), findsOneWidget);
    expect(find.text('¥5.98'), findsOneWidget);
    expect(find.text('¥9.98'), findsOneWidget);
    expect(find.text('¥29.98'), findsOneWidget);
    expect(find.text('¥59.98'), findsOneWidget);

    await tester.tap(find.byKey(const Key('vip-plan-year')));
    await tester.pump();
    expect(find.text('去支付 ¥29.98'), findsOneWidget);
    await tester.tap(find.byKey(const Key('vip-checkout')));
    await tester.pumpAndSettle();

    expect(find.text('模拟收银台'), findsOneWidget);
    expect(find.byKey(const Key('vip-mock-banner')), findsOneWidget);
    expect(find.byKey(const Key('vip-cashier-amount')), findsOneWidget);
    expect(find.text(_orderNo), findsOneWidget);

    await tester.tap(find.byKey(const Key('vip-mock-pay-fail')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('vip-purchase-message')), findsOneWidget);
    expect(find.text('模拟收银台'), findsOneWidget);

    await tester.tap(find.byKey(const Key('vip-mock-pay-success')));
    await tester.pumpAndSettle();
    expect(find.text('支付成功'), findsOneWidget);
    expect(find.byKey(const Key('vip-paid-summary')), findsOneWidget);

    await tester.tap(find.byKey(const Key('vip-purchase-done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('vip-purchase-dialog')), findsNothing);
    expect(find.text('VIP 服务已开通'), findsOneWidget);
    expect(find.text('续费 / 升级 VIP'), findsOneWidget);
    expect(api.createdPlans, <String>['year']);
  });

  testWidgets('lifetime VIP is shown and cannot be bought again', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(450, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeBillingAccountApi()..vipExpiresAt = DateTime.utc(9999);
    final account = await _signedIn(api);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: AccountPanel(controller: account))),
    );
    await tester.pumpAndSettle();
    expect(find.text('永久 VIP 已开通'), findsOneWidget);
    expect(find.text('永久有效'), findsOneWidget);
    expect(find.byKey(const Key('vip-purchase')), findsNothing);
  });

  testWidgets('the English interface shows the account but no purchase', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(450, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    AppStrings.setCurrentLanguage(AppLanguage.en);
    addTearDown(() => AppStrings.setCurrentLanguage(AppLanguage.zh));
    final api = _FakeBillingAccountApi();
    final account = await _signedIn(api);

    await tester.pumpWidget(
      AppLanguageScope(
        language: AppLanguage.en,
        child: MaterialApp(
          home: Scaffold(body: AccountPanel(controller: account)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Free account'), findsOneWidget);
    expect(find.text('Refresh account status'), findsOneWidget);
    expect(find.byKey(const Key('vip-purchase')), findsNothing);
    expect(find.text('当前为免费账号'), findsNothing);
  });
}

Future<AccountSessionController> _signedIn(_FakeBillingAccountApi api) async {
  final controller = AccountSessionController(
    api: api,
    tokenStore: _MemoryTokenStore(),
    deviceName: 'DESKTOP-TEST',
  );
  addTearDown(controller.dispose);
  final ok = await controller.login(
    email: 'buyer@example.com',
    password: 'long-password',
  );
  expect(ok, isTrue);
  return controller;
}

Map<String, Object?> _catalogJson({bool paymentAvailable = true}) =>
    <String, Object?>{
      'plans': <Object?>[
        _planJson('month', '月度 VIP', 598, 1),
        _planJson('quarter', '季度 VIP', 998, 3),
        _planJson('year', '年度 VIP', 2998, 12),
        _planJson('lifetime', '永久 VIP', 5998, 0, lifetime: true),
      ],
      'provider': paymentAvailable ? 'mock' : '',
      'payment_available': paymentAvailable,
    };

Map<String, Object?> _planJson(
  String id,
  String name,
  int cents,
  int months, {
  bool lifetime = false,
}) => <String, Object?>{
  'id': id,
  'name': name,
  'amount_cents': cents,
  'amount': '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}',
  'months': months,
  'lifetime': lifetime,
};

Map<String, Object?> _orderJson(
  String status, {
  String plan = 'year',
  String planName = '年度 VIP',
  int cents = 2998,
}) => <String, Object?>{
  'order_no': _orderNo,
  'plan': plan,
  'plan_name': planName,
  'amount_cents': cents,
  'amount': '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}',
  'provider': 'mock',
  'status': status,
  'created_at': '2026-10-13T08:00:00Z',
  'expires_at': '2026-10-13T08:15:00Z',
  'paid_at': status == 'paid' ? '2026-10-13T08:01:00Z' : null,
  'closed_at': status == 'closed' ? '2026-10-13T08:15:00Z' : null,
  'vip_expires_before': null,
  'vip_expires_after': status == 'paid' ? '2027-10-13T08:00:00Z' : null,
  'vip_lifetime': false,
};

/// Account + billing fake that behaves like the server's mock provider.
class _FakeBillingAccountApi
    implements AccountRemoteDataSource, VipBillingRemote {
  _FakeBillingAccountApi({
    this.paymentAvailable = true,
    this.closeOrders = false,
  });

  final bool paymentAvailable;
  final bool closeOrders;
  final List<String> createdPlans = <String>[];
  DateTime? vipExpiresAt;
  String _plan = 'month';

  AuthSession _session() {
    final vip = vipExpiresAt != null;
    return AuthSession(
      accessToken: 'access',
      accessTokenExpiresAt: DateTime.utc(2099),
      refreshToken: 'refresh',
      refreshTokenExpiresAt: DateTime.utc(2099, 2),
      account: JianheAccount(
        id: 'account-buyer',
        email: 'buyer@example.com',
        emailVerified: false,
        entitlement: AccountEntitlement(
          plan: vip ? 'vip' : 'free',
          vipExpiresAt: vipExpiresAt,
          vipLifetime: vipExpiresAt != null && vipExpiresAt!.year >= 9999,
          cloudBackupUploadAllowed: vip,
          cloudBackupDownloadAllowed: vip,
        ),
      ),
      device: const AccountDevice(id: 'device-id', name: 'TEST'),
    );
  }

  VipOrder _order(String status) {
    final plan = _catalogJson()['plans'] as List<Object?>;
    final json = plan.cast<Map<String, Object?>>().firstWhere(
      (item) => item['id'] == _plan,
    );
    return VipOrder.fromJson(
      _orderJson(
        status,
        plan: _plan,
        planName: json['name']! as String,
        cents: json['amount_cents']! as int,
      ),
    );
  }

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
    required String deviceName,
    required String platform,
    required String appVersion,
  }) async => _session();

  @override
  Future<AuthSession> register({
    required String email,
    required String password,
    required String deviceName,
    required String platform,
    required String appVersion,
  }) async => _session();

  @override
  Future<AuthSession> refresh({
    required String refreshToken,
    required String idempotencyKey,
  }) async => _session();

  @override
  Future<void> logout({
    required String refreshToken,
    required String idempotencyKey,
  }) async {}

  @override
  Future<CurrentAccount> currentAccount({required String accessToken}) async {
    final session = _session();
    return CurrentAccount(account: session.account, device: session.device);
  }

  @override
  Future<VipPlanCatalog> fetchVipPlans() async => VipPlanCatalog.fromJson(
    _catalogJson(paymentAvailable: paymentAvailable),
  );

  @override
  Future<VipOrder> createVipOrder({
    required String accessToken,
    required String planId,
  }) async {
    createdPlans.add(planId);
    _plan = planId;
    return _order('pending');
  }

  @override
  Future<VipOrder> fetchVipOrder({
    required String accessToken,
    required String orderNo,
  }) async => _order(vipExpiresAt == null ? 'pending' : 'paid');

  @override
  Future<VipOrder> cancelVipOrder({
    required String accessToken,
    required String orderNo,
  }) async => _order('closed');

  @override
  Future<VipOrder> mockPayVipOrder({
    required String accessToken,
    required String orderNo,
    required VipMockPaymentOutcome outcome,
  }) async {
    if (closeOrders) {
      throw const AccountApiException(
        code: 'ORDER_CLOSED',
        message: '订单已关闭，请重新下单。',
      );
    }
    if (outcome == VipMockPaymentOutcome.fail) {
      throw const AccountApiException(
        code: 'MOCK_PAYMENT_FAILED',
        message: '模拟支付失败：订单仍未支付，可以重试。',
        retryable: true,
      );
    }
    vipExpiresAt = DateTime.utc(2027, 10, 13, 8);
    return _order('paid');
  }
}

class _MemoryTokenStore implements RefreshTokenStore {
  StoredRefreshSession? value;

  @override
  Future<void> delete() async => value = null;

  @override
  Future<StoredRefreshSession?> read() async => value;

  @override
  Future<void> write(StoredRefreshSession session) async => value = session;
}
