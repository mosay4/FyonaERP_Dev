/// Pure layout/wording rules for the R1 reconciliation PDF — unit-testable
/// without rendering.
import '../../../../core/utils/currency_formatter.dart';

/// Per-unit row for a multi-unit product (derived truthful values).
class ReconUnitRow {
  final String unit;
  final String before;
  final String after;
  final String diff;
  const ReconUnitRow(this.unit, this.before, this.after, this.diff);
}

/// One unit sub-row inside an equalization confirmation group.
class EqualizeUnitRow {
  final String label; // unit name (empty for a single bank currency row)
  final String before;
  final String after;
  const EqualizeUnitRow(this.label, this.before, this.after);
}

/// One group in the equalization confirmation sheet. For a bank/cash currency
/// it holds a single unit row; for a multi-unit product it holds one row per
/// unit so EVERY unit is visible (never only the base unit).
class EqualizeEntry {
  final String name; // currency (bank) or product name (inventory)
  final String? type; // account type (bank only) → colored badge
  final List<EqualizeUnitRow> rows;
  const EqualizeEntry({required this.name, this.type, required this.rows});
}

/// Lightweight data carrier for expanded product rows.
class ReconResultRowData {
  final String name;
  final String? mark;
  final String? markColorKey;
  final num system;
  final num actual;
  final num diff;
  final String? unit;
  const ReconResultRowData(
      {required this.name,
      this.mark,
      this.markColorKey,
      required this.system,
      required this.actual,
      required this.diff,
      this.unit});
}

/// Expands a product line with multi-unit parts into SEPARATE row data
/// entries — one per unit — each with the product name + unit in parentheses
/// and its own system/actual/diff values. Products with a single unit (or no
/// parts) produce ONE entry as before.
List<ReconResultRowData> expandProductRows({
  required String name,
  required String? mark,
  required String? markColorKey,
  required num systemQty,
  required num actualQty,
  required num diff,
  required String unit,
  required List<dynamic> parts,
  List<dynamic>? serverRows,
}) {
  final unitRowsList = ReconPdfLayout.unitRows(
      systemQty: systemQty,
      baseAfter: actualQty,
      parts: parts,
      serverRows: serverRows);
  if (unitRowsList.length <= 1) {
    return [
      ReconResultRowData(
          name: name,
          mark: mark,
          markColorKey: markColorKey,
          system: systemQty,
          actual: actualQty,
          diff: diff,
          unit: unit),
    ];
  }
  return [
    for (final ur in unitRowsList)
      ReconResultRowData(
          name: '$name (${ur.unit})',
          // The REAL per-unit name travels in the row so the number cells are
          // labelled with the correct unit — never the product's base unit.
          mark: null,
          markColorKey: null,
          system: num.tryParse(ur.before.replaceAll(',', '')) ?? 0,
          actual: num.tryParse(ur.after.replaceAll(',', '')) ?? 0,
          diff: num.tryParse(ur.diff.replaceAll(',', '')) ?? 0,
          unit: ur.unit),
  ];
}

class ReconPdfLayout {
  /// Column order per language: Arabic reads RIGHT→LEFT so العملة must be the
  /// RIGHTMOST column; English reads LEFT→RIGHT.
  static List<String> columnOrder({required bool isAr, required bool isBank}) {
    final first = isAr
        ? (isBank ? 'العملة' : 'المنتج')
        : (isBank ? 'Currency' : 'Product');
    final sys = isAr ? 'بالنظام' : 'In system';
    final act = isAr ? 'بالحقيقة' : 'In reality';
    final dif = isAr ? 'الفرق' : 'Difference';
    // Children order in a pw.Row: first child = LEFTMOST.
    return isAr ? [dif, act, sys, first] : [first, sys, act, dif];
  }

  /// Null-safe stringifier — a literal «null» in the PDF came from
  /// string-interpolating nullable values; every dynamic value goes here.
  static String s(dynamic v) {
    if (v == null) return '';
    final t = '$v'.trim();
    return (t.isEmpty || t.toLowerCase() == 'null') ? '' : t;
  }

  static String fmtNum(num? v) {
    if (v == null) return '0';
    final d = v.toDouble();
    final str = d == d.roundToDouble()
        ? d.toInt().toString()
        : d.toStringAsFixed(2);
    final neg = str.startsWith('-');
    final body = neg ? str.substring(1) : str;
    final parts = body.split('.');
    final intPart =
        parts[0].replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
    final out = parts.length > 1 ? '$intPart.${parts[1]}' : intPart;
    return neg ? '-$out' : out;
  }

  /// Currency/product display name (full, never clipped — the cell wraps).
  static String displayName({
    required bool isBank,
    required bool isAr,
    required String? currency,
    required String? name,
  }) {
    if (!isBank) return s(name);
    final code = s(currency);
    return localizedCurrencyName(code, locale: isAr ? 'ar' : 'en') ?? code;
  }

  /// Multi-unit breakdown: «2 كرتون + 1 قطعة» (only when >1 unit used).
  static List<String> partsList(List<dynamic> parts) => [
        for (final p in parts.whereType<Map>())
          if (((p['qty'] as num?) ?? 0) > 0)
            '${fmtNum(p['qty'])} ${s(p['unit_name'])}'.trim()
      ];

  static String partsText(List<dynamic> parts) {
    final list = partsList(parts);
    return list.length > 1 ? list.join(' + ') : '';
  }

  /// The saved unit name with any redundant «(×8)» suffix stripped, so it can
  /// be shown next to the product without ugly double parentheses.
  static String cleanUnitName(String raw) {
    final t = s(raw);
    return t
        .replaceAll(RegExp(r'\s*[\(（][^)）]*[\)）]\s*$'), '')
        .trim();
  }

  /// Display label of a unit: its real saved name + the conversion factor
  /// («باكيت ×8»); the base unit (factor 1) shows just its name.
  static String unitLabel(String raw, num factor) {
    final base = cleanUnitName(raw);
    final f = factor.toDouble();
    if (f > 1) {
      final ftxt = f == f.roundToDouble()
          ? f.toInt().toString()
          : f.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '');
      return base.isEmpty ? '×$ftxt' : '$base ×$ftxt';
    }
    return base;
  }

  /// Per-unit rows for a multi-unit product. When the server provides
  /// `unit_rows` (ONE consistent table derived from the single base total),
  /// those are used verbatim; otherwise they are derived from the entered
  /// `parts` (display-only per-unit views; the base totals stay the truth).
  static List<ReconUnitRow> unitRows({
    required num systemQty,
    required num baseAfter,
    required List<dynamic> parts,
    List<dynamic>? serverRows,
  }) {
    if (serverRows != null && serverRows.isNotEmpty) {
      return [
        for (final r in serverRows.whereType<Map>())
          ReconUnitRow(
            unitLabel(s(r['unit_name']), (r['factor'] as num?) ?? 1),
            '${r['system'] ?? ''}',
            '${r['actual'] ?? ''}',
            '${r['diff'] ?? ''}',
          ),
      ];
    }
    final out = <ReconUnitRow>[];
    for (final p in parts.whereType<Map>()) {
      final f = ((p['factor'] as num?) ?? 1).toDouble();
      if (f <= 0) continue;
      final rawName = s(p['unit_name']);
      if (rawName.isEmpty && f <= 1) continue;
      final label = unitLabel(rawName, f);
      final entered = ((p['qty'] as num?) ?? 0).toDouble();
      final systemInUnit = systemQty / f;
      out.add(ReconUnitRow(label, _trim(systemInUnit), _trim(entered),
          _trim(entered - systemInUnit)));
    }
    return out;
  }

  static String _trim(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '');
  }

  /// The account type of a bank/cash settlement, resolved from the record's
  /// own lines. Match by ACCOUNT ID first (two settlements may share the same
  /// name+currency — «جيب» USD جاري and USD توفير — so name+currency would
  /// wrongly return the first type twice); fall back to name+currency only
  /// when the settlement carries no id.
  static String? settlementAccountType(
      Map settlement, List<Map> lines) {
    final sid = s(settlement['account_id']);
    final cur = s(settlement['currency']).toUpperCase();
    final nm = s(settlement['name']);
    for (final l in lines) {
      if (sid.isNotEmpty) {
        if (s(l['account_id']) == sid) {
          final t = s(l['account_type']);
          return t.isEmpty ? 'checking' : t;
        }
      } else if (s(l['currency']).toUpperCase() == cur &&
          s(l['name']) == nm) {
        final t = s(l['account_type']);
        return t.isEmpty ? 'checking' : t;
      }
    }
    return null;
  }

  /// Account-type wording (green = savings / blue = checking). [short] gives a
  /// compact badge label («جاري» / «توفير») that never clips long currencies.
  static String accountTypeLabelStr(String? type,
      {required bool isAr, bool short = false}) {
    final savings = (type ?? '') == 'savings';
    if (short) {
      return savings
          ? (isAr ? 'توفير' : 'Savings')
          : (isAr ? 'جاري' : 'Checking');
    }
    return savings
        ? (isAr ? 'حساب توفير' : 'Savings account')
        : (isAr ? 'حساب جاري' : 'Checking account');
  }

  /// The set of currencies that appear with MORE THAN ONE account type in the
  /// given rows. Only those currencies deserve a «جاري/توفير» badge — a
  /// currency that exists with a single type must show no badge at all.
  static Set<String> currenciesWithMultipleTypes(
    Iterable<Map> rows, {
    String currencyKey = 'currency',
    String typeKey = 'account_type',
  }) {
    final types = <String, Set<String>>{};
    for (final r in rows) {
      final cur = s(r[currencyKey]).toUpperCase();
      if (cur.isEmpty) continue;
      final raw = s(r[typeKey]);
      final t = raw.isEmpty ? 'checking' : raw;
      types.putIfAbsent(cur, () => <String>{}).add(t);
    }
    return {
      for (final e in types.entries)
        if (e.value.length > 1) e.key
    };
  }
}