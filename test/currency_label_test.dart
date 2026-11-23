import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/services/currency/money_format_service.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart';

void main() {
  test('currencyLabel: full Arabic name, compact English code', () {
    expect(currencyLabel('YER_OLD', locale: 'ar'), 'ريال يمني قديم');
    expect(currencyLabel('YER_NEW', locale: 'ar'), 'ريال يمني جديد');
    expect(currencyLabel('SAR', locale: 'ar'), 'ريال سعودي');
    expect(currencyLabel('USD', locale: 'ar'), 'دولار أمريكي');
    // English mode shows the code, never the long English name.
    expect(currencyLabel('YER_OLD', locale: 'en'), 'YER_OLD');
    expect(currencyLabel('USD', locale: 'en'), 'USD');
    // Bare YER normalizes to YER_NEW.
    expect(currencyLabel('YER', locale: 'en'), 'YER_NEW');
  });

  test('currencyFlagEmoji maps currencies to country flags', () {
    expect(currencyFlagEmoji('SAR'), '🇸🇦');
    expect(currencyFlagEmoji('USD'), '🇺🇸');
    expect(currencyFlagEmoji('YER_OLD'), '🇾🇪');
    expect(currencyFlagEmoji('YER_NEW'), '🇾🇪');
    expect(currencyFlagEmoji('YER'), '🇾🇪');
    expect(currencyFlagEmoji('UNKNOWN_XYZ'), '');
  });

  test('fmtNum respects the profile decimals setting', () {
    currentMoneyFormat = const MoneyFormatSettings(
        useThousandsSeparator: true, showDecimals: true);
    expect(fmtNum(20.06), '20.06');
    expect(fmtNum(1500.75), '1,500.75');
    expect(fmtNum(7000), '7,000');

    currentMoneyFormat = const MoneyFormatSettings(
        useThousandsSeparator: true, showDecimals: false);
    expect(fmtNum(20.06), '20');
    expect(fmtNum(1500.75), '1,501');
    expect(fmtNum(7000), '7,000');

    // Restore the default so other tests are unaffected.
    currentMoneyFormat = const MoneyFormatSettings();
  });
}
