import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/personal/data/peer_store.dart';

void main() {
  final snapshot = {
    'kind': 'customer',
    'published_at': '2026-11-24T10:00:00Z',
    'debts': [
      {'currency': 'YER_OLD', 'remaining_minor': 1700, 'paid_minor': 2300},
    ],
    'operations': [
      {'id': 'op1', 'number': 'APP-1', 'date': '2026-11-20', 'currency': 'YER_OLD',
       'total_minor': 4000, 'paid_minor': 2300, 'remaining_minor': 1700},
    ],
  };

  test('the customer sees the merchant debts from the device copy', () {
    final view = PeerDebtViews.overview(snapshot, 'link', displayCurrency: 'YER_OLD');
    expect(view['remaining_total'], '17.00');
    expect(view['paid_total'], '23.00');
    expect(view['grand_total'], '40.00');
    expect(view['fx_missing'], isEmpty);
    final op = (view['operations'] as List).single as Map;
    expect(op['status'], 'partial');
    expect(op['type'], 'sale');
    expect(PeerDebtViews.debtRows(snapshot), [
      {'currency': 'YER_OLD', 'debt': '17.00'},
    ]);
  });

  test('another display currency is never summed without a rate', () {
    final view = PeerDebtViews.overview(snapshot, 'link', displayCurrency: 'USD');
    expect(view['remaining_total'], isNull);
    expect(view['fx_missing'], ['YER_OLD']);
  });

  test('another currency is converted with the rates saved on the device', () {
    final view = PeerDebtViews.overview(snapshot, 'link', displayCurrency: 'USD',
        rate: (from, to) => from == 'YER_OLD' && to == 'USD' ? 1 / 500 : null);
    expect(view['remaining_total'], '0.03');
    expect(view['fx_missing'], isEmpty);
  });
}
