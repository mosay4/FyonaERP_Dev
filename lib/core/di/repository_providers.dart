import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers.dart';
import '../network/repositories.dart';

// ─── Repository Providers ───
final authRepositoryProvider = Provider<AuthRepository>((ref) => AuthRepository(ref.watch(apiClientProvider)));
final customersRepositoryProvider = Provider<CustomersRepository>((ref) => CustomersRepository(ref.watch(apiClientProvider)));
final suppliersRepositoryProvider = Provider<SuppliersRepository>((ref) => SuppliersRepository(ref.watch(apiClientProvider)));
final categoriesRepositoryProvider = Provider<CategoriesRepository>((ref) => CategoriesRepository(ref.watch(apiClientProvider)));
final productsRepositoryProvider = Provider<ProductsRepository>((ref) => ProductsRepository(ref.watch(apiClientProvider)));
final inventoryRepositoryProvider = Provider<InventoryRepository>((ref) => InventoryRepository(ref.watch(apiClientProvider)));
final invoicesRepositoryProvider = Provider<InvoicesRepository>((ref) => InvoicesRepository(ref.watch(apiClientProvider)));
final salesRepositoryProvider = Provider<SalesRepository>((ref) => SalesRepository(ref.watch(apiClientProvider)));
final purchasesRepositoryProvider = Provider<PurchasesRepository>((ref) => PurchasesRepository(ref.watch(apiClientProvider)));
final accountingRepositoryProvider = Provider<AccountingRepository>((ref) => AccountingRepository(ref.watch(apiClientProvider)));
final hrRepositoryProvider = Provider<HRRepository>((ref) => HRRepository(ref.watch(apiClientProvider)));
final reportsRepositoryProvider = Provider<ReportsRepository>((ref) => ReportsRepository(ref.watch(apiClientProvider)));
final aiRepositoryProvider = Provider<AIRepository>((ref) => AIRepository(ref.watch(apiClientProvider)));
final syncRepositoryProvider = Provider<SyncRepository>((ref) => SyncRepository(ref.watch(apiClientProvider)));
