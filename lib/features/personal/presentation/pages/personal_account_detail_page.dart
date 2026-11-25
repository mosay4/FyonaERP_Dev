import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../../../../shared/widgets/currency_selector.dart';
import '../../../../shared/widgets/receipt/receipt.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import '../providers/receipt_design_provider.dart';
import '../widgets/add_transaction_sheet.dart';
import 'package:intl/intl.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart' show fmtNum, currencySymbol, currencyName;
import 'package:fyona_flutter/core/responsive/r_api.dart';
import '../../../../core/utils/time_format.dart';
import '../../../../shared/widgets/money_text.dart';

String _currencySymbol(String code) => currencySymbol(code);

String _transactionTypeLabel(String type, AppLocalizations l10n) {
  switch (type) {
    case 'income':
      return l10n.translate('deposit');
    case 'expense':
      return l10n.translate('withdrawal');
    case 'transfer_in':
      return l10n.translate('incomingTransfer');
    case 'transfer_out':
      return l10n.translate('outgoingTransfer');
    default:
      return type;
  }
}

TwoToneIconData _transactionIcon(String type) {
  switch (type) {
    case 'income':
      return TwoToneIcons.arrowDown;
    case 'expense':
      return TwoToneIcons.arrowUp;
    case 'transfer_in':
    case 'transfer_out':
      return TwoToneIcons.transfer;
    default:
      return TwoToneIcons.close;
  }
}

Color _transactionColor(String type) {
  switch (type) {
    case 'income':
    case 'transfer_in':
      return AppColors.success;
    case 'expense':
    case 'transfer_out':
      return AppColors.danger;
    default:
      return AppColors.textSecondary;
  }
}

class PersonalAccountDetailPage extends ConsumerStatefulWidget {
  final String accountId;
  const PersonalAccountDetailPage({super.key, this.accountId = ''});
  @override
  ConsumerState<PersonalAccountDetailPage> createState() => _PersonalAccountDetailPageState();
}

class _PersonalAccountDetailPageState extends ConsumerState<PersonalAccountDetailPage> {
  String _resolvedAccountId = '';
  bool _initialized = false;
  String? _selCurrency;
  DateTime? _filterFrom;
  DateTime? _filterTo;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _initialized) return;
      _initialized = true;
      // Account IDs are backend UUID strings (online) or synthetic UUIDs
      // (offline) — never integers. Resolve as a raw string.
      var id = widget.accountId.trim();
      if (id.isEmpty) {
        id = (GoRouterState.of(context).pathParameters['id'] ?? '').trim();
      }
      if (id.isEmpty) {
        id = (GoRouterState.of(context).uri.queryParameters['accountId'] ?? '').trim();
      }
      _resolvedAccountId = id;
      final now = DateTime.now();
      _filterFrom ??= DateTime(now.year, now.month, 1);
      _filterTo ??= now;
      ref.read(personalFinanceProvider.notifier).loadTransactions(month: 0, year: 0);
    });
  }

  AppLocalizations get _l10n => AppLocalizations.of(context);

  PersonalBankAccount? _resolveAccount(PersonalFinanceState state) {
    return state.bankAccounts.where((a) => a.id == _resolvedAccountId).firstOrNull;
  }

  /// All accounts of the same bank (any currency/type).
  List<PersonalBankAccount> _bankGroup(PersonalFinanceState state, PersonalBankAccount account) {
    return state.bankAccounts.where((a) => a.bankName == account.bankName).toList();
  }

  /// All currency:type combinations available in this bank (may repeat a currency
  /// when it has several account types like جاري / توفير).
  List<String> _currencies(PersonalFinanceState state, PersonalBankAccount account) {
    final list = <String>[];
    for (final a in _bankGroup(state, account)) {
      final key = '${a.currency}:${a.accountType}';
      if (!list.contains(key)) list.add(key);
    }
    return list;
  }

  /// The account matching the currently selected currency:type key.
  PersonalBankAccount? _selectedAccount(PersonalBankAccount account) {
    final state = ref.read(personalFinanceProvider);
    final sel = _selCurrency;
    if (sel == null) {
      return _bankGroup(state, account).where((a) => a.currency == account.currency).firstOrNull;
    }
    final parts = sel.split(':');
    return _bankGroup(state, account)
        .where((a) => a.currency == parts[0] && a.accountType == parts[1])
        .firstOrNull;
  }

  String _effectiveCurrency(PersonalBankAccount account) {
    final sel = _selCurrency;
    if (sel == null) return account.currency;
    return sel.split(':').first;
  }

  double _groupBalance(PersonalFinanceState state, PersonalBankAccount account, String? currency) {
    final sel = _selCurrency;
    if (sel != null) {
      final parts = sel.split(':');
      final acc = _bankGroup(state, account).where((a) => a.currency == parts[0] && a.accountType == parts[1]).firstOrNull;
      return acc?.balance ?? 0;
    }
    if (currency != null) {
      final acc = _bankGroup(state, account).where((a) => a.currency == currency && a.accountType == account.accountType).firstOrNull;
      return acc?.balance ?? 0;
    }
    return _bankGroup(state, account).fold<double>(0, (s, a) => s + a.balance);
  }

  bool _matchesFilter(DateTime? date) {
    if (date == null) return _filterFrom == null && _filterTo == null;
    final day = DateTime(date.year, date.month, date.day);
    final from = _filterFrom;
    final to = _filterTo;
    if (from != null && day.isBefore(DateTime(from.year, from.month, from.day))) return false;
    if (to != null && day.isAfter(DateTime(to.year, to.month, to.day))) return false;
    return true;
  }

  List<PersonalTransaction> _visibleTransactions(PersonalFinanceState state, PersonalBankAccount account) {
    final curAcc = _selectedAccount(account);
    if (curAcc == null) return const [];
    return state.transactions.where((t) => t.accountId == curAcc.id && _matchesFilter(t.date)).toList();
  }

  void _showTransactionReceipt(PersonalTransaction t) {
    final state = ref.read(personalFinanceProvider);
    final account = state.bankAccounts.where((a) => a.id == t.accountId).firstOrNull;
    final preset = ref.read(personalReceiptDesignProvider.notifier).getPreset('bank');
    final typeLabel = _transactionTypeLabel(t.type, _l10n);
    ReceiptModal.show(context, ReceiptData(
      title: typeLabel,
      amount: t.amount,
      currencySymbol: currencySymbol(t.currency),
      dateTime: formatDateTimeDisplay(t.date ?? DateTime.now()),
      details: [
        if (account != null)
          ReceiptDetail(label: _l10n.translate('currencyDetail'), value: '${isCashAccount(account.bankName) ? cashDisplayName() : account.bankName} (${currencySymbol(account.currency)})'),
        if (t.category.isNotEmpty)
          ReceiptDetail(label: _l10n.translate('transactionType'), value: t.category),
        if ((t.description ?? '').isNotEmpty)
          ReceiptDetail(label: _l10n.translate('description'), value: t.description!),
        ReceiptDetail(
          label: _l10n.translate('paymentMethod'),
          value: t.paymentMethod == 'cash'
              ? _l10n.translate('payMethodCash')
              : _l10n.translate('payMethodBank'),
        ),
      ],
    ), preset: preset);
  }

  void _exportStatement(List<PersonalTransaction> txs, PersonalBankAccount account) {
    final preset = ref.read(personalReceiptDesignProvider.notifier).getPreset('bank');
    final fmtDate = DateFormat('yyyy/MM/dd');
    final currency = _effectiveCurrency(account);
    final sym = _currencySymbol(currency);
    final income = txs.where((t) => t.type == 'income').fold<double>(0, (s, t) => s + t.amount);
    final expense = txs.where((t) => t.type == 'expense').fold<double>(0, (s, t) => s + t.amount);
    final net = income - expense;
    final fromStr = _filterFrom != null ? fmtDate.format(_filterFrom!) : _l10n.translate('statementPeriodFrom');
    final toStr = _filterTo != null ? fmtDate.format(_filterTo!) : _l10n.translate('statementPeriodTo');
    ReceiptModal.show(context, ReceiptData(
      title: _l10n.translate('bankStatementTitle', params: {'bankName': account.bankName}),
      amount: _groupBalance(ref.read(personalFinanceProvider), account, currency),
      currencySymbol: sym,
      dateTime: formatDateTimeDisplay(DateTime.now()),
      details: [
        ReceiptDetail(label: _l10n.translate('currencyDetail'), value: currency),
        ReceiptDetail(label: _l10n.translate('statementPeriod'), value: '$fromStr / $toStr'),
        ReceiptDetail(label: _l10n.translate('totalIncome'), value: '${fmtNum(income)} $sym'),
        ReceiptDetail(label: _l10n.translate('totalExpense'), value: '${fmtNum(expense)} $sym'),
        ReceiptDetail(label: _l10n.translate('net'), value: '${fmtNum(net)} $sym'),
        ...txs.map((t) => ReceiptDetail(
          label: '${t.date != null ? '${t.date!.month}/${t.date!.day}' : ''} ${t.category}',
          value: '${t.type == 'income' ? '+' : '-'}${fmtNum(t.amount)}',
        )),
      ],
    ), preset: preset);
  }

  Future<void> _confirmDelete(PersonalTransaction t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(_l10n.translate('confirmDeleteTransactionTitle'), style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
        content: Text(_l10n.translate('confirmDeleteTransaction'), style:  TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_l10n.translate('cancel'), style: const TextStyle(fontFamily: 'Cairo')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_l10n.translate('delete'), style: const TextStyle(fontFamily: 'Cairo', color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final deleted = await ref.read(personalFinanceProvider.notifier).deleteTransaction(t.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          deleted ? _l10n.translate('deletedSuccessfully') : _l10n.translate('personalErrDeleteTx'),
          style: const TextStyle(fontFamily: 'Cairo')),
      backgroundColor: deleted ? AppColors.success : AppColors.danger,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(personalFinanceProvider);
    final account = _resolveAccount(state);
    final group = account != null ? _bankGroup(state, account) : const <PersonalBankAccount>[];
    final currencies = account != null ? _currencies(state, account) : const <String>[];
    final txs = account != null ? _visibleTransactions(state, account) : const <PersonalTransaction>[];
    final accountLabel = account?.bankName ?? _l10n.translate('bankStatement');

    return state.isLoading && account == null
        ? const Center(child: DotsLoader())
        : account == null
          ? Center(child: Text(_l10n.translate('noTransactions'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textDisabled)))
          : ListView(
              padding: EdgeInsets.all(R.spacing(context, 12)),
              children: [
                _buildAccountHeader(account),
                const SizedBox(height: 12),
                if (group.length > 1) _buildCurrencyChips(account, currencies),
                const SizedBox(height: 12),
                _buildDateFilter(),
                const SizedBox(height: 12),
                _buildQuickAdd(account),
                const SizedBox(height: 12),
                if (state.isLoading)
                  const Padding(padding: EdgeInsets.all(24), child: Center(child: DotsLoader()))
                else if (txs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 32),
                    child: Center(
                      child: Column(children: [
                        TwoToneIcon(data: TwoToneIcons.receipt, size: 44, outlineColor: AppColors.textDisabled, detailColor: AppColors.textDisabled),
                        const SizedBox(height: 10),
                        Text(_l10n.translate('noTransactions'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textSecondary)),
                      ]),
                    ),
                  )
                else
                  ...txs.map((t) => _buildTransactionRow(t, _l10n)),
              ],
            );
  }

  Widget _buildAccountHeader(PersonalBankAccount account) {
    final balance = _groupBalance(ref.read(personalFinanceProvider), account, _effectiveCurrency(account));
    final sym = _currencySymbol(_effectiveCurrency(account));
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(12),
            ),
            child: TwoToneIcon(data: TwoToneIcons.bank, outlineColor: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isCashAccount(account.bankName) ? cashDisplayName() : account.bankName, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      '${currencyName(_effectiveCurrency(account))}',
                      style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textSecondary),
                    ),
                    if (_selectedAccount(account) != null) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withAlpha(20),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _accountTypeLabel(_selectedAccount(account)!.accountType),
                          style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 9), fontWeight: FontWeight.w600, color: AppColors.primary),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerEnd,
                child: MoneyText(amount: fmtNum(balance), currency: sym, style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 17),
                  fontWeight: FontWeight.w700,
                  color: balance >= 0 ? AppColors.success : AppColors.danger,
                )),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrencyChips(PersonalBankAccount account, List<String> currencies) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final c in currencies)
            _chip(
              label: _chipLabel(account, c),
              selected: c == _selCurrency || (_selCurrency == null && c.startsWith('${account.currency}:')),
              onTap: () => setState(() => _selCurrency = _selCurrency == c ? null : c),
            ),
        ],
      ),
    );
  }

  String _chipLabel(PersonalBankAccount account, String key) {
    final parts = key.split(':');
    final currency = parts[0];
    final type = parts.length > 1 ? parts[1] : account.accountType;
    return '$currency · ${_accountTypeLabel(type)}';
  }

  String _accountTypeLabel(String type) {
    switch (type) {
      case 'checking': return _l10n.translate('accountTypeChecking');
      case 'savings': return _l10n.translate('accountTypeSavings');
      case 'credit': return _l10n.translate('accountTypeCredit');
      case 'wallet': return _l10n.translate('accountTypeWallet');
      case 'cash': return _l10n.translate('accountTypeCash');
      default: return _l10n.translate('accountTypeChecking');
    }
  }

  Widget _chip({required String label, required bool selected, required VoidCallback onTap}) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AppColors.primary : AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: selected ? AppColors.primary : AppColors.divider.withOpacity(0.3)),
          ),
          child: Text(label, style: TextStyle(
            fontFamily: 'Cairo', fontSize: R.fontSize(context, 12),
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? Colors.white : AppColors.textSecondary,
          )),
        ),
      ),
    );
  }

  Widget _buildDateFilter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(Icons.date_range, size: 18, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: _dateChip(
              label: _l10n.translate('statementPeriodFrom'),
              date: _filterFrom,
              onTap: () => _pickFilterDate(isFrom: true),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _dateChip(
              label: _l10n.translate('statementPeriodTo'),
              date: _filterTo,
              onTap: () => _pickFilterDate(isFrom: false),
            ),
          ),
          if (_filterFrom != null || _filterTo != null)
            IconButton(
              icon:  Icon(Icons.close, size: 18, color: AppColors.textSecondary),
              onPressed: () => setState(() {
                _filterFrom = null;
                _filterTo = null;
              }),
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }

  Future<void> _pickFilterDate({required bool isFrom}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: isFrom
          ? (_filterFrom ?? now)
          : (_filterTo ?? _filterFrom ?? now),
      firstDate: DateTime(2000),
      lastDate: now,
      helpText: isFrom
          ? _l10n.translate('statementPeriodFrom')
          : _l10n.translate('statementPeriodTo'),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isFrom) {
        _filterFrom = picked;
        if (_filterTo != null && _filterTo!.isBefore(picked)) _filterTo = picked;
      } else {
        _filterTo = picked;
        if (_filterFrom != null && _filterFrom!.isAfter(picked)) _filterFrom = picked;
      }
    });
  }

  Widget _dateChip({required String label, required DateTime? date, required VoidCallback onTap}) {
    final fmt = DateFormat('yyyy/MM/dd');
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text('$label ', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.textSecondary)),
            ),
            Flexible(
              child: Text(date != null ? fmt.format(date) : '—', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), fontWeight: FontWeight.w700, color: AppColors.primary)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickAdd(PersonalBankAccount account) {
    final targetAccount = _selectedAccount(account) ?? account;
    return Row(children: [
      Expanded(
        child: _QuickBtn(
          label: _l10n.translate('addIncome'),
          icon: TwoToneIcons.income,
          color: AppColors.success,
          onTap: () => showAddTransactionSheet(context, initialType: 'income', prefillAccountId: targetAccount.id),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: _QuickBtn(
          label: _l10n.translate('addExpense'),
          icon: TwoToneIcons.expense,
          color: AppColors.danger,
          onTap: () => showAddTransactionSheet(context, initialType: 'expense', prefillAccountId: targetAccount.id),
        ),
      ),
    ]);
  }

  Widget _buildTransactionRow(PersonalTransaction t, AppLocalizations l10n) {
    final color = _transactionColor(t.type);
    final label = _transactionTypeLabel(t.type, l10n);
    final icon = _transactionIcon(t.type);
    return GestureDetector(
      onTap: () => _showTransactionReceipt(t),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: color.withAlpha(25),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: TwoToneIcon(data: icon, outlineColor: color, size: 16),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                    if ((t.description ?? '').isNotEmpty)
                      Text(t.description!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.textSecondary)),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('${t.type == 'income' ? '+' : '-'}${fmtNum(t.amount)}', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: color)),
                  if (t.date != null)
                    Text(
                      '${t.date!.year}-${t.date!.month.toString().padLeft(2, '0')}-${t.date!.day.toString().padLeft(2, '0')}',
                      style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: AppColors.textDisabled),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _ActionIcon(
                icon: Icons.delete_outline_rounded,
                color: AppColors.danger,
                onTap: () => _confirmDelete(t),
              ),
            ],
          ),
        ]),
      ),
    );
  }
}

class _QuickBtn extends StatelessWidget {
  final String label;
  final TwoToneIconData icon;
  final Color color;
  final VoidCallback onTap;
  const _QuickBtn({required this.label, required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(color: color.withAlpha(20), border: Border.all(color: color.withAlpha(60)), borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          TwoToneIcon(data: icon, size: 18, outlineColor: color, detailColor: color),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.w700, color: color)),
        ]),
      ),
    );
  }
}

class _ActionIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _ActionIcon({required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: color.withAlpha(18),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 16, color: color),
      ),
    );
  }
}