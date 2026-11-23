import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../receipt_engine/models.dart';
import '../receipt_engine/renderer.dart';
import '../receipt_engine/export.dart';
import '../receipt_engine/templates.dart';
import '../receipt_engine/config.dart';
import 'interfaces/all_services.dart';

class ReceiptServiceImpl implements ReceiptService {
  final Ref? ref;
  final DocumentConfigService? configService;

  ReceiptServiceImpl({this.ref, this.configService});

  @override
  Future<ReceiptData> generateReceipt(DocumentType type, Map<String, dynamic> data, {DocumentConfig? config}) async {
    final items = (data['items'] as List<dynamic>?)
            ?.map((e) => ReceiptItem(
                  name: e['name'] as String? ?? '',
                  quantity: (e['quantity'] as num?)?.toDouble() ?? 0,
                  price: (e['price'] as num?)?.toDouble() ?? 0,
                  total: (e['total'] as num?)?.toDouble() ?? 0,
                  tax: (e['tax'] as num?)?.toDouble() ?? 0,
                  discount: (e['discount'] as num?)?.toDouble() ?? 0,
                  unit: e['unit'] as String?,
                ))
            .toList() ??
        [];
    return ReceiptData(
      type: type,
      documentNumber: data['document_number'] as String? ?? '',
      date: DateTime.tryParse(data['date'].toString()) ?? DateTime(2000),
      dueDate: DateTime.tryParse(data['due_date'].toString()),
      status: data['status'] as String?,
      referenceNumber: data['reference_number'] as String?,
      partyName: data['party_name'] as String?,
      partyAddress: data['party_address'] as String?,
      partyPhone: data['party_phone'] as String?,
      partyTaxNumber: data['party_tax_number'] as String?,
      subtotal: (data['subtotal'] as num?)?.toDouble() ?? 0,
      taxAmount: (data['tax_amount'] as num?)?.toDouble() ?? 0,
      discountAmount: (data['discount_amount'] as num?)?.toDouble() ?? 0,
      total: (data['total'] as num?)?.toDouble() ?? 0,
      paid: (data['paid'] as num?)?.toDouble() ?? 0,
      due: (data['due'] as num?)?.toDouble() ?? 0,
      amountInWords: data['amount_in_words'] as String?,
      notes: data['notes'] as String?,
      items: items,
      currency: data['currency'] as String? ?? 'SAR',
      createdBy: data['created_by'] as String?,
    );
  }

  @override
  Widget previewDocument(ReceiptData data, {DocumentConfig? config}) {
    return WidgetReceiptRenderer(
      data: data,
      config: config ?? ReceiptConfigDefaults.defaultFor(data.type),
    );
  }

  @override
  Future<Uint8List> exportPdf(ReceiptData data, {DocumentConfig? config}) {
    return exportToPdf(data, config ?? ReceiptConfigDefaults.defaultFor(data.type));
  }

  @override
  Future<Uint8List> exportImage(ReceiptData data, BuildContext context, {DocumentConfig? config}) {
    return exportToImage(data, config ?? ReceiptConfigDefaults.defaultFor(data.type), context);
  }

  @override
  Future<void> printDocument(ReceiptData data, {DocumentConfig? config}) {
    return printReceipt(data, config ?? ReceiptConfigDefaults.defaultFor(data.type));
  }

  @override
  Future<DocumentConfig> loadConfig({DocumentType type = DocumentType.salesInvoice}) async {
    if (configService != null) {
      return configService!.loadConfig(type: type);
    }
    return ReceiptConfigDefaults.defaultFor(type);
  }

  @override
  Future<void> saveConfig(DocumentConfig config) async {
    await configService?.saveConfig(config);
  }

  @override
  List<TemplatePreset> listTemplates() => TemplateRegistry.listTemplates();

  @override
  TemplatePreset getTemplate(DocumentType type) => TemplateRegistry.get(type);

  @override
  List<DocumentType> supportedTypes() => DocumentType.values.toList();
}
