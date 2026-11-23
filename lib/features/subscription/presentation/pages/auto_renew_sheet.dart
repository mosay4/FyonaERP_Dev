import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:go_router/go_router.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_exceptions.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/core/theme/app_radius.dart';
import 'package:fyona_flutter/core/theme/app_spacing.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'package:fyona_flutter/core/utils/subscription_identity.dart';
import 'package:fyona_flutter/shared/widgets/confirm_dialog.dart';
import 'package:fyona_flutter/shared/widgets/connectivity_widgets.dart';
import 'package:fyona_flutter/features/subscription/di/subscription_providers.dart';
import 'package:fyona_flutter/features/subscription/presentation/providers/subscription_providers.dart';
import 'package:fyona_flutter/features/subscription/presentation/widgets/stripe_error_messages.dart';
import 'package:fyona_flutter/features/auth/presentation/providers/auth_provider.dart';

/// Auto-renew activation / card replacement: explicit consent + card save
/// via Stripe SetupIntent.
///
/// Card data stays inside the Stripe SDK (CardField). After SetupIntent
/// success the saved method is attached to the subscription server-side.
/// Also serves renewal recovery (expired-card notice tap): plan/period
/// resolve from the live subscription status when not passed explicitly.
/// Returns `true` when auto-renew is active.
class AutoRenewSheet extends ConsumerStatefulWidget {
  final String? planName;
  final String period;

  const AutoRenewSheet({
    super.key,
    this.planName,
    this.period = 'yearly',
  });

  /// Opens the sheet; resolves `true` when auto-renew was enabled.
  static Future<bool?> push(
    BuildContext context, {
    String? planName,
    String period = 'yearly',
  }) {
    return Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AutoRenewSheet(planName: planName, period: period),
      ),
    );
  }

  @override
  ConsumerState<AutoRenewSheet> createState() => _AutoRenewSheetState();
}

class _AutoRenewSheetState extends ConsumerState<AutoRenewSheet> {
  bool _consent = false;
  bool _cardComplete = false;
  bool _working = false;
  String? _stripePlanId;
  String? _effPlanName;
  String _effPeriod = 'yearly';

  @override
  void initState() {
    super.initState();
    // Renewal-recovery entry (notice tap): resolve plan/period from the
    // live subscription status snapshot when the caller didn't pass them.
    try {
      final data = ref.read(subscriptionStatusProvider).valueOrNull ?? {};
      final p = (data['plan_name'] ?? data['plan'] ?? '').toString();
      if (p.isNotEmpty) _effPlanName = p;
      final per = (data['period'] ?? '').toString();
      if (per == 'monthly' || per == 'yearly') _effPeriod = per;
    } catch (_) {}
    _effPlanName ??= widget.planName;
    if (widget.period == 'monthly' || widget.period == 'yearly') {
      _effPeriod = widget.period;
    }
  }

  String _tr(String key, String fallback) =>
      AppLocalizations.of(context).translate(key) == key
          ? fallback
          : AppLocalizations.of(context).translate(key);

  Color get _accent => subscriptionIdentityColor(
      (_effPlanName ?? '').isNotEmpty ? _effPlanName! : 'personal');

  Future<void> _prepare() async {
    final service = ref.read(subscriptionServiceProvider);
    final plans = await service.getStripePlans();
    final active = plans.where((p) => p.isActive).toList();
    final want = _effPlanName ?? '';
    for (final p in active) {
      if (want.isNotEmpty &&
          (p.name == want || (p.nameEn != null && p.nameEn == want))) {
        _stripePlanId = p.id;
        break;
      }
    }
    _stripePlanId ??= active.isNotEmpty ? active.first.id : null;
  }

  Future<void> _activate() async {
    if (_working) return;
    if (!_consent) {
      showSnackbar(context,
          message: _tr('autoRenewConsentRequired', 'يجب الموافقة أولاً على حفظ وسيلة الدفع'),
          color: AppColors.warning);
      return;
    }
    if (!_cardComplete) {
      showSnackbar(context,
          message: _tr('subPayIncompleteCard', 'أكمل بيانات البطاقة أولاً'),
          color: AppColors.warning);
      return;
    }
    final connectivity = ref.read(connectivityServiceProvider);
    if (!connectivity.isOnline) {
      await showOfflineDialog(context, connectivity: connectivity);
      return;
    }
    setState(() => _working = true);
    try {
      final service = ref.read(subscriptionServiceProvider);
      if (_stripePlanId == null) await _prepare();
      final planId = _stripePlanId;
      if (planId == null || planId.isEmpty) {
        throw Exception(AppLocalizations.of(context).translate('subPayNoPlans'));
      }
      // 1) SetupIntent (backend owns customer + secret; no card data here).
      final setup = await service.createAutoRenewSetupIntent();
      final setupSecret = setup['client_secret'] ?? '';
      final setupKey = setup['publishable_key'] ?? '';
      if (setupSecret.isEmpty) {
        throw Exception(AppLocalizations.t('subPayFailed'));
      }
      if (setupKey.isNotEmpty) Stripe.publishableKey = setupKey;
      if (!mounted) return;
      // 2) Confirm inside the Stripe SDK (3DS/SCA handled natively).
      final confirmed = await Stripe.instance.confirmSetupIntent(
        paymentIntentClientSecret: setupSecret,
        params: PaymentMethodParams.card(
          paymentMethodData: PaymentMethodData(),
        ),
      );
      final pmId = confirmed.paymentMethodId;
      if (pmId == null || pmId.isEmpty) {
        throw Exception(AppLocalizations.t('subPayFailed'));
      }
      // 3) Attach + subscribe server-side (price from plan config).
      final result = await service.enableAutoRenew(
        planId: planId,
        period: _effPeriod,
        paymentMethodId: pmId,
        consent: true,
      );
      // 4) First charge may need 3DS — complete it when asked, then
      // verify it actually completed before claiming success.
      final needsAction = result['requires_action'] == true;
      final actionSecret = result['client_secret']?.toString() ?? '';
      if (needsAction && actionSecret.isNotEmpty && mounted) {
        await Stripe.instance.confirmPayment(
          paymentIntentClientSecret: actionSecret,
        );
        if (!mounted) return;
        try {
          final st2 = await service.autoRenewStatus();
          if (st2['enabled'] != true) {
            showSnackbar(context,
                message: _tr('autoRenewActionIncomplete',
                    'لم تكتمل المصادقة بعد — أعد المحاولة لإتمام أول دفعة.'),
                color: AppColors.warning);
            return;
          }
        } catch (_) {}
      }
      ref.invalidate(subscriptionStatusProvider);
      ref.invalidate(subscriptionPlansProvider);
      unawaited(ref.read(authProvider.notifier).refreshProfile());
      if (!mounted) return;
      showSnackbar(context,
          message: _tr('autoRenewEnabled', 'تم تفعيل التجديد التلقائي'),
          color: AppColors.success);
      context.pop(true);
    } catch (e) {
      if (!mounted) return;
      // Diagnostic breadcrumb (logcat only): full native error so the exact
      // Stripe code can be read if the generic message persists.
      try {
        if (e is StripeException) {
          debugPrint(
              'FYONA_DIAG setupConfirm code=${e.error.code} '
              'stripe=${e.error.stripeErrorCode} decline=${e.error.declineCode} '
              'msg=${e.error.message} loc=${e.error.localizedMessage}');
        } else {
          debugPrint('FYONA_DIAG setupConfirm other=$e');
        }
      } catch (_) {}
      final canceled =
          e is StripeException && e.error.code == FailureCode.Canceled;
      showSnackbar(context,
          message: canceled
              ? AppLocalizations.t('subPayCancelled')
              : _friendlyError(e),
          color: canceled ? AppColors.info : AppColors.danger);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String _friendlyError(Object e) {
    if (e is ApiException) return e.message;
    if (e is StripeException) {
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
    return AppLocalizations.t('subPayCouldNot');
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accent;
    // Tapping outside inputs dismisses the keyboard; it reappears on the
    // next input tap. Buttons keep working (child taps win the arena).
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(_tr('autoRenewEnableTitle', 'تفعيل التجديد التلقائي'),
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
          onPressed: _working ? null : () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Container(
              padding: EdgeInsets.all(R.spacing(context, 16)),
              decoration: BoxDecoration(
                color: accent.withAlpha(12),
                borderRadius: BorderRadius.circular(AppRadius.cardRadius),
                border: Border.all(color: accent.withAlpha(80), width: 1.2),
              ),
              child: Row(
                children: [
                  Icon(Icons.autorenew_rounded, color: accent, size: 26),
                  SizedBox(width: R.spacing(context, AppSpacing.md)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text((_effPlanName ?? '').isNotEmpty ? _effPlanName! : '—',
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: R.fontSize(context, 15),
                                fontWeight: FontWeight.w800,
                                color: AppColors.textPrimary)),
                        Text(
                            _effPeriod == 'yearly'
                                ? _tr('subPayYearly', 'تجديد سنوي تلقائي')
                                : _tr('subPayMonthly', 'تجديد شهري تلقائي'),
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: R.fontSize(context, 12),
                                color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: R.spacing(context, AppSpacing.lg)),
            Container(
              padding: EdgeInsets.all(R.spacing(context, 16)),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(AppRadius.cardRadius),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_tr('autoRenewCardTitle', 'بطاقة التجديد'),
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 14),
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary)),
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
                            borderRadius:
                                BorderRadius.circular(AppRadius.sm),
                            borderSide:
                                BorderSide(color: AppColors.border)),
                        focusedBorder: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(AppRadius.sm),
                            borderSide:
                                BorderSide(color: accent, width: 1.6)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 13),
                      ),
                      style: TextStyle(
                          fontSize: 15, color: AppColors.textPrimary),
                      cursorColor: accent,
                      numberHintText: '1234 1234 1234 1234',
                      expirationHintText: 'MM/YY',
                      cvcHintText: 'CVC',
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: R.spacing(context, AppSpacing.md)),
            GestureDetector(
              onTap: _working
                  ? null
                  : () => setState(() => _consent = !_consent),
              child: Container(
                padding: EdgeInsets.all(R.spacing(context, 14)),
                decoration: BoxDecoration(
                  color: _consent
                      ? AppColors.success.withAlpha(10)
                      : AppColors.surface,
                  border: Border.all(
                      color: _consent
                          ? AppColors.success
                          : AppColors.border,
                      width: _consent ? 1.6 : 1),
                  borderRadius: BorderRadius.circular(AppRadius.cardRadius),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                        _consent
                            ? Icons.check_box_rounded
                            : Icons.check_box_outline_blank_rounded,
                        color: _consent
                            ? AppColors.success
                            : AppColors.textSecondary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                          _tr('autoRenewConsent',
                              'أوافق على حفظ وسيلة الدفع واستخدامها تلقائيًا لتجديد الاشتراك عند انتهاء مدته.'),
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 13),
                              height: 1.6,
                              color: AppColors.textPrimary)),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: R.spacing(context, AppSpacing.lg)),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.success,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppColors.surfaceVariant,
                  shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(AppRadius.buttonRadius),
                  ),
                  elevation: 0,
                ),
                onPressed: _working ? null : _activate,
                child: _working
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: Colors.white))
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.lock_outline, size: 16),
                          const SizedBox(width: 8),
                          Text(
                              _tr('autoRenewConfirm',
                                  'تفعيل التجديد التلقائي'),
                              style: const TextStyle(
                                  fontFamily: 'Cairo',
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14)),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    ));
  }
}
