import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/route_names.dart';
import '../../data/local_directory/directory_pilot.dart';
import '../../data/local_directory/directory_scope.dart';

const commerceDocumentRoutes = <String, String>{
  RouteNames.salesView: RouteNames.invoices,
  RouteNames.purchasesView: RouteNames.invoices,
  RouteNames.invoicesView: RouteNames.invoices,
  RouteNames.returnsView: RouteNames.returns,
  RouteNames.returnsAdd: RouteNames.returns,
  RouteNames.inventoryProduct: RouteNames.inventory,
  RouteNames.inventoryProductEdit: RouteNames.inventory,
  RouteNames.inventoryProductMovements: RouteNames.inventory,
  RouteNames.inventoryCategoryDetail: RouteNames.inventoryCategories,
  RouteNames.businessTransactionDetails: RouteNames.businessTransactions,
};

/// Local ids live only in a scoped in-memory target, never in a legacy URL.
final class LocalCommerceTarget {
  const LocalCommerceTarget(this.scope, this.path, this.id, {this.kind});
  final DirectoryAccess scope;
  final String path;
  final String id;
  final String? kind;

  bool allows(DirectoryAccess? current, String requestedPath) =>
      path == requestedPath &&
      commerceDocumentRoutes.containsKey(path) &&
      isDirectoryId(id) &&
      scope.financialCutover &&
      current?.financialCutover == true &&
      sameDirectoryScope(scope, current);
}

Future<T?> openCommerceRecord<T>(
  BuildContext context,
  String path,
  String id, {
  String? kind,
  bool replace = false,
  DirectoryAccess? fromLocal,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final scope = container.read(businessLocalLedgerScopeProvider);
  if (fromLocal != null && !sameDirectoryScope(fromLocal, scope)) return null;
  final extra = scope == null
      ? null
      : LocalCommerceTarget(scope, path, id, kind: kind);
  final location = extra == null
      ? Uri(
          path: path,
          queryParameters: {
            path == RouteNames.returnsAdd ? 'invoice' : 'id': id,
            if (kind != null)
              (switch (path) {
                RouteNames.invoicesView => 'type',
                RouteNames.businessTransactionDetails => 'source',
                _ => 'kind',
              }): kind,
          },
        ).toString()
      : path;
  if (replace) {
    context.pushReplacement(location, extra: extra);
    return null;
  }
  return context.push<T>(location, extra: extra);
}
