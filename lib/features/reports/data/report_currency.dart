import '../../core_business/data/local_ledger/business_money.dart';
import '../../core_business/data/local_ledger/business_report_fx.dart';

/// Amount fields that a device report row may carry next to its `currency`.
const _amountKeys = {
  'total',
  'paid',
  'balance',
  'amount',
  'before',
  'after',
  'inflow',
  'outflow',
  'transfers',
  'settlements',
  'value',
};

final _decimal = RegExp(r'^(-?)(\d+)\.(\d{2})$');

/// Re-expresses every row of a device report in the report currency the
/// merchant chose, so that a currency switch changes the whole report (cards,
/// lists, and the PDF that is generated from the same data).
///
/// Section totals are already valued by the ledger with the operation's own
/// rate; this only converts the detail rows that were still recorded in their
/// original currency. Dated rows use the rate of their date; undated rows
/// (current balances) use the latest saved rate. A row whose rate is not
/// available on the device is left as recorded.
Map<String, dynamic> convertReportRows(
  Map<String, dynamic> report,
  BusinessReportFx fx,
) {
  final target = report['currency'];
  if (target is! String) return report;
  return {
    for (final entry in report.entries)
      entry.key: entry.key == 'currency'
          ? entry.value
          : _walk(entry.value, target, fx),
  };
}

Object? _walk(Object? node, String target, BusinessReportFx fx) {
  if (node is List) {
    final items = [for (final item in node) _walk(item, target, fx)];
    return _mergeAmounts(items, target) ?? items;
  }
  if (node is! Map) return node;
  final converted = <String, dynamic>{
    for (final entry in node.entries)
      '${entry.key}': _walk(entry.value, target, fx),
  };
  final code = converted['currency'];
  if (code is! String || code == target) return converted;
  final keys = [
    for (final key in _amountKeys)
      if (converted[key] is String && _decimal.hasMatch(converted[key]))
        key,
  ];
  if (keys.isEmpty) return converted;
  final at = _operationUs(converted['date'] ?? converted['approved_at']);
  final values = <String, String>{};
  for (final key in keys) {
    final minor = _minor(converted[key] as String);
    final value = fx.convert(minor, code, target, operationUs: at);
    if (value == null) return converted; // keep the row as recorded
    values[key] = BusinessMoney.displayTotal(value);
  }
  return {
    ...converted,
    ...values,
    'currency': target,
    'original_currency': code,
    for (final key in keys) 'original_$key': converted[key],
  };
}

/// `[{currency, total}, …]` lists (per-currency breakdowns) collapse into one
/// entry once every part is in the report currency.
List<Map<String, dynamic>>? _mergeAmounts(List items, String target) {
  if (items.length < 2) return null;
  var sum = BigInt.zero;
  for (final item in items) {
    if (item is! Map ||
        item['currency'] != target ||
        item['total'] is! String ||
        !_decimal.hasMatch(item['total'] as String) ||
        item.keys.any(
          (key) =>
              key != 'currency' &&
              key != 'total' &&
              key != 'original_currency' &&
              key != 'original_total',
        )) {
      return null;
    }
    sum += _minor(item['total'] as String);
  }
  return [
    {'currency': target, 'total': BusinessMoney.displayTotal(sum)},
  ];
}

BigInt _minor(String value) {
  final match = _decimal.firstMatch(value)!;
  final minor = BigInt.parse('${match[2]}${match[3]}');
  return match[1] == '-' ? -minor : minor;
}

int? _operationUs(Object? value) {
  if (value is! String) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  if (value.length == 10) {
    // A business day: value it at the end of that day.
    return DateTime(
          parsed.year,
          parsed.month,
          parsed.day + 1,
        ).microsecondsSinceEpoch -
        1;
  }
  return parsed.microsecondsSinceEpoch;
}
