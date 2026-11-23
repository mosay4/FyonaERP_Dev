import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/services/units/unit_breakdown.dart';

void main() {
  test('99 pieces across six count units decomposes without loss', () {
    final units = [
      const UnitBreakdownInput(name: 'قطعة', factor: 1, group: 'count'),
      const UnitBreakdownInput(name: 'باكيت', factor: 8, group: 'count'),
      const UnitBreakdownInput(name: 'كرتونة', factor: 16, group: 'count'),
      const UnitBreakdownInput(name: 'كرتون', factor: 32, group: 'count'),
      const UnitBreakdownInput(name: 'صندوق', factor: 64, group: 'count'),
      const UnitBreakdownInput(name: 'طرد', factor: 128, group: 'count'),
    ];
    final parts = decomposeCountUnits(99, units);
    expect(formatUnitBreakdown(parts),
        '1 صندوق + 1 كرتون + 3 قطعة');
    final total = parts.fold<double>(0, (s, p) => s + p.qty * p.factor);
    expect(total, 99);
  });

  test('from a pack starts at pack and keeps the exact remainder', () {
    final units = [
      const UnitBreakdownInput(name: 'قطعة', factor: 1, group: 'count'),
      const UnitBreakdownInput(name: 'باكيت', factor: 8, group: 'count'),
      const UnitBreakdownInput(name: 'كرتون', factor: 64, group: 'count'),
    ];
    expect(
        formatUnitBreakdown(
            decomposeCountUnits(99, units, fromFactor: 8)),
        '12 باكيت + 3 قطعة');
    expect(
        formatUnitBreakdown(
            decomposeCountUnits(99, units, fromFactor: 64)),
        '1 كرتون + 4 باكيت + 3 قطعة');
  });
}
