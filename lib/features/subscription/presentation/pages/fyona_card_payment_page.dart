import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:go_router/go_router.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_exceptions.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/core/theme/app_radius.dart';
import 'package:fyona_flutter/core/theme/app_spacing.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart';
import 'package:fyona_flutter/core/utils/subscription_identity.dart';
import 'package:fyona_flutter/shared/widgets/confirm_dialog.dart';
import 'package:fyona_flutter/shared/widgets/connectivity_widgets.dart';
import 'package:fyona_flutter/shared/widgets/payment_method_icons.dart';
import 'package:fyona_flutter/features/subscription/domain/services/subscription_service.dart';
import 'package:fyona_flutter/features/subscription/data/models/subscription_models.dart';
import 'package:fyona_flutter/features/subscription/presentation/widgets/stripe_error_messages.dart';
import 'package:fyona_flutter/features/subscription/di/subscription_providers.dart';
import 'package:fyona_flutter/features/subscription/presentation/providers/subscription_providers.dart';
import 'package:fyona_flutter/features/auth/presentation/providers/auth_provider.dart';

/// Feature flag for the native FYONA card screen.
///
/// `true`  → the native screen below handles card payments.
/// `false` → callers fall back to the Stripe PaymentSheet path.
/// Flip to `false` at any time to restore PaymentSheet with no backend change.
class FyonaCardPaymentConfig {
  FyonaCardPaymentConfig._();
  static const bool enabled = true;
}

/// Native FYONA card-payment screen (per-plan identity theming).
///
/// Uses the EXACT same backend contract as the PaymentSheet path:
/// `createStripePaymentIntent` (server prices, idempotency) → Stripe SDK card
/// confirm (PAN/CVC never touch FYONA code or backend) → the SAME
/// `confirmStripePayment` + webhook fallback + invoice navigation.
/// Launch with [FyonaCardPaymentScreen.push]; returns `'fallback'` when the
/// caller should retry via PaymentSheet instead.
class FyonaCardPaymentScreen extends ConsumerStatefulWidget {
  final String planId;
  final String planName;
  final String period;
  final double displayAmount;
  final String displayCurrency;
  final String stripePlanId;
  final String idemKey;

  const FyonaCardPaymentScreen({
    super.key,
    required this.planId,
    required this.planName,
    required this.period,
    required this.displayAmount,
    required this.displayCurrency,
    required this.stripePlanId,
    required this.idemKey,
  });

  /// Opens the screen; resolves to `'fallback'` if PaymentSheet should be
  /// used instead, or `null` on normal completion/cancel.
  static Future<String?> push(
    BuildContext context, {
    required String planId,
    required String planName,
    required String period,
    required double displayAmount,
    required String displayCurrency,
    required String stripePlanId,
    required String idemKey,
  }) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => FyonaCardPaymentScreen(
          planId: planId,
          planName: planName,
          period: period,
          displayAmount: displayAmount,
          displayCurrency: displayCurrency,
          stripePlanId: stripePlanId,
          idemKey: idemKey,
        ),
      ),
    );
  }

  @override
  ConsumerState<FyonaCardPaymentScreen> createState() =>
      _FyonaCardPaymentScreenState();
}

class _FyonaCardPaymentScreenState
    extends ConsumerState<FyonaCardPaymentScreen> {
  bool _paying = false;
  bool _cardComplete = false;
  bool _duplicateGuard = false;
  String _phase = '';
  // Post-payment save prompt: the card is charged first with NO pre-save
  // option. Only after the backend confirms the subscription is ACTIVE do
  // we ask the user whether to save the card for auto-renewal (§2/§3).
  // Nothing sensitive ever leaves the Stripe SDK.
  bool _renewKnownEnabled = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      try {
        final st = await ref
            .read(subscriptionServiceProvider)
            .autoRenewStatus();
        if (!mounted) return;
        setState(() => _renewKnownEnabled = st['enabled'] == true);
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  Color get _accent =>
      subscriptionIdentityColor(widget.planId.isNotEmpty ? widget.planId : widget.planName);

  Color get _onAccent =>
      _accent == AppColors.gold ? const Color(0xFF3A2E00) : Colors.white;

  String _tr(String key, String fallback) =>
      AppLocalizations.of(context).translate(key) == key
          ? fallback
          : AppLocalizations.of(context).translate(key);

  Future<void> _pay() async {
    if (_paying || _duplicateGuard) return;
    final connectivity = ref.read(connectivityServiceProvider);
    if (!connectivity.isOnline) {
      await showOfflineDialog(context, connectivity: connectivity);
      return;
    }
    if (!_cardComplete) {
      showSnackbar(context,
          message: _tr('subPayIncompleteCard', 'أكمل بيانات البطاقة أولاً'),
          color: AppColors.warning);
      return;
    }
    setState(() {
      _paying = true;
      _duplicateGuard = true;
      _phase = _tr('subPayProcessing', 'جارٍ معالجة الدفع…');
    });
StripePaymentIntent? createdIntent;
    try {
      final service = ref.read(subscriptionServiceProvider);
      // One-time charge with off-session mandate: the card is charged now;
      // the mandate lets the saved method be reused for renewal later.
      // Saving itself happens ONLY on the invoice Start tap (auto-save).
      createdIntent = await service.createStripePaymentIntent(
        widget.stripePlanId,
        period: widget.period,
        currency: widget.displayCurrency,
        idempotencyKey: widget.idemKey,
      );
      if (createdIntent.publishableKey == null ||
          createdIntent.publishableKey!.isEmpty) {
        throw _FyonaPaymentMessage(
            AppLocalizations.of(context).translate('subPayUnavailable'));
      }
      Stripe.publishableKey = createdIntent.publishableKey!;
      // Same cold-start guard as the opener: initialize natively now so no
      // later CardField/SDK call can hit an uninitialized native SDK.
      try {
        await Stripe.instance.applySettings();
      } catch (_) {}
      if (!mounted) return;
      // Card data stays inside the Stripe SDK (CardField); only Stripe sees
      // PAN/CVC. 3DS/SCA challenges are presented by the SDK automatically.
      // setupFutureUsage=OffSession stores the off-session mandate so the
      // method can later be attached for automatic renewal (no extra UI).
      String? chargedPmId;
      await Stripe.instance.confirmPayment(
        paymentIntentClientSecret: createdIntent.clientSecret,
        data: PaymentMethodParams.card(
          paymentMethodData: PaymentMethodData(),
        ),
        options: PaymentMethodOptions(
          setupFutureUsage: PaymentIntentsFutureUsage.OffSession,
        ),
      );
      if (!mounted) return;
      // Capture the method Stripe just charged so the invoice Start tap can
      // bind it for renewal without asking for card details again.
      try {
        final pi = await Stripe.instance.retrievePaymentIntent(
          createdIntent.clientSecret,
        );
        final raw = pi.paymentMethodId ?? '';
        if (raw.isNotEmpty) chargedPmId = raw;
      } catch (_) {}
      setState(() => _phase = _tr('subPayConfirming', 'جارٍ تأكيد الاشتراك…'));

      // ── Same instant verification + activation as the PaymentSheet path ──
      bool activated = false;
      try {
        await service.confirmStripePayment(
          paymentIntentId: createdIntent.stripePaymentIntentId,
          paymentId: createdIntent.paymentId,
        );
        activated = true;
      } catch (_) {
        activated = false;
      }

      ref.invalidate(subscriptionStatusProvider);
      ref.invalidate(subscriptionPlansProvider);
      unawaited(ref.read(authProvider.notifier).refreshProfile());

      if (!activated) {
        await _waitForWebhookActivation(service);
        // Final gate: success UI + invoice ONLY on backend-confirmed ACTIVE.
        try {
          final st = await service.getStatus();
          activated = st['status']?.toString() == 'active';
        } catch (_) {}
      } else {
        await Future.delayed(const Duration(milliseconds: 400));
        try {
          final st = await service.getStatus();
          if (st['status']?.toString() != 'active') {
            await _waitForWebhookActivation(service);
            try {
              final st2 = await service.getStatus();
              activated = st2['status']?.toString() == 'active';
            } catch (_) {}
          }
        } catch (_) {}
      }

      if (!mounted) return;
      if (!activated) {
        showSnackbar(context,
            message: AppLocalizations.t('subPayFailed'),
            color: AppColors.danger);
        return;
      }
      if (!mounted) return;
      showSnackbar(
          context,
          message:
              AppLocalizations.of(context).translate('subPaySuccess'),
          color: AppColors.success);
      // The invoice Start tap auto-saves this method for renewal: carry it
      // (and the plan id) as hidden route params — never displayed.
      _goInvoiceWithStatus(service,
          pmId: chargedPmId, stripePlanId: widget.stripePlanId);
    } catch (e) {
      if (!mounted) return;
      try {
        if (e is StripeException) {
          debugPrint(
              'FYONA_DIAG cardPay code=${e.error.code} '
              'stripe=${e.error.stripeErrorCode} decline=${e.error.declineCode} '
              'msg=${e.error.message} loc=${e.error.localizedMessage}');
        } else {
          debugPrint('FYONA_DIAG cardPay other=$e');
        }
      } catch (_) {}
      final canceled =
          e is StripeException && e.error.code == FailureCode.Canceled;
      if (!canceled) {
        // Rigorous race check: only a Stripe-verified success of THIS intent
        // may navigate. A stale 'active' status (trial/previous plan) must
        // never open an invoice for a failed payment.
        try {
          await ref.read(subscriptionServiceProvider).confirmStripePayment(
                paymentIntentId: createdIntent?.stripePaymentIntentId,
                paymentId: createdIntent?.paymentId,
              );
          ref.invalidate(subscriptionStatusProvider);
          // Best-effort: recover the charged method for Start-tap saving.
          String? racePmId;
          try {
            if (createdIntent != null) {
              final rpi = await Stripe.instance.retrievePaymentIntent(
                createdIntent.clientSecret,
              );
              final rraw = rpi.paymentMethodId ?? '';
              if (rraw.isNotEmpty) racePmId = rraw;
            }
          } catch (_) {}
          if (mounted) {
            _goInvoiceWithStatus(
                ref.read(subscriptionServiceProvider),
                pmId: racePmId,
                stripePlanId: widget.stripePlanId);
          }
          return;
        } catch (_) {}
      }
      if (_isTechnicalFailure(e) && !canceled) {
        // Unexpected technical failure → fall back to PaymentSheet.
        if (mounted) context.pop('fallback');
        return;
      }
      showSnackbar(context,
          message: _friendlyError(e),
          color: canceled ? AppColors.info : AppColors.danger);
    } finally {
      if (mounted) {
        setState(() {
          _paying = false;
          _phase = '';
        });
        // Re-arm duplicate clicks after the attempt settles.
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => _duplicateGuard = false);
        });
      }
    }
  }

  /// Failures where retrying via PaymentSheet is the safe move (SDK/config
  /// issues), as opposed to user cancel or card declines.
  bool _isTechnicalFailure(Object e) {
    if (e is StripeException) {
      final code = e.error.code;
      if (code == FailureCode.Canceled || code == FailureCode.Failed) {
        return false;
      }
      return true;
    }
    if (e is ApiException) return false;
    if (e is _FyonaPaymentMessage) return false;
    return true;
  }

  Future<void> _goInvoiceWithStatus(
    SubscriptionServiceImpl? service, {
    Map<String, dynamic>? cached,
    String? pmId,
    String? stripePlanId,
  }) async {
    Map<String, dynamic> st = cached ?? {};
    if (cached == null) {
      try {
        st = await ref.read(subscriptionServiceProvider).getStatus();
      } catch (_) {}
    }
    if (!mounted) return;
    final params = <String, String>{
      if (widget.planName.isNotEmpty) 'plan': widget.planName,
      'amount': widget.displayAmount > 0
          ? fmtNum(widget.displayAmount)
          : (st['plan_price']?.toString() ?? ''),
      'currency': widget.displayCurrency,
      'method': 'card',
      if ((st['invoice_number']?.toString() ?? '').isNotEmpty)
        'invoice_no': st['invoice_number'].toString(),
      'period': widget.period,
      if ((st['start_date']?.toString() ?? '').isNotEmpty)
        'start': st['start_date'].toString(),
      if ((st['end_date']?.toString() ?? '').isNotEmpty)
        'end': st['end_date'].toString(),
      if ((st['card_brand']?.toString() ?? '').isNotEmpty)
        'card': st['card_brand'].toString(),
      // Hidden renewal binding (never displayed): the just-charged method
      // + plan id the invoice Start tap uses for automatic card saving.
      if ((pmId ?? '').isNotEmpty) 'pm_id': pmId!,
      if ((stripePlanId ?? '').isNotEmpty) 'stripe_plan_id': stripePlanId!,
    }..removeWhere((_, v) => v.isEmpty);
    final qs = params.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    context.pushReplacement(
        '${RouteNames.subscriptionInvoice}${qs.isEmpty ? '' : '?$qs'}');
  }

  /// Short webhook polling as a fallback if the instant confirm did not
  /// succeed (e.g. Stripe status still processing). Max ~6s.
  Future<void> _waitForWebhookActivation(
      SubscriptionServiceImpl service) async {
    for (var i = 0; i < 3; i++) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      try {
        final status = await service.getStatus();
        if (status['status']?.toString() == 'active') {
          ref.invalidate(subscriptionStatusProvider);
          return;
        }
      } catch (_) {}
    }
  }

  String _friendlyError(Object e) {
    if (e is ApiException) return e.message;
    if (e is StripeException) {
      if (e.error.code == FailureCode.Canceled) {
        return AppLocalizations.t('subPayCancelled');
      }
      final mapped = stripeDeclineMessage(
        declineCode: e.error.declineCode,
        stripeErrorCode: e.error.stripeErrorCode,
        arabic: AppLocalizations.currentLanguage != 'en',
      );
      if (mapped != null && mapped.isNotEmpty) return mapped;
      final message = e.error.localizedMessage ?? e.error.message ?? '';
      final net = stripeNetworkMessage(message,
          arabic: AppLocalizations.currentLanguage != 'en');
      if (net != null) return net;
      if (message.isNotEmpty) return message;
      return AppLocalizations.t('subPayFailed');
    }
    if (e is _FyonaPaymentMessage) return e.message;
    return AppLocalizations.t('subPayCouldNot');
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accent;
    final onAccent = _onAccent;
    // Tapping outside inputs dismisses the keyboard; it reappears on the
    // next input tap. Buttons keep working (child taps win the arena).
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(_tr('subPayCardTitle', 'الدفع بالبطاقة'),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 17),
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary)),
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          color: AppColors.textPrimary,
          onPressed: _paying ? null : () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _planHeader(accent, onAccent),
            SizedBox(height: R.spacing(context, AppSpacing.lg)),
            _summaryCard(accent),
            SizedBox(height: R.spacing(context, AppSpacing.lg)),
            _cardFormCard(accent),
            SizedBox(height: R.spacing(context, AppSpacing.md)),
            // No pre-payment save option (§2): the save prompt appears only
            // AFTER a backend-confirmed successful payment. When renewal is
            // already enabled we show a read-only status banner instead.
            if (_renewKnownEnabled) _renewEnabledBanner(),
            if (_renewKnownEnabled)
              SizedBox(height: R.spacing(context, AppSpacing.md)),
            SizedBox(height: R.spacing(context, AppSpacing.lg)),
            _payButton(accent, onAccent),
            if (_phase.isNotEmpty) ...[
              const SizedBox(height: 12),
              Center(
                child: Text(_phase,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 12),
                        color: AppColors.textSecondary)),
              ),
            ],
            SizedBox(height: R.spacing(context, AppSpacing.sm)),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_outline,
                    size: 13, color: AppColors.textTertiary),
                const SizedBox(width: 6),
                Text(_tr('subPaySecuredByStripe', 'دفع آمن عبر Stripe'),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11),
                        color: AppColors.textTertiary)),
              ],
            ),
          ],
        ),
      ),
    ));
  }

  Widget _planHeader(Color accent, Color onAccent) {
    return Container(
      padding: EdgeInsets.all(R.spacing(context, 16)),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [accent.withAlpha(46), accent.withAlpha(12)],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: BorderRadius.circular(AppRadius.cardRadius),
        border: Border.all(color: accent.withAlpha(90), width: 1.2),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.workspace_premium_rounded,
                color: onAccent, size: 24),
          ),
          SizedBox(width: R.spacing(context, AppSpacing.md)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.planName.isNotEmpty ? widget.planName : '—',
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 16),
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary)),
                Text(
                    widget.period == 'yearly'
                        ? _tr('subPayYearly', 'اشتراك سنوي')
                        : _tr('subPayMonthly', 'اشتراك شهري'),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 12),
                        color: AppColors.textSecondary)),
              ],
            ),
          ),
          Text(
            '${fmtNum(widget.displayAmount)} ${currencySymbol(widget.displayCurrency)}',
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 17),
                fontWeight: FontWeight.w900,
                color: accent),
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(Color accent) {
    Widget row(String label, String value, {bool strong = false}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Text(label,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    color: AppColors.textSecondary)),
            const Spacer(),
            Text(value,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
                    color: strong ? accent : AppColors.textPrimary)),
          ],
        ),
      );
    }

    return Container(
      padding: EdgeInsets.all(R.spacing(context, 16)),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_tr('subPaySummary', 'ملخص الدفع'),
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 14),
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          row(_tr('subPayPlan', 'الباقة'),
              widget.planName.isNotEmpty ? widget.planName : '—'),
          row(
              _tr('subPayPeriod', 'المدة'),
              widget.period == 'yearly'
                  ? _tr('subPayYearly', 'سنوي')
                  : _tr('subPayMonthly', 'شهري')),
          row(_tr('subPayCurrency', 'العملة'), widget.displayCurrency),
          const Divider(height: 18),
          row(
              _tr('subPayTotal', 'الإجمالي'),
              '${fmtNum(widget.displayAmount)} ${currencySymbol(widget.displayCurrency)}',
              strong: true),
        ],
      ),
    );
  }

  Widget _cardFormCard(Color accent) {
    return Container(
      padding: EdgeInsets.all(R.spacing(context, 16)),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: accent.withAlpha(70), width: 1.2),
        borderRadius: BorderRadius.circular(AppRadius.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.credit_card_rounded, color: accent, size: 20),
              const SizedBox(width: 8),
              Text(_tr('subPayCardDetails', 'بيانات البطاقة'),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 14),
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary)),
            ],
          ),
          const SizedBox(height: 12),
          Directionality(
            textDirection: TextDirection.ltr,
                  child: CardField(
                      onCardChanged: (card) {
                        final done = card?.complete ?? false;
                        setState(() => _cardComplete = done);
                        // Card finished: dismiss the keyboard automatically.
                        // It reappears on the next input tap.
                        if (done) FocusScope.of(context).unfocus();
                      },
              decoration: InputDecoration(
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    borderSide: BorderSide(color: AppColors.border)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    borderSide: BorderSide(color: accent, width: 1.6)),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              ),
              style: TextStyle(
                  fontSize: 15, color: AppColors.textPrimary),
              cursorColor: accent,
              numberHintText: '1234 1234 1234 1234',
              expirationHintText: 'MM/YY',
              cvcHintText: 'CVC',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                  child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: PaymentMethodIcons.visa())),
              Expanded(
                  child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: PaymentMethodIcons.mastercard())),
              Expanded(
                  child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: PaymentMethodIcons.mada())),
              Expanded(
                  child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: PaymentMethodIcons.stripe())),
            ],
          ),
        ],
      ),
    );
  }

  /// Read-only banner shown when auto-renewal is already enabled (§4: no
  /// in-app toggle, no disable option — informational only).
  Widget _renewEnabledBanner() {
    return Container(
      padding: EdgeInsets.all(R.spacing(context, 14)),
      decoration: BoxDecoration(
        color: AppColors.success.withAlpha(10),
        borderRadius: BorderRadius.circular(AppRadius.cardRadius),
        border: Border.all(color: AppColors.success.withAlpha(70)),
      ),
      child: Row(
        children: [
          Icon(Icons.autorenew_rounded,
              size: 18, color: AppColors.success),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                _tr('autoRenewOn', 'التجديد التلقائي مفعل'),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    fontWeight: FontWeight.w700,
                    color: AppColors.success)),
          ),
        ],
      ),
    );
  }

  Widget _payButton(Color accent, Color onAccent) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          disabledBackgroundColor: AppColors.surfaceVariant,
          disabledForegroundColor: AppColors.textDisabled,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.buttonRadius),
          ),
          elevation: 0,
        ),
        onPressed: _paying ? null : _pay,
        child: _paying
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: onAccent,
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_outline, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    '${_tr('subPayNow', 'ادفع الآن')} • ${fmtNum(widget.displayAmount)} ${currencySymbol(widget.displayCurrency)}',
                    style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontWeight: FontWeight.bold,
                        fontSize: 14),
                  ),
                ],
              ),
      ),
    );
  }
}

class _FyonaPaymentMessage implements Exception {
  const _FyonaPaymentMessage(this.message);
  final String message;
}
