import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/dashboard/presentation/pages/business_dashboard_page.dart';
import 'package:fyona_flutter/features/dashboard/presentation/pages/widgets/business_bottom_nav.dart';
import 'package:fyona_flutter/features/dashboard/presentation/providers/business_dashboard_providers.dart';
import 'package:fyona_flutter/features/employees/data/employee_permissions.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/personal/presentation/providers/merchant_unread_provider.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/widgets/home_account_card.dart';

void main() {
  testWidgets(
    'denied business tiles, cards and nav disappear and child denial wins',
    (tester) async {
      await tester.runAsync(() => AppLocalizations.preload('ar'));
      var bankLoads = 0;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(
              body: BusinessDashboardPage(),
              bottomNavigationBar: BusinessBottomNav(),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      final permissions = {
        ...defaultEmployeePermissions(value: false),
        'dashboard': true,
        'customers': true,
        'inventory': true,
        'sales': true,
        'sales.create': false,
        'income': true,
        'reports': true,
        'reports.view': false,
      };
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            employeePermissionsProvider.overrideWith((ref) => permissions),
            employeeWorkspaceCompanyProvider.overrideWith(
              (ref) => {'role': 'member'},
            ),
            businessAccountsProvider.overrideWith((ref) async {
              bankLoads++;
              return [];
            }),
            debtUnreadProvider(
              'merchant',
            ).overrideWith((ref) => Stream.value(0)),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('ar'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = AppLocalizations(const Locale('ar'));
      await l10n.load();
      for (final key in [
        'bizSaleInvoice',
        'bizPurchaseInvoice',
        'bizEmployees',
        'bizReturns',
        'bizSuppliers',
        'bizInvoices',
        'bizBanks',
        'bizDebts',
        'bizReports',
      ]) {
        expect(find.text(l10n.translate(key)), findsNothing, reason: key);
      }
      for (final key in ['bizCustomers', 'bizWarehouse', 'bizExpenses']) {
        expect(find.text(l10n.translate(key)), findsOneWidget, reason: key);
      }
      expect(find.byType(HomeAccountCard), findsNothing);
      expect(find.byIcon(Icons.account_balance_outlined), findsNothing);
      expect(bankLoads, 0);
      // Three surviving tiles occupy one complete row, not their old slots.
      final customers = tester.getCenter(
        find.text(l10n.translate('bizCustomers')),
      );
      final inventory = tester.getCenter(
        find.text(l10n.translate('bizWarehouse')),
      );
      final income = tester.getCenter(find.text(l10n.translate('bizExpenses')));
      expect(customers.dy, inventory.dy);
      expect(inventory.dy, income.dy);
      expect(tester.takeException(), isNull);
    },
  );
}
