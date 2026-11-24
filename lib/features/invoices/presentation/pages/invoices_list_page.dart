import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fyona_flutter/core/utils/document_number.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/business_widgets.dart';
import '../../../sales/domain/sale_totals.dart' show parseMoney;
import '../../../returns/presentation/providers/returns_providers.dart';
import '../providers/invoices_providers.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../data/invoices_api.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';
import '../../../core_business/presentation/widgets/business_operation_error.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

/// Unified Business «الفواتير» center: a buy/sell filter, search by invoice
/// number / customer name / phone, and a precise date filter. No "new
/// invoice" button (creation happens from the home grid).
class InvoicesListPage extends ConsumerStatefulWidget {
  const InvoicesListPage({super.key});
  @override
  ConsumerState<InvoicesListPage> createState() => _InvoicesListPageState();
}

class _InvoicesListPageState extends ConsumerState<InvoicesListPage> {
  final _searchCtrl = TextEditingController();
  String _type = 'sale'; // 'sale' | 'purchase' | 'return'
  String _search = '';
  DateTime? _date;
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  Object? _error;
  int _generation = 0;
  DirectoryAccess? _loadedScope;
  InvoicesApi? _loadingSource;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final scope = ref.read(businessLocalLedgerScopeProvider);
    final invoices = ref.read(invoicesApiProvider);
    final returns = ref.read(returnsApiProvider);
    bool current() => mounted &&
        generation == _generation &&
        identical(invoices, ref.read(invoicesApiProvider)) &&
        identical(returns, ref.read(returnsApiProvider));
    setState(() {
      _loading = true;
      _error = null;
      _loadingSource = invoices;
    });
    try {
      final raw = _type == 'return'
          ? await returns.list(search: _search.isEmpty ? null : _search)
          : await invoices.list(type: _type, search: _search);
      if (!current()) return;
      setState(() {
        _items = [
          for (final m in raw.whereType<Map>())
            Map<String, dynamic>.from(m)
        ];
        _loading = false;
        _loadedScope = scope;
      });
    } catch (e) {
      if (!current()) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  bool _matchesDate(Map<String, dynamic> inv) {
    if (_date == null) return true;
    final dt =
        DateTime.tryParse((inv['invoice_date'] ?? inv['date'] ?? '').toString());
    if (dt == null) return false;
    return dt.year == _date!.year &&
        dt.month == _date!.month &&
        dt.day == _date!.day;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 1, 12, 31),
      builder: (ctx, child) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        final base = Theme.of(context);
        return Theme(
          data: base.copyWith(
            brightness: dark ? Brightness.dark : Brightness.light,
            colorScheme: base.colorScheme.copyWith(
                brightness: dark ? Brightness.dark : Brightness.light,
                primary: AppColors.primary),
          ),
          child: child!,
        );
      },
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final error = _error;
    ref.listen(invoicesApiProvider, (previous, next) {
      if (!identical(previous, next)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && identical(next, ref.read(invoicesApiProvider))) _load();
        });
      }
    });
    final source = ref.watch(invoicesApiProvider);
    final scope = ref.watch(businessLocalLedgerScopeProvider);
    final loadedScope = _loadedScope;
    final filtered = _items.where(_matchesDate).toList();
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          color: AppColors.textPrimary,
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go(RouteNames.dashboard);
            }
          },
        ),
        title: Text(l10n.translate('bizInvoices'),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 17),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
      ),
      body: SafeArea(
        child: Column(children: [
          // Type filter.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(children: [
              Expanded(
                child: _typeChip(
                    l10n.translate('invTypeSale'), 'sale', Icons.sell_outlined),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _typeChip(l10n.translate('invTypePurchase'), 'purchase',
                    Icons.shopping_bag_outlined),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _typeChip(l10n.translate('invTypeReturn'), 'return',
                    Icons.assignment_return_outlined),
              ),
            ]),
          ),
          SearchBarWidget(
            controller: _searchCtrl,
            hintText: l10n.translate('invListSearchHint'),
            onChanged: (v) {
              _search = v.trim();
              _load();
            },
          ),
          // Date filter.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Row(children: [
              Expanded(
                child: GestureDetector(
                  onTap: _pickDate,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: _date == null
                          ? AppColors.surface
                          : AppColors.primary.withAlpha(20),
                      border: Border.all(
                          color: _date == null
                              ? AppColors.border
                              : AppColors.primary),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(children: [
                      Icon(Icons.calendar_today_outlined,
                          size: 16,
                          color: _date == null
                              ? AppColors.textSecondary
                              : AppColors.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _date == null
                              ? l10n.translate('invFilterDate')
                              : '${_date!.year}/${_date!.month.toString().padLeft(2, '0')}/${_date!.day.toString().padLeft(2, '0')}',
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 12),
                              fontWeight: FontWeight.w600,
                              color: _date == null
                                  ? AppColors.textSecondary
                                  : AppColors.primary),
                        ),
                      ),
                      if (_date != null)
                        GestureDetector(
                          onTap: () => setState(() => _date = null),
                          child: Icon(Icons.close,
                              size: 16, color: AppColors.textSecondary),
                        ),
                    ]),
                  ),
                ),
              ),
            ]),
          ),
          Expanded(
            child: FyonaRefresh(
              color: AppColors.primary,
              onRefresh: _load,
               child: _loading || !identical(_loadingSource, source)
                  ? (scope != null ? const SizedBox.shrink()
                      : const Center(child: CircularProgressIndicator()))
                   : error != null
                       ? EmptyStateWidget(
                           title: l10n.translate('errorOccurred'),
                           subtitle: businessOperationError(l10n, error, fallback: 'txOperationFailed'))
                      : filtered.isEmpty
                          ? ListView(children: [
                              const SizedBox(height: 80),
                              EmptyStateWidget(
                                  title: l10n.translate('saleNoInvoices')),
                            ])
                          : ListView.builder(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 4, 16, 24),
                              itemCount: filtered.length,
                              itemBuilder: (context, i) => _type == 'return'
                                  ? _ReturnTile(
                                      ret: filtered[i],
                                       onTap: () => openCommerceRecord(context, RouteNames.returnsView,
                                            '${filtered[i]['id']}', kind: '${filtered[i]['kind']}',
                                            fromLocal: loadedScope),
                                    )
                                  : _InvoiceTile(
                                      inv: filtered[i],
                                       onTap: () => openCommerceRecord(context, RouteNames.invoicesView,
                                            '${filtered[i]['id']}', kind: '${filtered[i]['invoice_type'] ?? _type}',
                                            fromLocal: loadedScope),
                                    ),
                            ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _typeChip(String label, String type, IconData icon) {
    final active = _type == type;
    return GestureDetector(
      onTap: () {
        setState(() => _type = type);
        _load();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? AppColors.primary : AppColors.surface,
          border: Border.all(
              color: active ? AppColors.primary : AppColors.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 15,
                color: active ? Colors.white : AppColors.textSecondary),
            const SizedBox(width: 4),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(label,
                    maxLines: 1,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 12),
                        fontWeight: FontWeight.w800,
                        color: active ? Colors.white : AppColors.textSecondary)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InvoiceTile extends StatelessWidget {
  final Map<String, dynamic> inv;
  final VoidCallback onTap;
  const _InvoiceTile({required this.inv, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isSale = (inv['invoice_type'] ?? '') == 'sale';
    final party = (isSale
            ? (inv['customer_name'] ?? '')
            : (inv['supplier_name'] ?? ''))
        .toString();
    final phone = (isSale
            ? (inv['customer_phone'] ?? '')
            : (inv['supplier_phone'] ?? ''))
        .toString();
    final currency = (inv['currency'] ?? '').toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        // Burgundy frame around every invoice.
        border: Border.all(color: AppColors.primary, width: 1.4),
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(20),
              borderRadius: BorderRadius.circular(10)),
          child: Icon(
              isSale ? Icons.sell_outlined : Icons.shopping_bag_outlined,
              color: AppColors.primary,
              size: 20),
        ),
        title: Text(shortDocumentNumber(inv['invoice_number']),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 14),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
        subtitle: Text(
          '${party.isEmpty ? l10n.translate(isSale ? 'saleCashCustomer' : 'purCashSupplier') : party}'
          '${phone.isNotEmpty ? ' • $phone' : ''} • '
          '${parseMoney(inv['total'])} $currency',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 11.5),
              color: AppColors.textSecondary),
        ),
        trailing: StatusBadge(status: (inv['status'] ?? '').toString()),
        onTap: onTap,
      ),
    );
  }
}

class _ReturnTile extends StatelessWidget {
  final Map<String, dynamic> ret;
  final VoidCallback onTap;
  const _ReturnTile({required this.ret, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isSale = (ret['kind'] ?? '') == 'sale_return';
    final party = (ret['party'] ?? '').toString();
    final currency = (ret['currency'] ?? '').toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.primary, width: 1.4),
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(20),
              borderRadius: BorderRadius.circular(10)),
          child: Icon(
              isSale ? Icons.south_west : Icons.north_east,
              color: AppColors.primary,
              size: 20),
        ),
        title: Text(shortDocumentNumber(ret['return_number']),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 14),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
        subtitle: Text(
          '${l10n.translate(isSale ? 'retCustomerReturn' : 'retSupplierReturn')}'
          '${party.isNotEmpty ? ' • $party' : ''} • '
          '${parseMoney(ret['total'])} $currency',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 11.5),
              color: AppColors.textSecondary),
        ),
        trailing: StatusBadge(status: (ret['status'] ?? '').toString()),
        onTap: onTap,
      ),
    );
  }
}
