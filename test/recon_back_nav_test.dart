import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/reconciliation/data/reconciliation_api.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/pages/reconciliation_home_page.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/pages/recon_bank_pages.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/pages/recon_inventory_scope_page.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/widgets/recon_widgets.dart';

/// Back-arrow navigation across the bank reconciliation flow MUST return to
/// the previous list (accounts → select → amounts → result).
void main() {
  Future<void> preload(WidgetTester t) async {
    await t.runAsync(() => AppLocalizations.preload('ar'));
  }

  Widget host(WidgetTester tester) {
    return MaterialApp.router(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      routerConfig: GoRouter(routes: [
        GoRoute(
            path: '/',
            builder: (_, _) => const ReconciliationHomePage()),
        GoRoute(
            path: '/reconciliation/bank',
            builder: (_, _) => const ReconAccountsPage()),
        GoRoute(
            path: '/reconciliation/bank/select',
            builder: (_, state) =>
                ReconBankSelectPage(accountIds: state.uri.queryParameters['ids'] ?? ''),
        ),
        GoRoute(
            path: '/reconciliation/bank/run',
            builder: (_, state) =>
                ReconBankRunPage(accountIds: state.uri.queryParameters['ids'] ?? ''),
        ),
      ]),
    );
  }

  testWidgets('back arrow: select page → accounts page', (tester) async {
    await preload(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        reconciliationApiProvider.overrideWithValue(
            BackNavApi(ApiClient(dio: Dio()))),
      ],
      child: host(tester),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 150),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 6));
    // From the home: open the bank section (only ONE card «بنك الاختبار»).
    await tester.tap(find.text('فحص أرصدة البنوك والكاش'));
    await tester.pumpAndSettle(const Duration(milliseconds: 150),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 6));
    // Was the accounts page even reached?
    final accountsMounted = tester.any(find.byType(ReconAccountsPage));
    final homeMounted = tester.any(find.text('كيف شغلك؟'));
    final spinner = tester.any(find.byType(CircularProgressIndicator));
    final hasCard = tester.any(find.text('بنك الاختبار'));
    final startBtn = tester.any(find.text('بدء الفحص'));
    expect(startBtn, true,
        reason: 'accounts=$accountsMounted home=$homeMounted '
            'spinner=$spinner card=$hasCard startBtn=$startBtn');
    // Press «بدء الفحص» → the currency-selection page.
    await tester.tap(find.text('بدء الفحص'));
    await tester.pumpAndSettle(const Duration(milliseconds: 150),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 6));
    expect(find.text('أي عملات تبغى تطابق؟'), findsOneWidget,
        reason: 'selection page missing');
    // Back arrow → must return to the accounts list (the card page).
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
    await tester.pumpAndSettle(const Duration(milliseconds: 150),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 6));
    expect(find.text('بدء الفحص'), findsOneWidget,
        reason: 'back did NOT return to the accounts list');
    expect(find.text('أي عملات تبغى تطابق؟'), findsNothing);
  });

  testWidgets('back arrow: amounts page → selection page', (tester) async {
    await preload(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        reconciliationApiProvider.overrideWithValue(
            BackNavApi(ApiClient(dio: Dio()))),
      ],
      child: host(tester),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 150),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 6));
    await tester.tap(find.text('فحص أرصدة البنوك والكاش'));
    await tester.pumpAndSettle(const Duration(milliseconds: 150),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 6));
    await tester.tap(find.text('بدء الفحص'));
    await tester.pumpAndSettle(const Duration(milliseconds: 150),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 6));
    // Tick the first currency then Next.
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('التالي'));
    await tester.pumpAndSettle(const Duration(milliseconds: 150),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 6));
    expect(find.text('كم موجود عندك بالحقيقة؟'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
    await tester.pumpAndSettle(const Duration(milliseconds: 150),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 6));
    expect(find.text('أي عملات تبغى تطابق؟'), findsOneWidget,
        reason: 'back did NOT return to the selection list');
  });
}

class BackNavApi extends ReconciliationApi {
  BackNavApi(super.client);
  @override
  Future<List<Map<String, dynamic>>> accounts() async => [
        {
          'id': 'a1', 'bank_name': 'بنك الاختبار', 'account_name': 'دولار',
          'account_number': 'A1', 'currency': 'USD', 'balance': 2500,
          'account_type': 'checking', 'is_cash': false,
        },
      ];
}
