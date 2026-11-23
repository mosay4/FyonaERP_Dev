import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/invoices/data/invoice_design_models.dart';
import 'package:fyona_flutter/features/invoices/presentation/pdf/invoice_pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> invoiceWith(int n) {
    final items = <Map<String, dynamic>>[];
    var total = 0.0;
    for (var i = 0; i < n; i++) {
      final qty = i + 1;
      final price = 10.5 + i;
      final line = qty * price;
      total += line;
      items.add({
        'description': 'منتج رقم ${i + 1}',
        'quantity': qty,
        'unit_name': 'قطعة',
        'unit_price': price,
        'discount': 0,
        'total': line,
      });
    }
    return {
      'invoice_number': 'INV-2026-$n',
      'invoice_type': 'sale',
      'customer_name': 'عميل تجريبي',
      'customer_phone': '777000000',
      'invoice_date': '2026/10/08',
      'branch_name': 'الفرع الرئيسي',
      'currency': 'YER_NEW',
      'subtotal': total,
      'discount_amount': 0,
      'tax_amount': 0,
      'total': total,
      'paid_amount': total,
      'balance': 0,
      'notes': 'ملاحظة',
      'items': items,
    };
  }

  test('builds 5/50/100 products across all templates', () async {
    for (final n in [5, 50, 100]) {
      for (final t in ['thermal58', 'thermal', 'paper']) {
        final bytes = await buildInvoicePdf(
          invoiceWith(n),
          InvoiceDesignPreset.defaults(t),
          templateId: t,
          isPurchase: false,
        );
        File('/tmp/matrix_${t}_$n.pdf').writeAsBytesSync(bytes);
        expect(bytes.length, greaterThan(2000), reason: '$t $n');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
