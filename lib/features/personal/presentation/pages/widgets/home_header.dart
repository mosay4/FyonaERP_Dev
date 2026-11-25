import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/core/router/shell_keys.dart';
import 'package:fyona_flutter/core/services/section_scope.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';
import 'package:fyona_flutter/features/branches/presentation/widgets/business_branch_chip.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/employees/presentation/widgets/employee_avatar.dart';
import 'package:fyona_flutter/shared/widgets/two_tone_icon.dart';
import 'package:fyona_flutter/shared/widgets/two_tone_icons.dart';
import 'package:fyona_flutter/features/auth/presentation/providers/auth_provider.dart';
import 'package:fyona_flutter/features/subscription/presentation/providers/subscription_providers.dart';
import 'package:fyona_flutter/shared/providers/current_user_provider.dart';
import 'package:fyona_flutter/features/profile/presentation/providers/avatar_provider.dart';
import 'package:fyona_flutter/features/profile/presentation/providers/section_profile_provider.dart';
import 'package:fyona_flutter/features/notifications/presentation/widgets/unread_notification_bell.dart';
import 'package:fyona_flutter/shared/providers/platform_controls_provider.dart';
import 'package:fyona_flutter/shared/widgets/connectivity_widgets.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';


class HomeHeader extends ConsumerWidget {
  HomeHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPersonal = isPersonalSectionRoute(
      GoRouterState.of(context).uri.path,
      ref.watch(activeSectionProvider).name,
    );
    final user = ref.watch(authProvider).user;
    final rawStatus = user?.status;
    // Prefer the LIVE subscription snapshot so the hourglass counts down from
    // EXACTLY the same end date shown in «تفاصيل اشتراكك» (profile) — no more
    // mismatch between the header hourglass and the subscription details.
    final liveSub = ref.watch(subscriptionStatusProvider).valueOrNull;
    final isTrial = liveSub?['is_trial'] == true || rawStatus == 'trial';
    final trialEndStr =
        (liveSub?['end_date'] as String?) ?? user?.trialEndDate;
    final trialStartStr =
        (liveSub?['start_date'] as String?) ?? user?.trialStartDate;

    // Hide the trial hourglass when the admin turned the trial off (or forced
    // paid subscriptions) — it must not appear for users at all in that case.
    final controls = ref.watch(platformControlsProvider).valueOrNull;
    final trialVisible = controls == null ||
        (controls.trialEnabled && !controls.forcePaidSubscription);

    Duration? trialRemaining;
    Duration trialTotal = const Duration(hours: 24);
    if (isTrial && trialEndStr != null) {
      final end = DateTime.tryParse(trialEndStr);
      final start = trialStartStr != null ? DateTime.tryParse(trialStartStr) : null;
      if (start != null && end != null && end.isAfter(start)) {
        trialTotal = end.difference(start);
      } else if (start != null) {
        // Start exists but no end yet — fall back to the admin-configured
        // duration so the sand fills the whole active trial span.
        final cfg = ref.watch(platformControlsProvider).valueOrNull;
        final dur = cfg?.trialDuration ?? const Duration(hours: 24);
        trialTotal = dur;
        if (end == null) {
          final expiry = start.add(dur);
          trialRemaining = expiry.difference(DateTime.now());
          if (trialRemaining.isNegative) trialRemaining = null;
        }
      }
      if (end != null) {
        // Remaining is always measured from the backend end date; the total
        // span above only drives the hourglass sand fill.
        trialRemaining = end.difference(DateTime.now());
        if (trialRemaining.isNegative) trialRemaining = null;
      }
    }

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 4),
        child: Row(
          children: [
            GestureDetector(
              onTap: () => shellScaffoldKey.currentState?.openDrawer(),
              child: TwoToneIcon(data: TwoToneIcons.menu, size: 20, outlineColor: AppColors.textPrimary),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppLocalizations.of(context).translate(
                        isPersonal ? 'headerSectionPersonal' : 'headerSectionBusiness'),
                    style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 17), fontWeight: FontWeight.w700, color: AppColors.textPrimary, height: 1.3),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // Current branch UNDER the title — only with 2+ branches
                  // (collapses to nothing otherwise).
                  if (!isPersonal) const BusinessBranchChip(),
                ],
              ),
            ),
            ConnectivityIndicator(online: ref.watch(connectivityServiceProvider).isOnline, size: 18),
            const SizedBox(width: 10),
            if (trialRemaining != null && trialVisible) ...[
              _HeaderTrialClock(
                remaining: trialRemaining,
                total: trialTotal,
                endDate: trialEndStr,
                startDate: trialStartStr,
              ),
              const SizedBox(width: 10),
            ],
            if (isPersonal || ref.watch(employeeCanProvider('notifications'))) ...[
            UnreadNotificationBell(
              icon: Icons.notifications_outlined,
              color: AppColors.textPrimary,
              iconSize: 18,
            ),
            const SizedBox(width: 10),
            ],
            const HomeProfileAvatar(),
          ],
        ),
      ),
    );
  }
}

/// Route-aware identity; a merchant workspace must never open its owner's profile.
class HomeProfileAvatar extends ConsumerWidget {
  const HomeProfileAvatar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(branchEpochProvider);
    final isPersonal = GoRouterState.of(context).uri.path.startsWith('/personal');
    final company = ref.watch(employeeWorkspaceCompanyProvider);
    final org = BranchScope.organizationId;
    final employeeWorkspace = !isPersonal && company != null && org != null;
    final employee = employeeWorkspace
        ? (ref.watch(myEmployeeProfileForProvider(org)).valueOrNull?['employee'] as Map?)
        : null;
    return GestureDetector(
      onTap: () => context.push(employeeWorkspace
          ? '/employee-profile'
          : RouteNames.profileForMode(ref.read(currentBusinessTypeProvider))),
      child: employeeWorkspace
          ? EmployeeAvatar(photo: employee?['photo_url'] as String?, size: 32)
          : _ProfileAvatar(),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  PROFILE AVATAR — crimson circular border + profile image
// ════════════════════════════════════════════════════════════
class _ProfileAvatar extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final avatarBytes =
        ref.watch(sectionProfileProvider).avatar ?? ref.watch(avatarProvider);
    return Container(
      width: 32, height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.primary, width: 2),
      ),
      child: ClipOval(
        child: avatarBytes != null
            ? Image.memory(avatarBytes, gaplessPlayback: true, fit: BoxFit.cover, width: 32, height: 32)
            : Icon(Icons.person, size: 18, color: AppColors.textSecondary),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  HEADER TRIAL HOURGLASS — animated sand flowing top→bottom
// ════════════════════════════════════════════════════════════
class _HeaderTrialClock extends StatefulWidget {
  final Duration remaining;
  final Duration total;
  final String? startDate;
  final String? endDate;
  const _HeaderTrialClock({
    required this.remaining,
    required this.total,
    this.startDate,
    this.endDate,
  });

  @override
  State<_HeaderTrialClock> createState() => _HeaderTrialClockState();
}

class _HeaderTrialClockState extends State<_HeaderTrialClock>
    with SingleTickerProviderStateMixin {
  Timer? _timer;
  int _seconds = 0;
  bool _dismissed = false;
  bool _expired = false;
  static const _dismissKey = 'header_trial_clock_dismissed';
  late AnimationController _sandCtrl;

  DateTime? get _end =>
      widget.endDate != null ? DateTime.tryParse(widget.endDate!) : null;

  /// Remaining seconds measured from the SAME end date the profile details
  /// sheet uses — recomputed every tick so the two clocks can never drift.
  int _computeSeconds() {
    final end = _end;
    if (end != null) {
      final r = end.difference(DateTime.now()).inSeconds;
      return r < 0 ? 0 : r;
    }
    return _seconds > 0 ? _seconds - 1 : 0;
  }

  @override
  void initState() {
    super.initState();
    _seconds = widget.remaining.inSeconds;
    _sandCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))
      ..repeat(reverse: true);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final next = _computeSeconds();
      if (next <= 0) {
        // Trial just ran out — freeze the clock and bounce the user to the
        // subscription screen so they can never stay inside an expired trial.
        if (_expired) return;
        _expired = true;
        setState(() => _seconds = 0);
        _expireNow();
      } else {
        setState(() => _seconds = next);
      }
    });
    _loadDismissed();
  }

  @override
  void didUpdateWidget(covariant _HeaderTrialClock old) {
    super.didUpdateWidget(old);
    // Resync as soon as the live subscription snapshot (or a refresh) arrives.
    if (widget.remaining != old.remaining) {
      _seconds = widget.remaining.inSeconds;
    }
  }

  Future<void> _loadDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _dismissed = prefs.getBool(_dismissKey) ?? false);
  }

  Future<void> _dismiss() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_dismissKey, true);
    if (mounted) setState(() => _dismissed = true);
  }

  void _expireNow() {
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(AppLocalizations.of(context).translate('trialExpiredNow'), style: TextStyle(fontFamily: 'Cairo')),
      backgroundColor: AppColors.danger,
    ));
    context.go(RouteNames.subscription);
  }

  @override
  void dispose() { _timer?.cancel(); _sandCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    if (_dismissed || _seconds <= 0) return const SizedBox.shrink();

    final totalSec = widget.total.inSeconds;
    final progress = totalSec > 0 ? (_seconds / totalSec).clamp(0.0, 1.0) : 0.0;

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        _showSheet(context);
      },
      onLongPress: () {
        HapticFeedback.mediumImpact();
        _dismiss();
      },
      child: AnimatedBuilder(
        animation: _sandCtrl,
        builder: (_, __) => CustomPaint(
          size: const Size(18, 24),
          painter: _HourglassPainter(
            progress: progress,
            sandPhase: _sandCtrl.value,
            frameColor: AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  void _showSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _TrialCountdownSheet(
        remainingSeconds: _seconds,
        startDate: widget.startDate,
        endDate: widget.endDate,
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  HOURGLASS PAINTER — crimson sand, glass frame
// ════════════════════════════════════════════════════════════
class _HourglassPainter extends CustomPainter {
  final double progress;
  final double sandPhase;
  final Color frameColor;

  _HourglassPainter({required this.progress, required this.sandPhase, required this.frameColor});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;

    const bodyTop = 2.0;
    final bodyBot = h - 2.0;
    final waist = h / 2;
    final topW = w * 0.40;
    final waistW = 1.2;

    // ── Glass frame outline ──
    final frame = Path()
      ..moveTo(cx - topW, bodyTop)
      ..lineTo(cx + topW, bodyTop)
      ..lineTo(cx + waistW, waist)
      ..lineTo(cx + topW, bodyBot)
      ..lineTo(cx - topW, bodyBot)
      ..lineTo(cx - waistW, waist)
      ..close();
    canvas.drawPath(frame, Paint()
      ..color = frameColor.withAlpha(140)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..strokeCap = StrokeCap.round);

    // ── Top sand (decreases as trial runs out) ──
    final sandH = (waist - bodyTop - 1) * 0.85;
    final topH = sandH * progress;
    if (topH > 0.3) {
      final yBot = waist - 1;
      final yTop = yBot - topH;
      final wBot = _lerpW(waist, waistW, bodyTop, topW, yBot);
      final wTop = _lerpW(waist, waistW, bodyTop, topW, yTop);
      final topSand = Path()
        ..moveTo(cx - wBot, yBot)
        ..lineTo(cx + wBot, yBot)
        ..lineTo(cx + wTop, yTop)
        ..lineTo(cx - wTop, yTop)
        ..close();
      canvas.drawPath(topSand, Paint()..shader = ui.Gradient.linear(
        Offset(0, yTop), Offset(0, yBot), [AppColors.primary, AppColors.primaryDark],
      ));
    }

    // ── Bottom sand (increases as trial runs out) ──
    final botH = sandH * (1.0 - progress);
    if (botH > 0.3) {
      final yBot = bodyBot - 0.5;
      final yTop = yBot - botH;
      final wBot = _lerpW(waist, waistW, bodyBot, topW, yBot);
      final wTop = _lerpW(waist, waistW, bodyBot, topW, yTop);
      final botSand = Path()
        ..moveTo(cx - wBot, yBot)
        ..lineTo(cx + wBot, yBot)
        ..lineTo(cx + wTop, yTop)
        ..lineTo(cx - wTop, yTop)
        ..close();
      canvas.drawPath(botSand, Paint()..shader = ui.Gradient.linear(
        Offset(0, yTop), Offset(0, yBot), [AppColors.primaryDark, AppColors.primary],
      ));
    }

    // ── Flowing stream ──
    if (progress > 0.02 && progress < 0.98) {
      final streamW = 0.6 + sin(sandPhase * pi) * 0.3;
      canvas.drawLine(
        Offset(cx, waist - topH * 0.3),
        Offset(cx, waist + 1.5),
        Paint()..color = AppColors.primary.withAlpha(200)..strokeWidth = streamW..strokeCap = StrokeCap.round,
      );
    }

    // ── Falling grains ──
    if (progress > 0.02 && progress < 0.98) {
      final rng = Random(42);
      for (var i = 0; i < 4; i++) {
        final t = (sandPhase + rng.nextDouble()) % 1.0;
        final gy = waist + 0.5 + t * 7.0;
        final gx = cx + sin(t * pi * 2 + i * 1.3) * 0.8;
        final alpha = (255 * (1.0 - t)).round().clamp(40, 200);
        canvas.drawCircle(Offset(gx, gy), 0.4 + rng.nextDouble() * 0.3,
          Paint()..color = AppColors.primary.withAlpha(alpha));
      }
    }

    // ── Bottom pile ──
    if (progress < 0.95) {
      final pileH = 2.0 * (1.0 - progress);
      final pile = Path()
        ..moveTo(cx - 3, bodyBot - 0.5)
        ..quadraticBezierTo(cx, bodyBot - 0.5 - pileH * 2, cx + 3, bodyBot - 0.5)
        ..close();
      canvas.drawPath(pile, Paint()..color = AppColors.primary.withAlpha(220));
    }
  }

  double _lerpW(double y1, double w1, double y2, double w2, double y) {
    final t = ((y - y1) / (y2 - y1)).clamp(0.0, 1.0);
    return w1 + (w2 - w1) * t;
  }

  @override
  bool shouldRepaint(covariant _HourglassPainter old) =>
      progress != old.progress || sandPhase != old.sandPhase || frameColor != old.frameColor;
}

// ════════════════════════════════════════════════════════════
//  BOTTOM SHEET — Full countdown + trial subscription details
// ════════════════════════════════════════════════════════════
class _TrialCountdownSheet extends StatefulWidget {
  final int remainingSeconds;
  final String? startDate;
  final String? endDate;
  const _TrialCountdownSheet({
    required this.remainingSeconds,
    this.startDate,
    this.endDate,
  });

  @override
  State<_TrialCountdownSheet> createState() => _TrialCountdownSheetState();
}

class _TrialCountdownSheetState extends State<_TrialCountdownSheet> {
  Timer? _timer;
  int _seconds = 0;

  int _computeSeconds() {
    final end =
        widget.endDate != null ? DateTime.tryParse(widget.endDate!) : null;
    if (end != null) {
      final r = end.difference(DateTime.now()).inSeconds;
      return r < 0 ? 0 : r;
    }
    return _seconds > 0 ? _seconds - 1 : 0;
  }

  @override
  void initState() {
    super.initState();
    _seconds = widget.remainingSeconds;
    if (widget.endDate != null) _seconds = _computeSeconds();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _seconds = _computeSeconds());
    });
  }

  @override
  void dispose() { _timer?.cancel(); super.dispose(); }

  String _fmt(String? iso) {
    if (iso == null) return '--';
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    return '${d.day}/${d.month}/${d.year}';
  }

  Widget _detailRow(BuildContext context, String iconLabel, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.schedule_rounded, size: 15, color: AppColors.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            iconLabel,
            style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textSecondary),
          ),
        ),
        Text(
          value,
          style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.w700, color: Colors.white),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _seconds ~/ 86400;
    final h = (_seconds % 86400) ~/ 3600;
    final m = (_seconds % 3600) ~/ 60;
    final s = _seconds % 60;
    final l10n = AppLocalizations.of(context);
    final showDays = d > 0;
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;

    return Container(
      height: MediaQuery.of(context).size.height * 0.72,
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF1A0A10), AppColors.background]),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: AppColors.primary.withAlpha(40), width: 0.5)),
      ),
      child: Column(children: [
        Container(width: 40, height: 4, margin: const EdgeInsets.only(top: 12), decoration: BoxDecoration(color: Colors.white.withAlpha(30), borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          TwoToneIcon(data: TwoToneIcons.gift, size: 20, outlineColor: AppColors.primary),
          const SizedBox(width: 8),
          Text(l10n.translate('trialCountdownTitle'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        ]),
        const SizedBox(height: 8),
        Center(
          child: Text(l10n.translate('trialPeriod'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.textSecondary)),
        ),
        const SizedBox(height: 20),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          if (showDays) ...[
            _SheetDigitBox(value: d.toString().padLeft(2, '0'), label: l10n.translate('day')),
            _SheetSeparator(),
          ],
          _SheetDigitBox(value: h.toString().padLeft(2, '0'), label: l10n.translate('hour')),
          _SheetSeparator(),
          _SheetDigitBox(value: m.toString().padLeft(2, '0'), label: l10n.translate('minute')),
          _SheetSeparator(),
          _SheetDigitBox(value: s.toString().padLeft(2, '0'), label: l10n.translate('second')),
        ]),
        const SizedBox(height: 22),
        // ── Trial subscription details ──
        Center(
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: 28),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(12),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.primary.withAlpha(50)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _detailRow(context, l10n.translate('startDate'), _fmt(widget.startDate)),
              const SizedBox(height: 8),
              _detailRow(context, l10n.translate('endDate'), _fmt(widget.endDate)),
            ]),
          ),
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: SizedBox(
            width: double.infinity, height: 48,
            child: ElevatedButton(
              onPressed: () { Navigator.pop(context); context.go(RouteNames.subscription); },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: Text(l10n.translate('subscribeNow'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700)),
            ),
          ),
        ),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Text(l10n.translate('close'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textTertiary)),
        ),
        SizedBox(height: bottomPad),
      ]),
    );
  }
}

class _SheetDigitBox extends StatelessWidget {
  final String value;
  final String label;
  const _SheetDigitBox({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 56, height: 52,
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF2A1520), Color(0xFF1A0A10)]),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primary.withAlpha(40), width: 0.5),
          boxShadow: [
            BoxShadow(color: AppColors.primary.withAlpha(15), blurRadius: 0, offset: const Offset(0, -1)),
            BoxShadow(color: Colors.black.withAlpha(60), blurRadius: 4, offset: const Offset(0, 3)),
          ],
        ),
        alignment: Alignment.center,
        child: Text(value, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 24), fontWeight: FontWeight.w800, color: AppColors.primary, height: 1.0)),
      ),
      const SizedBox(height: 4),
      Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 9), fontWeight: FontWeight.w500, color: Colors.white.withAlpha(120))),
    ]);
  }
}

class _SheetSeparator extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 4, height: 4, decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.primary.withAlpha(150))),
        const SizedBox(height: 6),
        Container(width: 4, height: 4, decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.primary.withAlpha(150))),
      ]),
    );
  }
}
