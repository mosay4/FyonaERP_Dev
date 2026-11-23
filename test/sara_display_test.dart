import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/ai/domain/agent/sara_display.dart';

void main() {
  test('confirmation shows names, translated labels and currencies without IDs', () {
    final rows = saraDetailRows({'from_account_id': 'uuid-secret', 'from_account_name': 'كاش',
      'amount': 400, 'from_currency': 'USD', 'exchange_rate': 3.75}, arabic: true);
    expect(rows.first.value, 'كاش');
    expect(rows.map((r) => r.key).join(), isNot(contains('from_account_id')));
    expect(rows.map((r) => r.value).join(), isNot(contains('uuid-secret')));
    expect(rows.map((r) => r.value), contains('دولار أمريكي'));
  });
  test('Arabic uses masculine address and currency names but preserves document numbers', () {
    expect(saraDisplayText('راجعي 100 USD وأكدي INV-2026-01', arabic: true),
      'راجع 100 دولار أمريكي وأكد INV-2026-01');
    expect(saraDisplayText('100 USD', arabic: false), '100 USD');
  });
}
