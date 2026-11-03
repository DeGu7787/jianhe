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
import 'package:jianhe_desktop/features/account/vip_purchase_dialog.dart';
import 'package:jianhe_desktop/l10n/app_language_scope.dart';
import 'package:jianhe_desktop/l10n/app_strings.dart';
import 'package:qr_flutter/qr_flutter.dart';

const _orderNo = 'JHVIP20261013080000abcdef012345';
const _terms = '2026-11-02';
const _checkoutUrl =
    'https://jianhe.example.com/v1/billing/mock-checkout/$_orderNo?t=abc';

void main() {
  group('AccountApi billing', () {
    http.Response jsonResponse(Object body, int status) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: const <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );

    test('fetches both purchase entries from the server', () async {
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
      expect(catalog.paymentAvailable, isTrue);
      expect(catalog.termsVersion, _terms);
      expect(
        catalog.termsUrl,
        Uri.parse('https://jianhe.example.com/terms#vip'),
      );
      expect(catalog.markets.map((market) => market.id), <String>[
        'cn',
        'intl',
      ]);
      final cn = catalog.market('cn')!;
      expect(cn.plans.map((plan) => plan.price), <String>[
        '¥9.90',
        '¥68.00',
        '¥168.00',
      ]);
      expect(cn.plans[1].monthlyPrice, '¥5.67');
      expect(cn.plans.map((plan) => plan.recommended), <bool>[
        false,
        true,
        false,
      ]);
      // No early-bird offer: no regular price, savings or deadline.
      expect(cn.plans.map((plan) => plan.regularPrice), everyElement(isNull));
      expect(cn.plans.map((plan) => plan.earlyBird), everyElement(isFalse));
      expect(cn.plans[1].savings, isNull);
      expect(catalog.earlyBirdEndsAt, isNull);
      expect(cn.methods.map((method) => method.action), <VipPayActionType>[
        VipPayActionType.qr,
        VipPayActionType.url,
      ]);
      final intl = catalog.market('intl')!;
      expect(intl.plans.map((plan) => plan.price), <String>[
        'US\$4.99',
        'US\$29.99',
        'US\$79.00',
      ]);
      expect(intl.plans[1].monthlyPrice, 'US\$2.50');
      expect(intl.plans[1].recommended, isTrue);
      expect(intl.plans[2].regularPrice, isNull);
      expect(intl.methods.single.mock, isTrue);
    });

    test('early-bird plans carry the regular price and the deadline', () {
      final catalog = VipPlanCatalog.fromJson(_catalogJson(earlyBird: true));
      expect(catalog.earlyBirdEndsAt, DateTime.utc(2027, 2, 2, 16));
      final cn = catalog.market('cn')!;
      expect(cn.plans.map((plan) => plan.price), <String>[
        '¥6.90',
        '¥48.00',
        '¥128.00',
      ]);
      expect(cn.plans.map((plan) => plan.regularPrice), <String>[
        '¥9.90',
        '¥68.00',
        '¥168.00',
      ]);
      expect(cn.plans.map((plan) => plan.savings), <String>[
        '¥3',
        '¥20',
        '¥40',
      ]);
      expect(cn.plans.map((plan) => plan.percentOff), <int>[30, 29, 23]);
      final intl = catalog.market('intl')!;
      expect(intl.plans.map((plan) => plan.savings), <String>[
        'US\$1',
        'US\$10',
        'US\$20',
      ]);
      expect(intl.plans.map((plan) => plan.percentOff), <int>[20, 33, 25]);
    });

    test('a server without purchase entries offers nothing to buy', () {
      final catalog = VipPlanCatalog.fromJson(<String, Object?>{
        'plans': <Object?>[_planJson('month', 'cn', 598, 1)],
        'provider': 'mock',
        'payment_available': true,
      });
      expect(catalog.markets, isEmpty);
      expect(catalog.termsVersion, isNull);
    });

    test('orders carry the method and the accepted terms', () async {
      final requests = <http.Request>[];
      final api = AccountApi(
        baseUri: Uri.parse('https://jianhe.neodaas.com'),
        client: MockClient((request) async {
          requests.add(request);
          expect(request.headers['authorization'], 'Bearer access');
          if (request.url.path == '/v1/billing/orders') {
            return jsonResponse(
              _orderJson('pending', market: 'intl', method: 'mock_intl'),
              201,
            );
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
        methodId: 'mock_intl',
        termsVersion: _terms,
      );
      expect(jsonDecode(requests.single.body), <String, Object?>{
        'plan': 'year',
        'provider': 'mock_intl',
        'terms_version': _terms,
      });
      expect(order.status, VipOrderStatus.pending);
      expect(order.price, 'US\$29.99');
      expect(order.payAction?.type, VipPayActionType.url);
      expect(order.payAction?.value, _checkoutUrl);

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
      expect(paid.payAction, isNull);
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

  test('checkout needs the terms to be accepted', () async {
    final api = _FakeBillingAccountApi();
    final account = await _signedIn(api);
    final controller = _controller(account, api);

    await controller.loadPlans();
    expect(controller.stage, VipPurchaseStage.choosingPlan);
    expect(controller.market?.id, 'cn');
    // The recommended plan is selected first.
    expect(controller.selectedPlanId, 'year');
    expect(controller.checkoutUnavailableReason, isNull);
    expect(controller.canCheckout, isFalse);
    await controller.checkout();
    expect(api.created, isEmpty);

    controller.setTermsAccepted(true);
    expect(controller.canCheckout, isTrue);
    await controller.checkout();
    expect(api.created, <String>['year:mock_cn_qr:$_terms']);
  });

  test(
    'the preferred entry follows the interface but can be switched',
    () async {
      final api = _FakeBillingAccountApi();
      final account = await _signedIn(api);
      final controller = _controller(account, api, preferredMarket: 'intl');

      await controller.loadPlans();
      expect(controller.market?.id, 'intl');
      controller.selectPlan('year');
      expect(controller.selectedPlan?.price, 'US\$29.99');
      expect(controller.selectedMethod?.id, 'mock_intl');

      // Switching keeps the plan and picks the entry's own price and method.
      controller.selectMarket('cn');
      expect(controller.selectedPlan?.id, 'year');
      expect(controller.selectedPlan?.price, '¥68.00');
      expect(controller.selectedMethod?.id, 'mock_cn_qr');
      controller.selectMethod('mock_intl'); // not offered in this entry
      expect(controller.selectedMethod?.id, 'mock_cn_qr');
      controller.selectMethod('mock_cn_web');
      controller.setTermsAccepted(true);
      await controller.checkout();
      expect(api.created, <String>['year:mock_cn_web:$_terms']);
    },
  );

  test('the English interface only sells in USD', () async {
    final api = _FakeBillingAccountApi();
    final account = await _signedIn(api);
    final controller = _controller(
      account,
      api,
      preferredMarket: 'intl',
      lockMarket: true,
    );

    await controller.loadPlans();
    expect(controller.market?.id, 'intl');
    expect(controller.alternativeMarket, isNull);
    controller.selectMarket('cn');
    expect(controller.market?.id, 'intl');
    expect(controller.selectedPlan?.price, 'US\$29.99');

    // The Chinese interface offers the other entry.
    final chinese = _controller(account, api, preferredMarket: 'cn');
    await chinese.loadPlans();
    expect(chinese.alternativeMarket?.id, 'intl');
  });

  test('controller keeps the order payable after a failed payment', () async {
    final api = _FakeBillingAccountApi();
    final account = await _signedIn(api);
    final controller = _controller(account, api);

    await controller.loadPlans();
    controller.selectPlan('month');
    controller.setTermsAccepted(true);
    await controller.checkout();
    expect(controller.stage, VipPurchaseStage.awaitingPayment);
    expect(controller.order?.payAction?.type, VipPayActionType.qr);

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

  test('a browser checkout opens the page and confirms by query', () async {
    final api = _FakeBillingAccountApi();
    final opened = <Uri>[];
    final account = await _signedIn(api, opened: opened);
    final controller = _controller(account, api, preferredMarket: 'intl');

    await controller.loadPlans();
    controller.setTermsAccepted(true);
    await controller.checkout();
    expect(controller.stage, VipPurchaseStage.awaitingPayment);
    expect(opened, <Uri>[Uri.parse(_checkoutUrl)]);

    // "I've paid" before the money arrived keeps the order open.
    await controller.confirmPaid();
    expect(controller.stage, VipPurchaseStage.awaitingPayment);
    expect(controller.message, contains('还没有收到'));

    await controller.openPayPage();
    expect(opened, hasLength(2));

    api.payOutside();
    await controller.confirmPaid();
    expect(controller.stage, VipPurchaseStage.paid);
    expect(account.account!.entitlement.isVip, isTrue);
  });

  test('polling notices a payment made on a phone', () async {
    final api = _FakeBillingAccountApi();
    final account = await _signedIn(api);
    final controller = _controller(
      account,
      api,
      pollInterval: const Duration(milliseconds: 10),
    );

    await controller.loadPlans();
    controller.setTermsAccepted(true);
    await controller.checkout();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(controller.stage, VipPurchaseStage.awaitingPayment);
    expect(controller.message, isNull);

    api.payOutside();
    for (var i = 0; i < 20 && controller.stage != VipPurchaseStage.paid; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(controller.stage, VipPurchaseStage.paid);
  });

  test('controller returns to the plan list when the order closed', () async {
    final api = _FakeBillingAccountApi(closeOrders: true);
    final account = await _signedIn(api);
    final controller = _controller(account, api);

    await controller.loadPlans();
    controller.setTermsAccepted(true);
    await controller.checkout();
    await controller.mockPay(VipMockPaymentOutcome.success);
    expect(controller.stage, VipPurchaseStage.choosingPlan);
    expect(controller.order, isNull);
    expect(controller.message, contains('订单已关闭'));
  });

  test('checkout is blocked when the server has no payment channel', () async {
    final api = _FakeBillingAccountApi(paymentAvailable: false);
    final account = await _signedIn(api);
    final controller = _controller(account, api);

    await controller.loadPlans();
    controller.setTermsAccepted(true);
    expect(controller.canCheckout, isFalse);
    expect(controller.checkoutUnavailableReason, contains('支付通道暂未开放'));
    await controller.checkout();
    expect(api.created, isEmpty);
  });

  testWidgets('free user buys a year of VIP through the mock cashier', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(450, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeBillingAccountApi();
    final account = await _signedIn(api);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AccountPanel(controller: account)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('当前为免费账号'), findsOneWidget);
    expect(find.text('开通 VIP'), findsOneWidget);

    await tester.tap(find.byKey(const Key('vip-purchase')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('vip-purchase-dialog')), findsOneWidget);
    expect(find.text('¥9.90'), findsOneWidget);
    expect(find.text('¥68.00'), findsOneWidget);
    expect(find.text('¥168.00'), findsOneWidget);
    expect(find.text('季度 VIP'), findsNothing);
    expect(find.byKey(const Key('vip-plan-year-recommended')), findsOneWidget);
    // Without an early-bird offer there is no banner and no regular price.
    expect(find.byKey(const Key('vip-early-bird-banner')), findsNothing);
    expect(find.byKey(const Key('vip-plan-year-regular')), findsNothing);
    // One entry at a time; the other is a link, not a toggle.
    expect(find.text('US\$29.99'), findsNothing);
    expect(find.text('不在中国大陆？使用海外支付（美元）'), findsOneWidget);
    expect(find.byKey(const Key('vip-no-refund')), findsOneWidget);
    expect(find.textContaining('购买后不支持退款'), findsWidgets);

    await tester.tap(find.byKey(const Key('vip-plan-year')));
    await tester.pump();
    expect(find.text('去支付 ¥68.00'), findsOneWidget);
    // Paying is blocked until the terms are accepted.
    await tester.tap(find.byKey(const Key('vip-checkout')));
    await tester.pumpAndSettle();
    expect(api.created, isEmpty);
    await tester.tap(find.byKey(const Key('vip-terms-checkbox')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('vip-checkout')));
    await tester.pumpAndSettle();

    expect(find.text('模拟收银台'), findsOneWidget);
    expect(find.byKey(const Key('vip-mock-banner')), findsOneWidget);
    expect(find.byKey(const Key('vip-cashier-amount')), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text(_orderNo), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('vip-mock-pay-fail')));
    await tester.tap(find.byKey(const Key('vip-mock-pay-fail')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('vip-purchase-message')), findsOneWidget);
    expect(find.text('模拟收银台'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('vip-mock-pay-success')));
    await tester.tap(find.byKey(const Key('vip-mock-pay-success')));
    await tester.pumpAndSettle();
    expect(find.text('支付成功'), findsOneWidget);
    expect(find.byKey(const Key('vip-paid-summary')), findsOneWidget);

    await tester.tap(find.byKey(const Key('vip-purchase-done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('vip-purchase-dialog')), findsNothing);
    expect(find.text('VIP 服务已开通'), findsOneWidget);
    expect(find.text('续费 / 升级 VIP'), findsOneWidget);
    expect(api.created, <String>['year:mock_cn_qr:$_terms']);
  });

  testWidgets('the Chinese interface can switch to the overseas entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(450, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeBillingAccountApi();
    final opened = <Uri>[];
    final account = await _signedIn(api, opened: opened);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VipPurchaseDialog(
            account: account,
            billing: api,
            pollInterval: null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('¥68.00'), findsOneWidget);
    await tester.tap(find.byKey(const Key('vip-market-switch')));
    await tester.pumpAndSettle();
    expect(find.text('¥68.00'), findsNothing);
    expect(find.text('在中国大陆？改用国内支付（人民币）'), findsOneWidget);
    expect(find.text('US\$29.99'), findsOneWidget);
    expect(find.text('年度 VIP'), findsOneWidget);
    // One method in this entry: no method picker.
    expect(find.byKey(const Key('vip-method-mock_intl')), findsNothing);

    await tester.tap(find.byKey(const Key('vip-terms-link')));
    await tester.pump();
    expect(opened, <Uri>[Uri.parse('https://jianhe.example.com/terms#vip')]);
    expect(
      tester
          .widget<Checkbox>(find.byKey(const Key('vip-terms-checkbox')))
          .value,
      isFalse,
      reason: 'opening the terms must not tick the box',
    );

    await tester.tap(find.byKey(const Key('vip-terms-accept')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('vip-plan-year')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('vip-checkout')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('vip-pay-in-browser')), findsOneWidget);
    expect(opened.last, Uri.parse(_checkoutUrl));
    expect(find.text('US\$29.99'), findsOneWidget);
    expect(api.created, <String>['year:mock_intl:$_terms']);
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
      MaterialApp(
        home: Scaffold(body: AccountPanel(controller: account)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('永久 VIP 已开通'), findsOneWidget);
    expect(find.text('永久有效'), findsOneWidget);
    expect(find.byKey(const Key('vip-purchase')), findsNothing);
  });

  testWidgets('the English interface sells in USD only', (tester) async {
    tester.view.physicalSize = const Size(450, 900);
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
    expect(find.text('当前为免费账号'), findsNothing);

    await tester.tap(find.byKey(const Key('vip-purchase')));
    await tester.pumpAndSettle();
    expect(find.text('US\$4.99'), findsOneWidget);
    expect(find.text('Monthly VIP'), findsOneWidget);
    expect(find.text('Best value'), findsOneWidget);
    expect(find.textContaining('non-refundable'), findsWidgets);
    expect(find.text('Pay US\$29.99'), findsOneWidget);

    // No CNY prices and no way to switch to them.
    expect(find.byKey(const Key('vip-market-switch')), findsNothing);
    expect(find.textContaining('¥'), findsNothing);
  });

  testWidgets('the early-bird offer is shown with its savings and deadline', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(450, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeBillingAccountApi(earlyBird: true);
    final account = await _signedIn(api);

    Future<void> open(AppLanguage language) async {
      await tester.pumpWidget(
        AppLanguageScope(
          language: language,
          child: MaterialApp(
            home: Scaffold(
              body: VipPurchaseDialog(
                account: account,
                billing: api,
                pollInterval: null,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await open(AppLanguage.zh);
    expect(find.byKey(const Key('vip-early-bird-banner')), findsOneWidget);
    expect(find.text('早鸟优惠 · 低至 7 折'), findsOneWidget);
    expect(find.text('限时优惠，截至 2027-02-02，之后恢复正式价'), findsOneWidget);
    expect(find.text('¥48.00'), findsOneWidget);
    expect(find.text('省 ¥20'), findsOneWidget);
    expect(find.text('省 ¥3'), findsOneWidget);
    expect(find.text('省 ¥40'), findsOneWidget);
    expect(find.byKey(const Key('vip-plan-year-regular')), findsOneWidget);
    expect(find.text('去支付 ¥48.00（早鸟价）'), findsOneWidget);

    AppStrings.setCurrentLanguage(AppLanguage.en);
    addTearDown(() => AppStrings.setCurrentLanguage(AppLanguage.zh));
    await tester.pumpWidget(const SizedBox());
    await open(AppLanguage.en);
    expect(find.text('Early-bird offer · Save up to 33%'), findsOneWidget);
    expect(find.text('US\$19.99'), findsOneWidget);
    expect(find.text('Save US\$10'), findsOneWidget);
    expect(find.text('Pay US\$19.99 (early-bird price)'), findsOneWidget);
  });
}

VipPurchaseController _controller(
  AccountSessionController account,
  _FakeBillingAccountApi api, {
  String? preferredMarket,
  bool lockMarket = false,
  Duration? pollInterval,
}) {
  final controller = VipPurchaseController(
    account: account,
    billing: api,
    preferredMarket: preferredMarket,
    lockMarket: lockMarket,
    pollInterval: pollInterval,
  );
  addTearDown(controller.dispose);
  return controller;
}

Future<AccountSessionController> _signedIn(
  _FakeBillingAccountApi api, {
  List<Uri>? opened,
}) async {
  final controller = AccountSessionController(
    api: api,
    tokenStore: _MemoryTokenStore(),
    deviceName: 'DESKTOP-TEST',
    externalBrowserOpener: (uri) async => opened?.add(uri),
  );
  addTearDown(controller.dispose);
  final ok = await controller.login(
    email: 'buyer@example.com',
    password: 'long-password',
  );
  expect(ok, isTrue);
  return controller;
}

const _prices = <String, Map<String, int>>{
  'cn': <String, int>{'month': 990, 'year': 6800, 'lifetime': 16800},
  'intl': <String, int>{'month': 499, 'year': 2999, 'lifetime': 7900},
};
const _months = <String, int>{'month': 1, 'year': 12, 'lifetime': 0};
const _names = <String, String>{
  'month': '月度 VIP',
  'year': '年度 VIP',
  'lifetime': '永久 VIP',
};
const _methodMarket = <String, String>{
  'mock_cn_qr': 'cn',
  'mock_cn_web': 'cn',
  'mock_intl': 'intl',
};

String _amount(int cents) =>
    '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';

Map<String, Object?> _catalogJson({
  bool paymentAvailable = true,
  bool earlyBird = false,
}) {
  List<Object?> plans(String market) => <Object?>[
    for (final id in _names.keys)
      earlyBird
          ? _earlyBirdPlanJson(id, market)
          : _planJson(id, market, _prices[market]![id]!, _months[id]!),
  ];
  return <String, Object?>{
    if (earlyBird) 'early_bird_ends_at': '2027-02-02T16:00:00Z',
    'plans': plans('cn'),
    'provider': paymentAvailable ? 'mock' : '',
    'payment_available': paymentAvailable,
    'terms_version': _terms,
    'terms_url': 'https://jianhe.example.com/terms#vip',
    'markets': paymentAvailable
        ? <Object?>[
            <String, Object?>{
              'id': 'cn',
              'currency': 'CNY',
              'plans': plans('cn'),
              'methods': <Object?>[
                <String, Object?>{
                  'id': 'mock_cn_qr',
                  'name': '模拟扫码支付',
                  'action': 'qr',
                  'mock': true,
                },
                <String, Object?>{
                  'id': 'mock_cn_web',
                  'name': '模拟网页支付',
                  'action': 'url',
                  'mock': true,
                },
              ],
            },
            <String, Object?>{
              'id': 'intl',
              'currency': 'USD',
              'plans': plans('intl'),
              'methods': <Object?>[
                <String, Object?>{
                  'id': 'mock_intl',
                  'name': '模拟海外收银台',
                  'action': 'url',
                  'mock': true,
                },
              ],
            },
          ]
        : <Object?>[],
  };
}

Map<String, Object?> _planJson(
  String id,
  String market,
  int cents,
  int months,
) => <String, Object?>{
  'id': id,
  'name': _names[id],
  'market': market,
  'currency': market == 'cn' ? 'CNY' : 'USD',
  'amount_cents': cents,
  'amount': _amount(cents),
  'months': months,
  'lifetime': id == 'lifetime',
  'recommended': id == 'year',
};

const _earlyBirdPrices = <String, Map<String, int>>{
  'cn': <String, int>{'month': 690, 'year': 4800, 'lifetime': 12800},
  'intl': <String, int>{'month': 399, 'year': 1999, 'lifetime': 5900},
};

/// A plan as the server sends it while the early-bird offer runs.
Map<String, Object?> _earlyBirdPlanJson(String id, String market) {
  final regular = _prices[market]![id]!;
  return <String, Object?>{
    ..._planJson(id, market, _earlyBirdPrices[market]![id]!, _months[id]!),
    'regular_amount_cents': regular,
    'regular_amount': _amount(regular),
  };
}

Map<String, Object?> _orderJson(
  String status, {
  String plan = 'year',
  String market = 'cn',
  String method = 'mock_cn_qr',
}) {
  final cents = _prices[market]![plan]!;
  return <String, Object?>{
    'order_no': _orderNo,
    'plan': plan,
    'plan_name': _names[plan],
    'market': market,
    'currency': market == 'cn' ? 'CNY' : 'USD',
    'amount_cents': cents,
    'amount': _amount(cents),
    'provider': method,
    'status': status,
    'created_at': '2026-10-13T08:00:00Z',
    'expires_at': '2026-10-13T08:15:00Z',
    'paid_at': status == 'paid' ? '2026-10-13T08:01:00Z' : null,
    'closed_at': status == 'closed' ? '2026-10-13T08:15:00Z' : null,
    'vip_expires_before': null,
    'vip_expires_after': status == 'paid' ? '2027-10-13T08:00:00Z' : null,
    'vip_lifetime': false,
    'terms_version': _terms,
    'terms_accepted_at': '2026-10-13T08:00:00Z',
    if (status == 'pending')
      'pay_action': <String, Object?>{
        'type': method == 'mock_cn_qr' ? 'qr' : 'url',
        'value': _checkoutUrl,
      },
  };
}

/// Account + billing fake that behaves like the server's mock provider.
class _FakeBillingAccountApi
    implements AccountRemoteDataSource, VipBillingRemote {
  _FakeBillingAccountApi({
    this.paymentAvailable = true,
    this.closeOrders = false,
    this.earlyBird = false,
  });

  final bool paymentAvailable;
  final bool earlyBird;
  final bool closeOrders;

  /// `plan:method:terms` of every created order.
  final List<String> created = <String>[];
  DateTime? vipExpiresAt;
  String _plan = 'month';
  String _method = 'mock_cn_qr';

  /// The user paid on a phone or in the browser.
  void payOutside() => vipExpiresAt = DateTime.utc(2027, 10, 13, 8);

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

  VipOrder _order(String status) => VipOrder.fromJson(
    _orderJson(
      status,
      plan: _plan,
      market: _methodMarket[_method]!,
      method: _method,
    ),
  );

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
    _catalogJson(paymentAvailable: paymentAvailable, earlyBird: earlyBird),
  );

  @override
  Future<VipOrder> createVipOrder({
    required String accessToken,
    required String planId,
    required String methodId,
    required String termsVersion,
  }) async {
    created.add('$planId:$methodId:$termsVersion');
    _plan = planId;
    _method = methodId;
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
    payOutside();
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
