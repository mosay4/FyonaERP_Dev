import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/services/section_scope.dart';
import '../../core/utils/currency_formatter.dart' show setCurrentLocale;

/// The initial locale is set in main() before runApp.
late final String _initialLang;

/// Per-section persisted languages (personal / business). The active usage
/// mode picks which one applies, so changing the language in one section never
/// affects the other.
final Map<String, String> _sectionLang = {'personal': 'ar', 'business': 'ar'};

final localeProvider =
    NotifierProvider<LocaleNotifier, Locale>(LocaleNotifier.new);

class LocaleNotifier extends Notifier<Locale> {
  AppSection _section = AppSection.business;

  @override
  Locale build() {
    _section = ref.watch(activeSectionProvider);
    final lang = _sectionLang[_section.name] ?? _initialLang;
    AppLocalizations.setStaticLanguage(lang);
    setCurrentLocale(lang);
    return Locale(lang);
  }

  AppSection get section => _section;

  Future<void> setLocale(Locale locale) async {
    state = locale;
    _sectionLang[_section.name] = locale.languageCode;
    AppLocalizations.setStaticLanguage(locale.languageCode);
    setCurrentLocale(locale.languageCode);
    await AppLocalizations.preload(locale.languageCode);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('locale_${_section.name}', locale.languageCode);
    } catch (_) {}
  }

  void toggleLocale() {
    setLocale(
      state.languageCode == 'ar' ? const Locale('en') : const Locale('ar'),
    );
  }

  bool get isArabic => state.languageCode == 'ar';
  bool get isEnglish => state.languageCode == 'en';
}

/// Called once from main() before runApp to pass the pre-loaded language.
void setInitialLocale(String lang) {
  _initialLang = lang;
  _sectionLang['personal'] = lang;
  _sectionLang['business'] = lang;
}

/// Called from main() with the persisted per-section languages (when present).
void setInitialSectionLocales({String? personal, String? business}) {
  if (personal == 'ar' || personal == 'en') {
    _sectionLang['personal'] = personal!;
  }
  if (business == 'ar' || business == 'en') {
    _sectionLang['business'] = business!;
  }
}
