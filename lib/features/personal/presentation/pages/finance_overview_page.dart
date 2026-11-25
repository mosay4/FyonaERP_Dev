import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../../../../shared/widgets/receipt/receipt.dart';
import '../../data/models/personal_models.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../providers/personal_providers.dart';
import '../providers/receipt_design_provider.dart';
import '../../../../core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';
import '../../../../core/utils/time_format.dart';

class FinanceOverviewPage extends ConsumerStatefulWidget {
  const FinanceOverviewPage({super.key});
  @override
  ConsumerState<FinanceOverviewPage> createState() => _FinanceOverviewPageState();
}

class _FinanceOverviewPageState extends ConsumerState<FinanceOverviewPage> {
  String? _selectedTab;
  int _month = DateTime.now().month;
  int _year = DateTime.now().year;
  bool _includeGoals = true;
  bool _includeAi = true;

  String _monthName(int month) => AppLocalizations.of(context).translate('month$month');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { ref.read(personalFinanceProvider.notifier).loadTransactions(month: _month, year: _year); });
  }

  void _exportOverview() {
    final l10n = AppLocalizations.of(context);
    final preset = ref.read(personalReceiptDesignProvider.notifier).getPreset('report');
    final state = ref.read(personalFinanceProvider);
    final accounts = state.bankAccounts;
    final walletCurrency = state.walletCurrency;
    final engine = ref.read(currencyEngineProvider);
    final txs = state.transactions.where((t) {
      if (t.date == null) return false;
      if (t.date!.month != _month || t.date!.year != _year) return false;
      return true;
    }).toList();
    final selectedAccounts = _selectedTab == null ? accounts : accounts.where((a) => a.id == _selectedTab).toList();
    final totalIn = txs.where((t) => t.type == 'income').fold(0.0, (s, t) => s + (engine.convert(t.amount, t.currency, walletCurrency)));
    final totalOut = txs.where((t) => t.type == 'expense').fold(0.0, (s, t) => s + (engine.convert(t.amount, t.currency, walletCurrency)));
    final closingBalance = selectedAccounts.fold(0.0, (s, a) => s + (engine.convert(a.balance, a.currency, walletCurrency)));
    final openingBalance = closingBalance - totalIn + totalOut;
    ReceiptModal.show(context, ReceiptData(
      title: l10n.translate('comprehensiveFinancialOverview'),
      amount: closingBalance,
       currencySymbol: currencySymbol(walletCurrency),
       dateTime: formatDateTimeDisplay(DateTime.now()),
       details: [
         ReceiptDetail(label: l10n.translate('openingBalance'), value: '${fmtNum(openingBalance)} ${currencySymbol(walletCurrency)}'),
         ReceiptDetail(label: l10n.translate('totalIncome'), value: '${fmtNum(totalIn)} ${currencySymbol(walletCurrency)}'),
         ReceiptDetail(label: l10n.translate('totalExpense'), value: '${fmtNum(totalOut)} ${currencySymbol(walletCurrency)}'),
      ],
    ), preset: preset);
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
    final selectedAccounts = _selectedTab == null ? accounts : accounts.where((a) => a.id == _selectedTab).toList();
    final engine = ref.read(currencyEngineProvider);
    final walletCurrency = state.walletCurrency;
    final totalIn = txs.where((t) => t.type == 'income').fold(0.0, (s, t) => s + (engine.convert(t.amount, t.currency, walletCurrency)));
    final totalOut = txs.where((t) => t.type == 'expense').fold(0.0, (s, t) => s + (engine.convert(t.amount, t.currency, walletCurrency)));
    final closing = selectedAccounts.fold(0.0, (s, a) => s + (engine.convert(a.balance, a.currency, walletCurrency)));
    final opening = closing - totalIn + totalOut;

    return state.isLoading
        ? const Center(child: DotsLoader())
        : ListView(
          children: [
            _buildTabBar(accounts, l10n),
            _buildFilterRow(),
            _buildOptions(),
            _buildSummaryRow(opening, totalIn, totalOut, closing),
             Divider(height: 1, color: AppColors.border),
            if (txs.isEmpty)
              Padding(
                padding: EdgeInsets.all(R.spacing(context, 40)),
                child: Text(l10n.translate('noTransactionsInPeriod'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), color: AppColors.textSecondary)),
              )
            else
              Padding(
                padding: R.padding(context),
                child: _buildTransactionTable(txs, opening, accounts),
              ),
          ],
        );
  }

  Widget _buildTabBar(List<PersonalBankAccount> accounts, AppLocalizations l10n) {
    final tabIds = <String?>[null, for (final a in accounts) a.id];
    return Container(
      decoration:  BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border))),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: tabIds.map((aid) {
            final label = aid == null ? l10n.translate('allAccounts') : (() { final a = accounts.firstWhere((a) => a.id == aid); return isCashAccount(a.bankName) ? cashDisplayName() : a.bankName; })();
            final active = aid == _selectedTab;
            return GestureDetector(
              onTap: () {
                setState(() => _selectedTab = aid);
                ref.read(personalFinanceProvider.notifier).loadTransactions(accountId: aid, month: _month, year: _year);
              },
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: R.spacing(context, 18), vertical: R.spacing(context, 12)),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(width: 2, color: active ? AppColors.primary : Colors.transparent)),
                ),
                child: Text(label,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.font(context),
                    fontWeight: active ? FontWeight.bold : FontWeight.normal,
                    color: active ? AppColors.primary : AppColors.textSecondary,
                  )),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildFilterRow() {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: R.padding(context),
      decoration:  BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border), bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(children: [
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _month,
                  dropdownColor: AppColors.surface,
                  style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), color: AppColors.textPrimary),
                  items: List.generate(12, (i) => DropdownMenuItem(value: i + 1, child: Text(_monthName(i + 1)))),
                  onChanged: (v) {
                    setState(() => _month = v!);
                    ref.read(personalFinanceProvider.notifier).loadTransactions(accountId: _selectedTab, month: _month, year: _year);
                  },
                ),
              ),
              SizedBox(width: R.spacing(context, AppSpacing.sm)),
              DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _year,
                  dropdownColor: AppColors.surface,
                  style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), color: AppColors.textPrimary),
                  items: List.generate(8, (i) => DropdownMenuItem(value: 2023 + i, child: Text('${2023 + i}'))),
                  onChanged: (v) {
                    setState(() => _year = v!);
                    ref.read(personalFinanceProvider.notifier).loadTransactions(accountId: _selectedTab, month: _month, year: _year);
                  },
                ),
              ),
            ]),
          ),
        ),
        const Spacer(),
        IconButton(icon: Icon(Icons.receipt_long, color: AppColors.primary), onPressed: _exportOverview),
        IconButton(icon: TwoToneIcon(data: TwoToneIcons.search, outlineColor: AppColors.primary), onPressed: _showSearchDialog),
        GestureDetector(
          onTap: _pickImage,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(8)),
            child: Text('+ ${l10n.translate('addImage')}', style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'body_small'), color: AppColors.textSecondary)),
          ),
        ),
      ]),
    );
  }

  Widget _buildOptions() {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: R.spacing(context, 16), vertical: R.spacing(context, 4)),
      color: AppColors.surface,
      child: Row(children: [
        Expanded(
          child: Row(children: [
            SizedBox(
              height: 24, width: 24,
              child: Checkbox(
                value: _includeGoals,
                onChanged: (v) => setState(() => _includeGoals = v!),
                fillColor: WidgetStateProperty.all(AppColors.primary),
                checkColor: Colors.white,
                side:  BorderSide(color: AppColors.border),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
              ),
            ),
            SizedBox(width: R.spacing(context, AppSpacing.xs)),
            Flexible(child: Text(l10n.translate('showGoals'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'body_small'), color: AppColors.textPrimary))),
          ]),
        ),
        SizedBox(width: R.spacing(context, AppSpacing.lg)),
        Expanded(
          child: Row(children: [
            SizedBox(
              height: 24, width: 24,
              child: Checkbox(
                value: _includeAi,
                onChanged: (v) => setState(() => _includeAi = v!),
                fillColor: WidgetStateProperty.all(AppColors.primary),
                checkColor: Colors.white,
                side:  BorderSide(color: AppColors.border),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
              ),
            ),
            SizedBox(width: R.spacing(context, AppSpacing.xs)),
            Flexible(child: Text(l10n.translate('showSmartRecommendations'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'body_small'), color: AppColors.textPrimary))),
          ]),
        ),
      ]),
    );
  }

  Widget _buildSummaryRow(double opening, double totalIn, double totalOut, double closing) {
    final l10n = AppLocalizations.of(context);
    final cards = [
      (l10n.translate('openingBalance'), opening, AppColors.primary),
      (l10n.translate('currentBalance'), totalIn, AppColors.success),
      (l10n.translate('totalSpent'), totalOut, AppColors.danger),
      (l10n.translate('closingBalance'), closing, AppColors.primary),
    ];
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: R.spacing(context, 16), vertical: R.spacing(context, 12)),
      child: Row(children: cards.map((c) {
        return Expanded(
          child: Container(
            margin: EdgeInsets.symmetric(horizontal: R.spacing(context, 2)),
            padding: EdgeInsets.symmetric(vertical: R.spacing(context, 14)),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(R.radiusValue(context, 12)),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(children: [
              Text(c.$1, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'body_small'), color: AppColors.textSecondary)),
              SizedBox(height: R.spacing(context, 4)),
              Text('${fmtNum(c.$2)} SAR',
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'title_small'), fontWeight: FontWeight.bold, color: c.$3)),
            ]),
          ),
        );
      }).toList()),
    );
  }

  Widget _buildTransactionTable(List<PersonalTransaction> txs, double opening, List<PersonalBankAccount> accounts) {
    final l10n = AppLocalizations.of(context);
    final engine = ref.read(currencyEngineProvider);
    final walletCurrency = ref.read(personalFinanceProvider).walletCurrency;
    double running = opening;
    return Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: R.spacing(context, 12), vertical: R.spacing(context, 8)),
          decoration:  BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.vertical(top: Radius.circular(8))),
          child: Row(children: [
            Expanded(flex: 1, child: Text(l10n.translate('date'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'body_small'), fontWeight: FontWeight.bold, color: AppColors.textSecondary))),
            Expanded(flex: 2, child: Text(l10n.translate('description'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'body_small'), fontWeight: FontWeight.bold, color: AppColors.textSecondary))),
            Expanded(flex: 1, child: Text(l10n.translate('incoming'), textAlign: TextAlign.center, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'body_small'), fontWeight: FontWeight.bold, color: AppColors.textSecondary))),
            Expanded(flex: 1, child: Text(l10n.translate('outgoing'), textAlign: TextAlign.center, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'body_small'), fontWeight: FontWeight.bold, color: AppColors.textSecondary))),
            Expanded(flex: 1, child: Text(l10n.translate('balance'), textAlign: TextAlign.center, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'body_small'), fontWeight: FontWeight.bold, color: AppColors.textSecondary))),
          ]),
        ),
        ...txs.map((t) {
          final isIn = t.type == 'income';
          if (isIn) { running += engine.convert(t.amount, t.currency, walletCurrency); } else { running -= engine.convert(t.amount, t.currency, walletCurrency); }
          final isOdd = txs.indexOf(t) % 2 == 0;
          String desc = t.description ?? t.category;
          if (_selectedTab == null) {
            final acc = t.accountId == null ? null : accounts.where((a) => a.id == t.accountId).firstOrNull;
            if (acc != null) desc = '$desc (${acc.bankName})';
          }
          return Container(
            padding: EdgeInsets.symmetric(horizontal: R.spacing(context, 12), vertical: R.spacing(context, 6)),
            color: isOdd ? Colors.white.withAlpha(8) : null,
            child: Row(children: [
              Expanded(flex: 1, child: Text(t.date != null ? '${t.date!.day}/${t.date!.month}/${t.date!.year}' : '-', style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), color: AppColors.textPrimary))),
              Expanded(flex: 2, child: Text(desc, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), color: AppColors.textPrimary))),
              Expanded(flex: 1, child: Text(isIn ? fmtNum(t.amount) : '�', textAlign: TextAlign.center, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), color: AppColors.success))),
              Expanded(flex: 1, child: Text(!isIn ? fmtNum(t.amount) : '�', textAlign: TextAlign.center, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), color: AppColors.danger))),
              Expanded(flex: 1, child: Text(fmtNum(running), textAlign: TextAlign.center, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), fontWeight: FontWeight.bold, color: AppColors.textPrimary))),
            ]),
          );
        }),
      ],
    );
  }

  Future<void> _pickImage() async {
    final l10n = AppLocalizations.of(context);
    final result = await FilePicker.pickFiles(type: FileType.image);
    if (result != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.translate('imagePicked', params: {'fileName': result.files.first.name}), style: const TextStyle(fontFamily: 'Cairo'))),
      );
    }
  }

  Future<void> _showSearchDialog() async {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController();
    final state = ref.read(personalFinanceProvider);
    final txs = state.transactions.where((t) {
      if (t.date == null) return false;
      if (t.date!.month != _month || t.date!.year != _year) return false;
      return true;
    }).toList();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(l10n.translate('searchInTransactions'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary)),
          content: StatefulBuilder(
            builder: (ctx, setDialogState) {
              final query = controller.text.trim().toLowerCase();
              final filtered = query.isEmpty ? txs : txs.where((t) =>
                (t.description ?? '').toLowerCase().contains(query) ||
                t.category.toLowerCase().contains(query)
              ).toList();
              return SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FyonaTextField(
                      controller: controller,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: l10n.translate('searchHint'),
                        filled: true,
                        fillColor: AppColors.surfaceVariant,
                        border: OutlineInputBorder(borderRadius: AppRadius.inputBorder),
                        suffixIcon: IconButton(
                          icon: TwoToneIcon(data: TwoToneIcons.search),
                          onPressed: () => setDialogState(() {}),
                        ),
                      ),
                      style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                    SizedBox(height: 12),
                    if (filtered.isEmpty && query.isNotEmpty)
                      Text(l10n.translate('noResultsFound'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary))
                    else
                      SizedBox(
                        height: 300,
                        child: ListView(
                          shrinkWrap: true,
                          children: filtered.map((t) => ListTile(
                            dense: true,
                            title: Text(t.category, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textPrimary)),
                            subtitle: t.description != null ? Text(t.description!, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.textSecondary)) : null,
                            trailing: Text('${fmtNum(t.amount)} SAR', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w600, color: t.type == 'income' ? AppColors.success : AppColors.danger)),
                          )).toList(),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.translate('close'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
            ),
          ],
        ),
    );
    controller.dispose();
  }
}
