import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart' show apiClientProvider;
import '../../../../core/network/api_client.dart';
import '../../../../core/services/currency/currency_engine.dart'
    show currencyEngineProvider;
import '../../../dashboard/data/business_finance_api.dart';
import '../../../inventory/data/falcon_device_runner.dart';
import '../../../inventory/data/inventory_api.dart';
import '../../../invoices/data/invoices_api.dart';
import '../../../purchases/data/purchase_api.dart';
import '../../../returns/data/returns_api.dart';
import '../../presentation/providers/business_all_branches_provider.dart';
import '../local_directory/all_branches_ledger.dart';
import '../local_directory/directory_pilot.dart';
import '../local_directory/directory_scope.dart';
import 'local_commerce_api.dart';

/// Requests that were not given a merged answer never leave the phone in
/// «جميع الفروع»: the view is read-only and the server holds no branch data.
final _noNetwork = ApiClient(
  dio: Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) => handler.reject(
          DioException(
            requestOptions: request,
            type: DioExceptionType.cancel,
            error: const DirectoryAccessDenied(),
          ),
        ),
      ),
    ),
);

/// One read-only commerce bridge per branch of the merged view.
final allBranchesCommerceProvider = Provider<AllBranchesCommerce?>((ref) {
  final all = ref.watch(businessAllBranchesProvider);
  if (all == null) return null;
  final store = ref.watch(directoryPilotStoreProvider);
  final container = ref.container;
  return AllBranchesCommerce(
    all,
    (scope) => LocalCommerceBridge(
      store,
      all.currentScope(scope),
      (_) => all.isCurrent,
      rate: (from, to) =>
          container.read(currencyEngineProvider).getRate(from, to),
    ),
    network: ref.watch(apiClientProvider),
  );
});

typedef BranchBridge = ({String id, String name, LocalCommerceBridge bridge});

final class AllBranchesCommerce {
  AllBranchesCommerce(this.all, this._bridge, {required this.network});
  final BusinessAllBranches all;
  final LocalCommerceBridge Function(DirectoryAccess scope) _bridge;
  final ApiClient network;
  Future<List<BranchBridge>>? _bridges;

  Future<List<BranchBridge>> bridges() => _bridges ??= () async {
    final names = await all.branches();
    if (!all.isCurrent) throw const DirectoryAccessDenied();
    return [
      for (final entry in names.entries)
        (
          id: entry.key,
          name: entry.value,
          bridge: _bridge(all.scopeOf(entry.key)),
        ),
    ];
  }();

  /// Every branch's rows, each naming its branch.
  Future<List<Map<String, dynamic>>> rows(
    Future<List<dynamic>> Function(LocalCommerceBridge bridge) read,
  ) async {
    final out = <Map<String, dynamic>>[];
    for (final branch in await bridges()) {
      for (final row in (await read(branch.bridge)).whereType<Map>()) {
        out.add({
          ...Map<String, dynamic>.from(row),
          'branch_id': branch.id,
          'branch_name': branch.name,
        });
      }
    }
    if (!all.isCurrent) throw const DirectoryAccessDenied();
    return out;
  }
}

extension AllBranchesParties on AllBranchesCommerce {
  /// The customers (or suppliers) of every branch, merged per person, with
  /// each one's open debts per currency over all branches.
  Future<List<Map<String, dynamic>>> parties(
    DirectoryPartyKind kind,
    String query,
  ) async {
    final reads = <BranchRead<List<Map<String, dynamic>>>>[];
    for (final branch in await bridges()) {
      final rows = <Map<String, dynamic>>[];
      for (final party in (await branch.bridge.searchParties(kind, query))
          .whereType<Map>()) {
        final id = '${party['id']}';
        List debts = const [];
        try {
          debts = (await branch.bridge.partyBalance(kind, id))['debts'] as List;
        } on Object {
          debts = const [];
        }
        rows.add({...Map<String, dynamic>.from(party), 'debts': debts});
      }
      reads.add(BranchRead(branch.id, branch.name, rows));
    }
    if (!all.isCurrent) throw const DirectoryAccessDenied();
    return mergeAllBranchesParties(reads);
  }
}

String _nameKey(Object? name) =>
    '${name ?? ''}'.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');

/// «جميع الفروع» inventory: the products of every branch (each names its
/// branch), categories merged by name, Falcon on everything. Read-only.
final class AllBranchesInventoryApi extends InventoryApi {
  AllBranchesInventoryApi(this.commerce) : super(_noNetwork);
  final AllBranchesCommerce commerce;

  /// product id → its branch (ids are unique per device database).
  final Map<String, String> _owner = {};
  final Map<String, String> _categoryNames = {};

  Future<LocalCommerceBridge> _branchOf(String productId) async {
    final branches = await commerce.bridges();
    final known = _owner[productId];
    for (final branch in branches) {
      if (known != null && branch.id != known) continue;
      if (known != null || await branch.bridge.product(productId) != null) {
        _owner[productId] = branch.id;
        return branch.bridge;
      }
    }
    throw const DirectoryAccessDenied();
  }

  Future<String?> _categoryIn(LocalCommerceBridge bridge, String name) async {
    for (final row in await bridge.categories()) {
      if (_nameKey(row['name']) == name) return '${row['id']}';
    }
    return null;
  }

  @override
  Future<List<Map<String, dynamic>>> listProducts({
    String search = '',
    String? stockStatus,
    String? expiry,
    int expiryDays = 30,
    String? categoryId,
    bool uncategorized = false,
    int page = 1,
    int perPage = 50,
  }) async {
    if (categoryId != null && !_categoryNames.containsKey(categoryId)) {
      await categories();
    }
    final category = categoryId == null ? null : _categoryNames[categoryId];
    final rows = <Map<String, dynamic>>[];
    for (final branch in await commerce.bridges()) {
      String? local;
      if (category != null) {
        local = await _categoryIn(branch.bridge, category);
        if (local == null) continue;
      }
      for (final row in await branch.bridge.products(
        search: search,
        stockStatus: stockStatus,
        expiry: expiry,
        expiryDays: 60,
        categoryId: local,
        uncategorized: uncategorized,
        limit: perPage,
        offset: (page - 1) * perPage,
      )) {
        _owner['${row['id']}'] = branch.id;
        rows.add({...row, 'branch_id': branch.id, 'branch_name': branch.name});
      }
    }
    return rows;
  }

  @override
  Future<Map<String, dynamic>> getProduct(String id) async {
    final bridge = await _branchOf(id);
    final branch = (await commerce.bridges()).firstWhere(
      (b) => identical(b.bridge, bridge),
    );
    final row = await bridge.product(id) ?? <String, dynamic>{};
    return {...row, 'branch_id': branch.id, 'branch_name': branch.name};
  }

  @override
  Future<List<Map<String, dynamic>>> branches() async => [
    for (final branch in await commerce.bridges())
      {'id': branch.id, 'name': branch.name},
  ];

  /// Categories of every branch, one per name; the count is the sum.
  @override
  Future<List<Map<String, dynamic>>> categories() async {
    final merged = <String, Map<String, dynamic>>{};
    for (final branch in await commerce.bridges()) {
      for (final row in await branch.bridge.categories()) {
        final key = _nameKey(row['name']);
        final entry = merged[key];
        if (entry == null) {
          merged[key] = {
            ...row,
            'branch_names': [branch.name],
          };
          _categoryNames['${row['id']}'] = key;
          continue;
        }
        _categoryNames['${row['id']}'] = key;
        for (final field in const ['product_count', 'products_count']) {
          final a = entry[field], b = row[field];
          if (a is num && b is num) entry[field] = a + b;
        }
        (entry['branch_names'] as List).add(branch.name);
      }
    }
    return merged.values.toList();
  }

  @override
  Future<List<Map<String, dynamic>>> productMovements(
    String id, {
    int limit = 60,
  }) async => (await _branchOf(id)).movements(id, limit: limit);

  @override
  Future<Map<String, dynamic>> productUnits(String id) async =>
      (await _branchOf(id)).productUnits(id);

  @override
  Future<List<Map<String, dynamic>>> productPrices(String id) async =>
      (await _branchOf(id)).productPrices(id);

  @override
  Future<List<Map<String, dynamic>>> productLots(String id) async =>
      (await _branchOf(id)).lots(id);

  @override
  Future<Map<String, dynamic>> productStats(
    String id, {
    String? from,
    String? to,
    String? displayCurrency,
  }) async => (await _branchOf(id)).productStats(
    id,
    from: from,
    to: to,
    displayCurrency: displayCurrency,
  );

  @override
  Future<Map<String, dynamic>> resolveBarcode(String code) async {
    for (final branch in await commerce.bridges()) {
      try {
        final row = await branch.bridge.resolveBarcode(code);
        if (row.isNotEmpty) {
          return {...row, 'branch_id': branch.id, 'branch_name': branch.name};
        }
      } on Object {
        continue;
      }
    }
    return const {};
  }

  /// Falcon on all branches: the figures of every branch, each naming its
  /// branch, so the analysis compares branches and names them. A product or
  /// category is the same name in every branch. Read and summarised on this
  /// phone; only the compact summary goes to the analysis.
  late final FalconDeviceRunner _falcon = FalconDeviceRunner(
    network: commerce.network,
    owner: commerce,
    read: _falconFigures,
    extra: const {'device_all_branches': true},
  );

  Future<FalconFigures> _falconFigures(
    String scope,
    String? refId,
    String currency,
  ) async {
    String? name;
    String? rawName;
    String? category;
    if (scope == 'product' && refId != null) {
      rawName = '${(await getProduct(refId))['name'] ?? ''}'.trim();
      name = _nameKey(rawName);
    } else if (scope == 'category' && refId != null) {
      if (!_categoryNames.containsKey(refId)) await categories();
      category = _categoryNames[refId];
    }
    final items = <Map<String, dynamic>>[];
    String? categoryName;
    for (final branch in await commerce.bridges()) {
      String? localRef;
      if (scope == 'category' && category != null) {
        localRef = await _categoryIn(branch.bridge, category);
        if (localRef == null) continue;
      }
      final FalconFigures figures;
      if (scope == 'product' && name != null) {
        // Every branch's product of that name, analysed together — read
        // those products only (never the whole inventory of every branch).
        final rows = <Map<String, dynamic>>[];
        for (final p in await branch.bridge.products(search: rawName, limit: 50)) {
          if (_nameKey(p['name']) != name) continue;
          rows.addAll((await branch.bridge.falconFigures(
            'product',
            '${p['id']}',
            currency,
          )).items);
        }
        figures = (items: rows, category: null);
      } else {
        figures = await branch.bridge.falconFigures(scope, localRef, currency);
      }
      categoryName ??= figures.category;
      for (final row in figures.items) {
        if (scope == 'product' && name != null && _nameKey(row['name']) != name) {
          continue;
        }
        items.add({
          ...row,
          'branch_id': branch.id,
          'branch_name': branch.name.isEmpty ? branch.id : branch.name,
        });
      }
    }
    return (items: items, category: categoryName);
  }

  @override
  Future<Map<String, dynamic>?> falconPreview(
    String scope,
    String? refId, {
    String? reportCurrency,
  }) => _falcon.preview(scope, refId, reportCurrency: reportCurrency);

  @override
  Future<Map<String, dynamic>> falconAnalyze(
    String scope,
    String? refId, {
    String? reportCurrency,
  }) => _falcon.analyze(scope, refId, reportCurrency: reportCurrency);

  @override
  Future<Map<String, dynamic>> falconChat(
    String scope,
    String? refId,
    String question,
    List<Map<String, dynamic>> history, {
    String? reportCurrency,
  }) => _falcon.chat(
    scope,
    refId,
    question,
    history,
    reportCurrency: reportCurrency,
  );

  // Nothing is added, edited, moved or deleted in «جميع الفروع».
  Never _readOnly() => throw const DirectoryAccessDenied();

  @override
  Future<Map<String, dynamic>> createProduct(Map<String, dynamic> body) async =>
      _readOnly();

  @override
  Future<Map<String, dynamic>> updateProduct(
    String id,
    Map<String, dynamic> body,
  ) async => _readOnly();

  @override
  Future<void> deleteProduct(String id) async => _readOnly();

  @override
  Future<Map<String, dynamic>> adjustStock(Map<String, dynamic> body) async =>
      _readOnly();

  @override
  Future<Map<String, dynamic>> transferStock(Map<String, dynamic> body) async =>
      _readOnly();

  @override
  Future<Map<String, dynamic>> createCategory(String name) async => _readOnly();

  @override
  Future<Map<String, dynamic>> updateCategory(String id, String name) async =>
      _readOnly();

  @override
  Future<void> deleteCategory(String id) async => _readOnly();
}

/// «جميع الفروع» timeline: every branch's operations, newest first.
final class AllBranchesFinanceApi extends BusinessFinanceApi {
  AllBranchesFinanceApi(this.commerce) : super(_noNetwork);
  final AllBranchesCommerce commerce;

  @override
  Future<List<Map<String, dynamic>>> listTransactions({
    String? kind,
    String? period,
    String? search,
    String? dateFrom,
    String? dateTo,
    bool includeDocLegs = false,
  }) async {
    final rows = await commerce.rows(
      (bridge) => bridge.operations(
        kinds: businessOperationPermissions.keys.toSet(),
        kind: kind,
        period: period,
        search: search,
        dateFrom: dateFrom,
        dateTo: dateTo,
      ),
    );
    rows.sort(
      (a, b) => '${b['date'] ?? b['created_at'] ?? ''}'.compareTo(
        '${a['date'] ?? a['created_at'] ?? ''}',
      ),
    );
    return rows;
  }

  Future<List<Map<String, dynamic>>> recent(Set<String> kinds, int limit) async {
    final rows = await commerce.rows(
      (bridge) => bridge.operations(kinds: kinds, limit: limit),
    );
    rows.sort(
      (a, b) => '${b['date'] ?? b['created_at'] ?? ''}'.compareTo(
        '${a['date'] ?? a['created_at'] ?? ''}',
      ),
    );
    return rows.take(limit).toList();
  }

  @override
  Future<Map<String, dynamic>?> getTransaction(
    String sourceType,
    String sourceId,
  ) async {
    for (final branch in await commerce.bridges()) {
      final row = (await branch.bridge.operations(
        kinds: businessOperationPermissions.keys.toSet(),
        sourceType: sourceType,
        sourceId: sourceId,
        limit: 1,
      )).firstOrNull;
      if (row != null) {
        return {...row, 'branch_id': branch.id, 'branch_name': branch.name};
      }
    }
    return null;
  }
}

String _newestFirst(Map a) => '${a['created_at'] ?? a['date'] ?? ''}';

/// «جميع الفروع» invoices: every branch's documents (each names its branch),
/// newest first. Opening one finds its branch. Read-only.
final class AllBranchesInvoicesApi extends InvoicesApi {
  AllBranchesInvoicesApi(this.commerce) : super(_noNetwork);
  final AllBranchesCommerce commerce;

  @override
  Future<List<dynamic>> list({
    String? type,
    String? search,
    int perPage = 100,
  }) async {
    final rows = await commerce.rows(
      (bridge) => LocalInvoicesApi(_noNetwork, bridge).list(
        type: type,
        search: search,
        perPage: perPage,
      ),
    );
    rows.sort((a, b) => _newestFirst(b).compareTo(_newestFirst(a)));
    return rows;
  }

  @override
  Future<Map<String, dynamic>> getInvoice(String id) async {
    for (final branch in await commerce.bridges()) {
      try {
        final row = await LocalInvoicesApi(_noNetwork, branch.bridge).getInvoice(id);
        return {...row, 'branch_id': branch.id, 'branch_name': branch.name};
      } on DirectoryAccessDenied {
        continue;
      }
    }
    throw const DirectoryAccessDenied();
  }
}

/// «جميع الفروع» returns: every branch's returns. Read-only.
final class AllBranchesReturnsApi extends ReturnsApi {
  AllBranchesReturnsApi(this.commerce) : super(_noNetwork);
  final AllBranchesCommerce commerce;

  @override
  Future<List<dynamic>> list({
    String? kind,
    String? search,
    String? invoiceId,
    int page = 1,
  }) async {
    final rows = await commerce.rows(
      (bridge) =>
          bridge.returns(kind: kind, search: search, invoiceId: invoiceId),
    );
    rows.sort((a, b) => _newestFirst(b).compareTo(_newestFirst(a)));
    return rows;
  }

  @override
  Future<Map<String, dynamic>> detail(String kind, String id) async {
    for (final branch in await commerce.bridges()) {
      try {
        final row = await branch.bridge.returnDetail(kind, id);
        if (row.isNotEmpty) {
          return {...row, 'branch_id': branch.id, 'branch_name': branch.name};
        }
      } on Object {
        continue;
      }
    }
    throw const DirectoryAccessDenied();
  }

  @override
  Future<Map<String, dynamic>> create(
    String invoiceId,
    Map<String, dynamic> body,
  ) async => throw const DirectoryAccessDenied();
}

/// «جميع الفروع» people and their debts for Sara and the pickers: every
/// branch's customers/suppliers (merged per person). Read-only.
final class AllBranchesPurchaseApi extends PurchaseApi {
  AllBranchesPurchaseApi(this.commerce) : super(_noNetwork);
  final AllBranchesCommerce commerce;

  @override
  Future<List<dynamic>> searchCustomers(String query) =>
      commerce.parties(DirectoryPartyKind.customer, query);

  @override
  Future<List<dynamic>> searchSuppliers(String query) =>
      commerce.parties(DirectoryPartyKind.supplier, query);

  Future<Map<String, dynamic>> _balance(DirectoryPartyKind kind, String id) async {
    for (final party in await commerce.parties(kind, '')) {
      final members = (party['members'] as List).cast<Map>();
      if (party['id'] == id || members.any((m) => m['id'] == id)) {
        return {
          'name': party['name'],
          'debts': party['debts'],
          'by_branch': [
            for (final m in members)
              {'branch_name': m['branch_name'], 'debts': m['debts']},
          ],
        };
      }
    }
    throw const DirectoryAccessDenied();
  }

  @override
  Future<Map<String, dynamic>> customerBalance(String id) =>
      _balance(DirectoryPartyKind.customer, id);

  @override
  Future<Map<String, dynamic>> supplierBalance(String id) =>
      _balance(DirectoryPartyKind.supplier, id);

  @override
  Future<List<dynamic>> purchaseInvoices({String? search, int page = 1}) =>
      AllBranchesInvoicesApi(commerce).list(type: 'purchase', search: search);

  @override
  Future<Map<String, dynamic>> getInvoice(String id) =>
      AllBranchesInvoicesApi(commerce).getInvoice(id);
}
