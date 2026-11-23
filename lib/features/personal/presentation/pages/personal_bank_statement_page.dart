import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart' show fmtNum;
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'package:intl/intl.dart';

class PersonalBankStatementPage extends ConsumerStatefulWidget {
  const PersonalBankStatementPage({super.key});
  @override
  ConsumerState<PersonalBankStatementPage> createState() => _PersonalBankStatementPageState();
}

class _PersonalBankStatementPageState extends ConsumerState<PersonalBankStatementPage> {
  String? _selectedTab;
  int _month = DateTime.now().month;
  int _year = DateTime.now().year;

  String _monthName(int month) => AppLocalizations.of(context).translate('month$month');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { ref.read(personalFinanceProvider.notifier).loadTransactions(month: _month, year: _year); });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(personalFinanceProvider);
    final accounts = state.bankAccounts;
    final txs = state.transactions.where((t) {
      if (t.date == null) return false;
      if (t.date!.month != _month || t.date!.year != _year) return false;
      return true;
    }).toList();
    final selectedAccounts = _selectedTab == null
        ? accounts
        : accounts.where((a) => a.id == _selectedTab).toList();
    final engine = ref.read(currencyEngineProvider);
    final walletCurrency = state.walletCurrency;
    double _convert(PersonalTransaction t) {
      if (t.currency == walletCurrency) return t.amount;
      final converted = engine.convert(t.amount, t.currency, walletCurrency);
      return converted != 0 ? converted : t.amount;
    }
    final totalIn = txs.where((t) => t.type == 'income' || t.type == 'transfer_in').fold(0.0, (s, t) => s + _convert(t));
    final totalOut = txs.where((t) => t.type == 'expense' || t.type == 'transfer_out').fold(0.0, (s, t) => s + _convert(t));
    final closing = ref.read(personalFinanceProvider.notifier).convertAccountsToWallet(selectedAccounts);
    final opening = closing - totalIn + totalOut;

    return state.isLoading
        ? Center(child: DotsLoader())
        : ListView(
            children: [
              _buildTabBar(accounts),
              _buildFilterBar(),
              _buildSummaryRow(opening, totalIn, totalOut, closing),
              Divider(height: 1, color: AppColors.border),
              if (txs.isEmpty)
                Padding(
                  padding: EdgeInsets.all(40),
                  child: Text(
                    l10n.translate('noTransactionsInPeriod'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textSecondary),
                  ),
                )
              else
                Padding(
                  padding: EdgeInsets.all(16),
                  child: _buildTransactionTable(txs, opening),
                ),
            ],
          );
  }

  Widget _buildTabBar(List<PersonalBankAccount> accounts) {
    final l10n = AppLocalizations.of(context);
    final tabs = [(l10n.translate('allAccounts'), null), for (final a in accounts) (a.bankName, a.id)];
    return Container(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border))),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: tabs.map((t) {
            final active = t.$2 == _selectedTab;
            return GestureDetector(
              onTap: () {
                setState(() => _selectedTab = t.$2);
                ref.read(personalFinanceProvider.notifier).loadTransactions(accountId: t.$2, month: _month, year: _year);
              },
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(width: 2, color: active ? AppColors.primary : Colors.transparent)),
                ),
                child: Text(
                  t.$1,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    fontWeight: active ? FontWeight.bold : FontWeight.normal,
                    color: active ? AppColors.primary : AppColors.textSecondary,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildFilterBar() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border), bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: _month,
              dropdownColor: AppColors.surface,
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textPrimary),
              items: List.generate(12, (i) => DropdownMenuItem(value: i + 1, child: Text(_monthName(i + 1)))),
              onChanged: (v) {
                setState(() => _month = v!);
                ref.read(personalFinanceProvider.notifier).loadTransactions(accountId: _selectedTab, month: _month, year: _year);
              },
            ),
          ),
          SizedBox(width: 12),
          DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: _year,
              dropdownColor: AppColors.surface,
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textPrimary),
              items: List.generate(8, (i) => DropdownMenuItem(value: 2023 + i, child: Text('${2023 + i}'))),
              onChanged: (v) {
                setState(() => _year = v!);
                ref.read(personalFinanceProvider.notifier).loadTransactions(accountId: _selectedTab, month: _month, year: _year);
              },
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(double opening, double totalIn, double totalOut, double closing) {
    final l10n = AppLocalizations.of(context);
    final cards = [
      (l10n.translate('openingBalance'), opening, AppColors.primary),
      (l10n.translate('totalIncome'), totalIn, AppColors.chartGreen),
      (l10n.translate('totalExpense'), totalOut, AppColors.chartRed),
      (l10n.translate('closingBalance'), closing, AppColors.primary),
    ];
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: cards.map((c) {
          return Expanded(
            child: Container(
              margin: EdgeInsets.symmetric(horizontal: 2),
              padding: EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                children: [
                  Text(c.$1, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.textSecondary)),
                  SizedBox(height: 4),
                  Text(fmtNum(c.$2),
                    style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.bold, color: c.$3)),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildTransactionTable(List<PersonalTransaction> txs, double opening) {
    final l10n = AppLocalizations.of(context);
    double running = opening;
    return Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.surfaceVariant,
            borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Row(
            children: [
              Expanded(flex: 1, child: Text(l10n.translate('date'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), fontWeight: FontWeight.bold, color: AppColors.textSecondary))),
              Expanded(flex: 2, child: Text(l10n.translate('description'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), fontWeight: FontWeight.bold, color: AppColors.textSecondary))),
              Expanded(flex: 1, child: Text(l10n.translate('incoming'), textAlign: TextAlign.center, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), fontWeight: FontWeight.bold, color: AppColors.textSecondary))),
              Expanded(flex: 1, child: Text(l10n.translate('outgoing'), textAlign: TextAlign.center, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), fontWeight: FontWeight.bold, color: AppColors.textSecondary))),
              Expanded(flex: 1, child: Text(l10n.translate('balance'), textAlign: TextAlign.center, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), fontWeight: FontWeight.bold, color: AppColors.textSecondary))),
            ],
          ),
        ),
        ...txs.map((t) {
          final isIn = t.type == 'income' || t.type == 'transfer_in';
          final engine = ref.read(currencyEngineProvider);
          final walletCurrency = ref.read(personalFinanceProvider).walletCurrency;
          double amt = t.amount;
          if (t.currency != walletCurrency) {
            final converted = engine.convert(t.amount, t.currency, walletCurrency);
            if (converted != 0) amt = converted;
          }
          if (isIn) { running += amt; } else { running -= amt; }
          final idx = txs.indexOf(t);
          final isOdd = idx % 2 == 0;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: isOdd ? Colors.white.withAlpha(8) : null,
            child: Row(
              children: [
                Expanded(flex: 1, child: Text(t.date != null ? '${t.date!.day}/${t.date!.month}' : '-',
                  style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textPrimary))),
                Expanded(flex: 2, child: Text(t.description ?? t.category,
                  style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textPrimary))),
                Expanded(flex: 1, child: Text(isIn ? fmtNum(t.amount) : '-',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.success))),
                Expanded(flex: 1, child: Text(!isIn ? fmtNum(t.amount) : '-',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.danger))),
                Expanded(flex: 1, child: Text(fmtNum(running),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.bold, color: AppColors.textPrimary))),
              ],
            ),
          );
        }),
      ],
    );
  }
}
