import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/utils/country_phone_data.dart';
import 'package:fyona_flutter/core/utils/mobile_numbering.dart';

PhoneCountry _c(String iso) => kPhoneCountries.firstWhere((c) => c.iso == iso);

void main() {
  test('Yemen: 9 digits on a real operator', () {
    final ye = _c('YE');
    expect(mobilePlanFor(ye).maxLength, 9);
    for (final ok in ['770000000', '780633880', '711234567', '733333333', '700000000']) {
      expect(mobileNumberProblem(ye, ok), isNull, reason: ok);
    }
    expect(mobileNumberProblem(ye, '0770000000'), isNull); // trunk 0 dropped
    expect(mobileNumberProblem(ye, '٧٧٠٠٠٠٠٠٠'), isNull); // Arabic digits
    expect(mobileNumberProblem(ye, '760000000'), contains('تبدأ')); // no operator
    expect(mobileNumberProblem(ye, '77000000'), contains('9')); // too short
  });

  test('Saudi, Egypt and Kuwait follow their own plans', () {
    expect(mobileNumberProblem(_c('SA'), '512345678'), isNull);
    expect(mobileNumberProblem(_c('SA'), '412345678'), isNotNull);
    expect(mobileNumberProblem(_c('EG'), '1012345678'), isNull);
    expect(mobileNumberProblem(_c('EG'), '1312345678'), isNotNull);
    expect(mobilePlanFor(_c('KW')).maxLength, 8);
    expect(mobileNumberProblem(_c('KW'), '99123456'), isNull);
  });

  test('every listed country has a plan', () {
    for (final country in kPhoneCountries) {
      expect(kMobilePlans.containsKey(country.iso), isTrue, reason: country.iso);
    }
  });
}
