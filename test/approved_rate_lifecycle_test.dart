import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/di/providers.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';

Map<String, dynamic> snapshot({
  Map<String, dynamic>? global,
  Map<String, dynamic>? aden,
}) => {
  'global': global ?? {'USD': 1, 'SAR': 3.75, 'EUR': .92, 'JPY': 160},
  'yemen': {
    'source': 'store',
    'sanaa': {
      'USD': {'average': 534},
      'SAR': {'average': 140},
    },
    'aden':
        aden ??
        {
          'USD': {'average': 1600},
          'SAR': {'average': 410},
        },
  },
  'meta': {'global_source': 'store', 'fetched_at': '2026-01-01T00:00:00Z'},
};

void seed() {
  SharedPreferences.setMockInitialValues({
    'currency_engine_cache_time': '2020-01-01T00:00:00Z',
    'currency_engine_cache': jsonEncode({
      'version': 2,
      'approved': true,
      'global_source': 'store',
      'source': 'store',
      'global_rates': {'USD': 1, 'SAR': 3.75, 'EUR': .92, 'JPY': 160},
      'yemen_sanaa': {
        'USD': {'average': 534},
        'SAR': {'average': 140},
      },
      'yemen_aden': {
        'USD': {'average': 1600},
        'SAR': {'average': 410},
      },
      'fetched_at': '2020-01-01T00:00:00Z',
    }),
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'approved cache does not expire or disappear after years offline',
    () async {
      seed();
      final engine = CurrencyEngine();
      await engine.load();
      expect(engine.getRate('USD', 'SAR'), 3.75);
      expect(engine.getRate('USD', 'YER_NEW'), 1600);
      expect(engine.getRate('YER_OLD', 'YER_NEW'), closeTo(1600 / 534, 1e-10));
      expect(engine.freshness, RateFreshness.expired);
      expect(
        engine.sumConverted([(32.0, 'USD'), (280.0, 'YER_OLD')], 'SAR'),
        122,
      );
    },
  );

  test(
    'simultaneous refreshes coalesce and incomplete responses never erase rates',
    () async {
      seed();
      final dio = Dio();
      var calls = 0;
      final received = Completer<void>(), release = Completer<void>();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) async {
            calls++;
            if (!received.isCompleted) received.complete();
            await release.future;
            h.resolve(
              Response(
                requestOptions: o,
                data: {
                  'data': snapshot(global: {'USD': 1, 'SAR': 4}, aden: {}),
                },
              ),
            );
          },
        ),
      );
      final engine = CurrencyEngine(apiClient: ApiClient(dio: dio));
      await engine.load();
      final all = Future.wait(
        List.generate(20, (_) => engine.refreshIfStale(maxAge: Duration.zero)),
      );
      await received.future;
      expect(calls, 1);
      release.complete();
      await all;
      expect(engine.getRate('USD', 'SAR'), 4);
      expect(engine.getRate('USD', 'EUR'), .92);
      expect(engine.getRate('USD', 'YER_NEW'), 1600);
      await engine.load();
      expect(calls, 1);
      final restored = CurrencyEngine();
      await restored.load();
      expect(restored.getRate('USD', 'SAR'), 4);
      expect(restored.getRate('USD', 'YER_NEW'), 1600);
      dio.close();
    },
  );

  test(
    'failed refresh preserves all approved currencies and original timestamps',
    () async {
      seed();
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) => h.reject(
            DioException(
              requestOptions: o,
              type: DioExceptionType.connectionError,
            ),
          ),
        ),
      );
      final engine = CurrencyEngine(apiClient: ApiClient(dio: dio));
      await engine.load();
      await engine.refreshIfStale(maxAge: Duration.zero);
      expect(engine.getRate('USD', 'SAR'), 3.75);
      expect(engine.getRate('USD', 'YER_NEW'), 1600);
      expect(engine.fetchedAt, DateTime.parse('2020-01-01T00:00:00Z'));
      expect(
        () => engine.sumConverted([(10.0, 'USD'), (5.0, 'UNSEEN')], 'SAR'),
        throwsA(isA<MissingExchangeRate>()),
      );
      dio.close();
    },
  );

  test(
    'one refresh per offline-to-online edge, never per branch switch',
    () async {
      seed();
      final dio = Dio();
      var calls = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            calls++;
            h.resolve(Response(requestOptions: o, data: {'data': snapshot()}));
          },
        ),
      );
      final connectivity = ConnectivityService(debugOnline: false);
      final container = ProviderContainer(
        overrides: [
          dioProvider.overrideWithValue(dio),
          connectivityServiceProvider.overrideWithValue(connectivity),
        ],
      );
      final engine = container.read(currencyEngineProvider);
      await engine.load();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 0);
      connectivity.debugSetOnline(true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(calls, 1);
      connectivity.debugSetOnline(true);
      container.read(branchEpochProvider.notifier).state++;
      expect(container.read(currencyEngineProvider), same(engine));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 1);
      connectivity.debugSetOnline(false);
      connectivity.debugSetOnline(true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(calls, 2);
      container.dispose();
      connectivity.dispose();
      dio.close();
    },
  );
}
