import '../../../core/utils/currency_formatter.dart' as cf;
import 'invoice_design_models.dart';
import 'package:fyona_flutter/core/utils/document_number.dart';

/// A single normalized invoice representation consumed by BOTH the on-screen
/// preview and the PDF/share/print builders, so every method shows exactly the
/// same products, quantities, prices and payment details.
class InvoiceDoc {
  final String number;
  final String type; // 'sale' | 'purchase'
  final String dateRaw;
  final DateTime? date;
  final String branch;
  final String partyName;
  final String partyPhone;
  final String currencyCode;
  final String currencyName;
  final double subtotal;
  final double discount;
  final double tax;
  final double total;
  final double paid;
  final double balance;
  final String notes;
  final String cashier;
  /// 'owner' (the merchant) | 'employee' (a cashier) | '' (unknown/legacy).
  final String cashierRole;
  final String status;
  final String originalInvoice;
  final bool isReturn;
  final List<InvoiceDocItem> items;
  final List<InvoiceDocPayment> payments;

  const InvoiceDoc({
    required this.number,
    required this.type,
    required this.dateRaw,
    required this.date,
    required this.branch,
    required this.partyName,
    required this.partyPhone,
    required this.currencyCode,
    required this.currencyName,
    required this.subtotal,
    required this.discount,
    required this.tax,
    required this.total,
    required this.paid,
    required this.balance,
    required this.notes,
    required this.cashier,
    this.cashierRole = '',
    required this.status,
    this.originalInvoice = '',
    this.isReturn = false,
    required this.items,
    required this.payments,
  });

  bool get isPurchase => type == 'purchase' || type == 'purchase_return';

  String titleFor(InvoiceDesignPreset d) {
    if (type == 'sale_return') return d.titleReturnCustomer;
    if (type == 'purchase_return') return d.titleReturnSupplier;
    if (type == 'purchase') return d.titlePurchase;
    return d.titleSale;
  }

  String get title {
    if (type == 'sale_return') return 'مرتجع عميل';
    if (type == 'purchase_return') return 'مرتجع مورد';
    if (type == 'purchase') return 'فاتورة شراء';
    return 'فاتورة بيع';
  }

  static double _n(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.replaceAll(',', '')) ?? 0;
    return 0;
  }

  static String _s(dynamic v) => (v ?? '').toString();

  factory InvoiceDoc.from(Map<String, dynamic> inv) {
    final code = _s(inv['currency']).toUpperCase();
    final resolvedName =
        code.isEmpty ? '' : cf.currencyName(code).trim();
    final dateRaw = _s(inv['invoice_date']);
    final items = <InvoiceDocItem>[];
    for (final m in (inv['items'] as List? ?? const [])) {
      if (m is Map) {
        final mm = Map<String, dynamic>.from(m);
        items.add(InvoiceDocItem(
          description: _s(mm['description']).trim().isEmpty
              ? _s(mm['product_name'])
              : _s(mm['description']),
          quantity: _n(mm['quantity']),
          unitName: _s(mm['unit_name']),
          unitPrice: _n(mm['unit_price']),
          discount: _n(mm['discount']),
          total: _n(mm['total']),
          productId: _s(mm['product_id']),
        ));
      }
    }
    final payments = <InvoiceDocPayment>[];
    for (final m in (inv['payments'] as List? ?? const [])) {
      if (m is Map) {
        final mm = Map<String, dynamic>.from(m);
        payments.add(InvoiceDocPayment(
          method: _s(mm['payment_method']),
          amount: _n(mm['amount']),
          currency: _s(mm['payment_currency']).isEmpty
              ? code
              : _s(mm['payment_currency']),
          accountName: _s(mm['bank_account_name']),
        ));
      }
    }
    final type = _s(inv['invoice_type']).isEmpty
        ? (inv['customer_name'] != null ? 'sale' : 'purchase')
        : _s(inv['invoice_type']);
    final isPurchaseType =
        type == 'purchase' || type == 'purchase_return';
    return InvoiceDoc(
      number: shortDocumentNumber(inv['invoice_number']),
      type: type,
      dateRaw: dateRaw,
      date: DateTime.tryParse(dateRaw),
      branch: _s(inv['branch_name']),
      partyName: isPurchaseType
          ? _s(inv['supplier_name'])
          : _s(inv['customer_name']),
      partyPhone: isPurchaseType
          ? _s(inv['supplier_phone'])
          : _s(inv['customer_phone']),
      currencyCode: code,
      currencyName: resolvedName.isNotEmpty ? resolvedName : code,
      subtotal: _n(inv['subtotal']),
      discount: _n(inv['discount_amount']),
      tax: _n(inv['tax_amount']),
      total: _n(inv['total']),
      paid: _n(inv['paid_amount']),
      balance: _n(inv['balance']),
      notes: _s(inv['notes']),
      cashier: _s(inv['by_name']).isNotEmpty
          ? _s(inv['by_name'])
          : _s(inv['cashier_name']).trim(),
      cashierRole: _s(inv['cashier_role']),
      status: _s(inv['status']),
      originalInvoice: _s(inv['original_invoice']),
      isReturn: type.endsWith('_return'),
      items: items,
      payments: payments,
    );
  }
}

class InvoiceDocItem {
  final String description;
  final double quantity;
  final String unitName;
  final double unitPrice;
  final double discount;
  final double total;
  final String productId;
  const InvoiceDocItem({
    required this.description,
    required this.quantity,
    required this.unitName,
    required this.unitPrice,
    required this.discount,
    required this.total,
    required this.productId,
  });

  String get quantityText =>
      quantity == quantity.roundToDouble()
          ? quantity.toStringAsFixed(0)
          : quantity.toStringAsFixed(2);
}

class InvoiceDocPayment {
  final String method;
  final double amount;
  final String currency;
  final String accountName;
  const InvoiceDocPayment({
    required this.method,
    required this.amount,
    required this.currency,
    required this.accountName,
  });
}
