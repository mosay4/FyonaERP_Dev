import 'import_plan.dart';
import 'import_source.dart';

/// Smart import, the whole file as ONE connected database: what every
/// table is, which column is which field, and how tables point at each
/// other (a units table pointing at its products, …). Deterministic first;
/// a link is accepted only when the values really match (no guessing).
/// What has no place in FYONA is labelled with the reason and never saved.
enum TableRole {
  customers,
  suppliers,
  products,
  units,
  barcodes,
  images,
  categories,
  accounts,
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
  bool get productPart => const {TableRole.units, TableRole.barcodes, TableRole.images, TableRole.categories}.contains(this);

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

  /// Why it is not imported (history / unsupported / unknown).
  String? reason;
  double confidence;

  /// 'rules' (deterministic) or 'sara'.
  String by;
}

/// Fields of the joined product parts (besides [importFields]).
const partFields = <TableRole, List<ImportField>>{
  TableRole.units: [
    ImportField('name', ['الوحدة', 'اسم الوحدة', 'وحدة', 'unit', 'unit name', 'uom', 'name'], required: true),
    ImportField('factor', ['المعامل', 'معامل التحويل', 'التحويل', 'عدد', 'factor', 'conversion', 'qty per', 'pieces', 'contains', 'rate']),
    ImportField('barcode', ['الباركود', 'باركود', 'barcode', 'ean']),
    ImportField('sale_price', ['سعر البيع', 'السعر', 'price', 'sale price', 'selling price']),
    ImportField('cost_price', ['سعر الشراء', 'التكلفة', 'cost', 'purchase price']),
  ],
  TableRole.barcodes: [
    ImportField('barcode', ['الباركود', 'باركود', 'barcode', 'ean', 'upc', 'code'], required: true),
  ],
  TableRole.images: [
    ImportField('image', ['الصورة', 'صورة', 'image', 'img', 'pic', 'picture', 'photo', 'file', 'path', 'data', 'blob'], required: true),
  ],
  TableRole.categories: [
    ImportField('name', ['التصنيف', 'اسم التصنيف', 'الفئة', 'المجموعة', 'category', 'name', 'title', 'group'], required: true),
  ],
};

const _nameHints = <TableRole, List<String>>{
  TableRole.customers: ['customer', 'client', 'عميل', 'عملاء', 'زبون', 'زبائن'],
  TableRole.suppliers: ['supplier', 'vendor', 'مورد', 'موردين', 'موردون'],
  TableRole.units: ['unit', 'uom', 'وحد'],
  TableRole.barcodes: ['barcode', 'باركود', 'ean'],
  TableRole.images: ['image', 'photo', 'picture', 'صور', 'صوره'],
  TableRole.categories: ['categor', 'group', 'family', 'تصنيف', 'تصنيفات', 'فئ', 'مجموع'],
  TableRole.products: ['product', 'item', 'stock', 'inventory', 'goods', 'منتج', 'منتجات', 'صنف', 'اصناف', 'مواد', 'مخزون', 'بضاع'],
  TableRole.accounts: ['account', 'bank', 'cash', 'wallet', 'حساب', 'حسابات', 'بنك', 'بنوك', 'صندوق', 'خزين', 'خزنه'],
  TableRole.history: ['invoice', 'sale', 'purchase', 'order', 'payment', 'receipt', 'voucher', 'transaction', 'journal', 'return',
      'فاتور', 'فواتير', 'مبيع', 'مشتري', 'سند', 'سندات', 'دفع', 'مدفوع', 'قبض', 'حرك', 'مرتجع', 'قيود'],
  TableRole.unsupported: ['employee', 'staff', 'salary', 'payroll', 'attendance', 'leave', 'asset', 'user', 'role', 'permission',
      'setting', 'log', 'session', 'task', 'project', 'موظف', 'رواتب', 'راتب', 'حضور', 'اجاز', 'اصول', 'مستخدم', 'صلاحي', 'اعداد', 'مهام', 'مشاريع'],
};

const _historyColumns = ['invoice', 'total', 'amount', 'date', 'paid', 'فاتوره', 'الاجمالي', 'المبلغ', 'التاريخ', 'المدفوع', 'رقم الفاتوره'];
const _unsupportedColumns = ['salary', 'hire', 'national id', 'iqama', 'password', 'راتب', 'تاريخ التعيين', 'الهويه', 'كلمه المرور'];
const _productKeys = ['product_id', 'item_id', 'productid', 'itemid', 'product', 'item', 'منتج', 'الصنف', 'رقم الصنف', 'رقم المنتج', 'كود الصنف', 'code', 'sku', 'id'];

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
    if (v != null && v.isNotEmpty) out.add(v);
    if (++n >= limit) break;
  }
  return out;
}

/// Analyses every table of the file.
Future<List<TableAnalysis>> analyzeImportSchema(List<ImportTable> tables) async {
  final out = <TableAnalysis>[];
  for (final t in tables) {
    out.add(await _classify(t));
  }
  await _link(out);
  return out;
}

Future<TableAnalysis> _classify(ImportTable t) async {
  final name = importFold(t.name);
  final cols = t.columns.map(importWords).toList();
  bool col(List<String> words) => cols.any((c) => _hint(c, words));
  final roleByName = <TableRole>[
    for (final e in _nameHints.entries)
      if (_hint(name, e.value)) e.key,
  ];
  final products = autoMapColumns(ImportTarget.products, t.columns);
  final parties = autoMapColumns(ImportTarget.parties, t.columns);
  final accounts = autoMapColumns(ImportTarget.accounts, t.columns);

  // Things FYONA does not hold: said so, never stored.
  if (roleByName.contains(TableRole.unsupported) || col(_unsupportedColumns)) {
    return TableAnalysis(t, TableRole.unsupported, const {}, reason: 'no_place');
  }
  // Old documents/movements: their effect is already in today's balances
  // and stock; entering them again would double debts and stock.
  final historyCols = cols.where((c) => _hint(c, _historyColumns)).length;
  final ownPlace = roleByName.any((r) => r.importable);
  if (roleByName.contains(TableRole.history) && (historyCols >= 1 || !ownPlace) ||
      historyCols >= 3 && !products.containsKey('stock') && !parties.containsKey('phone')) {
    return TableAnalysis(t, TableRole.history, const {}, reason: 'history');
  }
  // Product parts (joined to the products).
  for (final role in const [TableRole.units, TableRole.barcodes, TableRole.images, TableRole.categories]) {
    if (!roleByName.contains(role)) continue;
    final fields = partFields[role]!;
    final map = <String, String>{};
    final used = <String>{};
    for (final f in fields) {
      for (final syn in f.synonyms.map(importWords)) {
        final hit = t.columns.where((c) => !used.contains(c) && importWords(c) == syn).firstOrNull ??
            t.columns.where((c) => !used.contains(c) && importWords(c).contains(syn) && !importIsKey(c)).firstOrNull;
        if (hit != null) {
          map[f.key] = hit;
          used.add(hit);
          break;
        }
      }
    }
    if (fields.where((f) => f.required).every((f) => map.containsKey(f.key))) {
      return TableAnalysis(t, role, map, confidence: .9);
    }
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
    return TableAnalysis(t, TableRole.unknown, const {}, reason: 'unclear', confidence: best.value / 4);
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

bool _isKeyColumn(String c) => importIsKey(c);

/// "UnitID" in a units table, "ID" anywhere: the table's own row number.
bool _ownKey(String column, String table) {
  final w = importWords(column).split(' ').where((x) => x.isNotEmpty).toList();
  if (w.length == 1) return true; // ID / No
  // The table's own thing is its LAST word: tbl_item_units → "unit".
  final tw = importWords(table).split(' ').where((x) => x.isNotEmpty).toList();
  if (tw.isEmpty) return false;
  String one(String x) => x.endsWith('es') && x.length > 4 ? x.substring(0, x.length - 2) : x.endsWith('s') ? x.substring(0, x.length - 1) : x;
  final last = one(tw.last);
  return w.length == 2 && (one(w.first) == last || last.startsWith(one(w.first)) && w.first.length >= 3);
}

/// Product parts are tied to their products by a column whose values are
/// (almost) all keys of the products table.
Future<void> _link(List<TableAnalysis> all) async {
  final products = all.where((a) => a.role == TableRole.products).toList();
  final cats = all.where((a) => a.role == TableRole.categories).toList();
  for (final part in all.where((a) => a.role.productPart && a.role != TableRole.categories)) {
    TableLink? best;
    var bestRank = -1;
    for (final p in products) {
      final keyCols = p.table.columns.where((c) => _hint(importFold(c), _productKeys) || c == p.mapping['barcode'] || c == p.mapping['sku']);
      for (final pk in keyCols) {
        final keys = (await _values(p.table, pk)).toSet();
        if (keys.length < 2) continue;
        final pkWords = importWords(pk);
        for (final fk in part.table.columns) {
          if (part.mapping.containsValue(fk) && !_hint(importFold(fk), _productKeys)) continue;
          final vals = await _values(part.table, fk, limit: 4000);
          if (vals.isEmpty) continue;
          final hit = vals.where(keys.contains).length / vals.length;
          if (hit < .95) continue;
          // The part's OWN row number is not a link even when its values
          // happen to be product numbers too.
          final own = importIsKey(fk) && vals.toSet().length == vals.length && _ownKey(fk, part.table.name);
          if (own) continue;
          // Prefer a column named after the products (or their key).
          final w = importWords(fk);
          final named = w == pkWords || _hint(w, const ['item', 'product', 'صنف', 'منتج', 'مادة']);
          final rank = (named ? 2 : 0) + (hit == 1 ? 1 : 0);
          if (rank > bestRank) {
            bestRank = rank;
            best = TableLink(fk, p.table, pk, hit);
          }
        }
      }
    }
    part.link = best;
    if (best == null) {
      part.role = TableRole.unknown;
      part.reason = 'no_link';
    }
  }
  // Products → category table (by id) when the products hold a category id.
  for (final p in products) {
    for (final c in cats) {
      final catKey = c.table.columns.where((x) => _isKeyColumn(x)).firstOrNull;
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
}

/// What the joined parts add to each product (by the product's key).
class ProductParts {
  final units = <String, List<Map<String, String?>>>{};
  final barcodes = <String, List<String>>{};
  final images = <String, String>{};

  /// category id → name (when products hold ids of a categories table).
  final categories = <String, String>{};

  /// The products' key column the parts point at.
  String? keyColumn;

  /// Rows of a part that point at no product (listed, not imported).
  final orphans = <String, int>{};
}

Future<ProductParts> joinProductParts(List<TableAnalysis> all, ImportTable products) async {
  final parts = ProductParts();
  for (final a in all) {
    final link = a.link;
    if (a.role == TableRole.categories && link != null && link.parent == products) {
      final idCol = link.column, nameCol = a.mapping['name'];
      if (nameCol == null) continue;
      final ii = a.table.columns.indexOf(idCol), ni = a.table.columns.indexOf(nameCol);
      await for (final r in a.table.rows()) {
        final id = r[ii]?.trim(), name = r[ni]?.trim();
        if (id != null && name != null && name.isNotEmpty) parts.categories[id] = name;
      }
      continue;
    }
    if (!a.role.productPart || link == null || link.parent != products) continue;
    parts.keyColumn ??= link.parentColumn;
    if (parts.keyColumn != link.parentColumn) continue;
    final fk = a.table.columns.indexOf(link.column);
    final idx = {for (final e in a.mapping.entries) e.key: a.table.columns.indexOf(e.value)};
    final keys = (await _values(products, link.parentColumn)).toSet();
    await for (final r in a.table.rows()) {
      final key = r[fk]?.trim();
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
          if (b != null) (parts.barcodes[key] ??= []).add(b);
        case TableRole.images:
          final im = at('image');
          if (im != null) parts.images.putIfAbsent(key, () => im);
        default:
      }
    }
  }
  return parts;
}


/// Applies Sara's suggestion to the tables the rules left unclear. Each
/// answer is checked again here (columns exist, the required field is
/// mapped, a part really links to the products) before it is used.
Future<int> applySaraSchema(List<TableAnalysis> all, List<Map<String, dynamic>> answers) async {
  var applied = 0;
  for (final a in all.where((a) => a.role == TableRole.unknown)) {
    final ans = answers.where((x) => x['name'] == a.table.name).firstOrNull;
    if (ans == null) continue;
    final role = TableRole.values.where((r) => r.name == ans['role']).firstOrNull;
    if (role == null || role == TableRole.unknown) continue;
    final mapping = <String, String>{
      for (final e in ((ans['mapping'] as Map?) ?? const {}).entries)
        if (a.table.columns.contains('${e.value}')) '${e.key}': '${e.value}',
    };
    final fields = role.target != null ? importFields[role.target]! : partFields[role] ?? const <ImportField>[];
    if (role.importable || role.productPart) {
      if (!fields.where((f) => f.required).every((f) => mapping.containsKey(f.key))) continue;
    }
    a
      ..role = role
      ..mapping = mapping
      ..reason = role == TableRole.history ? 'history' : role == TableRole.unsupported ? 'no_place' : null
      ..by = 'sara'
      ..confidence = .8;
    applied++;
  }
  // Parts Sara named must still really link to the products.
  await _link(all);
  return applied;
}
