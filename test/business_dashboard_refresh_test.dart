import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/network/dio_provider.dart'
    show apiClientProvider;
import 'package:fyona_flutter/features/business_banks/presentation/providers/local_business_banking.dart';
import 'package:fyona_flutter/features/dashboard/presentation/pages/business_dashboard_page.dart';
import 'package:fyona_flutter/features/dashboard/presentation/providers/business_dashboard_providers.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/widgets/home_account_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'dashboard holds and releases cards gently without waiting on I/O or drawing a spinner',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.runAsync(() => AppLocalizations.preload('ar'));
      final slow = Completer<List<PersonalBankAccount>>();
      final slowOps = Completer<List<Map<String, dynamic>>>();
      var reads = 0;
      var readsOps = 0;
      final rows = <PersonalBankAccount>[
        PersonalBankAccount(
          id: 'account',
          bankName: 'بنك تجريبي',
          balance: 3000,
          currency: 'YER_OLD',
          accountType: 'checking',
        ),
      ];
      final movements = <Map<String, dynamic>>[
        {
          'source_type': 'invoice',
          'source_id': 'sale',
          'kind': 'sale',
          'direction': 'in',
          'reference': 'INV-REFRESH-FIXTURE',
          'amount': 150.0,
          'currency': 'YER_OLD',
        },
      ];
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.example.test'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (r, h) {
              // Existing promotional banners are unrelated to operations/refresh.
              h.resolve(
                Response(
                  requestOptions: r,
                  data: {
                    'success': true,
                    'data': {'banners': []},
                  },
                ),
              );
            },
          ),
        );
      addTearDown(() => dio.close(force: true));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
            employeeCanProvider.overrideWith(
              (_, key) => key == 'banks.balances' || key == 'transactions',
            ),
            localBusinessBankingProvider.overrideWithValue(null),
            businessAccountsProvider.overrideWith((_) async {
              reads++;
              if (reads == 1) return rows;
              return slow.future;
            }),
            businessRecentProvider.overrideWith((_) async {
              readsOps++;
              if (readsOps == 1) return movements;
              return slowOps.future;
            }),
          ],
          child: MaterialApp(
            locale: const Locale('ar'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: const Scaffold(body: BusinessDashboardPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final card = find.byType(HomeAccountCard);
      final operation = find.text('INV-REFRESH-FIXTURE');
      expect(operation, findsOneWidget);
      final original = tester.getTopLeft(card).dy;
      await tester.timedDragFrom(
        const Offset(395, 60),
        const Offset(0, 380),
        const Duration(milliseconds: 410),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 130));
      expect(reads, 2);
      expect(readsOps, 2);
      expect(find.text('بنك تجريبي'), findsOneWidget);
      expect(operation, findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.getTopLeft(card).dy, greaterThan(original + 10));
      // A slow or disconnected source cannot keep the cards held down.
      await tester.pumpAndSettle(const Duration(milliseconds: 35));
      expect(tester.getTopLeft(card).dy, closeTo(original, 1));
      expect(slow.isCompleted, isFalse);
      expect(slowOps.isCompleted, isFalse);
      expect(find.text('بنك تجريبي'), findsOneWidget);
      expect(operation, findsOneWidget);
      slow.complete(rows);
      slowOps.complete(movements);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
