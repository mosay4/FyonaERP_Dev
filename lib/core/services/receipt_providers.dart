import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../receipt_engine/models.dart';
import '../receipt_engine/templates.dart';
import '../receipt_engine/cards.dart';
import '../receipt_engine/config.dart';
import '../receipt_engine/renderer.dart';
import '../receipt_engine/export.dart';
import 'receipt_service.dart';

final documentConfigServiceProvider = Provider<DocumentConfigService>((ref) {
  return DocumentConfigService();
});

final receiptServiceProvider = Provider<ReceiptServiceImpl>((ref) {
  final configService = ref.watch(documentConfigServiceProvider);
  return ReceiptServiceImpl(ref: ref, configService: configService);
});

class ReceiptConfigNotifier extends StateNotifier<DocumentConfig> {
  final DocumentConfigService _configService;

  ReceiptConfigNotifier(this._configService, DocumentConfig initialState)
      : super(initialState);

  Future<void> load({DocumentType type = DocumentType.salesInvoice}) async {
    final config = await _configService.loadConfig(type: type);
    state = config;
  }

  Future<void> save() async {
    await _configService.saveConfig(state);
  }

  void update(DocumentConfig config) {
    state = config;
  }

  void updateLayout(LayoutPreset layout) {
    state = state.copyWith(layoutPreset: layout);
  }

  void updateColors(ThemeColorsConfig colors) {
    state = state.copyWith(colors: colors);
  }

  void updateTypography(TypographyConfig typography) {
    state = state.copyWith(typography: typography);
  }

  void updateCompany(CompanyInfo company) {
    state = state.copyWith(company: company);
  }

  void updateVisibility(VisibilityConfig visibility) {
    state = state.copyWith(visibility: visibility);
  }

  void updateWatermark(WatermarkConfig watermark) {
    state = state.copyWith(watermark: watermark);
  }

  void updateFooter(FooterConfig footer) {
    state = state.copyWith(footer: footer);
  }

  void setLogo(Uint8List? bytes) {
    state = state.copyWith(logoBytes: bytes);
  }

  void setSignature(Uint8List? bytes) {
    state = state.copyWith(signatureBytes: bytes);
  }

  void setStamp(Uint8List? bytes) {
    state = state.copyWith(stampBytes: bytes);
  }
}

final receiptConfigProvider = StateNotifierProvider.autoDispose<ReceiptConfigNotifier, DocumentConfig>((ref) {
  final configService = ref.watch(documentConfigServiceProvider);
  final defaults = ReceiptConfigDefaults.defaultFor(DocumentType.salesInvoice);
  return ReceiptConfigNotifier(configService, defaults);
});

final receiptPreviewProvider = FutureProvider.autoDispose.family<Widget, ReceiptData>((ref, data) {
  final config = ref.watch(receiptConfigProvider);
  return WidgetReceiptRenderer(data: data, config: config);
});

final receiptPdfProvider = FutureProvider.autoDispose.family<Uint8List, ReceiptData>((ref, data) async {
  final config = ref.watch(receiptConfigProvider);
  return exportToPdf(data, config);
});

final initializeReceiptEngineProvider = Provider<void>((ref) {
  TemplateRegistry.initialize();
  CardRegistry.initialize();
  return;
});
