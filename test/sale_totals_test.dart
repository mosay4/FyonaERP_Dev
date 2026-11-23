import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/sales/domain/sale_totals.dart';

void main() {
  test('line totals + header percentage discount + percentage tax', () {
    final t = calcSaleTotals(
      lines: const [
        (quantity: 2, unitPrice: 100, discount: 10),
        (quantity: 1, unitPrice: 50, discount: 0),
      ],
      discountType: 'percentage',
      discountValue: 10,
      taxType: 'percentage',
      taxRate: 15,
    );
    expect(t['subtotal'], 240);
    expect(t['discount_amount'], 24);
    expect(t['tax_amount'], 32.4);
    expect(t['total'], 248.4);
  });

  test('fixed discount capped at subtotal, no tax', () {
    final t = calcSaleTotals(
      lines: const [(quantity: 1, unitPrice: 50, discount: 0)],
      discountType: 'fixed',
      discountValue: 999,
    );
    expect(t['discount_amount'], 50);
    expect(t['total'], 0);
  });

  test('empty lines total zero', () {
    final t = calcSaleTotals(lines: const []);
    expect(t.values.every((v) => v == 0), isTrue);
  });

  test('parseMoney accepts num and numeric strings', () {
    expect(parseMoney(10.5), 10.5);
    expect(parseMoney('10.00'), 10.0);
    expect(parseMoney(null), 0);
    expect(parseMoney('junk'), 0);
  });
}
