import 'import_schema.dart';
import 'import_source.dart';

/// Smart import, step 2: which column is which field (deterministic rules
/// first; Sara may suggest a mapping from a small sample), then every row
/// checked into a preview. Nothing is written here.
enum ImportTarget { parties, products, accounts }

class ImportField {
  const ImportField(this.key, this.synonyms, {this.required = false});
  final String key;
  final List<String> synonyms;
  final bool required;
}

const importFields = <ImportTarget, List<ImportField>>{
  ImportTarget.parties: [
    ImportField('name', ['اسم العميل', 'اسم المورد', 'الاسم', 'العميل', 'المورد', 'الزبون', 'اسم', 'name', 'customer', 'supplier', 'vendor', 'client', 'party'], required: true),
    ImportField('kind', ['النوع', 'نوع', 'الفئة', 'type', 'kind', 'category']),
    ImportField('phone', ['الجوال', 'الهاتف', 'رقم الجوال', 'رقم الهاتف', 'جوال', 'هاتف', 'موبايل', 'phone', 'mobile', 'tel', 'telephone']),
    ImportField('balance', ['الرصيد', 'رصيد', 'المبلغ', 'الدين', 'المستحق', 'المتبقي', 'balance', 'amount', 'due', 'outstanding', 'opening balance']),
    ImportField('debit', ['مدين', 'debit', 'dr']),
    ImportField('credit', ['دائن', 'credit', 'cr']),
    ImportField('currency', ['العملة', 'عملة', 'currency', 'cur']),
    ImportField('branch', ['الفرع', 'فرع', 'branch', 'store', 'location']),
  ],
  ImportTarget.products: [
    ImportField('name', ['اسم المنتج', 'اسم الصنف', 'المنتج', 'الصنف', 'الاسم', 'اسم', 'product', 'item', 'name', 'description'], required: true),
    ImportField('barcode', ['الباركود', 'باركود', 'barcode', 'ean', 'upc']),
    ImportField('sku', ['رمز المنتج', 'الرمز', 'الكود', 'كود', 'sku', 'code', 'item code']),
    ImportField('unit', ['الوحدة', 'وحدة', 'unit', 'uom']),
    ImportField('sale_price', ['سعر البيع', 'السعر', 'سعر', 'price', 'sale price', 'selling price', 'retail']),
    ImportField('cost_price', ['سعر الشراء', 'التكلفة', 'تكلفة', 'cost', 'cost price', 'purchase price', 'buy price', 'buy']),
    ImportField('stock', ['الكمية', 'كمية', 'المخزون', 'الرصيد', 'qty', 'quantity', 'stock', 'on hand']),
    ImportField('category', ['التصنيف', 'تصنيف', 'الفئة', 'المجموعة', 'category', 'group', 'family', 'cat id', 'category id', 'cat']),
    ImportField('image', ['الصورة', 'صورة', 'image', 'img', 'picture', 'photo']),
    ImportField('branch', ['الفرع', 'فرع', 'branch', 'store', 'location']),
    ImportField('min_stock', ['الحد الادنى', 'حد الطلب', 'min stock', 'min qty', 'reorder', 'minimum']),
    ImportField('description', ['الوصف', 'وصف', 'ملاحظات', 'description', 'notes']),
  ],
  ImportTarget.accounts: [
    ImportField('name', ['اسم الحساب', 'الحساب', 'account name', 'account', 'name'], required: true),
    ImportField('bank', ['البنك', 'اسم البنك', 'bank', 'bank name']),
    ImportField('number', ['رقم الحساب', 'account number', 'number', 'acc no']),
    ImportField('iban', ['الايبان', 'ايبان', 'iban']),
    ImportField('balance', ['الرصيد', 'رصيد', 'balance', 'amount', 'opening']),
    ImportField('currency', ['العملة', 'عملة', 'currency', 'cur']),
    ImportField('branch', ['الفرع', 'فرع', 'branch']),
  ],
};

/// Folds Arabic spelling variants, case, spaces and punctuation.
String importFold(String s) => s
    .toLowerCase()
    .replaceAll(RegExp('[ً-ٰٟـ]'), '')
    .replaceAll(RegExp('[أإآ]'), 'ا')
    .replaceAll('ة', 'ه')
    .replaceAll('ى', 'ي')
    .replaceAll(RegExp(r'[\s_\-:./()]+'), ' ')
    .trim();

/// Column title → comparable words: camelCase and snake_case split, Arabic
/// spelling folded ("ItemName" → "item name", "Sale_Price" → "sale price").
String importWords(String title) => importFold(title
    .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
    .replaceAllMapped(RegExp(r'([A-Z]+)([A-Z][a-z])'), (m) => '${m[1]} ${m[2]}'));

/// A key column (ItemID, CustID, رقم الصنف…): never a data field.
bool importIsKey(String title) {
  final w = importWords(title).split(' ').where((x) => x.isNotEmpty).toList();
  if (w.isEmpty) return false;
  const arabicKeys = {'الصنف', 'صنف', 'المنتج', 'منتج', 'العميل', 'عميل', 'المورد', 'مورد', 'الفاتوره', 'فاتوره', 'التسلسل', 'تسلسل', 'السجل'};
  return w.last == 'id' ||
      w.length == 1 && (w.single == 'no' || w.single == 'رقم') ||
      w.first == 'رقم' && w.length == 2 && arabicKeys.contains(w[1]) ||
      title.toLowerCase().endsWith('id') && !title.toLowerCase().endsWith('paid') && w.length == 1;
}

const _keyFields = {'barcode', 'sku', 'number', 'iban'};

/// Deterministic mapping from column titles: every (field, column) pair is
/// scored — same words 3, all the synonym's words present 2, part of a word
/// 1 — and the best pairs are taken first; each column used once.
Map<String, String> autoMapColumns(ImportTarget target, List<String> columns) {
  final words = {for (final c in columns) c: importWords(c)};
  final scored = <(int, int, String, String)>[]; // score, field order, field, column
  final fields = importFields[target]!;
  for (var fi = 0; fi < fields.length; fi++) {
    final f = fields[fi];
    for (final c in columns) {
      if (importIsKey(c) && !_keyFields.contains(f.key)) continue;
      final cw = words[c]!;
      final tokens = cw.split(' ').toSet();
      var best = 0;
      for (var si = 0; si < f.synonyms.length; si++) {
        final syn = importWords(f.synonyms[si]);
        final st = syn.split(' ').where((x) => x.isNotEmpty).toList();
        final score = cw == syn
            ? 30
            : st.every(tokens.contains)
                ? 20 + st.length
                : (syn.length >= 3 && cw.contains(syn))
                    ? 10
                    : 0;
        if (score > best) best = score;
      }
      if (best > 0) scored.add((best, fi, f.key, c));
    }
  }
  scored.sort((a, b) => b.$1 != a.$1 ? b.$1.compareTo(a.$1) : a.$2.compareTo(b.$2));
  final out = <String, String>{};
  final used = <String>{};
  for (final (_, _, field, col) in scored) {
    if (out.containsKey(field) || used.contains(col)) continue;
    out[field] = col;
    used.add(col);
  }
  return out;
}

const _digits = {
  '٠': '0', '١': '1', '٢': '2', '٣': '3', '٤': '4', '٥': '5', '٦': '6', '٧': '7', '٨': '8', '٩': '9',
  '۰': '0', '۱': '1', '۲': '2', '۳': '3', '۴': '4', '۵': '5', '۶': '6', '۷': '7', '۸': '8', '۹': '9',
};

/// A decimal number as written by people and spreadsheets: Arabic digits,
/// ٫ / ٬ separators, thousands commas, currency words, (negative), 12-.
/// Returns the plain decimal text, or null when it is not a number.
String? importDecimal(String? raw) {
  if (raw == null) return null;
  var s = raw.trim();
  if (s.isEmpty) return null;
  s = s.split('').map((c) => _digits[c] ?? c).join();
  s = s.replaceAll('٫', '.').replaceAll('٬', ',').replaceAll('٫', '.').replaceAll(' ', '');
  var negative = false;
  if (s.startsWith('(') && s.endsWith(')')) {
    negative = true;
    s = s.substring(1, s.length - 1);
  }
  s = s.replaceAll(RegExp(r'[^\d.,+\-]'), '');
  if (s.endsWith('-')) {
    negative = !negative;
    s = s.substring(0, s.length - 1);
  }
  if (s.startsWith('-')) {
    negative = !negative;
    s = s.substring(1);
  } else if (s.startsWith('+')) {
    s = s.substring(1);
  }
  if (s.isEmpty) return null;
  // 1,234.56 | 1.234,56 | 1234,56
  final lastDot = s.lastIndexOf('.'), lastComma = s.lastIndexOf(',');
  if (lastDot >= 0 && lastComma >= 0) {
    if (lastComma > lastDot) {
      s = s.replaceAll('.', '').replaceAll(',', '.');
    } else {
      s = s.replaceAll(',', '');
    }
  } else if (lastComma >= 0) {
    final tail = s.length - lastComma - 1;
    s = (tail == 3 && RegExp(r'^\d{1,3}(,\d{3})+$').hasMatch(s)) ? s.replaceAll(',', '') : s.replaceAll(',', '.');
  }
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(s) || s.length > 30) return null;
  return negative ? '-$s' : s;
}

/// Minor units (2 decimals) from [importDecimal] text; null when more than
/// 2 decimals would be lost or the number is too large.
int? importMinor(String? decimal) {
  if (decimal == null) return null;
  final neg = decimal.startsWith('-');
  final d = neg ? decimal.substring(1) : decimal;
  final parts = d.split('.');
  final frac = parts.length > 1 ? parts[1] : '';
  if (frac.length > 2 && frac.substring(2).replaceAll('0', '').isNotEmpty) return null;
  final whole = int.tryParse(parts[0]);
  if (whole == null || parts[0].length > 13) return null;
  final cents = int.parse((frac.length >= 2 ? frac.substring(0, 2) : frac.padRight(2, '0')));
  final v = whole * 100 + cents;
  return neg ? -v : v;
}

const _currencyNames = {
  'ريال سعودي': 'SAR', 'ر س': 'SAR', 'ريال': 'SAR', 'ريال يمني': 'YER', 'دولار': 'USD', 'دولار امريكي': 'USD',
  'درهم': 'AED', 'درهم اماراتي': 'AED', 'دينار كويتي': 'KWD', 'ريال قطري': 'QAR', 'ريال عماني': 'OMR',
  'دينار بحريني': 'BHD', 'جنيه مصري': 'EGP', 'يورو': 'EUR', '\$': 'USD', 'sr': 'SAR',
};

String? importCurrency(String? raw, String fallback) {
  final t = (raw ?? '').trim();
  if (t.isEmpty) return fallback;
  final named = _currencyNames[importFold(t)];
  if (named != null) return named;
  final code = t.toUpperCase();
  return RegExp(r'^[A-Z]{3}$').hasMatch(code) ? code : null;
}

const _customerWords = ['عميل', 'زبون', 'عملاء', 'customer', 'client', 'c'];
const _supplierWords = ['مورد', 'موردين', 'supplier', 'vendor', 's'];

class ImportIssue {
  const ImportIssue(this.row, this.code, [this.value]);

  /// File row number (1 = first row after the titles).
  final int row;

  /// missing_name | bad_number | credit_balance | bad_currency | bad_kind |
  /// duplicate_in_file | exists | too_many_decimals | other_branch |
  /// rejected_by_user
  final String code;
  final String? value;
}

class PartyImportRow {
  PartyImportRow(this.row, this.kind, this.name, this.phone, this.amountMinor, this.currency);
  final int row;
  final String kind; // customer | supplier
  final String name;
  final String? phone;
  final int amountMinor;
  final String currency;
}

class UnitImport {
  UnitImport(this.name, this.factor, {this.barcode, this.sale, this.cost});
  final String name;
  final String factor;
  final String? barcode, sale, cost;
}

class AccountImportRow {
  AccountImportRow(this.row, this.name, this.bank, this.number, this.iban, this.amountMinor, this.currency);
  final int row;
  final String name, bank, number;
  final String? iban;
  final int amountMinor;
  final String currency;
}

class ProductImportRow {
  ProductImportRow(this.row, this.name, this.barcode, this.sku, this.unit, this.sale, this.cost, this.stock,
      {this.category, this.image, this.units = const [], this.barcodes = const [], this.minStock, this.description});
  final List<UnitImport> units;
  final List<String> barcodes;
  final String? minStock, description;
  final int row;
  final String name;
  final String? barcode, sku, unit;
  final String? sale, cost, stock;
  final String? category;

  /// A picture file name inside the same ZIP (null: none).
  final String? image;
}

/// What the import WILL do: only the approved rows that have a place in
/// FYONA. Built from an [ImportReview].
class ImportPreview {
  ImportPreview(this.target, this.mapping);
  final ImportTarget target;
  final Map<String, String> mapping;
  int rows = 0;
  final parties = <PartyImportRow>[];
  final products = <ProductImportRow>[];
  final accounts = <AccountImportRow>[];
  final issues = <ImportIssue>[];
  int issueCount = 0;

  /// kind → currency → total balance (minor units).
  final totals = <String, Map<String, int>>{};
  int get ready => switch (target) {
        ImportTarget.parties => parties.length,
        ImportTarget.products => products.length,
        ImportTarget.accounts => accounts.length,
      };
}

/// Checks every row of [table] with [mapping] (see [ImportReview]) and
/// returns what would be imported, with every refused row listed.
Future<ImportPreview> buildImportPreview(
  ImportTable table,
  ImportTarget target,
  Map<String, String> mapping, {
  String defaultKind = 'customer',
  String defaultCurrency = 'SAR',
  Set<String> existing = const {},
  Set<String> branches = const {},
  Set<String> images = const {},
  void Function(int rows)? onRows,
}) async {
  final r = await ImportReview.load(table, target, mapping,
      defaultKind: defaultKind,
      defaultCurrency: defaultCurrency,
      existing: existing,
      branches: branches,
      images: images,
      onRows: onRows);
  return r.toPreview();
}

/// One source row under review: the mapped values (edited by the user or
/// not), why it cannot be imported, and the user's own decision.
class ReviewRow {
  ReviewRow(this.row, this.values);
  final int row;
  final Map<String, String?> values;

  /// Joined from the linked tables (products only).
  List<Map<String, String?>> units = const [];
  List<String> barcodes = const [];
  List<String> reasons = const [];
  List<String> warnings = const [];
  bool rejectedByUser = false;
  bool get accepted => reasons.isEmpty && !rejectedByUser;
  String? operator [](String field) => values[field];
}

/// The review behind the import screen: every row of one table, mapped to
/// FYONA fields, checked by the same rules again after every edit.
/// Columns that map to no field are listed and never saved.
class ImportReview {
  ImportReview._(this.table, this.target, this.mapping, this.defaultKind, this.defaultCurrency, this.existing,
      this.branches, this.images);

  final ImportTable table;
  final ImportTarget target;
  final Map<String, String> mapping;
  final String defaultKind;
  final String defaultCurrency;
  final Set<String> existing;

  /// Folded names / ids of the branch being imported into.
  final Set<String> branches;

  /// Picture file names available in the same ZIP.
  final Set<String> images;

  /// Pictures stored inside the (SQLite) file itself.
  bool blobImages = false;
  final rows = <ReviewRow>[];

  static Future<ImportReview> load(
    ImportTable table,
    ImportTarget target,
    Map<String, String> mapping, {
    String defaultKind = 'customer',
    String defaultCurrency = 'SAR',
    Set<String> existing = const {},
    Set<String> branches = const {},
    Set<String> images = const {},
    bool blobImages = false,
    ProductParts? parts,
    void Function(int rows)? onRows,
  }) async {
    final r = ImportReview._(table, target, Map.of(mapping), defaultKind, defaultCurrency, existing,
        {for (final b in branches) importFold(b)}, {for (final i in images) i.toLowerCase()})
      ..blobImages = blobImages;
    final idx = {for (final e in r.mapping.entries) e.key: table.columns.indexOf(e.value)}..removeWhere((_, v) => v < 0);
    final keyIdx = parts?.keyColumn == null ? -1 : table.columns.indexOf(parts!.keyColumn!);
    var n = 0;
    await for (final raw in table.rows()) {
      n++;
      if (n % 5000 == 0) onRows?.call(n);
      final values = <String, String?>{};
      for (final e in idx.entries) {
        final v = e.value < raw.length ? raw[e.value]?.trim() : null;
        values[e.key] = v == null || v.isEmpty ? null : v;
      }
      final row = ReviewRow(n, values);
      if (parts != null) {
        // A category id of the categories table → its name.
        final cat = values['category'];
        if (cat != null && parts.categories.containsKey(cat)) values['category'] = parts.categories[cat];
        final key = keyIdx < 0 || keyIdx >= raw.length ? null : raw[keyIdx]?.trim();
        if (key != null) {
          values['image'] ??= parts.images[key];
          row.units = parts.units[key] ?? const [];
          row.barcodes = parts.barcodes[key] ?? const [];
        }
      }
      r.rows.add(row);
    }
    onRows?.call(n);
    if (n == 0) throw const ImportRejected('empty');
    r.revalidate();
    return r;
  }

  /// Columns of the file that go nowhere in FYONA (never saved).
  List<String> get unusedColumns => [for (final c in table.columns) if (!mapping.containsValue(c)) c];

  int get acceptedCount => rows.where((r) => r.accepted).length;
  int get refusedCount => rows.length - acceptedCount;

  /// Refused rows grouped by their first reason (for the red section).
  Map<String, int> get refusedByReason {
    final out = <String, int>{};
    for (final r in rows) {
      if (r.accepted) continue;
      final k = r.reasons.isNotEmpty ? r.reasons.first : 'rejected_by_user';
      out[k] = (out[k] ?? 0) + 1;
    }
    return out;
  }

  /// Edits one cell; the whole table is checked again (duplicates).
  void edit(ReviewRow row, String field, String? value) {
    final v = value?.trim();
    row.values[field] = v == null || v.isEmpty ? null : v;
    revalidate();
  }

  void setRejected(Iterable<ReviewRow> which, bool rejected) {
    for (final r in which) {
      r.rejectedByUser = rejected;
    }
  }

  /// Checks every row (same rules as the import itself).
  void revalidate() {
    final seen = <String>{};
    for (final r in rows) {
      final reasons = <String>[];
      final warnings = <String>[];
      final name = r['name'];
      if (name == null) reasons.add('missing_name');
      final b = r['branch'];
      if (b != null && branches.isNotEmpty && !branches.contains(importFold(b))) reasons.add('other_branch');
      if (target == ImportTarget.accounts) {
        final bal = r['balance'];
        final m = bal == null ? 0 : importMinor(importDecimal(bal));
        if (m == null) {
          reasons.add('bad_number');
        } else if (m < 0) {
          reasons.add('credit_balance');
        }
        if (importCurrency(r['currency'], defaultCurrency) == null) reasons.add('bad_currency');
        if (name != null) {
          final key = 'account|${importFold(name)}|${importFold(r['bank'] ?? '')}';
          if (existing.contains(key)) {
            reasons.add('exists');
          } else if (reasons.isEmpty && !r.rejectedByUser && !seen.add(key)) {
            reasons.add('duplicate_in_file');
          }
        }
      } else if (target == ImportTarget.parties) {
        final kind = _kindOf(r);
        if (kind == null) reasons.add('bad_kind');
        final amount = _amountOf(r, kind ?? defaultKind);
        if (amount == null) {
          reasons.add('bad_number');
        } else if (amount < 0) {
          reasons.add('credit_balance');
        }
        if (importCurrency(r['currency'], defaultCurrency) == null) reasons.add('bad_currency');
        if (name != null && kind != null) {
          final key = '$kind|${importFold(name)}';
          if (existing.contains(key)) {
            reasons.add('exists');
          } else if (reasons.isEmpty && !r.rejectedByUser && !seen.add(key)) {
            reasons.add('duplicate_in_file');
          }
        }
      } else {
        for (final f in ['sale_price', 'cost_price', 'stock']) {
          final raw = r[f];
          if (raw == null) continue;
          final d = importDecimal(raw);
          if (d == null || d.startsWith('-')) {
            reasons.add('bad_number');
            break;
          }
          if (f != 'stock' && importMinor(d) == null) {
            reasons.add('too_many_decimals');
            break;
          }
        }
        final img = r['image'];
        if (img != null &&
            !(ImportImages.isBlob(img) ? blobImages : images.contains(img.split('/').last.split('\\').last.toLowerCase()))) {
          warnings.add('image_missing');
        }
        if (r.units.any((u) => _unitOf(u) == null)) warnings.add('unit_skipped');
        if (name != null) {
          final barcode = r['barcode'];
          final byName = 'product|${importFold(name)}';
          if (existing.contains(byName) || (barcode != null && existing.contains('product|$barcode'))) {
            reasons.add('exists');
          } else if (reasons.isEmpty && !r.rejectedByUser) {
            final byCode = barcode == null ? null : 'barcode|$barcode';
            if (!seen.add(byName) || (byCode != null && !seen.add(byCode))) reasons.add('duplicate_in_file');
          }
        }
      }
      r.reasons = reasons;
      r.warnings = warnings;
    }
  }

  /// A joined unit with a name and a positive factor (else left out).
  static UnitImport? _unitOf(Map<String, String?> u) {
    final name = u['name']?.trim();
    final f = importDecimal(u['factor'] ?? '1');
    if (name == null || name.isEmpty || f == null || f.startsWith('-') || double.parse(f) <= 0) return null;
    String? n(String k) => u[k] == null ? null : importDecimal(u[k]);
    return UnitImport(name, f, barcode: u['barcode'], sale: n('sale_price'), cost: n('cost_price'));
  }

  String? _kindOf(ReviewRow r) {
    final k = r['kind'];
    if (k == null) return defaultKind;
    final f = importFold(k);
    if (_customerWords.any((w) => f == w || f.contains(w) && w.length > 1)) return 'customer';
    if (_supplierWords.any((w) => f == w || f.contains(w) && w.length > 1)) return 'supplier';
    return null;
  }

  int? _amountOf(ReviewRow r, String kind) {
    final bal = r['balance'], dr = r['debit'], cr = r['credit'];
    int? read(String? v) => v == null ? 0 : importMinor(importDecimal(v));
    final b = read(bal), d = read(dr), c = read(cr);
    if (b == null || d == null || c == null) return null;
    // Two columns: a customer owes the "they owe" side, a supplier is owed
    // the "we owe" side.
    return b + (kind == 'customer' ? d - c : c - d);
  }

  /// The accepted rows, as the import will write them.
  ImportPreview toPreview() {
    final p = ImportPreview(target, Map.of(mapping))..rows = rows.length;
    for (final r in rows) {
      if (!r.accepted) {
        p.issueCount++;
        if (p.issues.length < 500) {
          p.issues.add(ImportIssue(r.row, r.reasons.isNotEmpty ? r.reasons.first : 'rejected_by_user', r['name']));
        }
        continue;
      }
      final name = r['name']!;
      final clean = name.length > 120 ? name.substring(0, 120) : name;
      if (target == ImportTarget.accounts) {
        final bal = r['balance'];
        p.accounts.add(AccountImportRow(r.row, clean, r['bank'] ?? clean, r['number'] ?? '-', r['iban'],
            bal == null ? 0 : importMinor(importDecimal(bal))!, importCurrency(r['currency'], defaultCurrency)!));
      } else if (target == ImportTarget.parties) {
        final kind = _kindOf(r)!;
        final amount = _amountOf(r, kind)!;
        final cur = importCurrency(r['currency'], defaultCurrency)!;
        p.parties.add(PartyImportRow(r.row, kind, clean, r['phone'], amount, cur));
        (p.totals[kind] ??= {})[cur] = (p.totals[kind]![cur] ?? 0) + amount;
      } else {
        String? num(String f) => r[f] == null ? null : importDecimal(r[f]);
        final img = r['image'];
        final codes = <String>{if (r['barcode'] != null) r['barcode']!};
        p.products.add(ProductImportRow(r.row, clean, r['barcode'], r['sku'], r['unit'], num('sale_price'),
            num('cost_price'), num('stock'),
            category: r['category'],
            image: img != null && !r.warnings.contains('image_missing')
                ? (ImportImages.isBlob(img) ? img : img.split('/').last.split('\\').last)
                : null,
            units: [for (final u in r.units) if (_unitOf(u) case final x?) x],
            barcodes: [for (final b in r.barcodes) if (codes.add(b)) b],
            minStock: num('min_stock'),
            description: r['description']));
      }
    }
    return p;
  }
}
