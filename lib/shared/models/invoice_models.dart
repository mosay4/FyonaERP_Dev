import 'package:equatable/equatable.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';

class SalesInvoiceModel extends Equatable {
  final String? id;
  final String invoiceNumber;
  final String? customerId;
  final String? customerName;
  final DateTime invoiceDate;
  final String status;
  final double subtotal;
  final double discount;
  final double tax;
  final double total;
  final double paid;
  final double balance;
  final String? notes;
  final List<InvoiceLineItem>? items;

  const SalesInvoiceModel({
    this.id, required this.invoiceNumber, this.customerId, this.customerName,
    required this.invoiceDate, this.status = 'draft',
    this.subtotal = 0, this.discount = 0, this.tax = 0, this.total = 0,
    this.paid = 0, this.balance = 0, this.notes, this.items,
  });

  factory SalesInvoiceModel.fromJson(Map<String, dynamic> json) => SalesInvoiceModel(
    id: json['id'].toString(),
    invoiceNumber: json['invoice_number'] as String? ?? '',
    customerId: json['customer_id'].toString(),
    customerName: json['customer_name'] as String?,
    invoiceDate: DateTime.tryParse(json['invoice_date'].toString()) ?? DateTime(2000),
    status: json['status'] as String? ?? 'draft',
    subtotal: (json['subtotal'] as num?)?.toDouble() ?? 0,
    discount: (json['discount_amount'] as num?)?.toDouble() ?? 0,
    tax: (json['tax_amount'] as num?)?.toDouble() ?? 0,
    total: (json['total'] as num?)?.toDouble() ?? 0,
    paid: (json['paid_amount'] as num?)?.toDouble() ?? 0,
    balance: (json['balance'] as num?)?.toDouble() ?? 0,
    notes: json['notes'] as String?,
    items: json['items'] is List ? (json['items'] as List).whereType<Map<String, dynamic>>().map((i) => InvoiceLineItem.fromJson(i)).toList() : null,
  );

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id, 'invoice_number': invoiceNumber,
    if (customerId != null) 'customer_id': customerId,
    'invoice_date': invoiceDate.toIso8601String(), 'status': status,
    'subtotal': subtotal, 'discount_amount': discount, 'tax_amount': tax,
    'total': total, 'paid_amount': paid, 'balance': balance,
    if (notes != null) 'notes': notes,
  };

  @override List<Object?> get props => [id, invoiceNumber];

  // Backward-compatible getters for legacy screens
  String get invoiceNo => invoiceNumber;
  String get invoiceNumberDisplay => invoiceNumber;
  double get grandTotal => total;
  double get grandTotalDisplay => total;
  String get date => '${invoiceDate.year}-${invoiceDate.month.toString().padLeft(2, '0')}-${invoiceDate.day.toString().padLeft(2, '0')}';
  String get statusLabel => status == 'draft' ? AppLocalizations.t('status_draft') : status == 'confirmed' ? AppLocalizations.t('status_confirmed') : status == 'paid' ? AppLocalizations.t('status_paid') : status == 'cancelled' ? AppLocalizations.t('status_cancelled') : status;
  String get statusColor => status == 'paid' ? 'green' : status == 'cancelled' ? 'red' : status == 'draft' ? 'grey' : 'blue';

  dynamic operator [](String key) {
    switch (key) {
      case 'id': return id;
      case 'invoice_number': case 'invoiceNo': case 'invoiceNumber': return invoiceNumber;
      case 'customer_id': return customerId;
      case 'customer_name': return customerName;
      case 'invoice_date': return invoiceDate.toIso8601String();
      case 'status': return status;
      case 'subtotal': return subtotal;
      case 'discount_amount': return discount;
      case 'tax_amount': return tax;
      case 'total': case 'grandTotal': return total;
      case 'paid_amount': return paid;
      case 'balance': return balance;
      case 'notes': return notes;
      default: return null;
    }
  }
}

class InvoiceLineItem extends Equatable {
  final String? id;
  final String? productId;
  final String? productName;
  final String description;
  final double quantity;
  final double unitPrice;
  final double discount;
  final double taxRate;
  final double total;

  const InvoiceLineItem({
    this.id, this.productId, this.productName, required this.description,
    this.quantity = 1, this.unitPrice = 0, this.discount = 0, this.taxRate = 0, this.total = 0,
  });

  factory InvoiceLineItem.fromJson(Map<String, dynamic> json) => InvoiceLineItem(
    id: json['id'].toString(), productId: json['product_id'].toString(),
    productName: json['product_name'] as String?,
    description: json['description'] as String? ?? '',
    quantity: (json['quantity'] as num?)?.toDouble() ?? 1,
    unitPrice: (json['unit_price'] as num?)?.toDouble() ?? 0,
    discount: (json['discount'] as num?)?.toDouble() ?? 0,
    taxRate: (json['tax_rate'] as num?)?.toDouble() ?? 0,
    total: (json['total'] as num?)?.toDouble() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    if (productId != null) 'product_id': productId,
    'description': description, 'quantity': quantity, 'unit_price': unitPrice,
    if (discount > 0) 'discount': discount,
    if (taxRate > 0) 'tax_rate': taxRate,
  };

  @override List<Object?> get props => [id, description];
}
