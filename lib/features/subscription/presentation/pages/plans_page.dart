import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import '../../../../shared/widgets/connectivity_widgets.dart';
import '../../../../shared/widgets/currency_selector.dart';
import '../../di/subscription_providers.dart';
import '../../data/models/subscription_models.dart';
import '../../domain/section_access.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../shared/services/notification_service.dart';
import '../../../../shared/providers/platform_controls_provider.dart';
import '../../../../core/network/api_exceptions.dart';
import '../providers/subscription_providers.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../../../../core/services/connectivity_service.dart';
import '../../../../core/utils/subscription_identity.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

IconData _iconFromName(String? name) => switch (name) {
  'business' => Icons.business,
  'crown' => Icons.workspace_premium,
  'star' => Icons.star,
  'person' => Icons.person,
  _ => Icons.workspace_premium,
};

class PlansPage extends ConsumerStatefulWidget {
  PlansPage({super.key, this.packageFilter});
  final String? packageFilter;

  String? get effectivePackageFilter =>
      const {'personal', 'business', 'premium'}.contains(packageFilter) ? packageFilter : null;

  bool includesPackage(String key) => effectivePackageFilter == null || effectivePackageFilter == key;
  @override
  ConsumerState<PlansPage> createState() => _PlansPageState();
}

class _PlansPageState extends ConsumerState<PlansPage> {
  /// Plans always open on USD (prices are USD-based); the selector below
  /// lists every world currency with search.
  String _currency = 'USD';
  Timer? _refreshTimer;
  Timer? _controlsTimer;
  /// Periodic 1s heartbeat to drive the (fake) urgency countdowns. Each tick
  /// rebuilds the page so every plan card shows a LIVE descending timer while
  /// the user is looking at the plans screen. Zero-cost when unused.
  Timer? _tickTimer;
  DateTime _countdownStart = DateTime.now();

  @override
  void initState() {
    super.initState();
    // Always fetch fresh plans on entering the page (never show a stale
    // cached price), then refresh every 60s to pick up admin changes live.
    Future.microtask(() {
      if (mounted) ref.invalidate(subscriptionPlansProvider);
    });
    _refreshTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) ref.invalidate(subscriptionPlansProvider);
    });
    // Pick up admin marketing edits (urgency seconds, fake-subscribers
    // base/step/interval, discount windows) LIVE every 12s so the page
    // reflects the admin web changes instantly — no restart needed.
    Future.microtask(() {
      if (mounted) {
        try {
          ref.read(platformControlsProvider.notifier).refresh();
        } catch (_) {}
        try {
          ref.read(currencyEngineProvider).load();
        } catch (_) {}
        try {
          ref.read(currencyEngineProvider).refreshIfStale();
        } catch (_) {}
      }
    });
    _controlsTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      if (!mounted) return;
      try {
        ref.read(platformControlsProvider.notifier).refresh();
      } catch (_) {}
      try {
        ref.read(currencyEngineProvider).refreshIfStale();
      } catch (_) {}
    });
    _countdownStart = DateTime.now();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  /// Seconds elapsed since this screen opened (drives the descending timers).
  int get _elapsedSeconds =>
      DateTime.now().difference(_countdownStart).inSeconds.clamp(0, 60 * 60 * 24);

  Future<void> _refreshPlans() async {
    ref.invalidate(subscriptionPlansProvider);
    try {
      await ref.read(subscriptionPlansProvider.future);
    } catch (_) {}
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _controlsTimer?.cancel();
    _tickTimer?.cancel();
    super.dispose();
  }

  /// Convert a plan price from its original currency (always USD for admin
  /// plans) to the user-selected currency using the live exchange rate from
  /// the app's CurrencyEngine (exchangerate-api.com + 2dec.net via backend).
  /// Falls back to the original USD price if no rate is available so no
  /// currency ever shows an error or zero price.
  double _convert(double price, [String? fromCurrency]) {
    final from = (fromCurrency == null || fromCurrency.isEmpty) ? 'USD' : fromCurrency.toUpperCase();
    final to = _currency.toUpperCase();
    if (to == from) return price;
    try {
      final engine = ref.read(currencyEngineProvider);
      final converted = engine.convert(price, from, to);
      // engine.convert returns 0 when no rate is available — fall back to
      // the original price so the user never sees 0 or an error.
      if (converted == 0) return price;
      return converted;
    } catch (_) {
      return price;
    }
  }

  String _formatPrice(double price) {
    // Keep one decimal for admin prices like 10.9 / 18.3, otherwise no
    // trailing zeros. Example: 10.90 -> "10.9", 5000 -> "5,000".
    if (price == price.roundToDouble()) return fmtNum(price.round());
    return fmtNum(double.parse(price.toStringAsFixed(2)));
  }

  String _sym() => currencySymbol(_currency, locale: AppLocalizations.of(context).locale.languageCode);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final statusAsync = ref.watch(subscriptionStatusProvider);
    final user = ref.watch(authProvider).user;
    final trialActivated = user?.personalTrialActivated ?? false;
    final effective = user?.effectiveStatus;
    final isTrialing = effective == 'active' && user?.status == 'trial';
    final hideTrial = trialActivated || isTrialing || effective == 'active' || user?.status == 'trial';
    final plansAsync = ref.watch(subscriptionPlansProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          l10n.translate('activateSubscription'),
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 18),
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
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go(RouteNames.personalDashboard);
            }
          },
        ),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          color: AppColors.primary,
          onRefresh: _refreshPlans,
          child: ListView(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
           Text(
            l10n.translate('planChoose'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 16),
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
          SizedBox(height: 16),
          if (widget.effectivePackageFilter != null)
            TextButton(
              onPressed: () => context.go('/subscription'),
              child: Text(l10n.locale.languageCode == 'ar' ? 'عرض جميع الباقات' : 'View all plans'),
            ),
          CurrencySelector(
            label: l10n.translate('planCurrency'),
            value: _currency,
            showCode: true,
            showAll: true,
            onChanged: (c) => setState(() => _currency = c),
          ),
          SizedBox(height: 20),
           if (widget.effectivePackageFilter == null) _buildTrialSection(statusAsync, hideTrial),
          ...plansAsync.when(
            loading: () => [
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator(color: AppColors.primary)),
              ),
            ],
            error: (e, _) {
              developer.log('Failed to load plans', error: e);
              return _buildFallbackPlanCards(context, statusAsync.valueOrNull, effective, l10n);
            },
            data: (plans) {
              if (plans.isEmpty) return _buildFallbackPlanCards(context, statusAsync.valueOrNull, effective, l10n);
              return _buildApiPlanCards(context, plans, statusAsync.valueOrNull, effective, l10n);
            },
          ),
          SizedBox(height: 20),
          _buildSubscriberCounterBar(),
          SizedBox(height: 20),
          Divider(height: 1, color: AppColors.border),
          SizedBox(height: 16),
           Text(
            AppLocalizations.of(context).translate('plansUseAnother'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 15),
              color: AppColors.textSecondary,
            ),
          ),
           SizedBox(height: 8),
          OutlinedButton.icon(
            icon: Icon(Icons.logout, color: AppColors.textSecondary, size: 20),
            label: Text(
              AppLocalizations.of(context).translate('plansLogout'),
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), color: AppColors.textSecondary),
            ),
            onPressed: () async {
              await ref.read(authProvider.notifier).logout();
              if (mounted) context.go(RouteNames.login);
            },
          ),
        ],
          ),
        ),
      ),
    );
  }

  /// Static epoch used to compute the fake paid-subscribers drift so the
  /// counter increases live while the user is watching, without any backend.
  /// PERSISTED across app restarts / logins so the count never resets: the
  /// app stores (value, anchored-time, config-signature) and keeps climbing
  /// from there at the admin's configured step/interval.
  static DateTime? _subCounterEpoch;
  static int? _subCounterBaseValue;
  static DateTime? _subCounterBaseAt;
  static String? _subCounterSig;
  static bool _subCounterLoaded = false;
  static DateTime? _subCounterLastSaved;
  static const _subCounterStoreKey = 'subscriber_counter_baseline';

  static Future<void> _loadSubCounterBaseline(
      int base, int step, int interval) async {
    final sig = '$base|$step|$interval';
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_subCounterStoreKey);
      if (raw != null && raw.isNotEmpty) {
        final saved = jsonDecode(raw) as Map<String, dynamic>;
        final sigOk = saved['sig']?.toString() == sig;
        final val = int.tryParse(saved['value']?.toString() ?? '');
        final at = DateTime.tryParse(saved['at']?.toString() ?? '');
        if (sigOk && val != null && at != null) {
          _subCounterBaseValue = val < base ? base : val;
          _subCounterBaseAt = at;
          _subCounterSig = sig;
          _subCounterLoaded = true;
          return;
        }
      }
    } catch (_) {}
    // No usable baseline (first run / admin changed the config): start at the
    // admin's base value anchored NOW.
    _subCounterBaseValue = base;
    _subCounterBaseAt = DateTime.now();
    _subCounterSig = sig;
    _subCounterLoaded = true;
  }

  static Future<void> _saveSubCounterBaseline(int value, DateTime at) async {
    final sig = _subCounterSig;
    if (sig == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _subCounterStoreKey,
          jsonEncode({'value': value, 'at': at.toIso8601String(), 'sig': sig}),
      );
      _subCounterLastSaved = DateTime.now();
    } catch (_) {}
  }

  /// Elegant paid-subscribers counter: neutral gray crest (readable in BOTH
  /// themes) with a glowing gold medal icon. Shows the COUNT first, then the
  /// "paid plans users" subtitle underneath — localized per language.
  Widget _buildSubscriberCounterBar() {
    final controls = ref.watch(platformControlsProvider).valueOrNull;
    if (controls == null || !(controls.subscriberCounterEnabled ?? false)) {
      return const SizedBox.shrink();
    }
    final base = controls.subscriberCounterBase;
    final step = controls.subscriberCounterStep > 0
        ? controls.subscriberCounterStep
        : 1;
    final interval = controls.subscriberCounterInterval > 0
        ? controls.subscriberCounterInterval
        : 10;
    if (base <= 0) return const SizedBox.shrink();

    if (!_subCounterLoaded) {
      // First frame of the session: show from the last-known baseline, or
      // fall back to a fresh epoch while the stored baseline loads.
      unawaited(_loadSubCounterBaseline(base, step, interval));
      _subCounterEpoch ??= DateTime.now();
    }
    final baseAt = _subCounterBaseAt ?? _subCounterEpoch ?? DateTime.now();
    final baseValue = _subCounterBaseValue ?? base;
    final drifted = DateTime.now().difference(baseAt).inSeconds;
    final safeElapsed = drifted.clamp(0, 10 * 60 * 60); // guard vs clock jumps
    final added = safeElapsed ~/ interval * step;
    final shown = (baseValue + added).clamp(base, 1 << 30);

    // Persist the baseline (~every 45s) so a restart/logout continues the
    // climb exactly where it left off — never back to `base`.
    final rem = safeElapsed % interval;
    if (_subCounterLastSaved == null ||
        DateTime.now().difference(_subCounterLastSaved!).inSeconds >= 45) {
      unawaited(_saveSubCounterBaseline(shown, DateTime.now().subtract(Duration(seconds: rem))));
    }
    _subCounterBaseValue = shown;
    _subCounterBaseAt = DateTime.now().subtract(Duration(seconds: rem));

    final l10n = AppLocalizations.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3A3F45), Color(0xFF23262B)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF6B7280).withAlpha(140), width: 1.2),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(70), blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 34, height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFFFC63D).withAlpha(22),
                  border: Border.all(color: const Color(0xFFFFC63D).withAlpha(150), width: 1.2),
                  boxShadow: [
                    BoxShadow(color: const Color(0xFFFFC63D).withAlpha(90), blurRadius: 10),
                  ],
                ),
                child: const Icon(Icons.workspace_premium, size: 18, color: Color(0xFFFFC63D)),
              ),
              const SizedBox(width: 10),
              Text(
                '$shown',
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            l10n.translate('plansPaidUsersSub'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFFE5E7EB),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrialSection(AsyncValue<Map<String, dynamic>> statusAsync, bool hideTrial) {
    if (hideTrial) return const SizedBox.shrink();
    final status = statusAsync.valueOrNull?['status'];
    if (status == 'active' || status == 'trial') return const SizedBox.shrink();
    // Trial visibility is fully driven by the admin platform controls:
    // hidden when the free trial is disabled or paid is forced.
    final controls = ref.watch(platformControlsProvider).valueOrNull;
    if (controls != null && (!controls.trialEnabled || controls.forcePaidSubscription)) {
      return const SizedBox.shrink();
    }
    return _TrialCard();
  }

  List<Widget> _buildApiPlanCards(
    BuildContext context,
    List<SubscriptionPlan> plans,
    Map<String, dynamic>? status,
    String? effective,
    AppLocalizations l10n,
  ) {
    // Per-section entitlements: each card reflects its own paid plan
    // (personal / business / premium), never a single account-wide flag.

    // Paid plans only — the free/trial plan is never in the main list.
    // Explicit cart order: personal → business → business+personal (premium).
    const order = {'personal': 0, 'business': 1, 'premium': 2};
    final paidPlans = plans
        .where((p) {
          final k = subscriptionIdentityKey(p.packageType);
          return (k == 'personal' || k == 'business' || k == 'premium') && widget.includesPackage(k);
        })
        .toList()
        ..sort((a, b) {
          final ka = subscriptionIdentityKey(a.packageType);
          final kb = subscriptionIdentityKey(b.packageType);
          final ia = order[ka] ?? 9;
          final ib = order[kb] ?? 9;
          return ia.compareTo(ib);
        });

    final controls = ref.watch(platformControlsProvider).valueOrNull;

    return paidPlans.map((plan) {
      final key = subscriptionIdentityKey(plan.packageType);
      final name = plan.name.isNotEmpty ? plan.name : _planName(key, l10n);
      final priceYearly = plan.priceYearly;
      final priceCurrency = plan.currency.isNotEmpty ? plan.currency : 'USD';
      final description = (plan.description == null || plan.description!.isEmpty)
          ? l10n.translate('planDesc_$key')
          : plan.description!;
      final features = plan.features.isNotEmpty
          ? plan.features
          : l10n.translateList('planFeatures_$key');
      final iconName = plan.icon;

      // ── Marketing discount (admin, validated window) ──
      double? discounted;
      int? percent;
      final isPremium = key == 'premium';
      final discountForPlan = controls?.discountFor(key);
      if (discountForPlan != null) {
        percent = discountForPlan['percent'] as int?;
        if (percent != null && percent > 0 && percent < 100) {
          discounted = priceYearly * (1 - percent / 100.0);
        } else {
          percent = null;
        }
      }

      // ── Urgency countdown (admin, fake, descending) ──
      Duration? countdown;
      if (controls?.urgencyEnabled ?? false) {
        final secs = controls!.urgencySecondsFor(key);
        if (secs > 0) {
          final left = secs - _elapsedSeconds;
          if (left > 0) countdown = Duration(seconds: left);
        }
      }

      final converted = _convert(priceYearly, priceCurrency);
      final convertedDiscounted = discounted != null
          ? _convert(discounted!, priceCurrency)
          : null;
      return _PlanCard(
        keyName: key,
        name: name,
        desc: description,
        priceYearly: priceYearly,
        features: features,
        accentColor: subscriptionIdentityColor(key),
        icon: _iconFromName(iconName),
        isCurrentPlan: hasPaidPlan(status, key),
        isSubscribed: key != 'premium' && hasPaidPlan(status, 'premium'),
        currencySymbol: _sym(),
        convertedPrice: converted,
        displayPrice: _formatPrice(converted),
        discountedPrice: convertedDiscounted != null ? _formatPrice(convertedDiscounted!) : null,
        discountPercent: percent,
        isPremium: isPremium,
        countdown: countdown,
        onSubscribe: () async {
          final connectivity = ref.read(connectivityServiceProvider);
          if (!connectivity.isOnline) {
            await showOfflineDialog(context, connectivity: connectivity);
            return;
          }
          final priceToPay = discounted != null
              ? _convert(discounted!, priceCurrency)
              : _convert(priceYearly, priceCurrency);
          final params = {
            'plan_id': key,
            'plan_name': name,
            'plan_price': fmtNum(priceToPay),
            'plan_currency': _currency,
            'period': 'yearly',
            if (discounted != null) 'original_price': fmtNum(converted),
            if (discounted != null) 'discount_percent': '$percent',
          };
          final qs = params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
          context.push('/subscription/pay?$qs');
        },
      );
    }).toList();
  }

  List<Widget> _buildFallbackPlanCards(
    BuildContext context,
    Map<String, dynamic>? status,
    String? effective,
    AppLocalizations l10n,
  ) {
    // Fallback mirrors the admin's current USD pricing so it never masks a
    // real admin change with stale values. Paid plans only — no free card.
    final plans = [
      _PlanData('personal', _planName('personal', l10n), 10.9, Icons.person, AppColors.info),
      _PlanData('business', _planName('business', l10n), 10.9, Icons.business, AppColors.danger),
      _PlanData('premium', _planName('premium', l10n), 18.3, Icons.workspace_premium, AppColors.gold),
    ];
    return plans.where((p) => widget.includesPackage(p.key)).map((p) => _PlanCard(
      keyName: p.key,
      name: p.name,
      desc: l10n.translate('planDesc_${p.key}'),
      priceYearly: p.price,
      features: l10n.translateList('planFeatures_${p.key}'),
      accentColor: p.accent,
      icon: p.icon,
      isCurrentPlan: hasPaidPlan(status, p.key),
      isSubscribed: p.key != 'premium' && hasPaidPlan(status, 'premium'),
      currencySymbol: _sym(),
      convertedPrice: _convert(p.price, 'USD'),
      displayPrice: _formatPrice(_convert(p.price, 'USD')),
      onSubscribe: () async {
        final connectivity = ref.read(connectivityServiceProvider);
        if (!connectivity.isOnline) {
          await showOfflineDialog(context, connectivity: connectivity);
          return;
        }
        final priceToPay = _convert(p.price, 'USD');
        final params = {
          'plan_id': p.key,
          'plan_name': p.name,
          'plan_price': fmtNum(priceToPay),
          'plan_currency': _currency,
          'period': 'yearly',
        };
        final qs = params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
        context.push('/subscription/pay?$qs');
      },
    )).toList();
  }
}

String _planName(String key, AppLocalizations l10n) => switch (key) {
  'free' => l10n.translate('planFree'),
  'business' => l10n.translate('planBusiness'),
  'premium' => l10n.translate('planPremium'),
  _ => l10n.translate('planPersonal'),
};

class _PlanData {
  final String key;
  final String name;
  final double price;
  final IconData icon;
  final Color accent;
  _PlanData(this.key, this.name, this.price, this.icon, this.accent);
}

class _TrialCard extends ConsumerStatefulWidget {
  @override
  ConsumerState<_TrialCard> createState() => _TrialCardState();
}

class _TrialCardState extends ConsumerState<_TrialCard> {
  bool _loading = false;

  /// Confirmation popup BEFORE activation: shows the admin-configured
  /// duration only — never asks for a receipt or any upload. The confirm
  /// button text matches the required "تاكيد تفعيل الاشتراك" label.
  Future<void> _confirmTrial() async {
    if (_loading) return;
    final l10n = AppLocalizations.of(context);
    final controls = ref.read(platformControlsProvider).valueOrNull;
    final offerLabel = controls != null
        ? controls.durationLabel(l10n)
        : l10n.translate('timeout24h');
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: AppColors.success.withAlpha(30),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.card_giftcard, color: AppColors.success, size: 30),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.translate('plansTrialConfirmTitle'),
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w800, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 10),
            Text(
              l10n.translate('plansTrialConfirmBody', params: {'duration': offerLabel}),
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w700, color: AppColors.success),
            ),
          ],
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  style: TextButton.styleFrom(
                    backgroundColor: AppColors.surfaceVariant,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: Text(l10n.translate('cancel'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: TextButton.styleFrom(
                    backgroundColor: AppColors.success,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: Text(l10n.translate('confirm'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: Colors.white)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed == true) await _activateTrial();
  }

  Future<void> _activateTrial() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      await _activateTrialCore();
    } catch (e) {
      if (!mounted) return;
      final msg = e is ApiException ? e.message : AppLocalizations.of(context).translate('plansTrialFailed');
      showSnackbar(context, message: msg, color: AppColors.danger);
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _activateTrialCore() async {
    final service = ref.read(subscriptionServiceProvider);
    final resp = await service.activateTrial(mode: 'personal');

    final now = DateTime.now();
    // Prefer precise backend-computed duration (handles 50 hours / days/weeks/months exactly)
    Duration duration;
    final hrs = resp['hours_remaining'];
    if (hrs is int && hrs > 0) {
      duration = Duration(hours: hrs);
    } else if (hrs is num && hrs > 0) {
      duration = Duration(hours: hrs.toInt());
    } else {
      final v = resp['duration_value'];
      final u = resp['duration_unit']?.toString();
      if (v != null && u != null) {
        final val = int.tryParse(v.toString()) ?? 24;
        switch (u) {
          case 'days': duration = Duration(days: val); break;
          case 'weeks': duration = Duration(days: val * 7); break;
          case 'months': duration = Duration(days: val * 30); break;
          default: duration = Duration(hours: val); break;
        }
      } else {
        final controls = ref.read(platformControlsProvider).valueOrNull;
        duration = controls?.trialDuration ?? const Duration(hours: 24);
      }
    }
    final end = now.add(duration);
    ref.read(authProvider.notifier).applyUserUpdate((u) => u.copyWith(
      status: 'trial',
      trialStartDate: now.toIso8601String(),
      trialEndDate: end.toIso8601String(),
      personalTrialActivated: true,
    ));

    // Force-fresh controls & status so the 50h/days/weeks/months choice from admin
    // is reflected instantly without waiting for the 12s poll
    try { ref.invalidate(platformControlsProvider); } catch (_) {}
    try { ref.invalidate(subscriptionStatusProvider); } catch (_) {}
    unawaited(ref.read(authProvider.notifier).refreshProfile());

    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) ref.read(notificationServiceProvider).showSaraWelcome(mode: 'personal');
    });
    // Free-plan activation: greet on the device tray IMMEDIATELY (the Sara
    // welcome above stays untouched and still arrives 5s later).
    try {
      final uid = ref.read(authProvider).user?.id ?? '';
      final scope =
          NotificationService.welcomeScopeKey(userId: uid, isFree: true);
      unawaited(ref
          .read(notificationServiceProvider)
          .showSubscriptionWelcomeOnce(scopeKey: scope));
    } catch (_) {}
    if (!mounted) return;
    showSnackbar(context, message: AppLocalizations.of(context).translate('plansTrialOk'), color: AppColors.success);
    context.go('/account-entry');
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: AppRadius.cardBorder,
      child: Container(
        margin: EdgeInsets.only(bottom: 12),
        padding: EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(
            left: BorderSide(color: AppColors.success, width: 3),
            top: BorderSide(color: AppColors.border),
            right: BorderSide(color: AppColors.border),
            bottom: BorderSide(color: AppColors.border),
          ),
        ),
        child: _buildTrialContent(),
      ),
    );
  }

  Widget _buildTrialContent() {
    final l10n = AppLocalizations.of(context);
    final controls = ref.read(platformControlsProvider).valueOrNull;
    final offerLabel = controls != null
        ? controls.durationLabel(l10n)
        : l10n.translate('timeout24h');
    return Column(
      children: [
        Icon(Icons.card_giftcard, size: 48, color: AppColors.success),
        SizedBox(height: 12),
        Text(
          l10n.translate('plansTrialTitle'),
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 20),
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
        SizedBox(height: 6),
        Text(
          offerLabel,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 15),
            fontWeight: FontWeight.w600,
            color: AppColors.success,
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.success,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.buttonRadius),
              ),
            ),
            onPressed: _loading ? null : _confirmTrial,
            child: _loading
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      AppLocalizations.of(context).translate('plansTrialSubscribe'),
                      style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.bold),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

}

class _PremiumRibbon extends StatelessWidget {
  final Color accent;
  const _PremiumRibbon({required this.accent});

  @override
  Widget build(BuildContext context) {
    // Royal gold ribbon placed INSIDE the plan card so it reads as part of
    // the card, with a crisp dark-gold text on a rich gradient crest — not a
    // heavy yellow block.
    final darkText = AppColors.isLightMode;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF5A3D00),
                const Color(0xFFD4A017),
                const Color(0xFFFFC63D),
                const Color(0xFF5A3D00),
              ],
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF3E2A00), width: 1.2),
            boxShadow: [
              BoxShadow(color: const Color(0xFFFFC63D).withAlpha(80), blurRadius: 10, offset: const Offset(0, 2)),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.workspace_premium,
                size: 15,
                color: darkText ? const Color(0xFF5A3D00) : const Color(0xFFFFE9A8),
              ),
              const SizedBox(width: 6),
              Text(
                AppLocalizations.of(context).translate('plansBestSeller'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 13),
                  fontWeight: FontWeight.w900,
                  color: darkText ? const Color(0xFF3E2A00) : const Color(0xFFFFEFC0),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PlanCard extends StatelessWidget {
  final String keyName;
  final String name;
  final String desc;
  final double priceYearly;
  final List<String> features;
  final Color accentColor;
  final IconData icon;
  final bool isCurrentPlan;
  final bool isSubscribed;
  final String currencySymbol;
  final double convertedPrice;
  final String displayPrice;
  final String? discountedPrice;
  final int? discountPercent;
  final bool isPremium;
  final Duration? countdown;
  final VoidCallback onSubscribe;

  _PlanCard({
    required this.keyName,
    required this.name,
    required this.desc,
    required this.priceYearly,
    required this.features,
    required this.accentColor,
    required this.icon,
    required this.isCurrentPlan,
    required this.isSubscribed,
    required this.currencySymbol,
    required this.convertedPrice,
    String? displayPrice,
    this.discountedPrice,
    this.discountPercent,
    this.isPremium = false,
    this.countdown,
    required this.onSubscribe,
  }) : displayPrice = displayPrice ?? fmtNum(convertedPrice);

  @override
  Widget build(BuildContext context) {
    final countLabel = countdownText();
    final hasCornerChips = (discountPercent != null) || (countdown != null);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: ClipRRect(
        borderRadius: AppRadius.cardBorder,
        child: Stack(
          children: [
            // ── Card body: name & ribbon sit BELOW the corner chips. ──
            Container(
              padding: EdgeInsets.fromLTRB(
                24,
                hasCornerChips ? 58 : (isPremium ? 16 : 24),
                24,
                24,
              ),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border(
                  left: BorderSide(color: accentColor, width: 3),
                  top: BorderSide(color: AppColors.border),
                  right: BorderSide(color: AppColors.border),
                  bottom: BorderSide(color: AppColors.border),
                ),
              ),
              child: Column(
                children: [
                  if (isPremium) ...[
                    _PremiumRibbon(accent: accentColor),
                    const SizedBox(height: 8),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, size: 30, color: accentColor),
                      const SizedBox(width: 10),
                      Text(
                        name,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 20),
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    desc,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 14),
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),
          // ── Single compact price display (never repeated, never overflows).
          // With a discount: strikethrough base ONCE + current price.
          // Without: the normal big price. Everything scales down to fit.
          if (discountedPrice != null && discountedPrice != displayPrice)
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    displayPrice,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 16),
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary,
                      decoration: TextDecoration.lineThrough,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    discountedPrice!,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 26),
                      fontWeight: FontWeight.w900,
                      color: accentColor,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    currencySymbol,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 14),
                      fontWeight: FontWeight.w700,
                      color: accentColor,
                    ),
                  ),
                ],
              ),
            )
          else
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    displayPrice,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 30),
                      fontWeight: FontWeight.w900,
                      color: accentColor,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    currencySymbol,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 16),
                      fontWeight: FontWeight.w700,
                      color: accentColor,
                    ),
                  ),
                ],
              ),
            ),
           Text(
            AppLocalizations.of(context).translate('plansYearly'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 14),
              color: AppColors.textSecondary,
            ),
          ),
          SizedBox(height: 20),
          Divider(color: AppColors.border, height: 1),
          SizedBox(height: 16),
          ...features.map(
            (f) => Padding(
              padding: EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Icon(Icons.check_circle, size: 20, color: accentColor),
                   SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      f,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 15),
                        fontWeight: FontWeight.w500,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
           SizedBox(height: 20),
          if (isCurrentPlan)
            Container(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(AppRadius.badgeRadius),
              ),
              child: Text(
                AppLocalizations.of(context).translate('plansCurrentPlan'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 16),
                  fontWeight: FontWeight.w800,
                  color: AppColors.success,
                ),
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.buttonRadius),
                  ),
                ),
                onPressed: onSubscribe,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    isSubscribed ? AppLocalizations.of(context).translate('plansUpgrade') : AppLocalizations.of(context).translate('plansSubscribeYearly'),
                    style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
                ],
              ),
            ),

            // ── Corner chips pinned to the card edges (above the name).
            // Countdown at the far LEFT, discount % badge at the far RIGHT.
            if (countdown != null)
              Positioned(
                top: 14,
                left: 8,
                child: _cornerChip(
                  context: context,
                  accent: accentColor,
                  label: countLabel,
                  icon: Icons.hourglass_bottom_rounded,
                ),
              ),
            if (discountPercent != null)
              Positioned(
                top: 14,
                right: 16,
                child: _cornerChip(
                  context: context,
                  accent: accentColor,
                  label: '-$discountPercent%',
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Small rounded chip used at the card's top corners (discount % / countdown).
  Widget _cornerChip({
    required BuildContext context,
    required Color accent,
    required String label,
    IconData? icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: accent.withAlpha(18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withAlpha(170), width: 1.2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: accent),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 12),
              fontWeight: FontWeight.w900,
              color: accent,
            ),
          ),
        ],
      ),
    );
  }

  /// Live countdown label (ترقيم عكسي): "06:12" — driven by the admin's
  /// fake urgency timer. Falls back to "--:--" once it hits zero.
  String countdownText() {
    final cd = countdown;
    if (cd == null) return '';
    final secs = cd.inSeconds;
    final m = (secs ~/ 60).clamp(0, 99);
    final s = (secs % 60).clamp(0, 59);
    return '${m.toStringAsFixed(0).padLeft(2, '0')}:${s.toStringAsFixed(0).padLeft(2, '0')}';
  }
}

// ════════════════════════════════════════════════════════════
//  COUNTRY DATA
// ════════════════════════════════════════════════════════════
class _Country {
  final String name;
  final String iso;
  final String cc;
  const _Country(this.name, this.iso, this.cc);
}

const _countries = [
  _Country('اليمن', 'YE', '+967'),
  _Country('السعودية', 'SA', '+966'),
  _Country('الإمارات', 'AE', '+971'),
  _Country('الكويت', 'KW', '+965'),
  _Country('قطر', 'QA', '+974'),
  _Country('البحرين', 'BH', '+973'),
  _Country('عمان', 'OM', '+968'),
  _Country('الأردن', 'JO', '+962'),
  _Country('لبنان', 'LB', '+961'),
  _Country('العراق', 'IQ', '+964'),
  _Country('سوريا', 'SY', '+963'),
  _Country('فلسطين', 'PS', '+970'),
  _Country('مصر', 'EG', '+20'),
  _Country('تركيا', 'TR', '+90'),
  _Country('المغرب', 'MA', '+212'),
  _Country('تونس', 'TN', '+216'),
  _Country('الجزائر', 'DZ', '+213'),
  _Country('ليبيا', 'LY', '+218'),
  _Country('السودان', 'SD', '+249'),
  _Country('جيبوتي', 'DJ', '+253'),
  _Country('الصومال', 'SO', '+252'),
  _Country('جزر القمر', 'KM', '+269'),
  _Country('موريتانيا', 'MR', '+222'),
  _Country('نيجيريا', 'NG', '+234'),
  _Country('غانا', 'GH', '+233'),
  _Country('كينيا', 'KE', '+254'),
  _Country('إثيوبيا', 'ET', '+251'),
  _Country('تنزانيا', 'TZ', '+255'),
  _Country('جنوب أفريقيا', 'ZA', '+27'),
  _Country('الهند', 'IN', '+91'),
  _Country('باكستان', 'PK', '+92'),
  _Country('بنغلاديش', 'BD', '+880'),
  _Country('سريلانكا', 'LK', '+94'),
  _Country('إيران', 'IR', '+98'),
  _Country('تايلاند', 'TH', '+66'),
  _Country('إندونيسيا', 'ID', '+62'),
  _Country('ماليزيا', 'MY', '+60'),
  _Country('الفلبين', 'PH', '+63'),
  _Country('فيتنام', 'VN', '+84'),
  _Country('كوريا الجنوبية', 'KR', '+82'),
  _Country('اليابان', 'JP', '+81'),
  _Country('الصين', 'CN', '+86'),
  _Country('سنغافورة', 'SG', '+65'),
  _Country('أستراليا', 'AU', '+61'),
  _Country('نيوزيلندا', 'NZ', '+64'),
  _Country('الولايات المتحدة', 'US', '+1'),
  _Country('كندا', 'CA', '+1'),
  _Country('بريطانيا', 'GB', '+44'),
  _Country('فرنسا', 'FR', '+33'),
  _Country('ألمانيا', 'DE', '+49'),
  _Country('إيطاليا', 'IT', '+39'),
  _Country('إسبانيا', 'ES', '+34'),
  _Country('هولندا', 'NL', '+31'),
  _Country('بلجيكا', 'BE', '+32'),
  _Country('سويسرا', 'CH', '+41'),
  _Country('النمسا', 'AT', '+43'),
  _Country('السويد', 'SE', '+46'),
  _Country('النرويج', 'NO', '+47'),
  _Country('الدنمارك', 'DK', '+45'),
  _Country('فنلندا', 'FI', '+358'),
  _Country('بولندا', 'PL', '+48'),
  _Country('رومانيا', 'RO', '+40'),
  _Country('اليونان', 'GR', '+30'),
  _Country('البرتغال', 'PT', '+351'),
  _Country('روسيا', 'RU', '+7'),
  _Country('البرازيل', 'BR', '+55'),
  _Country('المكسيك', 'MX', '+52'),
  _Country('الأرجنتين', 'AR', '+54'),
  _Country('كولومبيا', 'CO', '+57'),
];

String _flagOf(String iso) {
  final base = 0x1F1E6;
  return String.fromCharCode(base + iso.codeUnitAt(0) - 65) +
      String.fromCharCode(base + iso.codeUnitAt(1) - 65);
}

// ════════════════════════════════════════════════════════════
//  COUNTRY PICKER SHEET
// ════════════════════════════════════════════════════════════
class _CountryPickerSheet extends StatefulWidget {
  final String initial;
  const _CountryPickerSheet({required this.initial});

  @override
  State<_CountryPickerSheet> createState() => _CountryPickerSheetState();
}

class _CountryPickerSheetState extends State<_CountryPickerSheet> {
  final _searchCtrl = TextEditingController();
  late List<_Country> _filtered;

  @override
  void initState() {
    super.initState();
    _filtered = _countries;
    _searchCtrl.addListener(_applyFilter);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _applyFilter() {
    final q = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? _countries
          : _countries
              .where((c) =>
                  c.name.contains(q) ||
                  c.cc.contains(q) ||
                  c.iso.toLowerCase().contains(q) ||
                  c.name.toLowerCase().contains(q))
              .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: AppColors.primary.withAlpha(40), width: 0.5)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Row(
              children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(20),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.public_rounded, size: 20, color: AppColors.primary),
                ),
                const SizedBox(width: 12),
                Text(AppLocalizations.of(context).translate('subPhonePickCountry'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 17),
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    )),
                const Spacer(),
                Text(AppLocalizations.of(context).translate('subPhoneCountryCount', params: {'count': _filtered.length}),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 12),
                      color: AppColors.textSecondary,
                    )),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: FyonaTextField(
              controller: _searchCtrl,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 14),
                color: AppColors.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: AppLocalizations.of(context).translate('subPhoneSearchCountry'),
                hintStyle: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 13),
                  color: AppColors.textPlaceholder,
                ),
                prefixIcon: Icon(Icons.search_rounded, size: 20, color: AppColors.textSecondary),
                filled: true,
                fillColor: AppColors.surfaceVariant,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                  borderSide: BorderSide.none,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
           Divider(height: 1, color: AppColors.border),
          Expanded(
            child: _filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.search_off_rounded, size: 40, color: AppColors.textDisabled),
                        const SizedBox(height: 8),
                        Text(AppLocalizations.of(context).translate('subPhoneNoResults'),
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 14),
                              color: AppColors.textSecondary,
                            )),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: _filtered.length,
                    itemBuilder: (_, i) {
                      final c = _filtered[i];
                      final selected = c.iso == widget.initial;
                      return Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            HapticFeedback.lightImpact();
                            Navigator.pop(context, c);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            color: selected ? AppColors.primary.withAlpha(15) : null,
                            child: Row(
                              children: [
                                Text(_flagOf(c.iso), style: const TextStyle(fontSize: 24)),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Text(c.name,
                                      style: TextStyle(
                                        fontFamily: 'Cairo',
                                        fontSize: R.fontSize(context, 14),
                                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                                        color: selected ? AppColors.primary : AppColors.textPrimary,
                                      )),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: selected ? AppColors.primary.withAlpha(20) : AppColors.surfaceVariant,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(c.cc,
                                      style: TextStyle(
                                        fontFamily: 'Cairo',
                                        fontSize: R.fontSize(context, 13),
                                        fontWeight: FontWeight.w600,
                                        color: selected ? AppColors.primary : AppColors.textSecondary,
                                      )),
                                ),
                                if (selected) ...[
                                  const SizedBox(width: 10),
                                  Icon(Icons.check_circle_rounded, size: 18, color: AppColors.primary),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SizedBox(height: bottomPad),
        ],
      ),
    );
  }
}
