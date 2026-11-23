import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/personal_debts_page.dart'
    show splitDebtPayment, splitReceivableCollection;

/// Debt payment direction: the typed amount is ALWAYS in the selected
/// account currency; execution converts it to the debt currency at the
/// latest known rate.
/// (e.g. paying a 3000 USD debt from a YER account: typing 17000 credits
/// only ~30 USD — never a false "exceeds" warning.)
void main() {
  group('splitDebtPayment (typed in account currency)', () {
    test('same currency passes through untouched', () {
      final r = splitDebtPayment(
          amount: 1000,
          accountCurrency: 'SAR',
          debtCurrency: 'SAR',
          rate: 3.75);
      expect(r.bankMove, 1000);
      expect(r.debtCredit, 1000);
    });

    test('USD debt paid from SAR account converts (375 SAR -> ~100 USD)', () {
      final r = splitDebtPayment(
          amount: 375,
          accountCurrency: 'SAR',
          debtCurrency: 'USD',
          rate: 1 / 3.75);
      expect(r.bankMove, 375,
          reason: 'account moves the typed amount');
      expect(r.debtCredit, closeTo(100.0, 0.01),
          reason: 'debt is credited the converted value');
    });

    test('SAR debt collected into USD account converts', () {
      final r = splitDebtPayment(
          amount: 266.67, accountCurrency: 'USD', debtCurrency: 'SAR', rate: 3.75);
      expect(r.bankMove, 266.67);
      expect(r.debtCredit, closeTo(1000.0, 0.1));
    });

    test('missing rate falls back to 1:1 without blocking', () {
      final r = splitDebtPayment(
          amount: 1000,
          accountCurrency: 'USD',
          debtCurrency: 'SAR',
          rate: null);
      expect(r.bankMove, 1000);
      expect(r.debtCredit, 1000);
    });

    test('zero rate falls back to 1:1', () {
      final r = splitDebtPayment(
          amount: 500, accountCurrency: 'USD', debtCurrency: 'SAR', rate: 0);
      expect(r.bankMove, 500);
      expect(r.debtCredit, 500);
    });

    test('currency codes compare case-insensitively', () {
      final r = splitDebtPayment(
          amount: 700,
          accountCurrency: 'sar',
          debtCurrency: 'SAR',
          rate: 99);
      expect(r.bankMove, 700,
          reason: 'same currency must ignore any rate');
      expect(r.debtCredit, 700);
    });
  });

  group('splitReceivableCollection (typed in debt currency)', () {
    test('same currency passes through untouched', () {
      final r = splitReceivableCollection(
          amount: 100,
          accountCurrency: 'USD',
          debtCurrency: 'USD',
          rate: 3.75);
      expect(r.debtCredit, 100);
      expect(r.bankMove, 100);
    });

    test('100 USD collected into SAR credits ~385 SAR', () {
      final r = splitReceivableCollection(
          amount: 100,
          accountCurrency: 'SAR',
          debtCurrency: 'USD',
          rate: 3.85);
      expect(r.debtCredit, 100,
          reason: 'debt is credited the typed amount');
      expect(r.bankMove, closeTo(385.0, 0.01),
          reason: 'account receives the converted value');
    });

    test('missing rate falls back to 1:1 without blocking', () {
      final r = splitReceivableCollection(
          amount: 100,
          accountCurrency: 'SAR',
          debtCurrency: 'USD',
          rate: null);
      expect(r.debtCredit, 100);
      expect(r.bankMove, 100);
    });
  });
}
