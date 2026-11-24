import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/services/currency/enabled_currencies_service.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_country_cash.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('the phone tells the country', () {
    expect(countryOfPhone('+967780633880'), 'YE');
    expect(countryOfPhone('00966512345678'), 'SA');
    expect(countryOfPhone('+201012345678'), 'EG');
    expect(countryOfPhone('780633880'), isNull);
  });

  test('a new Yemeni account gets the four cash currencies', () async {
    SharedPreferences.setMockInitialValues({});
    List<String>? created;
    Set<String>? allowed;
    await seedPersonalCountryCash(
      userId: 'u1',
      phone: '+967780633880',
      ensure: (c, e) async {
        created = c;
        allowed = e;
      },
    );
    expect(created, ['USD', 'SAR', 'YER_OLD', 'YER_NEW']);
    expect(allowed, {'USD', 'SAR', 'YER_OLD', 'YER_NEW'});
  });

  test('a saved customization is never overridden', () async {
    SharedPreferences.setMockInitialValues({});
    await saveEnabledCurrencies({'USD', 'EUR'}, 'u2');
    Set<String>? allowed;
    await seedPersonalCountryCash(
      userId: 'u2',
      phone: '+967780633880',
      ensure: (c, e) async => allowed = e,
    );
    expect(allowed, {'USD', 'EUR'});
  });
}
