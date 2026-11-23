import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/inventory/presentation/pages/product_detail_page.dart';

/// Issue #4 — the extra-units section shows the REAL quantity in each unit,
/// derived from the unit's actual conversion factor (whole units + leftover
/// base units), never a fabricated balance.
void main() {
  test('available quantity per unit uses the real factor', () {
    expect(productUnitAvailableText(96, 8, 'باكيت', 'قطعة'), '12 باكيت');
    expect(productUnitAvailableText(100, 8, 'باكيت', 'قطعة'),
        '12 باكيت + 4 قطعة');
    expect(productUnitAvailableText(3, 8, 'باكيت', 'قطعة'), '3 قطعة');
    expect(productUnitAvailableText(100, 1, 'قطعة', 'قطعة'), '100 قطعة');
    expect(productUnitAvailableText(0, 8, 'باكيت', 'قطعة'), '0 باكيت');
    expect(productUnitAvailableText(240, 24, 'كرتون', 'قطعة'), '10 كرتون');
  });
}
