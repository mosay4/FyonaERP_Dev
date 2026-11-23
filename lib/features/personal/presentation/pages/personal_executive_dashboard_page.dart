import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../../../../core/utils/currency_formatter.dart' show fmtNum;
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/dots_loader.dart';

class PersonalExecutiveDashboardPage extends ConsumerStatefulWidget {
  const PersonalExecutiveDashboardPage({super.key});
  @override
  ConsumerState<PersonalExecutiveDashboardPage> createState() => _PersonalExecutiveDashboardPageState();
}

class _PersonalExecutiveDashboardPageState extends ConsumerState<PersonalExecutiveDashboardPage> {
  int _periodDays = 30;
  static const List<(String, int)> _periodOpts = [('???', 1), ('?????', 7), ('???', 30), ('???', 365)];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { ref.read(personalFinanceProvider.notifier).load(); });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(personalFinanceProvider);
    final user = ref.watch(authProvider).user;
    final now = DateTime.now();
    final since = now.subtract(Duration(days: _periodDays));
    final txs = state.transactions.where((t) => t.date != null && t.date!.isAfter(since)).toList();
    final engine = ref.read(currencyEngineProvider);
    final walletCurrency = state.walletCurrency;
    double _convert(PersonalTransaction t) {
      if (t.currency == walletCurrency) return t.amount;
      final converted = engine.convert(t.amount, t.currency, walletCurrency);
      return converted != 0 ? converted : t.amount;
    }
    final income = txs.where((t) => t.type == 'income').fold<double>(0, (s, t) => s + _convert(t));
    final expenses = txs.where((t) => t.type == 'expense').fold<double>(0, (s, t) => s + _convert(t));
    final net = income - expenses;
    final savingsRate = income > 0 ? ((income - expenses) / income * 100) : 0.0;
    final avgProgress = state.savingsGoals.isEmpty ? 0.0 : state.savingsGoals.fold<double>(0, (s, g) => s + g.progress) / state.savingsGoals.length * 100;
    final avgSpending = _periodDays > 0 && expenses > 0 ? fmtNum(expenses / _periodDays) : '0';
    final topCategory = state.spendingAnalytics.entries.isNotEmpty
      ? state.spendingAnalytics.entries.reduce((a, b) => a.value > b.value ? a : b).key
      : '�';

    final previousSince = since.subtract(Duration(days: _periodDays));
    final prevTxs = state.transactions.where((t) => t.date != null && t.date!.isAfter(previousSince) && t.date!.isBefore(since)).toList();
    final prevIncome = prevTxs.where((t) => t.type == 'income').fold<double>(0, (s, t) => s + _convert(t));
    final prevExpenses = prevTxs.where((t) => t.type == 'expense').fold<double>(0, (s, t) => s + _convert(t));
    final prevNet = prevIncome - prevExpenses;
    final incomeChange = prevIncome > 0 ? ((income - prevIncome) / prevIncome * 100) : (income > 0 ? 100.0 : 0.0);
    final expenseChange = prevExpenses > 0 ? ((expenses - prevExpenses) / prevExpenses * 100) : (expenses > 0 ? 100.0 : 0.0);
    final netChange = prevNet != 0 ? ((net - prevNet) / prevNet.abs() * 100) : (net > 0 ? 100.0 : 0.0);

    final balanceHistory = _buildBalanceHistory(state, since, now);

    return state.isLoading
        ? const Center(child: DotsLoader())
        : ListView(
          padding: EdgeInsets.symmetric(horizontal: R.spacing(context, 14), vertical: R.spacing(context, 6)),
          children: [
            _buildProfileHeader(user),
            SizedBox(height: R.spacing(context, AppSpacing.sm)),
            _buildFilterBar(),
            SizedBox(height: R.spacing(context, AppSpacing.md)),
            _buildKpiCards(state.walletTotalBalance, income, expenses, net, savingsRate, avgProgress, avgSpending, topCategory, incomeChange, expenseChange, netChange),
            SizedBox(height: R.spacing(context, AppSpacing.lg)),
            _buildCharts(balanceHistory, txs),
            SizedBox(height: R.spacing(context, AppSpacing.lg)),
            _buildSummarySection(income, expenses, net, savingsRate, txs),
            SizedBox(height: R.spacing(context, AppSpacing.lg)),
            SizedBox(height: R.spacing(context, AppSpacing.xl)),
          ],
        );
  }

  List<double> _buildBalanceHistory(PersonalFinanceState state, DateTime since, DateTime now) {
    final totalBalance = state.walletTotalBalance;
    final engine = ref.read(currencyEngineProvider);
    final walletCurrency = state.walletCurrency;
    double _convert(PersonalTransaction t) {
      if (t.currency == walletCurrency) return t.amount;
      final converted = engine.convert(t.amount, t.currency, walletCurrency);
      return converted != 0 ? converted : t.amount;
    }
    int dayCount = now.difference(since).inDays + 1;
    if (dayCount > 14) dayCount = 14;
    final txs = state.transactions.where((t) => t.date != null).toList();
    txs.sort((a, b) => a.date!.compareTo(b.date!));
    double runningBalance = totalBalance;
    for (int i = txs.length - 1; i >= 0; i--) {
      final t = txs[i];
      if (t.date!.isBefore(since)) break;
      final amt = _convert(t);
      if (t.type == 'income') {
        runningBalance -= amt;
      } else {
        runningBalance += amt;
      }
    }
    final result = <double>[];
    final step = (dayCount / 14).ceil().clamp(1, dayCount);
    for (int i = 0; i < dayCount; i += step) {
      final day = since.add(Duration(days: i));
      final dayTxs = txs.where((t) => t.date!.year == day.year && t.date!.month == day.month && t.date!.day == day.day).toList();
      for (final t in dayTxs) {
        final amt = _convert(t);
        if (t.type == 'income') runningBalance += amt;
        else runningBalance -= amt;
      }
      result.add(runningBalance);
    }
    if (result.isEmpty) result.add(totalBalance);
    return result;
  }

  List<Map<String, dynamic>> _buildMonthlyData(List<PersonalTransaction> txs, int months) {
    final engine = ref.read(currencyEngineProvider);
    final walletCurrency = ref.read(personalFinanceProvider).walletCurrency;
    double _convert(PersonalTransaction t) {
      if (t.currency == walletCurrency) return t.amount;
      final converted = engine.convert(t.amount, t.currency, walletCurrency);
      return converted != 0 ? converted : t.amount;
    }
    final now = DateTime.now();
    final monthly = <Map<String, dynamic>>[];
    final monthNames = ['?????', '??????', '????', '?????', '????', '?????', '?????', '?????', '??????', '??????', '??????', '??????'];
    for (int i = months - 1; i >= 0; i--) {
      final m = DateTime(now.year, now.month - i, 1);
      final monthTxs = txs.where((t) => t.date != null && t.date!.month == m.month && t.date!.year == m.year).toList();
      final inc = monthTxs.where((t) => t.type == 'income').fold<double>(0, (s, t) => s + _convert(t));
      final exp = monthTxs.where((t) => t.type == 'expense').fold<double>(0, (s, t) => s + _convert(t));
      monthly.add({'month': monthNames[m.month - 1], 'income': inc, 'expense': exp});
    }
    return monthly;
  }

  Widget _buildProfileHeader(dynamic user) {
    final name = user?.fullName ?? user?.username ?? '??????';
    return Container(
      padding: EdgeInsets.all(R.spacing(context, 16)),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(R.radiusValue(context, 12)),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        CircleAvatar(
          radius: 26,
          backgroundColor: AppColors.primary,
          child: Text(name.toString().substring(0, 1).toUpperCase(), style: TextStyle(fontFamily: 'Cairo', color: Colors.white, fontSize: R.fontSize(context, 22), fontWeight: FontWeight.bold)),
        ),
        SizedBox(width: R.spacing(context, AppSpacing.md)),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name.toString(), style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'title_small'), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          Text('??????? ???????? � ??? $_periodDays ?????', style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'body_small'), color: AppColors.textDisabled)),
        ])),
      ]),
    );
  }

  Widget _buildFilterBar() {
    return Container(
      padding: EdgeInsets.symmetric(vertical: R.spacing(context, AppSpacing.sm)),
      child: Row(children: _periodOpts.map((p) {
        final active = p.$2 == _periodDays;
        return Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _periodDays = p.$2),
            child: Container(
              margin: EdgeInsets.symmetric(horizontal: R.spacing(context, 3)),
              padding: EdgeInsets.symmetric(vertical: R.spacing(context, 10)),
              decoration: BoxDecoration(
                color: active ? AppColors.primary : AppColors.surface,
                border: Border.all(color: active ? AppColors.primary : AppColors.border),
                borderRadius: BorderRadius.circular(AppRadius.badgeRadius),
              ),
              child: Text(p.$1, textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context),
                  fontWeight: active ? FontWeight.bold : FontWeight.normal,
                  color: active ? Colors.white : AppColors.textPrimary)),
            ),
          ),
        );
      }).toList(),),
    );
  }

  Widget _buildKpiCards(double balance, double income, double expenses, double net, double savingsRate, double avgProgress, String avgSpending, String topCategory, double incomeChange, double expenseChange, double netChange) {
    return Column(children: [
      Row(children: [
        Expanded(child: _kpiCard('??????', fmtNum(balance), 0, AppColors.info, TwoToneIcons.wallet, [])),
        SizedBox(width: R.gap(context)),
        Expanded(child: _kpiCard('?????', fmtNum(income), incomeChange, AppColors.success, TwoToneIcons.arrowDown, [])),
      ]),
      SizedBox(height: R.spacing(context, AppSpacing.sm)),
      Row(children: [
        Expanded(child: _kpiCard('?????????', fmtNum(expenses), expenseChange, AppColors.danger, TwoToneIcons.arrowUp, [])),
        SizedBox(width: R.gap(context)),
        Expanded(child: _kpiCard('????????', fmtNum(net), netChange, AppColors.success, TwoToneIcons.savingsGoal, [])),
      ]),
      SizedBox(height: R.spacing(context, AppSpacing.sm)),
      Row(children: [
        Expanded(child: _kpiCard('???? ???????', '${savingsRate.toStringAsFixed(1)}%', savingsRate >= 0 ? 5.0 : -5.0, AppColors.primary, TwoToneIcons.chart, [])),
        SizedBox(width: R.gap(context)),
        Expanded(child: _kpiCard('???????', '${avgProgress.toStringAsFixed(0)}%', 0, AppColors.warning, TwoToneIcons.barChart, [])),
      ]),
      SizedBox(height: R.spacing(context, AppSpacing.sm)),
      Row(children: [
        Expanded(child: _kpiCard('????? ???????', avgSpending, expenseChange, AppColors.info, TwoToneIcons.calendar, [])),
        SizedBox(width: R.gap(context)),
        Expanded(child: _kpiCard('???? ???', topCategory, 0, AppColors.danger, TwoToneIcons.sparkle, [])),
      ]),
    ]);
  }

  Widget _kpiCard(String label, String value, double change, Color color, TwoToneIconData icon, List<double> sparkData) {
    final isUp = change >= 0;
    return Container(
      padding: EdgeInsets.all(R.spacing(context, 12)),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(R.radiusValue(context, 12)),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 26, height: 26,
            decoration: BoxDecoration(color: color.withAlpha(32), borderRadius: BorderRadius.circular(6)),
            child: TwoToneIcon(data: icon, outlineColor: color, size: 14),
          ),
          SizedBox(width: R.spacing(context, 6)),
          Expanded(child: Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'caption'), color: AppColors.textSecondary))),
          if (change != 0) ...[
            TwoToneIcon(data: isUp ? TwoToneIcons.arrowUp : TwoToneIcons.arrowDown, size: 14, outlineColor: isUp ? AppColors.success : AppColors.danger),
            SizedBox(width: R.spacing(context, 2)),
            Text('${change.abs().toStringAsFixed(1)}%', style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'body_small'), fontWeight: FontWeight.bold,
              color: isUp ? AppColors.success : AppColors.danger)),
          ],
        ]),
        SizedBox(height: R.spacing(context, AppSpacing.xs)),
        Text(value, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'title_small'), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
        if (sparkData.isNotEmpty) ...[
          SizedBox(height: R.spacing(context, 2)),
          _buildSparkline(sparkData, color),
        ],
      ]),
    );
  }

  Widget _buildSparkline(List<double> data, Color color) {
    if (data.isEmpty) return const SizedBox.shrink();
    final mx = data.reduce((a, b) => a > b ? a : b);
    if (mx == 0) return const SizedBox(height: 26);
    return SizedBox(
      height: 26,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: data.map((v) => Container(
          width: 3,
          height: (v / mx) * 26,
          margin: EdgeInsets.symmetric(horizontal: R.spacing(context, 1)),
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(1)),
        )).toList(),
      ),
    );
  }

  Widget _buildCharts(List<double> balanceHistory, List<PersonalTransaction> txs) {
    final monthly = _buildMonthlyData(txs, 6);
    return Column(children: [
      Row(children: [
        Expanded(child: _balanceChart(balanceHistory)),
        SizedBox(width: R.spacing(context, 10)),
        Expanded(child: _incomeExpenseChart(monthly)),
      ]),
    ]);
  }

  Widget _balanceChart(List<double> data) {
    if (data.isEmpty) return const SizedBox.shrink();
    final mx = data.reduce((a, b) => a > b ? a : b);
    final mn = data.reduce((a, b) => a < b ? a : b);
    final rg = mx - mn;
    return Container(
      padding: EdgeInsets.all(R.spacing(context, 14)),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(R.radiusValue(context, 12)),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('???? ??????', style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          const Spacer(),
          Text(fmtNum(data.last), style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'title_small'), fontWeight: FontWeight.bold, color: AppColors.info)),
        ]),
        SizedBox(height: R.spacing(context, AppSpacing.xs)),
        Container(
          height: 120,
          padding: const EdgeInsets.only(top: 4),
          decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(R.radiusValue(context, 8))),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: data.map((v) => Container(
              width: 10,
              height: rg > 0 ? ((v - mn) / rg) * 120 : 3,
              decoration: BoxDecoration(color: AppColors.info, borderRadius: BorderRadius.vertical(top: Radius.circular(3))),
            )).toList(),
          ),
        ),
      ]),
    );
  }

  Widget _incomeExpenseChart(List<Map<String, dynamic>> monthly) {
    final mx = monthly.fold<double>(0.0, (s, m) {
      final i = m['income'] as double;
      final e = m['expense'] as double;
      return (i > s ? i : (e > s ? e : s));
    });
    return Container(
      padding: EdgeInsets.all(R.spacing(context, 14)),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(R.radiusValue(context, 12)),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('????? vs ?????????', style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
           Spacer(),
          Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: AppColors.success, shape: BoxShape.circle)),
            SizedBox(width: R.spacing(context, 2)),
            Text('???', style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'caption'), color: AppColors.textSecondary)),
            SizedBox(width: R.spacing(context, 6)),
            Container(width: 8, height: 8, decoration: BoxDecoration(color: AppColors.danger, shape: BoxShape.circle)),
            SizedBox(width: R.spacing(context, 2)),
            Text('???', style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'caption'), color: AppColors.textSecondary)),
          ]),
        ]),
        SizedBox(height: R.spacing(context, AppSpacing.sm)),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(monthly.length, (i) {
            final m = monthly[i];
            final inc = m['income'] as double;
            final exp = m['expense'] as double;
            final ip = mx > 0 ? inc / mx : 0.0;
            final ep = mx > 0 ? exp / mx : 0.0;
            return Expanded(
              child: Column(children: [
                Text(fmtNum(inc), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 7), color: AppColors.success)),
                Container(height: ip * 60, decoration: BoxDecoration(color: AppColors.success, borderRadius: BorderRadius.circular(3))),
                SizedBox(height: R.spacing(context, 3)),
                Container(height: ep * 60, decoration: BoxDecoration(color: AppColors.danger, borderRadius: BorderRadius.circular(3))),
                Text(fmtNum(exp), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 7), color: AppColors.danger)),
                Text(m['month'] as String, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 8), color: AppColors.textDisabled)),
              ]),
            );
          }),
        ),
      ]),
    );
  }

  Widget _buildSummarySection(double income, double expenses, double net, double savingsRate, List<PersonalTransaction> txs) {
    final expenseRate = income > 0 ? (expenses / income * 100) : 0.0;
    final bestMonth = _findBestMonth(txs);
    final worstMonth = _findWorstMonth(txs);
    return Container(
      padding: EdgeInsets.all(R.spacing(context, 14)),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(R.radiusValue(context, 12)),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('???? ??????', style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
        SizedBox(height: R.spacing(context, AppSpacing.sm)),
        Row(children: [
          Expanded(child: _indicatorsColumn(savingsRate, expenseRate)),
          SizedBox(width: R.spacing(context, 10)),
          Expanded(child: _bestWorstColumn(bestMonth, worstMonth)),
        ]),
      ]),
    );
  }

  MapEntry<String, double>? _findBestMonth(List<PersonalTransaction> txs) {
    final monthlyIncome = <String, double>{};
    final monthNames = ['?????', '??????', '????', '?????', '????', '?????', '?????', '?????', '??????', '??????', '??????', '??????'];
    for (final t in txs.where((t) => t.type == 'income' && t.date != null)) {
      final key = '${monthNames[t.date!.month - 1]} ${t.date!.year}';
      monthlyIncome[key] = (monthlyIncome[key] ?? 0) + t.amount;
    }
    if (monthlyIncome.isEmpty) return null;
    final sorted = monthlyIncome.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return sorted.first;
  }

  MapEntry<String, double>? _findWorstMonth(List<PersonalTransaction> txs) {
    final monthlyExpense = <String, double>{};
    final monthNames = ['?????', '??????', '????', '?????', '????', '?????', '?????', '?????', '??????', '??????', '??????', '??????'];
    for (final t in txs.where((t) => t.type == 'expense' && t.date != null)) {
      final key = '${monthNames[t.date!.month - 1]} ${t.date!.year}';
      monthlyExpense[key] = (monthlyExpense[key] ?? 0) + t.amount;
    }
    if (monthlyExpense.isEmpty) return null;
    final sorted = monthlyExpense.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return sorted.first;
  }

  Widget _indicatorsColumn(double savingsRate, double expenseRate) {
    return Container(
      padding: EdgeInsets.all(R.spacing(context, 14)),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(R.radiusValue(context, 12)),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('????????', style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
        SizedBox(height: R.spacing(context, AppSpacing.xs)),
        _statItem('???? ???????', '${savingsRate.toStringAsFixed(1)}%', AppColors.primary),
        Divider(height: 1, color: AppColors.border),
        _statItem('???? ?????????', '${expenseRate.toStringAsFixed(1)}%', AppColors.danger),
      ]),
    );
  }

  Widget _bestWorstColumn(MapEntry<String, double>? best, MapEntry<String, double>? worst) {
    return Container(
      padding: EdgeInsets.all(R.spacing(context, 14)),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(R.radiusValue(context, 12)),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('?????? ???????', style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
        SizedBox(height: R.spacing(context, AppSpacing.xs)),
        _statItem('???? ??? ???', best != null ? fmtNum(best.value) : '�', AppColors.success, best?.key ?? ''),
         Divider(height: 1, color: AppColors.border),
        _statItem('???? ??? ???????', worst != null ? fmtNum(worst.value) : '�', AppColors.danger, worst?.key ?? ''),
      ]),
    );
  }

  Widget _statItem(String label, String value, Color color, [String sub = '']) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'body_small'), color: AppColors.textSecondary)),
          if (sub.isNotEmpty)
            Text(sub, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 9), color: AppColors.textDisabled)),
        ])),
        Text(value, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), fontWeight: FontWeight.bold, color: color)),
      ]),
    );
  }

}

