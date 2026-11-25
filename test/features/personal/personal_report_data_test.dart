import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/reports/personal_report_data.dart';

/// Personal › التقارير: every amount is converted to the ONE report currency
/// before it is added; amounts without a rate are left out and counted.
void main() {
  final now = DateTime(2026, 11, 20, 12);
  // 1 USD = 3.75 SAR = 0.92 EUR; no rate for XYZ.
  const usd = {'USD': 1.0, 'SAR': 3.75, 'EUR': 0.92};
  double? rate(String from, String to) {
    final a = usd[from], b = usd[to];
    return a == null || b == null ? null : b / a;
  }

  PersonalTransaction tx(
    String type,
    double amount,
    String currency,
    DateTime date, {
    String category = 'طعام',
    String? goalId,
  }) => PersonalTransaction(
    id: '$type$amount$currency${date.day}',
    type: type,
    amount: amount,
    category: category,
    date: date,
    currency: currency,
    goalId: goalId,
  );

  final txs = [
    tx('income', 1000, 'USD', DateTime(2026, 11, 2), category: 'راتب'),
    tx('income', 375, 'SAR', DateTime(2026, 11, 3), category: 'عمل حر'),
    tx('expense', 75, 'SAR', DateTime(2026, 11, 4)), // 20 USD
    tx('expense', 46, 'EUR', DateTime(2026, 11, 5), category: 'نقل'), // 50 USD
    tx('expense', 10, 'XYZ', DateTime(2026, 11, 6)), // no rate
    tx('expense', 30, 'USD', DateTime(2026, 11, 7), goalId: 'g1'),
    // A transfer is mirrored as expense + income: never income/spending.
    tx('expense', 100, 'USD', DateTime(2026, 11, 8), category: 'تحويل'),
    tx('income', 375, 'SAR', DateTime(2026, 11, 8), category: 'تحويل'),
    // Previous month (comparison only).
    tx('expense', 35, 'USD', DateTime(2026, 10, 20)),
  ];

  PersonalReportData build(String currency) => PersonalReportData.build(
    currency: currency,
    window: PersonalReportWindow.of('month', now: now),
    rate: rate,
    transactions: txs,
    banks: [
      PersonalBankAccount(id: 'a', bankName: 'جيب', balance: 500, currency: 'USD'),
      PersonalBankAccount(id: 'b', bankName: 'الراجحي', balance: 3750, currency: 'SAR'),
      PersonalBankAccount(id: 'c', bankName: 'غريب', balance: 9, currency: 'XYZ'),
    ],
    goals: [
      SavingsGoal(id: 'g1', name: 'سيارة', targetAmount: 3750, currentAmount: 375, currency: 'SAR'),
    ],
    debts: [
      PersonalDebt(id: 'd1', type: 'receivable', personName: 'علي', amount: 200, paid: 50, currency: 'USD', dueDate: DateTime(2026, 11, 1)),
      PersonalDebt(id: 'd2', type: 'payable', personName: 'سالم', amount: 375, currency: 'SAR'),
      PersonalDebt(id: 'd3', type: 'payable', personName: 'منتهي', amount: 10, paid: 10, status: 'paid', currency: 'USD'),
    ],
    budgets: [
      PersonalBudget(id: 'b1', name: 'الشهر', totalAmount: 375, totalSpent: 300, currency: 'SAR'),
    ],
    now: now,
  );

  test('values every operation, balance, goal, debt and budget in USD', () {
    final d = build('USD');
    expect(d.income, closeTo(1100, 1e-9));
    expect(d.spending, closeTo(70, 1e-9)); // goal contribution + transfer out
    expect(d.toGoals, closeTo(30, 1e-9));
    expect(d.net, closeTo(1000, 1e-9));
    expect(d.transfers, 1);
    expect(d.prevSpending, closeTo(35, 1e-9));
    expect(d.categories.first.label, 'نقل');
    expect(d.categories.first.amount, closeTo(50, 1e-9));
    expect(d.balances, closeTo(1500, 1e-9));
    expect(d.banks.where((b) => b.converted == null).single.name, 'غريب');
    expect(d.goals.single.saved, closeTo(100, 1e-9));
    expect(d.goals.single.target, closeTo(1000, 1e-9));
    expect(d.owedToMe, closeTo(150, 1e-9));
    expect(d.iOwe, closeTo(100, 1e-9));
    expect(d.debts, hasLength(2)); // the paid one is closed
    expect(d.overdueDebts, 1);
    expect(d.budgets.single.usage, closeTo(.8, 1e-9));
    expect(d.netWorth, closeTo(1550, 1e-9));
    // One operation and one balance in XYZ have no rate: never mixed in.
    expect(d.unconverted, {'XYZ': 2});
  });

  test('switching the report currency converts the whole report', () {
    final usdReport = build('USD');
    final sar = build('SAR');
    expect(sar.currency, 'SAR');
    expect(sar.income, closeTo(usdReport.income * 3.75, 1e-6));
    expect(sar.spending, closeTo(usdReport.spending * 3.75, 1e-6));
    expect(sar.netWorth, closeTo(usdReport.netWorth * 3.75, 1e-6));
    expect(sar.goals.single.saved, closeTo(375, 1e-6));
    final eur = build('EUR');
    expect(eur.balances, closeTo(1500 * .92, 1e-6));
    expect(eur.topExpenses.first.originalCurrency, 'EUR');
    expect(eur.topExpenses.first.amount, closeTo(46, 1e-6));
  });

  test('periods: today, week, year and custom windows', () {
    final today = PersonalReportWindow.of('today', now: now);
    expect(today.days, 1);
    expect(today.contains(DateTime(2026, 11, 20, 23)), isTrue);
    expect(today.contains(DateTime(2026, 11, 19, 23)), isFalse);
    expect(PersonalReportWindow.of('week', now: now).days, 7);
    final custom = PersonalReportWindow.of(
      'custom',
      now: now,
      customFrom: DateTime(2026, 1, 1),
      customTo: DateTime(2026, 1, 31),
    );
    expect(custom.days, 31);
    expect(custom.previous.to, custom.from);
    final year = PersonalReportData.build(
      currency: 'USD',
      window: PersonalReportWindow.of('year', now: now),
      rate: rate,
      transactions: txs,
      now: now,
    );
    expect(year.spending, closeTo(105, 1e-9));
    expect(year.months, hasLength(6));
  });
}
