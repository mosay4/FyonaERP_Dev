import '../../../core/utils/currency_formatter.dart' as cf;

/// Localized labels for the invoice document (A4 preview + PDF + thermal).
///
/// Arabic when the app language is Arabic, English otherwise — so the WHOLE
/// invoice (labels, headers, totals, payment box, QR/notes, footer) follows the
/// selected language instead of a hardcoded Arabic text.
class InvoiceLabels {
  final bool ar;
  const InvoiceLabels(this.ar);

  factory InvoiceLabels.current() => InvoiceLabels(cf.appLocale == 'ar');

  String get customerInfo => ar ? 'بيانات العميل' : 'Customer';
  String get supplierInfo => ar ? 'بيانات المورد' : 'Supplier';
  String get invoiceInfo => ar ? 'معلومات الفاتورة' : 'Invoice info';
  String get storeInfo => ar ? 'معلومات المتجر' : 'Store info';
  String get date => ar ? 'التاريخ' : 'Date';
  String get time => ar ? 'الوقت' : 'Time';
  String get branch => ar ? 'الفرع' : 'Branch';
  String get cashier => ar ? 'الكاشير' : 'Cashier';
  String get merchant => ar ? 'التاجر' : 'Merchant';

  /// «التاجر» when the account owner executed the document, «الكاشير» for
  /// an employee (and for documents whose role is unknown).
  String cashierFor(String role) => role == 'owner' ? merchant : cashier;
  String get originalInvoice => ar ? 'الفاتورة الأصلية' : 'Original invoice';

  String get colNum => '#';
  String get colProduct => ar ? 'المنتج' : 'Product';
  String get colQty => ar ? 'الكمية' : 'Qty';
  String get colUnitPrice => ar ? 'سعر الوحدة' : 'Unit price';
  String get colDiscount => ar ? 'الخصم' : 'Discount';
  String get colTotal => ar ? 'الإجمالي' : 'Total';

  String get sumBefore =>
      ar ? 'المجموع قبل الخصم والضريبة' : 'Subtotal (before discount/tax)';
  String get discount => ar ? 'إجمالي الخصم' : 'Discount';
  String get tax => ar ? 'الضريبة' : 'Tax';
  String get grandTotal => ar ? 'الإجمالي' : 'Total';
  String get returnValue => ar ? 'قيمة المرتجع' : 'Return value';

  String get paymentMethod => ar ? 'طريقة الدفع' : 'Payment method';
  String get paid => ar ? 'المبلغ المدفوع' : 'Paid';
  String get remaining => ar ? 'المتبقي' : 'Remaining';
  String get payment => ar ? 'دفعة' : 'Payment';
  String get returnDetails => ar ? 'تفاصيل المرتجع' : 'Return details';
  String get reason => ar ? 'السبب' : 'Reason';

  String get viewInvoice => ar ? 'عرض الفاتورة' : 'View invoice';
  String get scanHint =>
      ar ? 'امسح الرمز لعرضها والتحقق منها.' : 'Scan to view and verify.';
  String get notes => ar ? 'ملاحظات' : 'Notes';
  String get signature => ar ? 'التوقيع' : 'Signature';
  String get stamp => ar ? 'الختم' : 'Stamp';
  String get thanks => ar
      ? 'شكراً لتعاملك معنا. يمكن تخصيص سياسة الاسترجاع أو أي ملاحظة خاصة بالفاتورة.'
      : 'Thank you for your business. You can customise the return policy or any note here.';
  String get footer => ar ? 'نظام فيونا المحاسبي' : 'FYONA Accounting System';
}
