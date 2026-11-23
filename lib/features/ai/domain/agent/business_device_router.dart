import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/currency/currency_engine.dart';
import '../../../business_banks/presentation/providers/business_banks_providers.dart';
import '../../../core_business/data/project_settings_api.dart';
import '../../../dashboard/presentation/providers/business_dashboard_providers.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../inventory/presentation/providers/inventory_providers.dart';
import '../../../invoices/presentation/providers/invoices_providers.dart';
import '../../../purchases/presentation/providers/purchase_providers.dart';
import '../../../reconciliation/data/reconciliation_api.dart';
import '../../../reports/data/reports_api.dart';
import '../../../returns/presentation/providers/returns_providers.dart';
import '../../../sales/presentation/providers/sale_providers.dart';

/// Reads a provider (WidgetRef.read / Ref.read / ProviderContainer.read).
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

typedef _Handler =
    Future<Object?> Function(
      ProviderReader read,
      Map<String, String> path,
      Map<String, dynamic> query,
      Map<String, dynamic> body,
    );

/// Sara's hands on this phone. The model speaks the app's API language
/// ("GET /customers", "POST /invoices/issue-sale"); every request is answered
/// here by the SAME device APIs the buttons use, so Sara reads this branch's
/// own ledger and can do exactly what the user can — no more: the same
/// validations, stock/balance floors and employee permissions apply.
abstract final class BusinessDeviceRouter {
  static final List<(String, String, _Handler)> _routes = [
    // ── customers / suppliers ────────────────────────────────────────────
    ('GET', '/customers', (r, p, q, b) => r(purchaseApiProvider).searchCustomers(_s(q, 'search'))),
    ('GET', '/customers/{id}', (r, p, q, b) => _find(r(purchaseApiProvider).searchCustomers(''), p['id']!)),
    ('POST', '/customers', (r, p, q, b) => r(purchaseApiProvider).createCustomer(name: _req(b, 'name'), phone: b['phone']?.toString())),
    ('PUT', '/customers/{id}', (r, p, q, b) => r(purchaseApiProvider).updateCustomer(p['id']!, name: b['name']?.toString(), phone: b['phone']?.toString())),
    ('GET', '/customers/{id}/balance', (r, p, q, b) => r(purchaseApiProvider).customerBalance(p['id']!)),
    ('GET', '/customers/{id}/operations', (r, p, q, b) => r(purchaseApiProvider).customerOperations(p['id']!)),
    ('POST', '/customers/{id}/payments', (r, p, q, b) => r(purchaseApiProvider).collectCustomer(p['id']!, b)),
    ('GET', '/suppliers', (r, p, q, b) => r(purchaseApiProvider).searchSuppliers(_s(q, 'search'))),
    ('GET', '/suppliers/{id}', (r, p, q, b) => _find(r(purchaseApiProvider).searchSuppliers(''), p['id']!)),
    ('POST', '/suppliers', (r, p, q, b) => r(purchaseApiProvider).createSupplier(name: _req(b, 'name'), phone: b['phone']?.toString())),
    ('PUT', '/suppliers/{id}', (r, p, q, b) => r(purchaseApiProvider).updateSupplier(p['id']!, name: b['name']?.toString(), phone: b['phone']?.toString())),
    ('GET', '/suppliers/{id}/balance', (r, p, q, b) => r(purchaseApiProvider).supplierBalance(p['id']!)),
    ('GET', '/suppliers/{id}/operations', (r, p, q, b) => r(purchaseApiProvider).supplierOperations(p['id']!)),
    ('POST', '/suppliers/{id}/payments', (r, p, q, b) => r(purchaseApiProvider).paySupplier(p['id']!, b)),

    // ── invoices ─────────────────────────────────────────────────────────
    ('GET', '/invoices', (r, p, q, b) => r(invoicesApiProvider).list(type: _o(q, 'invoice_type'), search: _o(q, 'search'), perPage: _i(q, 'per_page', 100))),
    ('GET', '/invoices/{id}', (r, p, q, b) => r(invoicesApiProvider).getInvoice(p['id']!)),
    ('POST', '/invoices/issue-sale', (r, p, q, b) => r(salesApiProvider).issueSale(b)),
    ('POST', '/invoices/issue-purchase', (r, p, q, b) => r(purchaseApiProvider).issuePurchase(b)),
    ('POST', '/invoices/{id}/returns', (r, p, q, b) => r(returnsApiProvider).create(p['id']!, b)),
    ('GET', '/returns', (r, p, q, b) => r(returnsApiProvider).list(kind: _o(q, 'kind'), search: _o(q, 'search'), invoiceId: _o(q, 'invoice_id'), page: _i(q, 'page', 1))),
    ('GET', '/returns/{kind}/{id}', (r, p, q, b) => r(returnsApiProvider).detail(p['kind']!, p['id']!)),
    ('GET', '/business/payment-options', (r, p, q, b) => r(salesApiProvider).bankAccounts()),

    // ── products / stock ─────────────────────────────────────────────────
    ('GET', '/products', (r, p, q, b) => r(inventoryApiProvider).listProducts(search: _s(q, 'search'), stockStatus: _o(q, 'stock_status'), categoryId: _o(q, 'category_id'), page: _i(q, 'page', 1), perPage: _i(q, 'per_page', 50))),
    ('GET', '/products/resolve-barcode', (r, p, q, b) => r(inventoryApiProvider).resolveBarcode(_req(q, 'code'))),
    ('GET', '/products/{id}', (r, p, q, b) => r(inventoryApiProvider).getProduct(p['id']!)),
    ('POST', '/products', (r, p, q, b) => r(inventoryApiProvider).createProduct(b)),
    ('PUT', '/products/{id}', (r, p, q, b) => r(inventoryApiProvider).updateProduct(p['id']!, b)),
    ('DELETE', '/products/{id}', (r, p, q, b) => _done(r(inventoryApiProvider).deleteProduct(p['id']!))),
    ('GET', '/products/{id}/units', (r, p, q, b) => r(inventoryApiProvider).productUnits(p['id']!)),
    ('POST', '/products/{id}/units', (r, p, q, b) => r(inventoryApiProvider).createUnit(p['id']!, b)),
    ('DELETE', '/products/units/{id}', (r, p, q, b) => _done(r(inventoryApiProvider).deleteUnit(p['id']!))),
    ('POST', '/products/{id}/barcodes', (r, p, q, b) => r(inventoryApiProvider).addBarcode(p['id']!, b)),
    ('DELETE', '/products/barcodes/{id}', (r, p, q, b) => _done(r(inventoryApiProvider).deleteBarcode(p['id']!))),
    ('GET', '/products/{id}/prices', (r, p, q, b) => r(inventoryApiProvider).productPrices(p['id']!)),
    ('PUT', '/products/{id}/prices', (r, p, q, b) => _done(r(inventoryApiProvider).setProductPrices(p['id']!, _maps(b['prices'])))),
    ('GET', '/products/{id}/lots', (r, p, q, b) => r(inventoryApiProvider).productLots(p['id']!)),
    ('GET', '/products/{id}/stats', (r, p, q, b) => r(inventoryApiProvider).productStats(p['id']!, from: _o(q, 'from'), to: _o(q, 'to'), displayCurrency: _o(q, 'display_currency'))),
    ('GET', '/inventory/movements/product/{id}', (r, p, q, b) => r(inventoryApiProvider).productMovements(p['id']!, limit: _i(q, 'limit', 60))),
    ('POST', '/inventory/adjust', (r, p, q, b) => r(inventoryApiProvider).adjustStock(b)),
    ('POST', '/inventory/transfer', (r, p, q, b) => r(inventoryApiProvider).transferStock(b)),
    ('PUT', '/inventory/warehouse-settings', (r, p, q, b) => _done(r(inventoryApiProvider).setWarehouseSettings(expiryEnabled: b['expiry_enabled'] == true, warnDays: _i(b, 'warn_days', 30)))),
    ('GET', '/categories', (r, p, q, b) => r(inventoryApiProvider).categories()),
    ('POST', '/categories', (r, p, q, b) => r(inventoryApiProvider).createCategory(_req(b, 'name'))),
    ('PUT', '/categories/{id}', (r, p, q, b) => r(inventoryApiProvider).updateCategory(p['id']!, _req(b, 'name'))),
    ('DELETE', '/categories/{id}', (r, p, q, b) => _done(r(inventoryApiProvider).deleteCategory(p['id']!))),
    ('DELETE', '/categories/{id}/image', (r, p, q, b) => _done(r(inventoryApiProvider).deleteCategoryImage(p['id']!))),

    // ── money: banks, cash, expenses, timeline ───────────────────────────
    ('GET', '/banking/accounts', (r, p, q, b) => r(businessBanksApiProvider).listAccounts()),
    ('GET', '/banking/accounts/{id}', (r, p, q, b) => _find(r(businessBanksApiProvider).listAccounts(), p['id']!)),
    ('GET', '/banking/accounts/{id}/transactions', (r, p, q, b) => r(businessBanksApiProvider).transactions(p['id']!)),
    ('GET', '/banking/accounts/{id}/statement', (r, p, q, b) => r(businessBanksApiProvider).transactions(p['id']!)),
    ('POST', '/banking/accounts', (r, p, q, b) => r(businessBanksApiProvider).createAccount(bankName: _req(b, 'bank_name'), accountName: _s(b, 'account_name').isEmpty ? _req(b, 'bank_name') : _s(b, 'account_name'), accountNumber: _s(b, 'account_number'), iban: _o(b, 'iban'), currency: _req(b, 'currency'), accountType: _o(b, 'account_type') ?? 'checking', balance: _d(b, 'balance') ?? 0)),
    ('PUT', '/banking/accounts/{id}', (r, p, q, b) => r(businessBanksApiProvider).updateAccount(p['id']!, bankName: _o(b, 'bank_name'), accountName: _o(b, 'account_name'), accountNumber: _o(b, 'account_number'), iban: _o(b, 'iban'), currency: _o(b, 'currency'), accountType: _o(b, 'account_type'), isActive: b['is_active'] is bool ? b['is_active'] as bool : null)),
    ('DELETE', '/banking/accounts/{id}', (r, p, q, b) => r(businessBanksApiProvider).deleteAccount(p['id']!)),
    ('POST', '/banking/accounts/{id}/deposit', (r, p, q, b) => r(businessBanksApiProvider).deposit(p['id']!, _amount(b), description: _o(b, 'description'))),
    ('POST', '/banking/accounts/{id}/withdraw', (r, p, q, b) => r(businessBanksApiProvider).withdraw(p['id']!, _amount(b), description: _o(b, 'description'))),
    ('POST', '/banking/transfer', (r, p, q, b) => r(businessBanksApiProvider).transfer(fromId: _req(b, 'from_account_id'), toId: _req(b, 'to_account_id'), amount: _amount(b), toAmount: _d(b, 'to_amount'), rate: _d(b, 'exchange_rate') ?? _d(b, 'rate'), description: _o(b, 'description'))),
    ('POST', '/banking/banks/link', (r, p, q, b) => _done(r(businessBanksApiProvider).linkAccounts(_strings(b['account_ids'])))),
    ('POST', '/banking/banks/unlink', (r, p, q, b) => _done(r(businessBanksApiProvider).unlinkAccounts(_strings(b['account_ids'])))),
    ('GET', '/expenses', (r, p, q, b) => r(businessFinanceApiProvider).listExpenses()),
    ('POST', '/expenses', (r, p, q, b) => r(businessFinanceApiProvider).withdraw(_req(b, 'bank_account_id'), _amount(b), description: _o(b, 'description'), isExpense: true, category: _o(b, 'category'))),
    ('GET', '/business/transactions', (r, p, q, b) => r(businessFinanceApiProvider).listTransactions(kind: _o(q, 'kind'), period: _o(q, 'period'), search: _o(q, 'search'), dateFrom: _o(q, 'date_from'), dateTo: _o(q, 'date_to'))),
    ('GET', '/business/transactions/{type}/{id}', (r, p, q, b) => r(businessFinanceApiProvider).getTransaction(p['type']!, p['id']!)),

    // ── reconciliation ───────────────────────────────────────────────────
    ('GET', '/reconciliation/accounts', (r, p, q, b) => r(reconciliationApiProvider).accounts()),
    ('GET', '/reconciliation', (r, p, q, b) => r(reconciliationApiProvider).archive(rtype: _o(q, 'rtype'), status: _o(q, 'status'), dateFrom: _o(q, 'date_from'), dateTo: _o(q, 'date_to'), search: _o(q, 'search'), page: _i(q, 'page', 1))),
    ('GET', '/reconciliation/{id}', (r, p, q, b) => r(reconciliationApiProvider).detail(p['id']!)),
    ('POST', '/reconciliation/bank/check', (r, p, q, b) => _bankCheck(r, b)),
    ('POST', '/reconciliation/bank/{id}/approve', (r, p, q, b) => r(reconciliationApiProvider).bankApprove(reconId: p['id']!, entries: _maps(b['entries']), notes: _o(b, 'notes'))),
    ('POST', '/reconciliation/inventory/start', (r, p, q, b) => r(reconciliationApiProvider).inventoryStart(scope: _o(b, 'scope') ?? 'all', productId: _o(b, 'product_id'), categoryId: _o(b, 'category_id'), notes: _o(b, 'notes'), idempotencyKey: ReconciliationApi.newOperationId())),
    ('POST', '/reconciliation/inventory/{id}/save', (r, p, q, b) => r(reconciliationApiProvider).inventorySave(reconId: p['id']!, counts: _maps(b['counts']))),
    ('POST', '/reconciliation/inventory/{id}/check', (r, p, q, b) => r(reconciliationApiProvider).inventoryCheck(reconId: p['id']!)),
    ('POST', '/reconciliation/inventory/{id}/approve', (r, p, q, b) => r(reconciliationApiProvider).inventoryApprove(reconId: p['id']!, settlements: _maps(b['settlements']), notes: _o(b, 'notes'))),

    // ── reports ──────────────────────────────────────────────────────────
    ('GET', '/business-reports/home', (r, p, q, b) => r(businessReportsApiProvider).home(_o(q, 'from'), _o(q, 'to'), _o(q, 'currency') ?? 'SAR')),
    ('GET', '/business-reports/sales-purchases', (r, p, q, b) => r(businessReportsApiProvider).salesPurchases(_o(q, 'from'), _o(q, 'to'), _o(q, 'currency') ?? 'SAR')),
    ('GET', '/business-reports/money', (r, p, q, b) => r(businessReportsApiProvider).money(_o(q, 'from'), _o(q, 'to'), _o(q, 'currency') ?? 'SAR', _o(q, 'account_id'))),
    ('GET', '/business-reports/inventory', (r, p, q, b) => r(businessReportsApiProvider).inventory(_o(q, 'from'), _o(q, 'to'), _o(q, 'currency') ?? 'SAR')),
    ('GET', '/business-reports/debts', (r, p, q, b) => r(businessReportsApiProvider).debts(_o(q, 'from'), _o(q, 'to'), _o(q, 'currency') ?? 'SAR')),
    ('GET', '/business-reports/overview', (r, p, q, b) => r(businessReportsApiProvider).overview(_o(q, 'from'), _o(q, 'to'), _o(q, 'currency') ?? 'SAR')),

    // ── employees ────────────────────────────────────────────────────────
    ('GET', '/employees', (r, p, q, b) => r(employeeApiProvider).list()),
    ('POST', '/employees', (r, p, q, b) => r(employeeApiProvider).create(b)),
    ('PUT', '/employees/{id}', (r, p, q, b) => r(employeeApiProvider).update(p['id']!, b)),
    ('DELETE', '/employees/{id}', (r, p, q, b) => _done(r(employeeApiProvider).remove(p['id']!))),
    ('GET', '/employees/{id}/salary', (r, p, q, b) => r(employeeApiProvider).salary(p['id']!)),
    ('POST', '/employees/{id}/salary', (r, p, q, b) => r(employeeApiProvider).paySalary(p['id']!, b)),
    ('GET', '/employees/{id}/debts', (r, p, q, b) => r(employeeApiProvider).debts(p['id']!)),
    ('POST', '/employees/{id}/debts', (r, p, q, b) => r(employeeApiProvider).addDebt(p['id']!, b)),

    // ── settings ─────────────────────────────────────────────────────────
    ('GET', '/business/project-settings', (r, p, q, b) => r(projectSettingsApiProvider).load()),
    ('PUT', '/business/project-settings', (r, p, q, b) => _done(r(projectSettingsApiProvider).save(b))),
    // The phone's own approved rates (same as every screen); never invented.
    ('GET', '/business/exchange-rate', (r, p, q, b) async {
      final from = _req(q, 'from').toUpperCase(), to = _req(q, 'to').toUpperCase();
      final rate = r(currencyEngineProvider).getRate(from, to);
      if (rate == null || !rate.isFinite || rate <= 0) {
        return {'error': 'لا يوجد سعر صرف موثق لهاتين العملتين. لا تنفذ ولا تخترع سعرًا.'};
      }
      return {'from': from, 'to': to, 'rate': rate};
    }),
    ('GET', '/business/enabled-currencies', (r, p, q, b) async {
      final settings = await r(projectSettingsApiProvider).load();
      return {'enabled_branch_currencies': settings['enabled_currencies'] ?? const []};
    }),
  ];

  /// Every "VERB /template" the phone answers; the server shows Sara only
  /// these in device mode.
  static List<String> get supportedRoutes => [
    for (final (verb, template, _) in _routes) '$verb $template',
  ];

  static (_Handler, Map<String, String>)? _match(String method, String path) {
    final clean = path.split('?').first;
    for (final (verb, template, handler) in _routes) {
      if (verb != method.toUpperCase()) continue;
      final names = <String>[];
      final pattern = RegExp(
        '^${template.replaceAllMapped(RegExp(r'\{([^}]+)\}'), (m) {
          names.add(m.group(1)!);
          return '([^/]+)';
        })}\$',
      );
      final m = pattern.firstMatch(clean);
      if (m == null) continue;
      return (handler, {for (var i = 0; i < names.length; i++) names[i]: Uri.decodeComponent(m.group(i + 1)!)});
    }
    return null;
  }

  static bool supports(String method, String path) => _match(method, path) != null;

  /// Answer one request from this phone's ledger. Never throws: a refusal
  /// (validation, stock/balance floor, permission) comes back as data so
  /// Sara can explain it, exactly as the screen would.
  static Future<Map<String, dynamic>> handle(
    ProviderReader read, {
    required String method,
    required String path,
    Map<String, dynamic>? params,
    Map<String, dynamic>? body,
  }) async {
    final hit = _match(method, path);
    if (hit == null) {
      const reason = 'هذه العملية غير متاحة على الجهاز. استخدم مسارًا آخر من الدليل.';
      return {'success': false, 'error': reason, 'message': reason};
    }
    try {
      final data = await hit.$1(read, hit.$2, {...?params}, {...?body});
      return {'success': true, 'data': data};
    } catch (error) {
      final reason = _reason(error);
      return {'success': false, 'error': reason, 'message': reason};
    }
  }

  static String _reason(Object error) {
    final text = '$error'.replaceFirst(RegExp(r'^[A-Za-z]*(Exception|Error)[: ]*'), '').trim();
    return text.isEmpty || text.length > 400 ? 'رفض التطبيق العملية. راجع البيانات.' : text;
  }

  // ── reconciliation: actual amounts only; system balances read here ──
  static Future<Map<String, dynamic>> _bankCheck(ProviderReader read, Map<String, dynamic> body) async {
    final api = read(reconciliationApiProvider);
    final accounts = await api.accounts();
    final entries = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final actual in _maps(body['actuals'] ?? body['entries'])) {
      final currency = '${actual['currency'] ?? ''}'.toUpperCase();
      final name = '${actual['account_name'] ?? ''}'.trim().toLowerCase();
      final cash = const {'كاش', 'الكاش', 'cash'}.contains(name);
      final id = '${actual['account_id'] ?? ''}';
      final candidates = [
        for (final a in accounts)
          if ((id.isNotEmpty
                  ? '${a['id']}' == id
                  : name.isEmpty ||
                        (cash && a['is_cash'] == true) ||
                        {'${a['name'] ?? ''}', '${a['account_name'] ?? ''}', '${a['bank_name'] ?? ''}'}
                            .map((e) => e.toLowerCase())
                            .contains(name)) &&
              (currency.isEmpty || '${a['currency'] ?? ''}'.toUpperCase() == currency))
            a,
      ];
      if (candidates.length != 1) {
        throw StateError('حدد الحساب وعملته؛ رصيد النظام يُقرأ تلقائيًا.');
      }
      final account = '${candidates.single['id']}';
      final amount = num.tryParse('${actual['actual']}');
      if (amount == null || !amount.isFinite || !seen.add(account)) {
        throw StateError('رصيد فعلي غير صالح أو حساب مكرر.');
      }
      entries.add({'account_id': account, 'actual': '$amount'});
    }
    if (entries.isEmpty) throw StateError('أدخل الرصيد الفعلي للحساب المطلوب.');
    return api.bankCheck(entries: entries, idempotencyKey: ReconciliationApi.newOperationId());
  }

  // ── small argument helpers ──
  static String _s(Map m, String k) => '${m[k] ?? ''}'.trim();
  static String? _o(Map m, String k) {
    final v = _s(m, k);
    return v.isEmpty ? null : v;
  }

  static String _req(Map m, String k) {
    final v = _s(m, k);
    if (v.isEmpty) throw StateError('الحقل $k مطلوب.');
    return v;
  }

  static int _i(Map m, String k, int fallback) => int.tryParse(_s(m, k)) ?? fallback;
  static double? _d(Map m, String k) => double.tryParse(_s(m, k));
  static double _amount(Map m) {
    final v = _d(m, 'amount');
    if (v == null || !v.isFinite || v <= 0) throw StateError('المبلغ غير صالح.');
    return v;
  }

  static List<Map<String, dynamic>> _maps(Object? v) => [
    for (final e in v is List ? v : const [])
      if (e is Map) Map<String, dynamic>.from(e),
  ];
  static List<String> _strings(Object? v) => [for (final e in v is List ? v : const []) '$e'];

  static Future<Object?> _done(Future<void> f) async {
    await f;
    return {'done': true};
  }

  static Future<Object?> _find(Future<List<dynamic>> rows, String id) async {
    for (final row in await rows) {
      if (row is Map && '${row['id']}' == id) return row;
    }
    throw StateError('غير موجود');
  }
}
