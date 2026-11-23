import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:fyona_flutter/core/utils/storage_util.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/shared/widgets/two_tone_icon.dart';
import 'package:fyona_flutter/shared/widgets/two_tone_icons.dart';
import 'package:fyona_flutter/shared/widgets/dots_loader.dart';
import 'package:fyona_flutter/shared/widgets/app_icon_badge.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/core/theme/bank_gradients.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import '../providers/receipt_design_provider.dart';
import 'bank_report_pdf.dart';

class AllBanksReportPage extends ConsumerStatefulWidget {
  const AllBanksReportPage({super.key});
  @override
  ConsumerState<AllBanksReportPage> createState() => _AllBanksReportPageState();
}

class _AllBanksReportPageState extends ConsumerState<AllBanksReportPage> {
  int _month = DateTime.now().month;
  int _year = DateTime.now().year;

  String _monthName(int month) => AppLocalizations.of(context).translate('month$month');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { ref.read(personalFinanceProvider.notifier).load(); });
  }

  Future<void> _exportReport() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: DotsLoader()),
    );
    await Future.delayed(Duration.zero);

    try {
      final period = '${_monthName(_month)} $_year';
      final state = ref.read(personalFinanceProvider);
      final allAccounts = state.bankAccounts;
      final allTxs = state.transactions;
      final grouped = <String, List<PersonalBankAccount>>{};
      for (final a in allAccounts) {
        grouped.putIfAbsent(a.bankName, () => []).add(a);
      }
      final filteredTxs = allTxs.where((t) {
        if (t.date == null) return false;
        return t.date!.month == _month && t.date!.year == _year;
      }).toList();
      final engine = ref.read(currencyEngineProvider);
      final walletCurrency = state.walletCurrency;
      double _convert(PersonalTransaction t) {
        if (t.currency == walletCurrency) return t.amount;
        final converted = engine.convert(t.amount, t.currency, walletCurrency);
        return converted != 0 ? converted : t.amount;
      }
      final totalIncome = filteredTxs.where((t) => t.type == 'income').fold<double>(0, (s, t) => s + _convert(t));
      final totalExpense = filteredTxs.where((t) => t.type == 'expense').fold<double>(0, (s, t) => s + _convert(t));
      final totalBalance = state.walletTotalBalance;

      final banks = grouped.entries.map((e) {
        final accountBalances = ref.read(personalFinanceProvider.notifier).convertAccountsToWallet(e.value);
        final bankTxs = filteredTxs.where((t) => e.value.any((a) => a.id == t.accountId)).toList();
        final income = bankTxs.where((t) => t.type == 'income').fold<double>(0, (s, t) => s + _convert(t));
        final expense = bankTxs.where((t) => t.type == 'expense').fold<double>(0, (s, t) => s + _convert(t));
        return <String, dynamic>{
          'name': e.key,
          'accounts': e.value.length,
          'balance': accountBalances,
          'income': income,
          'expense': expense,
          'transactions': bankTxs.length,
        };
      }).toList();

      final preset = ref.read(personalReceiptDesignProvider.notifier).getPreset('bank_report');
      Uint8List? logoBytes;
      try {
        final logoFile = File('${(await getApplicationDocumentsDirectory()).path}/logo.png');
        if (await logoFile.exists()) logoBytes = await logoFile.readAsBytes();
      } catch (_) {}
      final pdfBytes = await BankReportPdfGenerator.generateAllBanksReport(
        period: period,
        totalBalance: totalBalance,
        totalIncome: totalIncome,
        totalExpense: totalExpense,
        banks: banks,
        preset: preset,
        logoBytes: logoBytes,
      );

      if (mounted) Navigator.of(context, rootNavigator: true).pop();

      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'fyona_all_banks_$timestamp.pdf';
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(pdfBytes);

      if (mounted) {
        await StorageUtil.showPdfOptions(context, file, fileName);
      }
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context).translate('pdfExportFailed', params: {'error': '$e'}), style: const TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppColors.danger,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(personalFinanceProvider);
    final allAccounts = state.bankAccounts;
    final allTxs = state.transactions;
    final grouped = <String, List<PersonalBankAccount>>{};
    for (final a in allAccounts) {
      grouped.putIfAbsent(a.bankName, () => []).add(a);
    }
    final filteredTxs = allTxs.where((t) {
      if (t.date == null) return false;
      return t.date!.month == _month && t.date!.year == _year;
    }).toList();
    final totalBalance = state.walletTotalBalance;
    final engine = ref.read(currencyEngineProvider);
    final walletCurrency = state.walletCurrency;
    double _convert(PersonalTransaction t) {
      if (t.currency == walletCurrency) return t.amount;
      final converted = engine.convert(t.amount, t.currency, walletCurrency);
      return converted != 0 ? converted : t.amount;
    }
    final totalIncome = filteredTxs.where((t) => t.type == 'income').fold<double>(0, (s, t) => s + _convert(t));
    final totalExpense = filteredTxs.where((t) => t.type == 'expense').fold<double>(0, (s, t) => s + _convert(t));

    return state.isLoading
          ? Center(child: DotsLoader())
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: Padding(
                  padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 8, 20, 0),
                  child: _buildHeader(context, grouped, totalBalance),
                )),
                SliverToBoxAdapter(child: _buildMonthSelector(context)),
                SliverToBoxAdapter(child: _buildSummaryCards(context, totalIncome, totalExpense)),
                SliverToBoxAdapter(child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: _SectionTitle(title: l10n.translate('bankSummary'), icon: TwoToneIcons.barChart),
                )),
                if (grouped.length > 1) ...[
                  SliverToBoxAdapter(child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: SizedBox(height: 220, child: _BanksComparisonChart(grouped: grouped, walletCurrency: state.walletCurrency, notifier: ref.read(personalFinanceProvider.notifier))),
                  )),
                ],
                SliverToBoxAdapter(child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: _SectionTitle(title: l10n.translate('totalBalance'), icon: TwoToneIcons.pieChart),
                )),
                if (grouped.isNotEmpty)
                  SliverToBoxAdapter(child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: SizedBox(height: 220, child: _BalancePieChart(grouped: grouped, walletCurrency: state.walletCurrency, notifier: ref.read(personalFinanceProvider.notifier))),
                  )),
                SliverToBoxAdapter(child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Row(children: [
                    Flexible(fit: FlexFit.loose, child: _SectionTitle(title: l10n.translate('personalBanks'), icon: TwoToneIcons.bank)),
                    Spacer(),
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(6)),
                      child: Text('${grouped.length}', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), fontWeight: FontWeight.w600, color: AppColors.textDisabled)),
                    ),
                  ]),
                )),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 100),
                  sliver: SliverList.separated(
                    itemCount: grouped.length,
                    separatorBuilder: (_, __) => SizedBox(height: 8),
                    itemBuilder: (ctx, i) {
                      final entry = grouped.entries.elementAt(i);
                      final convertedTotal = ref.read(personalFinanceProvider.notifier).convertAccountsToWallet(entry.value);
                      return _BankMiniCard(
                        bankName: entry.key,
                        accounts: entry.value,
                        convertedTotal: convertedTotal,
                        walletCurrency: state.walletCurrency,
                        txs: filteredTxs.where((t) => entry.value.any((a) => a.id == t.accountId)).toList(),
                        engine: engine,
                      );
                    },
                  ),
                ),
              ],
            );
  }

Widget _buildHeader(BuildContext context, Map<String, List<PersonalBankAccount>> grouped, double totalBalance) {
    final l10n = AppLocalizations.of(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(-1.0, -1.0), end: Alignment(1.5, 1.5),
          colors: [Color(0xFFC01838), AppColors.primary, Color(0xFF7A1020)],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: AppColors.primary.withAlpha(100), blurRadius: 32, offset: Offset(0, 12)),
          BoxShadow(color: AppColors.primaryDark.withAlpha(60), blurRadius: 48, offset: Offset(0, 24)),
        ],
      ),
      child: Stack(children: [
        Positioned(top: -30, right: -20, child: Container(width: 100, height: 100,
          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withAlpha(15)))),
        Positioned(bottom: -40, left: -10, child: Container(width: 120, height: 120,
          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withAlpha(10)))),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
            AppIconBadge(icon: TwoToneIcons.barChart.outline, size: 44, iconSize: 22, backgroundColor: Colors.white.withAlpha(20), borderColor: Colors.white.withAlpha(30)),
            SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l10n.translate('allBanksReport'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w700, color: Colors.white)),
              SizedBox(height: 2),
              Text('${grouped.length} ${l10n.translate('personalBanks')} \u2022 ${l10n.translate('allBanksReport')}', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: Colors.white.withAlpha(180))),
            ])),
            IconButton(
              icon: Icon(Icons.receipt_long, color: Colors.white, size: 22),
              onPressed: _exportReport,
            ),
          ]),
          SizedBox(height: 24),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l10n.translate('totalBalance'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: Colors.white.withAlpha(160))),
            SizedBox(height: 2),
            Text(fmtNum(totalBalance), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 20), fontWeight: FontWeight.w700, color: Colors.white.withAlpha(220))),
          ]),
        ]),
      ]),
    );
  }

  Widget _buildMonthSelector(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        IconButton(
          onPressed: () => setState(() { _month--; if (_month < 1) { _month = 12; _year--; } }),
          icon: Icon(Icons.chevron_right, color: AppColors.textSecondary),
        ),
        Expanded(child: Center(child: Text('${_monthName(_month)} $_year', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: AppColors.textPrimary)))),
        IconButton(
          onPressed: () => setState(() { _month++; if (_month > 12) { _month = 1; _year++; } }),
          icon: Icon(Icons.chevron_left, color: AppColors.textSecondary),
        ),
      ]),
    );
  }

  Widget _buildSummaryCards(BuildContext context, double income, double expense) {
    final l10n = AppLocalizations.of(context);
    final net = income - expense;
    return Container(
      color: AppColors.surface,
      padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(children: [
        _SummaryMini(label: l10n.translate('totalIncome'), amount: income, color: Color(0xFF2E7D32), icon: TwoToneIcons.arrowDown),
        SizedBox(width: 8),
        _SummaryMini(label: l10n.translate('totalExpense'), amount: expense, color: Color(0xFFC62828), icon: TwoToneIcons.arrowUp),
        SizedBox(width: 8),
        _SummaryMini(label: l10n.translate('net'), amount: net, color: net >= 0 ? AppColors.primary : AppColors.danger, icon: TwoToneIcons.money),
      ]),
    );
  }
}


//  SUB-WIDGETS
// ════════════════════════════════════════════════════════════

class _SummaryMini extends StatelessWidget {
  final String label;
  final double amount;
  final Color color;
  final TwoToneIconData icon;
  const _SummaryMini({required this.label, required this.amount, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            TwoToneIcon(data: icon, size: 14, outlineColor: color),
            SizedBox(width: 6),
            Flexible(
              child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: AppColors.textSecondary)),
            ),
          ]),
          SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(fmtNum(amount),
              maxLines: 1,
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: color)),
          ),
        ]),
      ),
    );
  }
}

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
class _BanksComparisonChart extends StatelessWidget {
  final Map<String, List<PersonalBankAccount>> grouped;
  final String walletCurrency;
  final PersonalFinanceNotifier notifier;
  const _BanksComparisonChart({required this.grouped, required this.walletCurrency, required this.notifier});

  @override
  Widget build(BuildContext context) {
    final colors = [AppColors.primary, AppColors.primaryDark, Color(0xFFB82040), Color(0xFFD4A373), Color(0xFF6C9BCF), Color(0xFF77DD77)];
    return BarChart(BarChartData(
      alignment: BarChartAlignment.spaceAround,
      barGroups: List.generate(grouped.length, (i) {
        final entry = grouped.entries.elementAt(i);
        final total = notifier.convertAccountsToWallet(entry.value);
        return BarChartGroupData(x: i, barRods: [
          BarChartRodData(toY: total, color: colors[i % colors.length], width: 32, borderRadius: BorderRadius.vertical(top: Radius.circular(6))),
        ]);
      }),
      titlesData: FlTitlesData(
        bottomTitles: AxisTitles(sideTitles: SideTitles(
          showTitles: true,
          getTitlesWidget: (v, _) {
            final name = grouped.keys.elementAt(v.toInt());
            return Text(name.length > 8 ? '${name.substring(0, 8)}..' : name, style: TextStyle(fontFamily: 'Cairo', fontSize: 9, color: AppColors.textSecondary));
          },
        )),
        leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40, getTitlesWidget: (v, _) => Text(fmtNum(v), style: TextStyle(fontFamily: 'Cairo', fontSize: 9, color: AppColors.textDisabled)))),
        topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      gridData: FlGridData(show: true, drawVerticalLine: false),
      borderData: FlBorderData(show: false),
    ));
  }
}

class _BalancePieChart extends StatelessWidget {
  final Map<String, List<PersonalBankAccount>> grouped;
  final String walletCurrency;
  final PersonalFinanceNotifier notifier;
  const _BalancePieChart({required this.grouped, required this.walletCurrency, required this.notifier});

  @override
  Widget build(BuildContext context) {
    final colors = [AppColors.primary, AppColors.primaryDark, Color(0xFFB82040), Color(0xFFD4A373), Color(0xFF6C9BCF), Color(0xFF77DD77)];
    return PieChart(PieChartData(
      sections: List.generate(grouped.length, (i) {
        final entry = grouped.entries.elementAt(i);
        final total = notifier.convertAccountsToWallet(entry.value);
        return PieChartSectionData(
          value: total.abs(),
          title: '${entry.key}\n${fmtNum(total)}',
          color: colors[i % colors.length],
          radius: 80,
          titleStyle: TextStyle(fontFamily: 'Cairo', fontSize: 9, fontWeight: FontWeight.w700, color: Colors.white),
        );
      }),
      centerSpaceRadius: 24,
      sectionsSpace: 3,
    ));
  }
}

// ════════════════════════════════════════════════════════════
//  BANK MINI CARD
// ════════════════════════════════════════════════════════════
class _BankMiniCard extends StatelessWidget {
  final String bankName;
  final List<PersonalBankAccount> accounts;
  final double convertedTotal;
  final String walletCurrency;
  final List<PersonalTransaction> txs;
  final CurrencyEngine engine;
  const _BankMiniCard({required this.bankName, required this.accounts, required this.convertedTotal, required this.walletCurrency, required this.txs, required this.engine});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final total = convertedTotal;
    final income = txs.where((t) => t.type == 'income').fold<double>(0, (s, t) {
      if (t.currency == walletCurrency) return s + t.amount;
      final converted = engine.convert(t.amount, t.currency, walletCurrency);
      return s + (converted != 0 ? converted : t.amount);
    });
    final expense = txs.where((t) => t.type == 'expense').fold<double>(0, (s, t) {
      if (t.currency == walletCurrency) return s + t.amount;
      final converted = engine.convert(t.amount, t.currency, walletCurrency);
      return s + (converted != 0 ? converted : t.amount);
    });
    final g = bankGradients[bankGradientIndex(bankName)];

    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment(1, -0.5), end: Alignment(-1, 0.5), colors: g),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AppIconBadge(icon: TwoToneIcons.bank.outline, size: 36, iconSize: 18, backgroundColor: Colors.white.withAlpha(20), borderColor: Colors.white.withAlpha(30)),
          SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(isCashAccount(bankName) ? cashDisplayName() : bankName, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: Colors.white)),
            Text('${accounts.length} ${l10n.translate('bankStatement')} \u2022 ${txs.length} ${l10n.translate('transactionsTab')}', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: Colors.white.withAlpha(130))),
          ])),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerEnd,
              child: Text(fmtNum(total),
                maxLines: 1,
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          ),
        ]),
        SizedBox(height: 12),
        Row(children: [
          _MiniStat(label: l10n.translate('totalIncome'), value: fmtNum(income), color: Color(0xFF81C784)),
          SizedBox(width: 12),
          _MiniStat(label: l10n.translate('totalExpense'), value: fmtNum(expense), color: Color(0xFFE57373)),
          SizedBox(width: 12),
          _MiniStat(label: l10n.translate('net'), value: fmtNum(income - expense), color: income - expense >= 0 ? Colors.white : Color(0xFFFFAB91)),
        ]),
      ]),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _MiniStat({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 9), color: Colors.white.withAlpha(120))),
        SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(value,
            maxLines: 1,
            style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.w700, color: color)),
        ),
      ]),
    );
  }
}
