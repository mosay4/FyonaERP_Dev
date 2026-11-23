import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/dio_provider.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../data/invoices_api.dart';

final invoicesApiProvider = Provider<InvoicesApi>(
  (ref) => localCommerceApi<InvoicesApi>(
    InvoicesApi.new, LocalInvoicesApi.new, ref.watch(apiClientProvider),
    ref.watch(localCommerceBridgeProvider),
  ),
);
