/// Phone numbering data per country: ISO code, calling code and an example
/// national-number mask shown as the phone input hint.
///
/// The mask uses the country's mobile leading digit(s) followed by `x`
/// placeholders (Yemen style: `7xxxxxxxx`). Countries without a fixed
/// mobile prefix (e.g. NANP +1) use all `x`s. Masks are hints only —
/// validation stays lenient on purpose.
class PhoneCountry {
  final String iso;
  final String cc;
  final String example;
  const PhoneCountry(this.iso, this.cc, this.example);
}

const List<PhoneCountry> kPhoneCountries = [
  PhoneCountry('YE', '+967', '7xxxxxxxx'),
  PhoneCountry('SA', '+966', '5xxxxxxxx'),
  PhoneCountry('AE', '+971', '5xxxxxxxx'),
  PhoneCountry('KW', '+965', '9xxxxxxx'),
  PhoneCountry('QA', '+974', '5xxxxxxx'),
  PhoneCountry('BH', '+973', '3xxxxxxx'),
  PhoneCountry('OM', '+968', '9xxxxxxx'),
  PhoneCountry('JO', '+962', '7xxxxxxxx'),
  PhoneCountry('LB', '+961', '7xxxxxxx'),
  PhoneCountry('IQ', '+964', '7xxxxxxxxx'),
  PhoneCountry('SY', '+963', '9xxxxxxxx'),
  PhoneCountry('PS', '+970', '5xxxxxxxx'),
  PhoneCountry('EG', '+20', '1xxxxxxxxx'),
  PhoneCountry('TR', '+90', '5xxxxxxxxx'),
  PhoneCountry('MA', '+212', '6xxxxxxxx'),
  PhoneCountry('TN', '+216', '2xxxxxxx'),
  PhoneCountry('DZ', '+213', '5xxxxxxxx'),
  PhoneCountry('LY', '+218', '9xxxxxxxx'),
  PhoneCountry('SD', '+249', '9xxxxxxxx'),
  PhoneCountry('DJ', '+253', '77xxxxxx'),
  PhoneCountry('SO', '+252', '6xxxxxxxx'),
  PhoneCountry('KM', '+269', '3xxxxxx'),
  PhoneCountry('MR', '+222', '2xxxxxxx'),
  PhoneCountry('CM', '+237', '6xxxxxxxx'),
  PhoneCountry('NG', '+234', '8xxxxxxxxx'),
  PhoneCountry('GH', '+233', '2xxxxxxxx'),
  PhoneCountry('KE', '+254', '7xxxxxxxx'),
  PhoneCountry('ET', '+251', '9xxxxxxxx'),
  PhoneCountry('TZ', '+255', '7xxxxxxxx'),
  PhoneCountry('ZA', '+27', '8xxxxxxxx'),
  PhoneCountry('IN', '+91', '9xxxxxxxxx'),
  PhoneCountry('PK', '+92', '3xxxxxxxxx'),
  PhoneCountry('BD', '+880', '1xxxxxxxxx'),
  PhoneCountry('LK', '+94', '7xxxxxxxx'),
  PhoneCountry('NP', '+977', '98xxxxxxxx'),
  PhoneCountry('AF', '+93', '7xxxxxxxx'),
  PhoneCountry('IR', '+98', '9xxxxxxxxx'),
  PhoneCountry('TH', '+66', '8xxxxxxxx'),
  PhoneCountry('ID', '+62', '8xxxxxxxxx'),
  PhoneCountry('MY', '+60', '1xxxxxxxx'),
  PhoneCountry('PH', '+63', '9xxxxxxxxx'),
  PhoneCountry('VN', '+84', '9xxxxxxxx'),
  PhoneCountry('KR', '+82', '10xxxxxxxx'),
  PhoneCountry('JP', '+81', '90xxxxxxxx'),
  PhoneCountry('CN', '+86', '1xxxxxxxxxx'),
  PhoneCountry('SG', '+65', '8xxxxxxx'),
  PhoneCountry('HK', '+852', '9xxxxxxx'),
  PhoneCountry('TW', '+886', '9xxxxxxxx'),
  PhoneCountry('AU', '+61', '4xxxxxxxx'),
  PhoneCountry('NZ', '+64', '2xxxxxxxx'),
  PhoneCountry('US', '+1', 'xxxxxxxxxx'),
  PhoneCountry('CA', '+1', 'xxxxxxxxxx'),
  PhoneCountry('GB', '+44', '7xxxxxxxxx'),
  PhoneCountry('FR', '+33', '6xxxxxxxx'),
  PhoneCountry('DE', '+49', '15xxxxxxxx'),
  PhoneCountry('IT', '+39', '3xxxxxxxxx'),
  PhoneCountry('ES', '+34', '6xxxxxxxx'),
  PhoneCountry('NL', '+31', '6xxxxxxxx'),
  PhoneCountry('BE', '+32', '4xxxxxxxx'),
  PhoneCountry('CH', '+41', '7xxxxxxxx'),
  PhoneCountry('AT', '+43', '6xxxxxxxxx'),
  PhoneCountry('SE', '+46', '7xxxxxxxx'),
  PhoneCountry('NO', '+47', '9xxxxxxx'),
  PhoneCountry('DK', '+45', '2xxxxxxx'),
  PhoneCountry('FI', '+358', '4xxxxxxxx'),
  PhoneCountry('PL', '+48', '5xxxxxxxx'),
  PhoneCountry('CZ', '+420', '6xxxxxxxx'),
  PhoneCountry('RO', '+40', '7xxxxxxxx'),
  PhoneCountry('GR', '+30', '6xxxxxxxxx'),
  PhoneCountry('PT', '+351', '9xxxxxxxx'),
  PhoneCountry('IE', '+353', '8xxxxxxxx'),
  PhoneCountry('RU', '+7', '9xxxxxxxxx'),
  PhoneCountry('UA', '+380', '9xxxxxxxx'),
  PhoneCountry('BR', '+55', '9xxxxxxxxx'),
  PhoneCountry('MX', '+52', 'xxxxxxxxxx'),
  PhoneCountry('AR', '+54', 'xxxxxxxxxx'),
  PhoneCountry('CO', '+57', '3xxxxxxxxx'),
  PhoneCountry('CL', '+56', '9xxxxxxxx'),
  PhoneCountry('PE', '+51', '9xxxxxxxx'),
];

/// Example mask for [iso] (case-insensitive); generic fallback for unknown.
String phoneExampleForCountry(String iso) {
  final key = iso.trim().toUpperCase();
  for (final c in kPhoneCountries) {
    if (c.iso == key) return c.example;
  }
  return 'xxxxxxxx';
}
