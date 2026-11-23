/// The current Business documents and bank balances use NUMERIC(12, 2).
/// SQLite stores integer minor units; doubles are only used for rendering.
abstract final class BusinessMoney {
  static const maxMinor = 999999999999;
  static final _maxMinorBig = BigInt.from(maxMinor);

  static int minor(String decimal, {bool halfEven = false}) {
    final (digits, divisor) = _decimal(decimal);
    return _checked(
      _round(digits * BigInt.from(100), divisor, halfEven: halfEven),
    );
  }

  static int checked(int minor) => _checked(BigInt.from(minor));

  static BigInt roundRatio(BigInt numerator, BigInt denominator) =>
      _round(numerator, denominator, halfEven: true);

  /// The connected return contract prorates the line discount, then rounds
  /// that line to cents before it reduces the debt or refunds the excess.
  static int returnLineMinor({
    required int quantityMicro,
    required int soldMicro,
    required int unitMinor,
    required int discountMinor,
  }) {
    final scale = BigInt.from(1000000);
    final sold = BigInt.from(soldMicro);
    return _checked(
      _round(
        BigInt.from(quantityMicro) *
            (BigInt.from(unitMinor) * sold -
                BigInt.from(discountMinor) * scale),
        scale * sold,
        halfEven: true,
      ),
    );
  }

  static String display(int minor) => displayTotal(BigInt.from(minor));

  static String displayTotal(BigInt minor) {
    final magnitude = minor.abs();
    final scale = BigInt.from(100);
    return '${minor.isNegative ? '-' : ''}${magnitude ~/ scale}.'
        '${(magnitude % scale).toString().padLeft(2, '0')}';
  }

  static int _checked(BigInt amount) {
    if (amount.abs() > _maxMinorBig) {
      throw const FormatException('Business amount is out of range');
    }
    return amount.toInt();
  }
}

/// An opening debt is one service line. Retain the exact quantity and apply
/// the invoice engine's cent rounding without converting inputs to doubles.
final class BusinessOpeningDebtLine {
  factory BusinessOpeningDebtLine(String quantity, String unitPrice) {
    final (units, scale) = _decimal(quantity);
    final (price, _) = _decimal(unitPrice);
    if (units <= BigInt.zero ||
        units > BigInt.from(999999999999) * scale ||
        price.isNegative) {
      throw const FormatException('Invalid opening debt line');
    }
    final unitMinor = BusinessMoney.minor(unitPrice, halfEven: true);
    final fraction = (units % scale)
        .toString()
        .padLeft(scale.toString().length - 1, '0')
        .replaceFirst(RegExp(r'0+$'), '');
    return BusinessOpeningDebtLine._(
      '${units ~/ scale}${fraction.isEmpty ? '' : '.$fraction'}',
      unitMinor,
      BusinessMoney._checked(
        _round(units * BigInt.from(unitMinor), scale, halfEven: true),
      ),
    );
  }

  const BusinessOpeningDebtLine._(
    this.quantity,
    this.unitMinor,
    this.totalMinor,
  );

  final String quantity;
  final int unitMinor;
  final int totalMinor;
}

/// A frozen quote: one unit of [from] equals [decimal] units of [to].
/// Eight decimal places match Business's persisted settlement rate.
final class BusinessRate {
  factory BusinessRate(String from, String to, String decimal) {
    final source = businessCurrency(from);
    final target = businessCurrency(to);
    final (digits, divisor) = _decimal(decimal);
    final units = _round(digits * _scale, divisor);
    if (units <= BigInt.zero ||
        units >= _limit ||
        (source == target && units != _scale)) {
      throw const FormatException('Invalid Business exchange rate');
    }
    return BusinessRate._(source, target, units);
  }

  BusinessRate._(this.from, this.to, this._units);

  static final _scale = BigInt.from(100000000);
  static final _limit = BigInt.from(1000000000) * BigInt.from(1000000000);
  final String from;
  final String to;
  final BigInt _units;

  String get decimal =>
      '${_units ~/ _scale}.${(_units % _scale).toString().padLeft(8, '0')}';

  int convert(int minor, {bool halfEven = true}) => BusinessMoney._checked(
    _round(BigInt.from(minor) * _units, _scale, halfEven: halfEven),
  );

  int original(int equivalentMinor) => BusinessMoney._checked(
    _round(BigInt.from(equivalentMinor) * _scale, _units, halfEven: true),
  );

  // Reporting composes scaled totals before the final cent rounding.
  BigInt convertScaled(BigInt value) =>
      BusinessMoney.roundRatio(value * _units, _scale);
  BigInt originalScaled(BigInt value) =>
      BusinessMoney.roundRatio(value * _scale, _units);

  /// Display sums combine currency buckets before rounding (the report's
  /// rounding policy differs from settlement).
  static BigInt reportTotal(Iterable<(BigInt, BusinessRate)> buckets) {
    var units = BigInt.zero;
    for (final (minor, quote) in buckets) {
      units += minor * quote._units;
    }
    return _round(units, _scale);
  }
}

String businessCurrency(String value) {
  final code = value.trim().toUpperCase();
  if (!RegExp(r'^[A-Z]{3}(?:_[A-Z]{3})?$').hasMatch(code)) {
    throw const FormatException('Invalid Business currency');
  }
  return code;
}

(BigInt, BigInt) _decimal(String value) {
  final clean = value.trim();
  final match = RegExp(r'^([+-]?)(\d*)(?:\.(\d*))?$').firstMatch(clean);
  if (match == null ||
      clean.length > 36 ||
      (match[2]!.isEmpty && (match[3] ?? '').isEmpty)) {
    throw const FormatException('Invalid Business decimal');
  }
  final fraction = match[3] ?? '';
  return (
    BigInt.parse('${match[1]}${match[2]}$fraction'),
    BigInt.from(10).pow(fraction.length),
  );
}

BigInt _round(BigInt numerator, BigInt divisor, {bool halfEven = false}) {
  final abs = numerator.abs();
  final whole = abs ~/ divisor;
  final twiceRemainder = (abs % divisor) * BigInt.two;
  final up =
      twiceRemainder > divisor ||
      (twiceRemainder == divisor && (!halfEven || whole.isOdd));
  return (up ? whole + BigInt.one : whole) * BigInt.from(numerator.sign);
}
