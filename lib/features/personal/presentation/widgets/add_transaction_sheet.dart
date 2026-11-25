import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models/personal_models.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../shared/widgets/currency_selector.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/amount_input_formatter.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../providers/personal_providers.dart';
import '../providers/receipt_design_provider.dart';
import '../../../../shared/widgets/receipt/receipt_modal.dart';
import '../../../../shared/widgets/receipt/receipt_data.dart';
import '../../di/personal_providers.dart' show personalFinanceServiceProvider;
import '../../domain/services/personal_finance_service.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';
import 'personal_account_choice.dart';
import '../../../../shared/widgets/account_type_bar.dart' show accountTypeLabel;
import '../../../../core/utils/time_format.dart';
import '../../../../shared/widgets/money_text.dart';

const _incomeCategories = ['مرتب', 'بيع', 'هدية', 'إيجار', 'استثمار', 'عمولة', 'عمل حر', 'مكافأة', 'أخرى'];
const _expenseCategories = ['طعام', 'مواصلات', 'اتصالات', 'صحة', 'تعليم', 'ترفيه', 'إيجار', 'فواتير', 'أخرى'];

/// accountId null = cash / wallet (no bank account) - the backend maps it to the كاش account.

bool _isCashName(String name) => name == 'كاش' || name == 'Cash';

/// Re-validates a budget+category selection against FRESH budget state at
/// submit time. A budget/category deleted or recreated after the sheet
/// opened (or prefilled with a stale object) would otherwise stage a
/// transaction linked to dead ids: money moves, but no budget shows it
/// (silent loss). Returns null when the selection is still valid, otherwise
/// the localization key of the message to show.
String? validateBudgetSelection({
  required List<PersonalBudget> budgets,
  required String? budgetId,
  required String? categoryId,
}) {
  if (budgetId == null || budgetId.isEmpty) return null; // plain expense
  PersonalBudget? fresh;
  for (final b in budgets) {
    if (b.id == budgetId) {
      fresh = b;
      break;
    }
  }
  if (fresh == null) return 'txBudgetGone';
  if (categoryId != null && categoryId.isNotEmpty) {
    final alive = fresh.categories.any((c) => c.id == categoryId);
    if (!alive) return 'txBudgetCategoryGone';
  }
  return null;
}

void showAddTransactionSheet(
  BuildContext context, {
  required String initialType,
  String? prefillAccountId,
  PersonalBudget? prefillBudget,
  BudgetCategory? prefillBudgetCategory,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _AddTransactionSheet(
      initialType: initialType,
      prefillAccountId: prefillAccountId,
      prefillBudget: prefillBudget,
      prefillBudgetCategory: prefillBudgetCategory,
      parentContext: context,
    ),
  );
}

class _AddTransactionSheet extends ConsumerStatefulWidget {
  final String initialType;
  final String? prefillAccountId;
  final PersonalBudget? prefillBudget;
  final BudgetCategory? prefillBudgetCategory;
  /// The caller context (stays alive after the sheet pops) — used to show
  /// the budget-withdrawal receipt on top of the underlying page.
  final BuildContext parentContext;

  const _AddTransactionSheet({
    required this.initialType,
    this.prefillAccountId,
    this.prefillBudget,
    this.prefillBudgetCategory,
    required this.parentContext,
  });

  @override
  ConsumerState<_AddTransactionSheet> createState() => _AddTransactionSheetState();
}

class _AddTransactionSheetState extends ConsumerState<_AddTransactionSheet> {
  late String _formType;
  final _amountCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  String? _selCategory;
  String? _payMethod; // 'cash' | 'bank'
  String? _selBankName; // bank name only (no currency shown)
  String? _selCurrency; // a currency of the selected bank
  // The exact bank account picked. A bank can hold the same currency twice
  // (جاري + توفير), so bank + currency alone is ambiguous.
  String? _selAccountId;
  bool _saving = false;
  PersonalBudget? _selectedBudget;
  BudgetCategory? _selectedBudgetCategory;
  late final String _opId;

  @override
  void initState() {
    super.initState();
    // One idempotency key per sheet session: every tap/retry of THIS form
    // shares it, so the backend executes it exactly once.
    _opId = ref.read(personalFinanceServiceProvider).newOperationId();
    _formType = widget.initialType;
    if (widget.prefillBudget != null) {
      _selectedBudget = widget.prefillBudget;
      _selectedBudgetCategory = widget.prefillBudgetCategory;
    }
    final accounts = ref.read(personalFinanceProvider).bankAccounts;
    final target = widget.prefillAccountId != null
        ? accounts.where((a) => a.id == widget.prefillAccountId).firstOrNull
        : null;
    if (target != null && !_isCashName(target.bankName)) {
      _payMethod = 'bank';
      _selBankName = target.bankName;
      _selCurrency = target.currency;
      _selAccountId = target.id;
    } else if (target != null) {
      _payMethod = 'cash';
    }
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  List<String> _currenciesFor(List<PersonalBankAccount> accounts, String bankName) =>
      [for (final a in accounts) if (a.bankName == bankName) a.currency];

  /// Canonical cash rows: one per currency bucket with summed balances, so
  /// duplicate mirror rows can never offer a twice-listed or phantom-zero
  /// currency here — and the resolved id is always the visible row.
  List<PersonalBankAccount> _canonicalCash(List<PersonalBankAccount> accounts) =>
      PersonalFinanceService.canonicalCashAccounts(accounts);

  String _cashCurrency(List<PersonalBankAccount> accounts) {
    if (_selCurrency != null && _payMethod == 'cash') return _selCurrency!;
    final cash = _canonicalCash(accounts);
    if (cash.isNotEmpty) return cash.first.currency;
    return 'USD';
  }

  List<String> _cashCurrencies(List<PersonalBankAccount> accounts) {
    return [for (final a in _canonicalCash(accounts)) a.currency];
  }

  String _selectedCurrency(List<PersonalBankAccount> accounts) {
    if (_payMethod == 'cash') return _cashCurrency(accounts);
    return _selCurrency ?? 'USD';
  }

  /// The bank account UUID matching the selected bank + currency, or null for cash.
  String? _resolveAccountId(List<PersonalBankAccount> accounts) {
    if (_payMethod == 'cash') {
      final selectedCur = _cashCurrency(accounts);
      for (final a in _canonicalCash(accounts)) {
        if (a.currency == selectedCur) return a.id;
      }
      final cash = _canonicalCash(accounts);
      if (cash.isNotEmpty && cash.first.id.isNotEmpty) {
        return cash.first.id;
      }
      return null;
    }
    if (_selBankName == null || _selCurrency == null) return null;
    return resolvePersonalAccount(
      accounts,
      accountId: _selAccountId,
      bankName: _selBankName,
      currency: _selCurrency,
    )?.id;
  }

  Future<void> _submit(List<PersonalBankAccount> accounts) async {
    final l10n = AppLocalizations.of(context);
    final raw = _amountCtrl.text.replaceAll(',', '');
    final amt = double.tryParse(raw);
    if (amt == null || amt <= 0) {
      _showMessage(l10n.translate('pleaseEnterAmount'));
      return;
    }
    if (_payMethod == null) {
      _showMessage(l10n.translate('selectAccountFirst'));
      return;
    }
    final accountId = _resolveAccountId(accounts);
    if (accountId == null) {
      _showMessage(_payMethod == 'bank' && _selCurrency == null
          ? l10n.translate('selectCurrencyFirst')
          : l10n.translate('selectAccountFirst'));
      return;
    }
    if (_selCategory == null) {
      _showMessage(l10n.translate('selectCategoryFirst'));
      return;
    }
    if (_selectedBudget != null) {
      // Guard against a stale selection (budget/category deleted or
      // recreated while the sheet was open): never stage a transaction
      // linked to dead ids. Falls back to the local mirror when the
      // provider list is not loaded yet, so offline use is unaffected.
      var budgets = ref.read(budgetProvider).budgets;
      if (budgets.isEmpty) {
        try {
          budgets = await ref
              .read(personalFinanceServiceProvider)
              .getAllBudgets();
        } catch (_) {}
      }
      if (budgets.isNotEmpty) {
        final problem = validateBudgetSelection(
          budgets: budgets,
          budgetId: _selectedBudget!.id,
          categoryId: _selectedBudgetCategory?.id,
        );
        if (problem != null) {
          _showMessage(l10n.translate(problem));
          return;
        }
      }
    }
    setState(() => _saving = true);
    final String? message;
    message = await ref.read(personalFinanceProvider.notifier).addTransaction(
      type: _formType,
      amount: amt,
      category: _selCategory!,
      description: _descCtrl.text.trim(),
      paymentMethod: _payMethod,
      date: DateTime.now(),
      accountId: accountId,
      currency: _selectedCurrency(accounts),
      budgetId: _selectedBudget?.id,
      budgetCategoryId: _selectedBudgetCategory?.id,
      clientOperationId: _opId,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (message == null) {
      final isIncome = _formType == 'income';
      // Budget withdrawals get their own full-data receipt (budget
      // customization) on top of the success notice.
      final budget = _selectedBudget;
      _showResult(
        title: isIncome ? l10n.translate('txDepositSuccess') : l10n.translate('txWithdrawSuccess'),
        subtitle: '${fmtNum(amt)} ${_selectedCurrency(accounts)}',
        icon: isIncome ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
        gradient: isIncome
            ? const [Color(0xFF1B7A43), Color(0xFF27AE60)]
            : const [Color(0xFFA31E22), Color(0xFFD32F2F)],
      );
      final parent = widget.parentContext;
      Navigator.pop(context);
      if (budget != null) {
        _showBudgetReceipt(parent, budget, amt, accounts);
      }
    } else {
      final insufficient = message.contains('رصيد') ||
          message.toLowerCase().contains('insufficient');
      _showResult(
        title: l10n.translate(
            insufficient ? 'insufficientBalance' : 'txOperationFailed'),
        subtitle: message,
        icon: Icons.error_outline_rounded,
        gradient: const [Color(0xFF7A1020), Color(0xFFC62828)],
        long: true,
      );
    }
  }

  void _showBudgetReceipt(BuildContext parent, PersonalBudget budget,
      double amt, List<PersonalBankAccount> accounts) {
    final l10n = AppLocalizations.of(parent);
    final currency = _selectedCurrency(accounts);
    final selAcc = _payMethod == 'bank'
        ? resolvePersonalAccount(accounts,
            accountId: _selAccountId,
            bankName: _selBankName,
            currency: _selCurrency)
        : null;
    final typeSuffix = selAcc != null &&
            personalAccountNeedsTypeTag(accounts, selAcc)
        ? ' · ${accountTypeLabel(l10n, selAcc.accountType)}'
        : '';
    final accountDisplay = (_payMethod == 'bank' && _selBankName != null)
        ? '$_selBankName ($currency$typeSuffix)'
        : '${l10n.translate('payMethodCash')} ($currency)';
    final categoryName =
        _selectedBudgetCategory?.name ?? _selCategory ?? budget.name;
    final remainingAfter =
        (budget.remaining - amt).clamp(0, double.infinity);
    final preset = ref
        .read(personalReceiptDesignProvider.notifier)
        .getPreset('budget_withdrawal');
    ReceiptModal.show(
      parent,
      ReceiptData(
        title: l10n.translate('txWithdrawFromBudget'),
        amount: amt,
        currencySymbol: currencySymbol(currency),
        dateTime: formatDateTimeDisplay(DateTime.now()),
        senderName: accountDisplay,
        receiverName: budget.name,
        details: [
          ReceiptDetail(
              label: l10n.translate('categoryLabel'), value: categoryName),
          ReceiptDetail(
              label: l10n.translate('personalBudget'), value: budget.name),
          ReceiptDetail(
              label: l10n.translate('totalBudgetLabel'),
              value: '${fmtNum(budget.totalAmount)} $currency'),
          ReceiptDetail(
              label: l10n.translate('homeServiceAccounts'),
              value: accountDisplay),
          ReceiptDetail(
              label: l10n.translate('detailRemaining'),
              value: '${fmtNum(remainingAfter)} $currency'),
          if (_descCtrl.text.trim().isNotEmpty)
            ReceiptDetail(
                label: l10n.translate('description'),
                value: _descCtrl.text.trim()),
        ],
      ),
      preset: preset,
    );
  }

  void _showMessage(String message) {
    _showResult(
      title: message,
      icon: Icons.info_outline_rounded,
      gradient: const [Color(0xFF3A3A3C), Color(0xFF5A5A5E)],
    );
  }

  /// Elegant result notice: green for deposits, red for withdrawals/errors.
  void _showResult({
    required String title,
    String? subtitle,
    required IconData icon,
    required List<Color> gradient,
    bool long = false,
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 28),
          padding: EdgeInsets.zero,
          duration: Duration(seconds: long ? 4 : 3),
          content: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: gradient,
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: gradient.last.withAlpha(90),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(28),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: Colors.white, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                      if (subtitle != null && subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.white.withAlpha(230),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final st = ref.watch(personalFinanceProvider);
    final accounts = st.bankAccounts;
    final categories = _formType == 'income' ? _incomeCategories : _expenseCategories;
    return Container(
      height: MediaQuery.of(context).size.height * 0.92,
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Container(
            margin: EdgeInsets.symmetric(vertical: 10),
            width: 40, height: 4,
            decoration: BoxDecoration(color: AppColors.textSecondary, borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Row(
              children: [
                Text(_formType == 'income' ? l10n.translate('addIncome') : l10n.translate('addExpense'),
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, fontFamily: 'Cairo')),
                Spacer(),
                IconButton(
                  icon: TwoToneIcon(data: TwoToneIcons.close, size: 22, outlineColor: AppColors.textSecondary),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSourceToggle(),
                  SizedBox(height: 12),
                  if (_payMethod == 'bank') _buildBankDropdown(accounts),
                  if (_payMethod == 'bank' && _selBankName != null) ...[
                    SizedBox(height: 12),
                    _buildBankCurrencyButton(accounts),
                  ] else if (_payMethod == 'cash') ...[
                    SizedBox(height: 12),
                    _buildCashCurrencyRow(accounts),
                  ],
                  SizedBox(height: 20),
                  _buildAmountField(accounts),
                  SizedBox(height: 20),
                  _SectionLabel(label: l10n.translate('categoryLabel')),
                  SizedBox(height: 10),
                  _buildCategoryGrid(categories),
                  if (_formType == 'expense') ...[
                    SizedBox(height: 12),
                    _buildDrawFromBudgetButton(),
                  ],
                  SizedBox(height: 20),
                  _buildDescriptionField(),
                  SizedBox(height: 24),
                  _buildSubmitButton(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceToggle() {
    final l10n = AppLocalizations.of(context);
    return Row(
      children: [
        Expanded(
          child: _ActionChip(
            label: l10n.translate('payMethodCash'),
            isActive: _payMethod == 'cash',
            color: AppColors.success,
            onTap: () => setState(() {
              _payMethod = 'cash';
              _selBankName = null;
              _selCurrency = null;
              _selAccountId = null;
            }),
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: _ActionChip(
            label: l10n.translate('payMethodBank'),
            isActive: _payMethod == 'bank',
            color: AppColors.primary,
            onTap: () => setState(() { _payMethod = 'bank'; }),
          ),
        ),
      ],
    );
  }

  /// Step 1 (bank): pick a bank - bank NAME only, no currency shown.
  /// Uses a modal bottom sheet matching the currency picker style.
  Widget _buildBankDropdown(List<PersonalBankAccount> accounts) {
    final l10n = AppLocalizations.of(context);
    return GestureDetector(
      onTap: () => _pickBankAccount(accounts),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border, width: 0.5),
        ),
        child: Row(
          children: [
            TwoToneIcon(data: TwoToneIcons.bank, size: 18, outlineColor: AppColors.primary),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                _selBankName != null
                    ? _selBankName!
                    : l10n.translate('selectAccountFirst'),
                style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w600, color: _selBankName != null ? AppColors.textPrimary : AppColors.textSecondary),
                textAlign: TextAlign.right,
              ),
            ),
            TwoToneIcon(data: TwoToneIcons.arrowDown, size: 18, outlineColor: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  Future<void> _pickBankAccount(List<PersonalBankAccount> accounts) async {
    final l10n = AppLocalizations.of(context);
    // One row per bank: dedupe by bank name (a bank with several
    // currencies appears exactly once), subtitle = currency count.
    final seen = <String>{};
    final bankAccounts = <PersonalBankAccount>[];
    for (final a in accounts) {
      if (_isCashName(a.bankName)) continue;
      if (seen.add(a.bankName)) bankAccounts.add(a);
    }
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Handle bar
            Center(
              child: Container(
                margin: EdgeInsets.only(top: 10),
                width: 40, height: 4,
                decoration: BoxDecoration(color: AppColors.textSecondary, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  TwoToneIcon(data: TwoToneIcons.bank, size: 22, outlineColor: AppColors.primary),
                  SizedBox(width: 10),
                  Text(l10n.translate('selectAccountFirst'),
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, fontFamily: 'Cairo', color: AppColors.textPrimary)),
                ],
              ),
            ),
            Divider(height: 1, color: AppColors.border),
            if (bankAccounts.isEmpty)
              Padding(
                padding: EdgeInsets.all(20),
                child: Text(l10n.translate('noAccountsYet'),
                    style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
              )
            else
              ...bankAccounts.map((a) {
                final isSelected = _selBankName == a.bankName;
                final n = _currenciesFor(accounts, a.bankName).toSet().length;
                return InkWell(
                  onTap: () => Navigator.pop(ctx, a.bankName),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                    decoration: BoxDecoration(
                      color: isSelected ? AppColors.primary.withAlpha(15) : Colors.transparent,
                      border: Border(bottom: BorderSide(color: AppColors.border.withAlpha(40), width: 0.5)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 42, height: 42,
                          decoration: BoxDecoration(
                            color: isSelected ? AppColors.primary.withAlpha(20) : AppColors.surface,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: isSelected ? AppColors.primary.withAlpha(60) : AppColors.border, width: 0.5),
                          ),
                          child: TwoToneIcon(data: TwoToneIcons.bank, size: 20, outlineColor: isSelected ? AppColors.primary : AppColors.textSecondary),
                        ),
                        SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(a.bankName,
                                  style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600,
                                      color: AppColors.textPrimary)),
                              SizedBox(height: 2),
                              Text(
                                l10n.translate('personalCurrenciesCount', params: {'count': '$n'}),
                                style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        if (isSelected)
                          TwoToneIcon(data: TwoToneIcons.check, size: 20, outlineColor: AppColors.primary)
                        else
                          TwoToneIcon(data: TwoToneIcons.arrowDown, size: 16, outlineColor: AppColors.textDisabled),
                      ],
                    ),
                  ),
                );
              }),
            SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen != null) setState(() {
      if (_selBankName != chosen) {
        _selAccountId = null;
        _selCurrency = null;
      }
      _selBankName = chosen;
      // A single-account bank needs no second step.
      final own = personalBankAccountsOf(accounts, chosen);
      if (own.length == 1) {
        _selAccountId = own.first.id;
        _selCurrency = own.first.currency;
      }
    });
  }

  /// Step 2 (bank): the currency button shows ONLY the currencies of the chosen bank.
  Widget _buildBankCurrencyButton(List<PersonalBankAccount> accounts) {
    final l10n = AppLocalizations.of(context);
    final selAcc = _payMethod == 'bank'
        ? resolvePersonalAccount(accounts,
            accountId: _selAccountId,
            bankName: _selBankName,
            currency: _selCurrency)
        : null;
    return GestureDetector(
      onTap: () => _pickBankCurrency(accounts, _selBankName!),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border, width: 0.5),
        ),
        child: Row(
          children: [
            TwoToneIcon(data: TwoToneIcons.coins, size: 18, outlineColor: AppColors.primary),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                _selCurrency != null
                    ? '${l10n.translate('currencyLabel')}: ${currencyLabel(_selCurrency!)}'
                    : l10n.translate('selectCurrencyFirst'),
                style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                textAlign: TextAlign.right,
              ),
            ),
            if (selAcc != null)
              PersonalAccountTypeTag(accounts: accounts, account: selAcc),
            SizedBox(width: 6),
            TwoToneIcon(data: TwoToneIcons.arrowDown, size: 18, outlineColor: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  Future<void> _pickBankCurrency(List<PersonalBankAccount> accounts, String bankName) async {
    final l10n = AppLocalizations.of(context);
    // Every currency of this bank with its balance beside it (debts/goals
    // style). Confirming uses that exact currency account.
    // ONE row per account (never collapsed by currency): the same currency
    // may exist twice (جاري + توفير); each row shows its own balance + tag.
    final accs = personalBankAccountsOf(accounts, bankName);
    final selId = resolvePersonalAccount(accounts,
            accountId: _selAccountId,
            bankName: _selBankName,
            currency: _selCurrency)
        ?.id;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Container(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.68),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Text('${l10n.translate('currencyLabel')} - $bankName',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, fontFamily: 'Cairo')),
              ),
              if (accs.isEmpty)
                Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(l10n.translate('selectCurrencyFirst'),
                      style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final a in accs)
                        ListTile(
                          leading: _currencyLeading(a.currency),
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(currencyLabel(a.currency),
                                    style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary)),
                              ),
                              PersonalAccountTypeTag(accounts: accs, account: a),
                            ],
                          ),
                          subtitle: MoneyText(amount: fmtNum(a.balance), currency: currencyShort(a.currency), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
                          trailing: selId == a.id
                              ? TwoToneIcon(data: TwoToneIcons.check, size: 20, outlineColor: AppColors.primary)
                              : null,
                          onTap: () => Navigator.pop(ctx, a.id),
                        ),
                    ],
                  ),
                ),
              SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (chosen == null) return;
    final picked = accs.where((a) => a.id == chosen).firstOrNull;
    if (picked != null) {
      setState(() {
        _selAccountId = picked.id;
        _selCurrency = picked.currency;
      });
    }
  }

  Widget _buildCashCurrencyRow(List<PersonalBankAccount> accounts) {
    final l10n = AppLocalizations.of(context);
    final cashCurrencies = _cashCurrencies(accounts);
    final balances = <String, double>{};
    for (final a in accounts) {
      if (_isCashName(a.bankName)) {
        balances[a.currency] = (balances[a.currency] ?? 0) + a.balance;
      }
    }
    if (cashCurrencies.length <= 1) {
      return Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border, width: 0.5),
        ),
        child: Row(
          children: [
            TwoToneIcon(data: TwoToneIcons.coins, size: 18, outlineColor: AppColors.primary),
            SizedBox(width: 12),
            Text('${l10n.translate('currencyLabel')}: ${_cashCurrency(accounts)}',
                style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                textAlign: TextAlign.right),
          ],
        ),
      );
    }
    return GestureDetector(
      onTap: () => _pickCashCurrency(cashCurrencies, balances),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border, width: 0.5),
        ),
        child: Row(
          children: [
            TwoToneIcon(data: TwoToneIcons.coins, size: 18, outlineColor: AppColors.primary),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                _selCurrency != null
                    ? '${l10n.translate('currencyLabel')}: ${currencyLabel(_selCurrency!)}'
                    : '${l10n.translate('currencyLabel')}: ${_cashCurrency(accounts)}',
                style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                textAlign: TextAlign.right,
              ),
            ),
            TwoToneIcon(data: TwoToneIcons.arrowDown, size: 18, outlineColor: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  Future<void> _pickCashCurrency(
      List<String> currencies, Map<String, double> balances) async {
    final l10n = AppLocalizations.of(context);
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Container(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.68),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Text('${l10n.translate('currencyLabel')} - ${l10n.translate('payMethodCash')}',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, fontFamily: 'Cairo')),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final c in currencies)
                      ListTile(
                        leading: _currencyLeading(c),
                        title: Text(currencyLabel(c),
                            style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary)),
                        subtitle: MoneyText(amount: fmtNum(balances[c] ?? 0), currency: currencyShort(c), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
                        trailing: _selCurrency == c
                            ? TwoToneIcon(data: TwoToneIcons.check, size: 20, outlineColor: AppColors.primary)
                            : null,
                        onTap: () => Navigator.pop(ctx, c),
                      ),
                  ],
                ),
              ),
              SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (chosen != null) setState(() => _selCurrency = chosen);
  }

  /// Country flag of the currency (fallback: a coin glyph when unmapped).
  Widget _currencyLeading(String c) {
    final flag = currencyFlagEmoji(c);
    if (flag.isEmpty) {
      return TwoToneIcon(
          data: TwoToneIcons.coins, size: 20, outlineColor: AppColors.primary);
    }
    return Text(flag, style: const TextStyle(fontSize: 22));
  }

  Widget _buildAmountField(List<PersonalBankAccount> accounts) {
    final l10n = AppLocalizations.of(context);
    final symbol = currencySymbol(_selectedCurrency(accounts));
    return FyonaTextField(
      controller: _amountCtrl,
      keyboardType: TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [AmountInputFormatter()],
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, fontFamily: 'Cairo', color: AppColors.textPrimary),
      decoration: InputDecoration(
        hintText: l10n.translate('enterAmountHere'),
        hintStyle: TextStyle(color: AppColors.textSecondary.withAlpha(90)),
        suffixText: symbol,
        suffixStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, fontFamily: 'Cairo', color: AppColors.primary),
        filled: true, fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: AppColors.border),
        ),
        contentPadding: EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      ),
    );
  }

  Widget _buildCategoryGrid(List<String> categories) {
    final l10n = AppLocalizations.of(context);
    return Wrap(
      spacing: 8, runSpacing: 8,
      children: categories.map((c) {
        final selected = _selCategory == c;
        final label = personalCategoryKey(c) == null
            ? c
            : l10n.translate('cat_${personalCategoryKey(c)}');
        return GestureDetector(
          onTap: () => setState(() {
            _selCategory = c;
            // Selecting a regular category cancels any budget selection
            if (_selectedBudget != null) {
              _selectedBudget = null;
            }
          }),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: selected ? AppColors.primary : AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: selected ? AppColors.primary : AppColors.border),
            ),
            child: Text(label, style: TextStyle(
              fontSize: 13, fontFamily: 'Cairo',
              color: selected ? Colors.white : AppColors.textPrimary,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            )),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildDescriptionField() {
    final l10n = AppLocalizations.of(context);
    return FyonaTextField(
      controller: _descCtrl,
      textAlign: TextAlign.right,
      decoration: InputDecoration(
        hintText: l10n.translate('notesOptional'),
        filled: true, fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.border),
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }

  Widget _buildDrawFromBudgetButton() {
    final budgetState = ref.watch(budgetProvider);
    final budgets = budgetState.budgets;
    if (budgets.isEmpty) return SizedBox.shrink();
    return GestureDetector(
      onTap: () => _showBudgetPicker(budgets),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.primary.withAlpha(10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primary.withAlpha(30)),
        ),
        child: Row(
          children: [
            Icon(Icons.account_balance_wallet_rounded, size: 20, color: AppColors.primary),
            SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(AppLocalizations.of(context).translate('txWithdrawFromBudget'), style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary)),
                  if (_selectedBudget != null)
                    Text(_selectedBudget!.name, style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
                ],
              ),
            ),
              if (_selectedBudget != null)
              IconButton(
                icon: Icon(Icons.close, size: 18, color: AppColors.textSecondary),
                onPressed: () => setState(() {
                  _selectedBudget = null;
                  _selectedBudgetCategory = null;
                }),
              )
            else
              Icon(Icons.chevron_left_rounded, color: AppColors.primary),
          ],
        ),
      ),
    );
  }

  void _showBudgetPicker(List<PersonalBudget> budgets) async {
    final chosen = await showModalBottomSheet<PersonalBudget>(
      context: context,
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.5,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Text(AppLocalizations.of(context).translate('txChooseBudget'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, fontFamily: 'Cairo')),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: budgets.length,
                  itemBuilder: (ctx, i) {
                    final b = budgets[i];
                    return ListTile(
                      leading: Container(
                        width: 40, height: 40,
                        decoration: BoxDecoration(color: AppColors.primary.withAlpha(15), borderRadius: BorderRadius.circular(10)),
                        child: Icon(Icons.account_balance_wallet_rounded, size: 20, color: AppColors.primary),
                      ),
                      title: Text(b.name, style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w600)),
                      subtitle: Text(AppLocalizations.of(context).translate('txBudgetRemaining', params: {'amount': fmtNum(b.remaining), 'currency': b.currency}), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
                      trailing: Icon(Icons.chevron_left_rounded, color: AppColors.textSecondary),
                      onTap: () => Navigator.pop(ctx, b),
                    );
                  },
                ),
              ),
              SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (chosen != null) {
      setState(() {
        _selectedBudget = chosen;
        _selectedBudgetCategory = null;
      });
      final hasCategories = chosen.categories.any((c) => c.allocatedAmount > 0);
      if (hasCategories) {
        _showBudgetCategoryPicker(chosen);
      } else {
        // No categories — deduct from budget directly
        setState(() {
          _selCategory = chosen.name;
        });
      }
    }
  }

  void _showBudgetCategoryPicker(PersonalBudget budget) async {
    final categories = budget.categories.where((c) => c.allocatedAmount > 0).toList();
    if (categories.isEmpty) {
      setState(() {
        _selCategory = budget.name;
      });
      return;
    }
    final chosen = await showModalBottomSheet<BudgetCategory>(
      context: context,
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.5,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Text(AppLocalizations.of(context).translate('txChooseCategoryFrom', params: {'name': budget.name}), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, fontFamily: 'Cairo')),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: categories.length,
                  itemBuilder: (ctx, i) {
                    final cat = categories[i];
                    final remaining = cat.remaining;
                    return ListTile(
                      leading: Container(
                        width: 40, height: 40,
                        decoration: BoxDecoration(color: AppColors.primary.withAlpha(15), borderRadius: BorderRadius.circular(10)),
                        child: Icon(Icons.category_rounded, size: 20, color: AppColors.primary),
                      ),
                      title: Text(cat.name, style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w600)),
                      subtitle: Text(AppLocalizations.of(context).translate('txCategoryRemaining', params: {'amount': fmtNum(remaining), 'currency': cat.currency}), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
                      trailing: Icon(Icons.chevron_left_rounded, color: AppColors.textSecondary),
                      onTap: () => Navigator.pop(ctx, cat),
                    );
                  },
                ),
              ),
              SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (chosen != null) {
      setState(() {
        _selCategory = chosen.name;
        _selectedBudgetCategory = chosen;
      });
    } else {
      // User cancelled category picker — deselect the budget
      setState(() {
        _selectedBudget = null;
        _selectedBudgetCategory = null;
      });
    }
  }

  Widget _buildSubmitButton() {
    final l10n = AppLocalizations.of(context);
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _saving ? null : () => _submit(ref.read(personalFinanceProvider).bankAccounts),
        style: ElevatedButton.styleFrom(
          backgroundColor: _formType == 'income' ? AppColors.success : AppColors.danger,
          foregroundColor: Colors.white,
          padding: EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 0,
        ),
        child: _saving
          ? DotsLoader.button()
          : Text(_formType == 'income' ? l10n.translate('addIncome') : l10n.translate('addExpense'),
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, fontFamily: 'Cairo')),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final String label;
  final bool isActive;
  final Color color;
  final VoidCallback onTap;
  const _ActionChip({required this.label, required this.isActive, required this.color, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: isActive ? color : AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: isActive ? color : AppColors.border),
        ),
        child: Text(label, textAlign: TextAlign.center, style: TextStyle(
          fontSize: 14, fontFamily: 'Cairo',
          color: isActive ? Colors.white : AppColors.textPrimary,
          fontWeight: FontWeight.w700,
        )),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});
  @override
  Widget build(BuildContext context) {
    return Text(label, style: TextStyle(
      fontSize: 14, fontWeight: FontWeight.w700, fontFamily: 'Cairo',
      color: AppColors.textPrimary,
    ));
  }
}