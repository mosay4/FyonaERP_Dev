import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fyona_flutter/core/utils/document_number.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../../core/router/route_names.dart';
import '../../../dashboard/presentation/providers/business_dashboard_providers.dart';
import '../../data/business_finance_api.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/presentation/providers/business_ledger_session.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';

/// Business → «المعاملات»: a unified, newest-first timeline over the REAL
/// movements that already exist in the system (invoices, returns,
/// collections/supplier payments, expenses, bank movements). Read-only:
/// every row keeps its real source so the details page can open the
/// ORIGINAL invoice. Auto-refreshes (timer + on return) so new movements
/// appear without a manual refresh.
class BusinessTransactionsPage extends ConsumerStatefulWidget {
  const BusinessTransactionsPage({super.key});
  @override
  ConsumerState<BusinessTransactionsPage> createState() =>
      _BusinessTransactionsPageState();
}

class _BusinessTransactionsPageState
    extends ConsumerState<BusinessTransactionsPage> {
  final _searchCtrl = TextEditingController();
  final _scroll = ScrollController();
  Timer? _autoRefresh;

  String _search = '';
  String _kind = ''; // '' = all
  String _period = ''; // '' = all
  DateTime? _from; // custom range
  DateTime? _to; // custom range
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String _error = '';
  int _readGeneration = 0;
  BusinessFinanceApi? _itemsSource;

  @override
  void initState() {
    super.initState();
    _reload();
    // New movements surface without any manual refresh.
    _autoRefresh = Timer.periodic(
      const Duration(seconds: 12),
      (_) {
        if (ref.read(businessLocalLedgerScopeProvider) == null) {
          _reload(silent: true);
        }
      },
    );
  }

  @override
  void dispose() {
    _autoRefresh?.cancel();
    _searchCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload({bool silent = false}) async {
    final source = ref.read(businessFinanceApiProvider);
    final generation = ++_readGeneration;
    final local = source is LocalBusinessFinanceApi;
    bool current() => mounted && generation == _readGeneration &&
        identical(source, ref.read(businessFinanceApiProvider));
    if (!silent)
      setState(() {
        _loading = !local;
        _error = '';
        _items = [];
      });
    try {
      final raw = await source.listTransactions(
            kind: _kind.isEmpty ? null : _kind,
            period: _from == null ? (_period.isEmpty ? null : _period) : null,
            search: _search.isEmpty ? null : _search,
            dateFrom: _from == null
                ? null
                : DateFormat('yyyy-MM-dd').format(_from!),
            dateTo: _to == null ? null : DateFormat('yyyy-MM-dd').format(_to!),
          );
      if (current()) {
        setState(() {
          _items = [
            for (final s in raw.whereType<Map>()) Map<String, dynamic>.from(s),
          ];
          _itemsSource = source;
          _loading = false;
          _error = '';
        });
      }
    } catch (e) {
      if (current()) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  /// «فترة مخصصة»: TWO calendars — «من تاريخ» tinted burgundy, then
  /// «إلى تاريخ» tinted teal so the user can tell them apart. Both follow
  /// the app's light/dark theme automatically.
  Future<void> _pickCustomRange() async {
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
            // Distinct teal for the TO calendar.
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

  String _kindLabel(String k, AppLocalizations l10n) {
    const keys = {
      'sale': 'txKindSale',
      'purchase': 'txKindPurchase',
      'sale_return': 'txKindSaleReturn',
      'purchase_return': 'txKindPurchaseReturn',
      'collection': 'txKindCollection',
      'supplier_payment': 'txKindSupplierPayment',
      'income': 'txKindIncome',
      'expense': 'txKindExpense',
      'transfer': 'txKindTransfer',
      'transfer_reversal': 'txKindTransferReversal',
      'inventory_transfer': 'txKindInventoryTransfer',
      'bank_withdrawal': 'txKindBankWithdrawal',
      'withdrawal_reversal': 'bizCashWithdrawalReversed',
      'reconciliation': 'reconMovement',
      'opening': 'txKindOpening',
    };
    return l10n.translate(keys[k] ?? 'txKindSale');
  }

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(businessLocalLedgerScopeProvider);
    ref.listen(businessFinanceApiProvider, (_, __) => _reload());
    if (scope != null) {
      ref.listen(businessBankRevisionProvider, (_, __) => _reload(silent: true));
      ref.listen(businessOperationsRevisionProvider, (_, __) => _reload(silent: true));
      ref.listen(visibleBusinessOperationKindsProvider, (_, __) => _reload());
    }
    final allowed = scope == null ? null : ref.watch(visibleBusinessOperationKindsProvider);
    final currentSource = ref.watch(businessFinanceApiProvider);
    final items = !identical(_itemsSource, currentSource) ? const <Map<String, dynamic>>[]
        : scope == null ? _items : [
      for (final item in _items)
        if (item['branch_id'] == scope.branchId && allowed!.contains(item['kind']))
          item,
    ];
    final l10n = AppLocalizations.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Text(
          l10n.translate('bizTransactions'),
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
          // ── Search ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
            child: FyonaTextField(
              controller: _searchCtrl,
              onChanged: (v) {
                _search = v.trim();
                _reload();
              },
              decoration: InputDecoration(
                hintText: l10n.translate('txSearchHint'),
                prefixIcon: Icon(
                  Icons.search,
                  size: 20,
                  color: AppColors.textSecondary,
                ),
                isDense: true,
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppColors.border),
                ),
              ),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          // ── Type filter ──
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                _chip(l10n.translate('txAll'), _kind.isEmpty, () {
                  setState(() => _kind = '');
                  _reload();
                }),
                _chip(l10n.translate('txKindSale'), _kind == 'sale', () {
                  setState(() => _kind = 'sale');
                  _reload();
                }),
                _chip(
                  l10n.translate('txKindPurchase'),
                  _kind == 'purchase',
                  () {
                    setState(() => _kind = 'purchase');
                    _reload();
                  },
                ),
                _chip(l10n.translate('txKindReturn'), _kind == 'return', () {
                  setState(() => _kind = 'return');
                  _reload();
                }),
                _chip(l10n.translate('txKindPayment'), _kind == 'payment', () {
                  setState(() => _kind = 'payment');
                  _reload();
                }),
                _chip(l10n.translate('txKindIncome'), _kind == 'income', () {
                  setState(() => _kind = 'income');
                  _reload();
                }),
                _chip(l10n.translate('txKindExpense'), _kind == 'expense', () {
                  setState(() => _kind = 'expense');
                  _reload();
                }),
                _chip(
                  l10n.translate('txKindTransfer'),
                  _kind == 'transfer',
                  () {
                    setState(() => _kind = 'transfer');
                    _reload();
                  },
                ),
              ],
            ),
          ),
          // ── Period filter ──
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                _chip(
                  l10n.translate('txPeriodAll'),
                  _period.isEmpty && _from == null,
                  () {
                    setState(() {
                      _period = '';
                      _from = null;
                      _to = null;
                    });
                    _reload();
                  },
                ),
                _chip(
                  l10n.translate('txPeriodToday'),
                  _period == 'today' && _from == null,
                  () {
                    setState(() {
                      _period = 'today';
                      _from = null;
                      _to = null;
                    });
                    _reload();
                  },
                ),
                _chip(
                  l10n.translate('txPeriodWeek'),
                  _period == 'week' && _from == null,
                  () {
                    setState(() {
                      _period = 'week';
                      _from = null;
                      _to = null;
                    });
                    _reload();
                  },
                ),
                _chip(
                  l10n.translate('txPeriodMonth'),
                  _period == 'month' && _from == null,
                  () {
                    setState(() {
                      _period = 'month';
                      _from = null;
                      _to = null;
                    });
                    _reload();
                  },
                ),
                _chip(
                  _from != null
                      ? '${DateFormat('yyyy-MM-dd').format(_from!)}'
                            ' ← ${DateFormat('yyyy-MM-dd').format(_to!)}'
                      : l10n.translate('txPeriodCustom'),
                  _from != null,
                  _pickCustomRange,
                ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator.noSpinner(
              onRefresh: () => _reload(silent: true),
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : _error.isNotEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
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
                              textAlign: TextAlign.center,
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
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              child: Text(
                                l10n.translate('txRetry'),
                                style: const TextStyle(fontFamily: 'Cairo'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : items.isEmpty
                  ? Center(
                      child: Text(
                        l10n.translate('txEmpty'),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 13),
                          color: AppColors.textSecondary,
                        ),
                      ),
                    )
                  : ListView.separated(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                       itemCount: items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                         final t = items[i];
                        return _TxTile(
                          tx: t,
                          kindLabel: _kindLabel(
                            (t['kind'] ?? '').toString(),
                            l10n,
                          ),
                          dark: dark,
                          onTap: () async {
                            // Push the details; when it pops, refresh so
                            // anything changed there shows immediately.
                             if (!sameDirectoryScope(
                                 scope, ref.read(businessLocalLedgerScopeProvider))) return;
                             await openCommerceRecord(
                               context, RouteNames.businessTransactionDetails,
                               '${t['source_id']}', kind: '${t['source_type']}', fromLocal: scope,
                             );
                            if (mounted) _reload(silent: true);
                          },
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool active, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: GestureDetector(
        onTap: onTap,
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
}

class _TxTile extends StatelessWidget {
  final Map<String, dynamic> tx;
  final String kindLabel;
  final bool dark;
  final VoidCallback onTap;
  const _TxTile({
    required this.tx,
    required this.kindLabel,
    required this.dark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isIn = tx['direction'] == 'in';
    final accent = isIn ? AppColors.success : AppColors.danger;
    final amount = asDoubleValue(tx['amount']);
    final currency = (tx['currency'] ?? '').toString();
    final branchName = (tx['branch_name'] ?? '').toString();
    final party = (tx['party'] ?? '').toString();
    final account = (tx['account'] ?? '').toString();
    final reference = shortDocumentNumber(tx['reference']);
    final notes = (tx['notes'] ?? '').toString();

    String when = '';
    final iso = (tx['date'] ?? '').toString();
    if (iso.isNotEmpty) {
      final d = DateTime.tryParse(iso)?.toLocal();
      if (d != null) {
        String two(int n) => n.toString().padLeft(2, '0');
        when =
            '${d.year}/${two(d.month)}/${two(d.day)}  '
            '${two(d.hour)}:${two(d.minute)}';
      }
    }

    final meta = <String>[
      if (BranchScope.allMode && branchName.isNotEmpty)
        l10n.translate('branchOfTransaction', params: {'name': branchName}),
      if (reference.isNotEmpty) reference,
      if (account.isNotEmpty) account,
      if (when.isNotEmpty) when,
    ].join('  •  ');

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withAlpha(dark ? 40 : 26),
              ),
              child: Icon(
                isIn ? Icons.south : Icons.north,
                size: 18,
                color: dark ? accent.withAlpha(220) : accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    party.isNotEmpty ? '$kindLabel — $party' : kindLabel,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (meta.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        meta,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 10.5),
                          color: AppColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (notes.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        notes,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 10.5),
                          color: AppColors.textTertiary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text.rich(
              TextSpan(
                text: '${isIn ? '+' : '−'}${fmtNum(amount)}',
                children: [
                  if (currency.isNotEmpty)
                    TextSpan(
                      text: '  ${currencyLabel(currency)}',
                      style: TextStyle(
                        fontSize: R.fontSize(context, 9),
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 13),
                fontWeight: FontWeight.w800,
                color: dark ? accent.withAlpha(230) : accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
