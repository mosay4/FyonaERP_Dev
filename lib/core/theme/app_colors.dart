import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  /// Drives the mode-aware palette getters below ([background], [surface],
  /// [textPrimary], ...). Synced from the app [ThemeMode] by the theme
  /// provider and the app root — every widget rebuild then re-reads the
  /// correct palette, so toggling dark/light repaints the whole app.
  /// Brand/semantic colors stay identical in both modes.
  static bool _isLight = false;
  static bool get isLightMode => _isLight;
  static void setLightMode(bool value) => _isLight = value;

  // ── Core Palette (identical in both modes) ──
  static const Color primary = Color(0xFFA01530);
  static const Color primaryLight = Color(0xFFB82040);
  static const Color primaryDark = Color(0xFF7A1020);

  // ── Background & Surface (mode-aware) ──
  static Color get background => _isLight ? backgroundLight : _backgroundDark;
  static const Color _backgroundDark = Color(0xFF0A0A0A);
  static Color get surface => _isLight ? surfaceLight : _surfaceDark;
  static const Color _surfaceDark = Color(0xFF151515);
  static Color get surfaceVariant => _isLight ? surfaceVariantLight : _surfaceVariantDark;
  static const Color _surfaceVariantDark = Color(0xFF1E1E1E);
  static Color get border => _isLight ? borderLight : _borderDark;
  static const Color _borderDark = Color(0xFF252525);

  static const Color backgroundLight = Color(0xFFE7EAED);
  static const Color surfaceLight = Color(0xFFF0F2F4);
  static const Color surfaceVariantLight = Color(0xFFE2E6E9);
  static const Color borderLight = Color(0xFFCBD1D6);

  // ── Divider (mode-aware) ──
  static Color get divider => _isLight ? dividerLight : _dividerDark;
  static const Color _dividerDark = Color(0xFF2A2A2A);
  static const Color dividerLight = Color(0xFFE1E4E6);

  // ── Chart & Analytics ──
  static const Color chartCyan = Color(0xFF00BCD4);
  static const Color chartGreen = Color(0xFF22c55e);
  static const Color chartRed = Color(0xFFef4444);

  // ── Semantic ──
  static const Color success = Color(0xFF2E7D32);
  static const Color warning = Color(0xFFE65100);
  static const Color danger = Color(0xFFC62828);
  static const Color info = Color(0xFF1565C0);
  static const Color gold = Color(0xFFFFD700);

  // ── Financial ──
  static const Color positiveAmount = Color(0xFF2E7D32);

  // ── Text (mode-aware) ──
  static Color get textPrimary => _isLight ? textPrimaryLight : _textPrimaryDark;
  static const Color _textPrimaryDark = Color(0xFFFFFFFF);
  static Color get textSecondary => _isLight ? textSecondaryLight : _textSecondaryDark;
  static const Color _textSecondaryDark = Color(0xFFE0E0E0);
  static Color get textTertiary => _isLight ? textTertiaryLight : _textTertiaryDark;
  static const Color _textTertiaryDark = Color(0xFFBBBBBB);
  static const Color textTertiaryLight = Color(0xFF5F6B72);
  static const Color textDisabled = Color(0xFF999999);
  static const Color textPlaceholder = Color(0xFF777777);

  static const Color textPrimaryLight = Color(0xFF1A1A1A);
  static const Color textSecondaryLight = Color(0xFF4A4A4A);
  static const Color textDisabledLight = Color(0xFF999999);
  static const Color textPlaceholderLight = Color(0xFFAAAAAA);

  // ── Gradients ──
  static const List<Color> gradientPrimary = [
    Color(0xFFA01530),
    Color(0xFF7A1020),
    Color(0xFF6A0E1A),
  ];

  static const List<Color> gradientCard = [
    Color(0xFFA01530),
    Color(0xFF0A0A0A),
  ];

  static const List<Color> gradientDark = [
    Color(0xFF0A0A0A),
    Color(0xFF101010),
    Color(0xFF151515),
  ];

  static const List<Color> gradientSuccess = [
    Color(0xFF11998E),
    Color(0xFF38EF7D),
  ];

  static const List<Color> gradientWarning = [
    Color(0xFFF12711),
    Color(0xFFF5AF19),
  ];

  static const List<Color> gradientInfo = [
    Color(0xFF667EEA),
    Color(0xFF764BA2),
  ];

  static const List<Color> gradientGold = [
    Color(0xFF8E6B23),
    Color(0xFFFFD700),
    Color(0xFF8E6B23),
  ];

  static const Map<String, List<Color>> cardGradients = {
    'sales': gradientInfo,
    'revenue': gradientSuccess,
    'customers': [Color(0xFF4FACFE), Color(0xFF00F2FE)],
    'invoices': [Color(0xFFF093FB), Color(0xFFF5576C)],
    'products': [Color(0xFFFA709A), Color(0xFFFEE140)],
    'expenses': [Color(0xFFA18CD1), Color(0xFFFBC2EB)],
  };

  // ── Status → Color Mapping ──
  static Color statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'paid':
      case 'active':
      case 'approved':
      case 'in':
        return success;
      case 'confirmed':
      case 'settled':
      case 'refunded':
        return info;
      case 'cancelled':
      case 'overdue':
      case 'out':
        return danger;
      case 'draft':
      case 'pending':
        return textSecondary;
      default:
        return textSecondary;
    }
  }

  // ── Account Type → Color Mapping ──
  static Color accountTypeColor(String type) {
    switch (type.toLowerCase()) {
      case 'asset':
        return success;
      case 'liability':
        return warning;
      case 'equity':
        return info;
      case 'revenue':
        return success;
      case 'expense':
        return danger;
      default:
        return textSecondary;
    }
  }
}



