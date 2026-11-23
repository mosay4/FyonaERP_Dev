import 'dart:convert';
import '../localization/app_localizations.dart';

/// Renders backend-supplied bilingual notification text according to the
/// APP's CURRENT language.
///
/// Backend maintenance notifications are stored as a JSON payload
/// `{"ar": …,"en": …}` so the SAME row can be shown fully in Arabic or fully
/// in English depending on the user's app language. Any other text is
/// returned unchanged (backward compatible with every existing message).
String localizedText(String raw) {
  if (raw == null || raw.isEmpty) return raw ?? '';
  final t = raw.trim();
  if (!t.startsWith('{') || !t.endsWith('}')) return t;
  try {
    final m = jsonDecode(t) as Map<String, dynamic>;
    final ar = m['ar']?.toString();
    final en = m['en']?.toString();
    if (ar == null && en == null) return t;
    final isArabic = AppLocalizations.currentLanguage == 'ar';
    return isArabic ? (ar ?? en!) : (en ?? ar!);
  } catch (_) {
    return t;
  }
}