import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/date_formatter.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../../../../shared/widgets/app_icon_badge.dart';
import '../../../../shared/widgets/charts/app_charts.dart';
import '../../../../shared/widgets/receipt/receipt.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import '../providers/receipt_design_provider.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../../core/localization/app_localizations.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

final _dateFmt = DateFormat('yyyy/MM/dd');
final _dayFmt = DateFormat('EEEE');
final _monthFmt = DateFormat('MMMM yyyy');

class PersonalReportsPage extends ConsumerStatefulWidget {
  const PersonalReportsPage({super.key});
  @override
  ConsumerState<PersonalReportsPage> createState() => _PersonalReportsPageState();
}

class _PersonalReportsPageState extends ConsumerState<PersonalReportsPage> {
  String _tab = 'month';
  DateTime _from = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _to = DateTime.now();
  void _load() {
    ref.read(personalFinanceProvider.notifier).load();
  }

  @override
  void initState() { super.initState(); WidgetsBinding.instance.addPostFrameCallback((_) => _load()); }

  (List<PersonalTransaction>, int) _filterTransactions(List<PersonalTransaction> txs) {
    switch (_tab) {
      case 'day':
        final start = DateTime(_to.year, _to.month, _to.day);
        final end = start.add(const Duration(days: 1));
        return (txs.where((t) => t.date != null && t.date!.isAfter(start) && t.date!.isBefore(end)).toList(), 1);
      case 'week':
        final start = _to.subtract(const Duration(days: 7));
        return (txs.where((t) => t.date != null && t.date!.isAfter(start)).toList(), 7);
      case 'month':
        final start = DateTime(_to.year, _to.month, 1);
        final end = DateTime(_to.year, _to.month + 1, 1);
        final monthDays = end.difference(start).inDays;
        return (txs.where((t) => t.date != null && t.date!.isAfter(start) && t.date!.isBefore(end)).toList(), monthDays);
      case 'custom':
        final start = _from;
        final end = _to.add(const Duration(days: 1));
        final diff = end.difference(start).inDays.clamp(1, 365);
        return (txs.where((t) => t.date != null && t.date!.isAfter(start) && t.date!.isBefore(end)).toList(), diff);
      default:
        return (<PersonalTransaction>[], 0);
    }
  }

  String _periodLabel() {
    final l10n = AppLocalizations.of(context);
    switch (_tab) {
      case 'day': return '${_dayFmt.format(_to)} - ${_dateFmt.format(_to)}';
      case 'week': return l10n.translate('last7Days');
      case 'month': return _monthFmt.format(_to);
      case 'custom': return '${_dateFmt.format(_from)} - ${_dateFmt.format(_to)}';
      default: return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final st = ref.watch(personalFinanceProvider);
    final user = ref.watch(authProvider).user;
    final txs = st.transactions;
    final (filtered, daysInPeriod) = _filterTransactions(txs);
    final engine = ref.read(currencyEngineProvider);
    final walletCurrency = st.walletCurrency;
    double _convert(PersonalTransaction t) {
      if (t.currency == walletCurrency) return t.amount;
      final converted = engine.convert(t.amount, t.currency, walletCurrency);
      return converted != 0 ? converted : t.amount;
    }
    final income = filtered.where((t) => t.type == 'income').fold(0.0, (s, t) => s + _convert(t));
    final expense = filtered.where((t) => t.type == 'expense').fold(0.0, (s, t) => s + _convert(t));
    final net = income - expense;
    final dailyAvg = daysInPeriod > 0 ? expense / daysInPeriod : 0.0;
    final savingsRate = income > 0 ? ((income - expense) / income * 100).clamp(0.0, 100.0) : 0.0;

    final cats = <String, double>{};
    for (final t in filtered.where((t) => t.type == 'expense')) cats[t.category] = (cats[t.category] ?? 0) + _convert(t);
    final sortedCats = cats.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    final monthlyData = _buildMonthlyData(filtered, l10n);
    final dailyTrend = _buildDailyTrend(filtered);

    return st.isLoading
        ? Center(child: DotsLoader())
        : FyonaRefresh(
            onRefresh: () async => _load(),
            color: AppColors.primary,
            backgroundColor: AppColors.surface,
            child: ListView(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 100),
              children: [
                _HeroReportHeader(
                  name: user?.fullName ?? '',
                  period: _periodLabel(),
                  income: income,
                  expense: expense,
                  net: net,
                ),
                SizedBox(height: 14),
                _PeriodTabs(
                  selected: _tab,
                  onChanged: (v) => setState(() => _tab = v),
                ),
                if (_tab == 'custom') ...[SizedBox(height: 8), _CustomDatePicker(from: _from, to: _to, onFromChanged: (d) => setState(() => _from = d), onToChanged: (d) => setState(() => _to = d))],
                SizedBox(height: 14),
                _SummaryCards(income: income, expense: expense, net: net, dailyAvg: dailyAvg),
                SizedBox(height: 14),
                _SavingsBadge(savingsRate: savingsRate, totalExpense: expense),
                SizedBox(height: 14),
                if (sortedCats.isNotEmpty) ...[
                  _SectionHeader(icon: TwoToneIcons.pieChart, title: l10n.translate('expenseBreakdown')),
                  SizedBox(height: 8),
                  AppPieChart(
                    data: sortedCats.take(6).toList(),
                    height: 240,
                  ),
                  SizedBox(height: 14),
                ],
                if (monthlyData.labels.isNotEmpty) ...[
                  _SectionHeader(icon: TwoToneIcons.barChart, title: l10n.translate('monthlyAnalysis')),
                  SizedBox(height: 8),
                  GroupedBarChart(
                    labels: monthlyData.labels,
                    incomeData: monthlyData.income,
                    expenseData: monthlyData.expense,
                  ),
                  SizedBox(height: 14),
                ],
                if (dailyTrend.labels.length >= 2) ...[
                  _SectionHeader(icon: TwoToneIcons.trendingUp, title: l10n.translate('dailyExpenseTrend')),
                  SizedBox(height: 8),
                  AppLineChart(
                    labels: dailyTrend.labels,
                    data: dailyTrend.values,
                    height: 200,
                    label: l10n.translate('dailyExpenses'),
                  ),
                  SizedBox(height: 14),
                ],
                SizedBox(height: 32),
              ],
            ),
          );
  }

  _MonthlyData _buildMonthlyData(List<PersonalTransaction> txs, AppLocalizations l10n) {
    final engine = ref.read(currencyEngineProvider);
    final walletCurrency = ref.read(personalFinanceProvider).walletCurrency;
    final months = <String, List<double>>{};
    final now = DateTime.now();
    for (int i = 5; i >= 0; i--) {
      final m = now.month - i;
      final y = now.year + (m <= 0 ? (m ~/ 12 - 1) : 0);
      final adjM = ((m % 12) + 12) % 12;
      final ym = '${adjM == 0 ? y - 1 : y}-${(adjM == 0 ? 12 : adjM).toString().padLeft(2, '0')}';
      months[ym] = [0.0, 0.0];
    }
    for (final t in txs) {
      if (t.date == null) continue;
      final k = '${t.date!.year}-${t.date!.month.toString().padLeft(2, '0')}';
      if (!months.containsKey(k)) continue;
      double amt = t.amount;
      if (t.currency != walletCurrency) {
        final converted = engine.convert(t.amount, t.currency, walletCurrency);
        if (converted != 0) amt = converted;
      }
      t.type == 'income' ? months[k]![0] += amt : months[k]![1] += amt;
    }
    final labels = months.keys.map((k) {
      final parts = k.split('-');
      final monthNum = int.parse(parts[1]);
      return l10n.translate('month$monthNum');
    }).toList();
    return _MonthlyData(
      labels: labels,
      income: months.values.map((v) => v[0]).toList(),
      expense: months.values.map((v) => v[1]).toList(),
    );
  }

  _DailyTrendData _buildDailyTrend(List<PersonalTransaction> txs) {
    final engine = ref.read(currencyEngineProvider);
    final walletCurrency = ref.read(personalFinanceProvider).walletCurrency;
    final daily = <String, double>{};
    for (final t in txs.where((t) => t.type == 'expense')) {
      if (t.date == null) continue;
      final key = _dateFmt.format(t.date!);
      double amt = t.amount;
      if (t.currency != walletCurrency) {
        final converted = engine.convert(t.amount, t.currency, walletCurrency);
        if (converted != 0) amt = converted;
      }
      daily[key] = (daily[key] ?? 0) + amt;
    }
    final sorted = daily.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    final last14 = sorted.take(14).toList();
    return _DailyTrendData(
      labels: last14.map((e) => e.key.substring(5)).toList(),
      values: last14.map((e) => e.value).toList(),
    );
  }

  void _exportReport() {
    final l10n = AppLocalizations.of(context);
    final st = ref.read(personalFinanceProvider);
    final txs = st.transactions;
    final engine = ref.read(currencyEngineProvider);
    final walletCurrency = st.walletCurrency;
    double _convert(PersonalTransaction t) {
      if (t.currency == walletCurrency) return t.amount;
      final converted = engine.convert(t.amount, t.currency, walletCurrency);
      return converted != 0 ? converted : t.amount;
    }
    final (filtered, daysInPeriod) = _filterTransactions(txs);
    final income = filtered.where((t) => t.type == 'income').fold(0.0, (s, t) => s + _convert(t));
    final expense = filtered.where((t) => t.type == 'expense').fold(0.0, (s, t) => s + _convert(t));
    final net = income - expense;
    final dailyAvg = daysInPeriod > 0 ? expense / daysInPeriod : 0.0;
    final preset = ref.read(personalReceiptDesignProvider.notifier).getPreset('report');
    ReceiptModal.show(context, ReceiptData(
      title: l10n.translate('personalReportTitle'),
      amount: net,
      currencySymbol: currencySymbol(walletCurrency),
      dateTime: DateFormat('yyyy/MM/dd HH:mm').format(DateTime.now()),
      senderName: l10n.translate('incomeLabel'),
      senderAccount: '${fmtNum(income)} ${currencySymbol(walletCurrency)}',
      receiverName: l10n.translate('expenseLabel'),
      receiverAccount: '${fmtNum(expense)} ${currencySymbol(walletCurrency)}',
      details: [
        ReceiptDetail(label: l10n.translate('period'), value: _periodLabel()),
        ReceiptDetail(label: l10n.translate('averageDailyExpense'), value: '${fmtNum(dailyAvg)} ${l10n.translate('sarPerDay')}'),
      ],
    ), preset: preset);
  }
}

class _MonthlyData {
  final List<String> labels;
  final List<double> income;
  final List<double> expense;
  _MonthlyData({required this.labels, required this.income, required this.expense});
}

class _DailyTrendData {
  final List<String> labels;
  final List<double> values;
  _DailyTrendData({required this.labels, required this.values});
}


// ------------------------------------------------------------
//  HERO REPORT HEADER
// ------------------------------------------------------------
class _HeroReportHeader extends StatelessWidget {
  final String name;
  final String period;
  final double income;
  final double expense;
  final double net;
  const _HeroReportHeader({required this.name, required this.period, required this.income, required this.expense, required this.net});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            AppIconBadge(icon: TwoToneIcons.chart.outline, size: 40, iconSize: 20, backgroundColor: Colors.white.withAlpha(20), borderColor: Colors.white.withAlpha(30)),
            SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l10n.translate('financialSummary'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w700, color: Colors.white)),
              Text(period, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: Colors.white.withAlpha(130))),
            ])),
          ]),
          SizedBox(height: 20),
          Row(children: [
            _HeroMiniStat(label: l10n.translate('income'), value: fmtNum(income), color: Color(0xFF81C784)),
            SizedBox(width: 16),
            _HeroMiniStat(label: l10n.translate('expense'), value: fmtNum(expense), color: Color(0xFFE57373)),
            SizedBox(width: 16),
            _HeroMiniStat(label: l10n.translate('net'), value: fmtNum(net), color: Colors.white),
          ]),
        ]),
      ]),
    );
  }
}

class _HeroMiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _HeroMiniStat({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: Colors.white.withAlpha(130))),
        FittedBox(fit: BoxFit.scaleDown, child: Text(value, maxLines: 1, style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w700, color: color))),
      ]),
    );
  }
}

// ------------------------------------------------------------
//  PERIOD TABS
// ------------------------------------------------------------
class _PeriodTabs extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onChanged;
  const _PeriodTabs({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tabs = [
      {'key': 'day', 'label': l10n.translate('day')},
      {'key': 'week', 'label': l10n.translate('week')},
      {'key': 'month', 'label': l10n.translate('month')},
      {'key': 'custom', 'label': l10n.translate('custom')},
    ];
    return Row(children: tabs.map((t) {
      final active = selected == t['key'];
      return Expanded(
        child: Padding(
          padding: EdgeInsetsDirectional.only(end: 6),
          child: GestureDetector(
            onTap: () => onChanged(t['key'] as String),
            child: Container(
              padding: EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: active ? AppColors.primary : AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: !active ? Border.all(color: AppColors.border) : null,
              ),
              child: Text(t['label'] as String, textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.w700, color: active ? Colors.white : AppColors.textSecondary)),
            ),
          ),
        ),
      );
    }).toList());
  }
}

// ------------------------------------------------------------
//  CUSTOM DATE PICKER
// ------------------------------------------------------------
class _CustomDatePicker extends StatelessWidget {
  final DateTime from;
  final DateTime to;
  final ValueChanged<DateTime> onFromChanged;
  final ValueChanged<DateTime> onToChanged;
  const _CustomDatePicker({required this.from, required this.to, required this.onFromChanged, required this.onToChanged});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      _dateField(context, from, onFromChanged),
      Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Text('-', style: TextStyle(color: AppColors.textSecondary))),
      _dateField(context, to, onToChanged),
    ]);
  }

  Widget _dateField(BuildContext context, DateTime d, ValueChanged<DateTime> onChange) {
    return Expanded(
      child: GestureDetector(
        onTap: () async {
          final p = await showDatePicker(context: context, firstDate: DateTime(2020), lastDate: DateTime(2030), initialDate: d, locale: Localizations.localeOf(context));
          if (p != null) onChange(p);
        },
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(8)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            TwoToneIcon(data: TwoToneIcons.calendar, size: 16, outlineColor: AppColors.textSecondary),
            SizedBox(width: 4),
            Text(_dateFmt.format(d), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textPrimary)),
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------
//  SUMMARY CARDS
// ------------------------------------------------------------
class _SummaryCards extends StatelessWidget {
  final double income;
  final double expense;
  final double net;
  final double dailyAvg;
  const _SummaryCards({required this.income, required this.expense, required this.net, required this.dailyAvg});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(children: [
      Row(children: [
        _StatCard(label: l10n.translate('revenue'), value: fmtNum(income), icon: TwoToneIcons.trendingUp, color: AppColors.success),
        SizedBox(width: 8),
        _StatCard(label: l10n.translate('expenses'), value: fmtNum(expense), icon: TwoToneIcons.trendingUp, color: AppColors.danger),
      ]),
      SizedBox(height: 8),
      Row(children: [
        _StatCard(label: l10n.translate('netProfit'), value: fmtNum(net), icon: TwoToneIcons.wallet, color: net >= 0 ? AppColors.success : AppColors.danger),
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

// ------------------------------------------------------------
//  SAVINGS BADGE
// ------------------------------------------------------------
class _SavingsBadge extends StatelessWidget {
  final double savingsRate;
  final double totalExpense;
  const _SavingsBadge({required this.savingsRate, required this.totalExpense});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String level;
    Color color;
    if (savingsRate > 50) { level = l10n.translate('excellent'); color = AppColors.gold; }
    else if (savingsRate > 30) { level = l10n.translate('good'); color = AppColors.success; }
    else if (savingsRate > 10) { level = l10n.translate('fair'); color = AppColors.info; }
    else { level = l10n.translate('poor'); color = AppColors.textSecondary; }

    return Container(
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withAlpha(60))),
      child: Row(children: [
        Container(width: 40, height: 40, decoration: BoxDecoration(color: color.withAlpha(20), borderRadius: BorderRadius.circular(10)),
          child: TwoToneIcon(data: TwoToneIcons.crown, size: 22, outlineColor: color)),
        SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l10n.translate('savingsLevel', params: {'level': level}), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: color)),
          Text(l10n.translate('savingsPercentOfExpenses', params: {'percent': savingsRate.toStringAsFixed(0), 'amount': fmtNum(totalExpense)}), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.textDisabled)),
        ])),
        AppDonutChart(value: savingsRate, max: 100, centerLabel: level, color: color, size: 56),
      ]),
    );
  }
}

// ------------------------------------------------------------
//  SECTION HEADER
// ------------------------------------------------------------
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


