import 'business_money.dart';

/// An approved publication, not a quote invented at report time. An undated
/// publication can value current balances, but cannot document a past rate.
typedef BusinessFxObservation = (
  String base,
  String currency,
  String? rate,
  int? at,
);

/// An immutable view of the saved publication history for a single read.
/// Values are decimal ratios; the caller chooses the accumulator's scale.
final class BusinessReportFx {
  const BusinessReportFx.empty() : _history = const {};

  BusinessReportFx(Iterable<BusinessFxObservation> observations)
    : _history = {} {
    for (final (base, currency, value, at) in observations) {
      final rate = _ReportRate.parse(value);
      (_history[(base, currency)] ??= []).add((at, rate));
    }
  }

  final Map<(String, String), List<(int?, _ReportRate?)>> _history;

  BigInt? convert(
    BigInt amount,
    String from,
    String to, {
    int? operationUs,
    BusinessRate? frozen,
  }) {
    // The whole app names the Aden rial «YER» (shown as «ريال يمني جديد»,
    // and the currency engine values it as YER_NEW): reports do the same.
    if (from == 'YER') from = 'YER_NEW';
    if (to == 'YER') to = 'YER_NEW';
    if (amount == BigInt.zero || from == to) return amount;
    if (frozen != null) {
      if (frozen.from == from && frozen.to == to) {
        return frozen.convertScaled(amount);
      }
      if (frozen.to == from) {
        return convert(
          frozen.originalScaled(amount),
          frozen.from,
          to,
          operationUs: operationUs,
        );
      }
    }
    final rate =
        _at(from, to, operationUs) ?? _at(to, from, operationUs)?.inverse;
    if (rate != null) return rate.apply(amount);
    final source = _at('USD', from, operationUs);
    final target = _at('USD', to, operationUs);
    return source != null && target != null
        ? BusinessMoney.roundRatio(
            amount * target.n * source.d,
            target.d * source.n,
          )
        : null;
  }

  _ReportRate? _at(String base, String currency, int? at) {
    if (base == currency) return _ReportRate(BigInt.one, BigInt.one);
    final rows = _history[(base, currency)];
    if (rows == null) return null;
    // A null rate is a withdrawn quote and is honoured as such.
    if (at == null) return rows.last.$2;
    // Prefer the last approved observation at or before the operation. When
    // the operation predates every saved observation (e.g. recorded offline
    // before the first rate was received), use the earliest dated approval,
    // then the latest one — the report must always value every amount in the
    // currency the merchant chose.
    for (final (observed, rate) in rows.reversed) {
      if (observed != null && observed <= at) return rate;
    }
    for (final (observed, rate) in rows) {
      if (observed != null) return rate;
    }
    return rows.last.$2;
  }

  static bool validDecimal(String? value) => _ReportRate.parse(value) != null;
}

final class _ReportRate {
  const _ReportRate(this.n, this.d);
  final BigInt n, d;

  static final _decimal = RegExp(r'^(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$');

  static _ReportRate? parse(String? value) {
    if (value == null || value.length > 45) return null;
    final match = _decimal.firstMatch(value);
    if (match == null) return null;
    final fraction = match[2] ?? '';
    final exponent = (int.tryParse(match[3] ?? '') ?? 0) - fraction.length;
    if (exponent.abs() > 40) return null;
    final digits = BigInt.parse('${match[1]}$fraction');
    if (digits == BigInt.zero) return null;
    final scale = BigInt.from(10).pow(exponent.abs());
    return exponent < 0
        ? _ReportRate(digits, scale)
        : _ReportRate(digits * scale, BigInt.one);
  }

  _ReportRate get inverse => _ReportRate(d, n);
  BigInt apply(BigInt amount) => BusinessMoney.roundRatio(amount * n, d);
}
