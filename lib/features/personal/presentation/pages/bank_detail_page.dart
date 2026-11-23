import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart';
import 'package:fyona_flutter/core/utils/storage_util.dart';
import 'package:fyona_flutter/shared/widgets/two_tone_icon.dart';
import 'package:fyona_flutter/shared/widgets/two_tone_icons.dart';
import 'package:fyona_flutter/shared/widgets/dots_loader.dart';
import 'package:fyona_flutter/shared/widgets/app_icon_badge.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import '../providers/receipt_design_provider.dart';
import 'bank_report_pdf.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

String _catDisplay(String category, AppLocalizations l10n) {
  final key = personalCategoryKey(category);
  if (key != null) return l10n.translate('cat_$key');
  if (category.startsWith('ادخار - ')) {
    return '${l10n.translate('cat_saving')} - ${category.substring('ادخار - '.length)}';
  }
  return category;
}

class BankDetailPage extends ConsumerStatefulWidget {
  final String bankName;
  const BankDetailPage({super.key, required this.bankName});
  @override
  ConsumerState<BankDetailPage> createState() => _BankDetailPageState();
}

class _BankDetailPageState extends ConsumerState<BankDetailPage> {
  int _selectedMonth = DateTime.now().month;
  int _selectedYear = DateTime.now().year;
  String _txSearchQuery = '';

  String _monthName(int month) {
    final l10n = AppLocalizations.of(context);
    return l10n.translate('month$month');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { ref.read(personalFinanceProvider.notifier).load(); });
  }

  Future<void> _exportStatement() async {
    final l10n = AppLocalizations.of(context);
    final period = '${_monthName(_selectedMonth)} $_selectedYear';
    final opts = await showModalBottomSheet<Map<String, bool>>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _ExportOptionsSheet(bankName: widget.bankName, period: period),
    );
    if (opts == null || !mounted) return;

    final includeCharts = opts['charts'] ?? true;
    final includeAccounts = opts['accounts'] ?? true;
    final includeTransactions = opts['transactions'] ?? true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: DotsLoader()),
    );
    await Future.delayed(Duration.zero);

    try {
      final state = ref.read(personalFinanceProvider);
      final allAccounts = state.bankAccounts.where((a) => a.bankName == widget.bankName).toList();
      final allTxs = state.transactions;
      final bankTxs = allTxs.where((t) => allAccounts.any((a) => a.id == t.accountId)).toList();
      final filteredTxs = bankTxs.where((t) {
        if (t.date == null) return false;
        return t.date!.month == _selectedMonth && t.date!.year == _selectedYear;
      }).toList();
      final totalBalance = ref.read(personalFinanceProvider.notifier).convertAccountsToWallet(allAccounts);
      final engine = ref.read(currencyEngineProvider);
      final walletCurrency = ref.read(personalFinanceProvider).walletCurrency;
      final totalIncome = filteredTxs.where((t) => t.type == 'income').fold<double>(0, (s, t) {
        if (t.currency == walletCurrency) return s + t.amount;
        final converted = engine.convert(t.amount, t.currency, walletCurrency);
        return s + (converted != 0 ? converted : t.amount);
      });
      final totalExpense = filteredTxs.where((t) => t.type == 'expense').fold<double>(0, (s, t) {
        if (t.currency == walletCurrency) return s + t.amount;
        final converted = engine.convert(t.amount, t.currency, walletCurrency);
        return s + (converted != 0 ? converted : t.amount);
      });

      final expenseByCategory = <String, double>{};
      for (final t in filteredTxs.where((t) => t.type == 'expense')) {
        final amt = t.currency == walletCurrency ? t.amount : (engine.convert(t.amount, t.currency, walletCurrency) != 0 ? engine.convert(t.amount, t.currency, walletCurrency) : t.amount);
        expenseByCategory[t.category] = (expenseByCategory[t.category] ?? 0) + amt;
      }
      final topCategories = expenseByCategory.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      final categoryData = topCategories.map((e) => {'label': e.key, 'value': e.value}).toList();

      final dailyTx = <int, double>{};
      for (final t in filteredTxs) {
        if (t.date == null) continue;
        final day = t.date!.day;
        if (t.type == 'expense') {
          final amt = t.currency == walletCurrency ? t.amount : (engine.convert(t.amount, t.currency, walletCurrency) != 0 ? engine.convert(t.amount, t.currency, walletCurrency) : t.amount);
          dailyTx[day] = (dailyTx[day] ?? 0) + amt;
        }
      }
      final dailyData = dailyTx.entries.map((e) => {'label': '${e.key}', 'value': e.value}).toList();

      final incomeExpenseData = [
        {'label': l10n.translate('totalIncome'), 'value': totalIncome},
        {'label': l10n.translate('totalExpenses'), 'value': totalExpense},
      ];

      final accountSummary = allAccounts.map((a) => {
        'currency': a.currency,
        'type': a.accountType == 'checking'
            ? l10n.translate('accountTypeChecking')
            : a.accountType == 'savings'
            ? l10n.translate('accountTypeSavings')
            : a.accountType == 'credit'
            ? l10n.translate('accountTypeCredit')
            : a.accountType == 'cash'
            ? l10n.translate('accountTypeCash')
            : a.accountType,
        'balance': fmtNum(a.balance),
        'notes': a.notes ?? '',
      }).toList();

      final transactionRows = filteredTxs.map((t) => {
        'date': t.date != null ? DateFormat('yyyy/MM/dd').format(t.date!) : '',
        'type': t.type == 'income' ? l10n.translate('txnDeposit') : l10n.translate('txnWithdrawal'),
        'category': personalCategoryKey(t.category) == null ? t.category : l10n.translate('cat_${personalCategoryKey(t.category)}'),
        'description': t.description ?? '',
        'amount': '${t.type == 'income' ? '+' : '-'}${fmtNum(t.amount)}',
      }).toList();

      final preset = ref.read(personalReceiptDesignProvider.notifier).getPreset('bank_report');
      Uint8List? logoBytes;
      try {
        final logoData = await rootBundle.load('assets/images/logo.png');
        logoBytes = logoData.buffer.asUint8List();
      } catch (_) {}
      final pdfBytes = await BankReportPdfGenerator.generate(
        logoBytes: logoBytes,
        bankName: widget.bankName,
        period: period,
        totalBalance: totalBalance,
        totalIncome: totalIncome,
        totalExpense: totalExpense,
        categoryData: categoryData,
        transactions: transactionRows,
        accountSummary: accountSummary,
        dailyData: includeCharts ? dailyData : null,
        incomeExpenseData: includeCharts ? incomeExpenseData : null,
        preset: preset,
        includeCharts: includeCharts,
        includeAccounts: includeAccounts,
        includeTransactions: includeTransactions,
      );

      if (mounted) Navigator.of(context, rootNavigator: true).pop();

      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'fyona_bank_$timestamp.pdf';
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(pdfBytes);

      if (mounted) {
        await StorageUtil.showPdfOptions(context, file, fileName);
      }
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.translate('pdfExportFailed', params: {'error': '$e'}), style: const TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppColors.danger,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(personalFinanceProvider);
    final allAccounts = state.bankAccounts.where((a) => a.bankName == widget.bankName).toList();
    final allTxs = state.transactions;
    final bankTxs = allTxs.where((t) => allAccounts.any((a) => a.id == t.accountId)).toList();
    final filteredTxs = bankTxs.where((t) {
      if (t.date == null) return false;
      return t.date!.month == _selectedMonth && t.date!.year == _selectedYear;
    }).toList();
    final totalBalance = ref.read(personalFinanceProvider.notifier).convertAccountsToWallet(allAccounts);
    final engine = ref.read(currencyEngineProvider);
    final walletCurrency = state.walletCurrency;
    final totalIncome = filteredTxs.where((t) => t.type == 'income').fold<double>(0, (s, t) {
      if (t.currency == walletCurrency) return s + t.amount;
      final converted = engine.convert(t.amount, t.currency, walletCurrency);
      return s + (converted != 0 ? converted : t.amount);
    });
    final totalExpense = filteredTxs.where((t) => t.type == 'expense').fold<double>(0, (s, t) {
      if (t.currency == walletCurrency) return s + t.amount;
      final converted = engine.convert(t.amount, t.currency, walletCurrency);
      return s + (converted != 0 ? converted : t.amount);
    });

    final expenseByCategory = <String, double>{};
    for (final t in filteredTxs.where((t) => t.type == 'expense')) {
      final amt = t.currency == walletCurrency ? t.amount : (engine.convert(t.amount, t.currency, walletCurrency) != 0 ? engine.convert(t.amount, t.currency, walletCurrency) : t.amount);
      expenseByCategory[t.category] = (expenseByCategory[t.category] ?? 0) + amt;
    }
    final topCategories = expenseByCategory.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final dailyTx = <int, double>{};
    for (final t in filteredTxs) {
      if (t.date == null) continue;
      final day = t.date!.day;
      if (t.type == 'expense') {
        final amt = t.currency == walletCurrency ? t.amount : (engine.convert(t.amount, t.currency, walletCurrency) != 0 ? engine.convert(t.amount, t.currency, walletCurrency) : t.amount);
        dailyTx[day] = (dailyTx[day] ?? 0) + amt;
      }
    }
    final txFiltered = _txSearchQuery.isEmpty
        ? filteredTxs
        : filteredTxs.where((t) => (t.category.toLowerCase().contains(_txSearchQuery.toLowerCase()) || (t.description ?? '').toLowerCase().contains(_txSearchQuery.toLowerCase()) || t.type.contains(_txSearchQuery))).toList();
    final sortedTxs = List<PersonalTransaction>.from(txFiltered)..sort((a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)));

    return state.isLoading
          ? Center(child: DotsLoader())
          : RefreshIndicator(
              color: AppColors.primary,
              backgroundColor: AppColors.surface,
              onRefresh: () async => await ref.read(personalFinanceProvider.notifier).load(),
              child: Builder(
                builder: (context) {
                  final l10n = AppLocalizations.of(context);
                  return CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(child: Padding(
                  padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 8, 20, 0),
                  child: _buildHeader(context, allAccounts, totalBalance),
                )),
                  SliverToBoxAdapter(child: _buildMonthSelector(context)),
                  SliverToBoxAdapter(child: _buildSummaryCards(context, totalIncome, totalExpense)),
                  // — Reports section —
                  if (totalIncome > 0 || totalExpense > 0) ...[
                    SliverToBoxAdapter(child: Padding(
                      padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                      child: _SectionTitle(title: l10n.translate('incomeVsExpenseComparison'), icon: TwoToneIcons.barChart),
                    )),
                    SliverToBoxAdapter(child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: SizedBox(height: 260, child: _IncomeExpenseBarChart(income: totalIncome, expense: totalExpense)),
                    )),
                  ],
                  if (topCategories.isNotEmpty) ...[
                    SliverToBoxAdapter(child: Padding(
                      padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                      child: _SectionTitle(title: l10n.translate('topSpendingCategories'), icon: TwoToneIcons.pieChart),
                    )),
                    SliverToBoxAdapter(child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: SizedBox(height: 260, child: _CategoryPieChart(categories: topCategories)),
                    )),
                  ],
                  if (dailyTx.isNotEmpty) ...[
                    SliverToBoxAdapter(child: Padding(
                      padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                      child: _SectionTitle(title: l10n.translate('dailyExpenses'), icon: TwoToneIcons.arrowUp),
                    )),
                    SliverToBoxAdapter(child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: SizedBox(height: 220, child: _DailyLineChart(data: dailyTx)),
                    )),
                  ],
                  if (topCategories.isNotEmpty) ...[
                    SliverToBoxAdapter(child: Padding(
                      padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                      child: _SectionTitle(title: l10n.translate('categoryDetails'), icon: TwoToneIcons.document),
                    )),
                    SliverToBoxAdapter(child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Column(children: topCategories.map((e) => _CategoryRow(label: e.key, amount: e.value, total: totalExpense)).toList()),
                    )),
                  ],
                  // — Accounts section —
                  SliverToBoxAdapter(child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                    child: _SectionTitle(title: l10n.translate('currencyDistribution'), icon: TwoToneIcons.pieChart),
                  )),
                  if (allAccounts.length > 1)
                    SliverToBoxAdapter(child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: SizedBox(height: 200, child: _CurrencyPieChart(accounts: allAccounts)),
                    )),
                  SliverToBoxAdapter(child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                    child: _SectionTitle(title: l10n.translate('bankAccountsTitle'), icon: TwoToneIcons.bank),
                  )),
                  SliverToBoxAdapter(child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Column(children: allAccounts.map((a) => _AccountTile(account: a)).toList()),
                  )),
                  // — Transactions section —
                  SliverToBoxAdapter(child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                    child: _SectionTitle(title: l10n.translate('transactionsTab'), icon: TwoToneIcons.transfer),
                  )),
                  SliverToBoxAdapter(child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: FyonaTextField(
                      onChanged: (v) => setState(() => _txSearchQuery = v),
                      style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textPrimary),
                      decoration: InputDecoration(
                        hintText: l10n.translate('searchHint'),
                        hintStyle: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textDisabled),
                        prefixIcon: Icon(Icons.search, color: AppColors.textDisabled, size: 20),
                        filled: true,
                        fillColor: AppColors.surfaceVariant,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),
                  )),
                  if (sortedTxs.isEmpty)
                    SliverToBoxAdapter(child: Center(child: Padding(
                      padding: EdgeInsets.only(top: 40, bottom: 40),
                      child: Text(l10n.translate('noTransactions'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textDisabled)),
                    )))
                  else
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 100),
                      sliver: SliverList.separated(
                        itemCount: sortedTxs.length,
                        separatorBuilder: (_, __) => SizedBox(height: 8),
                        itemBuilder: (ctx, i) => _TransactionTile(tx: sortedTxs[i]),
                      ),
                    ),
                ],
                  );
                },
              ),
            );
  }

  Widget _buildHeader(BuildContext context, List<PersonalBankAccount> accounts, double totalBalance) {
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
            AppIconBadge(icon: TwoToneIcons.bank.outline, size: 44, iconSize: 22, backgroundColor: Colors.white.withAlpha(20), borderColor: Colors.white.withAlpha(30)),
            SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(isCashAccount(widget.bankName) ? cashDisplayName() : widget.bankName, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w700, color: Colors.white)),
              SizedBox(height: 2),
              Text(l10n.translate('accountsCount', params: {'count': '${accounts.length}'}), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: Colors.white.withAlpha(180))),
            ])),
            IconButton(
              icon: Icon(Icons.receipt_long, color: Colors.white),
              onPressed: _exportStatement,
            ),
          ]),
          SizedBox(height: 24),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l10n.translate('totalBalances'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: Colors.white.withAlpha(160))),
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
          onPressed: () => setState(() {
            _selectedMonth--;
            if (_selectedMonth < 1) { _selectedMonth = 12; _selectedYear--; }
          }),
          icon: Icon(Icons.chevron_right, color: AppColors.textSecondary),
        ),
        Expanded(
          child: Center(
            child: Text('${_monthName(_selectedMonth)} $_selectedYear', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          ),
        ),
        IconButton(
          onPressed: () => setState(() {
            _selectedMonth++;
            if (_selectedMonth > 12) { _selectedMonth = 1; _selectedYear++; }
          }),
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
        _SummaryMini(label: l10n.translate('incomeLabel'), amount: income, color: Color(0xFF2E7D32), icon: TwoToneIcons.arrowDown),
        SizedBox(width: 8),
        _SummaryMini(label: l10n.translate('expenseLabel'), amount: expense, color: Color(0xFFC62828), icon: TwoToneIcons.arrowUp),
        SizedBox(width: 8),
        _SummaryMini(label: l10n.translate('net'), amount: net, color: net >= 0 ? AppColors.primary : AppColors.danger, icon: TwoToneIcons.money),
      ]),
    );
  }

  // ════════════════════════════════════════════════════════════
  //  SUB-WIDGETS
// ════════════════════════════════════════════════════════════
}

// ════════════════════════════════════════════════════════════
//  EXPORT OPTIONS BOTTOM SHEET
// ════════════════════════════════════════════════════════════
class _ExportOptionsSheet extends StatefulWidget {
  final String bankName;
  final String period;
  const _ExportOptionsSheet({required this.bankName, required this.period});
  @override
  State<_ExportOptionsSheet> createState() => _ExportOptionsSheetState();
}

class _ExportOptionsSheetState extends State<_ExportOptionsSheet> {
  bool _charts = true;
  bool _accounts = true;
  bool _transactions = true;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 12, 20, MediaQuery.of(context).padding.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
          SizedBox(height: 16),
          Row(children: [
            Icon(Icons.picture_as_pdf, color: AppColors.primary, size: 22),
            SizedBox(width: 8),
            Text(l10n.translate('exportPdf'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            Spacer(),
            Text(widget.period, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textSecondary)),
          ]),
          SizedBox(height: 4),
          Text(isCashAccount(widget.bankName) ? cashDisplayName() : widget.bankName, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textDisabled)),
          SizedBox(height: 16),
          Divider(color: AppColors.border, height: 1),
          SizedBox(height: 8),
          _OptionToggle(label: l10n.translate('chartsOption'), value: _charts, onChanged: (v) => setState(() => _charts = v)),
          _OptionToggle(label: l10n.translate('bankAccountsTitle'), value: _accounts, onChanged: (v) => setState(() => _accounts = v)),
          _OptionToggle(label: l10n.translate('transactionsTab'), value: _transactions, onChanged: (v) => setState(() => _transactions = v)),
          SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context, {'charts': _charts, 'accounts': _accounts, 'transactions': _transactions}),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: Text(l10n.translate('exportReport'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }
}

class _OptionToggle extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _OptionToggle({required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Icon(value ? Icons.check_box : Icons.check_box_outline_blank, color: value ? AppColors.primary : AppColors.textDisabled, size: 22),
        SizedBox(width: 10),
        Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textPrimary)),
        Spacer(),
      ]),
    );
  }
}

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
//  CHARTS (fl_chart for on-screen)
// ════════════════════════════════════════════════════════════
class _CurrencyPieChart extends StatelessWidget {
  final List<PersonalBankAccount> accounts;
  const _CurrencyPieChart({required this.accounts});

  @override
  Widget build(BuildContext context) {
    final colors = [AppColors.primary, AppColors.primaryDark, Color(0xFFB82040), Color(0xFFD4A373), Color(0xFF6C9BCF), Color(0xFF77DD77)];
    final sections = <PieChartSectionData>[];
    for (int i = 0; i < accounts.length; i++) {
      final a = accounts[i];
      sections.add(PieChartSectionData(
        value: a.balance.abs(),
        title: '${a.currency}\n${fmtNum(a.balance)}',
        color: colors[i % colors.length],
        radius: 110,
        titleStyle: TextStyle(fontFamily: 'Cairo', fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
      ));
    }
    return PieChart(PieChartData(sections: sections, centerSpaceRadius: 16, sectionsSpace: 3));
  }
}

class _IncomeExpenseBarChart extends StatelessWidget {
  final double income;
  final double expense;
  const _IncomeExpenseBarChart({required this.income, required this.expense});

  @override
  Widget build(BuildContext context) {
    return BarChart(BarChartData(
      alignment: BarChartAlignment.spaceEvenly,
      barGroups: [
        BarChartGroupData(x: 0, barRods: [
          BarChartRodData(toY: income, color: Color(0xFF2E7D32), width: 60, borderRadius: BorderRadius.vertical(top: Radius.circular(6))),
        ]),
        BarChartGroupData(x: 1, barRods: [
          BarChartRodData(toY: expense, color: Color(0xFFC62828), width: 60, borderRadius: BorderRadius.vertical(top: Radius.circular(6))),
        ]),
      ],
      titlesData: FlTitlesData(
        bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, getTitlesWidget: (v, _) {
          final l10n = AppLocalizations.of(context);
          final labels = [l10n.translate('totalIncome'), l10n.translate('totalExpenses')];
          return Text(labels[v.toInt()], style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: AppColors.textSecondary));
        })),
        leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 45, getTitlesWidget: (v, _) {
          return Text(fmtNum(v), style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: AppColors.textDisabled));
        })),
        topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      gridData: FlGridData(show: true, drawVerticalLine: false, horizontalInterval: income > 0 ? income / 4 : 1000),
      borderData: FlBorderData(show: false),
    ));
  }
}

class _CategoryPieChart extends StatelessWidget {
  final List<MapEntry<String, double>> categories;
  const _CategoryPieChart({required this.categories});

  @override
  Widget build(BuildContext context) {
    final colors = [AppColors.primary, Color(0xFFB82040), Color(0xFF7A1020), Color(0xFFD4A373), Color(0xFF6C9BCF), Color(0xFF77DD77), Color(0xFFFFB347), Color(0xFFCB99C9)];
    return PieChart(PieChartData(
      sections: List.generate(categories.length > 6 ? 6 : categories.length, (i) {
        final e = categories[i];
         return PieChartSectionData(value: e.value, title: '${_catDisplay(e.key, AppLocalizations.of(context))}\n${fmtNum(e.value)}', color: colors[i % colors.length], radius: 110, titleStyle: TextStyle(fontFamily: 'Cairo', fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white));
      }),
      centerSpaceRadius: 10,
      sectionsSpace: 2,
    ));
  }
}

class _DailyLineChart extends StatelessWidget {
  final Map<int, double> data;
  const _DailyLineChart({required this.data});

  @override
  Widget build(BuildContext context) {
    final spots = data.entries.map((e) => FlSpot(e.key.toDouble(), e.value)).toList()..sort((a, b) => a.x.compareTo(b.x));
    return LineChart(LineChartData(
      gridData: FlGridData(show: true, drawVerticalLine: false),
      titlesData: FlTitlesData(
        bottomTitles: AxisTitles(sideTitles: SideTitles(
          showTitles: true, interval: 5,
          getTitlesWidget: (v, _) => Text('${v.toInt()}', style: TextStyle(fontFamily: 'Cairo', fontSize: 9, color: AppColors.textDisabled)),
        )),
        leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 35, getTitlesWidget: (v, _) => Text(fmtNum(v), style: TextStyle(fontFamily: 'Cairo', fontSize: 9, color: AppColors.textDisabled)))),
        topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      borderData: FlBorderData(show: false),
      lineBarsData: [
        LineChartBarData(
          spots: spots, isCurved: true, barWidth: 2.5,
          color: AppColors.primary,
          dotData: FlDotData(show: true, getDotPainter: (spot, _, __, ___) => FlDotCirclePainter(radius: 3, color: AppColors.primary, strokeWidth: 1.5, strokeColor: Colors.white)),
          belowBarData: BarAreaData(show: true, color: AppColors.primary.withAlpha(30)),
        ),
      ],
    ));
  }
}

class _CategoryRow extends StatelessWidget {
  final String label;
  final double amount;
  final double total;
  const _CategoryRow({required this.label, required this.amount, required this.total});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final displayLabel = _catDisplay(label, l10n);
    final pct = total > 0 ? amount / total : 0.0;
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(10)),
      child: Column(children: [
        Row(children: [
          Expanded(child: Text(displayLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
          SizedBox(width: 8),
          Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: AlignmentDirectional.centerEnd, child: Text(fmtNum(amount), maxLines: 1, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: AppColors.primary)))),
          SizedBox(width: 6),
          Text('${(pct * 100).toStringAsFixed(1)}%', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: AppColors.textDisabled)),
        ]),
        SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: pct, backgroundColor: AppColors.border, color: AppColors.primary, minHeight: 6),
        ),
      ]),
    );
  }
}

class _AccountTile extends StatelessWidget {
  final PersonalBankAccount account;
  const _AccountTile({required this.account});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(color: AppColors.primary.withAlpha(20), borderRadius: BorderRadius.circular(10)),
          child: TwoToneIcon(data: TwoToneIcons.transfer, size: 18, outlineColor: AppColors.primary),
        ),
        SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${account.currency} — ${_accountTypeLabel(l10n, account.accountType)}', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          if (account.notes != null && account.notes!.isNotEmpty)
            Text(account.notes!, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: AppColors.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
        ])),
        Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: AlignmentDirectional.centerEnd, child: Text(fmtNum(account.balance), maxLines: 1, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: AppColors.textPrimary)))),
      ]),
    );
  }

  String _accountTypeLabel(AppLocalizations l10n, String type) {
    switch (type) {
      case 'checking': return l10n.translate('accountTypeChecking');
      case 'savings': return l10n.translate('accountTypeSavings');
      case 'credit': return l10n.translate('accountTypeCredit');
      case 'wallet': return l10n.translate('accountTypeWallet');
      default: return l10n.translate('accountTypeChecking');
    }
  }
}

class _TransactionTile extends StatelessWidget {
  final PersonalTransaction tx;
  const _TransactionTile({required this.tx});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isIncome = tx.type == 'income';
    final color = isIncome ? Color(0xFF2E7D32) : Color(0xFFC62828);
    final icon = isIncome ? TwoToneIcons.arrowDown : TwoToneIcons.arrowUp;
    final label = isIncome ? l10n.translate('deposit') : l10n.translate('withdrawal');

    return Container(
      margin: EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Container(
          width: 36, height: 36,
          decoration: BoxDecoration(color: color.withAlpha(25), borderRadius: BorderRadius.circular(10)),
          child: TwoToneIcon(data: icon, size: 16, outlineColor: color),
        ),
        SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          Text(_catDisplay(tx.category, l10n), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.textSecondary)),
          if ((tx.description ?? '').isNotEmpty)
            Text(tx.description!, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: AppColors.textDisabled), maxLines: 1, overflow: TextOverflow.ellipsis),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${isIncome ? '+' : '-'}${fmtNum(tx.amount)}', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: color)),
          if (tx.date != null)
            Text(DateFormat('dd/MM').format(tx.date!), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: AppColors.textDisabled)),
        ]),
      ]),
    );
  }
}

