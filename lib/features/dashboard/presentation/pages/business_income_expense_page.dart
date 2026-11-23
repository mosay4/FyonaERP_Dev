import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/receipt/receipt_data.dart';
import '../../../../shared/widgets/receipt/receipt_modal.dart';
import '../../../dashboard/presentation/providers/business_dashboard_providers.dart';
import 'widgets/business_add_movement_sheet.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../core_business/data/local_directory/directory_database.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../../core_business/presentation/providers/business_ledger_session.dart';

/// Business → «المصروف/المدخول»:
///   • Shows ONLY the manually created operations from «إضافة دخل» /
///     «سحب مصروف» (direct bank deposit/withdraw movements). Sale/purchase
///     invoices, returns and automatic invoice collections are excluded here
///     and remain visible in «المعاملات».
///   • Top filter: الكل (brand) / المدخولات (green) / المصروفات (red)
///   • Contextual actions: إضافة دخل (green) and/or سحب مصروف (red)
///   • Period filters per mode: اليوم / الأسبوع / فترة محددة (two tinted
///     calendars) — everything theme-aware.
///   • Rows follow the personal home style: income = green ↙, expense = red ↗
///     (two-tone arrows), amount colored, date on the end column.
///   • Tap → the personal-style receipt (ReceiptModal) with the real data.
///
/// The personal section is the visual/functional reference — untouched.
class BusinessIncomeExpensePage extends ConsumerStatefulWidget {
  const BusinessIncomeExpensePage({super.key});
  @override
  ConsumerState<BusinessIncomeExpensePage> createState() =>
      _BusinessIncomeExpensePageState();
}

class _BusinessIncomeExpensePageState
    extends ConsumerState<BusinessIncomeExpensePage> {
  String _mode = 'all'; // all | income | expense
  String _period = ''; // '' | today | week
  DateTime? _from;
  DateTime? _to;

  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String _error = '';

  int _readGeneration = 0;
  DirectoryAccess? _rowsScope;

  @override
  void initState() {
    super.initState();

    _reload();
  }

  Future<void> _reload() async {
    final generation = ++_readGeneration;
    final scope = ref.read(businessLocalLedgerScopeProvider);
    setState(() {
      _loading = scope == null;
      _error = '';
      if (scope == null || !sameDirectoryScope(_rowsScope, scope)) _items = [];
      _rowsScope = scope;
    });
    try {
      final raw = scope != null ? await _localMovements(scope) : await ref
          .read(businessFinanceApiProvider)
          .listTransactions(
            kind: 'inout',
            period: _from == null ? (_period.isEmpty ? null : _period) : null,
            dateFrom: _from == null
                ? null
                : DateFormat('yyyy-MM-dd').format(_from!),
            dateTo: _to == null ? null : DateFormat('yyyy-MM-dd').format(_to!),
          );
      if (mounted && generation == _readGeneration &&
          sameDirectoryScope(scope, ref.read(businessLocalLedgerScopeProvider))) {
        // This section shows ONLY the operations created manually through
        // «إضافة دخل» / «سحب مصروف»: direct bank movements with no document
        // reference. Sale/purchase invoices, returns and the automatic
        // invoice collections stay visible in «المعاملات».
        final rows = [
          for (final s in raw.whereType<Map>()) Map<String, dynamic>.from(s),
        ];
        final manual = rows
            .where((t) {
              final isBankTx = (t['source_type'] ?? '') == 'bank_tx';
              final isExpense = t['source_type'] == 'expense' && t['bank_account_id'] != null;
              final ref = (t['reference'] ?? '').toString();
              final k = (t['kind'] ?? '').toString();
              final isManualKind = k == 'income' || k == 'bank_withdrawal';
              return (isBankTx || isExpense) && ref.isEmpty && isManualKind;
            })
            .where((t) {
              if (_mode == 'income') return t['kind'] == 'income';
              if (_mode == 'expense') return t['kind'] == 'bank_withdrawal';
              return true;
            })
            .toList();
        setState(() {
          _items = manual;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted && generation == _readGeneration) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<List<Map<String, dynamic>>> _localMovements(DirectoryAccess scope) {
    final now = DateTime.now().toUtc();
    final from = _from;
    final to = _to;
    final incomes = _mode != 'expense' && ref.read(employeeCanProvider('income'));
    final expenses = _mode != 'income' && ref.read(employeeCanProvider('expenses'));
    if (!incomes && !expenses) return Future.value(const []);
    return withBusinessLedger(
      ref, scope, BusinessLedgerAction.readManualMovements,
      [if (incomes) 'income', if (expenses) 'expenses'],
      (ledger, grant) => ledger.manualMovements(
        grant,
        showIncome: incomes,
        showExpenses: expenses,
        from: from != null
            ? DateTime.utc(from.year, from.month, from.day)
            : switch (_period) {
                'today' => DateTime.utc(now.year, now.month, now.day),
                'week' => now.subtract(const Duration(days: 7)),
                _ => null,
              },
        to: to == null ? null : DateTime.utc(to.year, to.month, to.day + 1),
      ),
    );
  }

  /// Two calendars — «من تاريخ» burgundy, «إلى تاريخ» teal (like the
  /// transactions page) so the user can tell them apart. Theme-aware.
  Future<void> _pickRange() async {
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = Theme.of(context);

    DateTime? from = await showDatePicker(
      context: context,
      initialDate: _from ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 1, 12, 31),
      helpText: l10n.translate('txFromDate'),
      builder: (ctx, child) => Theme(
        data: base.copyWith(
          brightness: dark ? Brightness.dark : Brightness.light,
          colorScheme: base.colorScheme.copyWith(
            brightness: dark ? Brightness.dark : Brightness.light,
            primary: AppColors.primary,
          ),
        ),
        child: child!,
      ),
    );
    if (from == null || !mounted) return;

    DateTime? to = await showDatePicker(
      context: context,
      initialDate: _to != null && !_to!.isBefore(from) ? _to! : from,
      firstDate: from,
      lastDate: DateTime(now.year + 1, 12, 31),
      helpText: l10n.translate('txToDate'),
      builder: (ctx, child) => Theme(
        data: base.copyWith(
          brightness: dark ? Brightness.dark : Brightness.light,
          colorScheme: base.colorScheme.copyWith(
            brightness: dark ? Brightness.dark : Brightness.light,
            primary: const Color(0xFF00897B),
          ),
        ),
        child: child!,
      ),
    );
    if (to == null || !mounted) return;
    setState(() {
      _from = from;
      _to = to;
      _period = '';
    });
    _reload();
  }

  void _openMovement(String type) {
    final scope = ref.read(businessLocalLedgerScopeProvider);
    showBusinessAddMovementSheet(
      context,
      initialType: type,
      localScope: scope,
      onDone: () {
        if (!mounted) return;
        if (scope == null) ref.invalidate(businessRecentProvider);
        _reload();
      },
    );
  }

  String _kindLabel(String k, AppLocalizations l10n) {
    const keys = {
      'income': 'txKindIncome',
      'expense': 'txKindExpense',
      'bank_withdrawal': 'txKindExpense',
      'collection': 'txKindCollection',
    };
    return l10n.translate(keys[k] ?? 'txKindIncome');
  }

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(businessLocalLedgerScopeProvider);
    ref.listen(businessLocalLedgerScopeProvider, (old, next) {
      if (!sameDirectoryScope(old, next)) _reload();
    });
    if (scope == null) ref.listen(businessFinanceApiProvider, (_, __) => _reload());
    if (scope != null) ref.listen(businessBankRevisionProvider, (_, __) => _reload());
    for (final key in ['income', 'expenses']) {
      ref.listen(employeeCanProvider(key), (old, next) {
        if (scope != null && old != next) _reload();
      });
    }
    final rows = !sameDirectoryScope(_rowsScope, scope) ? const <Map<String, dynamic>>[]
        : scope == null ? _items
        : [
            for (final row in _items)
              if (ref.watch(employeeCanProvider(row['kind'] == 'income' ? 'income' : 'expenses')))
                row,
          ];
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Text(
          l10n.translate('bizExpenses'),
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 17),
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // ── Top mode filter: الكل / المدخولات / المصروفات ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: _modeChip(
                    l10n.translate('txAll'),
                    'all',
                    AppColors.primary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _modeChip(
                    l10n.translate('txIncomes'),
                    'income',
                    AppColors.success,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _modeChip(
                    l10n.translate('txExpenses'),
                    'expense',
                    AppColors.danger,
                  ),
                ),
              ],
            ),
          ),
          // ── Contextual actions (hidden in read-only all-branches view) ──
          if (!BranchScope.readOnly)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
              child: Row(
                children: [
                  if (_mode != 'expense' &&
                      ref.watch(employeeCanProvider('income')))
                    Expanded(
                      child: _actionButton(
                        l10n.translate('bizAddIncome'),
                        AppColors.success,
                        Icons.add_circle_outline,
                        () => _openMovement('income'),
                      ),
                    ),
                  if (_mode == 'all' &&
                      ref.watch(employeeCanProvider('income')) &&
                      ref.watch(employeeCanProvider('expenses')))
                    const SizedBox(width: 10),
                  if (_mode != 'income' &&
                      ref.watch(employeeCanProvider('expenses')))
                    Expanded(
                      child: _actionButton(
                        l10n.translate('bizWithdrawExpense'),
                        AppColors.danger,
                        Icons.remove_circle_outline,
                        () => _openMovement('expense'),
                      ),
                    ),
                ],
              ),
            ),
          // ── Period filter (labels follow the selected mode) ──
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                _periodChip(
                  _mode == 'income'
                      ? l10n.translate('txIncomeAll')
                      : _mode == 'expense'
                      ? l10n.translate('txExpenseAll')
                      : l10n.translate('txAll'),
                  _period.isEmpty && _from == null,
                  () => setState(() {
                    _period = '';
                    _from = null;
                    _to = null;
                  }),
                ),
                _periodChip(
                  _mode == 'income'
                      ? l10n.translate('txIncomeToday')
                      : _mode == 'expense'
                      ? l10n.translate('txExpenseToday')
                      : l10n.translate('txPeriodToday'),
                  _period == 'today' && _from == null,
                  () => setState(() {
                    _period = 'today';
                    _from = null;
                    _to = null;
                  }),
                ),
                _periodChip(
                  _mode == 'income'
                      ? l10n.translate('txIncomeWeek')
                      : _mode == 'expense'
                      ? l10n.translate('txExpenseWeek')
                      : l10n.translate('txPeriodWeek'),
                  _period == 'week' && _from == null,
                  () => setState(() {
                    _period = 'week';
                    _from = null;
                    _to = null;
                  }),
                ),
                _periodChip(
                  _from != null
                      ? '${DateFormat('yyyy-MM-dd').format(_from!)}'
                            ' ← ${DateFormat('yyyy-MM-dd').format(_to!)}'
                      : l10n.translate('txPeriodCustom'),
                  _from != null,
                  _pickRange,
                ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reload,
               child: _loading && scope == null
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : _error.isNotEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.cloud_off_outlined,
                            size: 40,
                            color: AppColors.textSecondary,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            l10n.translate('txLoadError'),
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 13),
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 12),
                          ElevatedButton(
                            onPressed: _reload,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              foregroundColor: Colors.white,
                            ),
                            child: Text(
                              l10n.translate('txRetry'),
                              style: const TextStyle(fontFamily: 'Cairo'),
                            ),
                          ),
                        ],
                      ),
                    )
                   : rows.isEmpty
                  ? ListView(
                      children: [
                        const SizedBox(height: 120),
                        Center(
                          child: Text(
                            l10n.translate('txEmpty'),
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 13),
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                       itemCount: rows.length,
                      itemBuilder: (context, i) => _MovementTile(
                         tx: rows[i],
                        kindLabel: _kindLabel(
                           (rows[i]['kind'] ?? '').toString(),
                          l10n,
                        ),
                         onTap: () => _showReceipt(rows[i], l10n),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeChip(String label, String mode, Color color) {
    final active = _mode == mode;
    return GestureDetector(
      onTap: () {
        setState(() => _mode = mode);
        _reload();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? color.withAlpha(28) : AppColors.surface,
          border: Border.all(color: active ? color : AppColors.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 13),
            fontWeight: FontWeight.w800,
            color: active ? color : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _actionButton(
    String label,
    Color color,
    IconData icon,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: Colors.white),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 13),
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _periodChip(String label, bool active, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: GestureDetector(
        onTap: () {
          onTap();
          _reload();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? AppColors.primary.withAlpha(24) : AppColors.surface,
            border: Border.all(
              color: active
                  ? AppColors.primary.withAlpha(90)
                  : AppColors.border,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 12),
              fontWeight: active ? FontWeight.w800 : FontWeight.w500,
              color: active ? AppColors.primary : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  /// Details — the personal section's receipt modal (same design), filled
  /// with the real business data.
  void _showReceipt(Map<String, dynamic> t, AppLocalizations l10n) {
    final isIn = t['direction'] == 'in';
    final amount = asDoubleValue(t['amount']);
    final currency = (t['currency'] ?? '').toString();
    final iso = (t['date'] ?? '').toString();
    final dt = DateTime.tryParse(iso)?.toLocal();
    final kind = _kindLabel((t['kind'] ?? '').toString(), l10n);
    final reference = (t['reference'] ?? '').toString();
    final account = (t['account'] ?? '').toString();
    final notes = (t['notes'] ?? '').toString();
    final party = (t['party'] ?? '').toString();

    final data = ReceiptData(
        title: l10n.translate(isIn ? 'deposit' : 'withdrawal'),
        amount: amount,
        currencySymbol: currency.isEmpty ? '' : currencySymbol(currency),
        dateTime: dt != null ? DateFormat('yyyy/MM/dd HH:mm').format(dt) : '-',
        referenceNumber: reference.isNotEmpty
            ? reference
            : '#${t['source_id']}',
        senderName: isIn ? (notes.isNotEmpty ? notes : kind) : null,
        receiverName: !isIn ? (notes.isNotEmpty ? notes : kind) : null,
        details: [
          ReceiptDetail(label: l10n.translate('txDetailType'), value: kind),
          if (party.isNotEmpty)
            ReceiptDetail(
              label: l10n.translate('txPartyCustomer'),
              value: party,
            ),
          if (account.isNotEmpty)
            ReceiptDetail(label: l10n.translate('txAccount'), value: account),
          if (notes.isNotEmpty)
            ReceiptDetail(label: l10n.translate('description'), value: notes),
        ],
    );
    ReceiptModal.show(context, data);
  }
}

/// Personal-style row: income = green ↙ (arrowDown), expense = red ↗ (arrowUp).
class _MovementTile extends StatelessWidget {
  final Map<String, dynamic> tx;
  final String kindLabel;
  final VoidCallback onTap;
  const _MovementTile({
    required this.tx,
    required this.kindLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isIn = tx['direction'] == 'in';
    final color = isIn ? AppColors.success : AppColors.danger;
    final iconData = isIn ? TwoToneIcons.arrowDown : TwoToneIcons.arrowUp;
    final amount = asDoubleValue(tx['amount']);
    final currency = (tx['currency'] ?? '').toString();
    final amt =
        '${isIn ? '+' : '-'}${fmtNum(amount)}'
        '${currency.isEmpty ? '' : ' ${currencySymbol(currency)}'}';

    String date = '';
    final iso = (tx['date'] ?? '').toString();
    if (iso.isNotEmpty) {
      final d = DateTime.tryParse(iso)?.toLocal();
      if (d != null) date = DateFormat('yyyy-MM-dd').format(d);
    }

    final account = (tx['account'] ?? '').toString();
    final notes = (tx['notes'] ?? '').toString();
    final sub = notes.isNotEmpty ? notes : (account.isNotEmpty ? account : '');

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(
            bottom: BorderSide(color: AppColors.divider, width: 1),
          ),
        ),
        child: Row(
          children: [
            TwoToneIcon(
              data: iconData,
              detailColor: AppColors.primary,
              outlineColor: AppColors.textSecondary,
              size: 22,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    kindLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 14),
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  if (sub.isNotEmpty)
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11),
                        fontWeight: FontWeight.w400,
                        color: AppColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  amt,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 14),
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
                Text(
                  date,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 10),
                    fontWeight: FontWeight.w400,
                    color: AppColors.textDisabled,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
