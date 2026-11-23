/// Pure sale-totals math (no Flutter imports → unit-testable).
///
/// Mirrors the backend formula exactly:
/// line = qty × price − discount; subtotal = Σ lines;
/// header discount (percentage|fixed, capped at subtotal);
/// header tax on (subtotal − discount); total = after-discount + tax.
Map<String, double> calcSaleTotals({
  required List<({double quantity, double unitPrice, double discount})> lines,
  String? discountType,
  double discountValue = 0,
  String? taxType,
  double taxRate = 0,
}) {
  double round2(double v) => (v * 100).round() / 100;
  var subtotal = 0.0;
  for (final ln in lines) {
    subtotal += ln.quantity * ln.unitPrice - ln.discount;
  }
  var discountAmount = 0.0;
  if (discountType == 'percentage') {
    discountAmount = subtotal * discountValue / 100;
  } else if (discountType == 'fixed') {
    discountAmount = discountValue;
  }
  if (discountAmount > subtotal) discountAmount = subtotal;
  final afterDiscount = subtotal - discountAmount;
  var taxAmount = 0.0;
  if (taxType == 'percentage') {
    taxAmount = afterDiscount * taxRate / 100;
  } else if (taxType == 'fixed') {
    taxAmount = taxRate;
  }
  final total = afterDiscount + taxAmount;
  return {
    'subtotal': round2(subtotal),
    'discount_amount': round2(discountAmount),
    'tax_amount': round2(taxAmount),
    'total': round2(total),
  };
}

/// Parse a backend money value that may arrive as num or numeric String
/// (legacy invoice endpoints serialize Decimals as strings).
double parseMoney(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}
