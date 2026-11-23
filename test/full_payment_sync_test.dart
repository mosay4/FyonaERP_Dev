import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/sales/presentation/providers/sale_providers.dart';
import 'package:fyona_flutter/features/purchases/presentation/providers/purchase_providers.dart';
import 'package:fyona_flutter/features/sales/presentation/widgets/sale_payment_section.dart'
    show resolveSalePrices;
import 'package:fyona_flutter/features/purchases/presentation/widgets/purchase_payment_section.dart'
    show resolvePurchasePrices;

void main() {
  group('sale full payment auto-sync', () {
    test('fills the whole total and re-syncs when the total changes', () {
      final n = SaleDraftNotifier();
      n.setItems([
        const SaleItem(description: 'A', quantity: 1, unitPrice: 30),
      ]);
      n.setPayMode(0);
      n.setPayments([
        const SalePaymentRow(
            accountId: 'acc', accountName: 'Bank', currency: 'USD', amount: 0),
      ]);
      expect(n.state.payments.first.amount, closeTo(30, 1e-6));
      expect(n.state.remaining, closeTo(0, 1e-6));

      // Adding another line raises the total; the full payment follows it.
      n.setItems([
        const SaleItem(description: 'A', quantity: 1, unitPrice: 30),
        const SaleItem(description: 'B', quantity: 1, unitPrice: 20),
      ]);
      expect(n.state.payments.first.amount, closeTo(50, 1e-6));
    });

    test('never keeps a stale amount when the invoice currency changes', () {
      final n = SaleDraftNotifier();
      // 30 USD invoice.
      n.setItems([
        const SaleItem(description: 'A', quantity: 1, unitPrice: 30),
      ]);
      n.setPayMode(0);
      n.setPayments([
        const SalePaymentRow(
            accountId: 'acc', accountName: 'Bank', currency: 'USD', amount: 0),
      ]);
      expect(n.state.payments.first.amount, closeTo(30, 1e-6));

      // Switch to YER_OLD: the item price is re-resolved (same row currency),
      // so the paid amount must equal the new total, NOT stay at 30.
      n.setItems([
        const SaleItem(description: 'A', quantity: 1, unitPrice: 4080),
      ]);
      n.setCurrencyAndPayments('YER_OLD', [
        const SalePaymentRow(
            accountId: 'acc',
            accountName: 'Bank',
            currency: 'YER_OLD',
            amount: 30),
      ]);
      expect(n.state.payments.first.amount, closeTo(4080, 1e-6));
      expect(n.state.paid, closeTo(4080, 1e-6));
      expect(n.state.remaining, closeTo(0, 1e-6));
    });

    test('converts into the payment currency via its frozen rate', () {
      final n = SaleDraftNotifier();
      n.setItems([
        const SaleItem(description: 'A', quantity: 1, unitPrice: 13600),
      ]);
      n.setPayMode(0);
      n.setCurrencyAndPayments('YER_OLD', [
        const SalePaymentRow(
            accountId: 'acc',
            accountName: 'Bank',
            currency: 'USD',
            amount: 0,
            exchangeRate: 136),
      ]);
      // 13600 YER_OLD / 136 = 100 USD.
      expect(n.state.payments.first.amount, closeTo(100, 1e-6));
      expect(n.state.paid, closeTo(13600, 1e-6));
    });

    test('does not touch the amount for partial / credit', () {
      final n = SaleDraftNotifier();
      n.setItems([
        const SaleItem(description: 'A', quantity: 1, unitPrice: 30),
      ]);
      n.setPayMode(1);
      n.setPayments([
        const SalePaymentRow(
            accountId: 'acc', accountName: 'Bank', currency: 'USD', amount: 7),
      ]);
      expect(n.state.payments.first.amount, closeTo(7, 1e-6));
    });
  });

  group('multi-currency price resolution (scenarios 1-4)', () {
    test('catalogue sell price converted via the engine rate', () {
      final items = [
        const SaleItem(
            productId: 'A',
            description: 'A',
            unitPrice: 50,
            sellPrices: {'SAR': 50},
            priceCurrency: 'SAR'),
      ];
      // 1 SAR = 136 YER_OLD  →  50 × 136 = 6800.
      final out = resolveSalePrices(items, 'YER_OLD', (f, t) => 136);
      expect(out.first.unitPrice, closeTo(6800, 1e-6));
      expect(out.first.originalUnitPrice, closeTo(50, 1e-6));
      expect(out.first.exchangeRateUsed, closeTo(136, 1e-6));
    });

    test('per-currency price used directly (no conversion)', () {
      final items = [
        const SaleItem(
            productId: 'B',
            description: 'B',
            unitPrice: 50,
            sellPrices: {'SAR': 50, 'YER_OLD': 6000},
            priceCurrency: 'SAR'),
      ];
      final out = resolveSalePrices(items, 'YER_OLD', (f, t) => 136);
      expect(out.first.unitPrice, closeTo(6000, 1e-6));
      expect(out.first.exchangeRateUsed, 1);
    });

    test('manual edit preserved + converted on currency change (scenario 3)',
        () {
      // Merchant edited 6800 → 7000 in YER_OLD, then switched to SAR.
      final items = [
        const SaleItem(
            productId: 'A',
            description: 'A',
            unitPrice: 7000,
            priceManual: true,
            manualPriceCurrency: 'YER_OLD',
            sellPrices: {'SAR': 50},
            priceCurrency: 'SAR'),
      ];
      final out = resolveSalePrices(items, 'SAR',
          (f, t) => (f == 'YER_OLD' && t == 'SAR') ? 1 / 136 : null);
      // NOT the catalogue 50 — the edited value converted back.
      expect(out.first.unitPrice, closeTo(7000 / 136, 1e-4));
      expect(out.first.manualPriceCurrency, 'SAR');
      // FX snapshot invariant kept: invoice = original × rate.
      expect(out.first.priceCurrency, 'YER_OLD');
      expect(out.first.originalUnitPrice, closeTo(7000, 1e-6));
      expect(
          out.first.unitPrice,
          closeTo((out.first.originalUnitPrice!) *
              (out.first.exchangeRateUsed!), 1e-4));
    });

    test('manual edit kept as-is when the currency does not change', () {
      final items = [
        const SaleItem(
            productId: 'A',
            description: 'A',
            unitPrice: 7000,
            priceManual: true,
            manualPriceCurrency: 'YER_OLD'),
      ];
      final out = resolveSalePrices(items, 'YER_OLD', (f, t) => null);
      expect(identical(out, items), isTrue);
    });

    test('purchase: manual buy price converted on currency change', () {
      final items = [
        const SaleItem(
            productId: 'A',
            description: 'A',
            unitPrice: 3000,
            priceManual: true,
            manualPriceCurrency: 'YER_OLD',
            sellPrices: {'SAR': 20},
            priceCurrency: 'SAR'),
      ];
      final out = resolvePurchasePrices(items, 'SAR',
          (f, t) => (f == 'YER_OLD' && t == 'SAR') ? 1 / 136 : null);
      expect(out.first.unitPrice, closeTo(3000 / 136, 1e-4));
    });
  });

  group('FX guard: no silent 1:1 for item prices', () {
    void setup(SaleDraftNotifier n, SaleItem item) {
      n.setItems([item]);
      n.setCurrency('YER_OLD');
      n.setPayMode(0);
      n.setPayments([
        const SalePaymentRow(
            accountId: 'a', accountName: 'B', currency: 'YER_OLD', amount: 0),
      ]);
    }

    test('sale BLOCKS when a line has no rate and is not manual', () {
      final n = SaleDraftNotifier();
      setup(
          n,
          const SaleItem(
              productId: 'A',
              description: 'A',
              unitPrice: 50,
              sellPrices: {'USD': 50},
              priceCurrency: 'USD'));
      expect(n.validateForIssue(), 'saleErrItemRate');
    });

    test('sale passes when the line carries a converted (non-1:1) rate', () {
      final n = SaleDraftNotifier();
      setup(
          n,
          const SaleItem(
              productId: 'A',
              description: 'A',
              unitPrice: 6800,
              sellPrices: {'USD': 50},
              priceCurrency: 'USD',
              originalUnitPrice: 50,
              exchangeRateUsed: 136));
      expect(n.validateForIssue(), isNot('saleErrItemRate'));
    });

    test('sale passes when the line is priced manually', () {
      final n = SaleDraftNotifier();
      setup(
          n,
          const SaleItem(
              productId: 'A',
              description: 'A',
              unitPrice: 7000,
              priceManual: true,
              manualPriceCurrency: 'YER_OLD',
              priceCurrency: 'USD'));
      expect(n.validateForIssue(), isNot('saleErrItemRate'));
    });

    test('purchase BLOCKS a foreign-currency line with no rate', () {
      final n = PurchaseDraftNotifier();
      n.setItems([
        const SaleItem(
            productId: 'A',
            description: 'A',
            unitPrice: 20,
            sellPrices: {'USD': 20},
            priceCurrency: 'USD'),
      ]);
      n.setCurrency('YER_OLD');
      n.setPayMode(0);
      n.setPayments([
        const SalePaymentRow(
            accountId: 'a', accountName: 'B', currency: 'YER_OLD', amount: 0),
      ]);
      expect(n.validateForIssue(), 'saleErrItemRate');
    });
  });

  group('full payment across multiple accounts', () {
    test('editing the 2nd account deducts from the 1st (same currency)', () {
      final n = SaleDraftNotifier();
      n.setItems([const SaleItem(description: 'A', unitPrice: 100)]);
      n.setPayMode(0);
      n.setCurrencyAndPayments('SAR', [
        const SalePaymentRow(
            accountId: 'a', accountName: 'A', currency: 'SAR', amount: 100),
        const SalePaymentRow(
            accountId: 'b', accountName: 'B', currency: 'SAR', amount: 0),
      ]);
      n.setPaymentAmount(1, 30);
      expect(n.state.payments[1].amount, closeTo(30, 1e-6));
      expect(n.state.payments[0].amount, closeTo(70, 1e-6));
      expect(n.state.paid, closeTo(100, 1e-6));
    });

    test('cross-currency: distribution uses the frozen rate', () {
      final n = SaleDraftNotifier();
      n.setItems([const SaleItem(description: 'A', unitPrice: 13600)]);
      n.setPayMode(0);
      n.setCurrencyAndPayments('YER_OLD', [
        const SalePaymentRow(
            accountId: 'a',
            accountName: 'A',
            currency: 'YER_OLD',
            amount: 13600,
            exchangeRate: 1),
        const SalePaymentRow(
            accountId: 'b',
            accountName: 'B',
            currency: 'USD',
            amount: 0,
            exchangeRate: 136),
      ]);
      n.setPaymentAmount(1, 50); // 50 USD = 6800 YER_OLD
      expect(n.state.payments[0].amount, closeTo(6800, 1e-6));
      expect(n.state.paid, closeTo(13600, 1e-6));
      expect(n.state.remaining, closeTo(0, 1e-6));
    });

    test('single receiving account stays fully automatic', () {
      final n = SaleDraftNotifier();
      n.setItems([const SaleItem(description: 'A', unitPrice: 100)]);
      n.setPayMode(0);
      n.setCurrencyAndPayments('SAR', [
        const SalePaymentRow(
            accountId: 'a', accountName: 'A', currency: 'SAR', amount: 0),
      ]);
      expect(n.state.payments[0].amount, closeTo(100, 1e-6));
    });

    test('three accounts: the first absorbs the remainder', () {
      final n = SaleDraftNotifier();
      n.setItems([const SaleItem(description: 'A', unitPrice: 100)]);
      n.setPayMode(0);
      n.setCurrencyAndPayments('SAR', [
        const SalePaymentRow(
            accountId: 'a', accountName: 'A', currency: 'SAR', amount: 100),
        const SalePaymentRow(
            accountId: 'b', accountName: 'B', currency: 'SAR', amount: 0),
        const SalePaymentRow(
            accountId: 'c', accountName: 'C', currency: 'SAR', amount: 0),
      ]);
      n.setPaymentAmount(1, 20);
      expect(n.state.payments[0].amount, closeTo(80, 1e-6));
      n.setPaymentAmount(2, 30);
      expect(n.state.payments[0].amount, closeTo(50, 1e-6));
      expect(n.state.paid, closeTo(100, 1e-6));
      expect(n.state.remaining, closeTo(0, 1e-6));
    });

    test('deleting a split row rebalances the first to the whole total', () {
      final n = SaleDraftNotifier();
      n.setItems([const SaleItem(description: 'A', unitPrice: 100)]);
      n.setPayMode(0);
      n.setCurrencyAndPayments('SAR', [
        const SalePaymentRow(
            accountId: 'a', accountName: 'A', currency: 'SAR', amount: 100),
        const SalePaymentRow(
            accountId: 'b', accountName: 'B', currency: 'SAR', amount: 0),
      ]);
      n.setPaymentAmount(1, 40);
      expect(n.state.payments[0].amount, closeTo(60, 1e-6));
      // Remove the second row -> single account -> first takes the whole total.
      n.setPayments([n.state.payments[0]]);
      expect(n.state.payments[0].amount, closeTo(100, 1e-6));
      expect(n.state.remaining, closeTo(0, 1e-6));
    });

    test('over-total distribution: first becomes 0, others unchanged', () {
      final n = SaleDraftNotifier();
      n.setItems([const SaleItem(description: 'A', unitPrice: 100)]);
      n.setPayMode(0);
      n.setCurrencyAndPayments('SAR', [
        const SalePaymentRow(
            accountId: 'a', accountName: 'A', currency: 'SAR', amount: 100),
        const SalePaymentRow(
            accountId: 'b', accountName: 'B', currency: 'SAR', amount: 0),
        const SalePaymentRow(
            accountId: 'c', accountName: 'C', currency: 'SAR', amount: 0),
      ]);
      n.setPaymentAmount(1, 60);
      n.setPaymentAmount(2, 50);
      // The balancing first account is clamped to 0; the others keep theirs.
      expect(n.state.payments[0].amount, closeTo(0, 1e-6));
      expect(n.state.payments[1].amount, closeTo(60, 1e-6));
      expect(n.state.payments[2].amount, closeTo(50, 1e-6));
      expect(n.state.paid, closeTo(110, 1e-6));
      // Blocked until the accountant fixes the split.
      expect(n.validateForIssue(), 'saleErrOverpaid');
    });
  });

  group('purchase full payment auto-sync', () {
    test('fills the whole total and re-syncs on currency change', () {
      final n = PurchaseDraftNotifier();
      n.setItems([
        const SaleItem(description: 'A', quantity: 5, unitPrice: 20),
      ]);
      n.setPayMode(0);
      n.setPayments([
        const SalePaymentRow(
            accountId: 'acc', accountName: 'Bank', currency: 'USD', amount: 0),
      ]);
      expect(n.state.payments.first.amount, closeTo(100, 1e-6));

      n.setItems([
        const SaleItem(description: 'A', quantity: 5, unitPrice: 3000),
      ]);
      n.setCurrencyAndPayments('YER_OLD', [
        const SalePaymentRow(
            accountId: 'acc',
            accountName: 'Bank',
            currency: 'YER_OLD',
            amount: 100),
      ]);
      expect(n.state.payments.first.amount, closeTo(15000, 1e-6));
      expect(n.state.remaining, closeTo(0, 1e-6));
    });
  });
}
