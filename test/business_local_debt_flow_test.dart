import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_party.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/presentation/pages/customers_page.dart';
import 'package:fyona_flutter/features/core_business/presentation/pages/party_debt_pages.dart';
import 'package:fyona_flutter/features/core_business/presentation/pages/party_detail_page.dart';
import 'package:fyona_flutter/features/core_business/presentation/pages/party_operations_page.dart';
import 'package:fyona_flutter/features/core_business/presentation/providers/business_debt_operation_source.dart';
import 'package:fyona_flutter/features/dashboard/presentation/pages/business_income_expense_page.dart';
import 'package:fyona_flutter/features/dashboard/presentation/providers/business_dashboard_providers.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/invoices/presentation/pages/invoice_view_page.dart';
import 'package:fyona_flutter/features/invoices/presentation/providers/invoices_providers.dart';
import 'package:fyona_flutter/features/personal/data/merchant_api.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/merchant_debt_pages.dart';
import 'package:fyona_flutter/features/purchases/presentation/providers/purchase_providers.dart';
import 'package:fyona_flutter/features/sales/presentation/providers/sale_providers.dart';
import 'package:fyona_flutter/shared/providers/current_user_provider.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

class _MerchantProbe implements MerchantApi {
  _MerchantProbe(this.unexpected);

  final Never Function(String) unexpected;

  @override
  Future<int> unreadNotifications({String? side}) async => 0;

  @override
  Future<Map<String, int>> chatUnreadByLink({String? side}) async => {};

  @override
  Future<Map<String, dynamic>> debtNotifications({String? linkId, String? side}) async {
    if (linkId != null || side == 'personal') unexpected('unexpected notification scope');
    // The bell checks new notifications separately, without a directory ID
    // and without holding up the local list or save.
    return {'unread': 0};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => unexpected('${invocation.memberName}');
}

void main() {
  testWidgets(
    'original debt and manual movement screens save locally in both modes',
    (tester) async {
      final keys = FixtureDirectoryKeys();
      final online = ConnectivityService(debugOnline: false);
      addTearDown(online.dispose);
      const kind = DirectoryPartyKind.customer;
      final scope = DirectoryAccess(
        workspace: DirectoryWorkspace(
          server: DirectoryPilotBuild.baseUrl,
          accountId: _id(),
          organizationId: _id(),
        ),
        branchId: _id(),
        readable: {kind},
        writable: {kind},
        financialCutover: true,
      );
      final access = BusinessLedgerAccess(
        scope,
        BusinessLedgerAction.values.toSet(),
      );
      late Directory root;
      late DirectoryPilotStore store;
      final accountId = _id();
      final contextName = 'Ledger starter';
      const folderName = 'قسم للتجربة';
      late DirectoryDebtGroupReference group;
      final denied = StateProvider<Set<String>>((_) => {});
       final rest = <String>[];
       Never unexpected(String source) {
         rest.add(source);
         throw StateError('Unexpected connected Business writer or data source');
      }

      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('fyona-cutover-widget-');
        store = DirectoryPilotStore(keys: keys, root: () async => root);
        SharedPreferences.setMockInitialValues({
          'enabled_currencies_fixture': ['SAR'],
        });
        await BranchScope.clear();
        await AppLocalizations.preload('ar');
        await store.remember(scope, {
          'status': 'active',
          'business_setup_completed': true,
          'sections': {
            'business': {
              'active': true,
              'end_date': DateTime.now()
                  .add(const Duration(days: 2))
                  .toIso8601String(),
            },
          },
        });
        await store.withLedger(
          access,
          () => scope,
          (ledger) => ledger.createAccount(
            access,
            commandId: accountId,
            bankName: 'كاش',
            accountName: 'حساب تجريبي',
            accountNumber: '123',
            currency: 'SAR',
          ),
        );
      });
      addTearDown(() async {
        await store.close();
        await root.delete(recursive: true);
      });
      final router = GoRouter(
        initialLocation: '/local',
        routes: [
          GoRoute(
            path: '/money',
            builder: (_, _) => const BusinessIncomeExpensePage(),
          ),
          GoRoute(
            path: '/local',
            builder: (_, _) => const CustomersPage(debtsContext: true),
          ),
          GoRoute(
            path: '/customers/detail',
            builder: (_, state) {
              expect(state.uri.queryParameters, isEmpty);
              return PartyDetailPage(
                id: '',
                isSupplier: false,
                localParty: state.extra as DirectoryPartyReference,
              );
            },
          ),
          GoRoute(
            path: '/debts/party-sections',
            builder: (_, state) => PartySectionsPage(
              partyKind: 'customer',
              partyId: '',
              name: '',
              localParty: state.extra as DirectoryPartyReference,
            ),
          ),
          GoRoute(
            path: '/debts/party-section',
            builder: (_, state) => PartySectionPage(
              partyKind: 'customer',
              partyId: '',
              name: '',
              groupId: '',
              groupName: '',
              localGroup: state.extra as DirectoryDebtGroupReference,
            ),
          ),
          GoRoute(
            path: '/debts/operation',
            builder: (_, state) {
              expect(state.uri.queryParameters, isEmpty);
              return DebtOperationDetailPage(
                linkId: '',
                invoiceId: '',
                name: '',
                isBusiness: true,
                localBusiness: BusinessLocalDebtOperation(
                  state.extra as DirectoryDebtInvoiceReference,
                ),
              );
            },
          ),
          GoRoute(
            path: '/invoices/view',
            builder: (_, state) {
              expect(state.uri.queryParameters, isEmpty);
              return InvoiceViewPage(
                id: '',
                type: 'sale',
                localOpeningInvoice:
                    state.extra as DirectoryDebtInvoiceReference,
              );
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            directoryPilotAccessProvider.overrideWithValue(scope),
            businessLocalLedgerScopeProvider.overrideWithValue(scope),
            directoryPilotStoreProvider.overrideWithValue(store),
            connectivityServiceProvider.overrideWithValue(online),
            currentUserIdProvider.overrideWithValue('fixture'),
             employeeCanProvider.overrideWith((ref, key) => !ref.watch(denied).contains(key)),
             purchaseApiProvider.overrideWith((_) => unexpected('purchase API')),
             invoicesApiProvider.overrideWith((_) => unexpected('invoices API')),
             saleAccountsProvider.overrideWith((_) => unexpected('sale accounts')),
             businessFinanceApiProvider.overrideWith((_) => unexpected('finance API')),
             businessPaymentAccountsProvider.overrideWith((_) => unexpected('payment accounts')),
             merchantApiProvider.overrideWith((_) => _MerchantProbe(unexpected)),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('ar'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
          ),
        ),
      );

      Future<void> until(Finder finder) async {
        for (var i = 0; i < 80; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
          await tester.pump(const Duration(milliseconds: 25));
          expect(find.byType(CircularProgressIndicator), findsNothing);
          if (finder.evaluate().isNotEmpty) return;
        }
        expect(finder, findsWidgets);
      }

      for (final connected in [false, true]) {
        online.debugSetOnline(connected);
        final name = '$contextName $connected';
        final add = find.text('إضافة عميل جديد');
        await until(add);
        await tester.tap(add);
        await until(find.text('قيمة الدين السابق'));
        final fields = find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(EditableText),
        );
        await tester.enterText(fields.at(0), name);
        await tester.enterText(fields.at(2), '30.25');
        final save = tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'حفظ'))
            .onPressed!;
        await tester.runAsync(() async {
          save();
          save();
        });
        await until(find.text(name));
        expect(find.text(name), findsOneWidget);
        expect(find.text('تمت الإضافة بنجاح'), findsOneWidget);
      }

      // Prepare a group in the same store; normal sales/purchases remain a
      // distinct (not yet migrated) operation, not another opening balance.
      await tester.runAsync(() async {
        final row = (await store.search(
          scope,
          kind,
          '$contextName false',
        )).single;
        final target = DirectoryPartyReference(
          scope: scope,
          kind: kind,
          id: row.id,
        );
        await store.createGroup(scope, target, folderName);
        final id = (await store.groups(scope, target)).single['id'] as String;
        group = DirectoryDebtGroupReference(party: target, id: id);
        await store.withLedger(
          access,
          () => scope,
          (ledger) => ledger.recordOpeningDebt(
            access,
            target,
            commandId: _id(),
            amountMinor: 2275,
            currency: 'SAR',
            groupId: group.id,
          ),
        );
      });
      await tester.tap(find.text('$contextName false'));
      await tester.pumpAndSettle();
      // The party's full history opens from one button; a debt row opens
      // its existing debt detail.
      final history = find.byKey(const ValueKey('party-operations-button'));
      await until(history);
      await tester.tap(history);
      await tester.pumpAndSettle();
      await until(find.textContaining('OPEN-'));
      await tester.tap(find.textContaining('OPEN-').first);
      await tester.pumpAndSettle();
      await until(find.byType(DebtOperationDetailPage));
      router.pop();
      await tester.pumpAndSettle();
      await until(find.byType(PartyOperationsPage));
      Navigator.of(tester.element(find.byType(PartyOperationsPage))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('مجموعات الديون'));
      await tester.pumpAndSettle();
      await until(find.text(folderName));
      await tester.tap(find.text(folderName));
      await tester.pumpAndSettle();
      final pay = find.text('تحصيل من العميل');
      await until(pay);
      online.debugSetOnline(false);
      await tester.tap(pay);
      await tester.pumpAndSettle();
      final bank = find.text('كاش').hitTestable();
      await until(bank);
      await tester.pumpAndSettle();
      await tester.tap(bank);
      await tester.pumpAndSettle();
      final confirm = find.widgetWithText(FilledButton, 'تحصيل');
      expect(confirm, findsOneWidget);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      final settle = tester.widget<FilledButton>(confirm).onPressed!;
      await tester.runAsync(() async {
        settle();
        settle();
      });
      await until(find.text('مسدد بالكامل'));
      await tester.runAsync(() async {
        final values = await store.withLedger(
          access,
          () => scope,
          (ledger) => ledger.debts(access, group.party, groupId: group.id),
        );
        expect(values.single['paid_minor'], 2275);
        final account = await store.withLedger(
          access,
          () => scope,
          (ledger) => ledger.accounts(access),
        );
        expect(account.single['balance_minor'], 2275);
      });

      // Open the original operation from the group, not a shortened invoice
      // preview. Keep the same local row while going back online, then cut the
      // connection as the single-invoice collection is being confirmed.
      online.debugSetOnline(true);
      final op = find.textContaining('OPEN-').hitTestable();
      await until(op);
      await tester.tap(op.first);
      await tester.pumpAndSettle();
      await until(find.byType(DebtOperationDetailPage));
      final edit = find.byTooltip('تعديل الفاتورة');
      await until(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      final detail = tester.element(find.byType(DebtOperationDetailPage));
      final grants = ProviderScope.containerOf(detail).read(denied.notifier);
      grants.state = {'customers.edit'};
      await tester.pumpAndSettle();
      expect(find.text('غير مصرح بالوصول'), findsOneWidget);
      expect(find.byType(EditableText), findsNothing);
      grants.state = {};
      await tester.pumpAndSettle();
      final prices = find.descendant(
        of: find.byType(BottomSheet), matching: find.byType(EditableText),
      );
      await tester.enterText(prices.last, '25.75');
      await tester.pumpAndSettle();
      final editAction = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'حفظ التعديلات'),
      ).onPressed!;
      await tester.runAsync(() async {
        editAction();
        editAction();
      });
      await until(find.text('تم حفظ التعديلات'));
      await tester.pumpAndSettle();
      await until(find.text('معدلة'));
      await tester.tap(find.text('معدلة'));
      await tester.pumpAndSettle();
      expect(find.text('تفاصيل تعديلات التاجر'), findsOneWidget);
      await tester.tap(find.text('معدلة'));
      await tester.pumpAndSettle();

      final payInvoice = find.widgetWithText(FilledButton, 'تحصيل من العميل');
      await tester.ensureVisible(payInvoice);
      await tester.pumpAndSettle();
      await tester.tap(payInvoice);
      await until(bank);
      await tester.pumpAndSettle();
      await tester.tap(bank);
      await tester.pumpAndSettle();
      final press = tester.widget<FilledButton>(confirm).onPressed!;
      online.debugSetOnline(false);
      await tester.runAsync(() async {
        press();
        press();
      });
      await until(find.widgetWithText(FilledButton, 'مسدد بالكامل'));
      final payments = find.widgetWithText(OutlinedButton, 'المدفوعات');
      await tester.ensureVisible(payments);
      await tester.tap(payments);
      await tester.pumpAndSettle();
      expect(find.textContaining('حصلت مبلغ'), findsNWidgets(2));
      router.pop();
      await tester.pumpAndSettle();

      grants.state = {'debts.details'};
      await tester.pumpAndSettle();
      expect(find.text('غير مصرح بالوصول'), findsOneWidget);
      expect(find.textContaining('OPEN-'), findsNothing);
      grants.state = {};
      await tester.pumpAndSettle();

      final delete = find.byTooltip('حذف الفاتورة');
      await tester.tap(delete);
      await tester.pumpAndSettle();
      final deleteAction = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'حذف الفاتورة'),
      ).onPressed!;
      await tester.runAsync(() async {
        deleteAction();
        deleteAction();
      });
      final page = find.byType(PartySectionPage);
      await until(find.text('تم حذف الفاتورة نهائيًا'));
      await until(page);
      await until(find.descendant(of: page, matching: find.text('لا توجد عمليات بعد')));
      await tester.runAsync(() async {
        final debts = await store.withLedger(
          access, () => scope, (l) => l.debts(access, group.party, groupId: group.id),
        );
        final legs = await store.withLedger(
          access, () => scope, (l) => l.statement(access, accountId),
        );
        expect(debts, isEmpty);
        expect(legs.map((l) => l['delta_minor']), [-2575, 300, 2275]);
      });

      router.go('/money');
      await tester.pumpAndSettle();
      final movementPage = tester.element(find.byType(BusinessIncomeExpensePage));
      ScaffoldMessenger.of(movementPage).clearSnackBars();
      await tester.pumpAndSettle();
      for (final (connected, action, category, amount, note, success) in [
        (
          true,
          'إضافة دخل',
          'رأس مال',
          '50.25',
          'Local income fixture',
          'تمت عملية الإيداع بنجاح',
        ),
        (
          false,
          'سحب مصروف',
          'إيجار',
          '10',
          'Local expense fixture',
          'تمت عملية السحب بنجاح',
        ),
      ]) {
        online.debugSetOnline(connected);
        await tester.tap(find.text(action).hitTestable());
        await tester.pumpAndSettle();
        final sheet = find.byType(BottomSheet);
        final cash = find
            .descendant(of: sheet, matching: find.text('كاش'))
            .hitTestable();
        await until(cash);
        await tester.tap(cash);
        await tester.pumpAndSettle();
        await until(find.descendant(
          of: sheet, matching: find.textContaining(': SAR'),
        ));
        final amountBox = find.byKey(
          const ValueKey('business_movement_amount'),
        );
        await tester.enterText(amountBox, amount);
        final item = find.byKey(
          ValueKey('business_movement_category_$category'),
        );
        await tester.ensureVisible(item);
        await tester.tap(item);
        final description = find.byKey(
          const ValueKey('business_movement_description'),
        );
        await tester.enterText(description, note);
        final submit = find.byKey(const ValueKey('business_movement_submit'));
        await tester.ensureVisible(submit);
        await tester.pumpAndSettle();
        final submitAction = tester.widget<ElevatedButton>(submit).onPressed!;
        await tester.runAsync(() async {
          submitAction();
          submitAction();
        });
        await tester.pump(const Duration(milliseconds: 350));
        final snackbar = find.descendant(
          of: find.byType(SnackBar), matching: find.byType(Text),
        );
        if (snackbar.evaluate().isNotEmpty) {
          expect(tester.widgetList<Text>(snackbar).map((text) => text.data),
            contains(success));
        }
        await until(find.text(success));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
        await until(find.text(note, findRichText: true));
        await tester.pump(const Duration(seconds: 4));
      }
      await tester.runAsync(() async {
        final rows = await store.withLedger(
          access,
          () => scope,
          (ledger) => ledger.manualMovements(
            access,
            showIncome: true,
            showExpenses: true,
          ),
        );
        expect(rows.map((row) => row['amount']), ['10.00', '50.25']);
        expect(rows.first['category'], 'إيجار');
        final accounts = await store.withLedger(
          access,
          () => scope,
          (ledger) => ledger.accounts(access),
        );
         expect(accounts.single['balance_minor'], 4025);
      });
       expect(rest, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !DirectoryPilotBuild.signupEnabled,
  );
}
