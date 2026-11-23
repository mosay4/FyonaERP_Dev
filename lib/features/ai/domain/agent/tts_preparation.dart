/// Text-to-Speech Preparation layer for Sara Agent.
///
/// Converts Sara's reply text into TTS-friendly spoken form, driven ONLY by
/// the current app language ([lang] = 'ar' | anything-else → 'en').
///
/// Design principles (P1):
/// - Rule-based normalization passes, never word-by-word patching and never
///   blind digit replacement (so IDs, dates, names and compounds keep meaning).
/// - Currency names come from the app's REAL currency data
///   ([localizedCurrencyName] / [currencySymbols] in
///   `core/utils/currency_formatter.dart`). Unknown codes are left untouched —
///   never invented.
/// - Amounts keep value + decimals + currency + sign. Fractions are spoken
///   digit-by-digit after "فاصلة" / "point" so the value is exact.
/// - Mixed Arabic + English + numbers text: words are never translated or
///   renamed (banks, products, brands pass through byte-identical); only
///   numbers/dates/percentages/currencies are verbalized per locale.
/// - Idempotent: running [prepare] twice yields the same string.
/// - Plain texts without numbers are unchanged (modulo pre-existing spacing).
import '../../../../core/utils/currency_formatter.dart'
    show localizedCurrencyName, currencySymbols;

class TtsPreparation {
  TtsPreparation._();

  // ── Legacy public maps (kept for backward compatibility) ────────────────

  static const Map<String, String> _arabicDigits = {
    '0': 'صفر', '1': 'واحد', '2': 'اثنان', '3': 'ثلاثة', '4': 'أربعة',
    '5': 'خمسة', '6': 'ستة', '7': 'سبعة', '8': 'ثمانية', '9': 'تسعة',
  };

  static const Map<String, String> _arabicCurrencies = {
    'SAR': 'ريال سعودي', 'USD': 'دولار أمريكي', 'EUR': 'يورو',
    'GBP': 'جنيه إسترليني', 'YER': 'ريال يمني', 'AED': 'درهم إماراتي',
    'EGP': 'جنيه مصري', 'JOD': 'دينار أردني', 'KWD': 'دينار كويتي',
  };

  static const Map<String, String> _spokenCurrencies = {
    'SAR': 'ريال', 'USD': 'دولار', 'EUR': 'يورو',
    'GBP': 'جنيه', 'YER': 'ريال', 'AED': 'درهم',
    'EGP': 'جنيه',
  };

  // ── Entry point ──────────────────────────────────────────────────────────

  /// Prepare text for TTS. Removes technical artifacts and formats naturally.
  static String prepare(String text, {String lang = 'ar'}) {
    if (text.isEmpty) return text;

    var result = text;

    // Remove JSON-like patterns
    result = result.replaceAll(RegExp(r'\{[^}]*\}'), '');
    result = result.replaceAll(RegExp(r'\[[^\]]*\]'), '');

    // Remove technical field names
    result = result.replaceAll(RegExp(r'"[a-z_]+"\s*:\s*'), '');
    result = result.replaceAll(RegExp(r'[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}'), '');

    // Remove IDs that look like integers
    result = result.replaceAll(RegExp(r'\bid[:\s]*\d+\b'), '');

    // Clean up double spaces
    result = result.replaceAll(RegExp(r'\s{2,}'), ' ').trim();

    if (lang == 'ar') {
      result = _prepareArabic(result);
    } else {
      result = _prepareEnglish(result);
    }

    return result;
  }

  /// Structured-money speech (P1, req 11): when Sara has a REAL amount +
  /// currency (tool data, invoice, balance line), speak from the structure —
  /// never by guessing digits out of a sentence. Preserves value, decimals,
  /// currency name (real app data) and sign. Unknown codes pass through.
  static String prepareMoney({
    required num amount,
    required String currencyCode,
    String lang = 'ar',
  }) {
    final code = currencyCode.trim().toUpperCase();
    final negative = amount < 0;
    final abs = negative ? -amount : amount;
    // Exact decimal digits from the value itself (no float drift for speeches).
    final parts = abs.toString().split('.');
    final intWords = _speakIntDigits(parts[0], lang: lang);
    var number = intWords;
    if (parts.length > 1) {
      final frac = parts[1].replaceAll(RegExp(r'0+$'), '');
      if (frac.isNotEmpty) {
        number = lang == 'ar'
            ? '$intWords فاصلة ${_spellDigits(frac, lang: lang)}'
            : '$intWords point ${_spellDigits(frac, lang: lang)}';
      }
    }
    final sign = negative ? (lang == 'ar' ? 'سالب ' : 'minus ') : '';
    final currency = _currencySpoken(code, lang: lang, afterAmount: true);
    return '$sign$number $currency'.trim();
  }

  // ── Shared low-level helpers ─────────────────────────────────────────────

  static const Map<String, String> _arabicIndicDigits = {
    '٠': '0', '١': '1', '٢': '2', '٣': '3', '٤': '4',
    '٥': '5', '٦': '6', '٧': '7', '٨': '8', '٩': '9',
    '۰': '0', '۱': '1', '۲': '2', '۳': '3', '۴': '4',
    '۵': '5', '۶': '6', '۷': '7', '۸': '8', '۹': '9',
  };

  /// Normalize all digit/decimal variants to plain western "1234.56".
  static String _normalizeDigits(String text) {
    var out = text;
    _arabicIndicDigits.forEach((k, v) => out = out.replaceAll(k, v));
    out = out.replaceAll('٫', '.'); // Arabic decimal separator
    out = out.replaceAll('٬', ''); // Arabic thousands separator
    return out;
  }

  /// Parse a localized numeric token exactly.
  ///
  /// Handles grouping commas ("1,000,000"), grouping dots ("1.000"),
  /// decimal commas ("19,99") and plain decimals ("19.99").
  /// Returns (integerDigits, fractionDigits?) or null when not a number.
  static _NumParts? _parseNumberToken(String raw) {
    var s = raw.replaceAll(' ', '').replaceAll('٬', '');
    if (s.isEmpty) return null;
    // European grouping dots: 1.000 / 1.000.000 (dot + exactly 3 digits).
    if (RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(s)) {
      s = s.replaceAll('.', '');
    } else if (s.contains(',') && !s.contains('.')) {
      // Single comma: "19,99"/"1,5" = decimal, "1,000" = grouping.
      final commaCount = ','.allMatches(s).length;
      if (commaCount == 1 && RegExp(r'^\d+,?\d{1,2}$').hasMatch(s)) {
        s = s.replaceFirst(',', '.');
      } else {
        s = s.replaceAll(',', '');
      }
    } else {
      s = s.replaceAll(',', '');
    }
    final m = RegExp(r'^(\d+)(?:\.(\d+))?$').firstMatch(s);
    if (m == null) return null;
    return _NumParts(m.group(1)!, m.group(2));
  }

  /// Speak an integer digit-string in [lang]; falls back to digit spelling
  /// when the value overflows int (meaning preserved, never truncated).
  static String _speakIntDigits(String digits, {required String lang}) {
    final d = digits.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    final clean = d.isEmpty ? '0' : d;
    try {
      final n = int.parse(clean);
      return lang == 'ar' ? numberToArabic(n) : numberToEnglish(n);
    } catch (_) {
      return _spellDigits(clean, lang: lang);
    }
  }

  /// Spell digits one by one ("050" → "صفر خمسة صفر"). Used for account
  /// numbers, card numbers and leading-zero tokens — never for quantities.
  static String _spellDigits(String digits, {required String lang}) {
    final buf = <String>[];
    for (final ch in digits.split('')) {
      if (lang == 'ar') {
        buf.add(_arabicDigits[ch] ?? ch);
      } else {
        buf.add(_englishOnes[ch] ?? ch);
      }
    }
    return buf.join(' ');
  }

  // ── Currency: real app data first ────────────────────────────────────────

  /// All codes the normalizer can recognize (legacy spoken list ∪ real app
  /// data keys ∪ Yemeni aliases). Matching never invents names: the SPOKEN
  /// name always comes from [_currencySpoken].
  static final Set<String> _knownCodes = {
    ..._englishCurrencies.keys,
    ..._englishCurrencySingular.keys,
    'YER_NEW', 'YER_OLD', 'VES', 'UZS', 'AZN', 'GEL', 'AMD', 'RSD', 'HRK',
    'ISK', 'XOF', 'XAF', 'MUR', 'ETB', 'BDT', 'CHF', 'SEK', 'NOK', 'DKK',
    'PLN', 'CZK', 'HUF', 'RON', 'BGN', 'AUD', 'CAD',
  };

  static String _codePattern() {
    final codes = _knownCodes.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    return codes.map(RegExp.escape).join('|');
  }

  /// symbol → code built from the app's REAL [currencySymbols]. Ambiguous or
  /// single-letter symbols (¥ = CNY/JPY, R = ZAR/…) are skipped on purpose.
  static final Map<String, String> _symbolToCode = (() {
    final rev = <String, List<String>>{};
    currencySymbols.forEach((code, sym) {
      rev.putIfAbsent(sym, () => []).add(code);
    });
    final out = <String, String>{};
    rev.forEach((sym, codes) {
      if (codes.length == 1 && sym.length > 1) out[sym] = codes.first;
    });
    // Unambiguous single-char symbols (standard, not invented).
    out[r'$'] = 'USD';
    out['€'] = 'EUR';
    out['£'] = 'GBP';
    out['₺'] = 'TRY';
    out['₹'] = 'INR';
    out['₽'] = 'RUB';
    out['₩'] = 'KRW';
    out['₫'] = 'VND';
    out['₱'] = 'PHP';
    out['₴'] = 'UAH';
    out['₸'] = 'KZT';
    out['₦'] = 'NGN';
    out['฿'] = 'THB';
    out['₵'] = 'GHS';
    return out;
  })();

  static String _symbolPattern() {
    final syms = _symbolToCode.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    return syms.map(RegExp.escape).join('|');
  }

  /// Spoken currency name from REAL app data ([localizedCurrencyName]),
  /// legacy maps as fallback, raw code as last resort (never invented).
  static String _currencySpoken(String code,
      {required String lang, required bool afterAmount}) {
    final c = code.toUpperCase();
    final real = localizedCurrencyName(c, locale: lang);
    if (real != null && real != c) {
      if (lang == 'ar' || !afterAmount) return real;
      return _pluralEnglish(c, real);
    }
    if (lang == 'ar') {
      return _arabicCurrencies[c] ?? _spokenCurrencies[c] ?? code;
    }
    return currencyToEnglish(c, afterAmount: afterAmount);
  }

  /// English plural for amount contexts ("Saudi Riyal" → "Saudi riyals").
  /// Legacy hand-checked plurals win; otherwise singular + "s" except known
  /// invariables (Yen/Yuan/Birr). Unknown codes pass through untouched.
  static String _pluralEnglish(String code, String singular) {
    final legacy = _englishCurrencies[code];
    if (legacy != null) return legacy;
    const invariable = {'JPY', 'CNY', 'ETB'};
    if (invariable.contains(code)) return singular;
    if (singular.endsWith('s')) return singular;
    return '${singular}s';
  }

  // ── Arabic ordinals (canonicalization, 1..10 m/f) ────────────────────────

  static const Map<String, String> _arabicOrdinals = {
    'اولا': 'أولًا', 'أولا': 'أولًا', 'أولاً': 'أولًا', 'اوّلًا': 'أولًا',
    'ثانيا': 'ثانيًا', 'ثانياً': 'ثانيًا',
    'ثالثا': 'ثالثًا', 'ثالثاً': 'ثالثًا',
    'رابعا': 'رابعًا', 'رابعاً': 'رابعًا',
    'خامسا': 'خامسًا', 'خامساً': 'خامسًا',
    'سادسا': 'سادسًا', 'سادساً': 'سادسًا',
    'سابعا': 'سابعًا', 'سابعاً': 'سابعًا',
    'ثامنا': 'ثامنًا', 'ثامناً': 'ثامنًا',
    'تاسعا': 'تاسعًا', 'تاسعاً': 'تاسعًا',
    'عاشرا': 'عاشرًا', 'عاشراً': 'عاشرًا',
    'اول': 'الأول', 'ثانى': 'الثاني', 'ثالث': 'الثالث', 'رابع': 'الرابع',
    'خامس': 'الخامس', 'سادس': 'السادس', 'سابع': 'السابع',
    'ثامن': 'الثامن', 'تاسع': 'التاسع', 'عاشر': 'العاشر',
  };

  // ── Months ───────────────────────────────────────────────────────────────

  static const List<String> _arMonths = [
    '', 'يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو',
    'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر',
  ];

  static const List<String> _enMonths = [
    '', 'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  static const Map<String, int> _enMonthIndex = {
    'january': 1, 'jan': 1, 'february': 2, 'feb': 2, 'march': 3, 'mar': 3,
    'april': 4, 'apr': 4, 'may': 5, 'june': 6, 'jun': 6, 'july': 7, 'jul': 7,
    'august': 8, 'aug': 8, 'september': 9, 'sep': 9, 'sept': 9,
    'october': 10, 'oct': 10, 'november': 11, 'nov': 11,
    'december': 12, 'dec': 12,
  };

  static const Map<String, String> _arMonthVariants = {
    'كانون الثاني': 'يناير', 'شباط': 'فبراير', 'آذار': 'مارس',
    'نيسان': 'أبريل', 'أيار': 'مايو', 'حزيران': 'يونيو',
    'تموز': 'يوليو', 'آب': 'أغسطس', 'أيلول': 'سبتمبر',
    'تشرين الأول': 'أكتوبر', 'تشرين الثاني': 'نوفمبر', 'كانون الأول': 'ديسمبر',
  };

  static const Map<int, String> _enOrdinals = {
    1: 'first', 2: 'second', 3: 'third', 4: 'fourth', 5: 'fifth',
    6: 'sixth', 7: 'seventh', 8: 'eighth', 9: 'ninth', 10: 'tenth',
    11: 'eleventh', 12: 'twelfth', 13: 'thirteenth', 14: 'fourteenth',
    15: 'fifteenth', 16: 'sixteenth', 17: 'seventeenth', 18: 'eighteenth',
    19: 'nineteenth', 20: 'twentieth', 21: 'twenty-first',
    22: 'twenty-second', 23: 'twenty-third', 24: 'twenty-fourth',
    25: 'twenty-fifth', 26: 'twenty-sixth', 27: 'twenty-seventh',
    28: 'twenty-eighth', 29: 'twenty-ninth', 30: 'thirtieth',
    31: 'thirty-first',
  };

  // ═══════════ Public number engines (backward compatible) ═════════════════

  /// Convert a number to Arabic spoken form (0 .. 10^21, exact decimals).
  static String numberToArabic(num number) {
    if (number == 0) return 'صفر';

    if (number is double && number != number.roundToDouble()) {
      // Exact fraction digits from the decimal representation (no *100 drift).
      final text = number.toString();
      final dot = text.indexOf('.');
      if (dot < 0) return numberToArabic(number.truncate());
      final intPart = int.tryParse(text.substring(0, dot)) ?? 0;
      final frac = text.substring(dot + 1).replaceAll(RegExp(r'0+$'), '');
      if (frac.isEmpty) return numberToArabic(intPart);
      final sign = number < 0 ? 'سالب ' : '';
      final base = numberToArabic(intPart < 0 ? -intPart : intPart);
      return '$sign$base فاصلة ${_spellDigits(frac, lang: 'ar')}';
    }

    final n = number.toInt();
    if (n < 0) return 'سالب ${numberToArabic(-n)}';
    if (n < 10) return _arabicDigits[n.toString()]!;
    if (n < 20) return _teens(n);
    if (n < 100) return _tens(n);
    if (n < 1000) return _hundreds(n);
    if (n < 1000000) return _thousands(n);
    if (n < 1000000000) return _millions(n);
    return _bigArabic(n);
  }

  /// Arabic scales ≥ 10^9: مليار / تريليون / كوادريليون / كوينتيليون.
  /// Beyond 10^21 falls back to digit spelling (value preserved).
  static String _bigArabic(int n) {
    const scales = [
      (1000000000, 'مليار', 'ملياران', 'مليارات'),
      (1000000000000, 'تريليون', 'تريليونان', 'تريليونات'),
      (1000000000000000, 'كوادريليون', 'كوادريليونان', 'كوادريليونات'),
      (1000000000000000000, 'كوينتيليون', 'كوينتيليونان', 'كوينتيليونات'),
    ];
    for (var i = scales.length - 1; i >= 0; i--) {
      final value = scales[i].$1;
      if (n >= value) {
        final count = n ~/ value;
        final remainder = n % value;
        final one = scales[i].$2, two = scales[i].$3, few = scales[i].$4;
        String head;
        if (count == 1) {
          head = one;
        } else if (count == 2) {
          head = two;
        } else if (count == 10) {
          head = 'عشرة $few';
        } else if (count < 10) {
          head = '${_arabicDigits[count.toString()]!} $few';
        } else {
          head = '${numberToArabic(count)} $one';
        }
        if (remainder == 0) return head;
        return '$head و${numberToArabic(remainder)}';
      }
    }
    return _spellDigits(n.toString(), lang: 'ar');
  }

  /// Convert amount with currency to Arabic spoken form.
  static String amountToArabic(num amount, String currency) {
    final spoken = _spokenCurrencies[currency] ?? _arabicCurrencies[currency] ?? currency;
    final number = numberToArabic(amount);
    return '$number $spoken';
  }

  static String _teens(int n) {
    if (n == 10) return 'عشرة';
    if (n == 12) return 'اثنا عشر';
    if (n == 11) return 'أحد عشر';
    if (n > 10 && n < 20) {
      final digit = n - 10;
      return '${_arabicDigits[digit.toString()]} عشر';
    }
    return n.toString();
  }

  static String _tens(int n) {
    const tens = [
      '', '', 'عشرون', 'ثلاثون', 'أربعون', 'خمسون',
      'ستون', 'سبعون', 'ثمانون', 'تسعون',
    ];
    final tensDigit = n ~/ 10;
    final onesDigit = n % 10;
    if (onesDigit == 0) return tens[tensDigit];
    return '${_arabicDigits[onesDigit.toString()]} و${tens[tensDigit]}';
  }

  static String _hundreds(int n) {
    final h = n ~/ 100;
    final remainder = n % 100;
    String hStr;
    if (h == 1) {
      hStr = 'مائة';
    } else if (h == 2) {
      hStr = 'مئتان';
    } else {
      const fused = {
        3: 'ثلاثمائة', 4: 'أربعمائة', 5: 'خمسمائة', 6: 'ستمائة',
        7: 'سبعمائة', 8: 'ثمانمائة', 9: 'تسعمائة',
      };
      hStr = fused[h]!;
    }

    if (remainder == 0) return hStr;
    return '$hStr و${numberToArabic(remainder)}';
  }

  static String _thousands(int n) {
    final th = n ~/ 1000;
    final remainder = n % 1000;
    String thStr;
    if (th == 1) {
      thStr = 'ألف';
    } else if (th == 2) {
      thStr = 'ألفان';
    } else if (th == 10) {
      thStr = 'عشرة آلاف';
    } else if (th < 10) {
      thStr = '${_arabicDigits[th.toString()]} آلاف';
    } else {
      thStr = '${numberToArabic(th)} ألف';
    }

    if (remainder == 0) return thStr;
    return '$thStr و${numberToArabic(remainder)}';
  }

  static String _millions(int n) {
    final m = n ~/ 1000000;
    final remainder = n % 1000000;
    String mStr;
    if (m == 1) {
      mStr = 'مليون';
    } else if (m == 2) {
      mStr = 'مليونان';
    } else if (m == 10) {
      mStr = 'عشرة ملايين';
    } else if (m < 10) {
      mStr = '${_arabicDigits[m.toString()]} ملايين';
    } else {
      mStr = '${numberToArabic(m)} مليون';
    }

    if (remainder == 0) return mStr;
    return '$mStr و${numberToArabic(remainder)}';
  }

  static const Map<String, String> _englishOnes = {
    '0': 'zero', '1': 'one', '2': 'two', '3': 'three', '4': 'four',
    '5': 'five', '6': 'six', '7': 'seven', '8': 'eight', '9': 'nine',
    '10': 'ten', '11': 'eleven', '12': 'twelve', '13': 'thirteen',
    '14': 'fourteen', '15': 'fifteen', '16': 'sixteen', '17': 'seventeen',
    '18': 'eighteen', '19': 'nineteen', '20': 'twenty', '30': 'thirty',
    '40': 'forty', '50': 'fifty', '60': 'sixty', '70': 'seventy',
    '80': 'eighty', '90': 'ninety',
  };

  static const List<String> _englishScale = [
    '', 'thousand', 'million', 'billion', 'trillion',
    'quadrillion', 'quintillion',
  ];

  /// English spoken forms for currency codes (plural where natural in amounts).
  static const Map<String, String> _englishCurrencies = {
    'SAR': 'Saudi riyals', 'USD': 'US dollars', 'EUR': 'euros',
    'GBP': 'pounds', 'YER': 'Yemeni rials', 'YER_OLD': 'old Yemeni rials',
    'YER_NEW': 'new Yemeni rials', 'AED': 'UAE dirhams', 'EGP': 'Egyptian pounds',
    'JOD': 'Jordanian dinars', 'KWD': 'Kuwaiti dinars', 'QAR': 'Qatari riyals',
    'BHD': 'Bahraini dinars', 'OMR': 'Omani rials', 'TRY': 'Turkish liras',
    'ILS': 'Israeli shekels', 'IQD': 'Iraqi dinars', 'LBP': 'Lebanese pounds',
    'SYP': 'Syrian pounds', 'INR': 'Indian rupees', 'PKR': 'Pakistani rupees',
    'MAD': 'Moroccan dirhams', 'TND': 'Tunisian dinars', 'LYD': 'Libyan dinars',
    'SDG': 'Sudanese pounds', 'CNY': 'Chinese yuan', 'JPY': 'yen',
    'KRW': 'South Korean won', 'THB': 'Thai baht', 'MYR': 'Malaysian ringgit',
    'IDR': 'Indonesian rupiah', 'PHP': 'Philippine pesos', 'VND': 'Vietnamese dong',
    'SGD': 'Singapore dollars', 'HKD': 'Hong Kong dollars', 'TWD': 'Taiwan dollars',
    'RUB': 'Russian rubles', 'ZAR': 'South African rand', 'NGN': 'Nigerian naira',
    'GHS': 'Ghanaian cedis', 'KES': 'Kenyan shillings', 'TZS': 'Tanzanian shillings',
    'UGX': 'Ugandan shillings', 'MXN': 'Mexican pesos', 'BRL': 'Brazilian reals',
    'ARS': 'Argentine pesos', 'CLP': 'Chilean pesos', 'COP': 'Colombian pesos',
    'PEN': 'Peruvian soles', 'UAH': 'Ukrainian hryvnias', 'KZT': 'Kazakhstani tenge',
  };

  /// Singular spoken currency (used alone, not after an amount).
  static const Map<String, String> _englishCurrencySingular = {
    'SAR': 'Saudi riyal', 'USD': 'US dollar', 'EUR': 'euro', 'GBP': 'pound',
    'YER': 'Yemeni rial', 'YER_OLD': 'old Yemeni rial', 'YER_NEW': 'new Yemeni rial',
    'AED': 'UAE dirham', 'EGP': 'Egyptian pound', 'JOD': 'Jordanian dinar',
    'KWD': 'Kuwaiti dinar', 'QAR': 'Qatari riyal', 'BHD': 'Bahraini dinar',
    'OMR': 'Omani rial', 'TRY': 'Turkish lira', 'ILS': 'Israeli shekel',
    'IQD': 'Iraqi dinar', 'LBP': 'Lebanese pound', 'SYP': 'Syrian pound',
    'INR': 'Indian rupee', 'PKR': 'Pakistani rupee', 'MAD': 'Moroccan dirham',
    'TND': 'Tunisian dinar', 'LYD': 'Libyan dinar', 'SDG': 'Sudanese pound',
  };

  /// Convert a number (0 .. 10^21) to clean English words, exact decimals.
  static String numberToEnglish(num number) {
    if (number == 0) return 'zero';

    if (number is double && number != number.roundToDouble()) {
      final text = number.toString();
      final dot = text.indexOf('.');
      if (dot < 0) return numberToEnglish(number.truncate());
      final intPart = int.tryParse(text.substring(0, dot)) ?? 0;
      final frac = text.substring(dot + 1).replaceAll(RegExp(r'0+$'), '');
      if (frac.isEmpty) return numberToEnglish(intPart);
      final sign = number < 0 ? 'minus ' : '';
      final base = numberToEnglish(intPart < 0 ? -intPart : intPart);
      return '$sign$base point ${_spellDigits(frac, lang: 'en')}';
    }

    final n = number.toInt();
    if (n < 0) return 'minus ${numberToEnglish(-n)}';
    if (n < 20) return _englishOnes[n.toString()]!;
    if (n < 100) {
      final tensDigit = (n ~/ 10) * 10;
      final onesDigit = n % 10;
      if (onesDigit == 0) return _englishOnes[tensDigit.toString()]!;
      return '${_englishOnes[tensDigit.toString()]!}-${_englishOnes[onesDigit.toString()]!}';
    }
    if (n < 1000) {
      final hundreds = n ~/ 100;
      final remainder = n % 100;
      final base = hundreds == 1 ? 'one hundred' : '${_englishOnes[hundreds.toString()]!} hundred';
      if (remainder == 0) return base;
      return '$base ${numberToEnglish(remainder)}';
    }

    // Above one thousand: scale in groups of three.
    final groups = <int>[];
    var temp = n;
    while (temp > 0) {
      groups.add(temp % 1000);
      temp ~/= 1000;
    }
    if (groups.length > _englishScale.length) {
      return _spellDigits(n.toString(), lang: 'en');
    }
    final words = <String>[];
    for (var i = groups.length - 1; i >= 0; i--) {
      final g = groups[i];
      if (g == 0) continue;
      final text = numberToEnglish(g);
      final scale = _englishScale[i];
      words.add(scale.isEmpty ? text : '$text $scale');
    }
    return words.join(' ');
  }

  /// Spoken currency phrase: plural after an amount, singular when standalone.
  static String currencyToEnglish(String code, {bool afterAmount = true}) {
    if (afterAmount) return _englishCurrencies[code] ?? _englishCurrencySingular[code] ?? code;
    return _englishCurrencySingular[code] ?? _englishCurrencies[code] ?? code;
  }

  // ═══════════ Arabic pipeline ═══════════

  static String _prepareArabic(String text) {
    var result = _normalizeDigits(text);

    // Financial normalization first (amounts with currency) — keep as is
    result = _speakArabicAmounts(result);
    result = _speakArabicCurrencyCodes(result);
    // Dates/times/percents are also financial-like, keep
    result = _speakArabicDatesTimes(result);
    result = _speakArabicPercents(result);
    // Labeled numbers (account/phone) stay as digit spelling, not as financial
    result = _spellArabicLabeledNumbers(result);
    result = _spellLongDigitRuns(result, lang: 'ar');
    result = _stashMixedTokens(result);
    // Bare numbers: only convert if they look like a financial amount
    // (e.g., "5000 ريال" already handled, so remaining bare numbers are likely not financial)
    // Keep normal text numbers as digits for natural speech
    // result = _speakArabicBareNumbers(result); // disabled for natural speech
    result = _canonArabicOrdinals(result);
    result = _restoreMixedTokens(result);

    result = result.replaceAll('،', '، ');
    // A sentence pause after a full stop, never inside a number (19.99).
    result = result.replaceAll(RegExp(r'\.(?!\d)|(?<!\d)\.'), '. ');
    result = result.replaceAll('؟', '؟ ');
    result = result.replaceAll('!', '! ');
    result = result.replaceAll(RegExp(r'\s{2,}'), ' ').trim();

    return result;
  }

  /// Dates (DD/MM/YYYY, ISO YYYY-MM-DD, "12 مايو 2026") and times (HH:MM).
  /// Numeric slash dates follow the app's own dd-first convention
  /// ([localizedShortDate] uses 'dd MMM yyyy').
  static String _speakArabicDatesTimes(String text) {
    var out = text;

    // ISO: 2026-05-12 / 2026/05/12.
    out = out.replaceAllMapped(
      RegExp(r'(?<!\d)(\d{4})[/-](\d{1,2})[/-](\d{1,2})(?!\d)'),
      (m) {
        final y = int.tryParse(m.group(1)!);
        final mo = int.tryParse(m.group(2)!);
        final d = int.tryParse(m.group(3)!);
        if (y == null || mo == null || d == null) return m.group(0)!;
        if (mo < 1 || mo > 12 || d < 1 || d > 31) return m.group(0)!;
        return '${numberToArabic(d)} ${_arMonths[mo]} ${numberToArabic(y)}';
      },
    );

    // DD/MM/YYYY or DD-MM-YYYY (app convention: day first).
    out = out.replaceAllMapped(
      RegExp(r'(?<!\d)(\d{1,2})[/-](\d{1,2})[/-](\d{4})(?!\d)'),
      (m) {
        final d = int.tryParse(m.group(1)!);
        final mo = int.tryParse(m.group(2)!);
        final y = int.tryParse(m.group(3)!);
        if (d == null || mo == null || y == null) return m.group(0)!;
        if (mo < 1 || mo > 12 || d < 1 || d > 31) return m.group(0)!;
        return '${numberToArabic(d)} ${_arMonths[mo]} ${numberToArabic(y)}';
      },
    );

    // Named month: "12 مايو 2026" (incl. Levantine variants → MSA name).
    final monthAlt = [..._arMonths.skip(1), ..._arMonthVariants.keys]
        .map(RegExp.escape).join('|');
    out = out.replaceAllMapped(
      RegExp('(?<!\\d)(\\d{1,2})\\s*($monthAlt)\\s*(\\d{4})(?!\\d)'),
      (m) {
        final d = int.tryParse(m.group(1)!);
        final y = int.tryParse(m.group(3)!);
        if (d == null || y == null || d < 1 || d > 31) return m.group(0)!;
        var month = m.group(2)!;
        month = _arMonthVariants[month] ?? month;
        return '${numberToArabic(d)} $month ${numberToArabic(y)}';
      },
    );

    // Times HH:MM with optional ص/م/صباحا/مساء/AM/PM markers.
    out = out.replaceAllMapped(
      RegExp(r'(?<!\d)(\d{1,2}):(\d{2})(?:\s*(ص|م|صباحًا|صباحا|مساءً|مساءا|AM|PM|am|pm))?(?!\d)'),
      (m) {
        final h = int.tryParse(m.group(1)!);
        final min = int.tryParse(m.group(2)!);
        if (h == null || min == null || h > 23 || min > 59) return m.group(0)!;
        final marker = m.group(3) ?? '';
        if (h == 0 && min == 0 && marker.isEmpty) return 'منتصف الليل';
        var period = '';
        if (marker == 'ص' || marker == 'صباحًا' || marker == 'صباحا') {
          period = 'صباحًا';
        } else if (marker == 'م' || marker == 'مساءً' || marker == 'مساءا') {
          period = 'مساءً';
        } else if (marker == 'AM' || marker == 'am') {
          period = 'صباحًا';
        } else if (marker == 'PM' || marker == 'pm') {
          period = 'مساءً';
        } else {
          period = h < 12 ? 'صباحًا' : 'مساءً';
        }
        var h12 = h % 12;
        if (h12 == 0) h12 = 12;
        final hourWord = _arabicHour(h12);
        if (min == 0) return 'الساعة $hourWord $period';
        if (min == 15) return 'الساعة $hourWord والربع $period';
        if (min == 30) return 'الساعة $hourWord والنصف $period';
        if (min == 45) {
          var next = h12 + 1;
          if (next > 12) next = 1;
          return 'الساعة ${_arabicHour(next)} إلا الربع $period';
        }
        final minWord = numberToArabic(min);
        String minutePart;
        if (min == 1) {
          minutePart = 'دقيقة';
        } else if (min == 2) {
          minutePart = 'دقيقتان';
        } else if (min <= 10) {
          minutePart = '$minWord دقائق';
        } else {
          minutePart = '$minWord دقيقة';
        }
        return 'الساعة $hourWord و$minutePart $period';
      },
    );

    return out;
  }

  static String _arabicHour(int h12) {
    const hours = {
      1: 'الواحدة', 2: 'الثانية', 3: 'الثالثة', 4: 'الرابعة',
      5: 'الخامسة', 6: 'السادسة', 7: 'السابعة', 8: 'الثامنة',
      9: 'التاسعة', 10: 'العاشرة', 11: 'الحادية عشرة', 12: 'الثانية عشرة',
    };
    return hours[h12] ?? numberToArabic(h12);
  }

  /// Percentages: "15%" / "15 ٪" / "15٪" / "-2.5%" → "خمسة عشر بالمئة".
  static String _speakArabicPercents(String text) {
    return text.replaceAllMapped(
      RegExp(r'(?<![\d.])(-\s*)?(\d[\d,]*(?:\.\d+)?)\s*(%|٪|﹪)(?![\d%])'),
      (m) {
        final parsed = _parseNumberToken(m.group(2)!);
        if (parsed == null) return m.group(0)!;
        final words = _speakNumParts(parsed, lang: 'ar');
        final sign = m.group(1) != null ? 'سالب ' : '';
        return '$sign$words بالمئة';
      },
    );
  }

  /// Arabic currency units (generic words kept verbatim — never invents
  /// SAR-vs-YER specificity) with up to two qualifier adjectives, so full
  /// app forms like "ريال يمني جديد" work without duplicating currency data.
  static const String _arUnitWords =
      'ريال|دولار|يورو|جنيه|درهم|دينار|ليرة|روبية|روبل|ين|يوان|فرنك|كرونا|كرون|'
      'شلن|شلنات|بيزو|بات|دونغ|رينغيت|بوليفار|سول|تاكا|سيدي|بير|ليو|ليف|زلوتي|'
      'فورنت|كونا|لاري|درام|مانات|سوم|تنغي|هريفنا|نيرة|راند|شيكل|أفغاني|ليك|'
      'هللة|هلله|فلس|فلوس|قرش|قروش|مليم|سنت|سنتات';
  static const String _arQualifiers =
      'سعودي|سعودية|يمني|يمنية|قديم|قديمة|جديد|جديدة|أمريكي|أمريكية|إماراتي|'
      'إماراتية|كويتي|كويتية|قطري|قطرية|بحريني|بحرينية|عماني|عمانية|مصري|مصرية|'
      'أردني|أردنية|تركي|تركية|سوداني|سودانية|عراقي|عراقية|لبناني|لبنانية|سوري|'
      'سورية|مغربي|مغربية|تونسي|تونسية|ليبي|ليبية|جزائري|جزائرية|هندي|هندية|'
      'باكستاني|باكستانية|صيني|صينية|ياباني|يابانية|كوري|كورية|روسي|روسية|'
      'سويسري|سويسرية|بريطاني|إسترليني|أوروبي|مكسيكي|برازيلي|كندي|أسترالي|'
      'سنغافوري|استرليني|عربي';

  /// Amounts: "5000 SAR" / "100 ر.س" / "\$100" / "1000 ريال (يمني جديد)".
  /// Value + decimals + sign preserved; currency word from real app data.
  static String _speakArabicAmounts(String text) {
    var out = text;
    final codes = _codePattern();
    final syms = _symbolPattern();

    // Signed number + currency code: "-500 SAR" / "19.99 USD".
    out = out.replaceAllMapped(
      RegExp('(?<![\\w.,:/-])(-\\s*)?(\\d[\\d,]*(?:\\.\\d+)?)\\s*($codes)(?![\\w])'),
      (m) {
        final parsed = _parseNumberToken(m.group(2)!);
        if (parsed == null) return m.group(0)!;
        final words = _speakNumParts(parsed, lang: 'ar');
        final sign = m.group(1) != null ? 'سالب ' : '';
        return '$sign$words ${_currencySpoken(m.group(3)!, lang: 'ar', afterAmount: true)}';
      },
    );

    // Currency symbol + number, either side: "$100" / "100 ر.س".
    out = out.replaceAllMapped(
      RegExp('(?<![\\w.,:/-])(-\\s*)?(?:($syms)\\s*)?(\\d[\\d,]*(?:\\.\\d+)?)\\s*(?:($syms))?(?![\\w])'),
      (m) {
        if ((m.group(2) ?? '').isEmpty && (m.group(4) ?? '').isEmpty) {
          return m.group(0)!;
        }
        final sym = (m.group(2) ?? '').isNotEmpty ? m.group(2)! : m.group(4)!;
        final code = _symbolToCode[sym];
        if (code == null) return m.group(0)!;
        final parsed = _parseNumberToken(m.group(3)!);
        if (parsed == null) return m.group(0)!;
        final words = _speakNumParts(parsed, lang: 'ar');
        final sign = m.group(1) != null ? 'سالب ' : '';
        return '$sign$words ${_currencySpoken(code, lang: 'ar', afterAmount: true)}';
      },
    );

    // Number + Arabic unit words (kept verbatim): "1000 ريال يمني جديد".
    out = out.replaceAllMapped(
      RegExp('(?<![\\w.,:/-])(-\\s*)?(\\d[\\d,]*(?:\\.\\d+)?)\\s*($_arUnitWords)((?:\\s+(?:$_arQualifiers)){0,2})(?![\\w])'),
      (m) {
        final parsed = _parseNumberToken(m.group(2)!);
        if (parsed == null) return m.group(0)!;
        final words = _speakNumParts(parsed, lang: 'ar');
        final sign = m.group(1) != null ? 'سالب ' : '';
        final unit = '${m.group(3)!}${m.group(4) ?? ''}';
        return '$sign$words $unit'.trim();
      },
    );

    return out;
  }

  /// Standalone codes/symbols → full spoken names from real app data.
  /// Dash/underscore-joined tokens (TXN-SAR-001) are NOT touched (IDs).
  static String _speakArabicCurrencyCodes(String text) {
    var out = text;
    final codes = _codePattern();
    out = out.replaceAllMapped(
      RegExp('(?<![A-Za-z_-])($codes)(?![A-Za-z0-9_-])'),
      (m) => _currencySpoken(m.group(1)!, lang: 'ar', afterAmount: false),
    );
    final syms = _symbolPattern();
    out = out.replaceAllMapped(
      RegExp('(?<![\\w_-])($syms)(?![\\w])'),
      (m) {
        final code = _symbolToCode[m.group(1)!];
        if (code == null) return m.group(0)!;
        return _currencySpoken(code, lang: 'ar', afterAmount: false);
      },
    );
    return out;
  }

  /// Labeled numbers (accounts/cards/phones/invoices) with ≥5 digits are
  /// spelled digit-by-digit (meaning preserved, leading zeros kept).
  /// Shorter ones stay normal quantities ("رقم 5").
  static String _spellArabicLabeledNumbers(String text) {
    return text.replaceAllMapped(
      RegExp(r'(رقم الحساب|رقم حساب|الحساب|حساب|البطاقة|بطاقة|الهاتف|هاتف|الجوال|جوال|رقم الجوال|رقم الهاتف|الفاتورة|فاتورة|رقم الفاتورة|رقم|الرقم)\s*[:#]?\s*(\d(?:[\s-]?\d)*)'),
      (m) {
        final digits = m.group(2)!.replaceAll(RegExp(r'[\s-]'), '');
        if (digits.length < 5) {
          final parsed = _parseNumberToken(digits);
          if (parsed == null) return m.group(0)!;
          return '${m.group(1)!} ${_speakNumParts(parsed, lang: 'ar')}';
        }
        return '${m.group(1)!} ${_spellDigits(digits, lang: 'ar')}';
      },
    );
  }

  /// Bare numbers → Arabic words. Leading-zero tokens ("050…") are spelled
  /// (never quantities); fractions exact digit-by-digit; negatives "سالب".
  static String _speakArabicBareNumbers(String text) {
    return text.replaceAllMapped(
      RegExp(r'(?<![\w.,:/-])(-\s*)?(\d[\d,]*(?:\.\d+)?)(?![\w.])'),
      (m) {
        final token = m.group(2)!;
        final parsed = _parseNumberToken(token);
        if (parsed == null) return m.group(0)!;
        final sign = m.group(1) != null ? 'سالب ' : '';
        // Leading-zero runs are identifiers, not quantities.
        if (parsed.frac == null &&
            parsed.intPart.length > 1 &&
            parsed.intPart.startsWith('0')) {
          return '$sign${_spellDigits(parsed.intPart, lang: 'ar')}';
        }
        return '$sign${_speakNumParts(parsed, lang: 'ar')}';
      },
    );
  }

  static String _canonArabicOrdinals(String text) {
    var out = text;
    _arabicOrdinals.forEach((variant, canon) {
      out = out.replaceAllMapped(
        RegExp('(?<![\\w\\u0600-\\u06FF])${RegExp.escape(variant)}(?![\\w\\u0600-\\u06FF])'),
        (_) => canon,
      );
    });
    return out;
  }

  /// Speak parsed (int, frac?) parts exactly in [lang].
  static String _speakNumParts(_NumParts p, {required String lang}) {
    final intWords = _speakIntDigits(p.intPart, lang: lang);
    if (p.frac == null || p.frac!.isEmpty) return intWords;
    final frac = p.frac!.replaceAll(RegExp(r'0+$'), '');
    if (frac.isEmpty) return intWords;
    return lang == 'ar'
        ? '$intWords فاصلة ${_spellDigits(frac, lang: lang)}'
        : '$intWords point ${_spellDigits(frac, lang: lang)}';
  }

  // ═══════════ English pipeline ═══════════

  /// Prepares English text for TTS with crystal-clear pronunciation:
  /// - numbers → words (incl. negatives, decimals, large scales)
  /// - currency codes (SAR, USD…) → spoken English currency names
  /// - amounts ("1,500 SAR") → "one thousand five hundred Saudi riyals"
  /// - percentages, dates, times → spoken form
  /// - IDs / mixed letter-digit tokens pass through untouched.
  static String _prepareEnglish(String text) {
    var result = _normalizeDigits(text);

    result = _speakEnglishDatesTimes(result);
    result = _speakEnglishPercents(result);
    result = _speakEnglishAmounts(result);
    result = _speakEnglishCurrencyCodes(result);
    result = _spellEnglishLabeledNumbers(result);
    result = _spellLongDigitRuns(result, lang: 'en');
    result = _stashMixedTokens(result);
    result = _speakEnglishBareNumbers(result);
    result = _restoreMixedTokens(result);

    // Normalise apostrophes/possessives and spacing.
    result = result
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(' ,', ',')
        .replaceAll(' .', '.')
        .trim();
    return result;
  }

  static String _speakEnglishDatesTimes(String text) {
    var out = text;

    // ISO: 2026-05-12.
    out = out.replaceAllMapped(
      RegExp(r'(?<!\d)(\d{4})[/-](\d{1,2})[/-](\d{1,2})(?!\d)'),
      (m) {
        final y = int.tryParse(m.group(1)!);
        final mo = int.tryParse(m.group(2)!);
        final d = int.tryParse(m.group(3)!);
        if (y == null || mo == null || d == null) return m.group(0)!;
        if (mo < 1 || mo > 12 || d < 1 || d > 31) return m.group(0)!;
        return '${_enMonths[mo]} ${_enOrdinals[d] ?? d}, ${_enYear(y)}';
      },
    );

    // DD/MM/YYYY or DD-MM-YYYY (app convention: day first, dd MMM yyyy).
    out = out.replaceAllMapped(
      RegExp(r'(?<!\d)(\d{1,2})[/-](\d{1,2})[/-](\d{4})(?!\d)'),
      (m) {
        final d = int.tryParse(m.group(1)!);
        final mo = int.tryParse(m.group(2)!);
        final y = int.tryParse(m.group(3)!);
        if (d == null || mo == null || y == null) return m.group(0)!;
        if (mo < 1 || mo > 12 || d < 1 || d > 31) return m.group(0)!;
        return '${_enMonths[mo]} ${_enOrdinals[d] ?? d}, ${_enYear(y)}';
      },
    );

    // Named month: "May 12, 2026" / "12 May 2026".
    out = out.replaceAllMapped(
      RegExp(r'(?<!\w)(January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\s+(\d{1,2})(?:st|nd|rd|th)?(?:\s*,\s*(\d{4}))?(?!\d)',
          caseSensitive: false),
      (m) {
        final mo = _enMonthIndex[m.group(1)!.toLowerCase()];
        final d = int.tryParse(m.group(2)!);
        if (mo == null || d == null || d < 1 || d > 31) return m.group(0)!;
        final y = m.group(3) == null ? null : int.tryParse(m.group(3)!);
        final base = '${_enMonths[mo]} ${_enOrdinals[d] ?? d}';
        return y == null ? base : '$base, ${_enYear(y)}';
      },
    );
    out = out.replaceAllMapped(
      RegExp(r'(?<!\d)(\d{1,2})(?:st|nd|rd|th)?\s+(January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\s+(\d{4})(?!\d)',
          caseSensitive: false),
      (m) {
        final d = int.tryParse(m.group(1)!);
        final mo = _enMonthIndex[m.group(2)!.toLowerCase()];
        final y = int.tryParse(m.group(3)!);
        if (d == null || mo == null || y == null) return m.group(0)!;
        if (d < 1 || d > 31) return m.group(0)!;
        return '${_enMonths[mo]} ${_enOrdinals[d] ?? d}, ${_enYear(y)}';
      },
    );

    // Times HH:MM with optional AM/PM.
    out = out.replaceAllMapped(
      RegExp(r'(?<!\d)(\d{1,2}):(\d{2})(?:\s*(AM|PM|am|pm))?(?!\d)'),
      (m) {
        final h = int.tryParse(m.group(1)!);
        final min = int.tryParse(m.group(2)!);
        if (h == null || min == null || h > 23 || min > 59) return m.group(0)!;
        var marker = (m.group(3) ?? '').toUpperCase();
        if (marker.isEmpty) marker = h < 12 ? 'AM' : 'PM';
        var h12 = h % 12;
        if (h12 == 0) h12 = 12;
        final hourWord = numberToEnglish(h12);
        if (min == 0) return '$hourWord $marker';
        final minWord = min < 10
            ? 'oh ${numberToEnglish(min)}'
            : numberToEnglish(min);
        return '$hourWord $minWord $marker';
      },
    );

    return out;
  }

  static String _enYear(int y) {
    if (y == 2000) return 'two thousand';
    if (y > 2000 && y < 2010) return 'two thousand ${numberToEnglish(y - 2000)}';
    if (y >= 2010 && y < 2100) {
      final hi = y ~/ 100;
      final lo = y % 100;
      if (lo == 0) return '${numberToEnglish(hi)} hundred';
      return '${numberToEnglish(hi)} ${lo < 10 ? 'oh ${numberToEnglish(lo)}' : numberToEnglish(lo)}';
    }
    return numberToEnglish(y);
  }

  static String _speakEnglishPercents(String text) {
    return text.replaceAllMapped(
      RegExp(r'(?<![\d.])(-\s*)?(\d[\d,]*(?:\.\d+)?)\s*(%)(?![\d%])'),
      (m) {
        final parsed = _parseNumberToken(m.group(2)!);
        if (parsed == null) return m.group(0)!;
        final words = _speakNumParts(parsed, lang: 'en');
        final sign = m.group(1) != null ? 'minus ' : '';
        return '$sign$words percent';
      },
    );
  }

  static const String _enUnitWords =
      r'dollars?|euros?|pounds?|rials?|riyals?|dirhams?|dinars?|liras?|'
      r'rupees?|yen|yuan|francs?|kronas?|kroner|rubles?|shillings?|pesos?|'
      r'baht|ringgit|rupiahs?|dong|taka|birr|cedis?|naira|rand|shekels?|'
      r'bolivars?|soles|tenge|som|manat|lari|dram|kuna|korunas?|forint|lev|'
      r'leu|zloty|afghanis?|lek';

  static String _speakEnglishAmounts(String text) {
    var out = text;
    final codes = _codePattern();
    final syms = _symbolPattern();

    // Amount + currency: "1,500 SAR" / "-250 USD" → words.
    out = out.replaceAllMapped(
      RegExp('(?<![\\w.,:/-])(-\\s*)?(\\d[\\d,]*(?:\\.\\d+)?)\\s*($codes)(?![\\w])'),
      (m) {
        final parsed = _parseNumberToken(m.group(2)!);
        if (parsed == null) return m.group(0)!;
        final words = _speakNumParts(parsed, lang: 'en');
        final sign = m.group(1) != null ? 'minus ' : '';
        // Real-data plural when available, legacy hand-checked otherwise.
        final code = m.group(3)!;
        final real = localizedCurrencyName(code, locale: 'en');
        final spoken = (real != null && real != code)
            ? _pluralEnglish(code, real)
            : currencyToEnglish(code, afterAmount: true);
        return '$sign$words $spoken';
      },
    );

    // Symbol + number either side: "$100" / "100$".
    out = out.replaceAllMapped(
      RegExp('(?<![\\w.,:/-])(-\\s*)?(?:($syms)\\s*)?(\\d[\\d,]*(?:\\.\\d+)?)\\s*(?:($syms))?(?![\\w])'),
      (m) {
        if ((m.group(2) ?? '').isEmpty && (m.group(4) ?? '').isEmpty) {
          return m.group(0)!;
        }
        final sym = (m.group(2) ?? '').isNotEmpty ? m.group(2)! : m.group(4)!;
        final code = _symbolToCode[sym];
        if (code == null) return m.group(0)!;
        final parsed = _parseNumberToken(m.group(3)!);
        if (parsed == null) return m.group(0)!;
        final words = _speakNumParts(parsed, lang: 'en');
        final sign = m.group(1) != null ? 'minus ' : '';
        final real = localizedCurrencyName(code, locale: 'en');
        final spoken = (real != null && real != code)
            ? _pluralEnglish(code, real)
            : currencyToEnglish(code, afterAmount: true);
        return '$sign$words $spoken';
      },
    );

    // Number + spelled unit ("100 dollars" → "one hundred dollars").
    out = out.replaceAllMapped(
      RegExp('(?<![\\w.,:/-])(-\\s*)?(\\d[\\d,]*(?:\\.\\d+)?)\\s*($_enUnitWords)(?![\\w])',
          caseSensitive: false),
      (m) {
        final parsed = _parseNumberToken(m.group(2)!);
        if (parsed == null) return m.group(0)!;
        final words = _speakNumParts(parsed, lang: 'en');
        final sign = m.group(1) != null ? 'minus ' : '';
        return '$sign$words ${m.group(3)!}';
      },
    );

    return out;
  }

  static String _speakEnglishCurrencyCodes(String text) {
    var out = text;
    final codes = _codePattern();
    out = out.replaceAllMapped(
      RegExp('(?<![A-Za-z_-])($codes)(?![A-Za-z0-9_-])'),
      (m) {
        final code = m.group(1)!;
        final real = localizedCurrencyName(code, locale: 'en');
        if (real != null && real != code) return real;
        return currencyToEnglish(code, afterAmount: false);
      },
    );
    return out;
  }

  static String _spellEnglishLabeledNumbers(String text) {
    return text.replaceAllMapped(
      RegExp(r'(bank account|account|card|phone|mobile|invoice|number|no\.?|ID)\s*[:#]?\s*(\d(?:[\s-]?\d)*)',
          caseSensitive: false),
      (m) {
        final digits = m.group(2)!.replaceAll(RegExp(r'[\s-]'), '');
        if (digits.length < 5) {
          final parsed = _parseNumberToken(digits);
          if (parsed == null) return m.group(0)!;
          return '${m.group(1)!} ${_speakNumParts(parsed, lang: 'en')}';
        }
        return '${m.group(1)!} ${_spellDigits(digits, lang: 'en')}';
      },
    );
  }

  /// Bare numbers that were not part of a currency → words (incl. negatives,
  /// decimals, grouping; leading-zero tokens spelled, never quantified).
  static String _speakEnglishBareNumbers(String text) {
    return text.replaceAllMapped(
      RegExp(r'(?<![\w.,:/-])(-\s*)?(\d[\d,]*(?:\.\d+)?)(?![\w.])'),
      (m) {
        final token = m.group(2)!;
        final parsed = _parseNumberToken(token);
        if (parsed == null) return m.group(0)!;
        final sign = m.group(1) != null ? 'minus ' : '';
        if (parsed.frac == null &&
            parsed.intPart.length > 1 &&
            parsed.intPart.startsWith('0')) {
          return '$sign${_spellDigits(parsed.intPart, lang: 'en')}';
        }
        return '$sign${_speakNumParts(parsed, lang: 'en')}';
      },
    );
  }

  // ═══════════ Shared: long runs + mixed-token stash ═══════════

  /// Card-like runs (13+ digits, separators allowed) → digit spelling.
  static String _spellLongDigitRuns(String text, {required String lang}) {
    return text.replaceAllMapped(
      RegExp(r'(?<!\d)(\d(?:[\s-]?\d){12,})(?!\d)'),
      (m) {
        final digits = m.group(1)!.replaceAll(RegExp(r'[\s-]'), '');
        return _spellDigits(digits, lang: lang);
      },
    );
  }

  static final List<String> _stash = [];

  /// Hide mixed letter+digit tokens (ObjectIds, SKUs, invoice refs like
  /// INV-2026-001, product codes) so numeric passes never mangle them.
  /// Restored verbatim afterwards — names are never translated or renamed.
  static String _stashMixedTokens(String text) {
    _stash.clear();
    return text.replaceAllMapped(
      RegExp(r'(?<![A-Za-z0-9_-])(?=[A-Za-z0-9_-]{6,})(?:[A-Za-z_-]*\d[A-Za-z0-9_-]*[A-Za-z][A-Za-z0-9_-]*|[A-Za-z_-]*[A-Za-z][A-Za-z0-9_-]*\d[A-Za-z0-9_-]*)(?![A-Za-z0-9_-])'),
      (m) {
        final token = m.group(0)!;
        // Pure currency codes are handled by name passes — keep them visible.
        if (_knownCodes.contains(token.toUpperCase())) return token;
        _stash.add(token);
        // Digit-free placeholder: numeric passes must never see an index.
        return '§${'s' * _stash.length}§';
      },
    );
  }

  static String _restoreMixedTokens(String text) {
    final out = text.replaceAllMapped(
      RegExp('§(s+)§'),
      (m) {
        final i = m.group(1)!.length - 1;
        if (i < 0 || i >= _stash.length) return m.group(0)!;
        return _stash[i];
      },
    );
    _stash.clear();
    return out;
  }
}

class _NumParts {
  final String intPart;
  final String? frac;
  _NumParts(this.intPart, this.frac);
}
