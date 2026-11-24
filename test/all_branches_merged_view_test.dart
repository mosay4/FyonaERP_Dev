import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/ai/domain/agent/business_device_router.dart';
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/business_banks/presentation/providers/local_business_banking.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/all_branches_ledger.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_report_fx.dart';
import 'package:fyona_flutter/features/dashboard/presentation/pages/widgets/business_services_grid.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/shared/providers/current_user_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

Map<String, Object?> _account(
  String id,
  String bank,
  String currency,
  int minor, {
  String type = 'checking',
}) => {
  'id': id,
  'bank_name': bank,
  'account_name': bank,
  'account_number': '1',
  'account_type': type,
  'currency': currency,
  'is_active': 1,
  'balance_minor': minor,
};

void main() {
  group('banks of all branches', () {
    test('same bank in two branches is one bank, currencies summed, an extra '
        'currency is one more currency of that bank', () {
      final merged = mergeAllBranchesBanks([
        BranchRead('a', 'الرياض', [
          _account('a1', 'الراجحي', 'SAR', 100050),
          _account('a2', 'كاش', 'SAR', 2000),
        ]),
        BranchRead('b', 'جدة', [
          _account('b1', ' الراجحي ', 'SAR', 50025),
          _account('b2', 'الراجحي', 'USD', 7000),
          _account('b3', 'Cash', 'SAR', 500),
          _account('b4', 'الأهلي', 'SAR', 900),
        ]),
      ], includeBalances: true);
      final rajhi = merged.where((r) => r['group_key'] == 'all:name:الراجحي');
      expect(rajhi, hasLength(2), reason: 'one bank, two currencies');
      final sar = rajhi.firstWhere((r) => r['currency'] == 'SAR');
      expect(sar['balance'], '1500.75');
      expect(sar['branch_names'], ['الرياض', 'جدة']);
      expect(
        (sar['merged_accounts'] as List).map((m) => (m as Map)['id']),
        ['a1', 'b1'],
      );
      final usd = rajhi.firstWhere((r) => r['currency'] == 'USD');
      expect(usd['balance'], '70.00');
      expect(usd['branch_names'], ['جدة']);
      // Cash of every branch is one cash, whatever its spelling.
      final cash = merged.where((r) => r['group_key'] == 'all:name:كاش');
      expect(cash.single['balance'], '25.00');
      expect(merged.where((r) => r['group_key'] == 'all:name:الأهلي'), hasLength(1));
      expect(merged, hasLength(4));
    });

    test('balances stay hidden without the balance right', () {
      final merged = mergeAllBranchesBanks([
        BranchRead('a', 'A', [_account('a1', 'X', 'SAR', 100)]),
      ], includeBalances: false);
      expect(merged.single['balance'], 0);
    });
  });

  group('reports of all branches', () {
    test('money is summed exactly, breakdowns per key, each branch kept', () {
      Map<String, dynamic> branch(String total, String usd, int count) => {
        'report': 'money',
        'currency': 'SAR',
        'branch_ids': ['x'],
        'totals_complete': true,
        'legacy_flow_unclassified': false,
        'balances': {
          'total': total,
          'per_currency': [
            {'currency': 'SAR', 'total': total},
            {'currency': 'USD', 'total': usd},
          ],
          'gaps': [],
        },
        'chart': [
          {'date': '2026-11-01', 'value': '10.00'},
        ],
        'settlements': {'total': '1.00', 'count': count, 'items': [
          {'id': 'i$count', 'amount': '1.00', 'currency': 'SAR'},
        ]},
      };
      final merged = mergeBranchReports([
        BranchRead('a', 'الرياض', branch('100.50', '5.00', 1)),
        BranchRead('b', 'جدة', {
          ...branch('20.25', '0.00', 2),
          'totals_complete': false,
          'legacy_flow_unclassified': true,
          'chart': [
            {'date': '2026-10-31', 'value': '1.00'},
            {'date': '2026-11-01', 'value': '2.50'},
          ],
        }),
      ]);
      expect(merged['report'], 'money');
      expect(merged['branch_ids'], ['a', 'b']);
      expect((merged['balances'] as Map)['total'], '120.75');
      expect((merged['balances'] as Map)['per_currency'], [
        {'currency': 'SAR', 'total': '120.75'},
        {'currency': 'USD', 'total': '5.00'},
      ]);
      expect(merged['totals_complete'], isFalse);
      expect(merged['legacy_flow_unclassified'], isTrue);
      expect(merged['chart'], [
        {'date': '2026-10-31', 'value': '1.00'},
        {'date': '2026-11-01', 'value': '12.50'},
      ]);
      final settlements = merged['settlements'] as Map;
      expect(settlements['count'], 3);
      expect(
        (settlements['items'] as List).map((i) => (i as Map)['branch_name']),
        ['الرياض', 'جدة'],
      );
      final byBranch = merged['by_branch'] as List;
      expect(byBranch.map((b) => (b as Map)['branch_name']), ['الرياض', 'جدة']);
      expect((byBranch.first as Map)['balances'], '100.50');
    });

    test('an incomplete branch total keeps the merged total incomplete', () {
      final merged = mergeBranchReports([
        BranchRead('a', 'A', {'currency': 'SAR', 'net': {'total': '5.00'}}),
        BranchRead('b', 'B', {'currency': 'SAR', 'net': {'total': null}}),
      ]);
      expect((merged['net'] as Map)['total'], isNull);
    });
  });

  test('people of all branches: one person, debts per currency summed', () {
    final merged = mergeAllBranchesParties([
      BranchRead('a', 'الرياض', [
        {'id': 'c1', 'name': 'محمد', 'phone': '0500', 'debts': [
          {'currency': 'SAR', 'total': '10.00'},
        ]},
      ]),
      BranchRead('b', 'جدة', [
        {'id': 'c2', 'name': ' محمد', 'phone': '0500', 'debts': [
          {'currency': 'SAR', 'total': '5.50'},
          {'currency': 'USD', 'total': '2.00'},
        ]},
        {'id': 'c3', 'name': 'علي', 'phone': null, 'debts': []},
      ]),
    ]);
    expect(merged, hasLength(2));
    final mohammed = merged.first;
    expect(mohammed['branch_names'], ['الرياض', 'جدة']);
    expect(mohammed['debts'], [
      {'currency': 'SAR', 'total': '15.50'},
      {'currency': 'USD', 'total': '2.00'},
    ]);
    expect((mohammed['members'] as List), hasLength(2));
  });

  group('device ledger of two branches', () {
    final workspace = DirectoryWorkspace(
      server: DirectoryPilotBuild.baseUrl,
      accountId: _id(),
      organizationId: _id(),
    );
    late String a, b;
    late Directory root;
    late FixtureDirectoryKeys keys;
    late DirectoryPilotStore store;
    DirectoryAccess scope(String branch) => DirectoryAccess(
      workspace: workspace,
      branchId: branch,
      readable: {},
      writable: {},
      financialCutover: true,
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      root = await Directory.systemTemp.createTemp('fyona-all-branches-');
      keys = FixtureDirectoryKeys();
      store = DirectoryPilotStore(root: () async => root, keys: keys);
      a = _id();
      b = _id();
      await store.remember(scope(a), {
        'status': 'active',
        'business_setup_completed': true,
        'sections': {
          'business': {
            'active': true,
            'end_date': DateTime.now()
                .add(const Duration(days: 1))
                .toIso8601String(),
          },
        },
      });
      final db = await DirectoryDatabase.open(
        root: root,
        workspace: workspace,
        keys: keys,
      );
      final write = BusinessLedgerAction.values.toSet();
      Future<String> open(String branch, String bank, String cur, int minor) async =>
          (await db.ledger.createAccount(
            BusinessLedgerAccess(scope(branch), write),
            commandId: _id(),
            bankName: bank,
            accountName: bank,
            accountNumber: '1',
            currency: cur,
            openingMinor: minor,
            managed: true,
          ))['id'] as String;
      final rajhiA = await open(a, 'الراجحي', 'SAR', 100000);
      await open(b, 'الراجحي', 'SAR', 25000);
      await open(b, 'الراجحي', 'USD', 3000);
      await db.ledger.move(
        BusinessLedgerAccess(scope(a), write),
        commandId: _id(),
        accountId: rajhiA,
        amountMinor: 5000,
        withdraw: true,
        description: 'إيجار',
      );
      await db.close();
    });

    tearDown(() async {
      await store.close();
      await root.delete(recursive: true);
      BranchScope.allMode = false;
    });

    BusinessAllBranches view({bool Function()? current}) => BusinessAllBranches(
      workspace: workspace,
      store: store,
      branches: () async => {a: 'الرياض', b: 'جدة'},
      isCurrent: current ?? () => true,
    );

    test('banks and statements are merged from the device ledger', () async {
      BranchScope.allMode = true;
      final banking = AllBranchesBanking(view());
      final rows = await banking.accounts();
      final sar = rows.singleWhere((r) => r['currency'] == 'SAR');
      expect(sar['balance'], '1200.00'); // 1000 − 50 + 250
      expect(rows.singleWhere((r) => r['currency'] == 'USD')['balance'], '30.00');
      expect({for (final r in rows) r['group_key']}, {'all:name:الراجحي'});
      final history = await banking.history(['${sar['id']}']);
      expect(history.map((h) => h['branch_name']).toSet(), {'الرياض', 'جدة'});
      expect(history.every((h) => h['bank_account_id'] == sar['id']), isTrue);
    });

    test('the merged money report sums both branches in one currency', () async {
      final reads = await view().each(
        {BusinessLedgerAction.readMoneyReport},
        (ledger, access) => ledger.moneyReport(
          access,
          currency: 'SAR',
          fx: const BusinessReportFx.empty(),
        ),
      );
      final merged = mergeBranchReports(reads);
      expect(merged['branch_ids'], [a, b]);
      final perCurrency = (merged['balances'] as Map)['per_currency'] as List;
      expect(
        perCurrency.firstWhere((r) => (r as Map)['currency'] == 'SAR'),
        containsPair('total', '1200.00'),
      );
      expect(
        (merged['by_branch'] as List).map((r) => (r as Map)['branch_name']),
        ['الرياض', 'جدة'],
      );
    });

    test('nothing is written and a switch back stops the merged read', () async {
      BranchScope.allMode = true;
      final write = BusinessLedgerAccess(scope(a), {BusinessLedgerAction.moveMoney});
      expect(write.onlyReads, isFalse);
      await expectLater(
        store.withLedger(write, () => scope(a), (_) async => 1),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      var selected = true;
      final merged = view(current: () => selected);
      selected = false;
      await expectLater(
        merged.each({BusinessLedgerAction.readBank}, (l, g) async => 1),
        throwsA(isA<DirectoryAccessDenied>()),
      );
    });
  });

  group('read-only «جميع الفروع»', () {
    tearDown(() => BranchScope.allMode = false);

    test('every write right is off, reading rights are untouched', () {
      final container = ProviderContainer(
        overrides: [
          currentUserProvider.overrideWithValue(null),
          employeeWorkspaceCompanyProvider.overrideWithValue(null),
          employeePermissionsProvider.overrideWithValue(const {}),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(employeeCanProvider('banks.add_delete')), isTrue);
      BranchScope.allMode = true;
      container.read(branchEpochProvider.notifier).state++;
      for (final right in businessWriteRights) {
        expect(container.read(employeeCanProvider(right)), isFalse, reason: right);
      }
      expect(container.read(employeeCanProvider('banks')), isTrue);
      expect(container.read(employeeCanProvider('reports.view')), isTrue);
      BranchScope.allMode = false;
      container.read(branchEpochProvider.notifier).state++;
      expect(container.read(employeeCanProvider('banks.add_delete')), isTrue);
    });

    testWidgets('operation tiles are hidden, reading tiles stay', (tester) async {
      await tester.runAsync(() => AppLocalizations.preload('ar'));
      Future<void> pump() async {
        await tester.pumpWidget(
          ProviderScope(
            key: UniqueKey(),
            overrides: [
              currentUserProvider.overrideWithValue(null),
              employeeWorkspaceCompanyProvider.overrideWithValue(null),
              employeePermissionsProvider.overrideWithValue(const {}),
            ],
            child: MaterialApp(
              locale: const Locale('ar'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: const Scaffold(
                body: SingleChildScrollView(child: BusinessServicesGrid()),
              ),
            ),
          ),
        );
        await tester.pump();
      }

      await pump();
      final l10n = AppLocalizations.of(tester.element(find.byType(Scaffold)));
      for (final key in ['bizSaleInvoice', 'bizPurchaseInvoice', 'bizInvoices']) {
        expect(find.text(l10n.translate(key)), findsOneWidget, reason: key);
      }
      BranchScope.allMode = true;
      await pump();
      for (final key in [
        'bizSaleInvoice',
        'bizPurchaseInvoice',
        'bizExpenses',
        'bizReconcile',
      ]) {
        expect(find.text(l10n.translate(key)), findsNothing, reason: key);
      }
      for (final key in ['bizInvoices', 'bizWarehouse', 'bizTransactions']) {
        expect(find.text(l10n.translate(key)), findsOneWidget, reason: key);
      }
    });

    test('Sara reads in all branches but never executes', () async {
      BranchScope.allMode = true;
      expect(
        BusinessDeviceRouter.readRoutes.every((r) => r.startsWith('GET ')),
        isTrue,
      );
      expect(BusinessDeviceRouter.readRoutes, contains('GET /banking/accounts'));
      final refused = await BusinessDeviceRouter.handle(
        <T>(ProviderListenable<T> p) => throw StateError('must not read'),
        method: 'POST',
        path: '/expenses',
        body: {'amount': '5', 'bank_account_id': 'x'},
      );
      expect(refused['success'], isFalse);
    });
  });
}
