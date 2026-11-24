import '../../../../core/services/currency/enabled_currencies_service.dart';
import '../../../../core/utils/country_phone_data.dart';

/// The country of a full phone number (`+967…`, `00967…`), by the longest
/// matching calling code; null when unknown.
String? countryOfPhone(String? phone) {
  var digits = (phone ?? '').replaceAll(RegExp(r'[^0-9+]'), '');
  if (digits.startsWith('00')) digits = '+${digits.substring(2)}';
  if (!digits.startsWith('+')) return null;
  final number = digits.substring(1);
  PhoneCountry? best;
  for (final country in kPhoneCountries) {
    final code = country.cc.replaceAll('+', '');
    if (number.startsWith(code) &&
        (best == null || code.length > best.cc.length - 1)) {
      best = country;
    }
  }
  return best?.iso;
}

/// The cash currencies a Personal account starts with: its country's set
/// (from the phone the account registered with). Accounts created through
/// the new sign-up never passed the old phone screen that used to seed them,
/// so this runs when the Personal section opens. It never overrides a
/// customization the user saved, and never resurrects a removed currency.
Future<void> seedPersonalCountryCash({
  required String userId,
  required String? phone,
  required Future<void> Function(List<String> currencies, Set<String> enabled)
  ensure,
}) async {
  final iso = countryOfPhone(phone);
  if (iso == null || userId.trim().isEmpty) return;
  await ensureCountryDefaults(iso, userId);
  final enabled = await loadEnabledCurrencies(userId);
  await ensure(defaultCurrenciesForCountry(iso), enabled);
}
