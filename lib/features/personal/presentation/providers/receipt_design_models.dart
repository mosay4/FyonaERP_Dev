import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';

enum PersonalReceiptSection {
  default_('default', 'receiptSectionDefault'),
  transfer('transfer', 'receiptSectionTransfer'),
  debt('debt', 'debtsTitle'),
  goal('goal', 'savingsGoalsTitle'),
  incomeExpense('income_expense', 'receiptSectionIncomeExpense'),
  recurring('recurring', 'receiptSectionRecurring'),
  budgetWithdrawal('budget_withdrawal', 'receiptSectionBudget');

  final String id;
  final String nameKey;
  const PersonalReceiptSection(this.id, this.nameKey);

  String get iconLabelKey {
    switch (this) {
      case PersonalReceiptSection.transfer: return 'transfer';
      case PersonalReceiptSection.debt: return 'debtsTitle';
      case PersonalReceiptSection.goal: return 'savingsGoalsTitle';
      case PersonalReceiptSection.incomeExpense: return 'deposit';
      case PersonalReceiptSection.recurring: return 'recurringTitle';
      case PersonalReceiptSection.budgetWithdrawal: return 'withdrawal';
      default: return 'receiptSectionDefault';
    }
  }
}

class ReceiptDesignPreset {
  final String sectionId;
  final Color primaryColor;
  final Color backgroundColor;
  final Color cardBackground;
  final Color textColor;
  final Color amountColor;
  final Color secondaryTextColor;
  final Color accentBarColor;
  final Color dividerColor;
  final Color successColor;
  final Color dangerColor;
  final String brandName;
  final String footerText;
  final String headerTitle;
  final bool showAccentBar;
  final bool showBrandLogo;
  final bool showSender;
  final bool showReceiver;
  final bool showReference;
  final bool showDetails;
  final bool showFooter;
  final double fontSizeScale;
  final Uint8List? logoBytes;

  const ReceiptDesignPreset({
    required this.sectionId,
    this.primaryColor = const Color(0xFFA01530),
    this.backgroundColor = const Color(0xFF0A0A0A),
    this.cardBackground = const Color(0xFF151515),
    this.textColor = const Color(0xFFFFFFFF),
    this.amountColor = const Color(0xFFA01530),
    this.secondaryTextColor = const Color(0xFFE0E0E0),
    this.accentBarColor = const Color(0xFFA01530),
    this.dividerColor = const Color(0xFF252525),
    this.successColor = const Color(0xFFA01530),
    this.dangerColor = const Color(0xFFC62828),
    this.brandName = 'FYONA',
    this.footerText = 'FYONA ERP',
    this.headerTitle = '',
    this.showAccentBar = true,
    this.showBrandLogo = true,
    this.showSender = true,
    this.showReceiver = true,
    this.showReference = true,
    this.showDetails = true,
    this.showFooter = true,
    this.fontSizeScale = 1.0,
    this.logoBytes,
  });

  static ReceiptDesignPreset defaults(String sectionId) {
    return ReceiptDesignPreset(sectionId: sectionId);
  }

  ReceiptDesignPreset copyWith({
    Color? primaryColor,
    Color? backgroundColor,
    Color? cardBackground,
    Color? textColor,
    Color? amountColor,
    Color? secondaryTextColor,
    Color? accentBarColor,
    Color? dividerColor,
    Color? successColor,
    Color? dangerColor,
    String? brandName,
    String? footerText,
    String? headerTitle,
    bool? showAccentBar,
    bool? showBrandLogo,
    bool? showSender,
    bool? showReceiver,
    bool? showReference,
    bool? showDetails,
    bool? showFooter,
    double? fontSizeScale,
    Uint8List? logoBytes,
    bool clearLogo = false,
  }) {
    return ReceiptDesignPreset(
      sectionId: sectionId,
      primaryColor: primaryColor ?? this.primaryColor,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      cardBackground: cardBackground ?? this.cardBackground,
      textColor: textColor ?? this.textColor,
      amountColor: amountColor ?? this.amountColor,
      secondaryTextColor: secondaryTextColor ?? this.secondaryTextColor,
      accentBarColor: accentBarColor ?? this.accentBarColor,
      dividerColor: dividerColor ?? this.dividerColor,
      successColor: successColor ?? this.successColor,
      dangerColor: dangerColor ?? this.dangerColor,
      brandName: brandName ?? this.brandName,
      footerText: footerText ?? this.footerText,
      headerTitle: headerTitle ?? this.headerTitle,
      showAccentBar: showAccentBar ?? this.showAccentBar,
      showBrandLogo: showBrandLogo ?? this.showBrandLogo,
      showSender: showSender ?? this.showSender,
      showReceiver: showReceiver ?? this.showReceiver,
      showReference: showReference ?? this.showReference,
      showDetails: showDetails ?? this.showDetails,
      showFooter: showFooter ?? this.showFooter,
      fontSizeScale: fontSizeScale ?? this.fontSizeScale,
      logoBytes: clearLogo ? null : (logoBytes ?? this.logoBytes),
    );
  }

  Map<String, dynamic> toJson() => {
    'section_id': sectionId,
    'primary_color': primaryColor.toARGB32(),
    'background_color': backgroundColor.toARGB32(),
    'card_background': cardBackground.toARGB32(),
    'text_color': textColor.toARGB32(),
    'amount_color': amountColor.toARGB32(),
    'secondary_text_color': secondaryTextColor.toARGB32(),
    'accent_bar_color': accentBarColor.toARGB32(),
    'divider_color': dividerColor.toARGB32(),
    'success_color': successColor.toARGB32(),
    'danger_color': dangerColor.toARGB32(),
    'brand_name': brandName,
    'footer_text': footerText,
    'header_title': headerTitle,
    'show_accent_bar': showAccentBar,
    'show_brand_logo': showBrandLogo,
    'show_sender': showSender,
    'show_receiver': showReceiver,
    'show_reference': showReference,
    'show_details': showDetails,
    'show_footer': showFooter,
    'font_size_scale': fontSizeScale,
    'logo_bytes': logoBytes != null ? base64Encode(logoBytes!) : null,
  };

  factory ReceiptDesignPreset.fromJson(Map<String, dynamic> json, String sectionId) {
    int _c(String key, int fallback) => json[key] as int? ?? fallback;
    return ReceiptDesignPreset(
      sectionId: sectionId,
      primaryColor: Color(_c('primary_color', 0xFFA01530)),
      backgroundColor: Color(_c('background_color', 0xFF0A0A0A)),
      cardBackground: Color(_c('card_background', 0xFF151515)),
      textColor: Color(_c('text_color', 0xFFFFFFFF)),
      amountColor: Color(_c('amount_color', 0xFFA01530)),
      secondaryTextColor: Color(_c('secondary_text_color', 0xFFE0E0E0)),
      accentBarColor: Color(_c('accent_bar_color', 0xFFA01530)),
      dividerColor: Color(_c('divider_color', 0xFF252525)),
      successColor: Color(_c('success_color', 0xFFA01530)),
      dangerColor: Color(_c('danger_color', 0xFFC62828)),
      brandName: json['brand_name'] as String? ?? 'FYONA',
      footerText: json['footer_text'] as String? ?? 'FYONA ERP',
      headerTitle: json['header_title'] as String? ?? '',
      showAccentBar: json['show_accent_bar'] as bool? ?? true,
      showBrandLogo: json['show_brand_logo'] as bool? ?? true,
      showSender: json['show_sender'] as bool? ?? true,
      showReceiver: json['show_receiver'] as bool? ?? true,
      showReference: json['show_reference'] as bool? ?? true,
      showDetails: json['show_details'] as bool? ?? true,
      showFooter: json['show_footer'] as bool? ?? true,
      fontSizeScale: (json['font_size_scale'] as num?)?.toDouble() ?? 1.0,
      logoBytes: json['logo_bytes'] != null ? base64Decode(json['logo_bytes'] as String) : null,
    );
  }
}

final List<PersonalReceiptSection> personalReceiptSections = PersonalReceiptSection.values;

/// Section id whose customization renders a transaction receipt, usable from
/// ANY list (home recent, transactions history, debt operations): linked
/// operations always render their own section's design — a debt operation
/// shows the debt customization even when opened from home, a goal
/// contribution shows the goal one, a budget withdrawal the budget one, a
/// transfer leg the transfer one; plain income/expense falls back to the
/// income_expense section. Link priority mirrors money ownership
/// (debt > goal > budget).
///
/// Transfer legs created inside Banks are stored as plain expense/income
/// rows, so they are detected by their transfer category (both creations
/// paths tag it) rather than by type.
String receiptSectionForTransaction({
  String? debtId,
  String? goalId,
  String? budgetId,
  String? txType,
  String? category,
}) {
  if (debtId != null && debtId.isNotEmpty) return 'debt';
  if (goalId != null && goalId.isNotEmpty) return 'goal';
  if (budgetId != null && budgetId.isNotEmpty) return 'budget_withdrawal';
  final t = (txType ?? '').toLowerCase();
  if (t.startsWith('transfer')) return 'transfer';
  final c = (category ?? '').trim().toLowerCase();
  if (c == 'تحويل' || c == 'transfer') return 'transfer';
  return 'income_expense';
}
