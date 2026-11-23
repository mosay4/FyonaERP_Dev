import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart';
import 'package:fyona_flutter/features/business_banks/data/business_bank_models.dart';
import 'package:fyona_flutter/features/business_banks/data/business_banks_api.dart';
import 'package:fyona_flutter/features/business_banks/presentation/pages/business_banks_page.dart';
import 'package:fyona_flutter/features/business_banks/presentation/pages/business_bank_detail_page.dart';
import 'package:fyona_flutter/features/business_banks/presentation/pages/business_account_detail_page.dart';
import 'package:fyona_flutter/features/business_banks/presentation/providers/business_banks_providers.dart';
import 'package:fyona_flutter/features/employees/data/employee_permissions.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';

class TestBankApi extends BusinessBanksApi {
  TestBankApi() : super(ApiClient(dio: Dio()));
  @override
  Future<List<dynamic>> transactions(String id) async => [];
}

class CachedBanks extends BusinessBanksNotifier {
  CachedBanks() : super(TestBankApi(), CurrencyEngine()) {
    state = const BusinessBanksState(
      walletTotal: 987654,
      accounts: [
        BusinessBankAccount(
          id: 'bank',
          bankName: 'Test Bank',
          currency: 'USD',
          balance: 987654,
        ),
      ],
    );
  }
  @override
  Future<void> load() async {}
}

void main() {
  for (final page in ['list', 'bank', 'account']) {
    testWidgets(
      'explicit balance denial hides stale cached balances in $page',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        await tester.runAsync(() => AppLocalizations.preload('ar'));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              businessBanksProvider.overrideWith((ref) => CachedBanks()),
              businessBanksApiProvider.overrideWithValue(TestBankApi()),
              employeeWorkspaceCompanyProvider.overrideWith(
                (ref) => {'role': 'member'},
              ),
              employeePermissionsProvider.overrideWith(
                (ref) => {
                  ...defaultEmployeePermissions(),
                  'banks.balances': false,
                  'banks.add_delete': false,
                  'banks.transfer': false,
                },
              ),
            ],
            child: MaterialApp(
              locale: const Locale('ar'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: Scaffold(
                body: page == 'list'
                    ? const BusinessBanksPage()
                    : page == 'bank'
                    ? const BusinessBankDetailPage(bankName: 'Test Bank')
                    : const BusinessAccountDetailPage(accountId: 'bank'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining(fmtNum(987654)), findsNothing);
        expect(find.byIcon(Icons.receipt_long), findsNothing);
        if (page == 'bank') {
          expect(find.text(currencyFlagEmoji('USD')), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
