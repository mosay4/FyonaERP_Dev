import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/features/business_banks/data/business_bank_models.dart';
import 'package:fyona_flutter/features/business_banks/data/business_banks_api.dart';
import 'package:fyona_flutter/features/business_banks/presentation/bank_transaction_visual.dart';
import 'package:fyona_flutter/features/business_banks/presentation/pages/business_account_detail_page.dart';
import 'package:fyona_flutter/features/business_banks/presentation/providers/business_banks_providers.dart';
import 'package:fyona_flutter/shared/widgets/two_tone_icons.dart';

class _CashApi extends BusinessBanksApi {
  _CashApi() : super(ApiClient(dio: Dio()));
  final requested = <String>[];

  @override
  Future<List<dynamic>> transactions(String id) async {
    requested.add(id);
    return [
      {
        'id': 'tx-$id',
        'bank_account_id': id,
        'tx_type': id == 'usd' ? 'transfer_reversal_in' : 'withdrawal',
        'amount': id == 'usd' ? '-950' : '950',
        'currency': id.startsWith('usd') ? 'USD' : 'SAR',
        'date': '2025-01-01T12:00:00Z',
        'description': 'history-$id',
      },
    ];
  }
}

class _Banks extends BusinessBanksNotifier {
  _Banks(BusinessBanksApi api) : super(api, CurrencyEngine());

  @override
  Future<void> load() async {
    state = state.copyWith(isLoading: true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    state = const BusinessBanksState(
      accounts: [
        BusinessBankAccount(id: 'sar', bankName: 'كاش', currency: 'SAR'),
        BusinessBankAccount(
          id: 'usd',
          bankName: 'كاش',
          currency: 'USD',
          balance: 950,
        ),
        BusinessBankAccount(
          id: 'usd-twin', bankName: 'كاش', currency: 'USD', balance: 50),
      ],
    );
  }
}

void main() {
  test(
    'all transaction pages are read, not only the default first twenty',
    () async {
      final dio = Dio();
      final pages = <int>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final page = options.queryParameters['page'] as int;
            pages.add(page);
            handler.resolve(
              Response(
                requestOptions: options,
                data: {
                  'success': true,
                  'data': {
                    'items': [
                      {'id': 'page-$page'},
                    ],
                    'total_pages': 3,
                  },
                },
              ),
            );
          },
        ),
      );
      final result = await BusinessBanksApi(
        ApiClient(dio: dio),
      ).transactions('cash');
      expect(pages, [1, 2, 3]);
      expect(result.length, 3);
      dio.close();
    },
  );

  test('reversals have their own icon and incoming/outgoing colors', () {
    final incoming = BankTransactionVisual(' transfer_reversal_in ');
    final outgoing = BankTransactionVisual('transfer_reversal_out');
    expect(incoming.icon, TwoToneIcons.refresh);
    expect(outgoing.icon, TwoToneIcons.refresh);
    expect(incoming.icon, isNot(TwoToneIcons.close));
    expect(incoming.color, AppColors.success);
    expect(outgoing.color, AppColors.danger);
    expect(incoming.isIn, isTrue);
    expect(outgoing.isIn, isFalse);
  });

  testWidgets(
    'cash history loads after cold account load and currency changes',
    (tester) async {
      await tester.runAsync(() => AppLocalizations.preload('ar'));
      final api = _CashApi();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            businessBanksApiProvider.overrideWithValue(api),
            businessBanksProvider.overrideWith((ref) => _Banks(api)),
          ],
          child: MaterialApp(
            locale: const Locale('ar'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: const BusinessAccountDetailPage(accountId: 'usd'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.requested, contains('usd'));
      expect(api.requested, contains('usd-twin'));
      expect(find.text('history-usd-twin'), findsOneWidget);
      expect(find.text('عكس تحويل وارد'), findsOneWidget);
      expect(find.text('+950'), findsOneWidget);
      expect(find.text('history-usd'), findsOneWidget);
      expect(find.text('transfer_reversal_in'), findsNothing);
      await tester.tap(find.text('SAR'));
      await tester.pumpAndSettle();
      expect(api.requested, contains('sar'));
      expect(find.text('history-sar'), findsOneWidget);
      expect(find.text('history-usd'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
