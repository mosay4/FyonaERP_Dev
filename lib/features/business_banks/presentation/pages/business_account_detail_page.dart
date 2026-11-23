import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart'
    show fmtNum, currencySymbol, currencyName;
import '../../../../shared/widgets/dots_loader.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/receipt/receipt.dart';
import '../../data/business_bank_models.dart';
import '../providers/business_banks_providers.dart';
import '../providers/local_business_banking.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/presentation/providers/business_ledger_session.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../bank_transaction_visual.dart';
import '../../../personal/presentation/providers/receipt_design_provider.dart';

/// Business account detail — mirrors the personal account-detail screen
/// exactly (header, currency chips, date filter, quick deposit/withdraw,
/// transaction rows with receipt view). No transaction delete: the backend
/// exposes no delete endpoint for bank transactions.
class BusinessAccountDetailPage extends ConsumerStatefulWidget {
  final String accountId;
  final LocalBankAccountTarget? localAccount;
  const BusinessAccountDetailPage({super.key, this.accountId = '', this.localAccount});
  @override
  ConsumerState<BusinessAccountDetailPage> createState() =>
      _BusinessAccountDetailPageState();
}

class _BusinessAccountDetailPageState
    extends ConsumerState<BusinessAccountDetailPage> {
  String _resolvedAccountId = '';
  bool _initialized = false;
  String? _selCurrency;
  DateTime? _filterFrom;
  DateTime? _filterTo;
  List<Map<String, dynamic>> _txs = [];
  bool _txLoading = false;
  String _txLoadedFor = '';
  String? _txError;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _initialized) return;
      _initialized = true;
      var id = widget.localAccount?.id ?? widget.accountId.trim();
      if (id.isEmpty) {
        id = (GoRouterState.of(context).pathParameters['id'] ?? '').trim();
      }
      if (id.isEmpty) {
        id = (GoRouterState.of(context).uri.queryParameters['accountId'] ?? '')
            .trim();
      }
      _resolvedAccountId = id;
      _bootstrap();
    });
  }

  AppLocalizations get _l10n => AppLocalizations.of(context);

  Future<void> _bootstrap() async {
    if (!mounted || !_allowSource()) return;
    await ref.read(businessBanksProvider.notifier).load();
    if (mounted && !_txLoading) await _loadTx();
  }

  bool _allowSource() {
    final active = ref.read(businessLocalLedgerScopeProvider);
    final target = widget.localAccount;
    if (target == null) return active == null;
    return target.allows(active) && ref.read(employeeCanProvider('banks.details'));
  }

  BusinessBankAccount? _resolveAccount(BusinessBanksState state) {
    for (final a in state.accounts) {
      if (a.id == _resolvedAccountId) return a;
    }
    return null;
  }

  /// All accounts of the same bank (any currency).
  List<BusinessBankAccount> _bankGroup(
      BusinessBanksState state, BusinessBankAccount account) {
    return state.accounts
        .where((a) => isBizCashAccount(account.bankName)
            ? isBizCashAccount(a.bankName)
            : account.groupKey.isNotEmpty
                ? a.groupKey == account.groupKey
                : a.bankName == account.bankName)
        .toList();
  }

  /// Currency codes available in this bank.
  List<String> _currencies(
      BusinessBanksState state, BusinessBankAccount account) {
    final list = <String>[];
    for (final a in _bankGroup(state, account)) {
      if (a.accountType != account.accountType) continue;
      if (!list.contains(a.currency)) list.add(a.currency);
    }
    return list;
  }

  List<BusinessBankAccount> _selectedAccounts(BusinessBankAccount account) {
    return _bankGroup(ref.read(businessBanksProvider), account)
        .where((a) => a.currency == _effectiveCurrency(account) &&
            a.accountType == account.accountType)
        .toList();
  }

  String _historyKey(BusinessBankAccount account) {
    final ids = _selectedAccounts(account).map((a) => a.id).toList()..sort();
    return ids.join('|');
  }

  String _effectiveCurrency(BusinessBankAccount account) {
    return _selCurrency ?? account.currency;
  }

  double _groupBalance(
      BusinessBanksState state, BusinessBankAccount account) {
    return _selectedAccounts(account)
        .fold<double>(0, (total, a) => total + a.balance);
  }

  Future<void> _loadTx() async {
    if (!mounted || !_allowSource()) return;
    final account = _resolveAccount(ref.read(businessBanksProvider));
    if (account == null) return;
    final source = ref.read(businessBanksProvider.notifier);
    final key = _historyKey(account);
    final generation = ++_loadGeneration;
    _txLoadedFor = key;
    setState(() {
      _txLoading = true;
      _txError = null;
    });
    try {
      final rows = await source.history(_selectedAccounts(account).map((a) => a.id).toList());
      if (!mounted || generation != _loadGeneration || !source.isCurrent ||
          !_allowSource()) return;
      final byId = {for (final row in rows) '${row['id']}': row};
      setState(() {
        _txs = byId.values.toList()
          ..sort((a, b) => '${b['date']}'.compareTo('${a['date']}'));
        _txLoading = false;
      });
    } catch (e) {
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _txLoading = false;
          _txError = _l10n.translate(source.isLocal ? 'txOperationFailed' : 'coreNetworkError');
        });
      }
    }
  }

  bool _matchesFilter(Map<String, dynamic> t) {
    DateTime? date;
    try {
      final raw = t['date']?.toString();
      if (raw != null && raw.isNotEmpty) date = DateTime.parse(raw);
    } catch (_) {}
    if (date == null) return _filterFrom == null && _filterTo == null;
    final day = DateTime(date.year, date.month, date.day);
    final from = _filterFrom;
    final to = _filterTo;
    if (from != null &&
        day.isBefore(DateTime(from.year, from.month, from.day))) {
      return false;
    }
    if (to != null &&
        day.isAfter(DateTime(to.year, to.month, to.day))) return false;
    return true;
  }

  void _showReceipt(Map<String, dynamic> t) {
    final type = (t['tx_type'] ?? '').toString();
    final preset = ref
        .read(personalReceiptDesignProvider.notifier)
        .getPreset('bank');
    ReceiptModal.show(
        context,
        ReceiptData(
          title: BankTransactionVisual(type).label(_l10n),
          amount: (t['amount'] is num)
              ? (t['amount'] as num).toDouble()
              : double.tryParse(t['amount']?.toString() ?? '') ?? 0,
          currencySymbol: currencySymbol((t['currency'] ?? '').toString()),
          dateTime: DateFormat('yyyy/MM/dd HH:mm')
              .format(DateTime.tryParse(t['date']?.toString() ?? '') ??
                  DateTime.now()),
          details: [
            if ((t['description'] ?? '').toString().isNotEmpty)
              ReceiptDetail(
                  label: _l10n.translate('description'),
                  value: t['description'].toString()),
          ],
        ),
        preset: preset);
  }

  @override
  Widget build(BuildContext context) {
    final local = ref.watch(businessLocalLedgerScopeProvider);
    final canReadDetails = ref.watch(employeeCanProvider('banks.details'));
    final state = ref.watch(businessBanksProvider);
    final target = widget.localAccount;
    final account = (target == null ? local == null : target.allows(local) && canReadDetails)
        ? _resolveAccount(state)
        : null;
    ref.listen(businessBanksProvider.notifier, (_, _) {
      _loadGeneration++;
      _txLoadedFor = '';
      _txLoading = false;
      _txs = [];
      _txError = null;
      _selCurrency = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _bootstrap();
      });
    });
    if (target != null) {
      ref.listen(businessBankRevisionProvider, (_, _) => _loadTx());
      ref.listen(employeeCanProvider('banks.details'), (_, allowed) {
        if (!allowed) {
          _loadGeneration++;
          _txLoadedFor = '';
          _txLoading = false;
          _txs = [];
        }
      });
    }
    if (account != null && _txLoadedFor != _historyKey(account) && !_txLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadTx());
    }
    final group =
        account != null ? _bankGroup(state, account) : const <BusinessBankAccount>[];
    final currencies =
        account != null ? _currencies(state, account) : const <String>[];
    final txs = account != null
        ? _txs.where((t) {
            final ids = _selectedAccounts(account).map((a) => a.id).toSet();
            final txAcct = _accountOf(t);
            if (txAcct != null && !ids.contains(txAcct)) return false;
            return _matchesFilter(t);
          }).toList()
        : const <Map<String, dynamic>>[];
    final accountLabel = account?.bankName ?? _l10n.translate('bankStatement');

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(accountLabel,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 18),
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary)),
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          color: AppColors.textPrimary,
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: state.isLoading && account == null
            ? const Center(child: DotsLoader())
            : account == null
                ? Center(
                    child: Text(_l10n.translate('noTransactions'),
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 14),
                            color: AppColors.textDisabled)))
                : ListView(
                    padding: EdgeInsets.all(R.spacing(context, 12)),
                    children: [
                      _buildAccountHeader(account),
                      const SizedBox(height: 12),
                      if (group.length > 1)
                        _buildCurrencyChips(account, currencies),
                      const SizedBox(height: 12),
                      _buildDateFilter(),
                      const SizedBox(height: 12),
                      if (_txLoading && widget.localAccount == null)
                        const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: DotsLoader()))
                       else if (_txError != null)
                         TextButton.icon(
                           onPressed: _loadTx,
                           icon: const Icon(Icons.refresh_rounded),
                           label: Text(_txError!),
                         )
                       else if (txs.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 32),
                          child: Center(
                            child: Column(children: [
                              TwoToneIcon(
                                  data: TwoToneIcons.receipt,
                                  size: 44,
                                  outlineColor: AppColors.textDisabled,
                                  detailColor: AppColors.textDisabled),
                              const SizedBox(height: 10),
                              Text(
                                  _l10n.translate('noTransactions'),
                                  style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize:
                                          R.fontSize(context, 14),
                                      color:
                                          AppColors.textSecondary)),
                            ]),
                          ),
                        )
                      else
                        ...txs.map((t) => _buildTransactionRow(t)),
                    ],
                  ),
      ),
    );
  }

  String? _accountOf(Map<String, dynamic> t) =>
      t['bank_account_id']?.toString();

  Widget _buildAccountHeader(BusinessBankAccount account) {
    final balance =
        _groupBalance(ref.read(businessBanksProvider), account);
    final sym = _effectiveCurrency(account);
    return Container(
      padding: const EdgeInsets.all(16),
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
            child: TwoToneIcon(
                data: TwoToneIcons.bank,
                outlineColor: Colors.white,
                size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    isBizCashAccount(account.bankName)
                        ? _l10n.translate('cashAccount')
                        : account.bankName,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 15),
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary)),
                const SizedBox(height: 2),
                Text(
                  currencyName(_effectiveCurrency(account)),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 12),
                      color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          if (ref.watch(businessBankBalanceReadProvider)) Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerEnd,
              child: Text('${fmtNum(balance)} $sym',
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 17),
                    fontWeight: FontWeight.w700,
                    color: balance >= 0
                        ? AppColors.success
                        : AppColors.danger,
                  )),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrencyChips(
      BusinessBankAccount account, List<String> currencies) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final c in currencies)
            _chip(
              label: c,
              selected: c == _selCurrency ||
                  (_selCurrency == null && c == account.currency),
              onTap: () {
                setState(() => _selCurrency = c);
                _loadTx();
              },
            ),
        ],
      ),
    );
  }

  Widget _chip(
      {required String label,
      required bool selected,
      required VoidCallback onTap}) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.primary
                : AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: selected
                    ? AppColors.primary
                    : AppColors.divider.withOpacity(0.3)),
          ),
          child: Text(label,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 12),
                fontWeight:
                    selected ? FontWeight.w700 : FontWeight.w500,
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
          const Icon(Icons.date_range,
              size: 18, color: AppColors.primary),
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
              icon: Icon(Icons.close,
                  size: 18, color: AppColors.textSecondary),
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
        if (_filterTo != null && _filterTo!.isBefore(picked)) {
          _filterTo = picked;
        }
      } else {
        _filterTo = picked;
        if (_filterFrom != null && _filterFrom!.isAfter(picked)) {
          _filterFrom = picked;
        }
      }
    });
  }

  Widget _dateChip(
      {required String label,
      required DateTime? date,
      required VoidCallback onTap}) {
    final fmt = DateFormat('yyyy/MM/dd');
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text('$label ',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 11),
                      color: AppColors.textSecondary)),
            ),
            Flexible(
              child: Text(date != null ? fmt.format(date) : '—',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 11),
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransactionRow(Map<String, dynamic> t) {
    final type = (t['tx_type'] ?? '').toString();
    final visual = BankTransactionVisual(type);
    final color = visual.color;
    final label = visual.label(_l10n);
    final icon = visual.icon;
    final amount = (t['amount'] is num)
        ? (t['amount'] as num).toDouble()
        : double.tryParse(t['amount']?.toString() ?? '') ?? 0;
    final isIn = visual.isIn;
    DateTime? date;
    try {
      final raw = t['date']?.toString();
      if (raw != null && raw.isNotEmpty) date = DateTime.parse(raw);
    } catch (_) {}
    return GestureDetector(
      onTap: () => _showReceipt(t),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
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
                  Text(label,
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 13),
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                  if ((t['description'] ?? '').toString().isNotEmpty)
                    Text(t['description'].toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 11),
                            color: AppColors.textSecondary)),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${isIn ? '+' : '-'}${fmtNum(amount.abs())}',
                    textDirection: TextDirection.ltr,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 13),
                        fontWeight: FontWeight.w700,
                        color: color)),
                if (date != null)
                  Text(
                    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 10),
                        color: AppColors.textDisabled),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
