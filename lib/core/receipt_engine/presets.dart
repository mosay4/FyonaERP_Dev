import 'package:flutter/material.dart';

class ThemeColors {
  const ThemeColors({
    required this.primary,
    required this.secondary,
    required this.accent,
    required this.success,
    required this.warning,
    required this.error,
    required this.background,
    required this.surface,
    required this.card,
    required this.text,
    required this.textSecondary,
    required this.border,
    required this.tableHeader,
    required this.tableRow,
    required this.tableAltRow,
  });

  final Color primary;
  final Color secondary;
  final Color accent;
  final Color success;
  final Color warning;
  final Color error;
  final Color background;
  final Color surface;
  final Color card;
  final Color text;
  final Color textSecondary;
  final Color border;
  final Color tableHeader;
  final Color tableRow;
  final Color tableAltRow;
}

class TemplateTypography {
  const TemplateTypography({
    this.headingFont,
    this.bodyFont,
    this.headingSize = 22,
    this.bodySize = 14,
    this.smallSize = 11,
    this.headingWeight = FontWeight.w700,
    this.bodyWeight = FontWeight.w400,
  });

  final String? headingFont;
  final String? bodyFont;
  final double headingSize;
  final double bodySize;
  final double smallSize;
  final FontWeight headingWeight;
  final FontWeight bodyWeight;
}

class TemplateLayout {
  const TemplateLayout({
    this.padding = 16,
    this.cardPadding = 14,
    this.itemSpacing = 8,
    this.sectionSpacing = 16,
    this.borderRadius = 8,
    this.cardBorderRadius = 10,
    this.maxWidth = 400,
  });

  final double padding;
  final double cardPadding;
  final double itemSpacing;
  final double sectionSpacing;
  final double borderRadius;
  final double cardBorderRadius;
  final double maxWidth;
}

class TemplateStyles {
  const TemplateStyles({
    this.headerStyle = 'default',
    this.cardStyle = 'default',
    this.tableStyle = 'default',
    this.footerStyle = 'default',
    this.showGradients = false,
    this.showShadows = true,
    this.showBorders = true,
    this.isRtl = true,
    this.watermarkOpacity = 0.04,
  });

  final String headerStyle;
  final String cardStyle;
  final String tableStyle;
  final String footerStyle;
  final bool showGradients;
  final bool showShadows;
  final bool showBorders;
  final bool isRtl;
  final double watermarkOpacity;
}

class TemplatePreset {
  const TemplatePreset({
    required this.name,
    required this.description,
    required this.colors,
    this.typography = const TemplateTypography(),
    this.layout = const TemplateLayout(),
    this.styles = const TemplateStyles(),
    this.isDark = false,
  });

  final String name;
  final String description;
  final ThemeColors colors;
  final TemplateTypography typography;
  final TemplateLayout layout;
  final TemplateStyles styles;
  final bool isDark;

  static const TemplatePreset modern = TemplatePreset(
    name: 'مودرن',
    description: 'خلفية داكنة مع لمسات حمراء، خطوط نظيفة وعصرية',
    isDark: true,
    colors: ThemeColors(
      primary: Color(0xFFE53935),
      secondary: Color(0xFFEF5350),
      accent: Color(0xFFFF5252),
      success: Color(0xFF66BB6A),
      warning: Color(0xFFFFA726),
      error: Color(0xFFEF5350),
      background: Color(0xFF121212),
      surface: Color(0xFF1E1E1E),
      card: Color(0xFF252525),
      text: Color(0xFFF5F5F5),
      textSecondary: Color(0xFFB0B0B0),
      border: Color(0xFF252525),
      tableHeader: Color(0xFF2A2A2A),
      tableRow: Color(0xFF1E1E1E),
      tableAltRow: Color(0xFF232323),
    ),
    typography: TemplateTypography(
      headingSize: 24,
      bodySize: 14,
      smallSize: 11,
      headingWeight: FontWeight.w800,
    ),
    layout: TemplateLayout(
      padding: 16,
      cardPadding: 14,
      itemSpacing: 10,
      sectionSpacing: 18,
      borderRadius: 8,
      cardBorderRadius: 12,
      maxWidth: 420,
    ),
    styles: TemplateStyles(
      showGradients: true,
      showShadows: true,
      showBorders: false,
    ),
  );

  static const TemplatePreset premium = TemplatePreset(
    name: 'بريميوم',
    description: 'بنفسجي مع وردي ذهبي، رأسيات أنيقة بخط serif',
    isDark: false,
    colors: ThemeColors(
      primary: Color(0xFF7B1FA2),
      secondary: Color(0xFFE91E63),
      accent: Color(0xFFFF80AB),
      success: Color(0xFF4CAF50),
      warning: Color(0xFFFF9800),
      error: Color(0xFFE91E63),
      background: Color(0xFFFDF6FF),
      surface: Color(0xFFFFF0FA),
      card: Color(0xFFFFFFFF),
      text: Color(0xFF2D0A33),
      textSecondary: Color(0xFF7A5C7E),
      border: Color(0xFFE8D5ED),
      tableHeader: Color(0xFFF3E5F5),
      tableRow: Color(0xFFFFFFFF),
      tableAltRow: Color(0xFFFDF6FF),
    ),
    typography: TemplateTypography(
      headingFont: 'Georgia',
      bodyFont: 'Cairo',
      headingSize: 26,
      bodySize: 14,
      smallSize: 11,
      headingWeight: FontWeight.w600,
    ),
    layout: TemplateLayout(
      padding: 20,
      cardPadding: 16,
      itemSpacing: 10,
      sectionSpacing: 20,
      borderRadius: 10,
      cardBorderRadius: 14,
      maxWidth: 420,
    ),
    styles: TemplateStyles(
      headerStyle: 'elegant',
      cardStyle: 'elevated',
      showGradients: true,
      showShadows: true,
      watermarkOpacity: 0.06,
    ),
  );

  static const TemplatePreset invoicePro = TemplatePreset(
    name: 'فاتورة احترافية',
    description: 'أزرق احترافي مع شريط برتقالي علوي، مثالي للشركات',
    isDark: false,
    colors: ThemeColors(
      primary: Color(0xFF1565C0),
      secondary: Color(0xFF1976D2),
      accent: Color(0xFFFF8F00),
      success: Color(0xFF2E7D32),
      warning: Color(0xFFE65100),
      error: Color(0xFFC62828),
      background: Color(0xFFF8F9FC),
      surface: Color(0xFFF0F2F7),
      card: Color(0xFFFFFFFF),
      text: Color(0xFF1A1A2E),
      textSecondary: Color(0xFF5A5F7A),
      border: Color(0xFFD5DDEB),
      tableHeader: Color(0xFFE8EEF7),
      tableRow: Color(0xFFFFFFFF),
      tableAltRow: Color(0xFFF5F8FC),
    ),
    typography: TemplateTypography(
      headingSize: 24,
      bodySize: 13,
      smallSize: 10,
      headingWeight: FontWeight.w700,
    ),
    layout: TemplateLayout(
      padding: 18,
      cardPadding: 16,
      itemSpacing: 8,
      sectionSpacing: 18,
      borderRadius: 6,
      cardBorderRadius: 8,
      maxWidth: 420,
    ),
    styles: TemplateStyles(
      headerStyle: 'accent-bar',
      tableStyle: 'bordered',
      showShadows: false,
      showBorders: true,
    ),
  );

  static const TemplatePreset elegant = TemplatePreset(
    name: 'كلاسيكي',
    description: 'درجات كريمية دافئة، طابع كلاسيكي أنيق',
    isDark: false,
    colors: ThemeColors(
      primary: Color(0xFF8D6E63),
      secondary: Color(0xFFA1887F),
      accent: Color(0xFFBCAAA4),
      success: Color(0xFF6D8A5E),
      warning: Color(0xFFBF8C4A),
      error: Color(0xFFB75A5A),
      background: Color(0xFFFDF8F3),
      surface: Color(0xFFF9F0E8),
      card: Color(0xFFFFFCF7),
      text: Color(0xFF3E2E24),
      textSecondary: Color(0xFF7D6B5C),
      border: Color(0xFFE5D5C8),
      tableHeader: Color(0xFFF2E8DE),
      tableRow: Color(0xFFFFFCF7),
      tableAltRow: Color(0xFFFDF6EE),
    ),
    typography: TemplateTypography(
      headingFont: 'Georgia',
      headingSize: 24,
      bodySize: 14,
      smallSize: 11,
      headingWeight: FontWeight.w500,
    ),
    layout: TemplateLayout(
      padding: 22,
      cardPadding: 18,
      itemSpacing: 10,
      sectionSpacing: 20,
      borderRadius: 4,
      cardBorderRadius: 6,
      maxWidth: 400,
    ),
    styles: TemplateStyles(
      headerStyle: 'classic',
      cardStyle: 'bordered',
      showGradients: false,
      showShadows: false,
      showBorders: true,
      watermarkOpacity: 0.03,
    ),
  );

  static const TemplatePreset luxury = TemplatePreset(
    name: 'فاخر',
    description: 'أسود مع ذهبي، تباين عالي وفخامة',
    isDark: true,
    colors: ThemeColors(
      primary: Color(0xFFFFD700),
      secondary: Color(0xFFDAA520),
      accent: Color(0xFFFFC107),
      success: Color(0xFF9CCC65),
      warning: Color(0xFFFFB300),
      error: Color(0xFFFF6F00),
      background: Color(0xFF0D0D0D),
      surface: Color(0xFF1A1A1A),
      card: Color(0xFF222222),
      text: Color(0xFFF5E6C8),
      textSecondary: Color(0xFFA89870),
      border: Color(0xFF3A3520),
      tableHeader: Color(0xFF1E1C14),
      tableRow: Color(0xFF141414),
      tableAltRow: Color(0xFF1A1812),
    ),
    typography: TemplateTypography(
      headingFont: 'Georgia',
      headingSize: 28,
      bodySize: 14,
      smallSize: 11,
      headingWeight: FontWeight.w700,
    ),
    layout: TemplateLayout(
      padding: 20,
      cardPadding: 16,
      itemSpacing: 12,
      sectionSpacing: 22,
      borderRadius: 10,
      cardBorderRadius: 14,
      maxWidth: 400,
    ),
    styles: TemplateStyles(
      headerStyle: 'ornate',
      cardStyle: 'elevated',
      showGradients: true,
      showShadows: true,
      showBorders: true,
      watermarkOpacity: 0.08,
    ),
  );

  static const TemplatePreset apple = TemplatePreset(
    name: 'أبل',
    description: 'أبيض/رمادي فاتح، بسيط للغاية، خطوط رفيعة',
    isDark: false,
    colors: ThemeColors(
      primary: Color(0xFF000000),
      secondary: Color(0xFF252525),
      accent: Color(0xFF007AFF),
      success: Color(0xFF34C759),
      warning: Color(0xFFFF9500),
      error: Color(0xFFFF3B30),
      background: Color(0xFFF2F2F7),
      surface: Color(0xFFFFFFFF),
      card: Color(0xFFFFFFFF),
      text: Color(0xFF1C1C1E),
      textSecondary: Color(0xFF8E8E93),
      border: Color(0xFFE5E5EA),
      tableHeader: Color(0xFFF2F2F7),
      tableRow: Color(0xFFFFFFFF),
      tableAltRow: Color(0xFFF9F9FB),
    ),
    typography: TemplateTypography(
      headingFont: 'SF Pro Display',
      bodyFont: 'SF Pro Text',
      headingSize: 22,
      bodySize: 13,
      smallSize: 10,
      headingWeight: FontWeight.w600,
      bodyWeight: FontWeight.w300,
    ),
    layout: TemplateLayout(
      padding: 20,
      cardPadding: 16,
      itemSpacing: 6,
      sectionSpacing: 14,
      borderRadius: 12,
      cardBorderRadius: 14,
      maxWidth: 400,
    ),
    styles: TemplateStyles(
      headerStyle: 'minimal',
      cardStyle: 'flat',
      showGradients: false,
      showShadows: false,
      showBorders: false,
      watermarkOpacity: 0.02,
    ),
  );

  static const TemplatePreset pos = TemplatePreset(
    name: 'نقطة بيع',
    description: 'مضغوط، تباين عالي، محسن للطابعة الحرارية',
    isDark: false,
    colors: ThemeColors(
      primary: Color(0xFF212121),
      secondary: Color(0xFF424242),
      accent: Color(0xFFFF6F00),
      success: Color(0xFF2E7D32),
      warning: Color(0xFFE65100),
      error: Color(0xFFC62828),
      background: Color(0xFFFFFFFF),
      surface: Color(0xFFFAFAFA),
      card: Color(0xFFFFFFFF),
      text: Color(0xFF000000),
      textSecondary: Color(0xFF616161),
      border: Color(0xFFBDBDBD),
      tableHeader: Color(0xFFEEEEEE),
      tableRow: Color(0xFFFFFFFF),
      tableAltRow: Color(0xFFF5F5F5),
    ),
    typography: TemplateTypography(
      headingSize: 18,
      bodySize: 12,
      smallSize: 9,
      headingWeight: FontWeight.w700,
      bodyWeight: FontWeight.w500,
    ),
    layout: TemplateLayout(
      padding: 8,
      cardPadding: 6,
      itemSpacing: 4,
      sectionSpacing: 8,
      borderRadius: 2,
      cardBorderRadius: 2,
      maxWidth: 280,
    ),
    styles: TemplateStyles(
      headerStyle: 'compact',
      cardStyle: 'borderless',
      tableStyle: 'compact',
      footerStyle: 'compact',
      showGradients: false,
      showShadows: false,
      showBorders: true,
      watermarkOpacity: 0.03,
    ),
  );

  static const TemplatePreset minimal = TemplatePreset(
    name: 'بسيط',
    description: 'فائق النظافة، بلا حدود تقريباً، أقصى مسافات بيضاء',
    isDark: false,
    colors: ThemeColors(
      primary: Color(0xFF37474F),
      secondary: Color(0xFF607D8B),
      accent: Color(0xFF78909C),
      success: Color(0xFF43A047),
      warning: Color(0xFFEF6C00),
      error: Color(0xFFE53935),
      background: Color(0xFFFAFAFA),
      surface: Color(0xFFFFFFFF),
      card: Color(0xFFFFFFFF),
      text: Color(0xFF212121),
      textSecondary: Color(0xFF9E9E9E),
      border: Color(0xFFEEEEEE),
      tableHeader: Color(0xFFF5F5F5),
      tableRow: Color(0xFFFFFFFF),
      tableAltRow: Color(0xFFFAFAFA),
    ),
    typography: TemplateTypography(
      headingSize: 20,
      bodySize: 13,
      smallSize: 10,
      headingWeight: FontWeight.w300,
      bodyWeight: FontWeight.w300,
    ),
    layout: TemplateLayout(
      padding: 28,
      cardPadding: 22,
      itemSpacing: 12,
      sectionSpacing: 28,
      borderRadius: 4,
      cardBorderRadius: 4,
      maxWidth: 440,
    ),
    styles: TemplateStyles(
      headerStyle: 'minimal',
      cardStyle: 'flat',
      showGradients: false,
      showShadows: false,
      showBorders: false,
      watermarkOpacity: 0.015,
    ),
  );

  static const TemplatePreset banking = TemplatePreset(
    name: 'بنكي',
    description: 'أخضر مع داكن، موثوق ومحافظ، مناسب للبنوك',
    isDark: true,
    colors: ThemeColors(
      primary: Color(0xFF2E7D32),
      secondary: Color(0xFF388E3C),
      accent: Color(0xFF66BB6A),
      success: Color(0xFF4CAF50),
      warning: Color(0xFFFFA000),
      error: Color(0xFFD32F2F),
      background: Color(0xFF1B1F1B),
      surface: Color(0xFF242824),
      card: Color(0xFF2A2F2A),
      text: Color(0xFFE8F5E9),
      textSecondary: Color(0xFFA5D6A7),
      border: Color(0xFF2E3B2E),
      tableHeader: Color(0xFF263326),
      tableRow: Color(0xFF1D241D),
      tableAltRow: Color(0xFF212A21),
    ),
    typography: TemplateTypography(
      headingSize: 22,
      bodySize: 14,
      smallSize: 11,
      headingWeight: FontWeight.w600,
      bodyWeight: FontWeight.w400,
    ),
    layout: TemplateLayout(
      padding: 18,
      cardPadding: 14,
      itemSpacing: 8,
      sectionSpacing: 18,
      borderRadius: 6,
      cardBorderRadius: 8,
      maxWidth: 400,
    ),
    styles: TemplateStyles(
      headerStyle: 'conservative',
      cardStyle: 'bordered',
      tableStyle: 'bordered',
      showGradients: false,
      showShadows: true,
      showBorders: true,
      watermarkOpacity: 0.04,
    ),
  );

  static const TemplatePreset glass = TemplatePreset(
    name: 'زجاجي',
    description: 'تأثير الزجاج الم frosting، بطاقات شبه شفافة مع ضبابية',
    isDark: true,
    colors: ThemeColors(
      primary: Color(0xFF90CAF9),
      secondary: Color(0xFF64B5F6),
      accent: Color(0xFF42A5F5),
      success: Color(0xFF81C784),
      warning: Color(0xFFFFCC80),
      error: Color(0xFFE57373),
      background: Color(0xFF0D1117),
      surface: Color(0x1AFFFFFF),
      card: Color(0x1AFFFFFF),
      text: Color(0xFFE8F0FE),
      textSecondary: Color(0xFF90A4AE),
      border: Color(0x33FFFFFF),
      tableHeader: Color(0x1AFFFFFF),
      tableRow: Color(0x0DFFFFFF),
      tableAltRow: Color(0x1AFFFFFF),
    ),
    typography: TemplateTypography(
      headingSize: 22,
      bodySize: 14,
      smallSize: 11,
      headingWeight: FontWeight.w600,
    ),
    layout: TemplateLayout(
      padding: 18,
      cardPadding: 16,
      itemSpacing: 10,
      sectionSpacing: 20,
      borderRadius: 16,
      cardBorderRadius: 20,
      maxWidth: 420,
    ),
    styles: TemplateStyles(
      headerStyle: 'glass',
      cardStyle: 'glass',
      tableStyle: 'glass',
      footerStyle: 'glass',
      showGradients: true,
      showShadows: true,
      showBorders: false,
      watermarkOpacity: 0.05,
    ),
  );

  static const TemplatePreset corporate = TemplatePreset(
    name: 'شركات',
    description: 'أزرق نظيف، احترافي، منظم وهيكلي',
    isDark: false,
    colors: ThemeColors(
      primary: Color(0xFF1565C0),
      secondary: Color(0xFF1E88E5),
      accent: Color(0xFF42A5F5),
      success: Color(0xFF2E7D32),
      warning: Color(0xFFE65100),
      error: Color(0xFFC62828),
      background: Color(0xFFF5F7FA),
      surface: Color(0xFFEBEFF5),
      card: Color(0xFFFFFFFF),
      text: Color(0xFF1A2332),
      textSecondary: Color(0xFF5A6A7E),
      border: Color(0xFFCFD8E6),
      tableHeader: Color(0xFFE3EAF3),
      tableRow: Color(0xFFFFFFFF),
      tableAltRow: Color(0xFFF4F7FB),
    ),
    typography: TemplateTypography(
      headingSize: 22,
      bodySize: 13,
      smallSize: 10,
      headingWeight: FontWeight.w700,
    ),
    layout: TemplateLayout(
      padding: 18,
      cardPadding: 14,
      itemSpacing: 8,
      sectionSpacing: 16,
      borderRadius: 4,
      cardBorderRadius: 6,
      maxWidth: 420,
    ),
    styles: TemplateStyles(
      headerStyle: 'structured',
      tableStyle: 'lined',
      showGradients: false,
      showShadows: false,
      showBorders: true,
    ),
  );

  static const TemplatePreset executive = TemplatePreset(
    name: 'تنفيذي',
    description: 'أزرق داكن مع ذهبي، طابع تنفيذي فاخر',
    isDark: true,
    colors: ThemeColors(
      primary: Color(0xFFC5A55A),
      secondary: Color(0xFFD4B872),
      accent: Color(0xFFE8D5A3),
      success: Color(0xFF7CB342),
      warning: Color(0xFFD4A017),
      error: Color(0xFFD4726A),
      background: Color(0xFF0D1B2A),
      surface: Color(0xFF14263A),
      card: Color(0xFF1B2D42),
      text: Color(0xFFEDE7D9),
      textSecondary: Color(0xFFA8B4C0),
      border: Color(0xFF2A3F54),
      tableHeader: Color(0xFF1A3045),
      tableRow: Color(0xFF122436),
      tableAltRow: Color(0xFF162A3E),
    ),
    typography: TemplateTypography(
      headingFont: 'Georgia',
      bodyFont: 'Cairo',
      headingSize: 26,
      bodySize: 14,
      smallSize: 11,
      headingWeight: FontWeight.w700,
    ),
    layout: TemplateLayout(
      padding: 22,
      cardPadding: 18,
      itemSpacing: 12,
      sectionSpacing: 24,
      borderRadius: 6,
      cardBorderRadius: 10,
      maxWidth: 420,
    ),
    styles: TemplateStyles(
      headerStyle: 'ornate',
      cardStyle: 'elevated',
      showGradients: true,
      showShadows: true,
      showBorders: true,
      watermarkOpacity: 0.06,
    ),
  );

  static const TemplatePreset base = TemplatePreset(
    name: 'قاعدة',
    description: 'افتراضي محايد، نظيف وبسيط',
    isDark: false,
    colors: ThemeColors(
      primary: Color(0xFFA01530),
      secondary: Color(0xFFB82040),
      accent: Color(0xFFD32F2F),
      success: Color(0xFF2E7D32),
      warning: Color(0xFFE65100),
      error: Color(0xFFC62828),
      background: Color(0xFFEDEFF0),
      surface: Color(0xFFF5F6F7),
      card: Color(0xFFFFFFFF),
      text: Color(0xFF1A1A1A),
      textSecondary: Color(0xFF5A5A5A),
      border: Color(0xFFD5D8DA),
      tableHeader: Color(0xFFE8EAEB),
      tableRow: Color(0xFFFFFFFF),
      tableAltRow: Color(0xFFF2F3F5),
    ),
    typography: TemplateTypography(
      headingSize: 22,
      bodySize: 14,
      smallSize: 11,
      headingWeight: FontWeight.w700,
    ),
    layout: TemplateLayout(
      padding: 16,
      cardPadding: 14,
      itemSpacing: 8,
      sectionSpacing: 16,
      borderRadius: 8,
      cardBorderRadius: 10,
      maxWidth: 400,
    ),
    styles: TemplateStyles(
      showShadows: true,
      showBorders: true,
    ),
  );
}

class PresetRegistry {
  PresetRegistry._();

  static final Map<String, TemplatePreset> _presets = {
    'modern': TemplatePreset.modern,
    'premium': TemplatePreset.premium,
    'invoice_pro': TemplatePreset.invoicePro,
    'elegant': TemplatePreset.elegant,
    'luxury': TemplatePreset.luxury,
    'apple': TemplatePreset.apple,
    'pos': TemplatePreset.pos,
    'minimal': TemplatePreset.minimal,
    'banking': TemplatePreset.banking,
    'glass': TemplatePreset.glass,
    'corporate': TemplatePreset.corporate,
    'executive': TemplatePreset.executive,
    'base': TemplatePreset.base,
  };

  static TemplatePreset get(String name) {
    return _presets[name] ?? _presets['base']!;
  }

  static List<TemplatePreset> list() => _presets.values.toList();

  static TemplatePreset getDefault() => TemplatePreset.base;

  static Map<String, dynamic> presetToConfig(TemplatePreset preset) {
    return {
      'name': preset.name,
      'is_dark': preset.isDark,
      'colors': {
        'primary': preset.colors.primary.toARGB32(),
        'secondary': preset.colors.secondary.toARGB32(),
        'accent': preset.colors.accent.toARGB32(),
        'background': preset.colors.background.toARGB32(),
        'surface': preset.colors.surface.toARGB32(),
        'card': preset.colors.card.toARGB32(),
        'text': preset.colors.text.toARGB32(),
        'text_secondary': preset.colors.textSecondary.toARGB32(),
        'border': preset.colors.border.toARGB32(),
        'table_header': preset.colors.tableHeader.toARGB32(),
        'table_row': preset.colors.tableRow.toARGB32(),
        'table_alt_row': preset.colors.tableAltRow.toARGB32(),
        'success': preset.colors.success.toARGB32(),
        'warning': preset.colors.warning.toARGB32(),
        'error': preset.colors.error.toARGB32(),
      },
      'typography': {
        'heading_font': preset.typography.headingFont,
        'body_font': preset.typography.bodyFont,
        'heading_size': preset.typography.headingSize,
        'body_size': preset.typography.bodySize,
        'small_size': preset.typography.smallSize,
        'heading_weight': preset.typography.headingWeight.value,
        'body_weight': preset.typography.bodyWeight.value,
      },
      'layout': {
        'padding': preset.layout.padding,
        'card_padding': preset.layout.cardPadding,
        'item_spacing': preset.layout.itemSpacing,
        'section_spacing': preset.layout.sectionSpacing,
        'border_radius': preset.layout.borderRadius,
        'card_border_radius': preset.layout.cardBorderRadius,
        'max_width': preset.layout.maxWidth,
      },
      'styles': {
        'header_style': preset.styles.headerStyle,
        'card_style': preset.styles.cardStyle,
        'table_style': preset.styles.tableStyle,
        'footer_style': preset.styles.footerStyle,
        'show_gradients': preset.styles.showGradients,
        'show_shadows': preset.styles.showShadows,
        'show_borders': preset.styles.showBorders,
        'is_rtl': preset.styles.isRtl,
        'watermark_opacity': preset.styles.watermarkOpacity,
      },
    };
  }
}





