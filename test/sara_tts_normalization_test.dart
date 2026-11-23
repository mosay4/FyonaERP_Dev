import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/ai/domain/agent/tts_preparation.dart';

/// P1 TTS normalization: Sara's reply text must be verbalized naturally in
/// the app language (Arabic / English) — numbers, amounts, currencies,
/// percents, dates, times, ordinals and mixed text — without changing words,
/// numbers, currencies, brands or IDs, and idempotently.
void main() {
  group('Arabic numbers (prepare + engine)', () {
    test('zero to large numbers speak naturally', () {
      expect(TtsPreparation.prepare('0', lang: 'ar'), 'صفر');
      expect(TtsPreparation.prepare('1', lang: 'ar'), 'واحد');
      expect(TtsPreparation.prepare('10', lang: 'ar'), 'عشرة');
      expect(TtsPreparation.prepare('100', lang: 'ar'), 'مائة');
      expect(TtsPreparation.prepare('1000', lang: 'ar'), 'ألف');
      expect(TtsPreparation.prepare('5000', lang: 'ar'), 'خمسة آلاف');
      expect(TtsPreparation.prepare('10000', lang: 'ar'), 'عشرة آلاف');
      expect(TtsPreparation.prepare('1000000', lang: 'ar'), 'مليون');
      expect(TtsPreparation.prepare('1000000000', lang: 'ar'), 'مليار');
    });

    test('billions and trillions keep exact meaning', () {
      expect(TtsPreparation.numberToArabic(2000000000), 'ملياران');
      expect(
        TtsPreparation.prepare('2500000000', lang: 'ar'),
        'ملياران وخمسمائة مليون',
      );
      expect(TtsPreparation.numberToArabic(1000000000000), 'تريليون');
    });

    test('decimals are exact digit-by-digit after فاصلة', () {
      expect(
        TtsPreparation.prepare('19.99', lang: 'ar'),
        'تسعة عشر فاصلة تسعة تسعة',
      );
      expect(TtsPreparation.numberToArabic(19.99),
          'تسعة عشر فاصلة تسعة تسعة');
      expect(TtsPreparation.numberToArabic(0.5), 'صفر فاصلة خمسة');
    });

    test('negatives use سالب and keep value', () {
      expect(TtsPreparation.prepare('-500', lang: 'ar'), 'سالب خمسمائة');
      expect(TtsPreparation.numberToArabic(-500), 'سالب خمسمائة');
    });

    test('grouping separators do not change value', () {
      expect(TtsPreparation.prepare('1,000,000', lang: 'ar'), 'مليون');
      expect(TtsPreparation.prepare('5,000', lang: 'ar'), 'خمسة آلاف');
      expect(TtsPreparation.prepare('١٠٠٠', lang: 'ar'), 'ألف');
    });
  });

  group('Arabic percents, dates, times, ordinals', () {
    test('percent speaks بالمئة with value', () {
      expect(TtsPreparation.prepare('15%', lang: 'ar'), 'خمسة عشر بالمئة');
      expect(TtsPreparation.prepare('نسبة الخصم 15% اليوم', lang: 'ar'),
          'نسبة الخصم خمسة عشر بالمئة اليوم');
    });

    test('slash date follows app dd-first convention', () {
      expect(
        TtsPreparation.prepare('12/05/2026', lang: 'ar'),
        'اثنا عشر مايو ألفان وستة وعشرون',
      );
    });

    test('ISO and named-month dates speak naturally', () {
      expect(
        TtsPreparation.prepare('2026-05-12', lang: 'ar'),
        'اثنا عشر مايو ألفان وستة وعشرون',
      );
      expect(
        TtsPreparation.prepare('12 مايو 2026', lang: 'ar'),
        'اثنا عشر مايو ألفان وستة وعشرون',
      );
    });

    test('times speak with period and minutes', () {
      expect(TtsPreparation.prepare('14:30', lang: 'ar'),
          'الساعة الثانية والنصف مساءً');
      expect(TtsPreparation.prepare('09:00', lang: 'ar'),
          'الساعة التاسعة صباحًا');
    });

    test('ordinal variants canonicalize without meaning change', () {
      expect(TtsPreparation.prepare('جاء ثالثا في الترتيب', lang: 'ar'),
          'جاء ثالثًا في الترتيب');
      expect(TtsPreparation.prepare('الفائز أولًا', lang: 'ar'), 'الفائز أولًا');
      expect(TtsPreparation.prepare('المركز الثاني', lang: 'ar'), 'المركز الثاني');
    });
  });

  group('Arabic amounts and real currency data', () {
    test('amount + code uses real Arabic name', () {
      expect(TtsPreparation.prepare('1000 ريال', lang: 'ar'), 'ألف ريال');
      expect(TtsPreparation.prepare('5000 SAR', lang: 'ar'),
          'خمسة آلاف ريال سعودي');
      expect(TtsPreparation.prepare('19.99 USD', lang: 'ar'),
          'تسعة عشر فاصلة تسعة تسعة دولار أمريكي');
      expect(TtsPreparation.prepare('-500 USD', lang: 'ar'),
          'سالب خمسمائة دولار أمريكي');
    });

    test('YER and YER_NEW share the new name, YER_OLD differs', () {
      final yer = TtsPreparation.prepare('100 YER', lang: 'ar');
      final yerNew = TtsPreparation.prepare('100 YER_NEW', lang: 'ar');
      final yerOld = TtsPreparation.prepare('100 YER_OLD', lang: 'ar');
      expect(yer, contains('ريال يمني جديد'));
      expect(yerNew, contains('ريال يمني جديد'));
      expect(yer, yerNew);
      expect(yerOld, contains('قديم'));
      expect(yerOld, isNot(yer));
    });

    test('standalone codes resolve from real app data', () {
      expect(TtsPreparation.prepare('العملة SAR', lang: 'ar'),
          'العملة ريال سعودي');
      expect(TtsPreparation.prepare('ادفع USD', lang: 'ar'), 'ادفع دولار أمريكي');
    });

    test('unknown currency codes pass through untouched', () {
      // The CODE stays XYZ (never invented); the number itself still speaks.
      expect(TtsPreparation.prepare('100 XYZ', lang: 'ar'), 'مائة XYZ');
    });

    test('full app currency phrases keep working', () {
      expect(TtsPreparation.prepare('1000 ريال يمني جديد', lang: 'ar'),
          'ألف ريال يمني جديد');
    });
  });

  group('Arabic mixed text and protected content', () {
    test('mixed Arabic + English + numbers keeps every word', () {
      final out = TtsPreparation.prepare(
          'رصيدك 5000 SAR في بنك الراجحي', lang: 'ar');
      expect(out, 'رصيدك خمسة آلاف ريال سعودي في بنك الراجحي');
    });

    test('bank names pass through byte-identical', () {
      const bank = 'بنك الراجحي';
      final out = TtsPreparation.prepare('حول إلى $bank غدًا', lang: 'ar');
      expect(out, contains(bank));
    });

    test('account numbers spell digit-by-digit, names intact', () {
      final out = TtsPreparation.prepare(
          'رقم الحساب 123456 في بنك البلاد', lang: 'ar');
      expect(out, contains('بنك البلاد'));
      expect(out, contains('واحد اثنان ثلاثة أربعة خمسة ستة'));
      expect(out, isNot(contains('123456')));
    });

    test('product names with model numbers are not mangled', () {
      final out = TtsPreparation.prepare('اشتريت iPhone 15 أمس', lang: 'ar');
      expect(out, contains('iPhone'));
      expect(out, contains('خمسة عشر'));
    });

    test('invoice refs and ObjectIds pass through untouched', () {
      expect(TtsPreparation.prepare('الفاتورة INV-2026-001 جاهزة', lang: 'ar'),
          'الفاتورة INV-2026-001 جاهزة');
      const oid = '507f1f77bcf86cd799439011';
      expect(TtsPreparation.prepare('المرجع $oid تم', lang: 'ar'),
          'المرجع $oid تم');
    });

    test('dash-joined codes inside IDs are not verbalized', () {
      expect(TtsPreparation.prepare('TXN-SAR-001', lang: 'ar'), 'TXN-SAR-001');
    });

    test('plain Arabic without numbers is unchanged', () {
      const text = 'مرحباً بك في فيونا لإدارة أعمالك';
      expect(TtsPreparation.prepare(text, lang: 'ar'), text);
    });
  });

  group('English normalization mirrors Arabic', () {
    test('numbers, large scales and negatives', () {
      expect(TtsPreparation.prepare('0', lang: 'en'), 'zero');
      expect(TtsPreparation.prepare('5000', lang: 'en'), 'five thousand');
      expect(TtsPreparation.prepare('1000000', lang: 'en'), 'one million');
      expect(
          TtsPreparation.prepare('1000000000', lang: 'en'), 'one billion');
      expect(TtsPreparation.prepare('-500', lang: 'en'), 'minus five hundred');
      expect(TtsPreparation.prepare('1,000,000', lang: 'en'), 'one million');
    });

    test('decimals use point with exact digits', () {
      expect(TtsPreparation.prepare('19.99', lang: 'en'),
          'nineteen point nine nine');
    });

    test('percent speaks percent', () {
      expect(TtsPreparation.prepare('15% complete', lang: 'en'),
          'fifteen percent complete');
    });

    test('dates speak Month ordinal, year', () {
      expect(TtsPreparation.prepare('12/05/2026', lang: 'en'),
          'May twelfth, twenty twenty-six');
      expect(TtsPreparation.prepare('May 12, 2026', lang: 'en'),
          'May twelfth, twenty twenty-six');
    });

    test('amounts use real plural currency names', () {
      expect(TtsPreparation.prepare('1500 SAR', lang: 'en'),
          'one thousand five hundred Saudi riyals');
      expect(TtsPreparation.prepare('-250 USD', lang: 'en'),
          'minus two hundred fifty US dollars');
      expect(TtsPreparation.prepare('100 YER_NEW', lang: 'en'),
          contains('new Yemeni rials'));
    });

    test('times speak naturally', () {
      expect(TtsPreparation.prepare('2:30 PM', lang: 'en'), 'two thirty PM');
    });

    test('mixed English keeps brands and spells accounts', () {
      final out = TtsPreparation.prepare(
          'Balance 5000 SAR at Al Rajhi Bank', lang: 'en');
      expect(out, contains('Al Rajhi Bank'));
      expect(out, contains('five thousand Saudi riyals'));
      final acc = TtsPreparation.prepare('account 123456 confirmed', lang: 'en');
      expect(acc, contains('one two three four five six'));
    });

    test('plain English without numbers is unchanged', () {
      const text = 'Welcome to Fyona for your business';
      expect(TtsPreparation.prepare(text, lang: 'en'), text);
    });
  });

  group('structured money API (req 11)', () {
    test('Arabic structured amount preserves value/decimals/currency/sign', () {
      expect(
        TtsPreparation.prepareMoney(
            amount: 19.99, currencyCode: 'SAR', lang: 'ar'),
        'تسعة عشر فاصلة تسعة تسعة ريال سعودي',
      );
      expect(
        TtsPreparation.prepareMoney(
            amount: -500, currencyCode: 'USD', lang: 'ar'),
        'سالب خمسمائة دولار أمريكي',
      );
      expect(
        TtsPreparation.prepareMoney(
            amount: 5000, currencyCode: 'YER_NEW', lang: 'ar'),
        'خمسة آلاف ريال يمني جديد',
      );
    });

    test('English structured amount uses minus + plural', () {
      expect(
        TtsPreparation.prepareMoney(
            amount: -500, currencyCode: 'USD', lang: 'en'),
        'minus five hundred US dollars',
      );
    });

    test('unknown structured code passes through', () {
      expect(
        TtsPreparation.prepareMoney(
            amount: 100, currencyCode: 'XYZ', lang: 'ar'),
        'مائة XYZ',
      );
    });
  });

  group('idempotency: second run changes nothing', () {
    final cases = {
      'ar': [
        'رصيدك 5000 SAR في بنك الراجحي',
        '19.99',
        '-500',
        '15%',
        '12/05/2026',
        '14:30',
        'جاء ثالثا في الترتيب',
        '1000 ريال يمني جديد',
        'رقم الحساب 123456 في بنك البلاد',
        'الفاتورة INV-2026-001 جاهزة',
        '2500000000',
        'مرحباً بك في فيونا',
      ],
      'en': [
        'Balance 5000 SAR at Al Rajhi Bank',
        '19.99',
        '-500',
        '15% complete',
        '12/05/2026',
        '2:30 PM',
        'May 12, 2026',
        'account 123456 confirmed',
        'Welcome to Fyona',
      ],
    };
    test('prepare(prepare(x)) == prepare(x) for all fixtures', () {
      cases.forEach((lang, texts) {
        for (final t in texts) {
          final once = TtsPreparation.prepare(t, lang: lang);
          final twice = TtsPreparation.prepare(once, lang: lang);
          expect(twice, once, reason: '[$lang] $t → $once');
          expect(once, isNot(contains('�')));
          expect(once, isNot(contains('§')));
        }
      });
    });
  });
}
