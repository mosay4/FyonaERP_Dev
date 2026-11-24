import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/dio_provider.dart';
import '../../../core_business/data/local_commerce/all_branches_commerce.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../data/invoices_api.dart';

final invoicesApiProvider = Provider<InvoicesApi>((ref) {
  // «جميع الفروع»: every branch's invoices, read-only.
  final all = ref.watch(allBranchesCommerceProvider);
  if (all != null) return AllBranchesInvoicesApi(all);
  return localCommerceApi<InvoicesApi>(
    InvoicesApi.new, LocalInvoicesApi.new, ref.watch(apiClientProvider),
    ref.watch(localCommerceBridgeProvider),
  );
});
