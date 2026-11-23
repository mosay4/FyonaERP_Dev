import 'package:fyona_flutter/core/localization/app_localizations.dart';

class AppValidators {
  AppValidators._();

  static String? validateRequired(String? value, [String fieldName = '']) {
    if (value == null || value.trim().isEmpty) {
      if (fieldName.isEmpty) return AppLocalizations.t('required');
      return AppLocalizations.t('coreFieldRequired', {'field': fieldName});
    }
    return null;
  }

  static String? validateEmail(String? value) {
    if (value == null || value.trim().isEmpty) {
      return AppLocalizations.t('emailRequired');
    }
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    if (!emailRegex.hasMatch(value.trim())) {
      return AppLocalizations.t('invalidEmail');
    }
    return null;
  }

  static String? validatePhone(String? value) {
    if (value == null || value.trim().isEmpty) {
      return AppLocalizations.t('corePhoneRequired');
    }
    final phoneRegex = RegExp(r'^\+?[\d\s-]{7,15}$');
    if (!phoneRegex.hasMatch(value.trim())) {
      return AppLocalizations.t('invalidPhone');
    }
    return null;
  }

  static String? validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return AppLocalizations.t('corePasswordRequired');
    }
    if (value.length < 8) {
      return AppLocalizations.t('corePasswordMin8');
    }
    if (!value.contains(RegExp('[A-Z]'))) {
      return AppLocalizations.t('corePasswordUpper');
    }
    if (!value.contains(RegExp('[a-z]'))) {
      return AppLocalizations.t('corePasswordLower');
    }
    if (!value.contains(RegExp('[0-9]'))) {
      return AppLocalizations.t('corePasswordDigit');
    }
    if (!value.contains(RegExp('[!@#\$%^&*()_+=\\-\\[\\]{};:.,<>/?]'))) {
      return AppLocalizations.t('corePasswordSpecial');
    }
    return null;
  }

  static String? validateConfirmPassword(String? value, String password) {
    if (value == null || value.isEmpty) {
      return AppLocalizations.t('coreConfirmPasswordRequired');
    }
    if (value != password) {
      return AppLocalizations.t('passwordMismatch');
    }
    return null;
  }

  static String? validatePositiveNumber(String? value,
      [String fieldName = '']) {
    if (value == null || value.trim().isEmpty) {
      if (fieldName.isEmpty) return AppLocalizations.t('coreValueRequired');
      return AppLocalizations.t('coreFieldRequiredF', {'field': fieldName});
    }
    final number = double.tryParse(value.trim());
    if (number == null || number < 0) {
      return AppLocalizations.t('corePositiveNumber');
    }
    return null;
  }

  static String? validateMinLength(String? value, int minLength,
      [String fieldName = '']) {
    if (value == null || value.trim().isEmpty) {
      if (fieldName.isEmpty) return AppLocalizations.t('required');
      return AppLocalizations.t('coreFieldRequired', {'field': fieldName});
    }
    if (value.trim().length < minLength) {
      return AppLocalizations.t('coreMinLength', {'min': minLength});
    }
    return null;
  }

  static String? validateMaxLength(String? value, int maxLength,
      [String fieldName = '']) {
    if (value != null && value.trim().length > maxLength) {
      return AppLocalizations.t('coreMaxLength', {'max': maxLength});
    }
    return null;
  }
}
