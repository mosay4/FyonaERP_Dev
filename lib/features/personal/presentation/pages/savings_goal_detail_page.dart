import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart';
import 'package:fyona_flutter/core/utils/storage_util.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/shared/widgets/two_tone_icon.dart';
import 'package:fyona_flutter/shared/widgets/two_tone_icons.dart';
import 'package:fyona_flutter/shared/widgets/dots_loader.dart';
import 'package:fyona_flutter/shared/widgets/app_icon_badge.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import '../../../../shared/widgets/receipt/receipt.dart';
import '../providers/receipt_design_provider.dart';
import 'goal_report_pdf.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';
import '../../../../core/utils/time_format.dart';
import '../../../../shared/widgets/money_text.dart';

/// Shared goal artwork (see [GoalIcons]) so the list and detail pages match.
const _iconChoices = GoalIcons.choices;

class SavingsGoalDetailPage extends ConsumerStatefulWidget {
  final String goalId;
  const SavingsGoalDetailPage({super.key, required this.goalId});
  @override
  ConsumerState<SavingsGoalDetailPage> createState() => _SavingsGoalDetailPageState();
}

class _SavingsGoalDetailPageState extends ConsumerState<SavingsGoalDetailPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { ref.read(personalFinanceProvider.notifier).load(); });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final stateData = ref.watch(personalFinanceProvider);
    final goal = stateData.savingsGoals.where((g) => g.id == widget.goalId).firstOrNull;
    if (goal == null) {
      return Center(child: Text(l10n.translate('goalNotFound'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textDisabled, fontSize: R.fontSize(context, 16))),);
    }

    // Goal operations by real relation id (goal_id), never by name.
    final allTxs = stateData.transactions;
    final goalTxs = allTxs.where((t) => t.goalId == goal.id).toList();
    final engine = ref.read(currencyEngineProvider);
    final totalContributed = goal.currentAmount;
    final progress = goal.targetAmount > 0 ? (goal.currentAmount / goal.targetAmount).clamp(0.0, 1.0) : 0.0;
    final pct = (progress * 100).toInt();

    return stateData.isLoading
          ? Center(child: DotsLoader())
          : FyonaRefresh(
              color: AppColors.primary,
              backgroundColor: AppColors.surface,
              onRefresh: () async => await ref.read(personalFinanceProvider.notifier).load(),
              child: SingleChildScrollView(
                physics: AlwaysScrollableScrollPhysics(),
                child: Column(
                  children: [
                    _buildHeader(context, goal, progress, pct),
                    _buildReportsTab(context, goalTxs, goal),
                    SizedBox(height: 24),
                  ],
                ),
              ),
            );
  }

  Widget _buildHeader(BuildContext context, SavingsGoal goal, double progress, int pct) {
    final l10n = AppLocalizations.of(context);
    final icon = _iconChoices[goal.icon] ?? TwoToneIcons.savingsGoal;
    final completed = goal.currentAmount >= goal.targetAmount;
    String deadlineText = '';
    bool deadlineOverdue = false;
    if (goal.deadline != null) {
      final d = DateTime.tryParse(goal.deadline!);
      if (d != null) {
        final days = d.difference(DateTime.now()).inDays;
        if (days >= 0) {
          deadlineText = l10n.translate('daysRemaining', params: {'days': '$days'});
        } else {
          deadlineOverdue = true;
          deadlineText = l10n.translate('daysOverdue', params: {'days': '${days.abs()}'});
        }
      }
    }
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 12, 20, 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment(1, -0.5), end: Alignment(-1, 0.5), colors: completed
            ? [Color(0xFF2E7D32), Color(0xFF1B5E20)]
            : [Color(0xFFC01838), AppColors.primary, Color(0xFF7A1020)]),
        boxShadow: [BoxShadow(color: AppColors.primary.withAlpha(100), blurRadius: 24, offset: Offset(0, 8))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 36, height: 36,
              decoration: BoxDecoration(color: Colors.white.withAlpha(20), borderRadius: BorderRadius.circular(10)),
              child: Icon(Icons.arrow_forward_ios, color: Colors.white, size: 18),
            ),
          ),
          SizedBox(width: 12),
          AppIconBadge(icon: icon.outline, size: 40, iconSize: 20,
            backgroundColor: Colors.white.withAlpha(20), borderColor: Colors.white.withAlpha(30),
            accentColor: Colors.white),
          SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(goal.name, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 18), fontWeight: FontWeight.w700, color: Colors.white)),
            Row(children: [
              Text(goal.icon, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: Colors.white.withAlpha(130))),
              if (deadlineText.isNotEmpty) ...[
                Text(' \u2022 ', style: TextStyle(color: Colors.white.withAlpha(100), fontSize: R.fontSize(context, 11))),
                Text(deadlineText, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: deadlineOverdue ? Colors.white.withAlpha(180) : Colors.white.withAlpha(130))),
              ],
            ]),
          ])),
          if (completed)
            Container(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: Colors.white.withAlpha(25), borderRadius: BorderRadius.circular(8)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.check_circle, size: 14, color: Colors.white),
                SizedBox(width: 4),
                Text(l10n.translate('completed'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), fontWeight: FontWeight.w700, color: Colors.white)),
              ]),
            ),
        ]),
        SizedBox(height: 20),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: progress, backgroundColor: Colors.white.withAlpha(20), minHeight: 8,
            valueColor: AlwaysStoppedAnimation(completed ? Color(0xFF81C784) : Colors.white.withAlpha(200))),
        ),
        SizedBox(height: 8),
        Row(children: [
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                MoneyText(amount: fmtNum(goal.currentAmount), currency: currencySymbol(goal.currency), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: Colors.white)),
                Text(' / ${fmtNum(goal.targetAmount)} ${currencySymbol(goal.currency)}', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: Colors.white.withAlpha(150))),
              ]),
            ),
          ),
          Spacer(),
          Text('$pct%', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w700, color: Colors.white)),
        ]),
      ]),
    );
  }

  // ════════════════════════════════════════════════════════════
  //  TAB 1: REPORTS
  // ════════════════════════════════════════════════════════════
  Widget _buildReportsTab(BuildContext context, List<PersonalTransaction> goalTxs, SavingsGoal goal) {
    final l10n = AppLocalizations.of(context);
    final engine = ref.read(currencyEngineProvider);
    // Group by month for monthly contribution chart
    final monthlyData = <String, double>{};
    for (final t in goalTxs) {
      if (t.date == null) continue;
      final key = '${t.date!.year}/${t.date!.month.toString().padLeft(2, '0')}';
      monthlyData[key] = (monthlyData[key] ?? 0) + engine.convert(t.amount, t.currency, goal.currency);
    }
    final sortedMonths = monthlyData.entries.toList()..sort((a, b) => a.key.compareTo(b.key));

    final progress = goal.targetAmount > 0 ? (goal.currentAmount / goal.targetAmount).clamp(0.0, 1.0) : 0.0;
    final totalContributed = goal.currentAmount;
    final avgMonthly = goalTxsMonthsCount(goal) > 0 ? totalContributed / goalTxsMonthsCount(goal) : 0.0;

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(children: [
            Expanded(child: _exportBtn(l10n.translate('exportImage'), Icons.image, AppColors.primary, () => _exportGoalReceipt(goal, totalContributed, avgMonthly))),
            SizedBox(width: 10),
            Expanded(child: _exportBtn(l10n.translate('exportPdf'), Icons.picture_as_pdf, AppColors.danger, () => _exportGoalPdf(goal, totalContributed, avgMonthly))),
          ]),
        ),
        _SectionTitle(title: l10n.translate('goalProgress'), icon: TwoToneIcons.savingsGoal),
        SizedBox(height: 12),
        Container(
          padding: EdgeInsets.all(16),
          decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(12)),
          child: Column(children: [
            Row(children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: MoneyText(amount: fmtNum(goal.currentAmount), currency: currencySymbol(goal.currency), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 18), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                ),
              ),
              Spacer(),
              Text('${(progress * 100).toInt()}%', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w700, color: AppColors.primary)),
            ]),
            SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(value: progress, backgroundColor: AppColors.border, minHeight: 12,
                valueColor: AlwaysStoppedAnimation(AppColors.primary)),
            ),
            SizedBox(height: 8),
            MoneyText(amount: fmtNum(goal.targetAmount), currency: currencySymbol(goal.currency), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textSecondary)),
          ]),
        ),
        SizedBox(height: 16),

        if (sortedMonths.isNotEmpty) ...[
          _SectionTitle(title: l10n.translate('monthlyDeposits'), icon: TwoToneIcons.barChart),
          SizedBox(height: 12),
          SizedBox(height: 260, child: _MonthlyBarChart(data: sortedMonths)),
          SizedBox(height: 16),
        ],

        // Progress over time chart
        if (goalTxs.isNotEmpty) ...[
          _SectionTitle(title: l10n.translate('goalProgressOverTime'), icon: TwoToneIcons.chart),
          SizedBox(height: 12),
          SizedBox(height: 260, child: _ProgressLineChart(goal: goal, goalTxs: goalTxs, engine: engine)),
          SizedBox(height: 16),
        ],

        if (goalTxs.isEmpty)
          Center(child: Padding(
            padding: EdgeInsets.only(top: 60),
            child: Text(l10n.translate('noTransactionsForGoal'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textDisabled)),
          )),
      ],
    );
  }

  int goalTxsCount(SavingsGoal g) {
    final st = ref.read(personalFinanceProvider);
    return st.transactions.where((t) => t.goalId == g.id).length;
  }

  int goalTxsMonthsCount(SavingsGoal g) {
    final st = ref.read(personalFinanceProvider);
    final months = <String>{};
    for (final t in st.transactions.where((t) => t.goalId == g.id)) {
      if (t.date != null) months.add('${t.date!.month}-${t.date!.year}');
    }
    return months.length;
  }

  int _remainingMonths(SavingsGoal g) {
    if (g.deadline == null) return 0;
    final d = DateTime.tryParse(g.deadline!);
    if (d == null) return 0;
    final diff = d.difference(DateTime.now());
    if (diff.isNegative) return 0;
    return (diff.inDays / 30).ceil();
  }

  void _exportGoalReceipt(SavingsGoal goal, double totalContributed, double avgMonthly) {
    final l10n = AppLocalizations.of(context);
    final preset = ref.read(personalReceiptDesignProvider.notifier).getPreset('goal');
    final progress = goal.targetAmount > 0 ? (goal.currentAmount / goal.targetAmount * 100).toStringAsFixed(1) : '0.0';
    ReceiptModal.show(context, ReceiptData(
      title: l10n.translate('goalReportTitle', params: {'name': goal.name}),
      amount: goal.currentAmount,
      currencySymbol: currencySymbol(goal.currency),
      dateTime: formatDateTimeDisplay(DateTime.now()),
      details: [
        ReceiptDetail(label: l10n.translate('goalLabel'), value: '${fmtNum(goal.targetAmount)} ${currencySymbol(goal.currency)}'),
        ReceiptDetail(label: l10n.translate('goalProgress'), value: '$progress%'),
        ReceiptDetail(label: l10n.translate('totalDeposited'), value: '${fmtNum(totalContributed)} ${currencySymbol(goal.currency)}'),
        ReceiptDetail(label: l10n.translate('remainingLabel'), value: '${fmtNum((goal.targetAmount - goal.currentAmount).clamp(0, goal.targetAmount.toInt()).toDouble())} ${currencySymbol(goal.currency)}'),
        ReceiptDetail(label: l10n.translate('averageMonthlyDeposit'), value: '${fmtNum(avgMonthly)} ${currencySymbol(goal.currency)}'),
        if (goal.deadline != null) ReceiptDetail(label: l10n.translate('dueDateLabel'), value: goal.deadline!),
      ],
    ), preset: preset);
  }

  Future<void> _exportGoalPdf(SavingsGoal goal, double totalContributed, double avgMonthly) async {
    final l10n = AppLocalizations.of(context);
    try {
      final nf = fmtNum;
      final preset = ref.read(personalReceiptDesignProvider.notifier).getPreset('goal');
      final allTxs = ref.read(personalFinanceProvider).transactions;
      final goalTxs = allTxs.where((t) => t.goalId == goal.id).toList();
      final engine = ref.read(currencyEngineProvider);
      final monthlyData = <String, double>{};
      for (final t in goalTxs) {
        if (t.date == null) continue;
        final key = '${t.date!.year}/${t.date!.month.toString().padLeft(2, '0')}';
        monthlyData[key] = (monthlyData[key] ?? 0) + engine.convert(t.amount, t.currency, goal.currency);
      }
      final sortedMonths = monthlyData.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
      final progress = goal.targetAmount > 0 ? (goal.currentAmount / goal.targetAmount * 100).toInt() : 0;
      final remaining = (goal.targetAmount - goal.currentAmount).clamp(0, goal.targetAmount.toInt()).toDouble();
      final remainingMonths = _remainingMonths(goal);
      final suggestedMonthly = remainingMonths > 0 ? remaining / remainingMonths : 0.0;
      final monthsCount = goalTxsMonthsCount(goal);

      String? deadlineStr;
      String? deadlineText;
      if (goal.deadline != null) {
        final d = DateTime.tryParse(goal.deadline!);
        if (d != null) {
          deadlineStr = DateFormat('yyyy/MM/dd').format(d);
          final days = d.difference(DateTime.now()).inDays;
          deadlineText = days >= 0
              ? l10n.translate('daysRemaining', params: {'days': '$days'})
              : l10n.translate('daysOverdue', params: {'days': '${days.abs()}'});
        }
      }

      final pdfBytes = await GoalReportPdfGenerator.generateGoalReport(
        goalName: goal.name,
        goalIcon: goal.icon,
        currency: goal.currency,
        targetAmount: goal.targetAmount,
        currentAmount: goal.currentAmount,
        totalContributed: totalContributed,
        averageMonthly: avgMonthly,
        suggestedMonthly: suggestedMonthly,
        progressPercent: progress,
        transactionCount: goalTxs.length,
        monthsCount: monthsCount,
        deadline: deadlineStr,
        deadlineText: deadlineText,
        monthlyData: sortedMonths.map((e) => {'month': e.key, 'amount': e.value}).toList(),
        transactions: goalTxs.map((t) => {
          'date': t.date != null ? DateFormat('yyyy/MM/dd').format(t.date!) : '',
          'description': t.description ?? '',
          'amount': nf(t.amount),
        }).toList(),
        preset: preset,
        logoBytes: await _loadLogo(),
      );

      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'fyona_goal_$timestamp.pdf';
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(pdfBytes);
      if (mounted) {
        await StorageUtil.showPdfOptions(context, file, fileName);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.translate('pdfExportFailed', params: {'error': '$e'}), style: const TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppColors.danger,
        ));
      }
    }
  }

  Future<Uint8List?> _loadLogo() async {
    try {
      final logoData = await rootBundle.load('assets/images/logo.png');
      return logoData.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  Widget _exportBtn(String label, IconData icon, Color color, VoidCallback onTap) {
    return SizedBox(
      height: 40,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: Colors.white),
            SizedBox(width: 4),
            Flexible(child: Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white), overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  SUB-WIDGETS
// ════════════════════════════════════════════════════════════
class _SectionTitle extends StatelessWidget {
  final String title;
  final TwoToneIconData? icon;
  const _SectionTitle({required this.title, this.icon});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      if (icon != null) ...[
        AppIconBadge(icon: icon!.outline, size: 28, iconSize: 14, backgroundColor: AppColors.primary.withAlpha(20), borderColor: AppColors.primary.withAlpha(40)),
        SizedBox(width: 8),
      ],
      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
    ]);
  }
}

// ════════════════════════════════════════════════════════════
//  CHARTS
// ════════════════════════════════════════════════════════════
class _MonthlyBarChart extends StatelessWidget {
  final List<MapEntry<String, double>> data;
  const _MonthlyBarChart({required this.data});

  @override
  Widget build(BuildContext context) {
    return BarChart(BarChartData(
      alignment: BarChartAlignment.spaceEvenly,
      barGroups: List.generate(data.length, (i) => BarChartGroupData(x: i, barRods: [
        BarChartRodData(toY: data[i].value, color: AppColors.primary, width: 32, borderRadius: BorderRadius.vertical(top: Radius.circular(4))),
      ])),
      titlesData: FlTitlesData(
        bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, getTitlesWidget: (v, _) {
          final idx = v.toInt();
          if (idx < 0 || idx >= data.length) return SizedBox.shrink();
          return Text(data[idx].key.split(' ').first, style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: AppColors.textSecondary));
        })),
        leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      gridData: FlGridData(show: false),
      borderData: FlBorderData(show: false),
    ));
  }
}

class _ProgressLineChart extends StatelessWidget {
  final SavingsGoal goal;
  final List<PersonalTransaction> goalTxs;
  final CurrencyEngine engine;
  const _ProgressLineChart({required this.goal, required this.goalTxs, required this.engine});

  @override
  Widget build(BuildContext context) {
    final sorted = List<PersonalTransaction>.from(goalTxs)..sort((a, b) => (a.date ?? DateTime(0)).compareTo(b.date ?? DateTime(0)));
    double runningTotal = 0;
    final spots = <FlSpot>[];
    for (int i = 0; i < sorted.length; i++) {
      runningTotal += engine.convert(sorted[i].amount, sorted[i].currency, goal.currency);
      spots.add(FlSpot(i.toDouble(), runningTotal));
    }
    if (spots.isEmpty) return SizedBox.shrink();
    return LineChart(LineChartData(
      gridData: FlGridData(show: true, drawVerticalLine: false),
      titlesData: FlTitlesData(
        bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, interval: (spots.length / 5).ceil().toDouble().clamp(1, double.infinity),
          getTitlesWidget: (v, _) {
            final idx = v.toInt();
            if (idx < 0 || idx >= sorted.length) return SizedBox.shrink();
            return Text(DateFormat('MM/dd').format(sorted[idx].date ?? DateTime(0)), style: TextStyle(fontFamily: 'Cairo', fontSize: 9, color: AppColors.textSecondary));
          })),
        leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 45, getTitlesWidget: (v, _) => Text(fmtNum(v), style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: AppColors.textDisabled)))),
        topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      borderData: FlBorderData(show: false),
      lineBarsData: [
        LineChartBarData(
          spots: spots, isCurved: true, barWidth: 3,
          color: AppColors.primary,
          dotData: FlDotData(show: true, getDotPainter: (spot, _, __, ___) => FlDotCirclePainter(radius: 4, color: AppColors.primary, strokeWidth: 2, strokeColor: Colors.white)),
          belowBarData: BarAreaData(show: true, color: AppColors.primary.withAlpha(30)),
        ),
      ],
    ));
  }
}
