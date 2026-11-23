import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:equatable/equatable.dart';

enum DocumentType {
  salesInvoice,
  purchaseInvoice,
  paymentReceipt,
  paymentVoucher,
  transferNote,
  receiptNote,
  paymentNote,
}

enum LayoutPreset {
  modern,
  bank,
  classic,
  minimal,
  elegant,
  corporate,
  premium,
  glass,
  luxury,
  apple,
  pos,
  banking,
  executive,
}

class CompanyInfo extends Equatable {
  final String name;
  final String? branch;
  final String? address;
  final String? phone;
  final String? phone2;
  final String? mobile;
  final String? email;
  final String? taxNumber;
  final String? commercialRegister;

  const CompanyInfo({
    this.name = '',
    this.branch,
    this.address,
    this.phone,
    this.phone2,
    this.mobile,
    this.email,
    this.taxNumber,
    this.commercialRegister,
  });

  CompanyInfo copyWith({
    String? name, String? branch, String? address,
    String? phone, String? phone2, String? mobile,
    String? email, String? taxNumber, String? commercialRegister,
  }) {
    return CompanyInfo(
      name: name ?? this.name, branch: branch ?? this.branch,
      address: address ?? this.address, phone: phone ?? this.phone,
      phone2: phone2 ?? this.phone2, mobile: mobile ?? this.mobile,
      email: email ?? this.email, taxNumber: taxNumber ?? this.taxNumber,
      commercialRegister: commercialRegister ?? this.commercialRegister,
    );
  }

  @override
  List<Object?> get props => [name, branch, address, phone, phone2, mobile, email, taxNumber, commercialRegister];

  Map<String, dynamic> toJson() => {
    'name': name, 'branch': branch, 'address': address,
    'phone': phone, 'phone2': phone2, 'mobile': mobile,
    'email': email, 'tax_number': taxNumber, 'commercial_register': commercialRegister,
  };

  factory CompanyInfo.fromJson(Map<String, dynamic> json) => CompanyInfo(
    name: json['name'] as String? ?? '',
    branch: json['branch'] as String?,
    address: json['address'] as String?,
    phone: json['phone'] as String?,
    phone2: json['phone2'] as String?,
    mobile: json['mobile'] as String?,
    email: json['email'] as String?,
    taxNumber: json['tax_number'] as String?,
    commercialRegister: json['commercial_register'] as String?,
  );
}

class WatermarkConfig extends Equatable {
  final bool enabled;
  final String text;
  final Uint8List? imageBytes;
  final double opacity;
  final double rotation;
  final double size;
  final Alignment alignment;

  const WatermarkConfig({
    this.enabled = false,
    this.text = 'FYONA ERP',
    this.imageBytes,
    this.opacity = 0.15,
    this.rotation = -30,
    this.size = 60,
    this.alignment = Alignment.center,
  });

  WatermarkConfig copyWith({
    bool? enabled, String? text, Uint8List? imageBytes,
    double? opacity, double? rotation, double? size, Alignment? alignment,
  }) {
    return WatermarkConfig(
      enabled: enabled ?? this.enabled, text: text ?? this.text,
      imageBytes: imageBytes ?? this.imageBytes, opacity: opacity ?? this.opacity,
      rotation: rotation ?? this.rotation, size: size ?? this.size,
      alignment: alignment ?? this.alignment,
    );
  }

  @override
  List<Object?> get props => [enabled, text, imageBytes, opacity, rotation, size, alignment];
}

class TypographyConfig extends Equatable {
  final String fontFamily;
  final double headerSize;
  final double bodySize;
  final double titleSize;
  final double amountSize;
  final double smallSize;

  const TypographyConfig({
    this.fontFamily = 'Cairo',
    this.headerSize = 18,
    this.bodySize = 11,
    this.titleSize = 14,
    this.amountSize = 20,
    this.smallSize = 9,
  });

  TypographyConfig copyWith({
    String? fontFamily, double? headerSize, double? bodySize,
    double? titleSize, double? amountSize, double? smallSize,
  }) {
    return TypographyConfig(
      fontFamily: fontFamily ?? this.fontFamily,
      headerSize: headerSize ?? this.headerSize,
      bodySize: bodySize ?? this.bodySize,
      titleSize: titleSize ?? this.titleSize,
      amountSize: amountSize ?? this.amountSize,
      smallSize: smallSize ?? this.smallSize,
    );
  }

  @override
  List<Object?> get props => [fontFamily, headerSize, bodySize, titleSize, amountSize, smallSize];
}

class ThemeColorsConfig extends Equatable {
  final Color primary;
  final Color secondary;
  final Color background;
  final Color cardBackground;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;
  final Color textDisabled;
  final Color amountText;
  final Color success;
  final Color warning;
  final Color danger;
  final Color tableHeader;
  final Color tableRowEven;
  final Color tableRowOdd;

  const ThemeColorsConfig({
    this.primary = const Color(0xFFA01530),
    this.secondary = const Color(0xFFB82040),
    this.background = const Color(0xFFF5F6F7),
    this.cardBackground = const Color(0xFFFFFFFF),
    this.border = const Color(0xFFD5D8DA),
    this.textPrimary = const Color(0xFF1A1A1A),
    this.textSecondary = const Color(0xFF5A5A5A),
    this.textDisabled = const Color(0xFF999999),
    this.amountText = const Color(0xFFA01530),
    this.success = const Color(0xFF2E7D32),
    this.warning = const Color(0xFFE65100),
    this.danger = const Color(0xFFC62828),
    this.tableHeader = const Color(0xFFA01530),
    this.tableRowEven = const Color(0xFFF8F8F8),
    this.tableRowOdd = const Color(0xFFFFFFFF),
  });

  ThemeColorsConfig copyWith({
    Color? primary, Color? secondary, Color? background,
    Color? cardBackground, Color? border, Color? textPrimary,
    Color? textSecondary, Color? textDisabled, Color? amountText, Color? success,
    Color? warning, Color? danger, Color? tableHeader,
    Color? tableRowEven, Color? tableRowOdd,
  }) {
    return ThemeColorsConfig(
      primary: primary ?? this.primary, secondary: secondary ?? this.secondary,
      background: background ?? this.background, cardBackground: cardBackground ?? this.cardBackground,
      border: border ?? this.border, textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textDisabled: textDisabled ?? this.textDisabled,
      amountText: amountText ?? this.amountText,
      success: success ?? this.success, warning: warning ?? this.warning,
      danger: danger ?? this.danger, tableHeader: tableHeader ?? this.tableHeader,
      tableRowEven: tableRowEven ?? this.tableRowEven, tableRowOdd: tableRowOdd ?? this.tableRowOdd,
    );
  }

  @override
  List<Object?> get props => [
    primary, secondary, background, cardBackground, border,
    textPrimary, textSecondary, textDisabled, amountText, success, warning, danger,
    tableHeader, tableRowEven, tableRowOdd,
  ];
}

class VisibilityConfig extends Equatable {
  final bool showLogo;
  final bool showCompanyName;
  final bool showBranch;
  final bool showDocumentTitle;
  final bool showDocumentNumber;
  final bool showDate;
  final bool showStatus;
  final bool showAmount;
  final bool showAmountInWords;
  final bool showParty;
  final bool showItems;
  final bool showTotals;
  final bool showNotes;
  final bool showQR;
  final bool showBarcode;
  final bool showSignature;
  final bool showStamp;
  final bool showWatermark;
  final bool showFooter;

  const VisibilityConfig({
    this.showLogo = true,
    this.showCompanyName = true,
    this.showBranch = true,
    this.showDocumentTitle = true,
    this.showDocumentNumber = true,
    this.showDate = true,
    this.showStatus = true,
    this.showAmount = true,
    this.showAmountInWords = true,
    this.showParty = true,
    this.showItems = true,
    this.showTotals = true,
    this.showNotes = true,
    this.showQR = true,
    this.showBarcode = false,
    this.showSignature = false,
    this.showStamp = false,
    this.showWatermark = false,
    this.showFooter = true,
  });

  VisibilityConfig copyWith({
    bool? showLogo, bool? showCompanyName, bool? showBranch,
    bool? showDocumentTitle, bool? showDocumentNumber, bool? showDate,
    bool? showStatus, bool? showAmount, bool? showAmountInWords,
    bool? showParty, bool? showItems, bool? showTotals, bool? showNotes,
    bool? showQR, bool? showBarcode, bool? showSignature, bool? showStamp,
    bool? showWatermark, bool? showFooter,
  }) {
    return VisibilityConfig(
      showLogo: showLogo ?? this.showLogo,
      showCompanyName: showCompanyName ?? this.showCompanyName,
      showBranch: showBranch ?? this.showBranch,
      showDocumentTitle: showDocumentTitle ?? this.showDocumentTitle,
      showDocumentNumber: showDocumentNumber ?? this.showDocumentNumber,
      showDate: showDate ?? this.showDate,
      showStatus: showStatus ?? this.showStatus,
      showAmount: showAmount ?? this.showAmount,
      showAmountInWords: showAmountInWords ?? this.showAmountInWords,
      showParty: showParty ?? this.showParty,
      showItems: showItems ?? this.showItems,
      showTotals: showTotals ?? this.showTotals,
      showNotes: showNotes ?? this.showNotes,
      showQR: showQR ?? this.showQR,
      showBarcode: showBarcode ?? this.showBarcode,
      showSignature: showSignature ?? this.showSignature,
      showStamp: showStamp ?? this.showStamp,
      showWatermark: showWatermark ?? this.showWatermark,
      showFooter: showFooter ?? this.showFooter,
    );
  }

  @override
  List<Object?> get props => [
    showLogo, showCompanyName, showBranch, showDocumentTitle,
    showDocumentNumber, showDate, showStatus, showAmount,
    showAmountInWords, showParty, showItems, showTotals, showNotes,
    showQR, showBarcode, showSignature, showStamp, showWatermark, showFooter,
  ];
}

class FooterConfig extends Equatable {
  final String? text;
  final bool showTerms;
  final bool showPoweredBy;

  const FooterConfig({this.text, this.showTerms = true, this.showPoweredBy = true});

  FooterConfig copyWith({String? text, bool? showTerms, bool? showPoweredBy}) {
    return FooterConfig(
      text: text ?? this.text,
      showTerms: showTerms ?? this.showTerms,
      showPoweredBy: showPoweredBy ?? this.showPoweredBy,
    );
  }

  @override
  List<Object?> get props => [text, showTerms, showPoweredBy];
}

class CanvasConfig extends Equatable {
  final double width;
  final double padding;
  final double borderRadius;

  const CanvasConfig({this.width = 580, this.padding = 16, this.borderRadius = 0});

  CanvasConfig copyWith({double? width, double? padding, double? borderRadius}) {
    return CanvasConfig(
      width: width ?? this.width,
      padding: padding ?? this.padding,
      borderRadius: borderRadius ?? this.borderRadius,
    );
  }

  @override
  List<Object?> get props => [width, padding, borderRadius];
}

class DocumentConfig extends Equatable {
  final DocumentType documentType;
  final LayoutPreset layoutPreset;
  final TypographyConfig typography;
  final ThemeColorsConfig colors;
  final CanvasConfig canvas;
  final CompanyInfo company;
  final Uint8List? logoBytes;
  final WatermarkConfig watermark;
  final Uint8List? signatureBytes;
  final Uint8List? stampBytes;
  final VisibilityConfig visibility;
  final FooterConfig footer;
  final String? amountInWords;
  final String? notes;

  const DocumentConfig({
    required this.documentType,
    this.layoutPreset = LayoutPreset.modern,
    this.typography = const TypographyConfig(),
    this.colors = const ThemeColorsConfig(),
    this.canvas = const CanvasConfig(),
    this.company = const CompanyInfo(),
    this.logoBytes,
    this.watermark = const WatermarkConfig(),
    this.signatureBytes,
    this.stampBytes,
    this.visibility = const VisibilityConfig(),
    this.footer = const FooterConfig(),
    this.amountInWords,
    this.notes,
  });

  @override
  List<Object?> get props => [
    documentType, layoutPreset, typography, colors, canvas, company,
    logoBytes, watermark, signatureBytes, stampBytes, visibility, footer,
    amountInWords, notes,
  ];

  DocumentConfig copyWith({
    DocumentType? documentType, LayoutPreset? layoutPreset,
    TypographyConfig? typography, ThemeColorsConfig? colors,
    CanvasConfig? canvas, CompanyInfo? company,
    Uint8List? logoBytes, WatermarkConfig? watermark,
    Uint8List? signatureBytes, Uint8List? stampBytes,
    VisibilityConfig? visibility, FooterConfig? footer,
    String? amountInWords, String? notes,
  }) {
    return DocumentConfig(
      documentType: documentType ?? this.documentType,
      layoutPreset: layoutPreset ?? this.layoutPreset,
      typography: typography ?? this.typography,
      colors: colors ?? this.colors,
      canvas: canvas ?? this.canvas,
      company: company ?? this.company,
      logoBytes: logoBytes ?? this.logoBytes,
      watermark: watermark ?? this.watermark,
      signatureBytes: signatureBytes ?? this.signatureBytes,
      stampBytes: stampBytes ?? this.stampBytes,
      visibility: visibility ?? this.visibility,
      footer: footer ?? this.footer,
      amountInWords: amountInWords ?? this.amountInWords,
      notes: notes ?? this.notes,
    );
  }

  Map<String, dynamic> toJson() => {
    'document_type': documentType.name,
    'layout_preset': layoutPreset.name,
    'typography': {
      'font_family': typography.fontFamily, 'header_size': typography.headerSize,
      'body_size': typography.bodySize, 'title_size': typography.titleSize,
      'amount_size': typography.amountSize, 'small_size': typography.smallSize,
    },
    'colors': {
      'primary': colors.primary.toARGB32(), 'secondary': colors.secondary.toARGB32(),
      'background': colors.background.toARGB32(), 'card_background': colors.cardBackground.toARGB32(),
      'border': colors.border.toARGB32(), 'text_primary': colors.textPrimary.toARGB32(),
      'text_secondary': colors.textSecondary.toARGB32(), 'amount_text': colors.amountText.toARGB32(),
      'success': colors.success.toARGB32(), 'warning': colors.warning.toARGB32(),
      'danger': colors.danger.toARGB32(), 'table_header': colors.tableHeader.toARGB32(),
      'table_row_even': colors.tableRowEven.toARGB32(), 'table_row_odd': colors.tableRowOdd.toARGB32(),
    },
    'canvas': {'width': canvas.width, 'padding': canvas.padding, 'border_radius': canvas.borderRadius},
    'company': company.toJson(),
    'watermark': {
      'enabled': watermark.enabled, 'text': watermark.text,
      'opacity': watermark.opacity, 'rotation': watermark.rotation, 'size': watermark.size,
    },
    'visibility': _visibilityToJson(),
    'footer': {'text': footer.text, 'show_terms': footer.showTerms, 'show_powered_by': footer.showPoweredBy},
  };

  Map<String, dynamic> _visibilityToJson() => {
    'show_logo': visibility.showLogo, 'show_company_name': visibility.showCompanyName,
    'show_branch': visibility.showBranch, 'show_document_title': visibility.showDocumentTitle,
    'show_document_number': visibility.showDocumentNumber, 'show_date': visibility.showDate,
    'show_status': visibility.showStatus, 'show_amount': visibility.showAmount,
    'show_amount_in_words': visibility.showAmountInWords, 'show_party': visibility.showParty,
    'show_items': visibility.showItems, 'show_totals': visibility.showTotals,
    'show_notes': visibility.showNotes, 'show_qr': visibility.showQR,
    'show_barcode': visibility.showBarcode, 'show_signature': visibility.showSignature,
    'show_stamp': visibility.showStamp, 'show_watermark': visibility.showWatermark,
    'show_footer': visibility.showFooter,
  };

  factory DocumentConfig.fromJson(Map<String, dynamic> json) {
    final colorsJson = json['colors'] as Map<String, dynamic>?;
    final visJson = json['visibility'] as Map<String, dynamic>?;
    return DocumentConfig(
      documentType: DocumentType.values.firstWhere(
        (e) => e.name == json['document_type'], orElse: () => DocumentType.salesInvoice,
      ),
      layoutPreset: LayoutPreset.values.firstWhere(
        (e) => e.name == json['layout_preset'], orElse: () => LayoutPreset.modern,
      ),
      typography: TypographyConfig(
        fontFamily: json['typography']?['font_family'] ?? 'Cairo',
        headerSize: (json['typography']?['header_size'] as num?)?.toDouble() ?? 18,
        bodySize: (json['typography']?['body_size'] as num?)?.toDouble() ?? 11,
        titleSize: (json['typography']?['title_size'] as num?)?.toDouble() ?? 14,
        amountSize: (json['typography']?['amount_size'] as num?)?.toDouble() ?? 20,
        smallSize: (json['typography']?['small_size'] as num?)?.toDouble() ?? 9,
      ),
      colors: ThemeColorsConfig(
        primary: Color(colorsJson?['primary'] ?? 0xFFA01530),
        secondary: Color(colorsJson?['secondary'] ?? 0xFFB82040),
        background: Color(colorsJson?['background'] ?? 0xFFF5F6F7),
        cardBackground: Color(colorsJson?['card_background'] ?? 0xFFFFFFFF),
        border: Color(colorsJson?['border'] ?? 0xFFD5D8DA),
        textPrimary: Color(colorsJson?['text_primary'] ?? 0xFF1A1A1A),
        textSecondary: Color(colorsJson?['text_secondary'] ?? 0xFF5A5A5A),
        amountText: Color(colorsJson?['amount_text'] ?? 0xFFA01530),
        success: Color(colorsJson?['success'] ?? 0xFF2E7D32),
        warning: Color(colorsJson?['warning'] ?? 0xFFE65100),
        danger: Color(colorsJson?['danger'] ?? 0xFFC62828),
        tableHeader: Color(colorsJson?['table_header'] ?? 0xFFA01530),
        tableRowEven: Color(colorsJson?['table_row_even'] ?? 0xFFF8F8F8),
        tableRowOdd: Color(colorsJson?['table_row_odd'] ?? 0xFFFFFFFF),
      ),
      company: json['company'] != null
          ? CompanyInfo.fromJson(json['company'] as Map<String, dynamic>)
          : const CompanyInfo(),
      watermark: WatermarkConfig(
        enabled: json['watermark']?['enabled'] ?? false,
        text: json['watermark']?['text'] ?? 'FYONA ERP',
        opacity: (json['watermark']?['opacity'] as num?)?.toDouble() ?? 0.15,
        rotation: (json['watermark']?['rotation'] as num?)?.toDouble() ?? -30,
        size: (json['watermark']?['size'] as num?)?.toDouble() ?? 60,
      ),
      visibility: VisibilityConfig(
        showLogo: visJson?['show_logo'] ?? true,
        showCompanyName: visJson?['show_company_name'] ?? true,
        showBranch: visJson?['show_branch'] ?? true,
        showDocumentTitle: visJson?['show_document_title'] ?? true,
        showDocumentNumber: visJson?['show_document_number'] ?? true,
        showDate: visJson?['show_date'] ?? true,
        showStatus: visJson?['show_status'] ?? true,
        showAmount: visJson?['show_amount'] ?? true,
        showAmountInWords: visJson?['show_amount_in_words'] ?? true,
        showParty: visJson?['show_party'] ?? true,
        showItems: visJson?['show_items'] ?? true,
        showTotals: visJson?['show_totals'] ?? true,
        showNotes: visJson?['show_notes'] ?? true,
        showQR: visJson?['show_qr'] ?? true,
        showBarcode: visJson?['show_barcode'] ?? false,
        showSignature: visJson?['show_signature'] ?? false,
        showStamp: visJson?['show_stamp'] ?? false,
        showWatermark: visJson?['show_watermark'] ?? false,
        showFooter: visJson?['show_footer'] ?? true,
      ),
      footer: FooterConfig(
        text: json['footer']?['text'] as String?,
        showTerms: json['footer']?['show_terms'] ?? true,
        showPoweredBy: json['footer']?['show_powered_by'] ?? true,
      ),
    );
  }
}

class ReceiptItem extends Equatable {
  final String name;
  final double quantity;
  final double price;
  final double total;
  final double tax;
  final double discount;
  final String? unit;

  const ReceiptItem({
    required this.name, required this.quantity, required this.price,
    required this.total, this.tax = 0, this.discount = 0, this.unit,
  });

  @override
  List<Object?> get props => [name, quantity, price, total, tax, discount, unit];
}

class ReceiptData extends Equatable {
  final DocumentType type;
  final String documentNumber;
  final DateTime date;
  final DateTime? dueDate;
  final String? status;
  final String? referenceNumber;
  final String? partyName;
  final String? partyAddress;
  final String? partyPhone;
  final String? partyTaxNumber;
  final double subtotal;
  final double taxAmount;
  final double discountAmount;
  final double total;
  final double paid;
  final double due;
  final String? amountInWords;
  final String? notes;
  final List<ReceiptItem> items;
  final String currency;
  final String? createdBy;

  const ReceiptData({
    required this.type, required this.documentNumber, required this.date,
    this.dueDate, this.status, this.referenceNumber,
    this.partyName, this.partyAddress, this.partyPhone, this.partyTaxNumber,
    this.subtotal = 0, this.taxAmount = 0, this.discountAmount = 0,
    required this.total, this.paid = 0, this.due = 0,
    this.amountInWords, this.notes, this.items = const [],
    this.currency = 'SAR', this.createdBy,
  });

  @override
  List<Object?> get props => [
    type, documentNumber, date, dueDate, status, referenceNumber,
    partyName, partyAddress, partyPhone, partyTaxNumber,
    subtotal, taxAmount, discountAmount, total, paid, due,
    amountInWords, notes, items, currency, createdBy,
  ];
}

class TemplatePreset extends Equatable {
  final String name;
  final String description;
  final DocumentType documentType;
  final LayoutPreset layout;
  final ThemeColorsConfig colors;
  final TypographyConfig typography;
  final List<String> cardOrder;

  const TemplatePreset({
    required this.name, required this.description, required this.documentType,
    required this.layout, required this.colors, required this.typography,
    required this.cardOrder,
  });

  @override
  List<Object?> get props => [name, description, documentType, layout, colors, typography, cardOrder];
}





