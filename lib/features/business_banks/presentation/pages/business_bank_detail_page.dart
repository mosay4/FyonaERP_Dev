import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/storage_util.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../../../../shared/widgets/app_icon_badge.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../branches/data/branch_scope.dart';
import '../../data/business_bank_models.dart';
import '../providers/business_banks_providers.dart';
import '../../../core_business/presentation/providers/business_ledger_session.dart';
import '../bank_transaction_visual.dart';
import '../../../personal/presentation/providers/receipt_design_provider.dart';
import '../../../personal/presentation/pages/bank_report_pdf.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Business bank detail — mirrors the personal bank-detail screen exactly:
/// gradient header (back, badge, name, counts, export), month selector,
/// income/expense/net summary, charts, currency distribution, account tiles,
/// searchable transactions and PDF export. Data is org-level and fully
/// separate from Personal.
class BusinessBankDetailPage extends ConsumerStatefulWidget {
  final String bankName;
  final String? groupId;
  const BusinessBankDetailPage({super.key, required this.bankName,
      this.groupId});
  @override
  ConsumerState<BusinessBankDetailPage> createState() =>
      _BusinessBankDetailPageState();
}

class _BusinessBankDetailPageState
    extends ConsumerState<BusinessBankDetailPage> {
  int _selectedMonth = DateTime.now().month;
  int _selectedYear = DateTime.now().year;
  String _txSearchQuery = '';
  List<Map<String, dynamic>> _allTxs = [];
  bool _txLoading = false;
  bool _txFailed = false;
  int _loadGeneration = 0;

  Future<void> _unlinkAccounts() async {
    if (!BranchScope.allMode || !ref.read(employeeCanProvider('banks.add_delete'))) return;
    final l10n = AppLocalizations.of(context);
    final source = ref.read(businessBanksProvider.notifier);
    final ids = ref
        .read(businessBanksProvider)
        .accounts
        .where(_matchesGroup)
        .map((a) => a.id)
        .toList();
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(l10n.translate('bankLinkUnlink'),
            style: const TextStyle(fontFamily: 'Cairo', fontSize: 15)),
        content: Text(l10n.translate('bankLinkBody'),
            style: const TextStyle(fontFamily: 'Cairo', fontSize: 11)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.translate('cancel'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.translate('bankLinkUnlink'),
                  style: const TextStyle(
                      fontFamily: 'Cairo', fontWeight: FontWeight.w800))),
        ],
      ),
    );
    if (ok != true || !mounted || !source.isCurrent || !BranchScope.allMode ||
        !ref.read(employeeCanProvider('banks.add_delete'))) return;
    try {
      await ref.read(businessBanksApiProvider).unlinkAccounts(ids);
      await ref.read(businessBanksProvider.notifier).load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.translate('bankLinkUnlinked'),
              style: const TextStyle(fontFamily: 'Cairo'))));
      context.pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('$e',
                style: const TextStyle(fontFamily: 'Cairo'))));
      }
    }
  }

  bool _matchesGroup(BusinessBankAccount a) =>
      widget.groupId != null && widget.groupId!.isNotEmpty
          ? a.groupKey == widget.groupId
          : a.bankName == widget.bankName;

  String _monthName(int month) {
    final l10n = AppLocalizations.of(context);
    return l10n.translate('month$month');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    if (!mounted) return;
    await ref.read(businessBanksProvider.notifier).load();
    if (!mounted) return;
    await _loadAllTx();
  }

  Future<void> _loadAllTx() async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    final source = ref.read(businessBanksProvider.notifier);
    final accounts = ref.read(businessBanksProvider).accounts;
    final mine = accounts.where(_matchesGroup).toList();
    if (mine.isEmpty) {
      if (mounted) setState(() => _allTxs = []);
      return;
    }
    setState(() {
      _txLoading = true;
      _txFailed = false;
    });
    try {
      final rows = await source.history(mine.map((a) => a.id).toList());
      if (!mounted || !source.isCurrent || generation != _loadGeneration) return;
      setState(() {
        _allTxs = rows;
        _txLoading = false;
      });
    } catch (_) {
      if (mounted && source.isCurrent && generation == _loadGeneration) {
        setState(() {
          _allTxs = [];
          _txLoading = false;
          _txFailed = true;
        });
      }
    }
  }

  double _asDouble(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  DateTime? _txDate(Map<String, dynamic> t) {
    try {
      final raw = t['date']?.toString();
      if (raw == null || raw.isEmpty) return null;
      return DateTime.parse(raw);
    } catch (_) {
      return null;
    }
  }

  bool _isIn(Map<String, dynamic> t) {
    return BankTransactionVisual('${t['tx_type'] ?? ''}').isIn;
  }

  double _inWallet(double amount, String currency, String wallet,
      BusinessBanksNotifier source) {
    if (currency == wallet) return amount;
    final converted = source.convert(amount, currency, wallet);
    return source.isLocal || converted != 0 ? converted : amount;
  }

  Future<void> _exportStatement(
      List<BusinessBankAccount> allAccounts,
      List<Map<String, dynamic>> filteredTxs,
      double totalBalance,
      double totalIncome,
      double totalExpense,
      Map<int, double> dailyTx) async {
    final source = ref.read(businessBanksProvider.notifier);
    final l10n = AppLocalizations.of(context);
    final period = '${_monthName(_selectedMonth)} $_selectedYear';
    final opts = await showModalBottomSheet<Map<String, bool>>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) =>
          _ExportOptionsSheet(bankName: widget.bankName, period: period),
    );
    if (opts == null || !mounted) return;
    bool canExport() => mounted && source.isCurrent &&
        ref.read(businessBankBalanceReadProvider) &&
        ref.read(employeeCanProvider('reports.view')) &&
        ref.read(employeeCanProvider('reports.export')) &&
        (!source.isLocal || ref.read(employeeCanProvider('banks.details')));
    if (!canExport()) return;

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
      final dailyData = dailyTx.entries
          .map((e) => {'label': '${e.key}', 'value': e.value})
          .toList();
      final incomeExpenseData = [
        {'label': l10n.translate('totalIncome'), 'value': totalIncome},
        {'label': l10n.translate('totalExpenses'), 'value': totalExpense},
      ];
      final accountSummary = allAccounts
          .map((a) => {
                'currency': a.currency,
                'type': a.accountType == 'savings'
                    ? l10n.translate('accountTypeSavings')
                    : l10n.translate('accountTypeChecking'),
                'balance': fmtNum(a.balance),
                'notes': '',
              })
          .toList();
      final transactionRows = filteredTxs.map((t) {
        final isIn = _isIn(t);
        DateTime? d = _txDate(t);
        return {
          'date': d != null ? DateFormat('yyyy/MM/dd').format(d) : '',
          'type': isIn
              ? l10n.translate('txnDeposit')
              : l10n.translate('txnWithdrawal'),
          'category': '',
          'description': (t['description'] ?? '').toString(),
          'amount':
              '${isIn ? '+' : '-'}${fmtNum(_asDouble(t['amount']))}',
        };
      }).toList();

      final preset = ref
          .read(personalReceiptDesignProvider.notifier)
          .getPreset('bank_report');
      Uint8List? logoBytes;
      try {
        final logoData =
            await rootBundle.load('assets/images/logo.png');
        logoBytes = logoData.buffer.asUint8List();
      } catch (_) {}
      final pdfBytes = await BankReportPdfGenerator.generate(
        logoBytes: logoBytes,
        bankName: widget.bankName,
        period: period,
        totalBalance: totalBalance,
        totalIncome: totalIncome,
        totalExpense: totalExpense,
        categoryData: const [],
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
      if (!canExport()) return;

      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'fyona_bank_$timestamp.pdf';
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(pdfBytes);

      if (canExport()) {
        await StorageUtil.showPdfOptions(context, file, fileName);
      }
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              l10n.translate('pdfExportFailed',
                  params: {'error': '$e'}),
              style: const TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppColors.danger,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(businessBanksProvider);
    final source = ref.watch(businessBanksProvider.notifier);
    final details = ref.watch(employeeCanProvider('banks.details'));
    ref.listen(businessBanksProvider.notifier, (_, _) {
      _loadGeneration++;
      _allTxs = [];
      _txLoading = _txFailed = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
    });
    if (source.isLocal) {
      ref.listen(businessBankRevisionProvider, (_, _) => _loadAllTx());
      ref.listen(employeeCanProvider('banks.details'), (_, allowed) {
        if (allowed) {
          _loadAllTx();
        } else {
          _loadGeneration++;
          _allTxs = [];
          _txLoading = _txFailed = false;
        }
      });
    }
    final allAccounts = state.accounts
        .where((_) => !source.isLocal || details)
        .where(_matchesGroup)
        .toList();
    final walletCurrency = state.walletCurrency;
    final ids = allAccounts.map((a) => a.id).toSet();
    final bankTxs = source.isLocal
        ? _allTxs.where((row) => ids.contains(row['bank_account_id']))
        : _allTxs;
    final filteredTxs = bankTxs.where((t) {
      final d = _txDate(t);
      if (d == null) return false;
      return d.month == _selectedMonth && d.year == _selectedYear;
    }).toList();
    double totalBalance = 0;
    for (final a in allAccounts) {
      totalBalance += _inWallet(a.balance, a.currency, walletCurrency, source);
    }
    double totalIncome = 0;
    double totalExpense = 0;
    for (final t in filteredTxs) {
      final amt = _inWallet(_asDouble(t['amount']),
           (t['currency'] ?? walletCurrency).toString(), walletCurrency, source);
      if (_isIn(t)) {
        totalIncome += amt;
      } else {
        totalExpense += amt;
      }
    }
    final dailyTx = <int, double>{};
    for (final t in filteredTxs) {
      final d = _txDate(t);
      if (d == null) continue;
      if (_isIn(t)) continue;
      final amt = _inWallet(_asDouble(t['amount']),
           (t['currency'] ?? walletCurrency).toString(), walletCurrency, source);
      dailyTx[d.day] = (dailyTx[d.day] ?? 0) + amt;
    }
    final txFiltered = _txSearchQuery.isEmpty
        ? filteredTxs
        : filteredTxs
            .where((t) => ((t['description'] ?? '')
                    .toString()
                    .toLowerCase()
                    .contains(_txSearchQuery.toLowerCase()) ||
                (t['tx_type'] ?? '')
                    .toString()
                    .contains(_txSearchQuery)))
            .toList();
    final sortedTxs = List<Map<String, dynamic>>.from(txFiltered)
      ..sort((a, b) {
        final da = _txDate(a);
        final db = _txDate(b);
        if (da == null && db == null) return 0;
        if (da == null) return 1;
        if (db == null) return -1;
        return db.compareTo(da);
      });

    return state.isLoading && allAccounts.isEmpty
        ? const Center(child: DotsLoader())
        : RefreshIndicator(
            color: AppColors.primary,
            backgroundColor: AppColors.surface,
            onRefresh: () async {
              await ref
                  .read(businessBanksProvider.notifier)
                  .load();
              await _loadAllTx();
            },
            child: Builder(
              builder: (context) {
                final l10n = AppLocalizations.of(context);
                return CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                        child: Padding(
                      padding: EdgeInsets.fromLTRB(
                          20,
                          MediaQuery.of(context).padding.top + 8,
                          20,
                          0),
                      child: _buildHeader(
                          context,
                          allAccounts,
                          totalBalance,
                          () => _exportStatement(
                              allAccounts,
                              filteredTxs,
                              totalBalance,
                              totalIncome,
                              totalExpense,
                              dailyTx)),
                    )),
                    SliverToBoxAdapter(
                        child: _buildMonthSelector(context)),
                    SliverToBoxAdapter(
                        child: _buildSummaryCards(
                            context, totalIncome, totalExpense)),
                    // — Reports section —
                    if (totalIncome > 0 || totalExpense > 0) ...[
                      SliverToBoxAdapter(
                          child: Padding(
                        padding:
                            const EdgeInsets.fromLTRB(16, 20, 16, 8),
                        child: _SectionTitle(
                            title: l10n.translate(
                                'incomeVsExpenseComparison'),
                            icon: TwoToneIcons.barChart),
                      )),
                      SliverToBoxAdapter(
                          child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16),
                        child: SizedBox(
                            height: 260,
                            child: _IncomeExpenseBarChart(
                                income: totalIncome,
                                expense: totalExpense)),
                      )),
                    ],
                    if (dailyTx.isNotEmpty) ...[
                      SliverToBoxAdapter(
                          child: Padding(
                        padding:
                            const EdgeInsets.fromLTRB(16, 20, 16, 8),
                        child: _SectionTitle(
                            title:
                                l10n.translate('dailyExpenses'),
                            icon: TwoToneIcons.arrowUp),
                      )),
                      SliverToBoxAdapter(
                          child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16),
                        child: SizedBox(
                            height: 220,
                            child:
                                _DailyLineChart(data: dailyTx)),
                      )),
                    ],
                    // — Accounts section —
                    if (ref.watch(businessBankBalanceReadProvider)) SliverToBoxAdapter(
                        child: Padding(
                      padding:
                           const EdgeInsets.fromLTRB(16, 20, 16, 8),
                      child: _SectionTitle(
                          title: l10n.translate('currencyDistribution'),
                          icon: TwoToneIcons.pieChart),
                    )),
                    if (allAccounts.length > 1 && ref.watch(businessBankBalanceReadProvider))
                      SliverToBoxAdapter(
                          child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16),
                        child: SizedBox(
                            height: 200,
                            child: _CurrencyPieChart(
                                accounts: allAccounts)),
                      )),
                    SliverToBoxAdapter(
                        child: Padding(
                      padding:
                          const EdgeInsets.fromLTRB(16, 20, 16, 8),
                      child: _SectionTitle(
                          title:
                              l10n.translate('bankAccountsTitle'),
                          icon: TwoToneIcons.bank),
                    )),
                    SliverToBoxAdapter(
                        child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16),
                      child: Column(
                          children: allAccounts
                              .map((a) => _AccountTile(account: a))
                              .toList()),
                    )),
                    // — Transactions section —
                    SliverToBoxAdapter(
                        child: Padding(
                      padding:
                          const EdgeInsets.fromLTRB(16, 20, 16, 8),
                      child: _SectionTitle(
                          title:
                              l10n.translate('transactionsTab'),
                          icon: TwoToneIcons.transfer),
                    )),
                    SliverToBoxAdapter(
                        child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16),
                      child: FyonaTextField(
                        onChanged: (v) =>
                            setState(() => _txSearchQuery = v),
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 13),
                            color: AppColors.textPrimary),
                        decoration: InputDecoration(
                          hintText: l10n.translate('searchHint'),
                          hintStyle: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 12),
                              color: AppColors.textDisabled),
                          prefixIcon: const Icon(Icons.search,
                              color: AppColors.textDisabled, size: 20),
                          filled: true,
                          fillColor: AppColors.surfaceVariant,
                          border: OutlineInputBorder(
                              borderRadius:
                                  BorderRadius.circular(10),
                              borderSide: BorderSide.none),
                          contentPadding:
                              const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
                        ),
                      ),
                    )),
                    if (_txLoading && !source.isLocal)
                      const SliverToBoxAdapter(
                          child: Center(
                              child: Padding(
                        padding: EdgeInsets.all(24),
                        child: DotsLoader(),
                      )))
                    else if (_txFailed && sortedTxs.isEmpty)
                      SliverToBoxAdapter(
                        child: TextButton.icon(
                          onPressed: _loadAllTx,
                          icon: const Icon(Icons.refresh_rounded),
                          label: Text(l10n.translate(source.isLocal ? 'txOperationFailed' : 'coreNetworkError')),
                        ),
                      )
                    else if (sortedTxs.isEmpty)
                      SliverToBoxAdapter(
                          child: Center(
                              child: Padding(
                        padding:
                            const EdgeInsets.only(top: 40, bottom: 40),
                        child: Text(
                            l10n.translate('noTransactions'),
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize:
                                    R.fontSize(context, 14),
                                color: AppColors.textDisabled)),
                      )))
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(
                            16, 8, 16, 100),
                        sliver: SliverList.separated(
                          itemCount: sortedTxs.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (ctx, i) =>
                              _TransactionTile(tx: sortedTxs[i]),
                        ),
                      ),
                  ],
                );
              },
            ),
          );
  }

  Widget _buildHeader(
      BuildContext context,
      List<BusinessBankAccount> accounts,
      double totalBalance,
      VoidCallback onExport) {
    final l10n = AppLocalizations.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment(-1.0, -1.0),
          end: Alignment(1.5, 1.5),
          colors: [
            Color(0xFFC01838),
            AppColors.primary,
            Color(0xFF7A1020)
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: AppColors.primary.withAlpha(100),
              blurRadius: 32,
              offset: const Offset(0, 12)),
          BoxShadow(
              color: AppColors.primaryDark.withAlpha(60),
              blurRadius: 48,
              offset: const Offset(0, 24)),
        ],
      ),
      child: Stack(children: [
        Positioned(
            top: -30,
            right: -20,
            child: Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withAlpha(15)))),
        Positioned(
            bottom: -40,
            left: -10,
            child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withAlpha(10)))),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                    color: Colors.white.withAlpha(20),
                    borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.arrow_forward_ios,
                    color: Colors.white, size: 18),
              ),
            ),
            const SizedBox(width: 12),
            AppIconBadge(
                icon: TwoToneIcons.bank.outline,
                size: 44,
                iconSize: 22,
                backgroundColor: Colors.white.withAlpha(20),
                borderColor: Colors.white.withAlpha(30)),
            const SizedBox(width: 14),
            Expanded(
                child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                  Text(
                      isBizCashAccount(widget.bankName)
                          ? l10n.translate('cashAccount')
                          : widget.bankName,
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 16),
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                  const SizedBox(height: 2),
                  Text(
                      l10n.translate('accountsCount',
                          params: {'count': '${accounts.length}'}),
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 11),
                          color: Colors.white.withAlpha(180))),
                ])),
            if ((widget.groupId ?? '').startsWith('link:') && ref.watch(employeeCanProvider('banks.add_delete')))
              IconButton(
                tooltip: l10n.translate('bankLinkUnlink'),
                icon: const Icon(Icons.link_off_rounded,
                    color: Colors.white),
                onPressed: _unlinkAccounts,
              ),
            if (ref.watch(businessBankBalanceReadProvider) && ref.watch(employeeCanProvider('reports.view')) && ref.watch(employeeCanProvider('reports.export'))) IconButton(
              icon: const Icon(Icons.receipt_long,
                  color: Colors.white),
              onPressed: onExport,
            ),
          ]),
          if (ref.watch(businessBankBalanceReadProvider)) const SizedBox(height: 24),
          if (ref.watch(businessBankBalanceReadProvider)) Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Text(l10n.translate('totalBalances'),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 10),
                    color: Colors.white.withAlpha(160))),
            const SizedBox(height: 2),
            Text(fmtNum(totalBalance),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 20),
                    fontWeight: FontWeight.w700,
                    color: Colors.white.withAlpha(220))),
          ]),
        ]),
      ]),
    );
  }

  Widget _buildMonthSelector(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        IconButton(
          onPressed: () => setState(() {
            _selectedMonth--;
            if (_selectedMonth < 1) {
              _selectedMonth = 12;
              _selectedYear--;
            }
          }),
          icon: Icon(Icons.chevron_right,
              color: AppColors.textSecondary),
        ),
        Expanded(
          child: Center(
            child: Text(
                '${_monthName(_selectedMonth)} $_selectedYear',
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 14),
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
          ),
        ),
        IconButton(
          onPressed: () => setState(() {
            _selectedMonth++;
            if (_selectedMonth > 12) {
              _selectedMonth = 1;
              _selectedYear++;
            }
          }),
          icon: Icon(Icons.chevron_left,
              color: AppColors.textSecondary),
        ),
      ]),
    );
  }

  Widget _buildSummaryCards(
      BuildContext context, double income, double expense) {
    final l10n = AppLocalizations.of(context);
    final net = income - expense;
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(children: [
        _SummaryMini(
            label: l10n.translate('incomeLabel'),
            amount: income,
            color: const Color(0xFF2E7D32),
            icon: TwoToneIcons.arrowDown),
        const SizedBox(width: 8),
        _SummaryMini(
            label: l10n.translate('expenseLabel'),
            amount: expense,
            color: const Color(0xFFC62828),
            icon: TwoToneIcons.arrowUp),
        const SizedBox(width: 8),
        _SummaryMini(
            label: l10n.translate('net'),
            amount: net,
            color: net >= 0 ? AppColors.primary : AppColors.danger,
            icon: TwoToneIcons.money),
      ]),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  EXPORT OPTIONS BOTTOM SHEET
// ════════════════════════════════════════════════════════════
class _ExportOptionsSheet extends StatefulWidget {
  final String bankName;
  final String period;
  const _ExportOptionsSheet(
      {required this.bankName, required this.period});
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
      padding: EdgeInsets.fromLTRB(
          20, 12, 20, MediaQuery.of(context).padding.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 16),
          Row(children: [
            const Icon(Icons.picture_as_pdf,
                color: AppColors.primary, size: 22),
            const SizedBox(width: 8),
            Text(l10n.translate('exportPdf'),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 16),
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
            const Spacer(),
            Text(widget.period,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 12),
                    color: AppColors.textSecondary)),
          ]),
          const SizedBox(height: 4),
          Text(
              isBizCashAccount(widget.bankName)
                  ? l10n.translate('cashAccount')
                  : widget.bankName,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 12),
                  color: AppColors.textDisabled)),
          const SizedBox(height: 16),
          Divider(color: AppColors.border, height: 1),
          const SizedBox(height: 8),
          _OptionToggle(
              label: l10n.translate('chartsOption'),
              value: _charts,
              onChanged: (v) => setState(() => _charts = v)),
          _OptionToggle(
              label: l10n.translate('bankAccountsTitle'),
              value: _accounts,
              onChanged: (v) => setState(() => _accounts = v)),
          _OptionToggle(
              label: l10n.translate('transactionsTab'),
              value: _transactions,
              onChanged: (v) =>
                  setState(() => _transactions = v)),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context, {
                'charts': _charts,
                'accounts': _accounts,
                'transactions': _transactions
              }),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding:
                    const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: Text(l10n.translate('exportReport'),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 14),
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
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
  const _OptionToggle(
      {required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Icon(
            value
                ? Icons.check_box
                : Icons.check_box_outline_blank,
            color: value
                ? AppColors.primary
                : AppColors.textDisabled,
            size: 22),
        const SizedBox(width: 10),
        Text(label,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 13),
                color: AppColors.textPrimary)),
        const Spacer(),
      ]),
    );
  }
}

class _SummaryMini extends StatelessWidget {
  final String label;
  final double amount;
  final Color color;
  final TwoToneIconData icon;
  const _SummaryMini(
      {required this.label,
      required this.amount,
      required this.color,
      required this.icon});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
            color: AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(12)),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            TwoToneIcon(data: icon, size: 14, outlineColor: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 10),
                      color: AppColors.textSecondary)),
            ),
          ]),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(fmtNum(amount),
                maxLines: 1,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 14),
                    fontWeight: FontWeight.w700,
                    color: color)),
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
        AppIconBadge(
            icon: icon!.outline,
            size: 28,
            iconSize: 14,
            backgroundColor: AppColors.primary.withAlpha(20),
            borderColor: AppColors.primary.withAlpha(40)),
        const SizedBox(width: 8),
      ],
      Text(title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 14),
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary)),
    ]);
  }
}

// ════════════════════════════════════════════════════════════
//  CHARTS (fl_chart for on-screen)
// ════════════════════════════════════════════════════════════
class _CurrencyPieChart extends StatelessWidget {
  final List<BusinessBankAccount> accounts;
  const _CurrencyPieChart({required this.accounts});

  @override
  Widget build(BuildContext context) {
    final colors = [
      AppColors.primary,
      AppColors.primaryDark,
      const Color(0xFFB82040),
      const Color(0xFFD4A373),
      const Color(0xFF6C9BCF),
      const Color(0xFF77DD77)
    ];
    final sections = <PieChartSectionData>[];
    for (int i = 0; i < accounts.length; i++) {
      final a = accounts[i];
      sections.add(PieChartSectionData(
        value: a.balance.abs(),
        title: '${a.currency}\n${fmtNum(a.balance)}',
        color: colors[i % colors.length],
        radius: 110,
        titleStyle: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Colors.white),
      ));
    }
    return PieChart(PieChartData(
        sections: sections, centerSpaceRadius: 16, sectionsSpace: 3));
  }
}

class _IncomeExpenseBarChart extends StatelessWidget {
  final double income;
  final double expense;
  const _IncomeExpenseBarChart(
      {required this.income, required this.expense});

  @override
  Widget build(BuildContext context) {
    return BarChart(BarChartData(
      alignment: BarChartAlignment.spaceEvenly,
      barGroups: [
        BarChartGroupData(x: 0, barRods: [
          BarChartRodData(
              toY: income,
              color: const Color(0xFF2E7D32),
              width: 60,
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(6))),
        ]),
        BarChartGroupData(x: 1, barRods: [
          BarChartRodData(
              toY: expense,
              color: const Color(0xFFC62828),
              width: 60,
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(6))),
        ]),
      ],
      titlesData: FlTitlesData(
        bottomTitles: AxisTitles(
            sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (v, _) {
                  final l10n = AppLocalizations.of(context);
                  final labels = [
                    l10n.translate('totalIncome'),
                    l10n.translate('totalExpenses')
                  ];
                  return Text(labels[v.toInt()],
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 12,
                          color: AppColors.textSecondary));
                })),
        leftTitles: AxisTitles(
            sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 45,
                getTitlesWidget: (v, _) {
                  return Text(fmtNum(v),
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 10,
                          color: AppColors.textDisabled));
                })),
        topTitles:
            AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles:
            AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: income > 0 ? income / 4 : 1000),
      borderData: FlBorderData(show: false),
    ));
  }
}

class _DailyLineChart extends StatelessWidget {
  final Map<int, double> data;
  const _DailyLineChart({required this.data});

  @override
  Widget build(BuildContext context) {
    final spots = data.entries
        .map((e) => FlSpot(e.key.toDouble(), e.value))
        .toList()
      ..sort((a, b) => a.x.compareTo(b.x));
    return LineChart(LineChartData(
      gridData: FlGridData(show: true, drawVerticalLine: false),
      titlesData: FlTitlesData(
        bottomTitles: AxisTitles(
            sideTitles: SideTitles(
          showTitles: true,
          interval: 5,
          getTitlesWidget: (v, _) => Text('${v.toInt()}',
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 9,
                  color: AppColors.textDisabled)),
        )),
        leftTitles: AxisTitles(
            sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 35,
                getTitlesWidget: (v, _) => Text(fmtNum(v),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 9,
                        color: AppColors.textDisabled)))),
        topTitles:
            AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles:
            AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      borderData: FlBorderData(show: false),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: true,
          barWidth: 2.5,
          color: AppColors.primary,
          dotData: FlDotData(
              show: true,
              getDotPainter: (spot, _, __, ___) => FlDotCirclePainter(
                  radius: 3,
                  color: AppColors.primary,
                  strokeWidth: 1.5,
                  strokeColor: Colors.white)),
          belowBarData: BarAreaData(
              show: true, color: AppColors.primary.withAlpha(30)),
        ),
      ],
    ));
  }
}

class _AccountTile extends ConsumerWidget {
  final BusinessBankAccount account;
  const _AccountTile({required this.account});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final typeLabel = account.accountType == 'savings'
        ? l10n.translate('accountTypeSavings')
        : l10n.translate('accountTypeChecking');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(20),
              borderRadius: BorderRadius.circular(10)),
          alignment: Alignment.center,
          child: Text(
              currencyFlagEmoji(account.currency).isEmpty
                  ? account.currency
                  : currencyFlagEmoji(account.currency),
              style: const TextStyle(fontSize: 22)),
        ),
        const SizedBox(width: 12),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${account.currency} — $typeLabel',
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 13),
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary)),
        ])),
        if (ref.watch(businessBankBalanceReadProvider)) Flexible(
            child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerEnd,
                child: Text(fmtNum(account.balance),
                    maxLines: 1,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 14),
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary)))),
      ]),
    );
  }
}

class _TransactionTile extends StatelessWidget {
  final Map<String, dynamic> tx;
  const _TransactionTile({required this.tx});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final type = (tx['tx_type'] ?? '').toString();
    final visual = BankTransactionVisual(type);
    final isIn = visual.isIn;
    final color = visual.color;
    final icon = visual.icon;
    final label = visual.label(l10n);
    double amount = 0;
    if (tx['amount'] is num) {
      amount = (tx['amount'] as num).toDouble();
    } else {
      amount = double.tryParse(tx['amount']?.toString() ?? '') ?? 0;
    }
    DateTime? date;
    try {
      final raw = tx['date']?.toString();
      if (raw != null && raw.isNotEmpty) date = DateTime.parse(raw);
    } catch (_) {}

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
              color: color.withAlpha(25),
              borderRadius: BorderRadius.circular(10)),
          child: TwoToneIcon(data: icon, size: 16, outlineColor: color),
        ),
        const SizedBox(width: 12),
        Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(label,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
              Text((tx['description'] ?? '').toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 11),
                      color: AppColors.textSecondary)),
            ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(
              '${isIn ? '+' : '-'}${fmtNum(amount.abs())} ${currencySymbol((tx['currency'] ?? '').toString())}',
              textDirection: TextDirection.ltr,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 13),
                  fontWeight: FontWeight.w700,
                  color: color)),
          if (date != null)
            Text(DateFormat('dd/MM').format(date),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 10),
                    color: AppColors.textDisabled)),
        ]),
      ]),
    );
  }
}
