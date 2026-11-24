import 'country_phone_data.dart';

/// Mobile numbering plan of a country: how many digits a mobile number has
/// after the country code (without the national trunk 0) and the leading
/// digits the country's mobile operators use.
class MobilePlan {
  const MobilePlan(this.lengths, this.prefixes);

  /// Allowed lengths of the national number (most countries: one).
  final Set<int> lengths;

  /// Operator prefixes; empty = any start is valid.
  final List<String> prefixes;

  int get maxLength => lengths.reduce((a, b) => a > b ? a : b);
}

/// Mobile plans per ISO country (operators' current ranges).
const Map<String, MobilePlan> kMobilePlans = {
  // Arab countries
  'YE': MobilePlan({9}, ['70', '71', '73', '77', '78']),
  'SA': MobilePlan({9}, ['50', '51', '53', '54', '55', '56', '57', '58', '59']),
  'AE': MobilePlan({9}, ['50', '52', '54', '55', '56', '58']),
  'KW': MobilePlan({8}, ['4', '5', '6', '9']),
  'QA': MobilePlan({8}, ['3', '5', '6', '7']),
  'BH': MobilePlan({8}, ['3', '6']),
  'OM': MobilePlan({8}, ['7', '9']),
  'JO': MobilePlan({9}, ['77', '78', '79']),
  'LB': MobilePlan({7, 8}, ['3', '70', '71', '76', '78', '79', '81']),
  'IQ': MobilePlan({10}, ['75', '77', '78', '79']),
  'SY': MobilePlan({9}, ['93', '94', '95', '96', '98', '99']),
  'PS': MobilePlan({9}, ['56', '59']),
  'EG': MobilePlan({10}, ['10', '11', '12', '15']),
  'MA': MobilePlan({9}, ['6', '7']),
  'TN': MobilePlan({8}, ['2', '4', '5', '9']),
  'DZ': MobilePlan({9}, ['5', '6', '7']),
  'LY': MobilePlan({9}, ['91', '92', '93', '94', '95']),
  'SD': MobilePlan({9}, ['90', '91', '92', '96', '99', '11', '12']),
  'DJ': MobilePlan({8}, ['77']),
  'SO': MobilePlan({8, 9}, ['6', '7', '9']),
  'KM': MobilePlan({7}, ['3', '4']),
  'MR': MobilePlan({8}, ['2', '3', '4']),
  // Africa
  'CM': MobilePlan({9}, ['6']),
  'NG': MobilePlan({10}, ['70', '80', '81', '90', '91']),
  'GH': MobilePlan({9}, ['2', '5']),
  'KE': MobilePlan({9}, ['1', '7']),
  'ET': MobilePlan({9}, ['7', '9']),
  'TZ': MobilePlan({9}, ['6', '7']),
  'ZA': MobilePlan({9}, ['6', '7', '8']),
  // Asia
  'TR': MobilePlan({10}, ['5']),
  'IN': MobilePlan({10}, ['6', '7', '8', '9']),
  'PK': MobilePlan({10}, ['3']),
  'BD': MobilePlan({10}, ['1']),
  'LK': MobilePlan({9}, ['7']),
  'NP': MobilePlan({10}, ['97', '98']),
  'AF': MobilePlan({9}, ['7']),
  'IR': MobilePlan({10}, ['9']),
  'TH': MobilePlan({9}, ['6', '8', '9']),
  'ID': MobilePlan({9, 10, 11, 12}, ['8']),
  'MY': MobilePlan({9, 10}, ['1']),
  'PH': MobilePlan({10}, ['9']),
  'VN': MobilePlan({9}, ['3', '5', '7', '8', '9']),
  'KR': MobilePlan({9, 10}, ['1']),
  'JP': MobilePlan({10}, ['70', '80', '90']),
  'CN': MobilePlan({11}, ['1']),
  'SG': MobilePlan({8}, ['8', '9']),
  'HK': MobilePlan({8}, ['5', '6', '7', '9']),
  'TW': MobilePlan({9}, ['9']),
  // Oceania
  'AU': MobilePlan({9}, ['4']),
  'NZ': MobilePlan({8, 9, 10}, ['2']),
  // Americas
  'US': MobilePlan({10}, ['2', '3', '4', '5', '6', '7', '8', '9']),
  'CA': MobilePlan({10}, ['2', '3', '4', '5', '6', '7', '8', '9']),
  'MX': MobilePlan({10}, []),
  'BR': MobilePlan({11}, []),
  'AR': MobilePlan({10, 11}, []),
  'CO': MobilePlan({10}, ['3']),
  'CL': MobilePlan({9}, ['9']),
  'PE': MobilePlan({9}, ['9']),
  // Europe
  'GB': MobilePlan({10}, ['7']),
  'FR': MobilePlan({9}, ['6', '7']),
  'DE': MobilePlan({10, 11}, ['15', '16', '17']),
  'IT': MobilePlan({9, 10}, ['3']),
  'ES': MobilePlan({9}, ['6', '7']),
  'NL': MobilePlan({9}, ['6']),
  'BE': MobilePlan({9}, ['4']),
  'CH': MobilePlan({9}, ['7']),
  'AT': MobilePlan({10, 11, 12, 13}, ['6']),
  'SE': MobilePlan({9}, ['7']),
  'NO': MobilePlan({8}, ['4', '9']),
  'DK': MobilePlan({8}, []),
  'FI': MobilePlan({9, 10}, ['4', '5']),
  'PL': MobilePlan({9}, ['4', '5', '6', '7', '8']),
  'CZ': MobilePlan({9}, ['6', '7']),
  'RO': MobilePlan({9}, ['7']),
  'GR': MobilePlan({10}, ['69']),
  'PT': MobilePlan({9}, ['9']),
  'IE': MobilePlan({9}, ['8']),
  'RU': MobilePlan({10}, ['9']),
  'UA': MobilePlan({9}, ['3', '5', '6', '7', '9']),
};

/// The plan for a country; a lenient one built from the example mask when
/// the country is not in the table.
MobilePlan mobilePlanFor(PhoneCountry country) =>
    kMobilePlans[country.iso] ??
    MobilePlan({country.example.length}, const []);

/// The national number as typed, digits only, without a leading trunk 0.
String nationalDigits(String raw) {
  const eastern = '٠١٢٣٤٥٦٧٨٩';
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  final buffer = StringBuffer();
  for (final ch in raw.split('')) {
    final e = eastern.indexOf(ch);
    final p = persian.indexOf(ch);
    if (e >= 0) {
      buffer.write(e);
    } else if (p >= 0) {
      buffer.write(p);
    } else if (RegExp(r'[0-9]').hasMatch(ch)) {
      buffer.write(ch);
    }
  }
  var digits = buffer.toString();
  while (digits.startsWith('0')) {
    digits = digits.substring(1);
  }
  return digits;
}

/// Why [raw] is not a mobile number of [country] (null when it is valid).
/// Arabic or English message by [arabic].
String? mobileNumberProblem(
  PhoneCountry country,
  String raw, {
  bool arabic = true,
}) {
  final plan = mobilePlanFor(country);
  final digits = nationalDigits(raw);
  if (digits.isEmpty) {
    return arabic ? 'اكتب رقم الهاتف' : 'Enter the phone number';
  }
  if (plan.prefixes.isNotEmpty &&
      !plan.prefixes.any(digits.startsWith) &&
      // While typing the first digit, only reject a start no operator uses.
      !(digits.length < 2 && plan.prefixes.any((p) => p.startsWith(digits)))) {
    final starts = plan.prefixes.join(' / ');
    return arabic
        ? 'الرقم غير صحيح: أرقام الجوال في هذه الدولة تبدأ بـ $starts'
        : 'Invalid number: mobile numbers in this country start with $starts';
  }
  if (!plan.lengths.contains(digits.length)) {
    final sorted = plan.lengths.toList()..sort();
    final count = sorted.join(arabic ? ' أو ' : ' or ');
    return arabic
        ? 'الرقم غير صحيح: رقم الجوال في هذه الدولة $count أرقام'
        : 'Invalid number: mobile numbers here have $count digits';
  }
  return null;
}
