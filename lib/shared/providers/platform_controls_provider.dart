import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/network/dio_provider.dart';
import '../../core/localization/app_localizations.dart';
import '../../core/utils/subscription_identity.dart';

/// Normalized trial-duration unit keys (as stored by the admin web).
enum TrialUnit {
  hours,
  days,
  weeks,
  months,
}

String normalizeTrialUnit(Object? raw) {
  switch (raw?.toString().toLowerCase()) {
    case 'days':
    case 'day':
    case 'd':
      return 'days';
    case 'weeks':
    case 'week':
    case 'w':
      return 'weeks';
    case 'months':
    case 'month':
    case 'mo':
      return 'months';
    default:
      return 'hours';
  }
}

/// Localized label for a trial duration: "7 أيام", "3 ساعات", "أسبوع واحد".
String trialDurationLabel(AppLocalizations l10n, {String? unit, Object? value}) {
  final u = normalizeTrialUnit(unit);
  final v = int.tryParse(value?.toString() ?? '') ?? 1;
  final count = v < 1 ? 1 : v;

  String word() {
    switch (u) {
      case 'days':
        if (count == 1) return l10n.translate('trialUnitDayOne');
        if (count == 2) return l10n.translate('trialUnitDayTwo');
        if (count <= 10) return l10n.translate('trialUnitDayFew');
        return l10n.translate('trialUnitDayMany');
      case 'weeks':
        if (count == 1) return l10n.translate('trialUnitWeekOne');
        if (count == 2) return l10n.translate('trialUnitWeekTwo');
        if (count <= 10) return l10n.translate('trialUnitWeekFew');
        return l10n.translate('trialUnitWeekMany');
      case 'months':
        if (count == 1) return l10n.translate('trialUnitMonthOne');
        if (count == 2) return l10n.translate('trialUnitMonthTwo');
        if (count <= 10) return l10n.translate('trialUnitMonthFew');
        return l10n.translate('trialUnitMonthMany');
      default:
        if (count == 1) return l10n.translate('trialUnitHourOne');
        if (count == 2) return l10n.translate('trialUnitHourTwo');
        if (count <= 10) return l10n.translate('trialUnitHourFew');
        return l10n.translate('trialUnitHourMany');
    }
  }

  // `one` and `two` forms are standalone words ("ساعة واحدة", "ساعتان"),
  // so they are never wrapped with a leading count.
  if (count == 1 || count == 2) return word();
  return l10n.translate('trialForDuration', params: {'count': '$count', 'unit': word()});
}

/// Snapshot of the platform controls pushed by the external Admin Web App.
///
/// Fetched from the public `GET /controls` endpoint so the app can enforce:
///  - maintenance (personal / business / all)
///  - disabled buttons per section
///  - trial enablement / duration (hours | days | weeks | months)
///  - force-paid subscription (no trial, must pay)
///  - marketing extras: per-plan discounts, urgency countdown, fake paid
///    subscribers counter (added the moment the admin toggles them).
class PlatformControls {
  final Map<String, dynamic> maintenance;
  final Map<String, dynamic> disabledButtons;
  final Map<String, dynamic> trial;
  final bool forcePaidSubscription;
  final Map<String, dynamic> discounts;
  final Map<String, dynamic> urgencyCountdown;
  final Map<String, dynamic> subscriberCounter;

  const PlatformControls({
    this.maintenance = const {},
    this.disabledButtons = const {},
    this.trial = const {},
    this.forcePaidSubscription = false,
    this.discounts = const {},
    this.urgencyCountdown = const {},
    this.subscriberCounter = const {},
  });

  factory PlatformControls.fromJson(Map<String, dynamic> json) => PlatformControls(
        maintenance: json['maintenance'] is Map ? Map<String, dynamic>.from(json['maintenance'] as Map) : const {},
        disabledButtons: json['disabled_buttons'] is Map ? Map<String, dynamic>.from(json['disabled_buttons'] as Map) : const {},
        trial: json['trial'] is Map ? Map<String, dynamic>.from(json['trial'] as Map) : const {},
        forcePaidSubscription: json['force_paid_subscription'] == true,
        discounts: json['discounts'] is Map ? Map<String, dynamic>.from(json['discounts'] as Map) : const {},
        urgencyCountdown: json['urgency_countdown'] is Map ? Map<String, dynamic>.from(json['urgency_countdown'] as Map) : const {},
        subscriberCounter: json['subscriber_counter'] is Map ? Map<String, dynamic>.from(json['subscriber_counter'] as Map) : const {},
      );

  Map<String, dynamic> toJson() => {
        'maintenance': maintenance,
        'disabled_buttons': disabledButtons,
        'trial': trial,
        'force_paid_subscription': forcePaidSubscription,
        'discounts': discounts,
        'urgency_countdown': urgencyCountdown,
        'subscriber_counter': subscriberCounter,
      };

  static const _cacheKey = 'platform_controls_cache';

  /// Persist controls to SharedPreferences so offline users still see the
  /// last-known maintenance state (sections stay locked until admin lifts).
  Future<void> saveToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(toJson()));
    } catch (_) {}
  }

  /// Restore the last-known controls from SharedPreferences.  Returns null
  /// when no cache exists (first launch with no prior network).
  static Future<PlatformControls?> loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null || raw.isEmpty) return null;
      return PlatformControls.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  bool get isAllMaintenance => maintenance['all'] == true;
  bool isSectionMaintenance(String mode) =>
      maintenance['all'] == true || maintenance[mode] == true;

  List<String> disabledButtonsFor(String mode) {
    final raw = disabledButtons[mode];
    if (raw is List) return raw.whereType<String>().toList();
    final all = disabledButtons['all'];
    if (all is List) return all.whereType<String>().toList();
    return const [];
  }

  /// All disabled keys across every mode (deduplicated).
  List<String> get allDisabledKeys {
    final out = <String>{};
    for (final val in disabledButtons.values) {
      if (val is List) out.addAll(val.whereType<String>());
    }
    return out.toList();
  }

  /// True when [key] is currently disabled in ANY mode list.
  bool isDisabledKey(String key) => allDisabledKeys.contains(key);

  bool get trialEnabled {
    return trial['enabled'] != false; // default true
  }

  /// Normalized trial-duration unit: hours | days | weeks | months.
  String get trialUnit => normalizeTrialUnit(trial['unit']);

  /// Numeric trial-duration value (>= 1). Legacy `hours`/`days` keys are
  /// honored when the newer `value` key is absent.
  int get trialValue {
    final raw = trial['value'];
    if (raw != null) {
      final v = int.tryParse(raw.toString());
      if (v != null && v > 0) return v;
    }
    switch (trialUnit) {
      case 'days':
        final d = trial['days'];
        final dv = int.tryParse(d?.toString() ?? '');
        return (dv != null && dv > 0) ? dv : 1;
      default:
        final h = trial['hours'];
        final hv = int.tryParse(h?.toString() ?? '');
        return (hv != null && hv > 0) ? hv : 24;
    }
  }

  /// The full trial duration as a Flutter [Duration], ready to add onto
  /// `DateTime.now()` when activating the free trial locally.
  Duration get trialDuration {
    final v = trialValue;
    switch (trialUnit) {
      case 'days':
        return Duration(days: v);
      case 'weeks':
        return Duration(days: v * 7);
      case 'months':
        return Duration(days: v * 30);
      default:
        return Duration(hours: v);
    }
  }

  int get trialHours {
    if (trialUnit == 'hours') return trialValue;
    return trialDuration.inHours;
  }

  int get trialDays {
    if (trialUnit == 'days') return trialValue;
    return (trialDuration.inHours / 24).ceil();
  }

  /// Localized label: "أسبوع واحد", "7 أيام", "3 ساعات", "شهران", ...
  String durationLabel(AppLocalizations l10n) =>
      trialDurationLabel(l10n, unit: trial['unit'], value: trialValue);

  // ── Marketing extras (admin web: discounts, urgency, counter) ──

  /// Discount config for a plan key (personal/business/premium):
  /// `{percent: int, starts_on: ISO-date, ends_on: ISO-date}` or null when no
  /// ACTIVE discount. A discount counts only while now is inside
  /// [starts_on, ends_on]; outside the window the base price returns.
  Map<String, dynamic>? discountFor(String planKey) {
    final raw = discounts[planKey];
    if (raw is! Map) return null;
    final cfg = Map<String, dynamic>.from(raw as Map);
    final percent = int.tryParse(cfg['percent']?.toString() ?? '');
    if (percent == null || percent <= 0 || percent >= 100) return null;
    final now = DateTime.now();
    final startsOn = cfg['starts_on']?.toString();
    if (startsOn != null && startsOn.isNotEmpty) {
      final start = DateTime.tryParse(startsOn);
      if (start != null && now.isBefore(start)) return null; // not started
    }
    final endsOn = cfg['ends_on']?.toString();
    if (endsOn != null && endsOn.isNotEmpty) {
      final end = DateTime.tryParse(endsOn);
      if (end != null && now.isAfter(end)) return null; // expired
    }
    cfg['percent'] = percent;
    return cfg;
  }

  /// True when the fake urgency countdown is enabled by the admin.
  bool get urgencyEnabled => urgencyCountdown['enabled'] == true;

  /// Plan-keys allowed to show the urgency chip. When the list is empty (or
  /// absent — legacy configs) EVERY plan with seconds>0 shows it.
  List<String> get urgencyPlans {
    final raw = urgencyCountdown['plans'];
    if (raw is List) {
      final list = raw.whereType<String>()
          .map((k) => k.trim().toLowerCase())
          .where((k) => k.isNotEmpty)
          .toList();
      if (list.isNotEmpty) return list;
    }
    return const [];
  }

  /// Starting countdown seconds for a plan key (>=60 so it renders <10min).
  /// Returns 0 when the plan is excluded via the admin's `plans` selection.
  int urgencySecondsFor(String planKey) {
    if (!urgencyEnabled) return 0;
    final plans = urgencyPlans;
    final key = subscriptionIdentityKey(planKey);
    if (plans.isNotEmpty && !plans.contains(key)) return 0;
    final raw = urgencyCountdown[planKey];
    final v = int.tryParse(raw?.toString() ?? '');
    return (v != null && v >= 60) ? v : 0;
  }

  /// Fake paid-subscribers counter config.
  bool get subscriberCounterEnabled => subscriberCounter['enabled'] == true;
  int get subscriberCounterBase =>
      int.tryParse(subscriberCounter['base']?.toString() ?? '') ?? 0;
  int get subscriberCounterStep =>
      int.tryParse(subscriberCounter['step']?.toString() ?? '') ?? 0;
  int get subscriberCounterInterval =>
      int.tryParse(subscriberCounter['interval_seconds']?.toString() ?? '') ?? 10;

  // ── Maintenance hierarchy (single central system) ──────────────
  /// Canonical PERSONAL maintenance features (stable keys — single source of
  /// truth shared with the backend `features_catalog`). Only these appear in
  /// the admin maintenance list for Personal.
  static const List<String> kPersonalMaintenanceFeatures = [
    'personal/debts',
    'personal/savings',
    'personal/banks',
    'personal/budget',
    'personal/transactions',
    'personal/ai',
    'personal/suggestions',
  ];

  /// Legacy/sub-route aliases → canonical maintenance feature.
  static final Map<String, String> kFeatureAliases = {
    'personal/transactions/add-income': 'personal/transactions',
    'personal/transactions/add-expense': 'personal/transactions',
    'banks': 'personal/banks',
    'transactions': 'personal/transactions',
    'debts': 'personal/debts',
    'budget': 'personal/budget',
    'savings': 'personal/savings',
    'ai': 'personal/ai',
    'suggestions': 'personal/suggestions',
  };

  /// Normalize any feature key/route to its canonical maintenance form.
  static String maintenanceFeatureFor(String key) {
    final norm = key.startsWith('/') ? key.substring(1) : key;
    return kFeatureAliases[norm] ?? norm;
  }

  static bool isFeatureInList(String key, dynamic list) {
    if (list is! List) return false;
    final norm = maintenanceFeatureFor(key);
    for (final raw in list) {
      final k = raw.toString();
      if (k == norm) return true;
      // canonical parent blocks the whole tree:
      // 'personal/transactions' blocks 'personal/transactions/add-income'
      if (norm.startsWith('$k/')) return true;
      // route without section prefix: '/suggestions' ↔ 'personal/suggestions'
      final v = maintenanceFeatureFor(k);
      if (v == norm) return true;
      if (k.endsWith('/${norm.split('/').last}') ||
          norm.endsWith('/${k.split('/').last}')) return true;
    }
    return false;
  }

  bool get isAppMaintenance => maintenance['all'] == true;
  bool get isPersonalMaintenance => isAppMaintenance || maintenance['personal'] == true;
  bool get isBusinessMaintenance => isAppMaintenance || maintenance['business'] == true;

  /// هل مسار [route] تحت الصيانة حسب الهرمية APP > PERSONAL/BUSINESS > FEATURE
  bool isRouteUnderMaintenance(String route) {
    if (isAppMaintenance) return true;
    final mode = _routeModeFor(route);
    if (mode == 'personal' && isPersonalMaintenance) return true;
    if (mode == 'business' && isBusinessMaintenance) return true;
    // feature-level via disabled_buttons
    return isFeatureDisabled(route);
  }

  /// هل ميزة محددة (مفتاح مثل personal/banks) معطلة؟
  bool isFeatureDisabled(String featureKey) {
    final norm = maintenanceFeatureFor(featureKey);
    // personal
    if (isFeatureInList(norm, disabledButtons['personal'])) return true;
    if (isFeatureInList(norm, disabledButtons['business'])) return true;
    if (isFeatureInList(norm, disabledButtons['all'])) return true;
    // also check if the raw route itself matches a disabled key
    return isDisabledKey(featureKey);
  }

  String? _routeModeFor(String route) {
    if (route.startsWith('/personal') || route.startsWith('/settings') || route.startsWith('/profile') || route.startsWith('/suggestions')) return 'personal';
    if (route.startsWith('/dashboard') || route.startsWith('/business') || route.startsWith('/customers') || route.startsWith('/suppliers') || route.startsWith('/products') || route.startsWith('/inventory') || route.startsWith('/sales') || route.startsWith('/purchases') || route.startsWith('/finance') || route.startsWith('/payments') || route.startsWith('/expenses') || route.startsWith('/cheques') || route.startsWith('/debts') || route.startsWith('/banks') || route.startsWith('/accounts') || route.startsWith('/journal') || route.startsWith('/reports') || route.startsWith('/employees') || route.startsWith('/payroll') || route.startsWith('/pos') || route.startsWith('/projects') || route.startsWith('/contracts') || route.startsWith('/users')) return 'business';
    return null;
  }

  /// مستوى الصيانة للمسار (للأولوية والعرض)
  String maintenanceLevelFor(String route) {
    if (isAppMaintenance) return 'app';
    final mode = _routeModeFor(route);
    if (mode == 'personal' && maintenance['personal'] == true) return 'personal';
    if (mode == 'business' && maintenance['business'] == true) return 'business';
    if (isFeatureDisabled(route)) return 'feature';
    return 'none';
  }
}

class PlatformControlsNotifier extends AsyncNotifier<PlatformControls> {
  /// Controls restored from local cache (null when none).
  static PlatformControls? _cachedOffline;

  @override
  Future<PlatformControls> build() async {
    return _fetch();
  }

  Future<PlatformControls> _fetch() async {
    try {
      final client = ref.read(apiClientProvider);
      final resp = await client.getSafe<Map<String, dynamic>>('/controls');
      final controls = PlatformControls.fromJson(resp.data ?? const {});
      // Cache for offline fallback (persists maintenance flags across restarts).
      _cachedOffline = controls;
      unawaited(controls.saveToPrefs());
      return controls;
    } catch (_) {
      // Offline or error: restore last-known controls so maintenance state
      // (personal/business/all) persists even without network.
      if (_cachedOffline != null) return _cachedOffline!;
      final saved = await PlatformControls.loadFromPrefs();
      if (saved != null) {
        _cachedOffline = saved;
        return saved;
      }
      return const PlatformControls();
    }
  }

  Future<void> refresh() async {
    state = AsyncValue.data(await _fetch());
  }
}

final platformControlsProvider =
    AsyncNotifierProvider<PlatformControlsNotifier, PlatformControls>(
        PlatformControlsNotifier.new);