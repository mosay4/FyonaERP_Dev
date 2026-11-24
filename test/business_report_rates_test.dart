import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/di/providers.dart' show apiClientProvider;
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_money.dart';
import 'package:fyona_flutter/features/reports/data/business_report_rates.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

DateTime _day(int day) => DateTime.utc(2026, 1, day);

Map<String, dynamic> _publication(
  int day, {
  double sar = 4,
  int oldYer = 500,
  int? oldSar = 120,
  String source = 'store',
}) => {
  'global': {'USD': 1, 'SAR': sar, 'EUR': .9, 'YER': 2, 'CAD': 1.3},
  'yemen': {
    'source': source,
    'sanaa': {
      'USD': {'average': oldYer},
      if (oldSar != null) 'SAR': {'average': oldSar},
    },
    'aden': {
      'USD': {'average': 1500},
    },
  },
  'meta': {
    'global_source': source,
    'observations': {
      for (final code in ['SAR', 'EUR', 'YER_OLD', 'YER_NEW'])
        code: {'source': source, 'observed_at': _day(day).toIso8601String()},
    },
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Business entry warms FX on reconnect without waiting for the network',
    () async {
      SharedPreferences.setMockInitialValues({});
      final connectivity = ConnectivityService(debugOnline: false);
      addTearDown(connectivity.dispose);
      final workspace = DirectoryWorkspace(
        server: 'https://rates.fixture.test/api/v1',
        accountId: const Uuid().v4(),
        organizationId: const Uuid().v4(),
      );
      final scope = DirectoryAccess(
        workspace: workspace,
        branchId: const Uuid().v4(),
        financialCutover: true,
        readable: {},
        writable: {},
      );
      final dio = Dio();
      addTearDown(dio.close);
      final requested = Completer<void>(), release = Completer<void>();
      final calls = <String>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (opts, h) async {
            calls.add('${opts.method} ${opts.path}');
            requested.complete();
            await release.future;
            h.resolve(
              Response(requestOptions: opts, data: {'data': _publication(1)}),
            );
          },
        ),
      );
      final container = ProviderContainer(
        overrides: [
          businessLocalLedgerScopeProvider.overrideWithValue(scope),
          connectivityServiceProvider.overrideWithValue(connectivity),
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        ],
      );
      addTearDown(container.dispose);
      container.listen(businessReportRateWarmupProvider, (_, _) {});
      final store = container.read(businessReportRatesProvider)!;
      await store.read(); // completes before the offline-to-online transition
      expect(calls, isEmpty);
      final published = Completer<void>();
      container.listen(businessReportRateRevisionProvider, (_, next) {
        if (next == 1) published.complete();
      });
      connectivity.debugSetOnline(true);
      await requested.future.timeout(const Duration(seconds: 2));
      expect((await store.read()).convert(BigInt.one, 'USD', 'SAR'), isNull);
      release.complete();
      await published.future.timeout(const Duration(seconds: 2));
      final online = await store.read();
      expect(online.convert(BigInt.from(100), 'USD', 'SAR'), BigInt.from(400));
      connectivity.debugSetOnline(false);
      expect(await store.read(), same(online));
      expect(calls, ['GET /personal/exchange-rates']);
    },
  );

  test(
    'dated and frozen FX, latest FX, pending network and durable isolation',
    () async {
      SharedPreferences.setMockInitialValues({
        'currency_engine_cache': 'personal-untouched',
      });
      final rates = BusinessReportRates('workspace-A');
      final release = Completer<Map>();
      final pending = rates.refresh(() => release.future, now: _day(1));
      final before = await rates.read();
      expect(before.convert(BigInt.one, 'USD', 'SAR'), isNull);
      release.complete(_publication(1));
      expect(await pending, isTrue);
      final old = await rates.read();
      expect(
        old.convert(BigInt.from(120), 'SAR', 'YER_OLD'),
        BigInt.from(14400),
      );
      expect(
        old.convert(BigInt.from(67480), 'YER_OLD', 'USD'),
        BigInt.from(135),
      );
      expect(
        old.convert(BigInt.from(500), 'YER_OLD', 'YER_NEW'),
        BigInt.from(1500),
      );
      // «YER» is the app's name for the Aden rial (YER_NEW) everywhere.
      expect(old.convert(BigInt.from(500), 'YER', 'USD'),
          old.convert(BigInt.from(500), 'YER_NEW', 'USD'));
      expect(old.convert(BigInt.from(500), 'YER_OLD', 'YER'), BigInt.from(1500));
      expect(old.convert(BigInt.from(100), 'USD', 'CAD'), BigInt.from(130));
      expect(
        old.convert(
          BigInt.from(100),
          'USD',
          'CAD',
          operationUs: _day(2).microsecondsSinceEpoch,
        ),
        // Owner's rule: a report in the chosen currency always converts.
        // Without a dated rate, the saved approved rate values the amount.
        BigInt.from(130),
      );
      expect(
        await rates.refresh(
          () async => _publication(3, sar: 5, oldYer: 1000, oldSar: null),
          now: _day(3),
        ),
        isTrue,
      );
      // A late response cannot restore the old independent SAR/YER quote.
      expect(
        await rates.refresh(
          () async => _publication(2, sar: 3, oldYer: 455),
          now: _day(4),
        ),
        isFalse,
      );
      expect(
        await rates.refresh(
          () async => _publication(9, sar: 2, source: 'fallback'),
          now: _day(10),
        ),
        isFalse,
      );
      expect(
        await rates.refresh(() => throw StateError('airplane mode')),
        isFalse,
      );
      expect(
        await rates.refresh(
          () async => _publication(5, sar: 5, oldYer: 1000, oldSar: null),
          now: _day(5),
        ),
        isFalse, // Same values, but keep the approval watermark.
      );
      expect(
        await BusinessReportRates('workspace-A').refresh(
          () async => _publication(4, sar: 2, oldYer: 450),
          now: _day(6),
        ),
        isFalse,
      );

      final restored = await BusinessReportRates('workspace-A').read();
      expect(
        restored.convert(BigInt.from(20000), 'YER_OLD', 'USD'),
        BigInt.from(20),
      );
      expect(
        restored.convert(BigInt.from(100), 'SAR', 'YER_OLD'),
        BigInt.from(20000),
      );
      final prior = _day(2).microsecondsSinceEpoch;
      expect(
        restored.convert(
          BigInt.from(20000),
          'YER_OLD',
          'USD',
          operationUs: prior,
        ),
        BigInt.from(40),
      );
      expect(
        restored.convert(
          BigInt.from(100),
          'USD',
          'SAR',
          operationUs: prior,
          frozen: BusinessRate('USD', 'SAR', '3.75'),
        ),
        BigInt.from(375),
      );
      expect(
        restored.convert(
          BigInt.from(100),
          'USD',
          'EUR',
          operationUs: _day(
            1,
          ).subtract(const Duration(microseconds: 1)).microsecondsSinceEpoch,
        ),
        // Recorded before the first saved rate: valued with the earliest
        // approved rate instead of staying unconverted.
        BigInt.from(90),
      );
      expect(
        old.convert(BigInt.from(20000), 'YER_OLD', 'USD'),
        BigInt.from(40),
      );
      final isolated = await BusinessReportRates('workspace-B').read();
      expect(isolated.convert(BigInt.from(20000), 'YER_OLD', 'USD'), isNull);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'currency_engine_cache',
        ),
        'personal-untouched',
      );
    },
  );
}
