import 'business_money.dart';

/// Read model for the existing debt widgets. No fetching and no mutation of
/// the originating document/payment rates on a report-currency change.
final class BusinessDebtProjection {
  BusinessDebtProjection(List<Map<String, Object?>> rows) {
    for (final row in rows) {
      final total = row['total_minor'] as int;
      final paid = row['paid_minor'] as int;
      final remaining =
          (row['remaining_minor'] as int?) ?? (total > paid ? total - paid : 0);
      final currency = row['currency'] as String;
      if (remaining > 0) _add(_remaining, currency, remaining);
      if (paid > 0) _add(_paid, currency, paid);
      operations.add({
        'id': row['id'],
        'number': row['number'],
        'date': row['invoice_date'],
        'currency': currency,
        'total': BusinessMoney.display(total),
        'paid': BusinessMoney.display(paid),
        'remaining': BusinessMoney.display(remaining),
        'status': remaining == 0
            ? 'paid'
            : paid == 0
            ? 'open'
            : 'partial',
        'group_id': row['group_id'],
      });
    }
  }

  final operations = <Map<String, dynamic>>[];
  final _remaining = <String, BigInt>{};
  final _paid = <String, BigInt>{};

  /// Oldest first, as used to choose the settlement target when the account
  /// holds a different currency.
  Map<String, double> get settlementBuckets => {
    for (final row in operations.reversed)
      if (row['remaining'] != '0.00')
        row['currency'] as String: double.parse(
          BusinessMoney.displayTotal(_remaining[row['currency']]!),
        ),
  };

  List<Map<String, dynamic>> get perCurrency => [
    for (final c in _remaining.keys.toList()..sort())
      {'currency': c, 'total': BusinessMoney.displayTotal(_remaining[c]!)},
  ];

  Map<String, dynamic> report(
    String currency,
    BusinessRate? Function(String from, String to) rate,
  ) {
    final missing = <String>{};
    BigInt? sum(Map<String, BigInt> amounts) {
      final known = <(BigInt, BusinessRate)>[];
      var complete = true;
      for (final item in amounts.entries) {
        final quote = item.key == currency
            ? BusinessRate(currency, currency, '1')
            : rate(item.key, currency);
        if (quote == null || quote.from != item.key || quote.to != currency) {
          missing.add(item.key);
          complete = false;
        } else {
          known.add((item.value, quote));
        }
      }
      return complete ? BusinessRate.reportTotal(known) : null;
    }

    final total = sum(_remaining);
    final paid = sum(_paid);
    return {
      'display_currency': currency,
      'display_total': total == null ? null : BusinessMoney.displayTotal(total),
      'remaining_total': total == null
          ? null
          : BusinessMoney.displayTotal(total),
      'paid_total': paid == null ? null : BusinessMoney.displayTotal(paid),
      'grand_total': total == null || paid == null
          ? null
          : BusinessMoney.displayTotal(total + paid),
      'fx_missing': missing.toList()..sort(),
      'operations': operations,
      'individual': operations.where((row) => row['group_id'] == null).toList(),
      'per_currency': perCurrency,
    };
  }

  static void _add(Map<String, BigInt> buckets, String currency, int minor) =>
      buckets.update(
        currency,
        (v) => v + BigInt.from(minor),
        ifAbsent: () => BigInt.from(minor),
      );
}
