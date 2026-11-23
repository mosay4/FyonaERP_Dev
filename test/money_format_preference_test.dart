import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/services/currency/money_format_service.dart';
import 'package:fyona_flutter/core/utils/amount_input_formatter.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    currentMoneyFormat = const MoneyFormatSettings();
  });

  test('fmtNum respects both merchant preferences everywhere', () {
    currentMoneyFormat = const MoneyFormatSettings(
        useThousandsSeparator: true, showDecimals: true);
    expect(fmtNum(1000000), '1,000,000');
    expect(fmtNum(1000.5), '1,000.5');

    currentMoneyFormat = const MoneyFormatSettings(
        useThousandsSeparator: false, showDecimals: true);
    expect(fmtNum(1000000), '1000000');
    expect(fmtNum(1000.5), '1000.5');

    currentMoneyFormat = const MoneyFormatSettings(
        useThousandsSeparator: true, showDecimals: false);
    expect(fmtNum(1000000), '1,000,000');
    expect(fmtNum(1000.5), '1,001');

    currentMoneyFormat = const MoneyFormatSettings(
        useThousandsSeparator: false, showDecimals: false);
    expect(fmtNum(1000000), '1000000');
    expect(fmtNum(1000.5), '1001');
  });

  test('rates never lose decimals when money decimals are hidden', () {
    currentMoneyFormat = const MoneyFormatSettings(
        useThousandsSeparator: true, showDecimals: false);
    expect(fmtRate(1.25), '1.25');
  });

  test('amount input formatter follows the separator preference', () {
    currentMoneyFormat = const MoneyFormatSettings(
        useThousandsSeparator: true, showDecimals: true);
    final f = AmountInputFormatter();
    var v = f.formatEditUpdate(TextEditingValue.empty,
        const TextEditingValue(text: '1000000'));
    expect(v.text, '1,000,000');

    currentMoneyFormat = const MoneyFormatSettings(
        useThousandsSeparator: false, showDecimals: true);
    v = f.formatEditUpdate(TextEditingValue.empty,
        const TextEditingValue(text: '1000000'));
    expect(v.text, '1000000');
  });

  test('fmtNum accepts server string amounts without TypeError', () {
    expect(fmtNum('123.45'), '123.45');
    expect(fmtNum(null), '0');
  });

  test('rate line uses human currency names in the correct order', () {
    expect(formatCurrencyRateLine('USD', 534, 'YER_OLD', locale: 'ar'),
        '1 دولار = 534 ريال يمني قديم');
    expect(formatCurrencyRateLine('USD', 534, 'YER_OLD', locale: 'en'),
        '1 USD = 534 YER_OLD');
  });

  test('invBuyPrice translation exists in both languages', () async {
    for (final (lang, expected) in [('ar', 'سعر الشراء'), ('en', 'Purchase price')]) {
      final raw = await rootBundle.loadString('assets/l10n/app_$lang.arb');
      final table = jsonDecode(raw) as Map<String, dynamic>;
      expect(table['invBuyPrice'], expected);
    }
  });
}
