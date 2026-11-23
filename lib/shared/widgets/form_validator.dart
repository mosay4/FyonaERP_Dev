import 'package:flutter/material.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';

class FormValidator {
  FormValidator._();

  static String? required(String? value, [String fieldName = '']) {
    if (value == null || value.trim().isEmpty) {
      if (fieldName.isEmpty) return AppLocalizations.t('required');
      return AppLocalizations.t('coreFieldRequired', {'field': fieldName});
    }
    return null;
  }

  static String? email(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final emailRegex = RegExp(r'^[\w\.-]+@([\w-]+\.)+[\w-]{2,4}$');
    if (!emailRegex.hasMatch(value.trim())) {
      return AppLocalizations.t('invalidEmail');
    }
    return null;
  }

  static String? phone(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final phoneRegex = RegExp(r'^\+?[\d\s\-]{7,15}$');
    if (!phoneRegex.hasMatch(value.trim())) {
      return AppLocalizations.t('invalidPhone');
    }
    return null;
  }

  static String? minLength(String? value, int min, [String fieldName = '']) {
    if (value == null || value.trim().isEmpty) {
      if (fieldName.isEmpty) return AppLocalizations.t('required');
      return AppLocalizations.t('coreFieldRequired', {'field': fieldName});
    }
    if (value.trim().length < min) {
      return AppLocalizations.t('sharedMinLength', {'min': min});
    }
    return null;
  }

  static String? maxLength(String? value, int max, [String fieldName = '']) {
    if (value != null && value.trim().length > max) {
      return AppLocalizations.t('sharedMaxLength', {'max': max});
    }
    return null;
  }

  static String? passwordMatch(String? value, String password) {
    if (value == null || value.isEmpty) {
      return AppLocalizations.t('coreConfirmPasswordRequired');
    }
    if (value != password) {
      return AppLocalizations.t('passwordMismatch');
    }
    return null;
  }

  static String? positiveNumber(String? value, [String fieldName = '']) {
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

  static bool validateForm(GlobalKey<FormState> formKey) {
    return formKey.currentState?.validate() ?? false;
  }

  static void clearForm(GlobalKey<FormState> formKey) {
    formKey.currentState?.reset();
  }
}
