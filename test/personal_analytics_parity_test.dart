import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_analytics.dart';

/// Parity with the backend: test/fixtures/personal_analytics_parity.json
/// holds the outputs of the REAL Python build_financial_analytics
/// (backend/tests/unit/test_sara_personal_analytics_parity.py).
void main() {
  final fixture = jsonDecode(File('test/fixtures/personal_analytics_parity.json').readAsStringSync())
      as Map<String, dynamic>;
  List<Map<String, dynamic>> rows(String key) =>
      [for (final r in fixture[key] as List) Map<String, dynamic>.from(r as Map)];

  for (final c in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
    test('device analytics == Python analytics (${c['name']})', () {
      final expected = Map<String, dynamic>.from(c['expected'] as Map);
      final meta = expected['meta'] as Map<String, dynamic>;
      final got = PersonalAnalytics.build(
        accounts: rows('accounts'),
        transactions: rows('transactions'),
        budgets: rows('budgets'),
        goals: rows('goals'),
        debts: rows('debts'),
        recurring: rows('recurring'),
        bounds: AnalyticsBounds(
          period: meta['period'], start: meta['period_start'], end: meta['period_end'],
          prevStart: meta['prev_start'], prevEnd: meta['prev_end'], timezone: meta['timezone']),
      );
      final normalized = jsonDecode(jsonEncode(got)) as Map<String, dynamic>;
      expect(normalized['meta']['source'], 'device');
      (normalized['meta'] as Map).remove('source');
      (normalized['meta'] as Map).remove('generated_at');
      for (final key in expected.keys) {
        expect(const DeepCollectionEquality().equals(normalized[key], expected[key]), isTrue,
            reason: '$key differs:\n${jsonEncode(normalized[key])}\n!=\n${jsonEncode(expected[key])}');
      }
      expect(normalized.keys.toSet(), expected.keys.toSet());
    });
  }

  group('PyDecimal matches Python decimal', () {
    PyDecimal d(String s) => PyDecimal.parse(s);
    test('division keeps the ideal exponent or 28 digits', () {
      expect('${d('150.00') / d('3')}', '50.00');
      expect('${d('35.00') / d('3')}', '11.66666666666666666666666667');
      expect('${d('800.00') / d('10000.00')}', '0.08');
      expect('${d('300.00') / d('100.00')}', '3');
      expect('${(d('36.00') / (d('35.00') / d('3'))).quantize(-1)}', '3.1');
    });
    test('quantize is half-even and keeps the sign of zero', () {
      expect('${d('0.25').quantize(-1)}', '0.2');
      expect('${d('0.35').quantize(-1)}', '0.4');
      expect('${d('-0.04').quantize(-1)}', '-0.0');
      expect('${d('3').quantize(-1)}', '3.0');
    });
    test('addition keeps the larger scale; money is NUMERIC(12,2)', () {
      expect('${PyDecimal.zero + d('10.00')}', '10.00');
      expect('${d('10.00') - d('10.00')}', '0.00');
      expect('${PyDecimal.money(100.5)}', '100.50');
      expect('${PyDecimal.money('40')}', '40.00');
      expect('${d('0.0000001')}', '1E-7');
    });
  });
}
