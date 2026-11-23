import 'dart:convert';
import 'dart:typed_data';

/// Business invoice design preset — two templates: paper (A4) and thermal
/// (80mm). Completely separate from the Personal receipt-design system; stored
/// under its own SharedPreferences keys.
///
/// The same preset is applied to BOTH sale and purchase invoices; the kind
/// only changes the printed title/party labels.
class InvoiceDesignPreset {
  final String templateId; // 'paper' | 'thermal'

  // Brand colours.
  final int primaryColor; // burgundy
  final int panelColor; // light panel
  final int textColor;
  final int secondaryTextColor;

  // Brand / store info.
  final String brandName;
  final String companyName;
  final String companyAddress;
  final String companyPhone;
  final String titleSale;
  final String titlePurchase;
  final String titleReturnCustomer;
  final String titleReturnSupplier;
  final String footerText;
  final String notesText;

  // Images.
  final Uint8List? logoBytes;
  final Uint8List? signatureBytes;
  final Uint8List? stampBytes;

  // Signature / stamp position (relative 0..1 inside the signature area).
  final double sigX;
  final double sigY;
  final double sigW;
  final double stampX;
  final double stampY;
  final double stampW;

  final double fontSizeScale;

  // Visibility.
  final bool showLogo;
  final bool showQR;
  final bool showSignature;
  final bool showStamp;
  final bool showCompanyInfo;
  final bool showCustomer;
  final bool showCashier;
  final bool showNotes;
  final bool showFooter;
  final bool showProductImages;

  const InvoiceDesignPreset({
    required this.templateId,
    this.primaryColor = 0xFF8E102F,
    this.panelColor = 0xFFF5F1F2,
    this.textColor = 0xFF1A1A1A,
    this.secondaryTextColor = 0xFF6B6B6B,
    this.brandName = 'FYONA',
    this.companyName = 'مؤسسة فيونا التجارية',
    this.companyAddress = 'صنعاء - اليمن',
    this.companyPhone = '777 000 000',
    this.titleSale = 'فاتورة بيع',
    this.titlePurchase = 'فاتورة شراء',
    this.titleReturnCustomer = 'مرتجع عميل',
    this.titleReturnSupplier = 'مرتجع مورد',
    this.footerText = 'نظام فيونا المحاسبي',
    this.notesText = 'شكراً لتعاملك معنا. يمكن تخصيص سياسة الاسترجاع أو أي ملاحظة خاصة بالفاتورة.',
    this.logoBytes,
    this.signatureBytes,
    this.stampBytes,
    this.sigX = 0.30,
    this.sigY = 0.25,
    this.sigW = 0.32,
    this.stampX = 0.70,
    this.stampY = 0.25,
    this.stampW = 0.28,
    this.fontSizeScale = 1.0,
    this.showLogo = true,
    this.showQR = true,
    this.showSignature = true,
    this.showStamp = true,
    this.showCompanyInfo = true,
    this.showCustomer = true,
    this.showCashier = true,
    this.showNotes = true,
    this.showFooter = true,
    this.showProductImages = true,
  });

  static InvoiceDesignPreset defaults(String templateId, {String? phone}) =>
      InvoiceDesignPreset(
        templateId: templateId,
        companyPhone:
            (phone == null || phone.trim().isEmpty) ? companyPhonePlaceholder : phone.trim(),
      );

  static const String companyPhonePlaceholder = '777 000 000';

  InvoiceDesignPreset copyWith({
    String? templateId,
    int? primaryColor,
    int? panelColor,
    int? textColor,
    int? secondaryTextColor,
    String? brandName,
    String? companyName,
    String? companyAddress,
    String? companyPhone,
    String? titleSale,
    String? titlePurchase,
    String? titleReturnCustomer,
    String? titleReturnSupplier,
    String? footerText,
    String? notesText,
    Uint8List? logoBytes,
    Uint8List? signatureBytes,
    Uint8List? stampBytes,
    bool clearLogo = false,
    bool clearSignature = false,
    bool clearStamp = false,
    double? sigX,
    double? sigY,
    double? sigW,
    double? stampX,
    double? stampY,
    double? stampW,
    double? fontSizeScale,
    bool? showLogo,
    bool? showQR,
    bool? showSignature,
    bool? showStamp,
    bool? showCompanyInfo,
    bool? showCustomer,
    bool? showCashier,
    bool? showNotes,
    bool? showFooter,
    bool? showProductImages,
  }) {
    return InvoiceDesignPreset(
      templateId: templateId ?? this.templateId,
      primaryColor: primaryColor ?? this.primaryColor,
      panelColor: panelColor ?? this.panelColor,
      textColor: textColor ?? this.textColor,
      secondaryTextColor: secondaryTextColor ?? this.secondaryTextColor,
      brandName: brandName ?? this.brandName,
      companyName: companyName ?? this.companyName,
      companyAddress: companyAddress ?? this.companyAddress,
      companyPhone: companyPhone ?? this.companyPhone,
      titleSale: titleSale ?? this.titleSale,
      titlePurchase: titlePurchase ?? this.titlePurchase,
      titleReturnCustomer: titleReturnCustomer ?? this.titleReturnCustomer,
      titleReturnSupplier: titleReturnSupplier ?? this.titleReturnSupplier,
      footerText: footerText ?? this.footerText,
      notesText: notesText ?? this.notesText,
      logoBytes: clearLogo ? null : (logoBytes ?? this.logoBytes),
      signatureBytes:
          clearSignature ? null : (signatureBytes ?? this.signatureBytes),
      stampBytes: clearStamp ? null : (stampBytes ?? this.stampBytes),
      sigX: sigX ?? this.sigX,
      sigY: sigY ?? this.sigY,
      sigW: sigW ?? this.sigW,
      stampX: stampX ?? this.stampX,
      stampY: stampY ?? this.stampY,
      stampW: stampW ?? this.stampW,
      fontSizeScale: fontSizeScale ?? this.fontSizeScale,
      showLogo: showLogo ?? this.showLogo,
      showQR: showQR ?? this.showQR,
      showSignature: showSignature ?? this.showSignature,
      showStamp: showStamp ?? this.showStamp,
      showCompanyInfo: showCompanyInfo ?? this.showCompanyInfo,
      showCustomer: showCustomer ?? this.showCustomer,
      showCashier: showCashier ?? this.showCashier,
      showNotes: showNotes ?? this.showNotes,
      showFooter: showFooter ?? this.showFooter,
      showProductImages: showProductImages ?? this.showProductImages,
    );
  }

  Map<String, dynamic> toJson() => {
        'templateId': templateId,
        'primaryColor': primaryColor,
        'panelColor': panelColor,
        'textColor': textColor,
        'secondaryTextColor': secondaryTextColor,
        'brandName': brandName,
        'companyName': companyName,
        'companyAddress': companyAddress,
        'companyPhone': companyPhone,
        'titleSale': titleSale,
        'titlePurchase': titlePurchase,
        'titleReturnCustomer': titleReturnCustomer,
        'titleReturnSupplier': titleReturnSupplier,
        'footerText': footerText,
        'notesText': notesText,
        'logo_bytes':
            logoBytes == null ? null : base64Encode(logoBytes!),
        'signature_bytes':
            signatureBytes == null ? null : base64Encode(signatureBytes!),
        'stamp_bytes': stampBytes == null ? null : base64Encode(stampBytes!),
        'sigX': sigX,
        'sigY': sigY,
        'sigW': sigW,
        'stampX': stampX,
        'stampY': stampY,
        'stampW': stampW,
        'fontSizeScale': fontSizeScale,
        'showLogo': showLogo,
        'showQR': showQR,
        'showSignature': showSignature,
        'showStamp': showStamp,
        'showCompanyInfo': showCompanyInfo,
        'showCustomer': showCustomer,
        'showCashier': showCashier,
        'showNotes': showNotes,
        'showFooter': showFooter,
        'showProductImages': showProductImages,
      };

  factory InvoiceDesignPreset.fromJson(Map<String, dynamic> j) {
    Uint8List? dec(dynamic v) {
      if (v is! String || v.isEmpty) return null;
      try {
        return base64Decode(v);
      } catch (_) {
        return null;
      }
    }

    final d = InvoiceDesignPreset.defaults(
        (j['templateId'] ?? 'paper').toString());
    return InvoiceDesignPreset(
      templateId: (j['templateId'] ?? d.templateId).toString(),
      primaryColor: (j['primaryColor'] as num?)?.toInt() ?? d.primaryColor,
      panelColor: (j['panelColor'] as num?)?.toInt() ?? d.panelColor,
      textColor: (j['textColor'] as num?)?.toInt() ?? d.textColor,
      secondaryTextColor:
          (j['secondaryTextColor'] as num?)?.toInt() ?? d.secondaryTextColor,
      brandName: (j['brandName'] ?? d.brandName).toString(),
      companyName: (j['companyName'] ?? d.companyName).toString(),
      companyAddress: (j['companyAddress'] ?? d.companyAddress).toString(),
      companyPhone: (j['companyPhone'] ?? d.companyPhone).toString(),
      titleSale: (j['titleSale'] ?? d.titleSale).toString(),
      titlePurchase: (j['titlePurchase'] ?? d.titlePurchase).toString(),
      titleReturnCustomer:
          (j['titleReturnCustomer'] ?? d.titleReturnCustomer).toString(),
      titleReturnSupplier:
          (j['titleReturnSupplier'] ?? d.titleReturnSupplier).toString(),
      footerText: (j['footerText'] ?? d.footerText).toString(),
      notesText: (j['notesText'] ?? d.notesText).toString(),
      logoBytes: dec(j['logo_bytes']),
      signatureBytes: dec(j['signature_bytes']),
      stampBytes: dec(j['stamp_bytes']),
      sigX: (j['sigX'] as num?)?.toDouble() ?? d.sigX,
      sigY: (j['sigY'] as num?)?.toDouble() ?? d.sigY,
      sigW: (j['sigW'] as num?)?.toDouble() ?? d.sigW,
      stampX: (j['stampX'] as num?)?.toDouble() ?? d.stampX,
      stampY: (j['stampY'] as num?)?.toDouble() ?? d.stampY,
      stampW: (j['stampW'] as num?)?.toDouble() ?? d.stampW,
      fontSizeScale:
          (j['fontSizeScale'] as num?)?.toDouble() ?? d.fontSizeScale,
      showLogo: (j['showLogo'] as bool?) ?? d.showLogo,
      showQR: (j['showQR'] as bool?) ?? d.showQR,
      showSignature: (j['showSignature'] as bool?) ?? d.showSignature,
      showStamp: (j['showStamp'] as bool?) ?? d.showStamp,
      showCompanyInfo: (j['showCompanyInfo'] as bool?) ?? d.showCompanyInfo,
      showCustomer: (j['showCustomer'] as bool?) ?? d.showCustomer,
      showCashier: (j['showCashier'] as bool?) ?? d.showCashier,
      showNotes: (j['showNotes'] as bool?) ?? d.showNotes,
      showFooter: (j['showFooter'] as bool?) ?? d.showFooter,
      showProductImages:
          (j['showProductImages'] as bool?) ?? d.showProductImages,
    );
  }
}
