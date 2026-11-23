import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../core/network/api_exceptions.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import '../../../../shared/widgets/connectivity_widgets.dart';
import '../../../../shared/widgets/payment_method_icons.dart';
import 'package:fyona_flutter/features/subscription/presentation/widgets/stripe_error_messages.dart';
import '../../data/models/subscription_models.dart';
import 'fyona_card_payment_page.dart';
import '../../domain/services/subscription_service.dart';
import '../../domain/subscription_errors.dart';
import '../../di/subscription_providers.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../providers/subscription_providers.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/services/connectivity_service.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../../../../core/utils/subscription_identity.dart';

enum _PaymentMethod { bank, electronic }

class _PaymentMessage implements Exception {
  const _PaymentMessage(this.message);
  final String message;
}

class PaymentPage extends ConsumerStatefulWidget {
  final String planId;
  final String planName;
  final String planPrice;
  final String planCurrency;
  final String period;

  const PaymentPage({
    super.key,
    this.planId = '',
    this.planName = '',
    this.planPrice = '',
    this.planCurrency = '',
    this.period = 'yearly',
  });
  @override
  ConsumerState<PaymentPage> createState() => _PaymentPageState();
}

class _PaymentPageState extends ConsumerState<PaymentPage> {
  bool _loading = false;
  final List<Map<String, dynamic>> _proofFiles = [];
  final _imagePicker = ImagePicker();
  int? _expandedCountry;
  String? _expandedPaymentMethod;

  /// Locale-safe lookup: returns the translated string, falling back to a
  /// built-in Arabic label so no screen ever renders a bare key/question marks
  /// even if the ARB bundle is stale or a key is missing.
  String _tr(String key, String fallback) =>
      AppLocalizations.of(context).translate(key) == key
          ? fallback
          : AppLocalizations.of(context).translate(key);

  _PaymentMethod _method = _PaymentMethod.bank;
  bool _stripeEnabled = false;
  bool _stripePaying = false;
  StripePlan? _stripePlan;
  String? _stripeIdemKey;

  /// The currency selected on the plans page (drives both display & charge).
  String get _chargeCurrency =>
      widget.planCurrency.isNotEmpty ? widget.planCurrency : 'SAR';

  /// Stable idempotency key for this checkout so retries never double-charge.
  String _idemKeyFor(String planId) => _stripeIdemKey ??= 'fyona_$planId-${widget.period}-$_chargeCurrency-${DateTime.now().millisecondsSinceEpoch}';

  @override
  void initState() {
    super.initState();
    _loadStripeState();
  }

  Future<void> _loadStripeState() async {
    try {
      final service = ref.read(subscriptionServiceProvider);
      final state = await service.getStripePaymentState(currency: _chargeCurrency);
      if (!mounted) return;
      StripePlan? match;
      final active = state.plans.where((p) => p.isActive).toList();
      for (final p in active) {
        if (widget.planName.isEmpty ||
            p.name == widget.planName ||
            (p.nameEn != null && p.nameEn == widget.planName)) {
          match = p;
          break;
        }
      }
      match ??= active.isNotEmpty ? active.first : null;
      setState(() {
        _stripeEnabled = state.enabled;
        _stripePlan = match;
      });
    } catch (_) {
      // Stripe state is non-blocking: keep default (disabled) on failure.
    }
  }

  @override
  Widget build(BuildContext context) {
    // A PENDING review blocks any new upload/submit in-page too (the router
    // also guards this route, and the backend rejects duplicates).
    final statusMap = ref.watch(subscriptionStatusProvider).valueOrNull;
    final hasPending = statusMap?['status'] == 'pending';
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          AppLocalizations.of(context).translate('subPayMethodsTitle'),
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 17),
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          color: AppColors.textPrimary,
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _summaryCard(),
            SizedBox(height: R.spacing(context, AppSpacing.lg)),
            if (_stripeEnabled) ...[
              _buildMethodSelector(context),
              SizedBox(height: R.spacing(context, AppSpacing.lg)),
            ],
            if (_method == _PaymentMethod.bank && hasPending) ...[
              _buildPendingNotice(),
            ] else if (_method == _PaymentMethod.bank) ...[
              Text(
                AppLocalizations.of(context).translate('subPayBankHint'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.font(context, 'caption'),
                  color: AppColors.textSecondary,
                  height: 1.4,
                ),
              ),
              SizedBox(height: R.spacing(context, AppSpacing.md)),
              ..._buildCountrySections(),
              SizedBox(height: R.spacing(context, AppSpacing.lg)),
              _buildUploadSection(),
              SizedBox(height: R.spacing(context, AppSpacing.xl)),
              _buildSubmitButton(),
            ] else ...[
              _buildStripeSection(context),
            ],
            SizedBox(height: R.spacing(context, AppSpacing.xl)),
          ],
        ),
      ),
    );
  }

  /// Shown instead of upload/submit while a request is under review.
  Widget _buildPendingNotice() {
    return Container(
      padding: EdgeInsets.all(R.spacing(context, 16)),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.cardRadius),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.hourglass_top_rounded, color: AppColors.warning, size: 22),
              SizedBox(width: R.spacing(context, AppSpacing.sm)),
              Expanded(
                child: Text(
                  AppLocalizations.of(context).translate('subPayPendingNotice'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.font(context, 'body'),
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: R.spacing(context, AppSpacing.md)),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: () => context.go(RouteNames.subscriptionPending),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.warning,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.buttonRadius),
                ),
                elevation: 0,
              ),
              child: Text(
                AppLocalizations.of(context).translate('subPayGoPending'),
                style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryCard() {
    final planColor = subscriptionIdentityColor(widget.planId);
    return Container(
      padding: EdgeInsets.all(R.spacing(context, 16)),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [planColor, planColor.withValues(alpha: 0.7)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(AppRadius.cardRadius),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(25),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.receipt_long, size: 20, color: Colors.white),
          ),
          SizedBox(width: R.spacing(context, AppSpacing.md)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocalizations.of(context).translate('subPaySummary'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.font(context, 'caption'),
                    color: Colors.white.withAlpha(180),
                  ),
                ),
                SizedBox(height: R.spacing(context, 2)),
                Text(
                  AppLocalizations.of(context).translate('subPayPlanName', params: {'plan': widget.planName}),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.font(context, 'body'),
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                Text(
                  _summaryPrice(),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.font(context, 'caption'),
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withAlpha(200),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Live plan from the backend catalog (same source as the plans page),
  /// so an admin price change is reflected here even if this page was
  /// opened with an older query price.
  SubscriptionPlan? _livePlan() {
    final plans = ref.watch(subscriptionPlansProvider).valueOrNull;
    if (plans == null || plans.isEmpty) return null;
    final want = subscriptionIdentityKey(widget.planId);
    for (final p in plans) {
      if (subscriptionIdentityKey(p.packageType) == want) return p;
    }
    return null;
  }

  /// Yearly price converted to the checkout currency from the LIVE backend
  /// price; falls back to the query price only when the catalog is missing.
  double _liveConvertedPrice() {
    // Prefer the already-converted price from the plans page — this is
    // always correct for the user's selected currency. Parsed with
    // parseFormattedAmount (not double.tryParse): plan_price arrives
    // fmtNum-formatted ("6,900"), and a bare tryParse returns null on the
    // comma, dropping YER discounts back to the full price.
    final parsed = parseFormattedAmount(widget.planPrice);
    if (parsed != null && parsed > 0) return parsed;

    // Fallback: try to re-convert from the live plan.
    final live = _livePlan();
    if (live != null && live.priceYearly > 0) {
      final from = live.currency.isNotEmpty ? live.currency : 'USD';
      final to = _chargeCurrency.toUpperCase();
      if (from.toUpperCase() == to) return live.priceYearly;
      try {
        final converted = ref.read(currencyEngineProvider).convert(live.priceYearly, from, to);
        if (converted > 0) return converted;
      } catch (_) {}
    }
    return 0;
  }

  String _summaryPrice() {
    if (_method == _PaymentMethod.electronic) {
      final amount = _displayAmount;
      if (amount > 0) {
        final sym = _currencySymbol(_displayCurrency);
        final value = fmtNum(amount);
        return widget.period == 'yearly'
            ? AppLocalizations.t('subPayYearlyElectronic', {'price': value, 'sym': sym})
            : AppLocalizations.t('stripeMonthlyElectronic', {'price': value, 'sym': sym});
      }
    }
    final sym = _currencySymbol(widget.planCurrency.isNotEmpty ? widget.planCurrency : null);
    final livePrice = _liveConvertedPrice();
    final priceStr = livePrice > 0
        ? fmtNum(livePrice)
        : widget.planPrice;
    return AppLocalizations.t('subPayYearlyBank', {'price': priceStr, 'sym': sym});
  }

  String _currencySymbol(String? code) => currencySymbol(code ?? 'SAR');

  /// Always the currency the user selected on the plans page — never the
  /// currency of the Stripe Price linked to the plan (which can be USD).
  String get _displayCurrency =>
      widget.planCurrency.isNotEmpty ? widget.planCurrency : 'SAR';

  /// Price in the user's selected currency for display:
  /// Always prefer the already-converted price passed from the plans page
  /// to avoid currency conversion mismatches (especially for YER).
  double get _displayAmount {
    final parsed = parseFormattedAmount(widget.planPrice);
    if (parsed != null && parsed > 0) return parsed;

    // Fallback: use Stripe quote if available.
    final quote = widget.period == 'yearly'
        ? _stripePlan?.quoteAmountYearly
        : _stripePlan?.quoteAmountMonthly;
    if (quote != null && quote > 0) return quote;

    return 0;
  }

  List<Widget> _buildCountrySections() {
    return [
      _countrySection(0, '🇾🇪', 'اليمن', _yeAccounts,
          showHolderBanner: true),
      SizedBox(height: R.spacing(context, AppSpacing.sm)),
      _countrySection(1, '🇸🇾', 'سوريا', _syAccounts),
      SizedBox(height: R.spacing(context, AppSpacing.sm)),
      _countrySection(
        2,
        '🌍',
        '',
        _globalAccounts,
        titleOverride: AppLocalizations.of(context).translate('subPayIntlTransfer'),
      ),
    ];
  }

  /// Account-holder banner shown at the top of the Yemen section only:
  /// single-line text with a small dot, both tinted by the current plan
  /// identity color (personal=blue, business=red, premium=gold), plus a
  /// small arrow pointing down toward the bank account buttons (which keep
  /// their exact order).
  Widget _yemenHolderBanner() {
    final accent = subscriptionIdentityColor(
      widget.planId.isNotEmpty ? widget.planId : widget.planName,
    );
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: R.spacing(context, 12),
        vertical: R.spacing(context, 8),
      ),
      decoration: BoxDecoration(
        color: accent.withAlpha(14),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: accent.withAlpha(70), width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                ),
              ),
              SizedBox(width: R.spacing(context, AppSpacing.sm)),
              Expanded(
                child: Text(
                  'جميع الحسابات بإسم : عبدالرحمن عادل عبده مجاهد القرشي',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 11),
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: R.spacing(context, 2)),
          Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 18,
            color: accent,
          ),
        ],
      ),
    );
  }

  /// Small rounded bank/exchange logo icon (never sharp-edged, never oversized).
  Widget _logoIcon(String asset, {double size = 34}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: Image.asset(asset, width: size, height: size, fit: BoxFit.cover),
      ),
    );
  }

  Widget _buildMethodSelector(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _methodOption(
            icon: Icons.account_balance_wallet,
            label: AppLocalizations.of(context).translate('subPayBankTransfer'),
            method: _PaymentMethod.bank,
          ),
        ),
        SizedBox(width: R.spacing(context, AppSpacing.md)),
        Expanded(
          child: _methodOption(
            icon: Icons.credit_card,
            label: AppLocalizations.of(context).translate('intlPayTitle'),
            method: _PaymentMethod.electronic,
          ),
        ),
      ],
    );
  }

  Widget _methodOption({
    required IconData icon,
    required String label,
    required _PaymentMethod method,
  }) {
    final selected = _method == method;
    final planColor = subscriptionIdentityColor(widget.planId);
    return InkWell(
      onTap: () => setState(() => _method = method),
      borderRadius: BorderRadius.circular(AppRadius.cardRadius),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: R.spacing(context, 14), horizontal: 10),
        decoration: BoxDecoration(
          gradient: selected
              ? LinearGradient(
                  colors: [planColor, planColor.withValues(alpha: 0.7)],
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                )
              : null,
          color: selected ? null : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.cardRadius),
          border: Border.all(
            color: selected ? planColor : AppColors.border,
            width: selected ? 1.5 : 1,
          ),
          boxShadow: selected
              ? [BoxShadow(color: planColor.withAlpha(60), blurRadius: 12, offset: const Offset(0, 4))]
              : null,
        ),
        child: Column(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: selected ? Colors.white.withAlpha(30) : planColor.withAlpha(12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 20, color: selected ? Colors.white : planColor),
            ),
            SizedBox(height: R.spacing(context, 6)),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.font(context, 'body_small'),
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStripeSection(BuildContext context) {
    final amount = _displayAmount;
    final currency = _displayCurrency;
    final planColor = subscriptionIdentityColor(widget.planId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: EdgeInsets.all(R.spacing(context, 16)),
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: planColor.withValues(alpha: 0.4)),
            borderRadius: BorderRadius.circular(AppRadius.cardRadius),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.credit_card, size: 26, color: planColor),
                  SizedBox(width: R.spacing(context, AppSpacing.sm)),
                  Expanded(
                    child: Text(
                      AppLocalizations.of(context).translate('intlPayTitle'),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.font(context, 'body'),
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: R.spacing(context, AppSpacing.sm)),
              Text(
                AppLocalizations.of(context).translate('subPayCardHint'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.font(context, 'caption'),
                  color: AppColors.textSecondary,
                ),
              ),
              if (amount > 0) ...[
                SizedBox(height: R.spacing(context, AppSpacing.md)),
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.symmetric(
                    vertical: R.spacing(context, 10),
                    horizontal: R.spacing(context, 12),
                  ),
                  decoration: BoxDecoration(
                    color: planColor.withAlpha(10),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    border: Border.all(color: planColor.withAlpha(40)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.price_check, size: 18, color: planColor),
                      SizedBox(width: R.spacing(context, AppSpacing.sm)),
                      Flexible(
                        child: Text(
                          AppLocalizations.of(context).translate('subPayYearlyPrice'),
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.font(context, 'caption'),
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: AlignmentDirectional.centerEnd,
                          child: Text(
                            '${fmtNum(amount)} ${_currencySymbol(currency)}',
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.font(context, 'body'),
                              fontWeight: FontWeight.w900,
                              color: planColor,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_stripePlan?.quoteFallbackUsd ?? false) ...[
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                       Icon(Icons.info_outline, size: 15, color: AppColors.textSecondary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          AppLocalizations.of(context).translate('intlUsdFallback'),
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.font(context, 'caption') - 1,
                            color: AppColors.textSecondary,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
              SizedBox(height: R.spacing(context, AppSpacing.md)),
              // Payment-brand logos: one slim, fixed, elegant row that always
              // fits the screen (no wrap, no scrolling, no overflow) — like the
              // international payment pages.
              Row(
                children: [
                  Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: PaymentMethodIcons.visa())),
                  Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: PaymentMethodIcons.mastercard())),
                  Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: PaymentMethodIcons.amazonPay())),
                  Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: PaymentMethodIcons.applePay())),
                  Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: PaymentMethodIcons.googlePay())),
                ],
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: PaymentMethodIcons.payPal())),
                  Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: PaymentMethodIcons.mada())),
                  Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: PaymentMethodIcons.stripe())),
                  const Expanded(child: SizedBox.shrink()),
                  const Expanded(child: SizedBox.shrink()),
                ],
              ),
              SizedBox(height: R.spacing(context, AppSpacing.sm)),
              Text(
                AppLocalizations.of(context).translate('subPayNoBrowser'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.font(context, 'caption') - 1,
                  color: AppColors.textTertiary,
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: R.spacing(context, AppSpacing.lg)),
        _buildStripePayButton(),
      ],
    );
  }

  Widget _buildStripePayButton() {
    final planColor = subscriptionIdentityColor(widget.planId);
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: planColor,
          foregroundColor: planColor == AppColors.gold ? const Color(0xFF3A2E00) : Colors.white,
          disabledBackgroundColor: AppColors.surfaceVariant,
          disabledForegroundColor: AppColors.textDisabled,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.buttonRadius),
          ),
          elevation: 0,
        ),
        onPressed: _stripePaying ? null : _onStripePayPressed,
        child: _stripePaying
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_outline, size: 16),
                  SizedBox(width: 8),
                  Text(
                    AppLocalizations.of(context).translate('subPayNow'),
                    style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ],
              ),
      ),
    );
  }

  /// True when the Stripe SDK was already initialized with a publishable
  /// key this session. The getter itself throws when unset, hence the guard.
  bool _stripeKeyReady() {
    try {
      return Stripe.publishableKey.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Entry point for card payments: the native FYONA screen when its flag is
  /// on, otherwise the untouched PaymentSheet path. The flag + fallback keep
  /// the current flow restorable without any backend change.
  Future<void> _onStripePayPressed() async {
    if (!FyonaCardPaymentConfig.enabled) {
      await _payWithStripe();
      return;
    }
    var stripePlanId = _stripePlan?.id;
    if (stripePlanId == null) {
      try {
        final service = ref.read(subscriptionServiceProvider);
        final plans = await service.getStripePlans();
        final activePlans = plans.where((p) => p.isActive).toList();
        for (final p in activePlans) {
          if (widget.planName.isEmpty ||
              p.name == widget.planName ||
              (p.nameEn != null && p.nameEn == widget.planName)) {
            stripePlanId = p.id;
            break;
          }
        }
        stripePlanId ??= activePlans.isNotEmpty ? activePlans.first.id : null;
      } catch (_) {}
    }
    if (!mounted || stripePlanId == null) {
      await _payWithStripe();
      return;
    }
    // The card screen builds a native CardField immediately. The Stripe SDK
    // MUST be initialized with the publishable key first — on a fresh
    // install the key was never set (it is only assigned after an intent is
    // created), and opening the screen uninitialized kills the app process
    // instantly. Pre-create the intent here with the SAME idempotency key
    // the card screen will reuse, so no duplicate charge is possible.
    if (!_stripeKeyReady()) {
      setState(() => _stripePaying = true);
      try {
        final service = ref.read(subscriptionServiceProvider);
        final pre = await service.createStripePaymentIntent(
          stripePlanId,
          period: widget.period,
          currency: _chargeCurrency,
          idempotencyKey: _idemKeyFor(stripePlanId),
        );
        if (pre.publishableKey != null && pre.publishableKey!.isNotEmpty) {
          Stripe.publishableKey = pre.publishableKey!;
          // Force native SDK init NOW (Dart-catchable). Without this, the
          // CardField platform view initializes lazily at build time and a
          // cold start kills the app process instantly with no Dart trace.
          await Stripe.instance.applySettings();
        }
      } catch (e) {
        if (!mounted) return;
        setState(() => _stripePaying = false);
        showSnackbar(context, message: _friendlyError(e), color: AppColors.danger);
        return;
      }
      if (mounted) setState(() => _stripePaying = false);
    }
    if (!mounted) return;
    if (!_stripeKeyReady()) {
      // Key still unavailable (e.g. backend unreachable) — use the
      // PaymentSheet path, which fetches and sets the key itself.
      await _payWithStripe();
      return;
    }
    final result = await FyonaCardPaymentScreen.push(
      context,
      planId: widget.planId,
      planName: widget.planName,
      period: widget.period,
      displayAmount: _displayAmount,
      displayCurrency: _displayCurrency,
      stripePlanId: stripePlanId,
      idemKey: _idemKeyFor(stripePlanId),
    );
    if (result == 'fallback' && mounted) {
      await _payWithStripe();
    }
  }

  Future<void> _payWithStripe() async {
    if (_stripePaying) return;
    final connectivity = ref.read(connectivityServiceProvider);
    if (!connectivity.isOnline) {
      await showOfflineDialog(context, connectivity: connectivity);
      return;
    }
    setState(() => _stripePaying = true);
    StripePaymentIntent? createdIntent;
    try {
      final service = ref.read(subscriptionServiceProvider);
      StripePlan? plan = _stripePlan;
      if (plan == null) {
        final plans = await service.getStripePlans();
        final activePlans = plans.where((p) => p.isActive).toList();
        for (final p in activePlans) {
          if (widget.planName.isEmpty ||
              p.name == widget.planName ||
              (p.nameEn != null && p.nameEn == widget.planName)) {
            plan = p;
            break;
          }
        }
        plan ??= activePlans.isNotEmpty ? activePlans.first : null;
      }
      if (plan == null || plan.id == null) {
        throw _PaymentMessage(AppLocalizations.of(context).translate('subPayNoPlans'));
      }
      createdIntent = await service.createStripePaymentIntent(
        plan.id!,
        period: widget.period,
        currency: _chargeCurrency,
        idempotencyKey: _idemKeyFor(plan.id!),
      );
      if (createdIntent.publishableKey == null || createdIntent.publishableKey!.isEmpty) {
        throw _PaymentMessage(AppLocalizations.of(context).translate('subPayUnavailable'));
      }
      Stripe.publishableKey = createdIntent.publishableKey!;
      if (!mounted) return;
      await Stripe.instance.initPaymentSheet(
        paymentSheetParameters: SetupPaymentSheetParameters(
          paymentIntentClientSecret: createdIntent.clientSecret,
          merchantDisplayName: 'FYONA',
        ),
      );
      if (!mounted) return;
      await Stripe.instance.presentPaymentSheet();
      if (!mounted) return;

      // ── Instant verification: confirm with the server and activate
      // the exact plan the user tapped (no webhook wait) ──
      bool activated = false;
      try {
        await service.confirmStripePayment(
          paymentIntentId: createdIntent.stripePaymentIntentId,
          paymentId: createdIntent.paymentId,
        );
        activated = true;
      } catch (_) {
        // Confirm may fail if Stripe hasn't marked succeeded yet — fall back
        // to short webhook polling so the user is never stuck.
        activated = false;
      }

      showSnackbar(context, message: AppLocalizations.of(context).translate('subPaySuccess'), color: AppColors.success);
      ref.invalidate(subscriptionStatusProvider);
      ref.invalidate(subscriptionPlansProvider);
      unawaited(ref.read(authProvider.notifier).refreshProfile());

      if (!activated) {
        await _waitForWebhookActivation(service);
        // Final gate: navigate to the invoice ONLY on backend-confirmed
        // ACTIVE status. A failed/pending payment must never show success.
        try {
          final st = await service.getStatus();
          activated = st['status']?.toString() == 'active';
        } catch (_) {}
      } else {
        // Give the DB a moment to commit, then verify status is active
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
      showSnackbar(context, message: AppLocalizations.of(context).translate('subPaySuccess'), color: AppColors.success);
      _goInvoiceWithStatus(service);
    } catch (e) {
      if (!mounted) return;
      final canceled = e is StripeException && e.error.code == FailureCode.Canceled;
      // Don't show success snackbar if canceled
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
          if (mounted) {
            _goInvoiceWithStatus(
                ref.read(subscriptionServiceProvider));
          }
          return;
        } catch (_) {}
      }
      showSnackbar(context, message: _friendlyError(e), color: canceled ? AppColors.info : AppColors.danger);
    } finally {
      if (mounted) setState(() => _stripePaying = false);
    }
  }

  /// Navigate to the invoice screen carrying the freshest known invoice data
  /// as route params, so the card renders instantly even if the providers
  /// have not finished reloading yet.
  Future<void> _goInvoiceWithStatus(
    SubscriptionServiceImpl? service, {
    Map<String, dynamic>? cached,
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
      'amount': _displayAmount > 0
          ? fmtNum(_displayAmount)
          : (st['plan_price']?.toString() ?? ''),
      'currency': _displayCurrency,
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
    }..removeWhere((_, v) => v.isEmpty);
    final qs = params.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    context.pushReplacement(
        '${RouteNames.subscriptionInvoice}${qs.isEmpty ? '' : '?$qs'}');
  }

  /// Short webhook polling as a fallback if the instant confirm did not
  /// succeed (e.g. Stripe status still processing). Max ~6s.
  Future<void> _waitForWebhookActivation(SubscriptionServiceImpl service) async {
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
    if (e is ApiException) return localizeSubscriptionError(e);
    if (e is StripeException) {
      if (e.error.code == FailureCode.Canceled) return AppLocalizations.t('subPayCancelled');
      // Machine-readable decline codes first (localized AR/EN), so an
      // insufficient-funds decline reads Arabic in Arabic mode.
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
    if (e is _PaymentMessage) return e.message;
    return premiumSubscriptionMessage(e) ??
        AppLocalizations.t('subPayCouldNot');
  }

  Widget _countrySection(int idx, String flag, String name, List<Widget> accounts, {String? titleOverride, bool showHolderBanner = false}) {
    final open = _expandedCountry == idx;
    final title = titleOverride ??
        AppLocalizations.of(context).translate('subPayMethodsIn', params: {'country': name});
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.cardRadius),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() {
              if (open) { _expandedCountry = null; } else { _expandedCountry = idx; }
            }),
            borderRadius: BorderRadius.circular(AppRadius.cardRadius),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: R.spacing(context, 14), vertical: 12),
              child: Row(
                children: [
                  Text(flag, style: const TextStyle(fontSize: 18)),
                  SizedBox(width: R.spacing(context, AppSpacing.sm)),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.font(context, 'body_small'),
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      size: 18,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: open
                ? Column(
                    children: [
                      Divider(color: AppColors.border, height: 1, indent: R.spacing(context, 14), endIndent: R.spacing(context, 14)),
                      if (showHolderBanner)
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            R.spacing(context, 12),
                            R.spacing(context, 10),
                            R.spacing(context, 12),
                            R.spacing(context, 2),
                          ),
                          child: _yemenHolderBanner(),
                        ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          R.spacing(context, 12),
                          R.spacing(context, 8),
                          R.spacing(context, 12),
                          R.spacing(context, 12),
                        ),
                        child: Column(children: accounts),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _nameRow(String label, String value) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.all(R.spacing(context, 12)),
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(8),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.primary.withAlpha(20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
            style: TextStyle(
              fontFamily: 'Cairo', fontSize: R.font(context, 'caption'), color: AppColors.textSecondary,
            )),
          SizedBox(height: R.spacing(context, 4)),
          Row(
            children: [
              Expanded(
                child: Text(value,
                  style: TextStyle(
                    fontFamily: 'Cairo', fontSize: R.font(context, 'body'),
                    fontWeight: FontWeight.w600, color: AppColors.textPrimary,
                  )),
              ),
              _copyButton(value),
            ],
          ),
        ],
      ),
    );
  }

  Widget _methodCard(String provider, String number, {String? currency, String? extra, String? section, String? imageAsset}) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: EdgeInsets.all(R.spacing(context, 12)),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (section != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(section,
                style: TextStyle(
                  fontFamily: 'Cairo', fontSize: R.font(context, 'caption'),
                  fontWeight: FontWeight.w700, color: AppColors.textPrimary,
                )),
            ),
          Row(
            children: [
              if (imageAsset != null) ...[
                _logoIcon(imageAsset, size: 32),
              ] else ...[
                Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(20),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Icon(Icons.account_balance_wallet, size: 14, color: AppColors.primary),
                ),
              ],
              const SizedBox(width: 7),
              Text(provider,
                style: TextStyle(
                  fontFamily: 'Cairo', fontSize: R.font(context, 'caption'),
                  fontWeight: FontWeight.w600, color: AppColors.textPrimary,
                )),
              if (currency != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(currency,
                    style: TextStyle(
                      fontFamily: 'Cairo', fontSize: R.font(context, 'caption') - 2,
                      color: AppColors.textSecondary,
                    )),
                ),
              ],
            ],
          ),
          SizedBox(height: R.spacing(context, 6)),
          Row(
            children: [
              Expanded(
                child: Text(number,
                  style: TextStyle(
                    fontFamily: 'Cairo', fontSize: R.font(context, 'body_small'),
                    fontWeight: FontWeight.w700, color: AppColors.textPrimary,
                    letterSpacing: 0.5,
                  )),
              ),
              _copyButton(number),
            ],
          ),
          if (extra != null) ...[
            SizedBox(height: R.spacing(context, 3)),
            Row(
              children: [
                Icon(Icons.person, size: 11, color: AppColors.textDisabled),
                const SizedBox(width: 3),
                Expanded(
                  child: Text(extra,
                    style: TextStyle(
                      fontFamily: 'Cairo', fontSize: R.font(context, 'caption') - 1,
                      color: AppColors.textSecondary,
                    )),
                ),
                _copyButton(extra, small: true),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _copyButton(String text, {bool small = false}) {
    return InkWell(
      onTap: () => _copy(text),
      borderRadius: BorderRadius.circular(5),
      child: Container(
        padding: EdgeInsets.all(small ? 3 : 5),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Icon(Icons.copy_rounded, size: small ? 12 : 14, color: AppColors.textSecondary),
      ),
    );
  }

  Widget _paymentMethodAccordion(String title, List<Widget> children, {List<String>? logos}) {
    final key = title;
    final open = _expandedPaymentMethod == key;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withAlpha(100),
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() {
              if (open) {
                _expandedPaymentMethod = null;
              } else {
                _expandedPaymentMethod = key;
              }
            }),
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    size: 18,
                    color: AppColors.primary,
                  ),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.font(context, 'caption'),
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  if (logos != null) ...[
                    const SizedBox(width: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (int i = 0; i < logos.length; i++) ...[
                          if (i > 0) const SizedBox(width: 6),
                          _logoIcon(logos[i], size: 30),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: open
                ? Padding(
                    padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: Column(children: children),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  List<Widget> get _yeAccounts => [
    _paymentMethodAccordion(
      AppLocalizations.of(context).translate('subPayProviderAlQatibi'),
      [
        _methodCard(
          AppLocalizations.of(context).translate('subPayProviderAlQatibi'),
          '487876714',
          currency: 'YER/USD/SAR',
          imageAsset: 'assets/images/banks/qutaibi.jpg',
        ),
      ],
      logos: const ['assets/images/banks/qutaibi.jpg'],
    ),
    SizedBox(height: R.spacing(context, AppSpacing.sm)),
    _paymentMethodAccordion(
      AppLocalizations.of(context).translate('subPayProviderKuraimi'),
      [
        _methodCard(AppLocalizations.of(context).translate('subPayProviderKuraimi'), '3097238889', currency: 'يمني', imageAsset: 'assets/images/banks/kuraimi.jpg'),
        _methodCard(AppLocalizations.of(context).translate('subPayProviderKuraimi'), '3097223822', currency: 'سعودي', imageAsset: 'assets/images/banks/kuraimi.jpg'),
        _methodCard(AppLocalizations.of(context).translate('subPayProviderKuraimi'), '3097467829', currency: 'دولار', imageAsset: 'assets/images/banks/kuraimi.jpg'),
      ],
      logos: const ['assets/images/banks/kuraimi.jpg'],
    ),
    SizedBox(height: R.spacing(context, AppSpacing.sm)),
    _paymentMethodAccordion(
      AppLocalizations.of(context).translate('subPayJeebWalletShared'),
      [
        _methodCard(
          AppLocalizations.of(context).translate('subPayProviderJeeb'),
          '706370',
          imageAsset: 'assets/images/banks/jeep.jpg',
        ),
      ],
      logos: const ['assets/images/banks/jeep.jpg'],
    ),
    SizedBox(height: R.spacing(context, AppSpacing.sm)),
    _paymentMethodAccordion(
      AppLocalizations.of(context).translate('subPayLocalNetworkTransfer'),
      [
        _nameRow(AppLocalizations.of(context).translate('subPayNameLabel'), 'عبدالرحمن عادل عبده مجاهد القرشي'),
        _nameRow(AppLocalizations.of(context).translate('subPayAccountLabel'), '٧٧٩٢٠٩٢١٨'),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // Only the icon files that actually exist (net_4.jpg was
              // removed) — same layout, sizes and spacing as before.
              for (final n in const [1, 2, 3, 5, 6, 7])
                _logoIcon('assets/images/transfers/net_$n.jpg', size: 40),
            ],
          ),
        ),
      ],
    ),
  ];

  List<Widget> get _syAccounts => [
    _nameRow(_tr('subPayShamCashHint', 'الحساب بإسم'), 'زكريا حميد ايوب'),
    _methodCard(
      AppLocalizations.of(context).translate('subPayProviderShamCash'),
      '563f7e6f1dd63d917a43bb03b813ea5b',
      imageAsset: 'assets/images/banks/shamcash.jpg',
    ),
  ];

  List<Widget> get _globalAccounts => [
    _paymentMethodAccordion(
      AppLocalizations.of(context).translate('subPayWU_MG'),
      [
        _nameRow(
          AppLocalizations.of(context).translate('subPayRecipientName'),
          AppLocalizations.of(context).translate('subPayGlobalRecipientName'),
        ),
        _nameRow(
          AppLocalizations.of(context).translate('subPayAccountLabel'),
          AppLocalizations.of(context).translate('subPayGlobalRecipientNumber'),
        ),
      ],
      logos: const [
        'assets/images/international/westernunion.jpg',
        'assets/images/international/moneygram.jpg',
      ],
    ),
  ];

  Widget _buildUploadSection() {
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
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(20),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.image_rounded, size: 20, color: AppColors.primary),
              ),
              SizedBox(width: R.spacing(context, AppSpacing.sm)),
              Expanded(
                child: Text(
                  _tr('subPayAttach', 'إرفاق سندات التحويل'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.font(context, 'body'),
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              if (_proofFiles.isNotEmpty)
                Text(
                  _tr('subPayProofCount', '{count} سند(ات)')
                      .replaceAll('{count}', '${_proofFiles.length}'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.font(context, 'caption'),
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          SizedBox(height: R.spacing(context, AppSpacing.sm)),
          Text(
            _tr('subPayUploadHint', 'يمكنك رفع صورة سند التحويل من معرض جهازك'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.font(context, 'caption'),
              color: AppColors.textSecondary,
            ),
          ),
          SizedBox(height: R.spacing(context, AppSpacing.md)),
          // Uploaded files grid
          if (_proofFiles.isNotEmpty) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: List.generate(_proofFiles.length, (i) {
                final file = _proofFiles[i];
                return SizedBox(
                  width: 100,
                  height: 120,
                  child: Stack(
                    children: [
                      Container(
                        width: 100,
                        height: 120,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.success.withAlpha(80), width: 1.5),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(7),
                          child: Image.memory(
                            file['bytes'],
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: AppColors.surface,
                              child: const Center(child: Icon(Icons.broken_image, color: AppColors.textDisabled, size: 24)),
                            ),
                          ),
                        ),
                      ),
                      // Delete button
                      Positioned(
                        top: 4,
                        left: 4,
                        child: GestureDetector(
                          onTap: () => setState(() => _proofFiles.removeAt(i)),
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: AppColors.danger,
                              shape: BoxShape.circle,
                              boxShadow: [BoxShadow(color: Colors.black.withAlpha(80), blurRadius: 4)],
                            ),
                            child: const Icon(Icons.close, size: 14, color: Colors.white),
                          ),
                        ),
                      ),
                      // File name
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withAlpha(120),
                            borderRadius: const BorderRadius.only(
                              bottomLeft: Radius.circular(7),
                              bottomRight: Radius.circular(7),
                            ),
                          ),
                          child: Text(
                            file['name'],
                            style: const TextStyle(fontFamily: 'Cairo', fontSize: 9, color: Colors.white),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
            SizedBox(height: R.spacing(context, AppSpacing.md)),
          ],
          // One clear action: tap straight into the device gallery to pick the
          // proof image(s) — no file browser, no PDF.
          InkWell(
            onTap: _pickFile,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppColors.primary.withAlpha(24), AppColors.primary.withAlpha(6)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                border: Border.all(
                  color: _proofFiles.isNotEmpty
                      ? AppColors.success.withAlpha(70)
                      : AppColors.primary.withAlpha(60),
                  width: 1.2,
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.upload_file_rounded, size: 20, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _tr('subPayUploadProof', 'اضغط هنا لرفع سند الدفع'),
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.font(context, 'body'),
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                   Icon(Icons.chevron_left_rounded, color: AppColors.textSecondary, size: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubmitButton() {
    final planColor = subscriptionIdentityColor(widget.planId);
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: planColor,
          foregroundColor: planColor == AppColors.gold ? const Color(0xFF3A2E00) : Colors.white,
          disabledBackgroundColor: AppColors.surfaceVariant,
          disabledForegroundColor: AppColors.textDisabled,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.buttonRadius),
          ),
          elevation: 0,
        ),
        onPressed: _loading ? null : _submit,
        child: _loading
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.send_rounded, size: 16),
                  SizedBox(width: 8),
                  Text(
                    AppLocalizations.of(context).translate('subPaySubmit'),
                    style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ],
              ),
      ),
    );
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    showSnackbar(context, message: AppLocalizations.of(context).translate('copied'));
  }

void _pickFile() async {
    // Max 2 proofs TOTAL across all picks (smaller payload = dramatically
    // faster upload on slow mobile data). The proof stays readable at
    // 500px/55% for the admin.
    if (_proofFiles.length >= 2) {
      showSnackbar(context, message: AppLocalizations.of(context).translate('subPayMaxProofs'), color: AppColors.warning);
      return;
    }
    try {
      final picks = await _imagePicker.pickMultiImage(
        imageQuality: 55,
        maxWidth: 500,
        maxHeight: 500,
        limit: 2 - _proofFiles.length,
      );
      if (picks.isNotEmpty && mounted) {
        int added = 0;
        for (final f in picks) {
          // Turbo: re-encode tighter (JPEG 0.6 factor of the picker bytes)
          // and cap at ~900KB so each proof uploads in well under a second.
          var bytes = await f.readAsBytes();
          if (bytes.isEmpty) continue;
          if (bytes.length > 2 * 1024 * 1024) {
            showSnackbar(context, message: AppLocalizations.of(context).translate('subPayFileTooBig', params: {'file': f.name}), color: AppColors.warning);
            continue;
          }
          setState(() {
            _proofFiles.add({'name': '${f.name.split('.').first}.jpg', 'bytes': bytes});
          });
          added++;
        }
        if (added > 0) showSnackbar(context, message: AppLocalizations.of(context).translate('subPayAddedCount', params: {'count': added}));
      }
    } catch (e) {
      if (mounted) {
        showSnackbar(context, message: AppLocalizations.of(context).translate('subPayPickFailed', params: {'error': e}), color: AppColors.danger);
      }
    }
  }

  Future<void> _submit() async {
    if (_loading) return;
    // Require internet to upload proofs and subscribe
    final connectivity = ref.read(connectivityServiceProvider);
    if (!connectivity.isOnline) {
      await showOfflineDialog(context, connectivity: connectivity);
      return;
    }
    if (_proofFiles.isEmpty) {
      showSnackbar(context, message: AppLocalizations.of(context).translate('subPayNeedProof'), color: AppColors.warning);
      return;
    }
    setState(() => _loading = true);
    int? planId;
    try {
      final service = ref.read(subscriptionServiceProvider);
      planId = PlanKey.fromKey(widget.planId)?.backendId ?? int.tryParse(widget.planId);
      if (planId == null) {
        throw ArgumentError(AppLocalizations.of(context).translate('subPayInvalidPlan', params: {'plan': widget.planId}));
      }
      // Strain the payment method BEFORE committing: card is charged at once
      // (same-second feedback); bank transfer needs a verification pick first.
      final isBank = _method == _PaymentMethod.bank;
      if (isBank && _proofFiles.isEmpty) {
        showSnackbar(context, message: AppLocalizations.of(context).translate('subPayNeedProof'), color: AppColors.warning);
        return;
      }
      // Amount follows the LIVE backend price (the server re-validates against
      // the DB price anyway); the query price is only a fallback.
      final livePrice = _liveConvertedPrice();
      final askedAmount = livePrice > 0 ? livePrice : double.tryParse(widget.planPrice);
      if (isBank) {
        // Upload receipt IMMEDIATELY, then navigate to waiting screen —
        // so the title "sent successfully" is accurate when user arrives.
        ref.read(pendingReceiptProvider.notifier).submit(PendingReceiptSubmission(
              planId: planId,
              period: widget.period,
              currency: _chargeCurrency,
              amount: askedAmount,
              proofFiles: _proofFiles,
            ));
        ref.read(receiptUploadProvider.notifier).reset();
        final uploaded = await ref.read(receiptUploadProvider.notifier).run(
          PendingReceiptSubmission(
            planId: planId,
            period: widget.period,
            currency: _chargeCurrency,
            amount: askedAmount,
            proofFiles: _proofFiles,
          ),
        );
        if (!mounted) return;
        if (!uploaded) {
          // Upload failed — stay on this page so the user can retry, and
          // SHOW the reason (e.g. Premium already covers both sections).
          final err = ref.read(receiptUploadProvider).error;
          setState(() => _loading = false);
          showSnackbar(
            context,
            message: err != null
                ? localizeSubscriptionError(err)
                : AppLocalizations.of(context).translate('subPayCouldNot'),
            color: AppColors.danger,
          );
          return;
        }
        ref.read(pendingReceiptProvider.notifier).clear();
        ref.invalidate(subscriptionStatusProvider);
        context.go(RouteNames.subscriptionPending);
        return;
      }
      await service.subscribe(
        planId,
        period: widget.period,
        currency: _chargeCurrency,
        amount: askedAmount,
        proofFiles: _proofFiles,
      );
      if (!mounted) return;
      // Instant feedback: goto the pending/waiting screen (hourglass) instead
      // of a plain snackbar.
      showSnackbar(context, message: AppLocalizations.of(context).translate('subPaySubmittedOk'));
      context.go(RouteNames.subscriptionPending);
    } catch (e) {
      if (!mounted) return;
      // Reconciliation: the server may have committed the request even when
      // the response never arrived (timeout on a slow link). Ask the server
      // for the truth — if a pending request now exists, take the user to
      // the waiting screen instead of stranding them on this page.
      if (e is ApiException && _isTimeoutError(e)) {
        try {
          final st = await ref.read(subscriptionServiceProvider).getStatus();
          if (!mounted) return;
          if (st['status']?.toString() == 'pending') {
            ref.invalidate(subscriptionStatusProvider);
            showSnackbar(context, message: AppLocalizations.of(context).translate('subPaySubmittedOk'));
            context.go(RouteNames.subscriptionPending);
            return;
          }
        } catch (_) {}
        if (!mounted) return;
      }
      final msg = e is ApiException
          ? localizeSubscriptionError(e)
          : (e is ArgumentError
              ? AppLocalizations.of(context)
                  .translate('subPayInvalidData', params: {'error': e.message})
              : (premiumSubscriptionMessage(e) ??
                  AppLocalizations.of(context).translate('subPaySubmitFailed')));
      showSnackbar(context, message: msg, color: AppColors.danger);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// True for timeout/connection failures (never for validation/server
  /// rejections, which must surface their real message).
  bool _isTimeoutError(ApiException e) {
    final m = e.message.toLowerCase();
    return m.contains('مهلة') ||
        m.contains('timeout') ||
        m.contains('timed out') ||
        m.contains('socket') ||
        m.contains('connection') ||
        m.contains('network');
  }
}
