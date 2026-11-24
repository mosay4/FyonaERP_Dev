import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fyona_flutter/core/utils/document_number.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../../shared/widgets/business_widgets.dart';
import '../../../sales/domain/sale_totals.dart' show parseMoney;
import '../providers/returns_providers.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/presentation/widgets/business_operation_error.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

/// Business → «المرتجعات»: two clear choices (customer / supplier return)
/// plus the previous returns list. Simple, merchant-friendly Arabic.
class ReturnsPage extends ConsumerStatefulWidget {
  const ReturnsPage({super.key});
  @override
  ConsumerState<ReturnsPage> createState() => _ReturnsPageState();
}

class _ReturnsPageState extends ConsumerState<ReturnsPage> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  String _kind = 'all';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final sourceScope = ref.watch(businessLocalLedgerScopeProvider);
    final listAsync = ref.watch(returnsListProvider(_kind));
    final items = listAsync.valueOrNull ?? const [];
    final base = _query.isEmpty
        ? items
        : items.where((e) {
            final m = Map<String, dynamic>.from(e as Map);
            final hay =
                '${m['return_number']} ${m['invoice_number']} '
                        '${m['party']} ${m['total']}'
                    .toLowerCase();
            return hay.contains(_query.toLowerCase());
          }).toList();
    // Newest → oldest (created_at when available, else the return date).
    final filtered = [...base]
      ..sort((a, b) {
        final ma = Map<String, dynamic>.from(a as Map);
        final mb = Map<String, dynamic>.from(b as Map);
        final da = (ma['created_at'] ?? ma['date'] ?? '').toString();
        final db = (mb['created_at'] ?? mb['date'] ?? '').toString();
        return db.compareTo(da);
      });

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          l10n.translate('bizReturns'),
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 18),
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
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
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (!BranchScope.readOnly)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(
                  children: [
                    if (ref.watch(employeeCanProvider('sales.returns')))
                      Expanded(
                        child: _NewOptionCard(
                          label: l10n.translate('retCustomerReturn'),
                          subtitle: l10n.translate('retCustomerReturnHint'),
                          icon: Icons.assignment_return_outlined,
                          color: AppColors.success,
                          onTap: () => context.push(
                            '${RouteNames.returnsAdd}?kind=sale_return',
                          ),
                        ),
                      ),
                    if (ref.watch(employeeCanProvider('sales.returns')) &&
                        ref.watch(employeeCanProvider('purchases.returns')))
                      const SizedBox(width: 12),
                    if (ref.watch(employeeCanProvider('purchases.returns')))
                      Expanded(
                        child: _NewOptionCard(
                          label: l10n.translate('retSupplierReturn'),
                          subtitle: l10n.translate('retSupplierReturnHint'),
                          icon: Icons.assignment_returned_outlined,
                          color: AppColors.danger,
                          onTap: () => context.push(
                            '${RouteNames.returnsAdd}?kind=purchase_return',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _KindChip(
                    label: l10n.translate('txAll'),
                    active: _kind == 'all',
                    onTap: () => setState(() => _kind = 'all'),
                  ),
                  const SizedBox(width: 8),
                  if (ref.watch(employeeCanProvider('sales.returns')))
                    _KindChip(
                      label: l10n.translate('retCustomerReturn'),
                      active: _kind == 'sale_return',
                      onTap: () => setState(() => _kind = 'sale_return'),
                    ),
                  const SizedBox(width: 8),
                  if (ref.watch(employeeCanProvider('purchases.returns')))
                    _KindChip(
                      label: l10n.translate('retSupplierReturn'),
                      active: _kind == 'purchase_return',
                      onTap: () => setState(() => _kind = 'purchase_return'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SearchBarWidget(
              controller: _searchCtrl,
              hintText: l10n.translate('retSearchHint'),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  l10n.translate('retPrevious'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 14),
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ),
            Expanded(
              child: FyonaRefresh(
                color: AppColors.primary,
                onRefresh: () async {
                  ref.invalidate(returnsListProvider(_kind));
                },
                child: listAsync.when(
                  loading: () => sourceScope != null
                      ? const SizedBox.shrink()
                      : const Center(child: CircularProgressIndicator()),
                  error: (e, _) => EmptyStateWidget(
                    title: l10n.translate('errorOccurred'),
                    subtitle: businessOperationError(
                      l10n,
                      e,
                      fallback: 'txOperationFailed',
                    ),
                  ),
                  data: (_) {
                    if (filtered.isEmpty) {
                      return ListView(
                        children: [
                          const SizedBox(height: 80),
                          EmptyStateWidget(
                            title: l10n.translate('retNoReturns'),
                          ),
                        ],
                      );
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      itemCount: filtered.length,
                      itemBuilder: (context, i) {
                        final r = Map<String, dynamic>.from(filtered[i] as Map);
                        return _ReturnTile(
                          ret: r,
                          onTap: () => openCommerceRecord(
                            context,
                            RouteNames.returnsView,
                             '${r['id']}',
                             kind: '${r['kind']}',
                             fromLocal: sourceScope,
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewOptionCard extends StatelessWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _NewOptionCard({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: color.withAlpha(90)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withAlpha(25),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 10),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 14),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 3,
              softWrap: true,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 10),
                height: 1.35,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KindChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _KindChip({
    required this.label,
    required this.active,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? AppColors.primary.withAlpha(24) : AppColors.surface,
            border: Border.all(
              color: active
                  ? AppColors.primary.withAlpha(90)
                  : AppColors.border,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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

class _ReturnTile extends StatelessWidget {
  final Map<String, dynamic> ret;
  final VoidCallback onTap;
  const _ReturnTile({required this.ret, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isSale = (ret['kind'] ?? '') == 'sale_return';
    final color = isSale ? AppColors.success : AppColors.danger;
    final kindLabel = l10n.translate(
      isSale ? 'retCustomerReturn' : 'retSupplierReturn',
    );
    final party = (ret['party'] ?? '').toString();
    final currency = (ret['currency'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: AppColors.border),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 4,
          ),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withAlpha(22),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              isSale ? Icons.south_west : Icons.north_east,
              color: color,
              size: 20,
            ),
          ),
          title: Text(
            shortDocumentNumber(ret['return_number']),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 14),
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          subtitle: Text(
            '$kindLabel${party.isNotEmpty ? ' • $party' : ''} • '
            '${parseMoney(ret['total'])} $currency',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 12),
              color: AppColors.textSecondary,
            ),
          ),
          trailing: Icon(
            Icons.chevron_left_rounded,
            color: AppColors.textSecondary,
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}
