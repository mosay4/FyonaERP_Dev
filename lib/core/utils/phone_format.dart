import 'country_phone_data.dart';

/// Display a phone number with the country key FIRST and digits only:
/// `+966XXXXXXXX`. Never reversed by RTL (pair with TextDirection.ltr).
///
/// • `+967 77...` → `+96777...`
/// • `00966...`   → `+966...`
/// • `0777...`    → `+967777...` (local Yemeni leading zero)
/// • `9665...`    → `+9665...`
String formatIntlPhone(String raw) {
  var s = raw.replaceAll(RegExp(r'[^0-9+]'), '');
  if (s.isEmpty) return '';
  if (s.startsWith('00')) s = '+${s.substring(2)}';
  if (s.startsWith('+')) return s;
  if (s.startsWith('0')) return '+967${s.substring(1)}';
  return '+$s';
}

/// `+967****880` — country key first, then the last 3 digits, masked.
String maskIntlPhone(String raw) {
  var s = formatIntlPhone(raw);
  if (!s.startsWith('+')) return s;
  final digits = s.substring(1);
  var cc = '';
  for (final c in kPhoneCountries) {
    final code = c.cc.replaceAll('+', '');
    if (digits.startsWith(code) && code.length > cc.length) cc = code;
  }
  final rest = cc.isEmpty ? digits : digits.substring(cc.length);
  final last3 = rest.length <= 3 ? rest : rest.substring(rest.length - 3);
  return '+$cc****$last3';
}
