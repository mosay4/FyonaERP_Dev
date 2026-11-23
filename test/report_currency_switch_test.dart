import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_report_fx.dart';
import 'package:fyona_flutter/features/reports/data/report_currency.dart';

void main() {
  final fx = BusinessReportFx([
    ('USD', 'YER_OLD', '500', DateTime(2026, 11, 1).microsecondsSinceEpoch),
    ('USD', 'YER_OLD', '1000', DateTime(2026, 11, 20).microsecondsSinceEpoch),
    ('USD', 'SAR', '3.75', null),
  ]);

  test('every detail row follows the chosen report currency', () {
    final report = convertReportRows({
      'currency': 'USD',
      'sales': {'total': '135.00', 'per_currency': []},
      'invoices': [
        {
          'number': 'INV-1',
          'currency': 'YER_OLD',
          'total': '67500.00',
          'paid': '47500.00',
          'balance': '20000.00',
          'date': '2026-11-10',
        },
      ],
      'accounts': [
        {'currency': 'SAR', 'balance': '375.00', 'inflow': null},
      ],
      'customers': {
        'top': [
          {
            'name': 'عميل',
            'debts': [
              {'currency': 'YER_OLD', 'total': '20000.00'},
              {'currency': 'USD', 'total': '5.00'},
            ],
          },
        ],
      },
      'gaps': [
        {'currency': 'EUR'},
      ],
    }, fx);

    final invoice = (report['invoices'] as List).single as Map;
    // Dated row: the rate in force on its day (500), not today's (1000).
    expect(invoice['currency'], 'USD');
    expect(invoice['total'], '135.00');
    expect(invoice['paid'], '95.00');
    expect(invoice['balance'], '40.00');
    expect(invoice['original_currency'], 'YER_OLD');
    expect(invoice['original_total'], '67500.00');

    final account = (report['accounts'] as List).single as Map;
    expect(account['currency'], 'USD');
    expect(account['balance'], '100.00');

    final debts =
        (((report['customers'] as Map)['top'] as List).single as Map)['debts'];
    // Current balance at the latest rate (1000), merged into one amount.
    expect(debts, [
      {'currency': 'USD', 'total': '25.00'},
    ]);
    // Rows with no amounts are left alone.
    expect(report['gaps'], [
      {'currency': 'EUR'},
    ]);
    expect((report['sales'] as Map)['total'], '135.00');
  });

  test('an operation before the first saved rate still converts', () {
    expect(
      fx.convert(
        BigInt.from(50000),
        'YER_OLD',
        'USD',
        operationUs: DateTime(2026, 10, 1).microsecondsSinceEpoch,
      ),
      BigInt.from(100),
    );
  });
}
