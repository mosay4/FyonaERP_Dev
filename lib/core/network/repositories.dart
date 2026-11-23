
import 'package:dio/dio.dart';

import 'api_client.dart';
import 'api_response.dart';
import 'api_endpoints.dart';
import 'error_handler.dart';

/// Base repository: provides get/post/put/delete calling the existing ApiClient.
class BaseRepository {
  final ApiClient _client;

  BaseRepository(this._client);

  Future<ApiResponse<dynamic>> get(String path, {Map<String, dynamic>? params}) async {
    try { final r = await _client.get(path, queryParameters: params); return ApiResponse.fromJson(r.data); }
    on DioException catch (e) { throw handleDioException(e); }
  }

  Future<ApiResponse<dynamic>> post(String path, {dynamic data}) async {
    try { final r = await _client.post(path, data: data); return ApiResponse.fromJson(r.data); }
    on DioException catch (e) { throw handleDioException(e); }
  }

  Future<ApiResponse<dynamic>> put(String path, {dynamic data}) async {
    try { final r = await _client.put(path, data: data); return ApiResponse.fromJson(r.data); }
    on DioException catch (e) { throw handleDioException(e); }
  }

  Future<ApiResponse<dynamic>> delete(String path) async {
    try { final r = await _client.delete(path); return ApiResponse.fromJson(r.data); }
    on DioException catch (e) { throw handleDioException(e); }
  }

  Map<String, dynamic> paginate(int page, int perPage, {String? search, String? status, String? type}) {
    final m = <String, dynamic>{'page': page, 'per_page': perPage};
    if (search != null) m['search'] = search;
    if (status != null) m['status'] = status;
    if (type != null) m['type'] = type;
    return m;
  }

}

// ─── Auth ───
class AuthRepository extends BaseRepository {
  AuthRepository(super.client);
  Future<ApiResponse<dynamic>> refreshToken(Map<String, dynamic> d) => post(ApiEndpoints.refresh, data: d);
  Future<ApiResponse<dynamic>> logout(Map<String, dynamic> d) => post(ApiEndpoints.logout, data: d);
  Future<ApiResponse<dynamic>> getMe() => get(ApiEndpoints.me);
  Future<ApiResponse<dynamic>> updateProfile(Map<String, dynamic> d) => put(ApiEndpoints.me, data: d);
}

// ─── Customers ───
class CustomersRepository extends BaseRepository {
  CustomersRepository(super.client);

  Future<ApiResponse<dynamic>> list({int page = 1, int perPage = 20, String? search}) => get(ApiEndpoints.customers, params: paginate(page, perPage, search: search));

  Future<ApiResponse<dynamic>> getById(String id) => get(ApiEndpoints.customer(id));

  Future<ApiResponse<dynamic>> create(Map<String, dynamic> d) => post(ApiEndpoints.customers, data: d);

  Future<ApiResponse<dynamic>> updateById(String id, Map<String, dynamic> d) => put(ApiEndpoints.customer(id), data: d);

  Future<ApiResponse<dynamic>> deleteById(String id) => delete(ApiEndpoints.customer(id));
}

// ─── Suppliers ───
class SuppliersRepository extends BaseRepository {
  SuppliersRepository(super.client);

  Future<ApiResponse<dynamic>> list({int page = 1, int perPage = 20, String? search}) => get(ApiEndpoints.suppliers, params: paginate(page, perPage, search: search));

  Future<ApiResponse<dynamic>> getById(String id) => get(ApiEndpoints.supplier(id));

  Future<ApiResponse<dynamic>> create(Map<String, dynamic> d) => post(ApiEndpoints.suppliers, data: d);

  Future<ApiResponse<dynamic>> updateById(String id, Map<String, dynamic> d) => put(ApiEndpoints.supplier(id), data: d);

  Future<ApiResponse<dynamic>> deleteById(String id) => delete(ApiEndpoints.supplier(id));
}

// ─── Categories ───
class CategoriesRepository extends BaseRepository {
  CategoriesRepository(super.client);
  Future<ApiResponse<dynamic>> list({bool onlyActive = false}) => get(ApiEndpoints.categories, params: {'only_active': onlyActive});
  Future<ApiResponse<dynamic>> getById(String id) => get(ApiEndpoints.category(id));
  Future<ApiResponse<dynamic>> create(Map<String, dynamic> d) => post(ApiEndpoints.categories, data: d);
  Future<ApiResponse<dynamic>> updateById(String id, Map<String, dynamic> d) => put(ApiEndpoints.category(id), data: d);
}

// ─── Products ───
class ProductsRepository extends BaseRepository {
  ProductsRepository(super.client);

  Future<ApiResponse<dynamic>> list({int page = 1, int perPage = 20, String? search, String? categoryId}) => get(ApiEndpoints.products, params: paginate(page, perPage, search: search)..putIfAbsent('category_id', () => categoryId));

  Future<ApiResponse<dynamic>> getById(String id) => get(ApiEndpoints.product(id));

  Future<ApiResponse<dynamic>> create(Map<String, dynamic> d) => post(ApiEndpoints.products, data: d);

  Future<ApiResponse<dynamic>> updateById(String id, Map<String, dynamic> d) => put(ApiEndpoints.product(id), data: d);

  Future<ApiResponse<dynamic>> deleteById(String id) => delete(ApiEndpoints.product(id));
}

// ─── Inventory ───
class InventoryRepository extends BaseRepository {
  InventoryRepository(super.client);
  Future<ApiResponse<dynamic>> listMovements({int page = 1, int perPage = 20, String? productId, String? type}) => get(ApiEndpoints.inventoryMovements, params: paginate(page, perPage, type: type)..putIfAbsent('product_id', () => productId));
  Future<ApiResponse<dynamic>> getProductMovements(String productId, {int limit = 50}) => get(ApiEndpoints.inventoryMovementsProduct(productId), params: {'limit': limit});
  Future<ApiResponse<dynamic>> createMovement(Map<String, dynamic> d) => post(ApiEndpoints.inventoryMovements, data: d);
}

// ─── Invoices ───
class InvoicesRepository extends BaseRepository {
  InvoicesRepository(super.client);

  Future<ApiResponse<dynamic>> list({int page = 1, int perPage = 20, String? search, String? status, String? type}) => get(ApiEndpoints.invoices, params: paginate(page, perPage, search: search, status: status, type: type));

  Future<ApiResponse<dynamic>> getById(String id) => get(ApiEndpoints.invoice(id));

  Future<ApiResponse<dynamic>> create(Map<String, dynamic> d) => post(ApiEndpoints.invoices, data: d);

  Future<ApiResponse<dynamic>> updateById(String id, Map<String, dynamic> d) => put(ApiEndpoints.invoice(id), data: d);

  Future<ApiResponse<dynamic>> deleteById(String id) => delete(ApiEndpoints.invoice(id));

  Future<ApiResponse<dynamic>> changeStatus(String id, String action) => post(ApiEndpoints.invoiceStatus(id), data: {'action': action});

  Future<ApiResponse<dynamic>> addPayment(String id, Map<String, dynamic> d) => post(ApiEndpoints.invoicePayments(id), data: d);
}

// ─── Sales ───
class SalesRepository extends BaseRepository {
  SalesRepository(super.client);

  Future<ApiResponse<dynamic>> listOrders({int page = 1, int perPage = 20, String? search, String? status}) => get(ApiEndpoints.salesOrders, params: paginate(page, perPage, search: search, status: status));

  Future<ApiResponse<dynamic>> getOrderById(String id) => get(ApiEndpoints.salesOrder(id));

  Future<ApiResponse<dynamic>> createOrder(Map<String, dynamic> d) => post(ApiEndpoints.salesOrders, data: d);

  Future<ApiResponse<dynamic>> updateOrderById(String id, Map<String, dynamic> d) => put(ApiEndpoints.salesOrder(id), data: d);

  Future<ApiResponse<dynamic>> deleteOrderById(String id) => delete(ApiEndpoints.salesOrder(id));

  Future<ApiResponse<dynamic>> changeOrderStatus(String id, String action) => post(ApiEndpoints.salesOrderStatus(id), data: {'action': action});

  Future<ApiResponse<dynamic>> createReturn(Map<String, dynamic> d) => post(ApiEndpoints.salesReturns, data: d);
  Future<ApiResponse<dynamic>> listQuotes({int page = 1, int perPage = 20}) => get(ApiEndpoints.salesQuotes, params: paginate(page, perPage));
  Future<ApiResponse<dynamic>> listDeliveries({int page = 1, int perPage = 20}) => get(ApiEndpoints.salesDeliveries, params: paginate(page, perPage));
}

// ─── Purchases ───
class PurchasesRepository extends BaseRepository {
  PurchasesRepository(super.client);

  Future<ApiResponse<dynamic>> listOrders({int page = 1, int perPage = 20, String? search, String? status}) => get(ApiEndpoints.purchaseOrders, params: paginate(page, perPage, search: search, status: status));

  Future<ApiResponse<dynamic>> getOrderById(String id) => get(ApiEndpoints.purchaseOrder(id));

  Future<ApiResponse<dynamic>> createOrder(Map<String, dynamic> d) => post(ApiEndpoints.purchaseOrders, data: d);

  Future<ApiResponse<dynamic>> updateOrderById(String id, Map<String, dynamic> d) => put(ApiEndpoints.purchaseOrder(id), data: d);

  Future<ApiResponse<dynamic>> deleteOrderById(String id) => delete(ApiEndpoints.purchaseOrder(id));

  Future<ApiResponse<dynamic>> changeOrderStatus(String id, String action) => post(ApiEndpoints.purchaseOrderStatus(id), data: {'action': action});

  Future<ApiResponse<dynamic>> createReceipt(Map<String, dynamic> d) => post(ApiEndpoints.purchaseReceipts, data: d);
  Future<ApiResponse<dynamic>> createBill(Map<String, dynamic> d) => post(ApiEndpoints.purchaseBills, data: d);
  Future<ApiResponse<dynamic>> payBillById(String id, double amount) => post(ApiEndpoints.purchaseBillPay(id), data: {'amount': amount});
}

// ─── Accounting ───
class AccountingRepository extends BaseRepository {
  AccountingRepository(super.client);
  Future<ApiResponse<dynamic>> initChart() => post(ApiEndpoints.accountingInit);
  Future<ApiResponse<dynamic>> listAccounts({String? typeFilter}) => get(ApiEndpoints.accounts, params: typeFilter != null ? {'type_filter': typeFilter} : null);
  Future<ApiResponse<dynamic>> createAccount(Map<String, dynamic> d) => post(ApiEndpoints.accounts, data: d);
  Future<ApiResponse<dynamic>> listJournal({int page = 1, int perPage = 20}) => get(ApiEndpoints.journal, params: paginate(page, perPage));
  Future<ApiResponse<dynamic>> createJournalEntry(Map<String, dynamic> d) => post(ApiEndpoints.journal, data: d);
  Future<ApiResponse<dynamic>> postJournalEntry(String id) => post(ApiEndpoints.journalPost(id));
  Future<ApiResponse<dynamic>> trialBalance({String? entryDate}) => get(ApiEndpoints.trialBalance, params: entryDate != null ? {'entry_date': entryDate} : null);
  Future<ApiResponse<dynamic>> profitLoss(String from, String to) => get(ApiEndpoints.profitLoss, params: {'from_date': from, 'to_date': to});
  Future<ApiResponse<dynamic>> balanceSheet(String asOf) => get(ApiEndpoints.balanceSheet, params: {'as_of': asOf});
}

// ─── HR ───
class HRRepository extends BaseRepository {
  HRRepository(super.client);
  Future<ApiResponse<dynamic>> listDepartments() => get(ApiEndpoints.departments);
  Future<ApiResponse<dynamic>> createDepartment(Map<String, dynamic> d) => post(ApiEndpoints.departments, data: d);
  Future<ApiResponse<dynamic>> listPositions({String? deptId}) => get(ApiEndpoints.positions, params: deptId != null ? {'dept_id': deptId} : null);
  Future<ApiResponse<dynamic>> createPosition(Map<String, dynamic> d) => post(ApiEndpoints.positions, data: d);
  Future<ApiResponse<dynamic>> listEmployees({int page = 1, int perPage = 20, String? search, String? deptId, String? status}) =>
      get(ApiEndpoints.employees, params: paginate(page, perPage, search: search, status: status)..putIfAbsent('dept_id', () => deptId));
  Future<ApiResponse<dynamic>> getEmployeeById(String id) => get(ApiEndpoints.employee(id));
  Future<ApiResponse<dynamic>> createEmployee(Map<String, dynamic> d) => post(ApiEndpoints.employees, data: d);
  Future<ApiResponse<dynamic>> updateEmployeeById(String id, Map<String, dynamic> d) => put(ApiEndpoints.employee(id), data: d);
  Future<ApiResponse<dynamic>> deleteEmployeeById(String id) => delete(ApiEndpoints.employee(id));
  Future<ApiResponse<dynamic>> listAttendance({int page = 1, int perPage = 20, String? empId, String? from, String? to}) =>
      get(ApiEndpoints.attendance, params: paginate(page, perPage)..putIfAbsent('emp_id', () => empId)..putIfAbsent('from_date', () => from)..putIfAbsent('to_date', () => to));
  Future<ApiResponse<dynamic>> recordAttendance(Map<String, dynamic> d) => post(ApiEndpoints.attendance, data: d);
  Future<ApiResponse<dynamic>> listLeaves({int page = 1, int perPage = 20, String? empId, String? status}) =>
      get(ApiEndpoints.leaves, params: paginate(page, perPage, status: status)..putIfAbsent('emp_id', () => empId));
  Future<ApiResponse<dynamic>> requestLeave(Map<String, dynamic> d) => post(ApiEndpoints.leaves, data: d);
  Future<ApiResponse<dynamic>> approveLeave(String id) => post(ApiEndpoints.leaveAction(id), data: {'action': 'approve'});
  Future<ApiResponse<dynamic>> rejectLeave(String id) => post(ApiEndpoints.leaveAction(id), data: {'action': 'reject'});
  Future<ApiResponse<dynamic>> listPayroll({int page = 1, int perPage = 20}) => get(ApiEndpoints.payroll, params: paginate(page, perPage));
  Future<ApiResponse<dynamic>> createPayroll(Map<String, dynamic> d) => post(ApiEndpoints.payroll, data: d);
  Future<ApiResponse<dynamic>> processPayroll(String id) => post(ApiEndpoints.payrollProcess(id));
}

// ─── Reports ───
class ReportsRepository extends BaseRepository {
  ReportsRepository(super.client);
  Future<ApiResponse<dynamic>> kpi() => get(ApiEndpoints.kpi);
  Future<ApiResponse<dynamic>> salesReport(String from, String to) => get(ApiEndpoints.reportsSales, params: {'from_date': from, 'to_date': to});
  Future<ApiResponse<dynamic>> inventoryReport() => get(ApiEndpoints.reportsInventory);
}

// ─── AI ───
class AIRepository extends BaseRepository {
  AIRepository(super.client);
  Future<ApiResponse<dynamic>> insights() => get(ApiEndpoints.aiInsights);
  Future<ApiResponse<dynamic>> forecast(String metric, {int periods = 3}) => get(ApiEndpoints.aiForecast(metric), params: {'periods': periods});
  Future<ApiResponse<dynamic>> query(Map<String, dynamic> d) => post(ApiEndpoints.aiQuery, data: d);
}

// ─── Sync ───
class SyncRepository extends BaseRepository {
  SyncRepository(super.client);
  Future<ApiResponse<dynamic>> push(Map<String, dynamic> d) => post(ApiEndpoints.syncPush, data: d);
  Future<ApiResponse<dynamic>> pull(Map<String, dynamic> d) => post(ApiEndpoints.syncPull, data: d);
  Future<ApiResponse<dynamic>> status() => get(ApiEndpoints.syncStatus);
  Future<ApiResponse<dynamic>> health() => get(ApiEndpoints.syncHealth);
  Future<ApiResponse<dynamic>> conflicts({bool unresolvedOnly = false, int page = 1, int perPage = 20}) =>
      get(ApiEndpoints.syncConflicts, params: {'unresolved_only': unresolvedOnly, 'page': page, 'per_page': perPage});
  Future<ApiResponse<dynamic>> logs({int page = 1, int perPage = 50}) =>
      get(ApiEndpoints.syncLogs, params: {'page': page, 'per_page': perPage});
}
