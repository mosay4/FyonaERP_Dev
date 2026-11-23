import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/currency/business_currency_scope.dart';
import 'package:fyona_flutter/features/branches/data/branch_api.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/business_banks/presentation/providers/business_banks_providers.dart';
import 'package:fyona_flutter/features/core_business/data/project_settings_api.dart';
import 'package:fyona_flutter/features/profile/presentation/pages/profile_page.dart';

class _SharedSettings extends ProjectSettingsApi {
  _SharedSettings() : super(ApiClient(dio: Dio()));
  Set<String> currencies = {'SAR', 'USD'};
  int loads = 0;
  @override
  Future<Map<String, dynamic>> load() async {
    loads++;
    return {'enabled_currencies': currencies.toList()};
  }
}

class _Branches extends BranchApi {
  _Branches(this.settings) : super(ApiClient(dio: Dio()));
  final _SharedSettings settings;
  @override
  Future<void> saveCurrencies(List<String> currencies) async {
    settings.currencies = currencies.toSet();
  }
}

class _Banks extends StateNotifier<BusinessBanksState>
    implements BusinessBanksNotifier {
  _Banks() : super(const BusinessBanksState());
  @override
  Future<void> load() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Cash implements BizCashService {
  @override
  Future<void> ensureCashAccounts(
    List<String> wanted, {
    Set<String>? enabled,
    String userId = '',
  }) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final count in [1, 2]) {
    testWidgets(
      'shared business currencies load fresh, save and reopen; $count accessible branches',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        await saveBizEnabledCurrencies({'SAR'});
        await tester.runAsync(() => AppLocalizations.preload('ar'));
        BranchScope.organizationId = 'merchant';
        BranchScope.branchId = 'branch-0';
        addTearDown(() {
          BranchScope.organizationId = null;
          BranchScope.branchId = null;
        });
        tester.view.physicalSize = const Size(900, 3000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final previousError = FlutterError.onError;
        FlutterError.onError = (details) {
          if (!details.exceptionAsString().startsWith(
            'ListTile background color or ink splashes may be invisible.',
          )) {
            previousError?.call(details);
          }
        };
        addTearDown(() => FlutterError.onError = previousError);
        final shared = _SharedSettings();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              projectSettingsApiProvider.overrideWithValue(shared),
              branchApiProvider.overrideWithValue(_Branches(shared)),
              branchAccessProvider.overrideWith(
                (ref) async => [
                  {
                    'organization_id': 'merchant',
                    'role': 'member',
                    'branches': [
                      for (var i = 0; i < count; i++) {'id': 'branch-$i'},
                    ],
                  },
                ],
              ),
              businessBanksProvider.overrideWith((ref) => _Banks()),
              bizCashServiceProvider.overrideWithValue(_Cash()),
            ],
            child: MaterialApp(
              locale: const Locale('ar'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: const ProfilePage(
                business: true,
                employeeFull: true,
                employee: {'full_name': 'Employee'},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final title = count > 1
            ? 'تخصيص عملات هذا الفرع'
            : 'تخصيص عملات قسم الأعمال';
        expect(find.text(title), findsOneWidget);
        Future<void> openAndSearch(String code) async {
          await tester.tap(find.text(title));
          await tester.pumpAndSettle();
          expect(find.text(title), findsNWidgets(2));
          await tester.enterText(find.byType(TextField), code);
          await tester.pumpAndSettle();
        }

        await openAndSearch('USD');
        expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
        await tester.enterText(find.byType(TextField), 'EUR');
        await tester.pumpAndSettle();
        await tester.tap(find.byType(Checkbox));
        await tester.pump();
        final l10n = AppLocalizations(const Locale('ar'));
        await l10n.load();
        await tester.tap(find.text(l10n.translate('saveChanges')));
        await tester.pumpAndSettle();
        expect(shared.currencies, containsAll(['SAR', 'USD', 'EUR']));
        // Simulate another workspace user saving; no local preference write occurs.
        shared.currencies.add('GBP');
        final before = shared.loads;
        await openAndSearch('GBP');
        expect(shared.loads, greaterThan(before));
        expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
