import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:go_router/go_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/responsive/r_api.dart';
import '../../core/router/route_names.dart';
import '../../core/localization/app_localizations.dart';
import '../../core/utils/country_names.dart';
import '../../features/auth/presentation/providers/auth_provider.dart';
import '../../features/subscription/di/subscription_providers.dart';
import '../../features/subscription/domain/section_access.dart';
import '../../features/subscription/presentation/providers/subscription_providers.dart';
import '../../core/network/api_exceptions.dart';
import '../providers/platform_controls_provider.dart';
import '../services/notification_service.dart';
import '../../features/branches/data/branch_api.dart';
import '../../features/branches/data/branch_scope.dart';
import '../../features/employees/presentation/providers/employee_device_finance_provider.dart';
import '../../core/services/section_scope.dart';
import 'confirm_dialog.dart';
import 'two_tone_icon.dart';
import 'two_tone_icons.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class _GateCountry {
  final String iso;
  final String cc;

  /// Known leading digit(s) of local mobile numbers (shown as example).
  final String prefix;

  /// Total national digits (without country code).
  final int len;
  const _GateCountry(this.iso, this.cc, this.prefix, this.len);

  /// Example placeholder: known prefix + × for the remaining digits.
  String get exampleHint {
    final rest = len - prefix.length;
    if (rest <= 0) return prefix;
    return prefix + '×' * rest;
  }
}

const _gateCountries = [
  _GateCountry('YE', '+967', '7', 9),
  _GateCountry('SA', '+966', '5', 10),
  _GateCountry('AE', '+971', '5', 9),
  _GateCountry('KW', '+965', '9', 8),
  _GateCountry('QA', '+974', '3', 8),
  _GateCountry('BH', '+973', '3', 8),
  _GateCountry('OM', '+968', '9', 8),
  _GateCountry('JO', '+962', '7', 9),
  _GateCountry('LB', '+961', '7', 8),
  _GateCountry('IQ', '+964', '7', 11),
  _GateCountry('SY', '+963', '9', 10),
  _GateCountry('PS', '+970', '5', 9),
  _GateCountry('EG', '+20', '1', 11),
  _GateCountry('TR', '+90', '5', 10),
  _GateCountry('MA', '+212', '6', 9),
  _GateCountry('TN', '+216', '2', 8),
  _GateCountry('DZ', '+213', '6', 10),
  _GateCountry('LY', '+218', '9', 10),
  _GateCountry('SD', '+249', '9', 9),
];

String _flagOf(String iso) {
  final base = 0x1F1E6;
  return String.fromCharCode(base + iso.codeUnitAt(0) - 65) +
      String.fromCharCode(base + iso.codeUnitAt(1) - 65);
}

class SubscriptionGate extends ConsumerWidget {
  final Widget child;

  /// When true the gate renders a FULL-SCREEN paywall instead of an overlay on
  /// top of the page content. Used to wrap the whole app shell so a
  /// non-subscriber can NEVER see hidden feature UI behind the gate.
  final bool fullScreen;

  const SubscriptionGate({
    super.key,
    required this.child,
    this.fullScreen = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final user = auth.user;

    if (user == null) return child;

    // Admin bypasses all subscription checks
    if (user.isAdmin) return child;

    // An invited branch member works inside the COMPANY's subscription; they
    // must not be forced to buy a Business plan of their own. Only the
    // Business section is unlocked, and only while they actually hold at
    // least one active branch membership.
    final uri = GoRouterState.of(context).uri;
    final isPersonal = uri.path.startsWith('/personal');
    if (employeeSelfWorkspaceRoute(uri.path, readOnly: uri.queryParameters['ro'] == '1') &&
        ref.watch(employeeDeviceSelectionProvider) != null) {
      // The self-service pages themselves require the unexpired, scoped copy.
      // Never extend this exception to the merchant's operational routes.
      return child;
    }
    if (!isPersonal &&
        BranchScope.organizationId != user.organizationId) {
      final companies = ref.watch(branchAccessProvider).valueOrNull ?? const [];
      final hasMembership = companies.any(
        (c) =>
            '${c['role']}' == 'member' &&
            '${c['organization_id']}' == BranchScope.organizationId &&
            ((c['branches'] as List?)?.isNotEmpty ?? false),
      );
      if (hasMembership) return child;
    }

    // ── Live server status is authoritative ──
    // A cancelled subscription must be reflected INSTANTLY even if the cached
    // user model still says `active`. The admin revoke → push arrives → this
    // provider refreshes → expired here, exactly as the router guard does.
    final snapshot = ref.watch(subscriptionStatusProvider);
    final live = snapshot.valueOrNull?['status']?.toString();
    if (isPersonal) {
      // The router already verified this section before mounting it. An
      // unavailable refresh must not replace a working Personal page with a
      // paywall based on a stale, aggregate user profile.
      final sections = snapshot.valueOrNull?['sections'];
      if (snapshot.hasError || snapshot.isLoading || sections is! Map ||
          hasSectionAccess(snapshot.valueOrNull, 'personal')) {
        return child;
      }
      return fullScreen ? _FullScreenExpiredGate() : _ExpiredGate(child: child);
    }

    if (uri.path == RouteNames.dashboard &&
        snapshot.asData == null &&
        hasSectionAccess(
          ref.watch(businessNavigationStatusProvider).asData?.value, 'business',
        )) {
      return child;
    }

    // Active → full access, no overlay (paid OR trial).
    if (live == 'active' || user.effectiveStatus == 'active') return child;

    // Trial → full access (clock icon in header handles countdown).
    if (live == 'trial' || user.effectiveStatus == 'trial') return child;

    // ── Not active anymore (pending / expired / cancelled / rejected / none) ──
    final livePending = live == 'pending';
    final userPending = user.effectiveStatus == 'pending';
    // `none` = brand-new account that was never subscribed and has no request
    // pending. Show the plans page / trial CTA instead of a fake waiting box.
    final isNeverSubscribed = live == 'none';
    final pending = livePending || (userPending && !isNeverSubscribed);
    final controls = ref.watch(platformControlsProvider).valueOrNull;
    final trialOffered =
        controls == null ||
        (controls.trialEnabled && !controls.forcePaidSubscription);

    if (pending) {
      // Pending review: offer the free trial ONLY if it is still available
      // on this device AND not yet used. Otherwise force the paid plan page.
      if (user.personalTrialActivated || !trialOffered) {
        return fullScreen
            ? _FullScreenExpiredGate()
            : _ExpiredGate(child: child);
      }
      return fullScreen
          ? _FullScreenExpiredGate(trial: true)
          : _PendingGate(child: child);
    }

    // Expired / cancelled / rejected / none → if the admin still offers the
    // free trial and this user never used it, show the FREE trial popup first;
    // otherwise force the paid paywall immediately.
    if (trialOffered && !user.personalTrialActivated) {
      return fullScreen
          ? _FullScreenExpiredGate(trial: true)
          : _PendingGate(child: child);
    }
    return fullScreen ? _FullScreenExpiredGate() : _ExpiredGate(child: child);
  }
}

// ════════════════════════════════════════════════════════════
//  PENDING GATE — transparent overlay with trial CTA
// ════════════════════════════════════════════════════════════
class _PendingGate extends ConsumerStatefulWidget {
  final Widget child;
  const _PendingGate({required this.child});

  @override
  ConsumerState<_PendingGate> createState() => _PendingGateState();
}

class _PendingGateState extends ConsumerState<_PendingGate> {
  bool _loading = false;

  Future<void> _activateTrial() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      await _activateTrialCore();
    } catch (e) {
      if (!mounted) return;
      final msg = e is ApiException
          ? e.message
          : AppLocalizations.of(context).translate('gateTrialFailed');
      showSnackbar(context, message: msg, color: AppColors.danger);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _activateTrialCore() async {
    final service = ref.read(subscriptionServiceProvider);
    final resp = await service.activateTrial(mode: 'personal');

    // Precise duration from backend (handles 50h / days/weeks/months exactly)
    final now = DateTime.now();
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
          case 'days':
            duration = Duration(days: val);
            break;
          case 'weeks':
            duration = Duration(days: val * 7);
            break;
          case 'months':
            duration = Duration(days: val * 30);
            break;
          default:
            duration = Duration(hours: val);
            break;
        }
      } else {
        final controls = ref.read(platformControlsProvider).valueOrNull;
        duration = controls?.trialDuration ?? const Duration(hours: 24);
      }
    }
    final end = now.add(duration);
    ref
        .read(authProvider.notifier)
        .applyUserUpdate(
          (u) => u.copyWith(
            status: 'trial',
            trialStartDate: now.toIso8601String(),
            trialEndDate: end.toIso8601String(),
            personalTrialActivated: true,
          ),
        );

    try {
      ref.invalidate(platformControlsProvider);
    } catch (_) {}
    try {
      ref.invalidate(subscriptionStatusProvider);
    } catch (_) {}
    unawaited(ref.read(authProvider.notifier).refreshProfile());

    if (!mounted) return;
    ref.read(notificationServiceProvider).showSaraWelcome(mode: 'personal');
    showSnackbar(
      context,
      message: AppLocalizations.of(context).translate('gateTrialActivated'),
      color: AppColors.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final trialControls = ref.watch(platformControlsProvider).valueOrNull;
    final trialOfferLabel = trialControls != null
        ? trialControls.durationLabel(l10n)
        : l10n.translate('timeout24h');
    return Stack(
      children: [
        widget.child,
        // Dark overlay
        Container(color: Colors.black.withAlpha(97)),
        // Trial CTA card
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border, width: 0.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(80),
                    blurRadius: 40,
                    offset: const Offset(0, 16),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Gift icon with glow
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          AppColors.primary.withAlpha(40),
                          AppColors.primary.withAlpha(10),
                        ],
                      ),
                    ),
                    child: Center(
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [AppColors.primary, AppColors.primaryDark],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.primary.withAlpha(80),
                              blurRadius: 20,
                            ),
                          ],
                        ),
                        child: TwoToneIcon(
                          data: TwoToneIcons.gift,
                          size: 28,
                          outlineColor: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Title
                  Text(
                    l10n.translate('gateTrialTitle'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 20),
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Subtitle
                  Text(
                    l10n.translate('gateTrialSubtitle'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 14),
                      color: AppColors.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // ── Configured trial duration badge (days/hours/weeks/months) ──
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withAlpha(14),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: AppColors.primary.withAlpha(70),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.schedule_rounded,
                          size: 15,
                          color: AppColors.primary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          trialOfferLabel,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 12),
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.translate('gateNoCard'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 12),
                      color: AppColors.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // CTA button — activates trial directly
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [AppColors.primary, AppColors.primaryDark],
                        ),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withAlpha(80),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ElevatedButton(
                        onPressed: _loading ? null : _activateTrial,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _loading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                l10n.translate('gateSubscribeTrial'),
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: R.fontSize(context, 15),
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════
//  EXPIRED GATE — overlay with subscribe CTA
// ════════════════════════════════════════════════════════════
class _ExpiredGate extends StatelessWidget {
  final Widget child;
  const _ExpiredGate({required this.child});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Stack(
      children: [
        child,
        // Dark overlay
        Container(color: Colors.black.withAlpha(97)),
        // Expired CTA card
        Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 28),
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border, width: 0.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(80),
                  blurRadius: 40,
                  offset: const Offset(0, 16),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Expired icon
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        AppColors.danger.withAlpha(40),
                        AppColors.danger.withAlpha(10),
                      ],
                    ),
                  ),
                  child: Center(
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [AppColors.danger, Color(0xFF8B0000)],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.danger.withAlpha(80),
                            blurRadius: 20,
                          ),
                        ],
                      ),
                      child: TwoToneIcon(
                        data: TwoToneIcons.clock,
                        size: 28,
                        outlineColor: Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Title
                Text(
                  l10n.translate('gateExpiredTitle'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 20),
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),

                // Subtitle
                Text(
                  l10n.translate('gateExpiredSubtitle'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 14),
                    color: AppColors.textTertiary,
                  ),
                ),
                const SizedBox(height: 24),

                // CTA button
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [AppColors.primary, AppColors.primaryDark],
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primary.withAlpha(80),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ElevatedButton(
                      onPressed: () => context.go(RouteNames.subscription),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        l10n.translate('gateChoosePlan'),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 15),
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════
//  FULL-SCREEN GATE — hard paywall replacing the whole shell.
// Used for the app-wide subscription enforcement. The feature content is
// NEVER rendered behind it — a non-subscriber only sees this screen.
// ════════════════════════════════════════════════════════════
class _FullScreenExpiredGate extends StatelessWidget {
  /// When true, offers the free trial CTA (admin-side trial still enabled).
  final bool trial;
  const _FullScreenExpiredGate({this.trial = false});

  /// Locale-aware label for the renew/plans CTA button, with a built-in
  /// Arabic fallback so it never renders a bare key.
  String _gateRenewLabel(AppLocalizations l10n) =>
      l10n.translate('gateRenewSubscription') == 'gateRenewSubscription'
      ? 'تجديد الاشتراك'
      : l10n.translate('gateRenewSubscription');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border, width: 0.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(80),
                  blurRadius: 40,
                  offset: const Offset(0, 16),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Lock icon
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        AppColors.primary.withAlpha(40),
                        AppColors.primary.withAlpha(10),
                      ],
                    ),
                  ),
                  child: Center(
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [AppColors.primary, AppColors.primaryDark],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withAlpha(80),
                            blurRadius: 20,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.hourglass_bottom_rounded,
                        size: 28,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  l10n.translate('gateExpiredTitle'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 20),
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.translate('gateExpiredSubtitle'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 14),
                    color: AppColors.textTertiary,
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: () => context.go(RouteNames.subscription),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _gateRenewLabel(l10n),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 15),
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  COUNTRY PICKER SHEET — searchable country list
// ════════════════════════════════════════════════════════════
class _GateCountryPickerSheet extends StatefulWidget {
  final String initial;
  const _GateCountryPickerSheet({required this.initial});

  @override
  State<_GateCountryPickerSheet> createState() =>
      _GateCountryPickerSheetState();
}

class _GateCountryPickerSheetState extends State<_GateCountryPickerSheet> {
  final _searchCtrl = TextEditingController();
  late List<_GateCountry> _filtered;

  @override
  void initState() {
    super.initState();
    _filtered = _gateCountries;
    _searchCtrl.addListener(_applyFilter);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _isAr() => Localizations.localeOf(context).languageCode == 'ar';

  String _countryLabel(_GateCountry c) => countryName(c.iso, isAr: _isAr());

  void _applyFilter() {
    final q = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? _gateCountries
          : _gateCountries
                .where(
                  (c) =>
                      _countryLabel(c).contains(q) ||
                      _countryLabel(c).toLowerCase().contains(q) ||
                      c.cc.contains(q) ||
                      c.iso.toLowerCase().contains(q),
                )
                .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(
          top: BorderSide(color: AppColors.primary.withAlpha(40), width: 0.5),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(20),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.public_rounded,
                    size: 20,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  AppLocalizations.of(context).translate('gateChooseCountry'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 17),
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const Spacer(),
                Text(
                  AppLocalizations.of(context).translate(
                    'gateCountryCount',
                    params: {'count': _filtered.length},
                  ),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 12),
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          // ── Search ──
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
                hintText: AppLocalizations.of(
                  context,
                ).translate('gateSearchCountry'),
                hintStyle: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 13),
                  color: AppColors.textPlaceholder,
                ),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  size: 20,
                  color: AppColors.textSecondary,
                ),
                filled: true,
                fillColor: AppColors.surfaceVariant,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
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
                        Icon(
                          Icons.search_off_rounded,
                          size: 40,
                          color: AppColors.textDisabled,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          AppLocalizations.of(
                            context,
                          ).translate('gateNoResults'),
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 14),
                            color: AppColors.textSecondary,
                          ),
                        ),
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
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 12,
                            ),
                            color: selected
                                ? AppColors.primary.withAlpha(15)
                                : null,
                            child: Row(
                              children: [
                                Text(
                                  _flagOf(c.iso),
                                  style: const TextStyle(fontSize: 24),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Text(
                                    _countryLabel(c),
                                    style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: R.fontSize(context, 14),
                                      fontWeight: selected
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      color: selected
                                          ? AppColors.primary
                                          : AppColors.textPrimary,
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? AppColors.primary.withAlpha(20)
                                        : AppColors.surfaceVariant,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    '\u200E${c.cc}',
                                    style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: R.fontSize(context, 13),
                                      fontWeight: FontWeight.w600,
                                      color: selected
                                          ? AppColors.primary
                                          : AppColors.textSecondary,
                                    ),
                                  ),
                                ),
                                if (selected) ...[
                                  const SizedBox(width: 10),
                                  Icon(
                                    Icons.check_circle_rounded,
                                    size: 18,
                                    color: AppColors.primary,
                                  ),
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
