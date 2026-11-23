import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/invoices/data/invoice_labels.dart';

void main() {
  test('InvoiceLabels: full Arabic and English labels', () {
    const ar = InvoiceLabels(true);
    const en = InvoiceLabels(false);
    expect(ar.colProduct, 'المنتج');
    expect(en.colProduct, 'Product');
    expect(ar.colQty, 'الكمية');
    expect(en.colQty, 'Qty');
    expect(ar.paymentMethod, 'طريقة الدفع');
    expect(en.paymentMethod, 'Payment method');
    expect(ar.remaining, 'المتبقي');
    expect(en.remaining, 'Remaining');
    expect(ar.sumBefore, contains('المجموع قبل'));
    expect(en.sumBefore, contains('Subtotal'));
    expect(ar.signature, 'التوقيع');
    expect(en.stamp, 'Stamp');
    expect(en.footer, contains('FYONA'));
    expect(ar.footer, contains('فيونا'));
  });
}
