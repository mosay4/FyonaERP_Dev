import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/dio_provider.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../../core_business/presentation/providers/business_ledger_session.dart';
import '../../../sales/presentation/providers/sale_providers.dart' show businessPaymentRows;
import '../../data/returns_api.dart';

import '../../../branches/data/branch_epoch.dart';

final returnsApiProvider = Provider<ReturnsApi>(
  (ref) => localCommerceApi<ReturnsApi>(
    ReturnsApi.new,
    LocalReturnsApi.new,
    ref.watch(apiClientProvider),
    ref.watch(localCommerceBridgeProvider),
  ),
);

/// Previous returns list, filtered by kind ('all' | 'sale_return' |
/// 'purchase_return'). Not auto-disposed so a return created on another page
/// is visible immediately after `ref.invalidate`.
final returnsListProvider = FutureProvider.family<List<dynamic>, String>((
  ref,
  kind,
) async {
  final api = ref.watch(returnsApiProvider);
  return api.list(kind: kind == 'all' ? null : kind);
});

/// Bank/cash accounts shaped for the shared account+currency picker.
final returnAccountsProvider = FutureProvider<List<Map<String, String>>>((
  ref,
) async {
  ref.watch(branchEpochProvider);
  final api = ref.watch(returnsApiProvider);
  if (api is LocalReturnsApi) ref.watch(businessBankRevisionProvider);
  return businessPaymentRows(await api.bankAccounts());
});
