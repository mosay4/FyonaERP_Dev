import 'import_source.dart';

/// Smart import, step 2: which column is which field (deterministic rules
/// first; Sara may suggest a mapping from a small sample), then every row
/// checked into a preview. Nothing is written here.
enum ImportTarget { parties, products, archive }

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
  ],
  ImportTarget.products: [
    ImportField('name', ['اسم المنتج', 'اسم الصنف', 'المنتج', 'الصنف', 'الاسم', 'اسم', 'product', 'item', 'name', 'description'], required: true),
    ImportField('barcode', ['الباركود', 'باركود', 'barcode', 'ean', 'upc']),
    ImportField('sku', ['رمز المنتج', 'الرمز', 'الكود', 'كود', 'sku', 'code', 'item code']),
    ImportField('unit', ['الوحدة', 'وحدة', 'unit', 'uom']),
    ImportField('sale_price', ['سعر البيع', 'السعر', 'سعر', 'price', 'sale price', 'selling price']),
    ImportField('cost_price', ['سعر الشراء', 'التكلفة', 'تكلفة', 'cost', 'cost price', 'purchase price']),
    ImportField('stock', ['الكمية', 'كمية', 'المخزون', 'الرصيد', 'qty', 'quantity', 'stock', 'on hand']),
  ],
  ImportTarget.archive: [],
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

/// Deterministic mapping from column titles (exact title first, then a
/// title containing a known word). Each column used once.
Map<String, String> autoMapColumns(ImportTarget target, List<String> columns) {
  final out = <String, String>{};
  final used = <String>{};
  final folded = {for (final c in columns) c: importFold(c)};
  for (final pass in [0, 1]) {
    for (final f in importFields[target]!) {
      if (out.containsKey(f.key)) continue;
      for (final syn in f.synonyms.map(importFold)) {
        final hit = columns.where((c) => !used.contains(c) && (pass == 0 ? folded[c] == syn : folded[c]!.contains(syn))).firstOrNull;
        if (hit != null) {
          out[f.key] = hit;
          used.add(hit);
          break;
        }
      }
    }
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
  /// duplicate_in_file | exists | too_many_decimals
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

class ProductImportRow {
  ProductImportRow(this.row, this.name, this.barcode, this.sku, this.unit, this.sale, this.cost, this.stock);
  final int row;
  final String name;
  final String? barcode, sku, unit;
  final String? sale, cost, stock;
}

/// What the import WOULD do — shown to the user before anything is written.
class ImportPreview {
  ImportPreview(this.target, this.mapping);
  final ImportTarget target;
  final Map<String, String> mapping;
  int rows = 0;
  final parties = <PartyImportRow>[];
  final products = <ProductImportRow>[];
  final archive = <List<String?>>[];
  final issues = <ImportIssue>[];
  int issueCount = 0;

  /// kind → currency → total opening balance (minor units).
  final totals = <String, Map<String, int>>{};
  int get ready => target == ImportTarget.parties
      ? parties.length
      : target == ImportTarget.products
          ? products.length
          : archive.length;

  void _issue(ImportIssue i) {
    issueCount++;
    if (issues.length < 500) issues.add(i);
  }
}

/// Checks every row of [table] with [mapping] into a preview. Rows with a
/// problem are listed (never guessed). [existing] are names already in the
/// branch (folded, per kind for parties): those rows are skipped.
Future<ImportPreview> buildImportPreview(
  ImportTable table,
  ImportTarget target,
  Map<String, String> mapping, {
  String defaultKind = 'customer',
  String defaultCurrency = 'SAR',
  Set<String> existing = const {},
  void Function(int rows)? onRows,
}) async {
  final p = ImportPreview(target, Map.of(mapping));
  final idx = {for (final e in mapping.entries) e.key: table.columns.indexOf(e.value)}..removeWhere((_, v) => v < 0);
  String? at(List<String?> r, String f) {
    final i = idx[f];
    final v = i == null || i >= r.length ? null : r[i]?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  final seen = <String>{};
  await for (final r in table.rows()) {
    final n = ++p.rows;
    if (n % 5000 == 0) onRows?.call(n);
    if (target == ImportTarget.archive) {
      p.archive.add(r);
      continue;
    }
    final name = at(r, 'name');
    if (name == null) {
      p._issue(ImportIssue(n, 'missing_name'));
      continue;
    }
    if (target == ImportTarget.parties) {
      var kind = defaultKind;
      final k = at(r, 'kind');
      if (k != null) {
        final f = importFold(k);
        if (_customerWords.any((w) => f == w || f.contains(w) && w.length > 1)) {
          kind = 'customer';
        } else if (_supplierWords.any((w) => f == w || f.contains(w) && w.length > 1)) {
          kind = 'supplier';
        } else {
          p._issue(ImportIssue(n, 'bad_kind', k));
          continue;
        }
      }
      int amount = 0;
      final bal = at(r, 'balance'), dr = at(r, 'debit'), cr = at(r, 'credit');
      if (bal != null || dr != null || cr != null) {
        int? read(String? v) => v == null ? 0 : importMinor(importDecimal(v));
        final b = read(bal), d = read(dr), c = read(cr);
        if (b == null || d == null || c == null) {
          p._issue(ImportIssue(n, 'bad_number', bal ?? dr ?? cr));
          continue;
        }
        // Debit/credit columns: a customer owes the debit side, a supplier
        // is owed the credit side.
        amount = b + (kind == 'customer' ? d - c : c - d);
      }
      if (amount < 0) {
        p._issue(ImportIssue(n, 'credit_balance', '${amount / 100}'));
        continue;
      }
      final cur = importCurrency(at(r, 'currency'), defaultCurrency);
      if (cur == null) {
        p._issue(ImportIssue(n, 'bad_currency', at(r, 'currency')));
        continue;
      }
      final key = '$kind|${importFold(name)}';
      if (existing.contains(key)) {
        p._issue(ImportIssue(n, 'exists', name));
        continue;
      }
      if (!seen.add(key)) {
        p._issue(ImportIssue(n, 'duplicate_in_file', name));
        continue;
      }
      p.parties.add(PartyImportRow(n, kind, name.length > 120 ? name.substring(0, 120) : name, at(r, 'phone'), amount, cur));
      (p.totals[kind] ??= {})[cur] = ((p.totals[kind]![cur]) ?? 0) + amount;
    } else {
      final sale = at(r, 'sale_price'), cost = at(r, 'cost_price'), stock = at(r, 'stock');
      String? num(String? v) => v == null ? null : importDecimal(v);
      final s = num(sale), c = num(cost), q = num(stock);
      if ((sale != null && s == null) || (cost != null && c == null) || (stock != null && q == null)) {
        p._issue(ImportIssue(n, 'bad_number', sale ?? cost ?? stock));
        continue;
      }
      if ((s?.startsWith('-') ?? false) || (c?.startsWith('-') ?? false) || (q?.startsWith('-') ?? false)) {
        p._issue(ImportIssue(n, 'bad_number', sale ?? cost ?? stock));
        continue;
      }
      if ((s != null && importMinor(s) == null) || (c != null && importMinor(c) == null)) {
        p._issue(ImportIssue(n, 'too_many_decimals', sale ?? cost));
        continue;
      }
      final barcode = at(r, 'barcode');
      final key = 'product|${barcode ?? importFold(name)}';
      if (existing.contains(key) || existing.contains('product|${importFold(name)}')) {
        p._issue(ImportIssue(n, 'exists', name));
        continue;
      }
      if (!seen.add(key) || !seen.add('product-name|${importFold(name)}')) {
        p._issue(ImportIssue(n, 'duplicate_in_file', name));
        continue;
      }
      p.products.add(ProductImportRow(n, name.length > 120 ? name.substring(0, 120) : name, barcode, at(r, 'sku'),
          at(r, 'unit'), s, c, q));
    }
  }
  onRows?.call(p.rows);
  if (p.rows == 0) throw const ImportRejected('empty');
  return p;
}
