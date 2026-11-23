import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/app_icon_badge.dart';

class PersonalReportsCenterPage extends StatelessWidget {
  const PersonalReportsCenterPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 100),
      children: [
        _HeroCenterHeader(),
        SizedBox(height: 20),
        _SectionLabel(title: l10n.translate('homeServiceFinancialReports')),
        SizedBox(height: 12),
        _ReportCard(
          icon: TwoToneIcons.chart,
          title: l10n.translate('homeServiceFinancialReports'),
          subtitle: l10n.translate('financialReportsSubtitle'),
          gradient: [Color(0xFFC01838), AppColors.primary],
          route: RouteNames.personalReports,
        ),
        SizedBox(height: 10),
        _ReportCard(
          icon: TwoToneIcons.barChart,
          title: l10n.translate('homeServiceAnalytics'),
          subtitle: l10n.translate('analyticsSubtitle'),
          gradient: [Color(0xFF1565C0), Color(0xFF42A5F5)],
          route: RouteNames.personalAnalytics,
        ),
        SizedBox(height: 10),
        _ReportCard(
          icon: TwoToneIcons.bank,
          title: l10n.translate('allBanksReport'),
          subtitle: l10n.translate('banksReportSubtitle'),
          gradient: [Color(0xFF2E7D32), Color(0xFF66BB6A)],
          route: RouteNames.personalAllBanksReport,
        ),
        SizedBox(height: 10),
        _ReportCard(
          icon: TwoToneIcons.invoice,
          title: l10n.translate('executiveDashboard'),
          subtitle: l10n.translate('executiveDashboardSubtitle'),
          gradient: [Color(0xFF6A1B9A), Color(0xFFAB47BC)],
          route: RouteNames.personalExecutive,
        ),
        SizedBox(height: 24),
        _SectionLabel(title: l10n.translate('smartTools')),
        SizedBox(height: 12),
        Row(children: [
          Expanded(child: _QuickAction(
            icon: TwoToneIcons.download,
            label: l10n.translate('exportPdf'),
            color: AppColors.danger,
            onTap: () => context.push(RouteNames.personalReports),
          )),
          SizedBox(width: 10),
          Expanded(child: _QuickAction(
            icon: TwoToneIcons.savingsGoal,
            label: l10n.translate('personalSavingsGoals'),
            color: AppColors.success,
            onTap: () => context.push(RouteNames.personalSavings),
          )),
          SizedBox(width: 10),
          Expanded(child: _QuickAction(
            icon: TwoToneIcons.transfer,
            label: l10n.translate('currencyConversion'),
            color: AppColors.info,
            onTap: () => context.push(RouteNames.personalBanks),
          )),
        ]),
        SizedBox(height: 24),
        _SectionLabel(title: l10n.translate('quickReport')),
        SizedBox(height: 12),
        _QuickSummaryCard(),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════
//  HERO HEADER
// ════════════════════════════════════════════════════════════
class _HeroCenterHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment(-1, -1), end: Alignment(1.5, 1.5), colors: [Color(0xFFC01838), AppColors.primary, Color(0xFF7A1020)]),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(color: AppColors.primary.withAlpha(80), blurRadius: 24, offset: Offset(0, 10))],
      ),
      child: Stack(children: [
        Positioned(top: -25, right: -20, child: Container(width: 90, height: 90, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withAlpha(12)))),
        Positioned(bottom: -35, left: -15, child: Container(width: 110, height: 110, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withAlpha(8)))),
        Row(children: [
          AppIconBadge(
            icon: TwoToneIcons.chart.outline, size: 52, iconSize: 26,
            backgroundColor: Colors.white.withAlpha(20),
            borderColor: Colors.white.withAlpha(30),
          ),
          SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l10n.translate('reportsCenter'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 22), fontWeight: FontWeight.w700, color: Colors.white)),
            SizedBox(height: 4),
            Text(l10n.translate('reportsCenterSubtitle'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: Colors.white.withAlpha(150))),
          ])),
        ]),
      ]),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  SECTION LABEL
// ════════════════════════════════════════════════════════════
class _SectionLabel extends StatelessWidget {
  final String title;
  const _SectionLabel({required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Container(width: 4, height: 18, decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(2))),
      SizedBox(width: 10),
      Text(title, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
    ]);
  }
}

// ════════════════════════════════════════════════════════════
//  REPORT CARD
// ════════════════════════════════════════════════════════════
class _ReportCard extends StatelessWidget {
  final TwoToneIconData icon;
  final String title;
  final String subtitle;
  final List<Color> gradient;
  final String route;
  const _ReportCard({required this.icon, required this.title, required this.subtitle, required this.gradient, required this.route});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        context.push(route);
      },
      child: Container(
        padding: EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment(1, -0.5), end: Alignment(-1, 0.5), colors: gradient),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: gradient.last.withAlpha(60), blurRadius: 16, offset: Offset(0, 8))],
        ),
        child: Row(children: [
          AppIconBadge(icon: icon.outline, size: 48, iconSize: 24, backgroundColor: Colors.white.withAlpha(20), borderColor: Colors.white.withAlpha(30)),
          SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w700, color: Colors.white)),
            SizedBox(height: 3),
            Text(subtitle, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: Colors.white.withAlpha(150)), maxLines: 2, overflow: TextOverflow.ellipsis),
          ])),
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(color: Colors.white.withAlpha(20), borderRadius: BorderRadius.circular(8)),
            child: TwoToneIcon(data: TwoToneIcons.arrowLeft, size: 16, outlineColor: Colors.white.withAlpha(200)),
          ),
        ]),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  QUICK ACTION
// ════════════════════════════════════════════════════════════
class _QuickAction extends StatelessWidget {
  final TwoToneIconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _QuickAction({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: color.withAlpha(15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withAlpha(40)),
        ),
        child: Column(children: [
          AppIconBadge(icon: icon.outline, size: 40, iconSize: 20, backgroundColor: color.withAlpha(20), borderColor: color.withAlpha(40), accentColor: color),
          SizedBox(height: 8),
          Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), fontWeight: FontWeight.w600, color: color), textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  QUICK SUMMARY CARD
// ════════════════════════════════════════════════════════════
class _QuickSummaryCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          TwoToneIcon(data: TwoToneIcons.sparkle, size: 18, outlineColor: AppColors.gold),
          SizedBox(width: 8),
          Text(l10n.translate('quickTip'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        ]),
        SizedBox(height: 8),
        Text(l10n.translate('quickTipContent'),
          style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textSecondary), maxLines: 3, overflow: TextOverflow.ellipsis),
      ]),
    );
  }
}
