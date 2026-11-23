import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/dashboard/presentation/pages/business_transactions_page.dart';
import 'package:fyona_flutter/features/dashboard/presentation/pages/widgets/business_services_grid.dart';

void main() {
  testWidgets('REPRO: tap business transactions tile reaches the page', (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    final router = GoRouter(
      initialLocation: '/dash',
      routes: [
        GoRoute(
          path: '/dash',
          builder: (_, __) => Scaffold(
            body: SingleChildScrollView(child: const BusinessServicesGrid()),
          ),
        ),
        GoRoute(
          path: '/business/transactions',
          builder: (_, __) => const BusinessTransactionsPage(),
        ),
      ],
    );
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp.router(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
    // Find the المعاملات tile and tap it
    final txText = find.text('المعاملات');
    expect(txText, findsWidgets);
    await tester.tap(txText.first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(router.routerDelegate.currentConfiguration.last.matchedLocation,
        '/business/transactions');
  });
}
