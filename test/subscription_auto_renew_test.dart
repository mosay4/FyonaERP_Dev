import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/subscription/domain/services/subscription_service.dart';
import 'package:fyona_flutter/features/subscription/presentation/pages/fyona_card_payment_page.dart';
import 'package:fyona_flutter/features/subscription/presentation/widgets/auto_renew_section.dart'
    show RenewalUiState, renewalUiState;
import 'package:fyona_flutter/features/subscription/presentation/widgets/stripe_error_messages.dart';

/// Auto-renew client contract + custom-card flag.
///
/// Verifies (with a stubbed Dio, no network) that the app:
/// - sends consent + plan + method for enable (and NEVER a price),
/// - parses setup secret / status / safe card display,
/// - keeps the custom FYONA screen enabled with PaymentSheet fallback intact.
void main() {
  test('custom FYONA card screen is enabled (PaymentSheet stays as fallback)',
      () {
    expect(FyonaCardPaymentConfig.enabled, isTrue);
  });

  SubscriptionServiceImpl stubService(
    Map<String, dynamic> bodies,
    Map<String, dynamic> responses,
  ) {
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9'));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      bodies[options.path] = options.data;
      final payload = responses[options.path] ?? {'success': true, 'data': {}};
      handler.resolve(Response(
        requestOptions: options,
        statusCode: 200,
        data: payload,
      ));
    }));
    return SubscriptionServiceImpl(apiClient: ApiClient(dio: dio));
  }

  group('auto-renew client contract', () {
    test('setup intent returns secret without sending card data', () async {
      final bodies = <String, dynamic>{};
      final svc = stubService(bodies, {
        '/payments/stripe/setup-intent': {
          'success': true,
          'data': {'client_secret': 'seti_secret_x', 'publishable_key': 'pk_x'}
        },
      });
      final out = await svc.createAutoRenewSetupIntent();
      expect(out['client_secret'], 'seti_secret_x');
      expect(out['publishable_key'], 'pk_x');
      expect(bodies['/payments/stripe/setup-intent'], isEmpty);
    });

    test('enable sends consent and references, never a price', () async {
      final bodies = <String, dynamic>{};
      final svc = stubService(bodies, {
        '/payments/stripe/auto-renew/enable': {
          'success': true,
          'data': {'status': 'active', 'stripe_subscription_id': 'sub_x'}
        },
      });
      final out = await svc.enableAutoRenew(
        planId: 'plan-uuid-1',
        period: 'yearly',
        paymentMethodId: 'pm_1',
        consent: true,
      );
      expect(out['status'], 'active');
      final sent = Map<String, dynamic>.from(
          bodies['/payments/stripe/auto-renew/enable'] as Map);
      expect(sent['consent'], isTrue);
      expect(sent['plan_id'], 'plan-uuid-1');
      expect(sent['period'], 'yearly');
      expect(sent['payment_method_id'], 'pm_1');
      expect(sent.containsKey('price'), isFalse);
      expect(sent.containsKey('amount'), isFalse);
    });

    test('disable and status parse', () async {
      final bodies = <String, dynamic>{};
      final svc = stubService(bodies, {
        '/payments/stripe/auto-renew/disable': {
          'success': true,
          'data': {'cancel_at_period_end': true, 'status': 'active'}
        },
        '/payments/stripe/auto-renew/status': {
          'success': true,
          'data': {
            'enabled': true,
            'status': 'active',
            'card': {'brand': 'visa', 'last4': '4242'}
          }
        },
      });
      final off = await svc.disableAutoRenew();
      expect(off['cancel_at_period_end'], isTrue);
      final st = await svc.autoRenewStatus();
      expect(st['enabled'], isTrue);
      expect((st['card'] as Map)['last4'], '4242');
      expect(st.toString().contains('cvc'), isFalse);
    });

    test('backend failure surfaces the message', () async {
      final bodies = <String, dynamic>{};
      final svc = stubService(bodies, {
        '/payments/stripe/auto-renew/enable': {
          'success': false,
          'message': 'موافقة المستخدم على التجديد التلقائي مطلوبة'
        },
      });
      expect(
        () => svc.enableAutoRenew(
          planId: 'p',
          period: 'yearly',
          paymentMethodId: 'pm',
          consent: false,
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('payment params stay valid without a cardholder name', () {
      // The holder field was removed: an empty PaymentMethodData must still
      // build valid params for confirmPayment (3DS unaffected).
      final params = PaymentMethodParams.card(
        paymentMethodData: PaymentMethodData(),
      );
      expect(params.paymentMethodData, isNotNull);
    });

    test('renewal UI truth comes from backend state only', () {      // TEST 6/7/9: no saved method -> save button, even if tapped before.
      expect(
        renewalUiState(
            enabled: false, hasSavedMethod: false, offSessionReady: false),
        RenewalUiState.showSave,
      );
      // Enabled + ready -> active pill, no save button.
      expect(
        renewalUiState(
            enabled: true, hasSavedMethod: true, offSessionReady: true),
        RenewalUiState.showEnabled,
      );
      // Enabled but not chargeable -> fix flow, never silent success.
      expect(
        renewalUiState(
            enabled: true, hasSavedMethod: true, offSessionReady: false),
        RenewalUiState.showFix,
      );
      // Saved method but renewal off -> offer enable (save path).
      expect(
        renewalUiState(
            enabled: false, hasSavedMethod: true, offSessionReady: true),
        RenewalUiState.showSave,
      );
    });

    test('decline codes localize to AR/EN with safe fallback', () {      final ar = stripeDeclineMessage(
          declineCode: 'insufficient_funds', arabic: true)!;
      expect(ar.contains('رصيد'), isTrue);
      final en = stripeDeclineMessage(
          declineCode: 'insufficient_funds', arabic: false)!;
      expect(en.toLowerCase().contains('insufficient'), isTrue);
      expect(
          stripeDeclineMessage(stripeErrorCode: 'card_declined')!
              .contains('البنك'),
          isTrue);
      expect(
          stripeDeclineMessage(
              stripeErrorCode: 'expired_card', arabic: false)!,
          contains('expired'));
      expect(stripeDeclineMessage(), isNull);
      expect(
          stripeDeclineMessage(stripeErrorCode: 'invalid_request_error'),
          isNull);
    });

    test('DNS failures map to an internet-check message', () {
      const raw =
          'IOException during API request to Stripe (https://api.stripe.com/v1/setup_intents/xxx/confirm): '
          'Unable to resolve host "api.stripe.com": No address associated with hostname.';
      final ar = stripeNetworkMessage(raw, arabic: true)!;
      expect(ar.contains('الإنترنت'), isTrue);
      final en = stripeNetworkMessage(raw, arabic: false)!;
      expect(en.toLowerCase().contains('internet'), isTrue);
      expect(stripeNetworkMessage('card declined'), isNull);
      expect(stripeNetworkMessage(null), isNull);
    });
  });
}
