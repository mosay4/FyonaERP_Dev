import 'package:intl/intl.dart';
import '../services/currency/money_format_service.dart';

const Map<String, String> currencySymbols = {
  'SAR': 'ر.س',
  'USD': '\$',
  'EUR': '€',
  'GBP': '£',
  'AED': 'د.إ',
  'EGP': 'ج.م',
  'KWD': 'د.ك',
  'QAR': 'ر.ق',
  'BHD': 'د.ب',
  'OMR': 'ر.ع',
  'YER': 'ر.ي',
  'YER_OLD': 'ر.ي',
  'TRY': '₺',
  'JPY': '¥',
  'CNY': '¥',
  'INR': '₹',
  'RUB': '₽',
  'KRW': '₩',
  'CHF': 'Fr',
  'CAD': 'C\$',
  'AUD': 'A\$',
  'SEK': 'kr',
  'NOK': 'kr',
  'DKK': 'kr',
  'PLN': 'zł',
  'ZAR': 'R',
  'BRL': 'R\$',
  'MXN': 'Mex\$',
  'IQD': 'ع.د',
  'JOD': 'د.أ',
  'LBP': 'ل.ل',
  'SYP': 'ل.س',
  'SYP_NEW': 'ل.س',
  'SYP_OLD': 'ل.س',
  'IRR': '﷼',
  'PKR': 'Rs',
  'THB': '฿',
  'IDR': 'Rp',
  'MYR': 'RM',
  'PHP': '₱',
  'VND': '₫',
  'SGD': 'S\$',
  'HKD': 'HK\$',
  'TWD': 'NT\$',
  'ARS': 'AR\$',
  'CLP': 'CL\$',
  'COP': 'COL\$',
  'PEN': 'S/',
  'UAH': '₴',
  'KZT': '₸',
  'GHS': 'GH₵',
  'NGN': '₦',
  'TZS': 'TSh',
  'KES': 'KSh',
};

/// Builds a [NumberFormat] that respects the app-wide money preferences
/// (thousands separators and decimals).
NumberFormat _effectiveNumFmt() {
  final s = currentMoneyFormat;
  final decimals = s.showDecimals;
  final sep = s.useThousandsSeparator;
  final pattern = decimals ? (sep ? '#,##0.##' : '#0.##') : (sep ? '#,##0' : '#0');
  return NumberFormat(pattern, 'en');
}

String fmtNum(dynamic value) {
  final num n = value is num ? value : (num.tryParse('$value') ?? 0);
  return _effectiveNumFmt().format(n);
}

/// Exchange rates must never lose their decimals when the merchant hides
/// decimals for money; only the thousands grouping preference applies.
String fmtRate(dynamic value) {
  final num n = value is num ? value : (num.tryParse('$value') ?? 0);
  final pattern = currentMoneyFormat.useThousandsSeparator
      ? '#,##0.######'
      : '#0.######';
  return NumberFormat(pattern, 'en').format(n);
}

/// Inverse of [fmtNum]: parses a formatted amount back to a double.
///
/// `double.tryParse` chokes on the thousands separators that [fmtNum] emits
/// (e.g. "6,900"), which silently zeroed every amount ≥ 1000 — exactly why
/// YER prices (always in the thousands) lost their values while small
/// USD/SAR amounts parsed fine. Strips grouping separators (Latin comma,
/// Arabic thousands separator, spaces) and normalizes Arabic-Indic digits
/// before parsing. Returns null only when no number is present.
double? parseFormattedAmount(String? raw) {
  if (raw == null) return null;
  var s = raw.trim();
  if (s.isEmpty) return null;
  s = s.replaceAll(',', '').replaceAll('٬', '').replaceAll(' ', '').replaceAll('\u00A0', '');
  const arabicIndic = '٠١٢٣٤٥٦٧٨٩';
  const latin = '0123456789';
  for (var i = 0; i < arabicIndic.length; i++) {
    s = s.replaceAll(arabicIndic[i], latin[i]);
  }
  // Persian/Urdu digits variant.
  const persianIndic = '۰۱۲۳۴۵۶۷۸۹';
  for (var i = 0; i < persianIndic.length; i++) {
    s = s.replaceAll(persianIndic[i], latin[i]);
  }
  return double.tryParse(s);
}

/// Canonical alias normalisation: several legacy codes refer to the SAME
/// currency and must ALWAYS be displayed identically everywhere. Bare `YER`
/// is the new Yemeni rial, so it folds into `YER_NEW`.
String _normalizeCurrency(String code) {
  final c = code.trim().toUpperCase();
  switch (c) {
    case 'YER':
      return 'YER_NEW';
    default:
      return c;
  }
}

/// The COMPACT token used wherever space is tight — the ISO code itself
/// (YER_OLD, YER_NEW, SAR, USD, …). This is the ONE short form the whole app
/// uses, so the same currency can never appear as «ر.ي» here and «YER_OLD»
/// there. Full names are provided by [currencyName].
String currencyShort(String code) => currencyLabel(code);

/// The canonical code itself (YER_OLD, SAR, …) for logic, keys and APIs —
/// never shown to Arabic users.
String currencyCode(String code) => _normalizeCurrency(code);

String formatAmount(num amount, String currencyCode, {String? locale}) {
  final symbol = currencySymbol(currencyCode, locale: locale);
  final formatted = fmtNum(amount);
  return '$symbol $formatted';
}

/// The token written next to amounts in tight layouts. Returns the compact
/// ISO code ([currencyShort]) so every small-space display is identical.
String currencySymbol(String code, {String? locale}) =>
    currencyLabel(code, locale: locale);

const Map<String, String> _currencyNamesAr = {
  'USD': 'دولار أمريكي', 'EUR': 'يورو', 'SAR': 'ريال سعودي',
  'AED': 'درهم إماراتي', 'KWD': 'دينار كويتي', 'QAR': 'ريال قطري',
  'BHD': 'دينار بحريني', 'OMR': 'ريال عماني', 'EGP': 'جنيه مصري',
  'YER': 'ريال يمني جديد', 'YER_OLD': 'ريال يمني قديم',
  'GBP': 'جنيه إسترليني', 'TRY': 'ليرة تركية', 'AFN': 'أفغاني',
  'ALL': 'ليك ألباني', 'DZD': 'دينار جزائري', 'AUD': 'دولار أسترالي',
  'CAD': 'دولار كندي', 'CNY': 'يوان صيني', 'JPY': 'ين ياباني',
  'INR': 'روبية هندية', 'KRW': 'وون كوري', 'RUB': 'روبل روسي',
  'CHF': 'فرنك سويسري', 'SEK': 'كرونا سويدية', 'NOK': 'كرونا نرويجية',
  'DKK': 'كرونا دنماركية', 'PLN': 'زلوتي بولندي', 'CZK': 'كرونا تشيكية',
  'HUF': 'فورنت مجري', 'RON': 'ليو روماني', 'BGN': 'ليف بلغاري',
  'ZAR': 'راند جنوب أفريقي', 'NGN': 'نيرة نيجيرية', 'MAD': 'درهم مغربي',
  'TND': 'دينار تونسي', 'LYD': 'دينار ليبي', 'SDG': 'جنيه سوداني',
  'IQD': 'دينار عراقي', 'JOD': 'دينار أردني', 'LBP': 'ليرة لبنانية',
  'SYP': 'ليرة سورية',
  'SYP_NEW': 'ليرة سورية جديدة',
  'SYP_OLD': 'ليرة سورية قديمة', 'ILS': 'شيكل إسرائيلي', 'IRR': 'ريال إيراني',
  'PKR': 'روبية باكستانية', 'BDT': 'تاكا بنغلاديشي', 'MYR': 'رينغيت ماليزي',
  'IDR': 'روبية إندونيسية', 'PHP': 'بيزو فلبيني', 'THB': 'بات تايلاندي',
  'VND': 'دونغ فيتنامي', 'SGD': 'دولار سنغافوري', 'HKD': 'دولار هونغ كونغ',
  'TWD': 'دولار تايواني', 'MXN': 'بيزو مكسيكي', 'BRL': 'ريال برازيلي',
  'ARS': 'بيزو أرجنتيني', 'CLP': 'بيزو تشيلي', 'COP': 'بيزو كولومبي',
  'PEN': 'سول بيروفي', 'VES': 'بوليفار فنزويلي', 'UAH': 'هريفنا أوكرانية',
  'KZT': 'تنغي كازاخستاني', 'UZS': 'سوم أوزبكي', 'AZN': 'مانات أذربيجاني',
  'GEL': 'لاري جورجي', 'AMD': 'درام أرميني', 'RSD': 'دينار صربي',
  'HRK': 'كونا كرواتية', 'ISK': 'كرونا آيسلندية', 'XOF': 'فرنك غرب أفريقي',
  'XAF': 'فرنك وسط أفريقي', 'MUR': 'روبية موريشيوس', 'ETB': 'بير إثيوبي',
  'KES': 'شلن كيني', 'TZS': 'شلن تنزاني', 'UGX': 'شلن أوغندي',
  'GHS': 'سيدي غاني', 'YER_NEW': 'ريال يمني جديد',
};

const Map<String, String> _currencyNamesEn = {
  'USD': 'US Dollar', 'EUR': 'Euro', 'SAR': 'Saudi Riyal',
  'AED': 'UAE Dirham', 'KWD': 'Kuwaiti Dinar', 'QAR': 'Qatari Riyal',
  'BHD': 'Bahraini Dinar', 'OMR': 'Omani Riyal', 'EGP': 'Egyptian Pound',
  'YER': 'New Yemeni Rial', 'YER_OLD': 'Old Yemeni Rial',
  'GBP': 'British Pound', 'TRY': 'Turkish Lira', 'AFN': 'Afghan Afghani',
  'ALL': 'Albanian Lek', 'DZD': 'Algerian Dinar', 'AUD': 'Australian Dollar',
  'CAD': 'Canadian Dollar', 'CNY': 'Chinese Yuan', 'JPY': 'Japanese Yen',
  'INR': 'Indian Rupee', 'KRW': 'South Korean Won', 'RUB': 'Russian Ruble',
  'CHF': 'Swiss Franc', 'SEK': 'Swedish Krona', 'NOK': 'Norwegian Krone',
  'DKK': 'Danish Krone', 'PLN': 'Polish Zloty', 'CZK': 'Czech Koruna',
  'HUF': 'Hungarian Forint', 'RON': 'Romanian Leu', 'BGN': 'Bulgarian Lev',
  'ZAR': 'South African Rand', 'NGN': 'Nigerian Naira', 'MAD': 'Moroccan Dirham',
  'TND': 'Tunisian Dinar', 'LYD': 'Libyan Dinar', 'SDG': 'Sudanese Pound',
  'IQD': 'Iraqi Dinar', 'JOD': 'Jordanian Dinar', 'LBP': 'Lebanese Pound',
  'SYP': 'Syrian Pound',
  'SYP_NEW': 'New Syrian Pound',
  'SYP_OLD': 'Old Syrian Pound', 'ILS': 'Israeli Shekel', 'IRR': 'Iranian Rial',
  'PKR': 'Pakistani Rupee', 'BDT': 'Bangladeshi Taka', 'MYR': 'Malaysian Ringgit',
  'IDR': 'Indonesian Rupiah', 'PHP': 'Philippine Peso', 'THB': 'Thai Baht',
  'VND': 'Vietnamese Dong', 'SGD': 'Singapore Dollar', 'HKD': 'Hong Kong Dollar',
  'TWD': 'Taiwan Dollar', 'MXN': 'Mexican Peso', 'BRL': 'Brazilian Real',
  'ARS': 'Argentine Peso', 'CLP': 'Chilean Peso', 'COP': 'Colombian Peso',
  'PEN': 'Peruvian Sol', 'VES': 'Venezuelan Bolivar', 'UAH': 'Ukrainian Hryvnia',
  'KZT': 'Kazakhstani Tenge', 'UZS': 'Uzbekistani Som', 'AZN': 'Azerbaijani Manat',
  'GEL': 'Georgian Lari', 'AMD': 'Armenian Dram', 'RSD': 'Serbian Dinar',
  'HRK': 'Croatian Kuna', 'ISK': 'Icelandic Krona', 'XOF': 'West African Franc',
  'XAF': 'Central African Franc', 'MUR': 'Mauritian Rupee', 'ETB': 'Ethiopian Birr',
  'KES': 'Kenyan Shilling', 'TZS': 'Tanzanian Shilling', 'UGX': 'Ugandan Shilling',
  'GHS': 'Ghanaian Cedi', 'YER_NEW': 'New Yemeni Rial',
};

/// Whether the app has built-in localized names/symbols for [code].
bool isKnownCurrency(String code) {
  final c = _normalizeCurrency(code);
  return _currencyNamesAr.containsKey(c) || _currencyNamesEn.containsKey(c);
}

/// Localized full name for [code] in the current locale, or null when the
/// code is not known to the app (caller can then fall back to stored data).
String? localizedCurrencyName(String code, {String? locale}) {
  final c = _normalizeCurrency(code);
  final isAr = (locale ?? _currentLocale) == 'ar';
  final map = isAr ? _currencyNamesAr : _currencyNamesEn;
  return map[c] ?? map[code.trim().toUpperCase()];
}

/// Full currency name in the current app locale (falls back to the compact
/// code). Arabic mode returns the full Arabic name (e.g. دولار أمريكي، ريال
/// سعودي، ريال يمني قديم); English mode returns the full English name.
String currencyName(String code, {String? locale}) {
  // English shows the plain code everywhere (USD, YER_OLD, YER_NEW, SAR).
  if ((locale ?? _currentLocale) != 'ar') return _normalizeCurrency(code);
  return localizedCurrencyName(code, locale: 'ar') ?? _normalizeCurrency(code);
}

/// The SINGLE localized label shown in pickers/lists: the full Arabic name in
/// Arabic mode (e.g. ريال يمني قديم) and the compact ISO code in English mode
/// (e.g. YER_OLD) — never the duplicated «CODE - name» pair.
String currencyLabel(String code, {String? locale}) {
  final isAr = (locale ?? _currentLocale) == 'ar';
  return isAr
      ? (localizedCurrencyName(code, locale: 'ar') ?? _normalizeCurrency(code))
      : _normalizeCurrency(code);
}

/// ISO country (alpha-2) per currency code — used to render the flag.
const Map<String, String> _currencyFlagCountry = {
  'USD': 'US', 'EUR': 'EU', 'SAR': 'SA', 'AED': 'AE', 'KWD': 'KW',
  'QAR': 'QA', 'BHD': 'BH', 'OMR': 'OM', 'EGP': 'EG', 'YER': 'YE',
  'YER_NEW': 'YE', 'YER_OLD': 'YE', 'GBP': 'GB', 'TRY': 'TR', 'AFN': 'AF',
  'ALL': 'AL', 'DZD': 'DZ', 'AUD': 'AU', 'CAD': 'CA', 'CNY': 'CN',
  'JPY': 'JP', 'INR': 'IN', 'KRW': 'KR', 'RUB': 'RU', 'CHF': 'CH',
  'SEK': 'SE', 'NOK': 'NO', 'DKK': 'DK', 'PLN': 'PL', 'CZK': 'CZ',
  'HUF': 'HU', 'RON': 'RO', 'BGN': 'BG', 'ZAR': 'ZA', 'NGN': 'NG',
  'MAD': 'MA', 'TND': 'TN', 'LYD': 'LY', 'SDG': 'SD', 'IQD': 'IQ',
  'JOD': 'JO', 'LBP': 'LB', 'SYP': 'SY', 'SYP_NEW': 'SY', 'SYP_OLD': 'SY',
  'ILS': 'IL', 'IRR': 'IR', 'PKR': 'PK', 'BDT': 'BD', 'MYR': 'MY',
  'IDR': 'ID', 'PHP': 'PH', 'THB': 'TH', 'VND': 'VN', 'SGD': 'SG',
  'HKD': 'HK', 'TWD': 'TW', 'MXN': 'MX', 'BRL': 'BR', 'ARS': 'AR',
  'CLP': 'CL', 'COP': 'CO', 'PEN': 'PE', 'VES': 'VE', 'UAH': 'UA',
  'KZT': 'KZ', 'UZS': 'UZ', 'AZN': 'AZ', 'GEL': 'GE', 'AMD': 'AM',
  'RSD': 'RS', 'HRK': 'HR', 'ISK': 'IS', 'XOF': 'SN', 'XAF': 'CM',
  'MUR': 'MU', 'ETB': 'ET', 'KES': 'KE', 'TZS': 'TZ', 'UGX': 'UG',
  'GHS': 'GH',
};

/// Regional-indicator flag emoji for a currency code, or '' when the currency
/// has no mapped country (callers fall back to a neutral glyph).
String currencyFlagEmoji(String code) {
  final iso = _currencyFlagCountry[_normalizeCurrency(code)] ??
      _currencyFlagCountry[code.trim().toUpperCase()] ??
      '';
  if (iso.length != 2) return '';
  return String.fromCharCodes(
      [iso.codeUnitAt(0) + 127397, iso.codeUnitAt(1) + 127397]);
}

/// App-wide locale used as the default for [currencySymbol] when no explicit
/// locale is passed. Updated from [FYONAApp] whenever the user changes language.
String _currentLocale = 'ar';

/// The current app language code ('ar' | 'en').
String get appLocale => _currentLocale;

void setCurrentLocale(String languageCode) {
  _currentLocale = languageCode;
}


String formatCurrencyRateLine(dynamic from, dynamic rate, dynamic to,
    {String? locale}) {
  final lang = locale ?? _currentLocale;
  String name(dynamic code) {
    final c = '${code ?? ''}'.toUpperCase();
    if (c == 'USD' && lang == 'ar') return 'دولار';
    return currencyLabel(c, locale: lang);
  }

  return '1 ${name(from)} = ${fmtRate(rate)} ${name(to)}';
}


double asDoubleValue(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse('$value') ?? 0;
}
