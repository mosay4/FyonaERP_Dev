import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/providers/current_user_provider.dart';

/// Currencies shown in the app by default on first launch.
const List<String> defaultEnabledCurrencies = ['YER_OLD', 'YER_NEW', 'SAR', 'USD'];

/// Default currency sets per country ISO code (USD first as the universal
/// reference, then the country's home currency/currencies). Used once, right
/// after the user confirms their phone country — never overrides a set the
/// user already customized in profile preferences.
const Map<String, List<String>> countryDefaultCurrencies = {
  'YE': ['USD', 'SAR', 'YER_OLD', 'YER_NEW'],
  'SA': ['USD', 'SAR'],
  'AE': ['USD', 'AED'],
  'KW': ['USD', 'KWD'],
  'QA': ['USD', 'QAR'],
  'BH': ['USD', 'BHD'],
  'OM': ['USD', 'OMR'],
  'JO': ['USD', 'JOD'],
  'LB': ['USD', 'LBP'],
  'IQ': ['USD', 'IQD'],
  'SY': ['USD', 'SYP'],
  'PS': ['USD', 'ILS', 'JOD'],
  'EG': ['USD', 'EGP'],
  'TR': ['USD', 'TRY'],
  'MA': ['USD', 'MAD'],
  'TN': ['USD', 'TND'],
  'DZ': ['USD', 'DZD'],
  'LY': ['USD', 'LYD'],
  'SD': ['USD', 'SDG'],
  'DJ': ['USD'],
  'SO': ['USD'],
  'KM': ['USD'],
  'MR': ['USD'],
  'CM': ['USD', 'XAF'],
  'NG': ['USD', 'NGN'],
  'GH': ['USD', 'GHS'],
  'KE': ['USD', 'KES'],
  'ET': ['USD', 'ETB'],
  'TZ': ['USD', 'TZS'],
  'ZA': ['USD', 'ZAR'],
  'IN': ['USD', 'INR'],
  'PK': ['USD', 'PKR'],
  'BD': ['USD', 'BDT'],
  'LK': ['USD'],
  'NP': ['USD', 'INR'],
  'AF': ['USD', 'AFN'],
  'IR': ['USD', 'IRR'],
  'TH': ['USD', 'THB'],
  'ID': ['USD', 'IDR'],
  'MY': ['USD', 'MYR'],
  'PH': ['USD', 'PHP'],
  'VN': ['USD', 'VND'],
  'KR': ['USD', 'KRW'],
  'JP': ['USD', 'JPY'],
  'CN': ['USD', 'CNY'],
  'SG': ['USD', 'SGD'],
  'HK': ['USD', 'HKD'],
  'TW': ['USD', 'TWD'],
  'AU': ['USD', 'AUD'],
  'NZ': ['USD'],
  'US': ['USD'],
  'CA': ['USD', 'CAD'],
  'GB': ['USD', 'GBP'],
  'FR': ['USD', 'EUR'],
  'DE': ['USD', 'EUR'],
  'IT': ['USD', 'EUR'],
  'ES': ['USD', 'EUR'],
  'NL': ['USD', 'EUR'],
  'BE': ['USD', 'EUR'],
  'CH': ['USD', 'CHF'],
  'AT': ['USD', 'EUR'],
  'SE': ['USD', 'SEK'],
  'NO': ['USD', 'NOK'],
  'DK': ['USD', 'DKK'],
  'FI': ['USD', 'EUR'],
  'PL': ['USD', 'PLN'],
  'CZ': ['USD', 'CZK'],
  'RO': ['USD', 'RON'],
  'GR': ['USD', 'EUR'],
  'PT': ['USD', 'EUR'],
  'IE': ['USD', 'EUR'],
  'RU': ['USD', 'RUB'],
  'UA': ['USD', 'UAH'],
  'BR': ['USD', 'BRL'],
  'MX': ['USD', 'MXN'],
  'AR': ['USD', 'ARS'],
  'CO': ['USD', 'COP'],
  'CL': ['USD', 'CLP'],
  'PE': ['USD', 'PEN'],
};

/// Default currencies for a country (falls back to the global defaults for
/// unknown ISO codes).
List<String> defaultCurrenciesForCountry(String iso) =>
    countryDefaultCurrencies[iso.trim().toUpperCase()] ?? defaultEnabledCurrencies;

/// Saves the country's defaults for [userId] ONLY when they never customized
/// their set (no saved value). Safe to call on every phone save.
Future<void> ensureCountryDefaults(String iso, [String userId = '']) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getStringList(_currencyKey(userId)) != null) return;
    await saveEnabledCurrencies(defaultCurrenciesForCountry(iso).toSet(), userId);
  } catch (_) {}
}

/// Returns the per-user SharedPreferences key used to store the enabled set.
///
/// The key is scoped by the current user's id so that currency preferences
/// stay private to each account. When no user is signed in the global key is
/// used as a fallback (e.g. pre-login screens).
String _currencyKey(String userId) {
  final scope = userId.trim().isEmpty ? 'global' : userId;
  return 'enabled_currencies_$scope';
}

/// Preferred default currency for forms and displays: USD whenever it is
/// among the user's enabled set, otherwise the first enabled code (sorted
/// for stability), else USD as a last resort. Never throws.
Future<String> resolveDefaultCurrency([String userId = '']) async {
  try {
    final enabled = await loadEnabledCurrencies(userId);
    if (enabled.contains('USD')) return 'USD';
    if (enabled.isNotEmpty) {
      final sorted = enabled.toList()..sort();
      return sorted.first;
    }
  } catch (_) {}
  return 'USD';
}

/// Reads the user's enabled currencies from preferences.
/// Falls back to the default four when nothing was saved yet.
Future<Set<String>> loadEnabledCurrencies([String userId = '']) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getStringList(_currencyKey(userId));
  if (saved != null && saved.isNotEmpty) return saved.toSet();
  return defaultEnabledCurrencies.toSet();
}

/// Persists the enabled currencies for the given user.
Future<void> saveEnabledCurrencies(Set<String> currencies, [String userId = '']) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(_currencyKey(userId), currencies.toList());
}

/// Returns the enabled subset of a list of currency codes for the user.
Future<List<String>> filterEnabled(List<String> codes, [String userId = '']) async {
  final enabled = await loadEnabledCurrencies(userId);
  return codes.where(enabled.contains).toList();
}

Future<bool> isCurrencyEnabled(String code, [String userId = '']) async {
  final enabled = await loadEnabledCurrencies(userId);
  return enabled.contains(code);
}

/// Riverpod provider that resolves to the enabled currency set for the
/// currently signed-in user. It re-evaluates when the user changes.
final enabledCurrenciesProvider = FutureProvider.autoDispose<Set<String>>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  return loadEnabledCurrencies(userId);
});
