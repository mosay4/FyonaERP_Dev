import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/presentation/widgets/add_transaction_sheet.dart'
    show validateBudgetSelection;

/// Submit-time guard: a budget/category deleted or recreated after the
/// sheet opened must never stage a transaction linked to dead ids
/// (money moves, but no budget shows it — silent loss).
void main() {
  PersonalBudget budget(String id, List<BudgetCategory> cats) =>
      PersonalBudget(id: id, name: 'B', categories: cats);

  BudgetCategory cat(String id) =>
      BudgetCategory(id: id, name: 'Food', type: 'expense');

  group('validateBudgetSelection', () {
    test('plain expense (no budget) always passes', () {
      expect(
          validateBudgetSelection(
              budgets: const [], budgetId: null, categoryId: null),
          isNull);
      expect(
          validateBudgetSelection(
              budgets: const [], budgetId: '', categoryId: null),
          isNull);
    });

    test('fresh budget + live category passes', () {
      final budgets = [budget('b1', [cat('c1')])];
      expect(
          validateBudgetSelection(
              budgets: budgets, budgetId: 'b1', categoryId: 'c1'),
          isNull);
    });

    test('whole-budget expense (no category) passes when budget alive', () {
      final budgets = [budget('b1', [cat('c1')])];
      expect(
          validateBudgetSelection(
              budgets: budgets, budgetId: 'b1', categoryId: null),
          isNull);
    });

    test('deleted/recreated budget is blocked', () {
      final budgets = [budget('b2', [cat('c1')])];
      expect(
          validateBudgetSelection(
              budgets: budgets, budgetId: 'b1', categoryId: 'c1'),
          'txBudgetGone');
    });

    test('deleted/recreated category is blocked', () {
      final budgets = [budget('b1', [cat('c9')])];
      expect(
          validateBudgetSelection(
              budgets: budgets, budgetId: 'b1', categoryId: 'c1'),
          'txBudgetCategoryGone');
    });
  });
}
