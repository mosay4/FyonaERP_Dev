import 'package:flutter/material.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';
import 'package:fyona_flutter/core/utils/document_number.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/presentation/widgets/business_operation_error.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/business_widgets.dart';
import '../providers/sale_providers.dart';
import '../../domain/sale_totals.dart' show parseMoney;
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

/// Minimal sale-invoices home (the «الفواتير» button target): search +
/// list with status badges. Detail lives on the view page.
class SaleInvoicesPage extends ConsumerStatefulWidget {
  const SaleInvoicesPage({super.key});
  @override
  ConsumerState<SaleInvoicesPage> createState() => _SaleInvoicesPageState();
}

class _SaleInvoicesPageState extends ConsumerState<SaleInvoicesPage> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final listAsync = ref.watch(saleInvoicesProvider(_query));
    final scope = ref.watch(businessLocalLedgerScopeProvider);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          l10n.translate('saleInvoicesTitle'),
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
        actions: [
          if (!BranchScope.readOnly &&
              ref.watch(employeeCanProvider('sales.create')))
            IconButton(
              icon: const Icon(Icons.add, size: 22),
              color: AppColors.primary,
              onPressed: () => context.push(RouteNames.salesAdd),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            SearchBarWidget(
              controller: _searchCtrl,
              hintText: l10n.translate('saleSearchInvoiceHint'),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
            Expanded(
              child: FyonaRefresh(
                color: AppColors.primary,
                onRefresh: () async {
                  ref.invalidate(saleInvoicesProvider);
                },
                child: listAsync.when(
                  loading: () => scope != null
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
                  data: (items) {
                    if (items.isEmpty) {
                      return EmptyStateWidget(
                        title: l10n.translate('saleNoInvoices'),
                      );
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      itemCount: items.length,
                      itemBuilder: (context, i) {
                        final inv = Map<String, dynamic>.from(items[i] as Map);
                        final status = (inv['status'] ?? '').toString();
                        return _InvoiceTile(
                          invoice: inv,
                          status: status,
                          onTap: () => openCommerceRecord(
                            context,
                            RouteNames.invoicesView,
                            '${inv['id']}',
                            kind: 'sale',
                            fromLocal: scope,
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

class _InvoiceTile extends StatelessWidget {
  final Map<String, dynamic> invoice;
  final String status;
  final VoidCallback onTap;
  const _InvoiceTile({
    required this.invoice,
    required this.status,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
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
          title: Text(
            shortDocumentNumber(invoice['invoice_number']),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 14),
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          subtitle: Text(
            '${(invoice['customer_name'] ?? AppLocalizations.of(context).translate('saleCashCustomer')).toString()} • ${parseMoney(invoice['total'])} ${currencySymbol((invoice['currency'] ?? '').toString())}',
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 12),
              color: AppColors.textSecondary,
            ),
          ),
          trailing: StatusBadge(status: status),
          onTap: onTap,
        ),
      ),
    );
  }
}
