import 'import_plan.dart';
import 'import_source.dart';

/// Smart import, the whole file as ONE connected database: what every
/// table is, which column is which field, and how tables point at each
/// other (units → their products, receivables → their customers, stock →
/// its products and branch…). Deterministic first; a link is accepted only
/// when the values really match (no guessing). What has no place in FYONA
/// is labelled with the reason and never saved.
enum TableRole {
  customers,
  suppliers,
  products,
  accounts,
  units,
  barcodes,
  images,
  categories,
  prices,
  stock,
  balances,
  branches,
  currencies,
  history,
  unsupported,
  unknown,
}

extension TableRoleX on TableRole {
  /// Imported as rows of their own (reviewed in the window).
  bool get importable => const {
        TableRole.customers,
        TableRole.suppliers,
        TableRole.products,
        TableRole.accounts,
      }.contains(this);

  /// Joined into the products (never imported alone).
  bool get productPart => const {
        TableRole.units,
        TableRole.barcodes,
        TableRole.images,
        TableRole.categories,
        TableRole.prices,
        TableRole.stock,
      }.contains(this);

  /// Joined into the customers / suppliers (their balances).
  bool get partyPart => this == TableRole.balances;

  /// Read to understand other tables (branch names, currency codes); not
  /// imported themselves.
  bool get reference => this == TableRole.branches || this == TableRole.currencies;

  bool get part => productPart || partyPart;

  /// Never imported (with the reason shown).
  bool get skipped => this == TableRole.history || this == TableRole.unsupported || this == TableRole.unknown;

  ImportTarget? get target => switch (this) {
        TableRole.customers || TableRole.suppliers => ImportTarget.parties,
        TableRole.products => ImportTarget.products,
        TableRole.accounts => ImportTarget.accounts,
        _ => null,
      };
}

/// child.column → parent table / its key column.
class TableLink {
  const TableLink(this.column, this.parent, this.parentColumn, this.matched);
  final String column;
  final ImportTable parent;
  final String parentColumn;

  /// Share of the child's values found in the parent (1.0 = all).
  final double matched;
}

class TableAnalysis {
  TableAnalysis(this.table, this.role, this.mapping, {this.link, this.reason, this.confidence = 1, this.by = 'rules'});
  final ImportTable table;
  TableRole role;
  Map<String, String> mapping;
  TableLink? link;

  /// Why it is not imported (history / no_place / unclear / no_link).
  String? reason;
  double confidence;

  /// 'rules' (deterministic), 'sara' or 'user'.
  String by;
}

/// Fields of the joined parts and reference tables.
const partFields = <TableRole, List<ImportField>>{
  TableRole.units: [
    ImportField('name', ['الوحدة', 'اسم الوحدة', 'وحدة', 'unit', 'unit name', 'uom', 'name'], required: true),
    ImportField('factor', ['المعامل', 'معامل التحويل', 'التحويل', 'عدد', 'factor', 'conversion', 'qty per', 'pieces', 'contains', 'rate', 'ratio']),
    ImportField('barcode', ['الباركود', 'باركود', 'barcode', 'ean']),
    ImportField('sale_price', ['سعر البيع', 'سعر الوحدة', 'السعر', 'price', 'unit price', 'sale price', 'selling price']),
    ImportField('cost_price', ['سعر الشراء', 'التكلفة', 'cost', 'purchase price']),
  ],
  TableRole.barcodes: [
    ImportField('barcode', ['الباركود', 'باركود', 'barcode', 'ean', 'upc', 'code'], required: true),
  ],
  TableRole.images: [
    ImportField('image', ['الصورة', 'صورة', 'image', 'img', 'pic', 'picture', 'photo', 'file', 'path', 'url', 'data', 'blob'], required: true),
  ],
  TableRole.categories: [
    ImportField('name', ['التصنيف', 'اسم التصنيف', 'الفئة', 'المجموعة', 'category', 'name ar', 'name', 'title', 'group'], required: true),
  ],
  TableRole.prices: [
    ImportField('price', ['السعر', 'سعر البيع', 'سعر', 'price', 'sale price', 'selling price', 'amount', 'value'], required: true),
    ImportField('kind', ['نوع السعر', 'النوع', 'قائمة الأسعار', 'الفئة', 'price type', 'type', 'price list', 'list', 'tier', 'level', 'kind']),
    ImportField('cost', ['سعر الشراء', 'التكلفة', 'cost', 'buy price', 'purchase price']),
    ImportField('currency', ['العملة', 'عملة', 'currency', 'cur']),
  ],
  TableRole.stock: [
    ImportField('quantity', ['الكمية', 'كمية', 'الكمية المتوفرة', 'المتوفر', 'الرصيد', 'quantity', 'qty', 'on hand', 'qty on hand', 'stock', 'available', 'balance'], required: true),
    ImportField('branch', ['الفرع', 'فرع', 'المستودع', 'المخزن', 'branch', 'store', 'warehouse', 'location']),
  ],
  TableRole.balances: [
    ImportField('amount', ['المبلغ المستحق', 'المستحق', 'المتبقي', 'الرصيد', 'المبلغ', 'amount due', 'balance due', 'outstanding', 'remaining', 'open balance', 'balance', 'due', 'amount'], required: true),
    ImportField('paid', ['المدفوع', 'paid', 'paid amount', 'amount paid']),
    ImportField('currency', ['العملة', 'عملة', 'currency', 'cur']),
  ],
  TableRole.branches: [
    ImportField('name', ['اسم الفرع', 'الفرع', 'الاسم', 'branch name', 'name ar', 'name', 'title'], required: true),
  ],
  TableRole.currencies: [
    ImportField('code', ['رمز العملة', 'الرمز', 'الكود', 'code', 'iso', 'iso code', 'currency code', 'symbol'], required: true),
  ],
};

/// Part fields that may be key columns (a branch id, a currency id).
const _partKeyFields = {'branch', 'currency', 'code'};

const _nameHints = <TableRole, List<String>>{
  TableRole.customers: ['customer', 'client', 'debtor', 'عميل', 'عملاء', 'زبون', 'زبائن'],
  TableRole.suppliers: ['supplier', 'vendor', 'creditor', 'مورد', 'موردين', 'موردون'],
  TableRole.units: ['unit', 'uom', 'وحد'],
  TableRole.barcodes: ['barcode', 'باركود', 'ean'],
  TableRole.images: ['image', 'photo', 'picture', 'صور', 'صوره'],
  TableRole.categories: ['categor', 'group', 'family', 'تصنيف', 'تصنيفات', 'فئ', 'مجموع'],
  TableRole.prices: ['price', 'pricing', 'tariff', 'سعر', 'اسعار', 'تسعير'],
  TableRole.stock: ['stock', 'quant', 'inventory', 'on hand', 'warehouse stock', 'مخزون', 'كميات', 'ارصده المخزن', 'المستودع'],
  TableRole.balances: ['receivable', 'payable', 'outstanding', 'opening balance', 'balances', 'aging', 'ذمم', 'مديوني', 'مستحقات', 'ارصده', 'ارصده افتتاحيه', 'ديون'],
  TableRole.branches: ['branch', 'فرع', 'فروع'],
  TableRole.currencies: ['currenc', 'عملات', 'العمله'],
  TableRole.products: ['product', 'item', 'stock', 'inventory', 'goods', 'article', 'منتج', 'منتجات', 'صنف', 'اصناف', 'مواد', 'مخزون', 'بضاع'],
  TableRole.accounts: ['account', 'bank', 'cash', 'wallet', 'treasury', 'حساب', 'حسابات', 'بنك', 'بنوك', 'صندوق', 'صناديق', 'خزين', 'خزنه'],
  TableRole.history: ['invoice', 'sale', 'purchase', 'order', 'payment', 'receipt', 'voucher', 'transaction', 'journal', 'return',
      'movement', 'entry', 'entries', 'ledger', 'فاتور', 'فواتير', 'مبيع', 'مشتري', 'سند', 'سندات', 'دفع', 'مدفوع', 'قبض', 'حرك', 'مرتجع', 'قيود'],
  TableRole.unsupported: ['employee', 'staff', 'salary', 'payroll', 'attendance', 'leave', 'asset', 'user', 'role', 'permission',
      'setting', 'config', 'log', 'session', 'task', 'project', 'contract', 'warranty', 'subscription', 'plan', 'maintenance',
      'work order', 'equipment', 'vehicle', 'ticket', 'appointment', 'booking', 'reservation', 'audit', 'notification', 'message',
      'shift', 'migration', 'tax rule', 'department', 'campaign', 'loyalty', 'coupon', 'survey', 'chart of accounts', 'coa',
      'دليل الحسابات', 'شجره الحسابات',
      'موظف', 'رواتب', 'راتب', 'حضور', 'اجاز', 'اصول', 'مستخدم', 'صلاحي', 'اعداد', 'مهام', 'مشاريع', 'عقود', 'عقد', 'ضمان',
      'اشتراك', 'صيانه', 'معدات', 'مواعيد', 'حجوزات', 'تذاكر', 'اقسام', 'سجل'],
};

const _historyColumns = ['invoice', 'total', 'date', 'paid', 'فاتوره', 'الاجمالي', 'التاريخ', 'المدفوع', 'رقم الفاتوره'];
const _unsupportedColumns = ['salary', 'hire', 'national id', 'iqama', 'password', 'راتب', 'تاريخ التعيين', 'الهويه', 'كلمه المرور'];
const _productKeys = ['product_id', 'item_id', 'productid', 'itemid', 'product', 'item', 'منتج', 'الصنف', 'رقم الصنف', 'رقم المنتج', 'كود الصنف', 'code', 'sku', 'barcode', 'id'];
const _partyKeys = ['customer', 'client', 'supplier', 'vendor', 'party', 'partner', 'account', 'debtor', 'creditor', 'code', 'id',
    'عميل', 'العميل', 'مورد', 'المورد', 'رقم', 'كود'];

bool _hint(String folded, List<String> words) => words.any((w) => folded.contains(importFold(w)));

final _valueCache = Expando<Map<String, List<String>>>();

/// Reads the values of [column] (up to [limit] rows), once per table.
Future<List<String>> _values(ImportTable t, String column, {int limit = 20000}) async {
  final cache = _valueCache[t] ??= {};
  final key = '$column|$limit';
  return cache[key] ??= await _readValues(t, column, limit: limit);
}

Future<List<String>> _readValues(ImportTable t, String column, {int limit = 20000}) async {
  final i = t.columns.indexOf(column);
  final out = <String>[];
  if (i < 0) return out;
  var n = 0;
  await for (final r in t.rows()) {
    final v = i < r.length ? r[i]?.trim() : null;
    if (v != null && v.isNotEmpty) out.add(_canon(v));
    if (++n >= limit) break;
  }
  return out;
}

/// Same key whether stored as 12, 12.0 or "12".
String importKey(String v) => _canon(v.trim());

String _canon(String v) => RegExp(r'^\d+\.0+$').hasMatch(v) ? v.substring(0, v.indexOf('.')) : v;

/// What the whole file says besides its rows: the branches it holds and
/// the currency codes behind its currency ids.
class ImportContext {
  /// Branch key/name as written in the file → its display name.
  final branches = <String, String>{};

  /// Currency id → ISO code (from a currencies table).
  final currencyCodes = <String, String>{};
}

/// Analyses every table of the file.
Future<List<TableAnalysis>> analyzeImportSchema(List<ImportTable> tables, {ImportContext? context}) async {
  final out = <TableAnalysis>[];
  for (final t in tables) {
    out.add(await _classify(t));
  }
  await linkImportSchema(out, context: context);
  return out;
}

Map<String, String> _mapPart(TableRole role, List<String> columns) =>
    mapImportFields(partFields[role]!, columns, keyFields: _partKeyFields);

bool _requiredMapped(TableRole role, Map<String, String> map) {
  final fields = role.target != null ? importFields[role.target]! : partFields[role] ?? const <ImportField>[];
  return fields.where((f) => f.required).every((f) => map.containsKey(f.key));
}

Future<TableAnalysis> _classify(ImportTable t) async {
  final name = importFold(importWords(t.name));
  final cols = t.columns.map(importWords).toList();
  bool col(List<String> words) => cols.any((c) => _hint(c, words));
  final roleByName = <TableRole>[
    for (final e in _nameHints.entries)
      if (_hint(name, e.value)) e.key,
  ];
  final products = autoMapColumns(ImportTarget.products, t.columns);
  final parties = autoMapColumns(ImportTarget.parties, t.columns);
  final accounts = autoMapColumns(ImportTarget.accounts, t.columns);
  // Columns pointing at another table (not the table's own row number).
  final linkish = t.columns.where((c) => importIsKey(c) && !_ownKey(c, t.name)).length;

  // Things FYONA does not hold: said so, never stored.
  if (roleByName.contains(TableRole.unsupported) || col(_unsupportedColumns)) {
    return TableAnalysis(t, TableRole.unsupported, const {}, reason: 'no_place');
  }
  // Reference tables (read to understand the others).
  if (roleByName.contains(TableRole.currencies)) {
    final m = _mapPart(TableRole.currencies, t.columns);
    if (m.containsKey('code')) return TableAnalysis(t, TableRole.currencies, m, confidence: .9);
  }
  if (roleByName.contains(TableRole.branches) && !roleByName.any((r) => r.importable || r.part || r == TableRole.history)) {
    final m = _mapPart(TableRole.branches, t.columns);
    if (m.containsKey('name')) return TableAnalysis(t, TableRole.branches, m, confidence: .9);
  }
  // Parts named after what they hold (a receivables table is checked
  // before the "history" rule: it is today's balance, not a movement).
  for (final role in const [
    TableRole.units,
    TableRole.barcodes,
    TableRole.images,
    TableRole.categories,
    TableRole.prices,
    TableRole.balances,
    TableRole.stock,
  ]) {
    if (!roleByName.contains(role)) continue;
    if (role == TableRole.stock && products.containsKey('name') && t.columns.length > 6) continue;
    if (role == TableRole.prices && products.containsKey('name') && products.containsKey('barcode')) continue;
    if (role != TableRole.categories && linkish == 0) continue;
    final map = _mapPart(role, t.columns);
    if (_requiredMapped(role, map)) return TableAnalysis(t, role, map, confidence: .9);
  }
  // Old documents/movements: their effect is already in today's balances
  // and stock; entering them again would double debts and stock.
  final historyCols = cols.where((c) => _hint(c, _historyColumns)).length;
  final ownPlace = roleByName.any((r) => r.importable);
  if (roleByName.contains(TableRole.history) && (historyCols >= 1 || !ownPlace) ||
      historyCols >= 3 && !products.containsKey('stock') && !parties.containsKey('phone')) {
    return TableAnalysis(t, TableRole.history, const {}, reason: 'history');
  }
  // Rows with their own place.
  final scores = <TableRole, double>{
    TableRole.products: (products.containsKey('name') ? 1 : 0) +
        ['barcode', 'sale_price', 'cost_price', 'stock', 'unit', 'sku'].where(products.containsKey).length * .6 +
        (roleByName.contains(TableRole.products) ? 2 : 0),
    TableRole.customers: (parties.containsKey('name') ? 1 : 0) +
        ['phone', 'balance', 'debit', 'credit'].where(parties.containsKey).length * .6 +
        (roleByName.contains(TableRole.customers) ? 2 : 0),
    TableRole.suppliers: (parties.containsKey('name') ? 1 : 0) +
        ['phone', 'balance', 'debit', 'credit'].where(parties.containsKey).length * .6 +
        (roleByName.contains(TableRole.suppliers) ? 2.1 : 0),
    TableRole.accounts: (accounts.containsKey('name') ? 1 : 0) +
        ['bank', 'number', 'iban'].where(accounts.containsKey).length * .8 +
        (roleByName.contains(TableRole.accounts) ? 2 : 0),
  };
  final best = scores.entries.reduce((a, b) => b.value > a.value ? b : a);
  final second = scores.entries.where((e) => e.key != best.key).map((e) => e.value).fold<double>(0, (a, b) => b > a ? b : a);
  // Customers vs suppliers with no name hint: one parties table with a
  // type column is still clear (the column says it per row).
  if (best.value < 1.6 || (best.value - second) < .5 && !(best.key == TableRole.suppliers || best.key == TableRole.customers)) {
    // Nothing of FYONA's in it at all (no name, no money, no code): it has
    // no place; anything in between is left for Sara.
    final none = !products.containsKey('name') && !parties.containsKey('name') && !accounts.containsKey('name');
    return none && roleByName.isEmpty
        ? TableAnalysis(t, TableRole.unknown, const {}, reason: 'unclear', confidence: 0)
        : TableAnalysis(t, TableRole.unknown, const {}, reason: 'unclear', confidence: best.value / 4);
  }
  final role = best.key == TableRole.suppliers && !roleByName.contains(TableRole.suppliers) && !roleByName.contains(TableRole.customers)
      ? TableRole.customers
      : best.key;
  final map = switch (role) {
    TableRole.products => products,
    TableRole.accounts => accounts,
    _ => parties,
  };
  final clear = roleByName.contains(role) || (role == TableRole.customers && map.containsKey('kind'));
  return TableAnalysis(t, role, map, confidence: clear ? 1 : .75);
}

/// "UnitID" in a units table, "ID" anywhere: the table's own row number.
bool _ownKey(String column, String table) {
  final w = importWords(column).split(' ').where((x) => x.isNotEmpty).toList();
  if (w.length == 1) return true; // ID / No
  // The table's own thing is its LAST word: tbl_item_units → "unit".
  final tw = importWords(table).split(' ').where((x) => x.isNotEmpty).toList();
  if (tw.isEmpty) return false;
  String one(String x) => x.endsWith('ies') && x.length > 4
      ? '${x.substring(0, x.length - 3)}y'
      : x.endsWith('es') && x.length > 4
          ? x.substring(0, x.length - 2)
          : x.endsWith('s')
              ? x.substring(0, x.length - 1)
              : x;
  final last = one(tw.last);
  return w.length == 2 && (one(w.first) == last || last.startsWith(one(w.first)) && w.first.length >= 3);
}

/// The best column of [child] whose values are (almost) all keys of one of
/// [parents]. The child's own row number never counts as a link.
Future<TableLink?> _bestLink(TableAnalysis child, List<TableAnalysis> parents, List<String> parentKeyHints,
    List<String> namedHints, {int Function(TableAnalysis parent, String column)? prefer}) async {
  TableLink? best;
  var bestRank = -1;
  for (final p in parents) {
    final keyCols = p.table.columns.where((c) =>
        _hint(importFold(importWords(c)), parentKeyHints.map(importWords).toList()) ||
        c == p.mapping['barcode'] ||
        c == p.mapping['sku'] ||
        importIsKey(c));
    for (final pk in keyCols) {
      final keys = (await _values(p.table, pk)).toSet();
      if (keys.length < 2) continue;
      final pkWords = importWords(pk);
      for (final fk in child.table.columns) {
        if (child.mapping.containsValue(fk) && !importIsKey(fk)) continue;
        final vals = await _values(child.table, fk, limit: 4000);
        if (vals.isEmpty) continue;
        final hit = vals.where(keys.contains).length / vals.length;
        if (hit < .95) continue;
        final own = importIsKey(fk) && vals.toSet().length == vals.length && _ownKey(fk, child.table.name);
        if (own) continue;
        final w = importWords(fk);
        final named = w == pkWords || _hint(w, namedHints);
        final rank = (named ? 2 : 0) + (hit == 1 ? 1 : 0) + (prefer?.call(p, fk) ?? 0);
        if (rank > bestRank) {
          bestRank = rank;
          best = TableLink(fk, p.table, pk, hit);
        }
      }
    }
  }
  return best;
}

/// Ties parts to their products / customers, reads branch names and
/// currency codes, and drops what does not really link.
Future<void> linkImportSchema(List<TableAnalysis> all, {ImportContext? context}) async {
  final products = all.where((a) => a.role == TableRole.products).toList();
  final parties = all.where((a) => a.role == TableRole.customers || a.role == TableRole.suppliers).toList();
  final cats = all.where((a) => a.role == TableRole.categories).toList();
  for (final part in all.where((a) => a.role.productPart && a.role != TableRole.categories)) {
    final best = await _bestLink(part, products, _productKeys, const ['item', 'product', 'article', 'صنف', 'منتج', 'مادة']);
    part.link = best;
    if (best == null) {
      part
        ..role = TableRole.unknown
        ..reason = 'no_link';
    }
  }
  for (final part in all.where((a) => a.role.partyPart)) {
    // Ids of customers and suppliers often overlap (both 1, 2, 3…): the
    // side the table and its column name decide.
    final tableWords = importFold(importWords(part.table.name));
    final buy = _hint(tableWords, const ['supplier', 'vendor', 'payable', 'creditor', 'مورد', 'دائن']);
    final sell = _hint(tableWords, const ['customer', 'client', 'receivable', 'debtor', 'عميل', 'زبون', 'مدين']);
    final best = await _bestLink(part, parties, _partyKeys,
        const ['customer', 'client', 'supplier', 'vendor', 'party', 'partner', 'عميل', 'مورد'], prefer: (p, fk) {
      final w = importFold(importWords(fk));
      final colBuy = _hint(w, const ['supplier', 'vendor', 'مورد']), colSell = _hint(w, const ['customer', 'client', 'عميل', 'زبون']);
      final wantSuppliers = colBuy || (!colSell && buy && !sell);
      final wantCustomers = colSell || (!colBuy && sell && !buy);
      if (wantSuppliers) return p.role == TableRole.suppliers ? 4 : -4;
      if (wantCustomers) return p.role == TableRole.customers ? 4 : -4;
      return 0;
    });
    part.link = best;
    if (best == null) {
      part
        ..role = TableRole.unknown
        ..reason = 'no_link';
    }
  }
  // Products → category table (by id) when the products hold a category id.
  for (final p in products) {
    for (final c in cats) {
      final catKey = c.table.columns.where(importIsKey).firstOrNull;
      if (catKey == null) continue;
      final keys = (await _values(c.table, catKey)).toSet();
      bool catColumn(String x) {
        final w = importWords(x).split(' ');
        return w.any((t) => const {'cat', 'category', 'categories', 'group', 'family'}.contains(t)) ||
            _hint(importFold(x), ['تصنيف', 'فئ', 'مجموع']);
      }

      for (final fk in p.table.columns.where(catColumn)) {
        final vals = await _values(p.table, fk, limit: 4000);
        if (vals.isEmpty) continue;
        final hit = vals.where(keys.contains).length / vals.length;
        if (hit >= .95) {
          c.link = TableLink(catKey, p.table, fk, hit);
          p.mapping['category'] = fk;
        }
      }
    }
  }
  final ctx = context;
  if (ctx == null) return;
  // Branch names: a branches table (id → name) and every branch value.
  ctx.branches.clear();
  for (final b in all.where((a) => a.role == TableRole.branches)) {
    final key = b.table.columns.where(importIsKey).firstOrNull, name = b.mapping['name'];
    if (name == null) continue;
    final ki = key == null ? -1 : b.table.columns.indexOf(key), ni = b.table.columns.indexOf(name);
    await for (final r in b.table.rows()) {
      final n = ni < r.length ? r[ni]?.trim() : null;
      if (n == null || n.isEmpty) continue;
      ctx.branches[n] = n;
      final k = ki < 0 || ki >= r.length ? null : r[ki]?.trim();
      if (k != null && k.isNotEmpty) ctx.branches[_canon(k)] = n;
    }
  }
  // Currency ids → codes.
  ctx.currencyCodes.clear();
  for (final c in all.where((a) => a.role == TableRole.currencies)) {
    final key = c.table.columns.where(importIsKey).firstOrNull, code = c.mapping['code'];
    if (key == null || code == null) continue;
    final ki = c.table.columns.indexOf(key), ci = c.table.columns.indexOf(code);
    await for (final r in c.table.rows()) {
      final k = ki < r.length ? r[ki]?.trim() : null, v = ci < r.length ? r[ci]?.trim().toUpperCase() : null;
      if (k != null && v != null && RegExp(r'^[A-Z]{3}$').hasMatch(v)) ctx.currencyCodes[_canon(k)] = v;
    }
  }
  // A currency id column that no currencies table explains is dropped
  // (amounts then use the chosen currency) instead of refusing every row.
  for (final a in all) {
    final cur = a.mapping['currency'];
    if (cur == null || !importIsKey(cur)) continue;
    final vals = await _values(a.table, cur, limit: 2000);
    if (vals.isEmpty || !vals.every(ctx.currencyCodes.containsKey)) a.mapping.remove('currency');
  }
  // A branch column whose values are not branches of the file is no branch.
  for (final a in all) {
    final br = a.mapping['branch'];
    if (br == null || !importIsKey(br)) continue;
    final vals = await _values(a.table, br, limit: 2000);
    if (ctx.branches.isEmpty) {
      for (final v in vals.toSet()) {
        ctx.branches.putIfAbsent(v, () => v);
      }
    } else if (!vals.every(ctx.branches.containsKey)) {
      a.mapping.remove('branch');
    }
  }
  for (final a in all) {
    final br = a.mapping['branch'];
    if (br == null || importIsKey(br)) continue;
    for (final v in (await _values(a.table, br, limit: 2000)).toSet()) {
      ctx.branches.putIfAbsent(v, () => v);
    }
  }
}

/// The file's branches by display name (each with every key that means
/// it), for the "which branch of the file" choice.
Map<String, Set<String>> importBranchChoices(ImportContext ctx) {
  final out = <String, Set<String>>{};
  for (final e in ctx.branches.entries) {
    (out[e.value] ??= {}).add(e.key);
  }
  return out;
}

/// What the joined parts add to each product (by the product's key).
class ProductParts {
  final units = <String, List<Map<String, String?>>>{};
  final barcodes = <String, List<String>>{};
  final images = <String, String>{};

  /// Price rows: {price, kind, cost, currency}.
  final prices = <String, List<Map<String, String?>>>{};

  /// Quantity per product (decimal text), summed over the chosen branch.
  final stock = <String, String>{};

  /// Products that have a stock table (a product missing there has 0).
  bool hasStock = false;

  /// category id → name (when products hold ids of a categories table).
  final categories = <String, String>{};

  /// The products' key column the parts point at.
  String? keyColumn;

  /// Rows of a part that point at no product (listed, not imported).
  final orphans = <String, int>{};
}

/// [branchKeys]: the file's branch to import (null: all branches).
Future<ProductParts> joinProductParts(List<TableAnalysis> all, ImportTable products, {Set<String>? branchKeys}) async {
  final parts = ProductParts();
  final stockSum = <String, BigInt>{}; // product → quantity × 1000
  for (final a in all) {
    final link = a.link;
    if (a.role == TableRole.categories && link != null && link.parent == products) {
      final idCol = link.column, nameCol = a.mapping['name'];
      if (nameCol == null) continue;
      final ii = a.table.columns.indexOf(idCol), ni = a.table.columns.indexOf(nameCol);
      await for (final r in a.table.rows()) {
        final id = ii < r.length ? r[ii]?.trim() : null, name = ni < r.length ? r[ni]?.trim() : null;
        if (id != null && name != null && name.isNotEmpty) parts.categories[_canon(id)] = name;
      }
      continue;
    }
    if (!a.role.productPart || link == null || link.parent != products) continue;
    parts.keyColumn ??= link.parentColumn;
    if (parts.keyColumn != link.parentColumn) continue;
    final fk = a.table.columns.indexOf(link.column);
    final idx = {for (final e in a.mapping.entries) e.key: a.table.columns.indexOf(e.value)};
    final keys = (await _values(products, link.parentColumn)).toSet();
    if (a.role == TableRole.stock) parts.hasStock = true;
    await for (final r in a.table.rows()) {
      final raw = fk < r.length ? r[fk]?.trim() : null;
      final key = raw == null ? null : _canon(raw);
      if (key == null || !keys.contains(key)) {
        parts.orphans[a.table.name] = (parts.orphans[a.table.name] ?? 0) + 1;
        continue;
      }
      String? at(String f) {
        final i = idx[f];
        final v = i == null || i < 0 || i >= r.length ? null : r[i]?.trim();
        return v == null || v.isEmpty ? null : v;
      }

      switch (a.role) {
        case TableRole.units:
          (parts.units[key] ??= []).add({
            'name': at('name'), 'factor': at('factor'), 'barcode': at('barcode'),
            'sale_price': at('sale_price'), 'cost_price': at('cost_price'),
          });
        case TableRole.barcodes:
          final b = at('barcode');
          if (b != null) (parts.barcodes[key] ??= []).add(_canon(b));
        case TableRole.images:
          final im = at('image');
          if (im != null) parts.images.putIfAbsent(key, () => im);
        case TableRole.prices:
          (parts.prices[key] ??= []).add({'price': at('price'), 'kind': at('kind'), 'cost': at('cost'), 'currency': at('currency')});
        case TableRole.stock:
          final b = at('branch');
          if (branchKeys != null && (b == null || !branchKeys.contains(_canon(b)))) continue;
          final q = importRound(importDecimal(at('quantity')), 3)?.value;
          if (q == null) continue;
          final neg = q.startsWith('-');
          final p = (neg ? q.substring(1) : q).split('.');
          final milli = BigInt.parse('${p[0]}${(p.length > 1 ? p[1] : '').padRight(3, '0')}');
          stockSum[key] = (stockSum[key] ?? BigInt.zero) + (neg ? -milli : milli);
        default:
      }
    }
  }
  for (final e in stockSum.entries) {
    final neg = e.value.isNegative;
    final t = e.value.abs().toString().padLeft(4, '0');
    final txt = '${t.substring(0, t.length - 3)}.${t.substring(t.length - 3)}'.replaceFirst(RegExp(r'\.?0+$'), '');
    parts.stock[e.key] = '${neg ? '-' : ''}${txt.isEmpty ? '0' : txt}';
  }
  return parts;
}

/// The balance each customer / supplier owes today, from a receivables or
/// payables table (summed per party; paid amounts taken off).
class PartyParts {
  /// party key → currency (null: the row's / chosen one) → minor units.
  final balances = <String, Map<String?, int>>{};
  String? keyColumn;
  final orphans = <String, int>{};

  /// Rows whose amount is not a number (listed, not imported).
  int badRows = 0;
}

Future<PartyParts> joinPartyParts(List<TableAnalysis> all, ImportTable parties, {Map<String, String>? currencyCodes}) async {
  final out = PartyParts();
  for (final a in all.where((a) => a.role.partyPart && a.link?.parent == parties)) {
    final link = a.link!;
    out.keyColumn ??= link.parentColumn;
    if (out.keyColumn != link.parentColumn) continue;
    final fk = a.table.columns.indexOf(link.column);
    final ai = a.table.columns.indexOf(a.mapping['amount'] ?? '');
    final pi = a.table.columns.indexOf(a.mapping['paid'] ?? '');
    final ci = a.table.columns.indexOf(a.mapping['currency'] ?? '');
    final keys = (await _values(parties, link.parentColumn)).toSet();
    await for (final r in a.table.rows()) {
      final raw = fk < r.length ? r[fk]?.trim() : null;
      final key = raw == null ? null : _canon(raw);
      if (key == null || !keys.contains(key)) {
        out.orphans[a.table.name] = (out.orphans[a.table.name] ?? 0) + 1;
        continue;
      }
      String? at(int i) => i < 0 || i >= r.length ? null : r[i]?.trim();
      int? minor(String? v) => v == null || v.isEmpty ? 0 : importMinor(importRound(importDecimal(v), 2)?.value);
      final amount = minor(at(ai)), paid = minor(at(pi));
      if (amount == null || paid == null) {
        out.badRows++;
        continue;
      }
      final cur = at(ci);
      final code = cur == null || cur.isEmpty ? null : (currencyCodes?[_canon(cur)] ?? cur);
      final m = out.balances[key] ??= {};
      m[code] = (m[code] ?? 0) + amount - paid;
    }
  }
  return out;
}

/// Applies Sara's suggestion to the tables the rules left unclear or were
/// not sure of. Each answer is checked again here (columns exist, the
/// required field is mapped, a part really links) before it is used.
Future<int> applySaraSchema(List<TableAnalysis> all, List<Map<String, dynamic>> answers, {ImportContext? context}) async {
  var applied = 0;
  for (final a in all.where((a) => a.by != 'user' && (a.role == TableRole.unknown || a.confidence < .9))) {
    final ans = answers.where((x) => x['name'] == a.table.name).firstOrNull;
    if (ans == null) continue;
    final role = TableRole.values.where((r) => r.name == ans['role']).firstOrNull;
    if (role == null || role == TableRole.unknown) continue;
    final mapping = <String, String>{
      for (final e in ((ans['mapping'] as Map?) ?? const {}).entries)
        if (a.table.columns.contains('${e.value}')) '${e.key}': '${e.value}',
    };
    if ((role.importable || role.part || role.reference) && !_requiredMapped(role, mapping)) continue;
    a
      ..role = role
      ..mapping = mapping
      ..link = null
      ..reason = role == TableRole.history ? 'history' : role == TableRole.unsupported ? 'no_place' : null
      ..by = 'sara'
      ..confidence = .85;
    applied++;
  }
  // Parts Sara named must still really link.
  await linkImportSchema(all, context: context);
  return applied;
}

/// The user (or Sara at the user's request) puts a table somewhere else.
/// The columns are mapped again for that place; a part must still link.
Future<void> setTableRole(List<TableAnalysis> all, TableAnalysis a, TableRole role, {ImportContext? context}) async {
  a
    ..role = role
    ..by = 'user'
    ..confidence = 1
    ..link = null
    ..reason = switch (role) {
      TableRole.history => 'history',
      TableRole.unsupported => 'no_place',
      TableRole.unknown => 'by_user',
      _ => null,
    }
    ..mapping = role.target != null
        ? autoMapColumns(role.target!, a.table.columns)
        : partFields.containsKey(role)
            ? _mapPart(role, a.table.columns)
            : <String, String>{};
  await linkImportSchema(all, context: context);
}
