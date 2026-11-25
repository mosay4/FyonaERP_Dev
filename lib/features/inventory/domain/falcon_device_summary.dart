// The Falcon's deterministic figures, computed on the phone.
//
// A device-ledger branch used to send every product row to the server
// (hundreds of KB, times the branches in «جميع الفروع»). The phone now runs
// the same rules as the server's `falcon_service.device_dataset` and sends
// only this compact summary; the server re-shapes it through whitelists and
// asks the model for the narrative. The summary also gives the page its key
// numbers at once, before the narrative arrives.
import 'package:collection/collection.dart';

const _fields = [
  'stock',
  'min_stock',
  'sell_price',
  'cost_price',
  'sales',
  'qty_sold',
  'cogs',
  'profit',
  'purchases',
  'qty_purchased',
];

const _summed = [
  'stock',
  'min_stock',
  'sales',
  'qty_sold',
  'cogs',
  'profit',
  'purchases',
  'qty_purchased',
];

double _num(Object? v) {
  final d = v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
  return d == null || !d.isFinite ? 0 : d;
}

double _r4(num v) => (v * 10000).roundToDouble() / 10000;

/// Python's round(): halves go to the even neighbour.
int _pyRound(double v) {
  final floor = v.floorToDouble();
  final diff = v - floor;
  if (diff > .5) return floor.toInt() + 1;
  if (diff < .5) return floor.toInt();
  return floor.toInt().isEven ? floor.toInt() : floor.toInt() + 1;
}

String _short(Object? v, int max) {
  final s = '${v ?? ''}';
  return s.length > max ? s.substring(0, max) : s;
}

List<Map<String, dynamic>> _sorted(
  List<Map<String, dynamic>> rows,
  num Function(Map<String, dynamic>) by, {
  bool descending = false,
}) {
  final out = List.of(rows);
  // Stable, like Python's sorted().
  mergeSort(out, compare: (a, b) {
    final c = by(a).compareTo(by(b));
    return descending ? -c : c;
  });
  return out;
}

Map<String, dynamic> _summary(
  List<Map<String, dynamic>> items,
  String rep,
  bool unverified,
) {
  final active = [
    for (final i in items)
      if ((i['qty_sold'] as double) > 0 || (i['stock'] as double) > 0) i,
  ];
  double sum(Iterable<Map<String, dynamic>> rows, double Function(Map) f) =>
      rows.fold(0.0, (a, i) => a + f(i));
  double value(Map i) => (i['cost_price'] as double) * (i['stock'] as double);
  final stagnant = [
    for (final i in active)
      if ((i['qty_sold'] as double) <= 0 && (i['stock'] as double) > 0) i,
  ];
  final reorder = <Map<String, dynamic>>[];
  for (final i in active) {
    final sold = i['qty_sold'] as double, stock = i['stock'] as double;
    final min = i['min_stock'] as double;
    if (sold <= 0 || stock > min) continue;
    final target = (min * 2) > (sold / 6.0) ? min * 2 : sold / 6.0;
    final q = _pyRound(target - stock) < 0 ? 0 : _pyRound(target - stock);
    if (q <= 0) continue;
    reorder.add({
      'name': i['name'],
      'stock': stock,
      'min_stock': min,
      'qty_sold': sold,
      'order_qty': q,
      'order_cost': _r4(q * (i['cost_price'] as double)),
    });
  }
  final total = sum(active, value);
  return {
    'report_currency': rep,
    'unified': false,
    'unverified_fx': unverified,
    'inventory_value': _r4(total),
    'total_sales': _r4(sum(active, (i) => i['sales'] as double)),
    'total_profit': _r4(sum(active, (i) => i['profit'] as double)),
    'total_cogs': _r4(sum(active, (i) => i['cogs'] as double)),
    'products_count': active.length,
    'low_stock': [
      for (final i in active)
        if ((i['stock'] as double) > 0 &&
            (i['stock'] as double) <= (i['min_stock'] as double))
          i['name'],
    ].take(20).toList(),
    'out_of_stock': [
      for (final i in active)
        if ((i['stock'] as double) <= 0) i['name'],
    ].take(20).toList(),
    'top_sellers': _sorted(active, (i) => i['qty_sold'] as double,
            descending: true)
        .take(10)
        .toList(),
    'top_profit': _sorted(active, (i) => i['profit'] as double,
            descending: true)
        .take(10)
        .toList(),
    'bottom_sellers':
        _sorted(active, (i) => i['qty_sold'] as double).take(10).toList(),
    'slow_moving': stagnant.take(15).toList(),
    'weak_margin': [
      for (final i in active)
        if ((i['sales'] as double) > 0 &&
            (i['profit'] as double) / (i['sales'] as double) < 0.1)
          i,
    ].take(15).toList(),
    'reorder': _sorted(reorder, (r) => r['qty_sold'] as double,
            descending: true)
        .take(15)
        .toList(),
    'stagnant_value_share': active.any((i) => (i['stock'] as double) > 0)
        ? _r4(sum(stagnant, value) / (total > 1e-9 ? total : 1e-9))
        : 0.0,
  };
}

Map<String, dynamic> _branchSummary(
  String id,
  String name,
  List<Map<String, dynamic>> items,
) {
  double sum(String key) =>
      items.fold(0.0, (a, i) => a + (i[key] as double));
  return {
    'branch_id': id,
    'branch_name': name,
    'products_count': items.length,
    'stock': sum('stock'),
    'total_sales': sum('sales'),
    'total_profit': sum('profit'),
    'total_cogs': sum('cogs'),
    'total_purchases': sum('purchases'),
    'inventory_value': items.fold(
      0.0,
      (a, i) => a + (i['cost_price'] as double) * (i['stock'] as double),
    ),
    'low_stock': [
      for (final i in items)
        if ((i['stock'] as double) > 0 &&
            (i['stock'] as double) <= (i['min_stock'] as double))
          i['name'],
    ].take(10).toList(),
    'out_of_stock': [
      for (final i in items)
        if ((i['stock'] as double) <= 0) i['name'],
    ].take(10).toList(),
    'top_sellers': _sorted(items, (i) => i['qty_sold'] as double,
            descending: true)
        .take(5)
        .toList(),
  };
}

List<Map<String, dynamic>> _mergeByName(List<Map<String, dynamic>> rows) {
  final merged = <String, Map<String, dynamic>>{};
  for (final row in rows) {
    final key = (row['name'] as String)
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .join(' ');
    final entry = merged[key];
    final value = (row['cost_price'] as double) * (row['stock'] as double);
    if (entry == null) {
      merged[key] = {
        for (final e in row.entries)
          if (e.key != 'branch_id' && e.key != 'branch_name') e.key: e.value,
        '_value': value,
      };
      continue;
    }
    for (final f in _summed) {
      entry[f] = _r4((entry[f] as double) + (row[f] as double));
    }
    entry['_value'] = (entry['_value'] as double) + value;
    if ((entry['sell_price'] as double) == 0) {
      entry['sell_price'] = row['sell_price'];
    }
  }
  return [
    for (final entry in merged.values)
      () {
        final value = entry.remove('_value') as double;
        if ((entry['stock'] as double) > 0) {
          entry['cost_price'] = _r4(value / (entry['stock'] as double));
        }
        return entry;
      }(),
  ];
}

/// The same figures `falcon_service.device_dataset` builds from [items]
/// (the rows `falconFigures` reads), as the `device_summary` to send.
Map<String, dynamic> falconDeviceSummary(
  List<Map<String, dynamic>> items, {
  required String currency,
  required String scope,
  String? refId,
  String? category,
}) {
  final rep = currency.trim().isEmpty ? 'USD' : currency.trim().toUpperCase();
  var clean = <Map<String, dynamic>>[];
  var unverified = false;
  for (final raw in items.take(3000)) {
    final row = <String, dynamic>{
      'id': '${raw['id'] ?? ''}',
      'name': _short(raw['name'], 200),
      'unit': _short(raw['unit'], 40),
      'currency': rep,
      'expiry_date': raw['expiry_date'],
    };
    for (final f in _fields) {
      row[f] = _r4(_num(raw[f]));
    }
    unverified = unverified || raw['fx_incomplete'] == true;
    final branch = raw['branch_id'];
    if (branch is String && branch.isNotEmpty) {
      row['branch_id'] = _short(branch, 64);
      row['branch_name'] = _short(raw['branch_name'] ?? branch, 120);
    }
    clean.add(row);
  }
  final branches = <String, (String, List<Map<String, dynamic>>)>{};
  for (final row in clean) {
    final id = row['branch_id'] as String?;
    if (id == null) continue;
    branches.putIfAbsent(id, () => (row['branch_name'] as String, []));
    branches[id]!.$2.add(row);
  }
  List<Map<String, dynamic>>? summaries;
  if (branches.isNotEmpty) {
    summaries = [
      for (final e in branches.entries) _branchSummary(e.key, e.value.$1, e.value.$2),
    ];
    clean = _mergeByName(clean);
  }
  if (scope == 'product') {
    final p =
        clean.firstWhereOrNull((i) => refId == null || i['id'] == refId) ??
        (branches.isNotEmpty && clean.isNotEmpty ? clean.first : null) ??
        const <String, dynamic>{};
    double f(String key) => _num(p[key]);
    final stock = f('stock'), qty = f('qty_sold');
    final data = <String, dynamic>{
      'report_currency': rep,
      'unified': false,
      'unverified_fx': unverified,
      'name': p['name'] ?? '',
      'unit': p['unit'] ?? '',
      'category_name': _short(category ?? '', 120),
      'total_sales': f('sales'),
      'total_cogs': f('cogs'),
      'total_profit': f('profit'),
      'inventory_value': _r4(f('cost_price') * stock),
      'products_count': p.isEmpty ? 0 : 1,
      'sales_total': f('sales'),
      'purchases_total': f('purchases'),
      'cogs': f('cogs'),
      'profit': f('profit'),
      'sales_quantity': qty,
      'stock': stock,
      'min_stock': f('min_stock'),
      'sell_price': f('sell_price'),
      'cost_price': f('cost_price'),
      'currency': rep,
      'batches': const [],
    };
    if (qty > 0) {
      final target = f('min_stock') * 2 > qty / 6.0 ? f('min_stock') * 2 : qty / 6.0;
      final q = _pyRound(target - stock);
      data['suggested_order_qty'] = q < 0 ? 0 : q;
    }
    if (summaries != null) {
      data['branch_ids'] = branches.keys.toList();
      data['branch_summaries'] = summaries;
    }
    return data;
  }
  final data = _summary(clean, rep, unverified);
  if (summaries != null) {
    data['branch_ids'] = branches.keys.toList();
    data['branch_summaries'] = summaries;
  }
  if (scope == 'category') data['category_name'] = _short(category ?? '', 120);
  return data;
}

/// Chat still sends rows (a named branch is recomputed from its own rows),
/// but only the ones the analysis reads: idle products add nothing.
List<Map<String, dynamic>> falconActiveRows(
  List<Map<String, dynamic>> items,
  String scope,
) => scope == 'product'
    ? items
    : [
        for (final i in items)
          if (_num(i['qty_sold']) > 0 || _num(i['stock']) > 0) i,
      ];
