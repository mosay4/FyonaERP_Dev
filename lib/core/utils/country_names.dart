/// Shared country names (Arabic / English) keyed by ISO code.
/// Used by every country picker so geographic names follow the app language.
/// NOTE: these are reference data (like currency names), not user content.
const Map<String, String> _countryNamesAr = {
  'YE': 'اليمن', 'SA': 'السعودية', 'AE': 'الإمارات', 'KW': 'الكويت',
  'QA': 'قطر', 'BH': 'البحرين', 'OM': 'عمان', 'JO': 'الأردن',
  'LB': 'لبنان', 'IQ': 'العراق', 'SY': 'سوريا', 'PS': 'فلسطين',
  'EG': 'مصر', 'TR': 'تركيا', 'MA': 'المغرب', 'TN': 'تونس',
  'DZ': 'الجزائر', 'LY': 'ليبيا', 'SD': 'السودان', 'DJ': 'جيبوتي',
  'SO': 'الصومال', 'KM': 'جزر القمر', 'MR': 'موريتانيا', 'CM': 'الكاميرون',
  'NG': 'نيجيريا', 'GH': 'غانا', 'KE': 'كينيا', 'ET': 'إثيوبيا',
  'TZ': 'تنزانيا', 'ZA': 'جنوب أفريقيا', 'IN': 'الهند', 'PK': 'باكستان',
  'BD': 'بنغلاديش', 'LK': 'سريلانكا', 'NP': 'نيبال', 'AF': 'أفغانستان',
  'IR': 'إيران', 'TH': 'تايلاند', 'ID': 'إندونيسيا', 'MY': 'ماليزيا',
  'PH': 'الفلبين', 'VN': 'فيتنام', 'KR': 'كوريا الجنوبية', 'JP': 'اليابان',
  'CN': 'الصين', 'SG': 'سنغافورة', 'HK': 'هونغ كونغ', 'TW': 'تايوان',
  'AU': 'أستراليا', 'NZ': 'نيوزيلندا', 'US': 'الولايات المتحدة',
  'CA': 'كندا', 'GB': 'بريطانيا', 'FR': 'فرنسا', 'DE': 'ألمانيا',
  'IT': 'إيطاليا', 'ES': 'إسبانيا', 'NL': 'هولندا', 'BE': 'بلجيكا',
  'CH': 'سويسرا', 'AT': 'النمسا', 'SE': 'السويد', 'NO': 'النرويج',
  'DK': 'الدنمارك', 'FI': 'فنلندا', 'PL': 'بولندا', 'CZ': 'التشيك',
  'RO': 'رومانيا', 'GR': 'اليونان', 'PT': 'البرتغال', 'IE': 'أيرلندا',
  'RU': 'روسيا', 'UA': 'أوكرانيا', 'BR': 'البرازيل', 'MX': 'المكسيك',
  'AR': 'الأرجنتين', 'CO': 'كولومبيا', 'CL': 'تشيلي', 'PE': 'بيرو',
};

const Map<String, String> _countryNamesEn = {
  'YE': 'Yemen', 'SA': 'Saudi Arabia', 'AE': 'United Arab Emirates',
  'KW': 'Kuwait', 'QA': 'Qatar', 'BH': 'Bahrain', 'OM': 'Oman',
  'JO': 'Jordan', 'LB': 'Lebanon', 'IQ': 'Iraq', 'SY': 'Syria',
  'PS': 'Palestine', 'EG': 'Egypt', 'TR': 'Turkey', 'MA': 'Morocco',
  'TN': 'Tunisia', 'DZ': 'Algeria', 'LY': 'Libya', 'SD': 'Sudan',
  'DJ': 'Djibouti', 'SO': 'Somalia', 'KM': 'Comoros', 'MR': 'Mauritania',
  'CM': 'Cameroon', 'NG': 'Nigeria', 'GH': 'Ghana', 'KE': 'Kenya',
  'ET': 'Ethiopia', 'TZ': 'Tanzania', 'ZA': 'South Africa', 'IN': 'India',
  'PK': 'Pakistan', 'BD': 'Bangladesh', 'LK': 'Sri Lanka', 'NP': 'Nepal',
  'AF': 'Afghanistan', 'IR': 'Iran', 'TH': 'Thailand', 'ID': 'Indonesia',
  'MY': 'Malaysia', 'PH': 'Philippines', 'VN': 'Vietnam',
  'KR': 'South Korea', 'JP': 'Japan', 'CN': 'China', 'SG': 'Singapore',
  'HK': 'Hong Kong', 'TW': 'Taiwan', 'AU': 'Australia', 'NZ': 'New Zealand',
  'US': 'United States', 'CA': 'Canada', 'GB': 'United Kingdom',
  'FR': 'France', 'DE': 'Germany', 'IT': 'Italy', 'ES': 'Spain',
  'NL': 'Netherlands', 'BE': 'Belgium', 'CH': 'Switzerland',
  'AT': 'Austria', 'SE': 'Sweden', 'NO': 'Norway', 'DK': 'Denmark',
  'FI': 'Finland', 'PL': 'Poland', 'CZ': 'Czechia', 'RO': 'Romania',
  'GR': 'Greece', 'PT': 'Portugal', 'IE': 'Ireland', 'RU': 'Russia',
  'UA': 'Ukraine', 'BR': 'Brazil', 'MX': 'Mexico', 'AR': 'Argentina',
  'CO': 'Colombia', 'CL': 'Chile', 'PE': 'Peru',
};

/// Country display name in the requested language (falls back to the ISO).
String countryName(String iso, {bool isAr = true}) {
  final map = isAr ? _countryNamesAr : _countryNamesEn;
  return map[iso] ?? iso;
}
