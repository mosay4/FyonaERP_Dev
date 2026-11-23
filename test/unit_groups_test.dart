import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/services/units/custom_units.dart';

/// Unit classification + compatibility helpers (Business only).
void main() {
  test('units are classified into the correct measurement family', () {
    for (final n in ['قطعة', 'درزن', 'باكيت', 'علبة', 'كرتون', 'كرتونة']) {
      expect(unitGroupOfName(n), 'count', reason: n);
    }
    for (final n in ['كيلو', 'جرام', 'طن']) {
      expect(unitGroupOfName(n), 'weight', reason: n);
    }
    expect(unitGroupOfName('لتر'), 'volume');
    expect(unitGroupOfName('متر'), 'length');
    expect(unitGroupOfName('متر مربع'), 'area');
    for (final n in ['ساعة', 'يوم']) {
      expect(unitGroupOfName(n), 'time', reason: n);
    }
    for (final n in ['خدمة', 'خدمة إلكترونية']) {
      expect(unitGroupOfName(n), 'service', reason: n);
    }
    expect(unitGroupOfName('غير معروف'), isNull);
  });

  test('liter/meter are NOT weight (previous mis-classification fixed)', () {
    final liter = defaultUnits.firstWhere((u) => u.name == 'لتر');
    expect(liter.weight, isFalse);
    expect(liter.group, 'volume');
    final meter = defaultUnits.firstWhere((u) => u.name == 'متر');
    expect(meter.weight, isFalse);
    expect(meter.group, 'length');
    final m2 = defaultUnits.firstWhere((u) => u.name == 'متر مربع');
    expect(m2.weight, isFalse);
    expect(m2.group, 'area');
  });

  test('packaging factors are neutral (set per product, never mandatory)', () {
    for (final n in ['باكيت', 'علبة', 'كرتون', 'كرتونة']) {
      expect(defaultUnits.firstWhere((u) => u.name == n).factor, 1, reason: n);
    }
    // Fixed, well-known conversions stay exact.
    expect(defaultUnits.firstWhere((u) => u.name == 'درزن').factor, 12);
    expect(defaultUnits.firstWhere((u) => u.name == 'طن').factor, 1000);
  });

  test('measurement-group labels', () {
    expect(unitGroupLabel('count', isAr: true), 'العدد والتغليف');
    expect(unitGroupLabel('weight', isAr: true), 'الوزن');
    expect(unitGroupLabel('volume', isAr: true), 'الحجم');
    expect(unitGroupLabel('count', isAr: false), 'Count / packaging');
  });
}
