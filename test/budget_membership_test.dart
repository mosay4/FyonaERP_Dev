import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/domain/services/budget_aggregation.dart';

/// Budget membership: the list, the detail, and the server must count the
/// SAME operations (one true number). Regression coverage for operations
/// that carry only a category link (no direct budget_id):
/// a budget_id-only filter silently drops them from the total.
///
/// (Debt/goal links are NOT counted: that linking was removed — budgets
/// carry only user-added categories, or none at all.)
void main() {
  PersonalTransaction tx({
    required String id,
    String? budgetId,
    String? budgetCategoryId,
    String? debtId,
    String? goalId,
  }) =>
      PersonalTransaction(
        id: id,
        type: 'expense',
        amount: 100,
        category: 'x',
        budgetId: budgetId,
        budgetCategoryId: budgetCategoryId,
        debtId: debtId,
        goalId: goalId,
      );

  const bid = 'budget-1';
  const catIds = {'cat-1', 'cat-2'};

  bool belongs(PersonalTransaction t) => budgetTxBelongs(
        t: t,
        budgetId: bid,
        categoryIds: catIds,
      );

  group('budgetTxBelongs', () {
    test('direct budget link counts', () {
      expect(belongs(tx(id: 'a', budgetId: bid)), isTrue);
    });

    test('category-only transaction counts (no budget_id)', () {
      expect(
          belongs(tx(id: 'b', budgetCategoryId: 'cat-1')), isTrue,
          reason: 'category of this budget implies membership');
    });

    test('debt/goal links do NOT count (linking removed)', () {
      expect(belongs(tx(id: 'c', debtId: 'debt-1')), isFalse);
      expect(belongs(tx(id: 'd', goalId: 'goal-1')), isFalse);
    });

    test('foreign links do NOT count', () {
      expect(belongs(tx(id: 'e', budgetId: 'other')), isFalse);
      expect(belongs(tx(id: 'f', budgetCategoryId: 'other-cat')), isFalse);
      expect(belongs(tx(id: 'i')), isFalse);
    });

    test('user scenario: direct + category shapes sum to the true total', () {
      final ops = [
        tx(id: 't1', budgetId: bid), // direct
        tx(id: 't2', budgetCategoryId: 'cat-2'), // category-only
        tx(id: 't3', debtId: 'debt-1'), // not linked anymore
        tx(id: 't4', budgetId: 'unrelated'), // must stay out
      ];
      final counted = ops.where(belongs).length;
      expect(counted, 2,
          reason: 'direct + category count; debt-linked and foreign do not');
    });
  });
}
