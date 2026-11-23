/// Currency-safe money helpers for Sara reads.
///
/// HARD RULE: amounts in different currencies must NEVER be added together.
/// Every financial figure Sara reports is grouped by its real currency id
/// (the canonical uppercase code — `YER` and `YER_NEW` stay distinct).
/// A unified total exists ONLY as an explicit per-currency breakdown, or as
/// a converted total produced by the real exchange-rate engine (never 1.0,
/// never invented).
library sara_money;

import 'package:fyona_flutter/core/utils/currency_formatter.dart';

/// Canonical currency id: trimmed uppercase code. No merging, no aliases.
String saraCurrencyId(String? code) => (code ?? '').trim().toUpperCase();

/// One currency bucket: id + display code + summed amount.
class SaraMoneyLine {
  final String currencyId;
  final String currencyCode;
  final double amount;
  const SaraMoneyLine({
    required this.currencyId,
    required this.currencyCode,
    required this.amount,
  });

  Map<String, dynamic> toJson() => {
        'currency_id': currencyId,
        'currency': currencyCode,
        'amount': amount,
      };
}

/// Groups amounts by real currency id. Same code accumulates; different
/// codes NEVER merge. Sorted by code for stable output.
Map<String, double> groupAmounts<T>(
  Iterable<T> rows,
  double Function(T) amountOf,
  String Function(T) currencyOf,
) {
  final out = <String, double>{};
  for (final r in rows) {
    final id = saraCurrencyId(currencyOf(r));
    final key = id.isEmpty ? 'UNKNOWN' : id;
    out[key] = (out[key] ?? 0) + amountOf(r);
  }
  final sorted = Map.fromEntries(
    out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
  );
  return sorted;
}

/// Renders grouped totals, one line per currency. When exactly one currency
/// exists the single line doubles as the total (with its code attached).
/// Multi-currency output NEVER contains a unified number.
String formatBreakdown(Map<String, double> totals, {required bool arabic}) {
  if (totals.isEmpty) return arabic ? 'لا توجد مبالغ.' : 'No amounts.';
  final lines = totals.entries
      .map((e) => '${e.key}: ${fmtNum(e.value)}')
      .join('\n');
  if (totals.length == 1) return lines;
  return arabic ? 'حسب العملة (بدون جمع):\n$lines' : 'By currency (not summed):\n$lines';
}

/// Result of converting grouped totals into one target currency using ONLY
/// real engine rates. [missing] lists codes with no valid rate — the caller
/// must state unavailability instead of showing a wrong number.
class SaraConvertedTotal {
  final String targetCurrency;
  final double total;
  final List<String> missing;
  const SaraConvertedTotal({
    required this.targetCurrency,
    required this.total,
    required this.missing,
  });
}

/// Converts every bucket with [rateOf]. Buckets without a valid rate (> 0)
/// land in [missing] and are EXCLUDED from [total] — the caller must state
/// their unavailability instead of presenting a partial number as complete.
SaraConvertedTotal convertBuckets(
  Map<String, double> totals,
  String targetCurrency,
  double? Function(String from, String to) rateOf,
) {
  final target = saraCurrencyId(targetCurrency);
  double total = 0;
  final missing = <String>[];
  for (final e in totals.entries) {
    if (e.key == target) {
      total += e.value;
      continue;
    }
    double? rate;
    try {
      rate = rateOf(e.key, target);
    } catch (_) {
      rate = null;
    }
    if (rate == null || rate <= 0) {
      missing.add(e.key);
      continue;
    }
    total += e.value * rate;
  }
  return SaraConvertedTotal(
      targetCurrency: target, total: total, missing: missing);
}
