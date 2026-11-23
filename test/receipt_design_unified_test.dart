import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/features/personal/presentation/providers/receipt_design_provider.dart';
import 'package:fyona_flutter/features/personal/presentation/providers/receipt_design_models.dart';

/// Unified receipt mode: enabling wipes every stored customization and every
/// section renders Default; disabling returns to per-section customs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer makeContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  test('unified off by default; sections render their own presets', () async {
    SharedPreferences.setMockInitialValues({});
    final container = makeContainer();
    final notifier = container.read(personalReceiptDesignProvider.notifier);
    await notifier.load();
    expect(notifier.unified, isFalse);
    await notifier.savePreset(
      (await container.read(personalReceiptDesignProvider))['debt']!
          .copyWith(brandName: 'MINE'),
    );
    expect(notifier.getPreset('debt').brandName, 'MINE');
  });

  test('a section customization never leaks into sibling sections', () async {
    SharedPreferences.setMockInitialValues({});
    final container = makeContainer();
    final notifier = container.read(personalReceiptDesignProvider.notifier);
    await notifier.load();
    // Customize income/expense exactly like the reported scenario.
    await notifier.savePreset(
      (await container.read(personalReceiptDesignProvider))[
              'income_expense']!
          .copyWith(
              brandName: 'INCOME-CUSTOM',
              primaryColor: const Color(0xFF00FF00)),
    );
    // Every sibling section still renders its own (default) design.
    for (final id in ['goal', 'debt', 'transfer', 'recurring', 'budget_withdrawal', 'default']) {
      final preset = notifier.getPreset(id);
      expect(preset.brandName, 'FYONA', reason: 'section $id');
      expect(preset.primaryColor, const Color(0xFFA01530),
          reason: 'section $id');
    }
    expect(notifier.getPreset('income_expense').brandName, 'INCOME-CUSTOM');
  });

  test('enabling unified wipes customs and routes everything to default',
      () async {
    SharedPreferences.setMockInitialValues({});
    final container = makeContainer();
    final notifier = container.read(personalReceiptDesignProvider.notifier);
    await notifier.load();
    await notifier.savePreset(
      (await container.read(personalReceiptDesignProvider))['debt']!
          .copyWith(brandName: 'MINE'),
    );
    await notifier.savePreset(
      (await container.read(personalReceiptDesignProvider))['goal']!
          .copyWith(brandName: 'MINE2'),
    );
    await notifier.setUnified(true);
    expect(notifier.unified, isTrue);
    expect(notifier.getPreset('debt').brandName, 'FYONA');
    expect(notifier.getPreset('goal').brandName, 'FYONA');
    expect(notifier.getPreset('transfer').brandName, 'FYONA');
    // Default itself is untouched.
    expect(notifier.getPreset('default').brandName, 'FYONA');
  });
  test('disabling unified restores the previous customs, not defaults',
      () async {
    SharedPreferences.setMockInitialValues({});
    final container = makeContainer();
    final notifier = container.read(personalReceiptDesignProvider.notifier);
    await notifier.load();
    await notifier.savePreset(
      (await container.read(personalReceiptDesignProvider))['debt']!
          .copyWith(brandName: 'KEPT'),
    );
    await notifier.setUnified(true);
    expect(notifier.getPreset('debt').brandName, 'FYONA');
    await notifier.setUnified(false);
    expect(notifier.unified, isFalse);
    // The pre-unified customization is back, siblings untouched.
    expect(notifier.getPreset('debt').brandName, 'KEPT');
    expect(notifier.getPreset('goal').brandName, 'FYONA');
  });

  test('disabling unified restores per-section routing', () async {
    SharedPreferences.setMockInitialValues({});
    final container = makeContainer();
    final notifier = container.read(personalReceiptDesignProvider.notifier);
    await notifier.load();
    await notifier.setUnified(true);
    await notifier.setUnified(false);
    expect(notifier.unified, isFalse);
    await notifier.savePreset(
      (await container.read(personalReceiptDesignProvider))['debt']!
          .copyWith(brandName: 'BACK'),
    );
    // Only the edited section changes; the rest stay default.
    expect(notifier.getPreset('debt').brandName, 'BACK');
    expect(notifier.getPreset('goal').brandName, 'FYONA');
    expect(notifier.getPreset('transfer').brandName, 'FYONA');
  });

  group('receiptSectionForTransaction (one design per section, everywhere)',
      () {
    test('linked operations resolve their own section', () {
      expect(receiptSectionForTransaction(debtId: 'd'), 'debt');
      expect(receiptSectionForTransaction(goalId: 'g'), 'goal');
      expect(
          receiptSectionForTransaction(budgetId: 'b'), 'budget_withdrawal');
    });

    test('debt wins over co-links (payments carry budget too)', () {
      expect(
          receiptSectionForTransaction(
              debtId: 'd', budgetId: 'b', txType: 'expense'),
          'debt');
      expect(
          receiptSectionForTransaction(goalId: 'g', budgetId: 'b'),
          'goal');
    });

    test('transfer legs resolve transfer; plain rows income_expense', () {
      expect(receiptSectionForTransaction(txType: 'transfer_out'),
          'transfer');
      expect(
          receiptSectionForTransaction(txType: 'transfer_in'), 'transfer');
      // Banks-path legs are stored as plain expense/income rows tagged
      // with the transfer category.
      expect(
          receiptSectionForTransaction(
              txType: 'expense', category: 'تحويل'),
          'transfer');
      expect(
          receiptSectionForTransaction(
              txType: 'income', category: 'Transfer'),
          'transfer');
      expect(receiptSectionForTransaction(txType: 'income'),
          'income_expense');
      expect(receiptSectionForTransaction(txType: 'expense'),
          'income_expense');
      expect(receiptSectionForTransaction(), 'income_expense');
    });
  });
}
