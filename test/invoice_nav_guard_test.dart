import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/dashboard/presentation/pages/widgets/business_bottom_nav.dart';
import 'package:fyona_flutter/features/personal/presentation/providers/merchant_unread_provider.dart';
import 'package:fyona_flutter/features/sales/presentation/providers/sale_providers.dart';
import 'package:fyona_flutter/features/purchases/presentation/providers/purchase_providers.dart';
import 'package:fyona_flutter/features/invoices/presentation/providers/invoice_design_provider.dart';

void main() {
  testWidgets('bottom nav asks before leaving a filled sale invoice',
      (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    final container = ProviderContainer(overrides: [
      debtUnreadProvider('merchant').overrideWith((ref) => Stream.value(0)),
    ]);
    addTearDown(container.dispose);
    container.read(saleDraftProvider.notifier).addItem(
        const SaleItem(description: 'زبادي', quantity: 2, unitPrice: 5));
    final router = GoRouter(initialLocation: '/sales/add', routes: [
      GoRoute(
          path: '/sales/add',
          builder: (_, __) => Scaffold(
              body: const Text('invoice'),
              bottomNavigationBar: const BusinessBottomNav())),
      GoRoute(path: '/dashboard', builder: (_, __) => const Text('dashboard')),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.home_rounded));
    await tester.pumpAndSettle();
    expect(find.text('هل تريد إبقاء البيانات والخروج؟'), findsOneWidget);
    await tester.tap(find.text('إلغاء'));
    await tester.pumpAndSettle();
    expect(find.text('invoice'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.home_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('الخروج دون إبقاء البيانات'));
    await tester.pumpAndSettle();
    expect(find.text('dashboard'), findsOneWidget);
    expect(container.read(saleDraftProvider).items, isEmpty);
  });

  testWidgets('bottom nav asks before leaving a filled purchase invoice',
      (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    final container = ProviderContainer(overrides: [
      debtUnreadProvider('merchant').overrideWith((ref) => Stream.value(0)),
    ]);
    addTearDown(container.dispose);
    container.read(purchaseDraftProvider.notifier).addItem(
        const SaleItem(description: 'زبادي', quantity: 2, unitPrice: 5));
    final router = GoRouter(initialLocation: '/purchases/add', routes: [
      GoRoute(
          path: '/purchases/add',
          builder: (_, __) => Scaffold(
              body: const Text('purchase invoice'),
              bottomNavigationBar: const BusinessBottomNav())),
      GoRoute(path: '/dashboard', builder: (_, __) => const Text('dashboard')),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.home_rounded));
    await tester.pumpAndSettle();
    expect(find.text('هل تريد إبقاء البيانات والخروج؟'), findsOneWidget);
    await tester.tap(find.text('إبقاء البيانات والخروج'));
    await tester.pumpAndSettle();
    expect(find.text('dashboard'), findsOneWidget);
    expect(container.read(purchaseDraftProvider).items, isNotEmpty);
  });

  testWidgets('bottom nav asks before leaving unsaved invoice design',
      (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    final container = ProviderContainer(overrides: [
      debtUnreadProvider('merchant').overrideWith((ref) => Stream.value(0)),
    ]);
    addTearDown(container.dispose);
    container.read(invoiceDesignDirtyProvider.notifier).state = true;
    final router = GoRouter(initialLocation: '/invoices/design/edit', routes: [
      GoRoute(
          path: '/invoices/design/edit',
          builder: (_, __) => Scaffold(
              body: const Text('design'),
              bottomNavigationBar: const BusinessBottomNav())),
      GoRoute(path: '/dashboard', builder: (_, __) => const Text('dashboard')),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.home_rounded));
    await tester.pumpAndSettle();
    expect(find.text('تغييرات غير محفوظة'), findsOneWidget);
    await tester.tap(find.text('خروج بدون حفظ'));
    await tester.pumpAndSettle();
    expect(find.text('dashboard'), findsOneWidget);
  });
}
