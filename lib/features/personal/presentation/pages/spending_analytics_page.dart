import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../../../../shared/widgets/app_icon_badge.dart';
import '../../../../shared/widgets/charts/app_charts.dart';
import '../../../../shared/widgets/receipt/receipt.dart';
import '../providers/personal_providers.dart';
import '../providers/receipt_design_provider.dart';

class SpendingAnalyticsPage extends ConsumerStatefulWidget {
  const SpendingAnalyticsPage({super.key});
  @override
  ConsumerState<SpendingAnalyticsPage> createState() => _SpendingAnalyticsPageState();
}

class _SpendingAnalyticsPageState extends ConsumerState<SpendingAnalyticsPage> {
  int _periodIndex = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { ref.read(personalFinanceProvider.notifier).load(); });
  }

  Duration get _periodDuration {
    switch (_periodIndex) {
      case 0: return const Duration(days: 7);
      case 1: return const Duration(days: 30);
      case 2: return const Duration(days: 90);
      default: return const Duration(days: 36500);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final periodLabels = [l10n.translate('last7Days'), l10n.translate('last30Days'), l10n.translate('last3Months'), l10n.translate('all')];
    final periodLabel = periodLabels[_periodIndex];
    final state = ref.watch(personalFinanceProvider);
    final now = DateTime.now();
    final period = _periodDuration;

    final filtered = state.transactions.where((t) {
      if (t.date == null) return period.inDays > 365;
      return t.date!.isAfter(now.subtract(period));
    }).toList();

    final engine = ref.read(currencyEngineProvider);
    final walletCurrency = state.walletCurrency;
    double _convert(dynamic t) {
      if (t.currency == walletCurrency) return t.amount;
      final converted = engine.convert(t.amount, t.currency, walletCurrency);
      return converted != 0 ? converted : t.amount;
    }

    final totalIncome = filtered.where((t) => t.type == 'income').fold<double>(0, (s, t) => s + _convert(t));
    final totalExpenses = filtered.where((t) => t.type == 'expense').fold<double>(0, (s, t) => s + _convert(t));
    final net = totalIncome - totalExpenses;
    final daysInPeriod = period.inDays > 365 ? 365 : period.inDays;
    final double dailyAvg = daysInPeriod > 0 ? totalExpenses / daysInPeriod : 0.0;

    final expenseByCategory = <String, double>{};
    for (final t in filtered.where((t) => t.type == 'expense')) {
      expenseByCategory[t.category] = (expenseByCategory[t.category] ?? 0) + _convert(t);
    }
    final sortedCategories = expenseByCategory.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    final savingsRate = totalIncome > 0 ? ((totalIncome - totalExpenses) / totalIncome * 100).clamp(0.0, 100.0) : 0.0;

    final dailyData = _buildDailyData(filtered, now);

    return state.isLoading
        ? Center(child: DotsLoader())
        : state.transactions.isEmpty
            ? _EmptyState(l10n: l10n)
            : RefreshIndicator(
                onRefresh: () => ref.read(personalFinanceProvider.notifier).load(),
                color: AppColors.primary,
                backgroundColor: AppColors.surface,
                child: ListView(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 100),
                  children: [
                    _HeroAnalyticsHeader(period: periodLabel, l10n: l10n),
                    SizedBox(height: 14),
                    _PeriodChips(selected: _periodIndex, onChanged: (i) => setState(() => _periodIndex = i), l10n: l10n),
                    SizedBox(height: 14),
                    _SummaryCards(income: totalIncome, expense: totalExpenses, net: net, dailyAvg: dailyAvg, l10n: l10n),
                    SizedBox(height: 14),
                    _SavingsBadge(savingsRate: savingsRate, l10n: l10n),
                    SizedBox(height: 14),
                    if (sortedCategories.isNotEmpty) ...[
                      _SectionHeader(icon: TwoToneIcons.pieChart, title: l10n.translate('categoryBreakdown')),
                      SizedBox(height: 8),
                      AppPieChart(data: sortedCategories.take(6).toList(), height: 240),
                      SizedBox(height: 14),
                    ],
                    if (sortedCategories.isNotEmpty) ...[
                      _SectionHeader(icon: TwoToneIcons.barChart, title: l10n.translate('topCategories')),
                      SizedBox(height: 8),
                      HorizontalBarChart(data: sortedCategories.take(6).toList()),
                      SizedBox(height: 14),
                    ],
                    if (dailyData.labels.isNotEmpty) ...[
                      _SectionHeader(icon: TwoToneIcons.trendingUp, title: l10n.translate('spendingTrend')),
                      SizedBox(height: 8),
                      AppLineChart(labels: dailyData.labels, data: dailyData.values, height: 200),
                      SizedBox(height: 14),
                    ],
                    SizedBox(height: 12),
                    Container(
                      padding: EdgeInsets.all(12),
                      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border)),
                      child: Row(children: [
                        TwoToneIcon(data: TwoToneIcons.info, outlineColor: AppColors.textSecondary, size: 18),
                        SizedBox(width: 8),
                        Expanded(child: Text(l10n.translate('dataDisplayedForPeriod', params: {'period': periodLabel}), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textSecondary))),
                      ]),
                    ),
                    SizedBox(height: 32),
                  ],
                ),
              );
  }

  _DailyData _buildDailyData(List transactions, DateTime now) {
    final engine = ref.read(currencyEngineProvider);
    final walletCurrency = ref.read(personalFinanceProvider).walletCurrency;
    final daily = <String, double>{};
    for (final t in transactions) {
      if (t.type != 'expense' || t.date == null) continue;
      final key = DateFormat('MM/dd').format(t.date!);
      double amt = t.amount;
      if (t.currency != walletCurrency) {
        final converted = engine.convert(t.amount, t.currency, walletCurrency);
        if (converted != 0) amt = converted;
      }
      daily[key] = (daily[key] ?? 0) + amt;
    }
    final entries = daily.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    final last14 = entries.take(14).toList();
    return _DailyData(labels: last14.map((e) => e.key).toList(), values: last14.map((e) => e.value).toList());
  }

  void _exportReport() {
    final l10n = AppLocalizations.of(context);
    final st = ref.read(personalFinanceProvider);
    final now = DateTime.now();
    final period = _periodDuration;
    final engine = ref.read(currencyEngineProvider);
    final walletCurrency = st.walletCurrency;
    double _convert(dynamic t) {
      if (t.currency == walletCurrency) return t.amount;
      final converted = engine.convert(t.amount, t.currency, walletCurrency);
      return converted != 0 ? converted : t.amount;
    }
    final filtered = st.transactions.where((t) {
      if (t.date == null) return period.inDays > 365;
      return t.date!.isAfter(now.subtract(period));
    }).toList();
    final totalIncome = filtered.where((t) => t.type == 'income').fold<double>(0, (s, t) => s + _convert(t));
    final totalExpenses = filtered.where((t) => t.type == 'expense').fold<double>(0, (s, t) => s + _convert(t));
    final daysInPeriod = period.inDays > 365 ? 365 : period.inDays;
    final double dailyAvg = daysInPeriod > 0 ? totalExpenses / daysInPeriod : 0.0;
    final savingsRate = totalIncome > 0 ? ((totalIncome - totalExpenses) / totalIncome * 100).clamp(0.0, 100.0) : 0.0;
    final expenseByCategory = <String, double>{};
    for (final t in filtered.where((t) => t.type == 'expense')) {
      expenseByCategory[t.category] = (expenseByCategory[t.category] ?? 0) + _convert(t);
    }
    final categoryTotals = expenseByCategory.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final preset = ref.read(personalReceiptDesignProvider.notifier).getPreset('analytics');
    ReceiptModal.show(context, ReceiptData(
      title: l10n.translate('analyticsReport'),
      amount: totalIncome - totalExpenses,
      currencySymbol: currencySymbol(walletCurrency),
      dateTime: DateFormat('yyyy/MM/dd HH:mm').format(DateTime.now()),
      senderName: l10n.translate('incomeLabel'),
      senderAccount: '${fmtNum(totalIncome)} ${currencySymbol(walletCurrency)}',
      receiverName: l10n.translate('expenseLabel'),
      receiverAccount: '${fmtNum(totalExpenses)} ${currencySymbol(walletCurrency)}',
      details: [
        ReceiptDetail(label: l10n.translate('savingsRate'), value: '$savingsRate%'),
        ReceiptDetail(label: l10n.translate('averageDailyExpense'), value: '${fmtNum(dailyAvg)} ${currencySymbol(walletCurrency)}'),
        ...categoryTotals.take(6).map((e) => ReceiptDetail(label: e.key, value: '${fmtNum(e.value)} ${currencySymbol(walletCurrency)}')),
      ],
    ), preset: preset);
  }
}

class _DailyData {
  final List<String> labels;
  final List<double> values;
  _DailyData({required this.labels, required this.values});
}

// ════════════════════════════════════════════════════════════
//  HERO HEADER
// ════════════════════════════════════════════════════════════
class _HeroAnalyticsHeader extends StatelessWidget {
  final String period;
  final AppLocalizations l10n;
  const _HeroAnalyticsHeader({required this.period, required this.l10n});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment(-1, -1), end: Alignment(1.5, 1.5), colors: [Color(0xFFC01838), AppColors.primary, Color(0xFF7A1020)]),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(color: AppColors.primary.withAlpha(80), blurRadius: 24, offset: Offset(0, 10))],
      ),
      child: Stack(children: [
        Positioned(top: -20, right: -15, child: Container(width: 80, height: 80, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withAlpha(12)))),
        Positioned(bottom: -30, left: -10, child: Container(width: 100, height: 100, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withAlpha(8)))),
        Row(children: [
          AppIconBadge(icon: TwoToneIcons.barChart.outline, size: 44, iconSize: 22, backgroundColor: Colors.white.withAlpha(20), borderColor: Colors.white.withAlpha(30)),
          SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l10n.translate('analyticsTitle'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 18), fontWeight: FontWeight.w700, color: Colors.white)),
            SizedBox(height: 2),
            Text(period, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: Colors.white.withAlpha(130))),
          ])),
        ]),
      ]),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  PERIOD CHIPS
// ════════════════════════════════════════════════════════════
class _PeriodChips extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onChanged;
  final AppLocalizations l10n;
  const _PeriodChips({required this.selected, required this.onChanged, required this.l10n});

  @override
  Widget build(BuildContext context) {
    final periods = [l10n.translate('period7Days'), l10n.translate('period30Days'), l10n.translate('period3Months'), l10n.translate('all')];
    return Row(children: periods.asMap().entries.map((e) {
      final active = selected == e.key;
      return Expanded(
        child: Padding(
          padding: EdgeInsetsDirectional.only(end: 6),
          child: GestureDetector(
            onTap: () => onChanged(e.key),
            child: Container(
              padding: EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: active ? AppColors.primary : AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: !active ? Border.all(color: AppColors.border) : null,
              ),
              child: Text(e.value, textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.w700, color: active ? Colors.white : AppColors.textSecondary)),
            ),
          ),
        ),
      );
    }).toList());
  }
}

// ════════════════════════════════════════════════════════════
//  SUMMARY CARDS
// ════════════════════════════════════════════════════════════
class _SummaryCards extends StatelessWidget {
  final double income;
  final double expense;
  final double net;
  final double dailyAvg;
  final AppLocalizations l10n;
  const _SummaryCards({required this.income, required this.expense, required this.net, required this.dailyAvg, required this.l10n});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Row(children: [
        _StatCard(label: l10n.translate('incomeLabel'), value: fmtNum(income), icon: TwoToneIcons.trendingUp, color: AppColors.success),
        SizedBox(width: 8),
        _StatCard(label: l10n.translate('expenseLabel'), value: fmtNum(expense), icon: TwoToneIcons.trendingUp, color: AppColors.danger),
      ]),
      SizedBox(height: 8),
      Row(children: [
        _StatCard(label: l10n.translate('net'), value: fmtNum(net), icon: TwoToneIcons.wallet, color: net >= 0 ? AppColors.success : AppColors.danger),
        SizedBox(width: 8),
        _StatCard(label: l10n.translate('averageDaily'), value: fmtNum(dailyAvg), icon: TwoToneIcons.calendar, color: AppColors.info),
      ]),
    ]);
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final TwoToneIconData icon;
  final Color color;
  const _StatCard({required this.label, required this.value, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
        child: Column(children: [
          Container(width: 32, height: 32, decoration: BoxDecoration(color: color.withAlpha(25), borderRadius: BorderRadius.circular(8)),
            child: TwoToneIcon(data: icon, size: 18, outlineColor: color)),
          SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value, maxLines: 1, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 18), fontWeight: FontWeight.w700, color: color)),
          ),
          SizedBox(height: 2),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.textSecondary)),
        ]),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  SAVINGS BADGE
// ════════════════════════════════════════════════════════════
class _SavingsBadge extends StatelessWidget {
  final double savingsRate;
  final AppLocalizations l10n;
  const _SavingsBadge({required this.savingsRate, required this.l10n});

  @override
  Widget build(BuildContext context) {
    String level;
    Color color;
    if (savingsRate > 50) { level = l10n.translate('excellent'); color = AppColors.gold; }
    else if (savingsRate > 30) { level = l10n.translate('veryGood'); color = AppColors.success; }
    else if (savingsRate > 10) { level = l10n.translate('good'); color = AppColors.info; }
    else { level = l10n.translate('needsImprovement'); color = AppColors.danger; }

    return Container(
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withAlpha(60))),
      child: Row(children: [
        Container(width: 40, height: 40, decoration: BoxDecoration(color: color.withAlpha(20), borderRadius: BorderRadius.circular(10)),
          child: TwoToneIcon(data: TwoToneIcons.crown, size: 22, outlineColor: color)),
        SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l10n.translate('savingsRateLabel', params: {'level': level}), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: color)),
          Text(l10n.translate('savingsRatePercent', params: {'percent': savingsRate.toStringAsFixed(1)}), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.textDisabled)),
        ])),
        AppDonutChart(value: savingsRate, max: 100, centerLabel: level, color: color, size: 56),
      ]),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  SECTION HEADER
// ════════════════════════════════════════════════════════════
class _SectionHeader extends StatelessWidget {
  final TwoToneIconData icon;
  final String title;
  const _SectionHeader({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      AppIconBadge(icon: icon.outline, size: 32, iconSize: 16, backgroundColor: AppColors.primary.withAlpha(20), borderColor: AppColors.primary.withAlpha(40)),
      SizedBox(width: 8),
      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
    ]);
  }
}

// ════════════════════════════════════════════════════════════
//  EXPORT BUTTON
// ════════════════════════════════════════════════════════════

class _EmptyState extends StatelessWidget {
  final AppLocalizations l10n;
  const _EmptyState({required this.l10n});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_outlined, size: 64, color: AppColors.textDisabled),
          SizedBox(height: 16),
          Text(l10n.translate('noTransactions'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}
