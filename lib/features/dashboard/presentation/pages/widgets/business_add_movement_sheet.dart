import 'package:flutter/material.dart';


import 'package:dio/dio.dart';
import '../../../../core_business/presentation/widgets/business_number_field.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../../core/localization/app_localizations.dart';
import '../../../../../core/responsive/r_api.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/utils/amount_input_formatter.dart';
import '../../../../../core/utils/currency_formatter.dart';
import '../../../../../shared/widgets/account_type_bar.dart';
import '../../../../../shared/widgets/two_tone_icon.dart';
import '../../../../../shared/widgets/two_tone_icons.dart';
import '../../../../personal/data/models/personal_models.dart';
import '../../../../personal/domain/services/personal_finance_service.dart';
import '../../providers/business_dashboard_providers.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';
import '../../../../employees/presentation/providers/employee_providers.dart';
import '../../../../core_business/data/local_directory/directory_database.dart';
import '../../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../../core_business/data/local_directory/directory_scope.dart';
import '../../../../core_business/data/local_ledger/business_money.dart';
import '../../../../core_business/presentation/providers/business_ledger_session.dart';

/// Business add-movement sheet — the EXACT same design/flow as the personal
/// section's add income/expense sheet (source toggle cash/bank, bank picker,
/// per-bank currency picker, cash currency picker, amount with currency
/// suffix, category grid, description, colored submit), wired to the
/// BUSINESS accounts/endpoints:
///   income  → POST /banking/accounts/{id}/deposit  (balance + movement)
///   expense → POST /banking/accounts/{id}/withdraw (balance check + movement)
///
/// Business-only differences:
///   • income category title = «من أين جاءت الفلوس؟» with common sources.
///   • expense category title = «ما هو سبب السحب؟» with common reasons.
///   • choosing «أخرى» lets the user type the source/reason manually.
void showBusinessAddMovementSheet(
  BuildContext context, {
  required String initialType,
  VoidCallback? onDone,
  DirectoryAccess? localScope,
}) {
  if (!ProviderScope.containerOf(
    context,
    listen: false,
  ).read(employeeCanProvider(initialType == 'income' ? 'income' : 'expenses')))
    return;
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) =>
        _BusinessAddMovementSheet(initialType: initialType, onDone: onDone,
          localScope: localScope),
  );
}

const _otherOption = 'أخرى';
const _incomeSources = [
  'رأس مال',
  'استثمار',
  'تمويل',
  'دخل إضافي',
  'عمولة',
  'تأجير',
  'خدمات',
  _otherOption,
];
const _expenseReasons = [
  'إيجار',
  'كهرباء وماء',
  'نقل',
  'تسويق',
  'صيانة',
  'مشتريات تشغيلية',
  'رسوم',
  _otherOption,
];

class _BusinessAddMovementSheet extends ConsumerStatefulWidget {
  final String initialType;
  final VoidCallback? onDone;
  final DirectoryAccess? localScope;
  const _BusinessAddMovementSheet({
    required this.initialType, this.onDone, this.localScope,
  });
  @override
  ConsumerState<_BusinessAddMovementSheet> createState() =>
      _BusinessAddMovementSheetState();
}

class _BusinessAddMovementSheetState
    extends ConsumerState<_BusinessAddMovementSheet> {
  late String _formType = widget.initialType; // 'income' | 'expense'
  final _amountCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _otherCtrl = TextEditingController();
  String? _selCategory;
  String? _payMethod; // 'cash' | 'bank'
  String? _selBankName; // bank name only (no currency shown)
  String? _selCurrency; // a currency of the selected bank / cash bucket
  String? _selAccountType; // جاري / توفير — when the bank has both
  bool _saving = false;
  final _localCommand = const Uuid().v4();
  List<PersonalBankAccount> _localAccounts = const [];

  bool get _isIncome => _formType == 'income';

  @override
  void initState() {
    super.initState();
    if (widget.localScope != null) _loadLocalAccounts();
  }

  Future<void> _loadLocalAccounts() async {
    try {
      final accounts = await withBusinessLedger(
        ref, widget.localScope!, BusinessLedgerAction.readBank,
        [_isIncome ? 'income' : 'expenses'],
        (ledger, grant) => ledger.accounts(grant),
      );
      if (!mounted) return;
      setState(() {
        _localAccounts = [
          for (final row in accounts)
            PersonalBankAccount.fromServer({
              ...row,
              'balance': double.parse(BusinessMoney.display(row['balance_minor'] as int)),
            }),
        ];
      });
    } catch (_) {
      if (mounted) _showMessage(AppLocalizations.of(context).translate('txOperationFailed'));
    }
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _descCtrl.dispose();
    _otherCtrl.dispose();
    super.dispose();
  }

  List<String> _currenciesFor(
    List<PersonalBankAccount> accounts,
    String bankName,
  ) => [
    for (final a in accounts)
      if (a.bankName == bankName) a.currency,
  ];

  /// Canonical cash rows: one per currency bucket with summed balances —
  /// identical to the personal sheet.
  List<PersonalBankAccount> _canonicalCash(
    List<PersonalBankAccount> accounts,
  ) => PersonalFinanceService.canonicalCashAccounts(accounts);

  String _cashCurrency(List<PersonalBankAccount> accounts) {
    if (_selCurrency != null && _payMethod == 'cash') return _selCurrency!;
    final cash = _canonicalCash(accounts);
    if (cash.isNotEmpty) return cash.first.currency;
    return 'USD';
  }

  List<String> _cashCurrencies(List<PersonalBankAccount> accounts) => [
    for (final a in _canonicalCash(accounts)) a.currency,
  ];

  String _selectedCurrency(List<PersonalBankAccount> accounts) {
    if (_payMethod == 'cash') return _cashCurrency(accounts);
    return _selCurrency ?? 'USD';
  }

  /// The bank account UUID matching the selected bank + currency, or null.
  String? _resolveAccountId(List<PersonalBankAccount> accounts) {
    if (_payMethod == 'cash') {
      final selectedCur = _cashCurrency(accounts);
      for (final a in _canonicalCash(accounts)) {
        if (a.currency == selectedCur) return a.id;
      }
      final cash = _canonicalCash(accounts);
      if (cash.isNotEmpty && cash.first.id.isNotEmpty) return cash.first.id;
      return null;
    }
    if (_selBankName == null || _selCurrency == null) return null;
    // Exact account first (bank + currency + checking/savings)…
    if (_selAccountType != null) {
      for (final a in accounts) {
        if (a.bankName == _selBankName &&
            a.currency == _selCurrency &&
            a.accountType == _selAccountType) {
          return a.id;
        }
      }
    }
    // …then the plain bank + currency match.
    for (final a in accounts) {
      if (a.bankName == _selBankName && a.currency == _selCurrency) return a.id;
    }
    return null;
  }

  Future<void> _submit(List<PersonalBankAccount> accounts) async {
    if (_saving) return;
    final l10n = AppLocalizations.of(context);
    final raw = _amountCtrl.text.replaceAll(',', '');
    final amt = double.tryParse(raw);
    if (amt == null || !amt.isFinite || amt <= 0) {
      _showMessage(l10n.translate('pleaseEnterAmount'));
      return;
    }
    if (_payMethod == null) {
      _showMessage(l10n.translate('selectAccountFirst'));
      return;
    }
    final accountId = _resolveAccountId(accounts);
    if (accountId == null) {
      _showMessage(
        _payMethod == 'bank' && _selCurrency == null
            ? l10n.translate('selectCurrencyFirst')
            : l10n.translate('selectAccountFirst'),
      );
      return;
    }
    if (_selCategory == null) {
      _showMessage(l10n.translate('selectCategoryFirst'));
      return;
    }
    if (_selCategory == _otherOption && _otherCtrl.text.trim().isEmpty) {
      _showMessage(
        l10n.translate(
          _isIncome ? 'bizIncomeOtherHint' : 'bizExpenseOtherHint',
        ),
      );
      return;
    }
    final category = _selCategory == _otherOption
        ? _otherCtrl.text.trim()
        : _selCategory!;
    final description = _descCtrl.text.trim().isEmpty
        ? '$category — ${l10n.translate(_isIncome ? 'txKindIncome' : 'txKindExpense')}'
        : _descCtrl.text.trim();

    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final scope = widget.localScope;
      if (scope != null) {
        await withBusinessLedger(
          ref, scope, BusinessLedgerAction.moveMoney,
          [_isIncome ? 'income' : 'expenses'],
          (ledger, grant) => ledger.move(
            grant, commandId: _localCommand, accountId: accountId,
            amountMinor: BusinessMoney.minor(raw), withdraw: !_isIncome,
            description: description, expenseCategory: _isIncome ? null : category,
          ),
        );
      } else {
        final api = ref.read(businessFinanceApiProvider);
        _isIncome
            ? await api.deposit(accountId, amt, description: description)
            : await api.withdraw(accountId, amt, description: description,
                isExpense: true, category: category);
      }
      if (!mounted) return;

      Navigator.pop(context);
      widget.onDone?.call();
      _showResultOn(
        messenger,
        title: l10n.translate(
          _isIncome ? 'txDepositSuccess' : 'txWithdrawSuccess',
        ),
        subtitle: '${fmtNum(amt)} ${_selectedCurrency(accounts)}',
        icon: _isIncome
            ? Icons.arrow_downward_rounded
            : Icons.arrow_upward_rounded,
        gradient: _isIncome
            ? const [Color(0xFF1B7A43), Color(0xFF27AE60)]
            : const [Color(0xFFA31E22), Color(0xFFD32F2F)],
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      final detail = _errorText(e);
      final insufficient =
          detail.contains('رصيد') ||
          detail.toLowerCase().contains('insufficient') ||
          (e is BusinessLedgerError &&
              e.problem == BusinessLedgerProblem.insufficientBalance);
      _showResultOn(
        messenger,
        title: l10n.translate(
          insufficient ? 'insufficientBalance' : 'txOperationFailed',
        ),
        subtitle: detail.isEmpty ? null : detail,
        icon: Icons.error_outline_rounded,
        gradient: const [Color(0xFF7A1020), Color(0xFFC62828)],
      );
    }
  }

  String _errorText(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map) {
        final detail = data['detail'] ?? data['message'];
        if (detail is String && detail.trim().isNotEmpty) return detail.trim();
      }
      if (error.message != null && error.message!.trim().isNotEmpty) {
        return error.message!.trim();
      }
    }
    return '';
  }

  void _showMessage(String message) => _showResultOn(
    ScaffoldMessenger.of(context),
    title: message,
    icon: Icons.info_outline_rounded,
    gradient: const [Color(0xFF3A3A3C), Color(0xFF5A5A5E)],
  );

  /// Elegant result notice — identical to the personal sheet (green for
  /// deposits, red for withdrawals/errors).
  void _showResultOn(
    ScaffoldMessengerState messenger, {
    required String title,
    String? subtitle,
    required IconData icon,
    required List<Color> gradient,
  }) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 28),
          padding: EdgeInsets.zero,
          duration: const Duration(seconds: 3),
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
    final local = widget.localScope;
    final accounts = local == null
        ? ref.watch(businessPaymentAccountsProvider).valueOrNull ?? const <PersonalBankAccount>[]
        : sameDirectoryScope(local, ref.watch(businessLocalLedgerScopeProvider)) &&
                ref.watch(employeeCanProvider(_isIncome ? 'income' : 'expenses'))
            ? _localAccounts : const <PersonalBankAccount>[];
    final categories = _isIncome ? _incomeSources : _expenseReasons;
    return Container(
      height: MediaQuery.of(context).size.height * 0.92,
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.textSecondary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Row(
              children: [
                Text(
                  l10n.translate(_isIncome ? 'addIncome' : 'addExpense'),
                  style: TextStyle(
                    fontSize: R.fontSize(context, 18),
                    fontWeight: FontWeight.w700,
                    fontFamily: 'Cairo',
                    color: AppColors.textPrimary,
                  ),
                ),
                const Spacer(),
                IconButton(
                  key: const ValueKey('business_movement_cancel'),
                  icon: TwoToneIcon(
                    data: TwoToneIcons.close,
                    size: 22,
                    outlineColor: AppColors.textSecondary,
                  ),
                  onPressed: _saving ? null : () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSourceToggle(),
                  const SizedBox(height: 12),
                  if (_payMethod == 'bank') _buildBankDropdown(accounts),
                  if (_payMethod == 'bank' && _selBankName != null) ...[
                    const SizedBox(height: 12),
                    _buildBankCurrencyButton(accounts),
                  ] else if (_payMethod == 'cash') ...[
                    const SizedBox(height: 12),
                    _buildCashCurrencyRow(accounts),
                  ],
                  const SizedBox(height: 20),
                  _buildAmountField(accounts),
                  const SizedBox(height: 20),
                  _SectionLabel(
                    label: l10n.translate(
                      _isIncome
                          ? 'bizIncomeSourceLabel'
                          : 'bizExpenseReasonLabel',
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildCategoryGrid(categories),
                  if (_selCategory == _otherOption) ...[
                    const SizedBox(height: 12),
                    _buildOtherField(),
                  ],
                  const SizedBox(height: 20),
                  _buildDescriptionField(),
                  const SizedBox(height: 24),
                  _buildSubmitButton(accounts),
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
              _selAccountType = null;
            }),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _ActionChip(
            label: l10n.translate('payMethodBank'),
            isActive: _payMethod == 'bank',
            color: AppColors.primary,
            onTap: () => setState(() => _payMethod = 'bank'),
          ),
        ),
      ],
    );
  }

  /// Step 1 (bank): pick a bank — bank NAME only, no currency shown.
  Widget _buildBankDropdown(List<PersonalBankAccount> accounts) {
    final l10n = AppLocalizations.of(context);
    return GestureDetector(
      onTap: () => _pickBankAccount(accounts),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border, width: 0.5),
        ),
        child: Row(
          children: [
            TwoToneIcon(
              data: TwoToneIcons.bank,
              size: 18,
              outlineColor: AppColors.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _selBankName != null
                    ? _selBankName!
                    : l10n.translate('selectAccountFirst'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.w600,
                  color: _selBankName != null
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                ),
                textAlign: TextAlign.right,
              ),
            ),
            TwoToneIcon(
              data: TwoToneIcons.arrowDown,
              size: 18,
              outlineColor: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickBankAccount(List<PersonalBankAccount> accounts) async {
    final l10n = AppLocalizations.of(context);
    final seen = <String>{};
    final bankAccounts = <PersonalBankAccount>[];
    for (final a in accounts) {
      if (isCashAccount(a.bankName)) continue;
      if (seen.add(a.bankName)) bankAccounts.add(a);
    }
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textSecondary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  TwoToneIcon(
                    data: TwoToneIcons.bank,
                    size: 22,
                    outlineColor: AppColors.primary,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    l10n.translate('selectAccountFirst'),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'Cairo',
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: AppColors.border),
            if (bankAccounts.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  l10n.translate('noAccountsYet'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppColors.textSecondary,
                  ),
                ),
              )
            else
              ...bankAccounts.map((a) {
                final isSelected = _selBankName == a.bankName;
                final n = _currenciesFor(accounts, a.bankName).toSet().length;
                return InkWell(
                  onTap: () => Navigator.pop(ctx, a.bankName),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppColors.primary.withAlpha(15)
                          : Colors.transparent,
                      border: Border(
                        bottom: BorderSide(
                          color: AppColors.border.withAlpha(40),
                          width: 0.5,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppColors.primary.withAlpha(20)
                                : AppColors.surface,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isSelected
                                  ? AppColors.primary.withAlpha(60)
                                  : AppColors.border,
                              width: 0.5,
                            ),
                          ),
                          child: TwoToneIcon(
                            data: TwoToneIcons.bank,
                            size: 20,
                            outlineColor: isSelected
                                ? AppColors.primary
                                : AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                a.bankName,
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                l10n.translate(
                                  'personalCurrenciesCount',
                                  params: {'count': '$n'},
                                ),
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 11,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (isSelected)
                          TwoToneIcon(
                            data: TwoToneIcons.check,
                            size: 20,
                            outlineColor: AppColors.primary,
                          )
                        else
                          TwoToneIcon(
                            data: TwoToneIcons.arrowDown,
                            size: 16,
                            outlineColor: AppColors.textDisabled,
                          ),
                      ],
                    ),
                  ),
                );
              }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen != null) {
      setState(() {
        _selBankName = chosen;
        _selAccountType = null; // re-pick the exact account for the new bank
        if (!_currenciesFor(accounts, chosen).contains(_selCurrency)) {
          _selCurrency = null;
        }
      });
    }
  }

  /// Step 2 (bank): the currency button shows ONLY the currencies of the
  /// chosen bank (with balance beside each).
  Widget _buildBankCurrencyButton(List<PersonalBankAccount> accounts) {
    final l10n = AppLocalizations.of(context);
    return GestureDetector(
      onTap: () => _pickBankCurrency(accounts, _selBankName!),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border, width: 0.5),
        ),
        child: Row(
          children: [
            TwoToneIcon(
              data: TwoToneIcons.coins,
              size: 18,
              outlineColor: AppColors.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _selCurrency != null
                    ? '${l10n.translate('currencyLabel')}: ${currencyLabel(_selCurrency!)}'
                          '${_selAccountType != null ? ' • ${accountTypeLabel(l10n, _selAccountType)}' : ''}'
                    : l10n.translate('selectCurrencyFirst'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
                textAlign: TextAlign.right,
              ),
            ),
            TwoToneIcon(
              data: TwoToneIcons.arrowDown,
              size: 18,
              outlineColor: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickBankCurrency(
    List<PersonalBankAccount> accounts,
    String bankName,
  ) async {
    final l10n = AppLocalizations.of(context);
    final accs = accounts
        .where((a) => a.bankName == bankName && !isCashAccount(a.bankName))
        .toList();
    // Distinct (currency, type) rows — the same currency as checking AND
    // savings appears BOTH times, each with its own label + colored bar.
    final rows = <PersonalBankAccount>[];
    final seen = <String>{};
    for (final a in accs) {
      if (seen.add('${a.currency}|${a.accountType}')) rows.add(a);
    }
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Text(
                '${l10n.translate('currencyLabel')} - $bankName',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'Cairo',
                ),
              ),
            ),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  l10n.translate('selectCurrencyFirst'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppColors.textSecondary,
                  ),
                ),
              )
            else
              ...rows.map((a) {
                final c = a.currency;
                final isSel =
                    _selCurrency == c &&
                    (_selAccountType == null ||
                        _selAccountType == a.accountType);
                return ListTile(
                  leading: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AccountTypeBar(type: a.accountType),
                      const SizedBox(width: 10),
                      _currencyLeading(c),
                    ],
                  ),
                  title: Row(
                    children: [
                      Text(
                        currencyLabel(c),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        accountTypeLabel(l10n, a.accountType),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: accountTypeBarColor(a.accountType),
                        ),
                      ),
                    ],
                  ),
                  subtitle: !ref.read(employeeCanProvider('banks.balances'))
                      ? null
                      : Text(
                          '${fmtNum(a.balance)} ${currencyShort(c)}',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 11,
                            color: AppColors.textSecondary,
                          ),
                        ),
                  trailing: isSel
                      ? TwoToneIcon(
                          data: TwoToneIcons.check,
                          size: 20,
                          outlineColor: AppColors.primary,
                        )
                      : null,
                  onTap: () =>
                      Navigator.pop(ctx, '${a.currency}||${a.accountType}'),
                );
              }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen != null) {
      final parts = chosen.split('||');
      setState(() {
        _selCurrency = parts.isNotEmpty ? parts[0] : chosen;
        _selAccountType = parts.length > 1 ? parts[1] : null;
      });
    }
  }

  Widget _buildCashCurrencyRow(List<PersonalBankAccount> accounts) {
    final l10n = AppLocalizations.of(context);
    final cashCurrencies = _cashCurrencies(accounts);
    final balances = <String, double>{};
    for (final a in accounts) {
      if (isCashAccount(a.bankName)) {
        balances[a.currency] = (balances[a.currency] ?? 0) + a.balance;
      }
    }
    if (cashCurrencies.length <= 1) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border, width: 0.5),
        ),
        child: Row(
          children: [
            TwoToneIcon(
              data: TwoToneIcons.coins,
              size: 18,
              outlineColor: AppColors.primary,
            ),
            const SizedBox(width: 12),
            Text(
              '${l10n.translate('currencyLabel')}: ${_cashCurrency(accounts)}',
              style: TextStyle(
                fontFamily: 'Cairo',
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
              textAlign: TextAlign.right,
            ),
          ],
        ),
      );
    }
    return GestureDetector(
      onTap: () => _pickCashCurrency(cashCurrencies, balances),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border, width: 0.5),
        ),
        child: Row(
          children: [
            TwoToneIcon(
              data: TwoToneIcons.coins,
              size: 18,
              outlineColor: AppColors.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _selCurrency != null
                    ? '${l10n.translate('currencyLabel')}: ${currencyLabel(_selCurrency!)}'
                    : '${l10n.translate('currencyLabel')}: ${_cashCurrency(accounts)}',
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
                textAlign: TextAlign.right,
              ),
            ),
            TwoToneIcon(
              data: TwoToneIcons.arrowDown,
              size: 18,
              outlineColor: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickCashCurrency(
    List<String> currencies,
    Map<String, double> balances,
  ) async {
    final l10n = AppLocalizations.of(context);
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Text(
                '${l10n.translate('currencyLabel')} - ${l10n.translate('payMethodCash')}',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'Cairo',
                ),
              ),
            ),
            ...currencies.map(
              (c) => ListTile(
                leading: _currencyLeading(c),
                title: Text(
                  currencyLabel(c),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppColors.textPrimary,
                  ),
                ),
                subtitle: !ref.read(employeeCanProvider('banks.balances'))
                    ? null
                    : Text(
                        '${fmtNum(balances[c] ?? 0)} ${currencyShort(c)}',
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 11,
                          color: AppColors.textSecondary,
                        ),
                      ),
                trailing: _selCurrency == c
                    ? TwoToneIcon(
                        data: TwoToneIcons.check,
                        size: 20,
                        outlineColor: AppColors.primary,
                      )
                    : null,
                onTap: () => Navigator.pop(ctx, c),
              ),
            ),
            const SizedBox(height: 8),
          ],
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
        data: TwoToneIcons.coins,
        size: 20,
        outlineColor: AppColors.primary,
      );
    }
    return Text(flag, style: const TextStyle(fontSize: 22));
  }

  Widget _buildAmountField(List<PersonalBankAccount> accounts) {
    final l10n = AppLocalizations.of(context);
    final symbol = currencySymbol(_selectedCurrency(accounts));
    return BusinessNumberField(
      key: const ValueKey('business_movement_amount'),
      controller: _amountCtrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [AmountInputFormatter()],
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        fontFamily: 'Cairo',
        color: AppColors.textPrimary,
      ),
      decoration: InputDecoration(
        hintText: l10n.translate('enterAmountHere'),
        hintStyle: TextStyle(color: AppColors.textSecondary.withAlpha(90)),
        suffixText: symbol,
        suffixStyle: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          fontFamily: 'Cairo',
          color: AppColors.primary,
        ),
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: AppColors.border),
        ),
        contentPadding: const EdgeInsets.symmetric(
          vertical: 16,
          horizontal: 16,
        ),
      ),
    );
  }

  Widget _buildCategoryGrid(List<String> categories) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: categories.map((c) {
        final selected = _selCategory == c;
        final label = c;
        return GestureDetector(
          onTap: () => setState(() {
            _selCategory = c;
            if (c != _otherOption) _otherCtrl.clear();
          }),
          child: Container(
            key: ValueKey('business_movement_category_$c'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: selected ? AppColors.primary : AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: selected ? AppColors.primary : AppColors.border,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontFamily: 'Cairo',
                color: selected ? Colors.white : AppColors.textPrimary,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildOtherField() {
    final l10n = AppLocalizations.of(context);
    return FyonaTextField(
      controller: _otherCtrl,
      textAlign: TextAlign.right,
      style: const TextStyle(fontFamily: 'Cairo'),
      decoration: InputDecoration(
        hintText: l10n.translate(
          _isIncome ? 'bizIncomeOtherHint' : 'bizExpenseOtherHint',
        ),
        hintStyle: TextStyle(color: AppColors.textSecondary),
        prefixIcon: Icon(
          Icons.edit_outlined,
          size: 18,
          color: AppColors.primary,
        ),
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.border),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
    );
  }

  Widget _buildDescriptionField() {
    final l10n = AppLocalizations.of(context);
    return FyonaTextField(
      key: const ValueKey('business_movement_description'),
      controller: _descCtrl,
      textAlign: TextAlign.right,
      style: const TextStyle(fontFamily: 'Cairo'),
      decoration: InputDecoration(
        hintText: l10n.translate('notesOptional'),
        hintStyle: TextStyle(color: AppColors.textSecondary),
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.border),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
    );
  }

  Widget _buildSubmitButton(List<PersonalBankAccount> accounts) {
    final l10n = AppLocalizations.of(context);
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        key: const ValueKey('business_movement_submit'),
        onPressed: _saving ? null : () => _submit(accounts),
        style: ElevatedButton.styleFrom(
          backgroundColor: _isIncome ? AppColors.success : AppColors.danger,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          elevation: 0,
        ),
        child: _saving && widget.localScope == null
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Text(
                l10n.translate(_isIncome ? 'addIncome' : 'addExpense'),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'Cairo',
                ),
              ),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final String label;
  final bool isActive;
  final Color color;
  final VoidCallback onTap;
  const _ActionChip({
    required this.label,
    required this.isActive,
    required this.color,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: isActive ? color : AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: isActive ? color : AppColors.border),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            fontFamily: 'Cairo',
            color: isActive ? Colors.white : AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});
  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        fontFamily: 'Cairo',
        color: AppColors.textPrimary,
      ),
    );
  }
}
