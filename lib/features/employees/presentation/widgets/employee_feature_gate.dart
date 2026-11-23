import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core_business/data/local_directory/directory_party.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';
import '../../data/employee_permissions.dart';
import '../providers/employee_providers.dart';
import '../providers/employee_device_finance_provider.dart';

/// Denied route bodies are never mounted: no stale finance fetches or controls.
class EmployeeFeatureGate extends ConsumerWidget {
  const EmployeeFeatureGate({
    super.key,
    required this.route,
    required this.child,
  });
  final String route;
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = GoRouterState.of(context);
    final uri = state.uri;
    final extra = state.extra;
    final commerce = extra is LocalCommerceTarget ? extra : null;
    final returnKind = commerce?.kind ?? uri.queryParameters['kind'];
    final key = route == '/invoices/view'
        ? ((extra is DirectoryDebtInvoiceReference
                ? extra.party.kind == DirectoryPartyKind.supplier
                : (commerce?.kind ?? uri.queryParameters['type']) == 'purchase')
              ? 'purchases.view'
              : 'sales.view')
        : route == '/inventory/product/edit'
        ? ((commerce?.id ?? uri.queryParameters['id'])?.isNotEmpty == true
              ? 'inventory.edit'
              : 'inventory.add')
        : employeeRoutePermission(route);
    final ownFinance = (route == '/employees/salary' || route == '/employees/debts') &&
        uri.queryParameters['ro'] == '1' &&
        ref.watch(employeeDeviceSelectionProvider)?.employee == uri.queryParameters['id'] &&
        uri.queryParameters['id'] != null;
    var permitted = ownFinance || key == null || ref.watch(employeeCanProvider(key));
    if (route.startsWith('/returns/') && returnKind != null) {
      permitted &= ref.watch(
        employeeCanProvider(
          returnKind == 'purchase_return'
              ? 'purchases.returns'
              : 'sales.returns',
        ),
      );
    }
    if (route == '/business/income-expense') {
      permitted &=
          ref.watch(employeeCanProvider('income')) ||
          ref.watch(employeeCanProvider('expenses'));
    }
    if (route.startsWith('/reconciliation/bank'))
      permitted &= ref.watch(employeeCanProvider('banks.balances'));
    if (route.startsWith('/reconciliation/inventory'))
      permitted &= ref.watch(employeeCanProvider('inventory.count'));
    if (route == '/reports/view')
      permitted &= ref.watch(
        employeeReportCanProvider(uri.queryParameters['kind'] ?? 'overview'),
      );
    if (permitted) return child;
    return const Center(child: Icon(Icons.lock_outline_rounded));
  }
}
