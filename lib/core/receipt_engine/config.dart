import 'package:flutter/services.dart';
import '../localization/app_localizations.dart';
import '../services/interfaces/all_services.dart';
import 'models.dart';

class ReceiptConfigDefaults {
  ReceiptConfigDefaults._();

  static DocumentConfig defaultFor(DocumentType type) {
    return DocumentConfig(
      documentType: type,
      layoutPreset: LayoutPreset.modern,
      typography: const TypographyConfig(),
      colors: const ThemeColorsConfig(
        primary: Color(0xFFA01530),
        secondary: Color(0xFFB82040),
        background: Color(0xFFF5F6F7),
        cardBackground: Color(0xFFFFFFFF),
        border: Color(0xFFD5D8DA),
        textPrimary: Color(0xFF1A1A1A),
        textSecondary: Color(0xFF5A5A5A),
        amountText: Color(0xFFA01530),
        success: Color(0xFF2E7D32),
        warning: Color(0xFFE65100),
        danger: Color(0xFFC62828),
        tableHeader: Color(0xFFA01530),
        tableRowEven: Color(0xFFF8F8F8),
        tableRowOdd: Color(0xFFFFFFFF),
      ),
      canvas: const CanvasConfig(),
      company: const CompanyInfo(
        name: '',
        branch: '',
        address: '',
        phone: '',
        email: '',
      ),
      watermark: const WatermarkConfig(),
      visibility: const VisibilityConfig(),
      footer: FooterConfig(text: AppLocalizations.t('designStudioThankYouForDealing')),
    );
  }

  static DocumentConfig merge(DocumentConfig base, DocumentConfig? override) {
    if (override == null) return base;
    return base.copyWith(
      layoutPreset: override.layoutPreset,
      typography: override.typography,
      colors: override.colors,
      canvas: override.canvas,
      company: override.company,
      logoBytes: override.logoBytes,
      watermark: override.watermark,
      signatureBytes: override.signatureBytes,
      stampBytes: override.stampBytes,
      visibility: override.visibility,
      footer: override.footer,
      amountInWords: override.amountInWords,
      notes: override.notes,
    );
  }
}

DocumentConfig mergeDocumentConfig(DocumentConfig base, DocumentConfig? override) {
  return ReceiptConfigDefaults.merge(base, override);
}

class DocumentConfigService {
  final UserPreferencesService? preferencesService;

  DocumentConfigService({this.preferencesService});

  Future<DocumentConfig> loadConfig({DocumentType type = DocumentType.salesInvoice}) async {
    if (preferencesService == null) {
      return ReceiptConfigDefaults.defaultFor(type);
    }
    try {
      final prefs = await preferencesService!.getPreferencesByGroup('receipt');
      if (prefs.isNotEmpty) {
        final json = Map<String, dynamic>.from(prefs);
        json['document_type'] = type.name;
        return DocumentConfig.fromJson(json);
      }
    } catch (_) {}
    return ReceiptConfigDefaults.defaultFor(type);
  }

  Future<void> saveConfig(DocumentConfig config) async {
    if (preferencesService == null) return;
    try {
      final json = config.toJson();
      for (final entry in json.entries) {
        if (entry.key == 'document_type') continue;
        await preferencesService!.setPreference('receipt_${entry.key}', entry.value);
      }
    } catch (_) {}
  }
}




