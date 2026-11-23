import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/invoices/data/invoice_design_models.dart';
import 'package:fyona_flutter/features/invoices/data/invoice_doc.dart';

void main() {
  group('Return invoices + design defaults', () {
    test('default footer + return titles', () {
      final d = InvoiceDesignPreset.defaults('paper');
      expect(d.footerText, 'نظام فيونا المحاسبي');
      expect(d.titleReturnCustomer, 'مرتجع عميل');
      expect(d.titleReturnSupplier, 'مرتجع مورد');
    });

    test('sale return is detected and titled', () {
      final doc = InvoiceDoc.from({
        'invoice_number': 'RET-1',
        'invoice_type': 'sale_return',
        'customer_name': 'عميل',
        'currency': 'YER_NEW',
        'total': 250,
        'original_invoice': 'INV-9',
        'items': [
          {'description': 'منتج', 'quantity': 2, 'unit_price': 125, 'total': 250},
        ],
      });
      expect(doc.isReturn, isTrue);
      expect(doc.isPurchase, isFalse);
      expect(doc.originalInvoice, 'INV-9');
      expect(doc.title, 'مرتجع عميل');
      expect(doc.titleFor(InvoiceDesignPreset.defaults('return_paper')),
          'مرتجع عميل');
      // currency code resolved to its Arabic name
      expect(doc.currencyName, 'ريال يمني جديد');
      expect(doc.items.length, 1);
    });

    test('purchase return is detected and titled', () {
      final doc = InvoiceDoc.from({
        'invoice_number': 'RET-2',
        'invoice_type': 'purchase_return',
        'supplier_name': 'مورد',
        'currency': 'SAR',
        'total': 100,
        'items': const [],
      });
      expect(doc.isReturn, isTrue);
      expect(doc.isPurchase, isTrue);
      expect(doc.titleFor(InvoiceDesignPreset.defaults('return_thermal')),
          'مرتجع مورد');
    });

    test('normal sale/purchase are not returns', () {
      final sale = InvoiceDoc.from(
          {'invoice_type': 'sale', 'currency': 'SAR', 'items': const []});
      final purchase = InvoiceDoc.from(
          {'invoice_type': 'purchase', 'currency': 'SAR', 'items': const []});
      expect(sale.isReturn, isFalse);
      expect(sale.title, 'فاتورة بيع');
      expect(purchase.isPurchase, isTrue);
      expect(purchase.title, 'فاتورة شراء');
    });
  });
}
