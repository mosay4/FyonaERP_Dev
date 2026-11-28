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
    ImportField('branch', ['الفرع', 'فرع', 'branch', 'store', 'location', 'warehouse', 'المستودع', 'المخزن']),
  ],
  ImportTarget.products: [
    ImportField('name', ['اسم المنتج', 'اسم الصنف', 'الاسم العربي', 'المنتج', 'الصنف', 'الاسم', 'اسم', 'name ar', 'arabic name', 'product name', 'item name', 'product', 'item', 'name', 'title'], required: true),
    ImportField('barcode', ['الباركود', 'باركود', 'barcode', 'ean', 'upc']),
    ImportField('sku', ['رمز المنتج', 'الرمز', 'الكود', 'كود', 'sku', 'code', 'item code']),
    ImportField('unit', ['الوحدة', 'وحدة', 'unit', 'uom']),
    ImportField('sale_price', ['سعر البيع', 'سعر التجزئة', 'السعر', 'سعر', 'price', 'sale price', 'selling price', 'sell price', 'retail price', 'unit price', 'retail']),
    ImportField('cost_price', ['سعر الشراء', 'سعر التكلفة', 'التكلفة', 'تكلفة', 'cost', 'cost price', 'purchase price', 'buy price', 'average cost', 'avg cost', 'buy']),
    ImportField('stock', ['الكمية', 'كمية', 'المخزون', 'الكمية المتوفرة', 'qty', 'quantity', 'stock', 'on hand', 'qty on hand', 'stock qty', 'available']),
    ImportField('category', ['التصنيف', 'تصنيف', 'الفئة', 'المجموعة', 'category', 'group', 'family', 'cat id', 'category id', 'cat']),
    ImportField('image', ['الصورة', 'صورة', 'image', 'img', 'picture', 'photo']),
    ImportField('branch', ['الفرع', 'فرع', 'branch', 'store', 'location', 'warehouse', 'المستودع', 'المخزن']),
    ImportField('min_stock', ['الحد الادنى', 'حد الطلب', 'min stock', 'min qty', 'min quantity', 'reorder', 'reorder level', 'minimum']),
    ImportField('description', ['الوصف', 'وصف', 'description', 'details']),
    ImportField('expiry', ['تاريخ الانتهاء', 'الانتهاء', 'الصلاحية', 'expiry', 'expiry date', 'expiration', 'expire', 'best before']),
    ImportField('notes', ['ملاحظات', 'ملاحظة', 'notes', 'note', 'remarks']),
  ],
  ImportTarget.accounts: [
    ImportField('name', ['اسم الحساب', 'الحساب', 'اسم الصندوق', 'الصندوق', 'صندوق', 'اسم الخزينة', 'الاسم', 'account name', 'account', 'cash box', 'box', 'name'], required: true),
    ImportField('bank', ['البنك', 'اسم البنك', 'bank', 'bank name']),
    ImportField('number', ['رقم الحساب', 'account number', 'account no', 'number', 'acc no']),
    ImportField('iban', ['الايبان', 'ايبان', 'iban']),
    ImportField('balance', ['الرصيد', 'رصيد', 'balance', 'amount', 'opening']),
    ImportField('currency', ['العملة', 'عملة', 'currency', 'cur']),
    ImportField('branch', ['الفرع', 'فرع', 'branch', 'store']),
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
  const arabicKeys = {
    'الصنف', 'صنف', 'المنتج', 'منتج', 'العميل', 'عميل', 'المورد', 'مورد', 'الفاتوره', 'فاتوره', 'التسلسل', 'تسلسل', 'السجل',
    'المجموعه', 'مجموعه', 'الوحده', 'وحده', 'الفرع', 'فرع', 'المخزن', 'المستودع', 'الصندوق', 'التصنيف', 'الفئه', 'القسم',
    'العمله', 'الموظف', 'المستخدم', 'الطلب', 'القيد', 'السند', 'الماده', 'البند',
  };
  return w.last == 'id' ||
      w.length == 1 && (w.single == 'no' || w.single == 'رقم') ||
      w.first == 'رقم' && w.length == 2 && arabicKeys.contains(w[1]) ||
      title.toLowerCase().endsWith('id') && !title.toLowerCase().endsWith('paid') && w.length == 1;
}

const _keyFields = {'barcode', 'sku', 'number', 'iban', 'branch', 'currency'};

/// Deterministic mapping from column titles: every (field, column) pair is
/// scored — same words 3, all the synonym's words present 2, part of a word
/// 1 — and the best pairs are taken first; each column used once.
Map<String, String> autoMapColumns(ImportTarget target, List<String> columns) =>
    mapImportFields(importFields[target]!, columns, keyFields: _keyFields);

const _moneyFields = {'balance', 'debit', 'credit', 'amount', 'paid', 'sale_price', 'cost_price', 'price', 'cost', 'stock', 'quantity'};
const _notMoney = {'limit', 'max', 'maximum', 'rate', 'percent', 'percentage', 'ratio', 'pct', 'tax', 'vat', 'discount', 'weight',
    'حد', 'نسبه', 'الضريبه', 'ضريبه', 'خصم', 'الخصم', 'الوزن', 'سقف'};

/// [autoMapColumns] for any field list; [keyFields] may take key columns
/// (a branch id, a currency id…), the other fields never do.
Map<String, String> mapImportFields(List<ImportField> fields, List<String> columns, {Set<String> keyFields = const {}}) {
  final words = {for (final c in columns) c: importWords(c)};
  final scored = <(int, int, String, String)>[]; // score, field order, field, column
  for (var fi = 0; fi < fields.length; fi++) {
    final f = fields[fi];
    for (final c in columns) {
      if (importIsKey(c) && !keyFields.contains(f.key)) continue;
      final cw = words[c]!;
      final tokens = cw.split(' ').toSet();
      // A limit, rate or percentage is never an amount ("credit_limit" is
      // not a credit balance).
      if (_moneyFields.contains(f.key) && tokens.any(_notMoney.contains)) continue;
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
  'ريال سعودي': 'SAR', 'ر س': 'SAR', 'ريال': 'SAR', 'رس': 'SAR', 'sr': 'SAR', 'sar': 'SAR', '﷼': 'SAR', 'saudi riyal': 'SAR',
  'ريال يمني': 'YER', 'ر ي': 'YER', 'yr': 'YER', 'يمني': 'YER',
  'دولار': 'USD', 'دولار امريكي': 'USD', r'$': 'USD', r'us$': 'USD', 'us dollar': 'USD', 'dollar': 'USD',
  'درهم': 'AED', 'درهم اماراتي': 'AED', 'د ا': 'AED', 'dhs': 'AED', 'dirham': 'AED',
  'دينار كويتي': 'KWD', 'د ك': 'KWD', 'ريال قطري': 'QAR', 'ر ق': 'QAR', 'ريال عماني': 'OMR', 'ر ع': 'OMR',
  'دينار بحريني': 'BHD', 'د ب': 'BHD', 'جنيه مصري': 'EGP', 'جنيه': 'EGP', 'ج م': 'EGP', 'دينار اردني': 'JOD',
  'دينار عراقي': 'IQD', 'ليره تركيه': 'TRY', 'يورو': 'EUR', '€': 'EUR', 'euro': 'EUR', 'جنيه استرليني': 'GBP', '£': 'GBP',
};

/// A currency code from what the file says (code, Arabic/English name or
/// symbol, or an id of the file's currencies table in [codes]). Empty →
/// [fallback]; anything not recognised → null (never guessed).
String? importCurrency(String? raw, String fallback, [Map<String, String>? codes]) {
  final t = (raw ?? '').trim();
  if (t.isEmpty) return fallback;
  final viaTable = codes?[t];
  if (viaTable != null) return viaTable;
  final named = _currencyNames[importFold(t)];
  if (named != null) return named;
  final code = t.toUpperCase();
  return RegExp(r'^[A-Z]{3}$').hasMatch(code) ? code : null;
}

/// A date as YYYY-MM-DD from the usual ways files write it (2026-03-01,
/// 2026/3/1, 01/03/2026, an ISO time); null when it is not a date.
String? importDate(String? raw) {
  if (raw == null) return null;
  final t = raw.trim().split('').map((c) => _digits[c] ?? c).join();
  if (t.isEmpty) return null;
  int? y, m, d;
  final ymd = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})').firstMatch(t);
  final dmy = RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})').firstMatch(t);
  if (ymd != null) {
    y = int.parse(ymd[1]!);
    m = int.parse(ymd[2]!);
    d = int.parse(ymd[3]!);
  } else if (dmy != null) {
    y = int.parse(dmy[3]!);
    m = int.parse(dmy[2]!);
    d = int.parse(dmy[1]!);
  } else {
    return null;
  }
  if (m < 1 || m > 12 || d < 1 || d > 31 || y < 1900 || y > 2200) return null;
  final dt = DateTime(y, m, d);
  if (dt.month != m) return null;
  String two(int n) => n.toString().padLeft(2, '0');
  return '$y-${two(m)}-${two(d)}';
}

/// A decimal rounded to [places]: float noise (9.9900000000002) is cleaned
/// silently; a real extra digit is rounded half-up and reported.
({String value, bool rounded})? importRound(String? decimal, int places) {
  if (decimal == null) return null;
  final neg = decimal.startsWith('-');
  final d = neg ? decimal.substring(1) : decimal;
  final parts = d.split('.');
  final frac = parts.length > 1 ? parts[1] : '';
  if (frac.length <= places) return (value: decimal, rounded: false);
  final rest = frac.substring(places);
  final noise = rest.replaceAll('0', '').isEmpty || rest.startsWith('0000') || rest.startsWith('9999');
  final up = rest.codeUnitAt(0) >= 0x35;
  var units = BigInt.parse('${parts[0]}${frac.substring(0, places)}');
  if (up) units += BigInt.one;
  final txt = units.toString().padLeft(places + 1, '0');
  final whole = txt.substring(0, txt.length - places), tail = txt.substring(txt.length - places);
  final out = places == 0 ? whole : '$whole.$tail';
  return (value: neg && units != BigInt.zero ? '-$out' : out, rounded: !noise);
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
      {this.category,
      this.image,
      this.units = const [],
      this.barcodes = const [],
      this.minStock,
      this.description,
      this.expiry,
      this.notes,
      this.prices = const []});

  /// Prices in other currencies: {currency, price, buy_price}.
  final List<Map<String, String?>> prices;
  final String? expiry, notes;
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
  ImportPreview(this.target, this.mapping, {this.currency = 'SAR'});

  /// The currency of amounts the file does not name (cost prices too).
  final String currency;
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

  /// Prices in other currencies (from a prices table).
  List<Map<String, String?>> prices = const [];
  List<String> reasons = const [];
  List<String> warnings = const [];
  bool rejectedByUser = false;

  /// Unit / extra barcodes left out (already used elsewhere).
  Set<String> droppedCodes = const {};

  /// The phone is left out (used by another card / too long).
  bool dropPhone = false;

  /// A problem found while joining the linked tables (e.g. one customer
  /// with balances in two currencies).
  String? joinProblem;
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
    PartyParts? partyParts,
    Map<String, String> currencyCodes = const {},
    void Function(int rows)? onRows,
  }) async {
    final r = ImportReview._(table, target, Map.of(mapping), defaultKind, defaultCurrency, existing,
        {for (final b in branches) importFold(b)}, {for (final i in images) i.toLowerCase()})
      ..blobImages = blobImages
      ..currencyCodes = currencyCodes;
    final idx = {for (final e in r.mapping.entries) e.key: table.columns.indexOf(e.value)}..removeWhere((_, v) => v < 0);
    final keyIdx = parts?.keyColumn != null
        ? table.columns.indexOf(parts!.keyColumn!)
        : partyParts?.keyColumn != null
            ? table.columns.indexOf(partyParts!.keyColumn!)
            : -1;
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
      final rawKey = keyIdx < 0 || keyIdx >= raw.length ? null : raw[keyIdx];
      final key = rawKey == null || rawKey.trim().isEmpty ? null : importKey(rawKey);
      if (parts != null) {
        // A category id of the categories table → its name.
        final cat = values['category'];
        if (cat != null && parts.categories.containsKey(importKey(cat))) values['category'] = parts.categories[importKey(cat)];
        if (key != null) {
          values['image'] ??= parts.images[key];
          row.units = parts.units[key] ?? const [];
          // The unit of factor 1 is the product's own unit.
          values['unit'] ??= row.units.where((u) => importDecimal(u['factor'] ?? '1') == '1' && (u['name'] ?? '').isNotEmpty)
              .map((u) => u['name'])
              .firstOrNull;
          row.barcodes = parts.barcodes[key] ?? const [];
          r._applyPrices(row, parts.prices[key] ?? const []);
        }
        // A stock table holds the quantities (of the chosen branch): it
        // wins over a quantity column of the products table.
        if (parts.hasStock) values['stock'] = key == null ? null : parts.stock[key] ?? '0';
      }
      if (partyParts?.keyColumn != null) {
        // Balances from a receivables / payables table: that table is the
        // only source (the parties' own balance column is not added on top).
        values
          ..remove('debit')
          ..remove('credit');
        final b = key == null ? null : partyParts!.balances[key];
        if (b == null || b.isEmpty) {
          values['balance'] = '0';
        } else if (b.length > 1) {
          row.joinProblem = 'multi_currency';
        } else {
          final e = b.entries.single;
          values['balance'] = _decimalOf(e.value);
          if (e.key != null) values['currency'] = e.key;
        }
      }
      r.rows.add(row);
    }
    onRows?.call(n);
    if (n == 0) throw const ImportRejected('empty');
    r.revalidate();
    return r;
  }

  /// Currency id of the file's currencies table → ISO code.
  Map<String, String> currencyCodes = const {};

  static const _saleKinds = ['retail', 'sale', 'sell', 'selling', 'default', 'standard', 'normal', 'list', 'base', 'بيع', 'تجزئه', 'قطاعي', 'عادي', 'افتراضي', 'اساسي'];
  static const _costKinds = ['cost', 'purchase', 'buy', 'buying', 'شراء', 'تكلفه'];

  /// Rows of a prices table → the product's sale / cost price (in the
  /// chosen currency) and its prices in other currencies. Other lists
  /// (wholesale…) have no place in a FYONA product and are left out.
  void _applyPrices(ReviewRow row, List<Map<String, String?>> prices) {
    if (prices.isEmpty) return;
    final other = <String, Map<String, String?>>{};
    for (final p in prices) {
      final kind = importFold(p['kind'] ?? '');
      final isCost = kind.isNotEmpty && _costKinds.any((w) => kind.contains(importFold(w)));
      final isSale = kind.isEmpty || _saleKinds.any((w) => kind.contains(importFold(w)));
      final cur = importCurrency(p['currency'], defaultCurrency, currencyCodes);
      if (cur == null) continue;
      if (cur == defaultCurrency) {
        if (isCost) {
          row.values['cost_price'] ??= p['price'];
        } else if (isSale) {
          row.values['sale_price'] ??= p['price'];
          if (p['cost'] != null) row.values['cost_price'] ??= p['cost'];
        }
      } else if (isSale || isCost) {
        final o = other[cur] ??= {'currency': cur};
        if (isCost) {
          o['buy_price'] ??= p['price'];
        } else {
          o['price'] ??= p['price'];
          if (p['cost'] != null) o['buy_price'] ??= p['cost'];
        }
      }
    }
    row.prices = [for (final o in other.values) if (o['price'] != null) o];
  }

  static String _decimalOf(int minor) {
    final neg = minor < 0;
    final a = minor.abs();
    final txt = '${a ~/ 100}.${(a % 100).toString().padLeft(2, '0')}';
    return neg ? '-$txt' : txt;
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
      // Another branch of the file first: the row is not for this branch
      // whatever else is wrong with it.
      final b = r['branch'];
      if (b != null && branches.isNotEmpty && !branches.contains(importFold(importKey(b)))) reasons.add('other_branch');
      if (name == null) reasons.add('missing_name');
      if (r.joinProblem != null) reasons.add(r.joinProblem!);
      if (target == ImportTarget.accounts) {
        final m = _money(r['balance'], warnings);
        if (m == null) {
          reasons.add('bad_number');
        } else if (m < 0) {
          reasons.add('credit_balance');
        }
        if (importCurrency(r['currency'], defaultCurrency, currencyCodes) == null) reasons.add('bad_currency');
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
        final amount = _amountOf(r, kind ?? defaultKind, warnings);
        if (amount == null) {
          reasons.add('bad_number');
        } else if (amount < 0) {
          reasons.add('credit_balance');
        }
        if (importCurrency(r['currency'], defaultCurrency, currencyCodes) == null) reasons.add('bad_currency');
        if (name != null && name.trim().runes.length < 2) reasons.add('name_too_short');
        if (name != null && kind != null) {
          // FYONA keeps one card per name (and per phone) for each kind.
          final key = '$kind|${importFold(name)}';
          if (existing.contains(key)) {
            reasons.add('exists');
          } else if (reasons.isEmpty && !r.rejectedByUser && !seen.add(key)) {
            reasons.add('duplicate_in_file');
          }
          final phone = r['phone']?.trim();
          r.dropPhone = false;
          if (phone != null && phone.isNotEmpty && reasons.isEmpty && !r.rejectedByUser) {
            final pk = 'phone|$kind|$phone';
            if (phone.runes.length > 50 || existing.contains(pk) || !seen.add(pk)) {
              r.dropPhone = true;
              warnings.add('phone_skipped');
            }
          }
        }
      } else {
        for (final f in ['sale_price', 'cost_price', 'min_stock']) {
          final raw = r[f];
          if (raw == null) continue;
          final d = importDecimal(raw);
          if (d == null || d.startsWith('-')) {
            reasons.add('bad_number');
            break;
          }
          if (f != 'min_stock' && (importRound(d, 2)?.rounded ?? false)) warnings.add('rounded');
        }
        final st = r['stock'];
        if (st != null) {
          final d = importDecimal(st);
          if (d == null) {
            reasons.add('bad_number');
          } else if (d.startsWith('-') && d.replaceAll(RegExp(r'[-0.]'), '').isNotEmpty) {
            warnings.add('negative_stock');
          }
        }
        for (final p in r.prices) {
          if (importDecimal(p['price']) == null) warnings.add('price_skipped');
        }
        if (r['expiry'] != null && importDate(r['expiry']) == null) warnings.add('bad_date');
        final img = r['image'];
        if (img != null &&
            !(ImportImages.isBlob(img) ? blobImages : images.contains(img.split('/').last.split('\\').last.toLowerCase()))) {
          warnings.add('image_missing');
        }
        if (r.units.any((u) {
          final f = importDecimal(u['factor'] ?? '1');
          return (u['name'] ?? '').trim().isEmpty || f == null || f.startsWith('-') || double.parse(f) <= 0;
        })) {
          warnings.add('unit_skipped');
        }
        if (name != null) {
          // A product is the same one when its barcode or code says so; two
          // products may share a name (sizes, colours) when their codes differ.
          final barcode = r['barcode'], sku = r['sku'];
          final byName = 'product|${importFold(name)}';
          if ((barcode != null && existing.contains('product|$barcode')) ||
              (sku != null && existing.contains('sku|$sku')) ||
              (barcode == null && sku == null && existing.contains(byName))) {
            reasons.add('exists');
          } else if (reasons.isEmpty && !r.rejectedByUser) {
            final dupCode = (barcode != null && !seen.add('barcode|$barcode')) || (sku != null && !seen.add('sku|$sku'));
            final dupName = !seen.add(byName);
            if (dupCode || (dupName && barcode == null && sku == null)) {
              reasons.add('duplicate_in_file');
            } else if (dupName) {
              warnings.add('same_name');
            }
          }
        }
      }
      r.reasons = reasons;
      r.warnings = warnings;
    }
    if (target == ImportTarget.products) _checkCodes();
  }

  /// One barcode means one thing in a FYONA branch: a unit's or an extra
  /// barcode already used (by another product of the file, or in the
  /// branch) is left out of that product, with a note.
  void _checkCodes() {
    final taken = <String>{
      for (final e in existing)
        if (e.startsWith('code|')) e.substring(5),
      for (final r in rows)
        if (r.accepted && r['barcode'] != null) r['barcode']!,
    };
    for (final r in rows) {
      r.droppedCodes = {};
      if (!r.accepted) continue;
      final own = r['barcode'];
      for (final u in r.units) {
        final b = u['barcode'];
        // The base unit listed again carries the product's own code.
        if (b == null || b.isEmpty || b == own || _unitOf(u, base: r['unit']) == null) continue;
        if (!taken.add(b)) r.droppedCodes.add(b);
      }
      for (final b in r.barcodes) {
        if (b == own) continue;
        if (!taken.add(b)) r.droppedCodes.add(b);
      }
      if (r.droppedCodes.isNotEmpty) r.warnings = [...r.warnings, 'code_skipped'];
    }
  }

  /// Money in minor units; a real third decimal is rounded and reported.
  int? _money(String? raw, List<String> warnings) {
    if (raw == null) return 0;
    final d = importRound(importDecimal(raw), 2);
    if (d == null) return null;
    if (d.rounded && !warnings.contains('rounded')) warnings.add('rounded');
    return importMinor(d.value);
  }

  /// A joined unit with a name and a positive factor (else left out).
  static UnitImport? _unitOf(Map<String, String?> u, {String? base}) {
    final name = u['name']?.trim();
    final f = importDecimal(u['factor'] ?? '1');
    if (name == null || name.isEmpty || f == null || f.startsWith('-') || double.parse(f) <= 0) return null;
    // The base unit listed again (factor 1, same name): it is the product's
    // own unit, not a second one.
    if (double.parse(f) == 1 && (base == null || importFold(base) == importFold(name))) return null;
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

  int? _amountOf(ReviewRow r, String kind, [List<String>? warnings]) {
    final bal = r['balance'], dr = r['debit'], cr = r['credit'];
    final w = warnings ?? <String>[];
    final b = _money(bal, w), d = _money(dr, w), c = _money(cr, w);
    if (b == null || d == null || c == null) return null;
    // Two columns: a customer owes the "they owe" side, a supplier is owed
    // the "we owe" side.
    return b + (kind == 'customer' ? d - c : c - d);
  }

  /// The accepted rows, as the import will write them.
  ImportPreview toPreview() {
    final p = ImportPreview(target, Map.of(mapping), currency: defaultCurrency)..rows = rows.length;
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
        p.accounts.add(AccountImportRow(r.row, clean, r['bank'] ?? clean, r['number'] ?? '-', r['iban'],
            _money(r['balance'], [])!, importCurrency(r['currency'], defaultCurrency, currencyCodes)!));
      } else if (target == ImportTarget.parties) {
        final kind = _kindOf(r)!;
        final amount = _amountOf(r, kind)!;
        final cur = importCurrency(r['currency'], defaultCurrency, currencyCodes)!;
        p.parties.add(PartyImportRow(r.row, kind, clean, r.dropPhone ? null : r['phone']?.trim(), amount, cur));
        (p.totals[kind] ??= {})[cur] = (p.totals[kind]![cur] ?? 0) + amount;
      } else {
        String? num(String f, [int places = 2]) => r[f] == null ? null : importRound(importDecimal(r[f]), places)?.value;
        String? stock() {
          final v = num('stock', 3);
          return v == null || v.startsWith('-') ? (v == null ? null : '0') : v;
        }

        final img = r['image'];
        final codes = <String>{if (r['barcode'] != null) r['barcode']!};
        p.products.add(ProductImportRow(r.row, clean, r['barcode'], r['sku'], r['unit'], num('sale_price'),
            num('cost_price'), stock(),
            category: r['category'],
            image: img != null && !r.warnings.contains('image_missing')
                ? (ImportImages.isBlob(img) ? img : img.split('/').last.split('\\').last)
                : null,
            units: [
              for (final u in r.units)
                if (_unitOf(u, base: r['unit']) case final x?)
                  r.droppedCodes.contains(x.barcode) ? UnitImport(x.name, x.factor, sale: x.sale, cost: x.cost) : x,
            ],
            barcodes: [for (final b in r.barcodes) if (!r.droppedCodes.contains(b) && codes.add(b)) b],
            minStock: num('min_stock', 4),
            description: r['description'],
            expiry: importDate(r['expiry']),
            notes: r['notes'],
            prices: [
              for (final x in r.prices)
                if (importRound(importDecimal(x['price']), 2) case final pr?)
                  {
                    'currency': x['currency'],
                    'price': pr.value,
                    if (importRound(importDecimal(x['buy_price']), 2) case final bp?) 'buy_price': bp.value,
                  },
            ]));
      }
    }
    return p;
  }
}
