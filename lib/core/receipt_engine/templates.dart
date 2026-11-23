import 'package:flutter/material.dart';
import 'models.dart';

const _defaultCardOrder = [
  'header', 'amount', 'info', 'party',
  'items', 'totals', 'notes', 'footer',
];

class TemplateRegistry {
  TemplateRegistry._();

  static final Map<DocumentType, TemplatePreset> _registry = {};

  static void register(DocumentType type, TemplatePreset preset) {
    _registry[type] = preset;
  }

  static TemplatePreset get(DocumentType type) {
    return _registry[type] ?? _registry.values.first;
  }

  static List<TemplatePreset> listTemplates() => _registry.values.toList();

  static List<String> cardOrderFor(DocumentType type) {
    return _registry[type]?.cardOrder ?? _defaultCardOrder;
  }

  static void initialize() {
    register(DocumentType.salesInvoice, const TemplatePreset(
      name: 'فاتورة مبيعات', description: 'قالب فاتورة المبيعات الأساسي',
      documentType: DocumentType.salesInvoice, layout: LayoutPreset.modern,
      colors: ThemeColorsConfig(), typography: TypographyConfig(),
      cardOrder: _defaultCardOrder,
    ));
    register(DocumentType.purchaseInvoice, const TemplatePreset(
      name: 'فاتورة مشتريات', description: 'قالب فاتورة المشتريات',
      documentType: DocumentType.purchaseInvoice, layout: LayoutPreset.modern,
      colors: ThemeColorsConfig(primary: Color(0xFF1565C0), amountText: Color(0xFF1565C0), tableHeader: Color(0xFF1565C0)),
      typography: TypographyConfig(),
      cardOrder: ['header', 'info', 'party', 'items', 'totals', 'notes', 'footer'],
    ));
    register(DocumentType.paymentReceipt, const TemplatePreset(
      name: 'سند قبض', description: 'قالب سند القبض',
      documentType: DocumentType.paymentReceipt, layout: LayoutPreset.bank,
      colors: ThemeColorsConfig(primary: Color(0xFF2E7D32), amountText: Color(0xFF2E7D32), tableHeader: Color(0xFF2E7D32)),
      typography: TypographyConfig(amountSize: 24),
      cardOrder: ['header', 'amount', 'info', 'party', 'totals', 'notes', 'footer'],
    ));
    register(DocumentType.paymentVoucher, const TemplatePreset(
      name: 'سند صرف', description: 'قالب سند الصرف',
      documentType: DocumentType.paymentVoucher, layout: LayoutPreset.bank,
      colors: ThemeColorsConfig(primary: Color(0xFFC62828), amountText: Color(0xFFC62828), tableHeader: Color(0xFFC62828)),
      typography: TypographyConfig(amountSize: 24),
      cardOrder: ['header', 'amount', 'info', 'party', 'totals', 'notes', 'footer'],
    ));
    register(DocumentType.transferNote, const TemplatePreset(
      name: 'إذن تحويل', description: 'قالب إذن التحويل',
      documentType: DocumentType.transferNote, layout: LayoutPreset.minimal,
      colors: ThemeColorsConfig(primary: Color(0xFFE65100), amountText: Color(0xFFE65100), tableHeader: Color(0xFFE65100)),
      typography: TypographyConfig(),
      cardOrder: ['header', 'info', 'items', 'totals', 'notes', 'footer'],
    ));
    register(DocumentType.receiptNote, const TemplatePreset(
      name: 'إذن استلام', description: 'قالب إذن الاستلام',
      documentType: DocumentType.receiptNote, layout: LayoutPreset.minimal,
      colors: ThemeColorsConfig(primary: Color(0xFF1565C0), amountText: Color(0xFF1565C0), tableHeader: Color(0xFF1565C0)),
      typography: TypographyConfig(),
      cardOrder: ['header', 'info', 'items', 'totals', 'notes', 'footer'],
    ));
    register(DocumentType.paymentNote, const TemplatePreset(
      name: 'إشعار دائن/مدين', description: 'قالب الإشعار',
      documentType: DocumentType.paymentNote, layout: LayoutPreset.classic,
      colors: ThemeColorsConfig(primary: Color(0xFFA01530), amountText: Color(0xFFA01530), tableHeader: Color(0xFFA01530)),
      typography: TypographyConfig(),
      cardOrder: _defaultCardOrder,
    ));
  }
}




