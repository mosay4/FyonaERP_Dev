import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';

/// Proves the plans-pricing model: plan prices are stored in USD and convert
/// correctly to world currencies (exchangerate-api style per-USD rates) and
/// to Yemeni Rials (2dec.net style sanaa/aden quotes).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<CurrencyEngine> engineWith({
    required Map<String, double> global,
    Map<String, dynamic> sanaa = const {},
    Map<String, dynamic> aden = const {},
  }) async {
    SharedPreferences.setMockInitialValues({
      'currency_engine_cache_time': DateTime.now().toIso8601String(),
      'currency_engine_cache': jsonEncode({
        'version': 2,
        'approved': true,
        'global_source': 'exchangerate-api.com',
        'global_rates': global,
        'yemen_sanaa': sanaa,
        'yemen_aden': aden,
        'last_updated': DateTime.now().toIso8601String(),
        'source': '2dec.net',
        'fetched_at': DateTime.now().toIso8601String(),
      }),
    });
    final engine = CurrencyEngine(apiClient: null);
    await engine.load();
    return engine;
  }

  test('USD base converts to world currencies per-USD rates', () async {
    final e = await engineWith(
      global: {'USD': 1.0, 'SAR': 3.75, 'EUR': 0.92, 'AED': 3.67},
    );
    expect(e.convert(100, 'USD', 'USD'), 100);
    expect(e.convert(100, 'USD', 'SAR'), closeTo(375, 0.001));
    expect(e.convert(100, 'USD', 'EUR'), closeTo(92, 0.001));
    expect(e.convert(100, 'SAR', 'USD'), closeTo(100 / 3.75, 0.001));
    expect(e.convert(50, 'USD', 'AED'), closeTo(183.5, 0.001));
  });

  test('USD converts to YER_OLD via sanaa quote, round-trips back', () async {
    final e = await engineWith(
      global: {'USD': 1.0, 'SAR': 3.75},
      sanaa: {
        'USD': {'average': 530.0},
        'SAR': {'average': 141.0},
      },
    );
    expect(e.convert(100, 'USD', 'YER_OLD'), closeTo(53000, 0.001));
    expect(e.convert(53000, 'YER_OLD', 'USD'), closeTo(100, 0.001));
    expect(e.convert(100, 'USD', 'SAR'), closeTo(375, 0.001));
  });

  test('USD converts to YER_NEW via live aden quote (not hardcoded)', () async {
    final e = await engineWith(
      global: {'USD': 1.0, 'SAR': 3.75},
      aden: {
        'USD': {'average': 1600.0},
      },
    );
    expect(e.convert(100, 'USD', 'YER_NEW'), closeTo(160000, 0.001));
    expect(e.convert(160000, 'YER_NEW', 'USD'), closeTo(100, 0.001));
  });

  test(
    'YER_NEW never invents 1542 when an approved Aden quote is missing',
    () async {
      final e = await engineWith(global: {'USD': 1.0});
      expect(e.convertSafe(1, 'USD', 'YER_NEW'), isNull);
    },
  );

  test('same currency and unknown currency behave safely', () async {
    final e = await engineWith(global: {'USD': 1.0, 'SAR': 3.75});
    expect(e.convert(42, 'USD', 'USD'), 42);
    expect(e.convert(42, 'XXX', 'USD'), 0);
  });
}
