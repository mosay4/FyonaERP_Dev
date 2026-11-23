import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/business_banks/presentation/pages/business_account_detail_page.dart';
import 'package:fyona_flutter/features/business_banks/presentation/pages/business_bank_detail_page.dart';
import 'package:fyona_flutter/features/business_banks/presentation/pages/business_banks_page.dart';
import 'package:fyona_flutter/features/business_banks/presentation/providers/business_banks_providers.dart';
import 'package:fyona_flutter/features/business_banks/presentation/providers/local_business_banking.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/project_settings_api.dart';
import 'package:fyona_flutter/features/core_business/presentation/providers/biz_payment_pref.dart';
import 'package:fyona_flutter/features/dashboard/presentation/providers/business_dashboard_providers.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/shared/providers/current_user_provider.dart';
import 'package:fyona_flutter/shared/widgets/currency_selector.dart';
import 'package:fyona_flutter/shared/widgets/dots_loader.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();
String _rates(double sar) => jsonEncode({
  'version': 2,
  'approved': true,
  'global_rates': {'USD': 1, 'SAR': sar},
});

DirectoryAccess _scope(DirectoryWorkspace workspace) => DirectoryAccess(
  workspace: workspace,
  branchId: _id(),
  readable: DirectoryPartyKind.values.toSet(),
  writable: DirectoryPartyKind.values.toSet(),
  financialCutover: true,
);

class _BankLab {
  final workspace = DirectoryWorkspace(
    server: DirectoryPilotBuild.baseUrl,
    accountId: _id(),
    organizationId: _id(),
  );
  final online = ConnectivityService(debugOnline: false);
  final denied = StateProvider<Set<String>>((_) => {});
  final rest = <String>[];
  late final DirectoryAccess scope = _scope(workspace);
  late final DirectoryAccess sibling = _scope(workspace);
  late final selected = StateProvider<DirectoryAccess?>((_) => scope);
  late final Directory root;
  late final DirectoryPilotStore store;
  late final ProviderContainer container;
  Future<Directory> Function()? openRoot;

  Never _unexpected(String call) {
    rest.add(call);
    throw StateError('Unexpected connected path: $call');
  }

  Future<void> setup() async {
    SharedPreferences.setMockInitialValues({
      'biz_wallet_currency': 'SAR',
      'currency_engine_cache': _rates(3.75),
      'enabled_currencies_${workspace.accountId}': ['JPY'],
    });
    await BranchScope.clear();
    root = await Directory.systemTemp.createTemp('fyona-business-banks-');
    store = DirectoryPilotStore(
      keys: FixtureDirectoryKeys(),
      root: () => openRoot?.call() ?? Future.value(root),
    );
    final status = {
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
    };
    await store.remember(scope, status);
    await store.remember(sibling, status);
    container = ProviderContainer(
      overrides: [
        directoryPilotStoreProvider.overrideWithValue(store),
        directoryPilotAccessProvider.overrideWith((ref) => ref.watch(selected)),
        businessLocalLedgerScopeProvider.overrideWith(
          (ref) => ref.watch(selected),
        ),
        connectivityServiceProvider.overrideWithValue(online),
        currentUserIdProvider.overrideWithValue(workspace.accountId),
        employeeWorkspaceCompanyProvider.overrideWithValue(null),
        employeeCanProvider.overrideWith(
          (ref, group) => !ref.watch(denied).contains(group),
        ),
        businessBanksApiProvider.overrideWith((_) => _unexpected('banking')),
        bizCashServiceProvider.overrideWith(
          (_) => _unexpected('legacy cash vault'),
        ),
        businessFinanceApiProvider.overrideWith((_) => _unexpected('finance')),
        projectSettingsApiProvider.overrideWith(
          (_) => _unexpected('project settings'),
        ),
        currencyEngineProvider.overrideWith(
          (_) => _unexpected('connected currency engine'),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      online.dispose();
      await store.close();
      await root.delete(recursive: true);
      expect(rest, isEmpty);
    });
  }

  BusinessBanksNotifier get bank =>
      container.read(businessBanksProvider.notifier);

  Future<Map<String, Object?>> seed(
    String bank,
    String currency,
    int balance,
    String id, {
    DirectoryAccess? branch,
  }) {
    final selectedBranch = branch ?? scope;
    final grant = BusinessLedgerAccess(selectedBranch, {
      BusinessLedgerAction.createBank,
    });
    return store.withLedger(
      grant,
      () => selectedBranch,
      (ledger) => ledger.createAccount(
        grant,
        commandId: id,
        bankName: bank,
        accountName: bank,
        accountNumber: '',
        currency: currency,
        openingMinor: balance,
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'writes recheck permissions after database open; retained sources cannot switch branches',
    () async {
      final lab = _BankLab();
      await lab.setup();
      final till = _id();
      final office = _id();
      await lab.seed('كاش', 'SAR', 10000, till);
      await lab.seed('Office', 'SAR', 0, office);
      await lab.seed('Sibling only', 'SAR', 7600, _id(), branch: lab.sibling);
      final source = lab.bank;
      await source.load();
      expect(
        (await lab.container.read(businessAccountsProvider.future)).length,
        2,
      );
      await lab.store.close();

      final opening = Completer<void>();
      final finish = Completer<Directory>();
      lab.openRoot = () {
        opening.complete();
        return finish.future;
      };
      final action = source.transfer(fromId: till, toId: office, amount: 15);
      final rejection = expectLater(
        action,
        throwsA(isA<DirectoryAccessDenied>()),
      );
      await opening.future;
      lab.container.read(lab.denied.notifier).state = {'banks.transfer'};
      finish.complete(lab.root);
      await rejection;
      lab.openRoot = null;
      expect((await source.history([till])).single['amount'], '100.00');

      lab.container.read(lab.denied.notifier).state = {'banks.balances'};
      final history = await source.history([till]);
      expect(history.single, isNot(contains('running_balance')));
      lab.container.read(lab.denied.notifier).state = {'banks.details'};
      await expectLater(
        source.history([till]),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      lab.container.read(lab.denied.notifier).state = {};
      lab.container.read(lab.selected.notifier).state = lab.sibling;
      await expectLater(
        source.history([till]),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      final next = lab.bank;
      await next.load();
      await expectLater(
        next.history([till]),
        throwsA(isA<BusinessLedgerError>()),
      );
      expect(
        (await lab.container.read(
          businessAccountsProvider.future,
        )).single.bankName,
        'Sibling only',
      );
    },
    skip: !DirectoryPilotBuild.signupEnabled,
  );

  test(
    'Business payment policy persists without the settings API or Personal preferences',
    () async {
      final lab = _BankLab();
      await lab.setup();
      final till = _id();
      await lab.seed('كاش', 'SAR', 0, till);
      final pref = lab.container.read(bizPaymentPrefProvider.notifier);
      await expectLater(
        lab.bank.withdraw(till, 0.01),
        throwsA(
          isA<BusinessLedgerError>().having(
            (e) => e.problem,
            'problem',
            BusinessLedgerProblem.insufficientBalance,
          ),
        ),
      );
      await pref.setAllowNegative(true);
      await lab.bank.withdraw(till, 0.01);
      await lab.store.close();
      await pref.load();
      expect(lab.container.read(bizPaymentPrefProvider).allowNegative, isTrue);
      expect(
        (await lab.bank.history([till])).single['running_balance'],
        '-0.01',
      );
      expect(
        (await SharedPreferences.getInstance()).getStringList(
          'enabled_currencies_${lab.workspace.accountId}',
        ),
        ['JPY'],
      );
    },
    skip: !DirectoryPilotBuild.signupEnabled,
  );

  test(
    'an open Business home receives committed accounts without refreshing REST',
    () async {
      final lab = _BankLab();
      await lab.setup();
      await lab.seed('Fixture cash', 'SAR', 0, _id());
      final changed = Completer<double>();
      final subscription = lab.container.listen(businessAccountsProvider, (
        _,
        next,
      ) {
        final added = next.asData?.value
            .where((a) => a.bankName == 'Committed bank')
            .firstOrNull;
        if (added != null && !changed.isCompleted) {
          changed.complete(added.balance);
        }
      });
      addTearDown(subscription.close);
      expect(
        (await lab.container.read(
          businessAccountsProvider.future,
        )).single.bankName,
        'Fixture cash',
      );
      await lab.bank.addAccount(
        bankName: 'Committed bank',
        accountName: 'Committed bank',
        accountNumber: '',
        currency: 'SAR',
        decimalBalance: '21.07',
      );
      expect(await changed.future.timeout(const Duration(seconds: 5)), 21.07);
    },
    skip: !DirectoryPilotBuild.signupEnabled,
  );

  testWidgets(
    'original bank creation, transfer and statements work with connectivity loss and reopen',
    (tester) async {
      final lab = _BankLab();
      final till = _id();
      final office = _id();
      await tester.runAsync(() async {
        await lab.setup();
        await AppLocalizations.preload('ar');
        await lab.seed('صندوق التجربة', 'USD', 10000, till);
        await lab.seed('بنك التجربة', 'SAR', 0, office);
        await lab.seed('كاش', 'SAR', 0, _id());
      });
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final router = GoRouter(
        initialLocation: '/banks',
        routes: [
          GoRoute(
            path: '/banks',
            builder: (_, _) => const Scaffold(body: BusinessBanksPage()),
          ),
          GoRoute(
            path: LocalBankAccountTarget.path,
            builder: (_, state) => BusinessAccountDetailPage(
              localAccount: state.extra! as LocalBankAccountTarget,
            ),
          ),
          GoRoute(
            path: '/banks/detail',
            builder: (_, _) => const Scaffold(
              body: BusinessBankDetailPage(bankName: 'بنك التجربة'),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: lab.container,
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('ar'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
          ),
        ),
      );
      Future<void> until(Finder target) async {
        for (var i = 0; i < 80; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 12)),
          );
          await tester.pump(const Duration(milliseconds: 25));
          expect(find.byType(DotsLoader), findsNothing);
          if (target.evaluate().isNotEmpty) return;
        }
        expect(target, findsWidgets);
      }

      Future<void> tap(Finder finder) async {
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      Future<void> withDisk(Future<void> Function() operation) async {
        var completed = false;
        Object? failure;
        StackTrace? trace;
        await tester.runAsync(() async {
          unawaited(
            operation().then<void>(
              (_) => completed = true,
              onError: (Object error, StackTrace stack) {
                failure = error;
                trace = stack;
                completed = true;
              },
            ),
          );
        });
        // A widget-triggered FFI read may already hold the store lock. Let
        // its fake-clock continuation run while the real disk work completes.
        for (var i = 0; i < 100 && !completed; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        if (!completed) fail('The local ledger did not finish its disk work');
        if (failure != null) Error.throwWithStackTrace(failure!, trace!);
      }

      Future<void> choose(String field, String bank) async {
        await tap(find.text(field));
        final sheet = find.byType(BottomSheet);
        await tap(find.descendant(of: sheet, matching: find.text(bank)));
      }

      await until(find.text('صندوق التجربة'));
      for (final initiallyOnline in [false, true]) {
        lab.online.debugSetOnline(initiallyOnline);
        await tap(find.text('المصارفة'));
        await choose('من حساب', 'صندوق التجربة');
        await choose('إلى حساب', 'بنك التجربة');
        await tester.enterText(find.byType(EditableText).last, '2.25');
        await tester.pump();
        final save = tester
            .widget<ElevatedButton>(
              find.ancestor(
                of: find.text('تحويل'),
                matching: find.byWidgetPredicate(
                  (widget) => widget is ElevatedButton,
                ),
              ),
            )
            .onPressed!;
        await tester.runAsync(() async {
          save();
          lab.online.debugSetOnline(false);
          save();
        });
        await until(find.text('تمت المصارفه بنجاح'));
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
      }
      await tap(find.text('إضافة بنك'));
      Finder field(String hint) => find.byWidgetPredicate(
        (widget) => widget is TextField && widget.decoration?.hintText == hint,
      );
      await tester.enterText(field('اسم البنك'), 'حساب مضاف من الجهاز');
      await tester.enterText(field('الرصيد الافتتاحي'), '99.12');
      await tap(field('اختر العملة'));
      final selector = find.byType(CurrencySelector);
      await tap(
        find.descendant(of: selector, matching: find.text(currencyName('SAR'))),
      );
      expect(tester.widget<CurrencySelector>(selector).value, 'SAR');
      final add = tester
          .widget<ElevatedButton>(
            find.ancestor(
              of: find.text('إضافة'),
              matching: find.byWidgetPredicate(
                (widget) => widget is ElevatedButton,
              ),
            ),
          )
          .onPressed!;
      await tester.runAsync(() async {
        add();
        add();
      });
      // find.text also matches the editable value while the INSERT is running.
      final bankRow = find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == 'حساب مضاف من الجهاز',
      );
      await until(bankRow);
      expect(field('اسم البنك'), findsNothing);
      expect(bankRow, findsOneWidget);
      await withDisk(() async {
        await lab.bank.load();
        final accounts = lab.container.read(businessBanksProvider).accounts;
        expect(
          accounts
              .singleWhere((a) => a.bankName == 'حساب مضاف من الجهاز')
              .balance,
          99.12,
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('currency_engine_cache', _rates(4));
        await lab.bank.load();
        final rows = await lab.bank.history([till, office]);
        expect(
          rows.where((row) => row['tx_type'] == 'transfer_out'),
          hasLength(2),
        );
        final received = rows.where((row) => row['tx_type'] == 'transfer_in');
        expect(received.map((row) => row['amount']), ['8.44', '8.44']);
        expect(received.map((row) => row['exchange_rate']), [
          '3.75000000',
          '3.75000000',
        ]);
        await lab.store.close();
      });
      router.go(
        LocalBankAccountTarget.path,
        extra: LocalBankAccountTarget(lab.scope, office),
      );
      await tester.pumpAndSettle();
      await until(find.textContaining('تحويل من صندوق التجربة'));
      expect(find.textContaining('تحويل من صندوق التجربة'), findsNWidgets(2));
      expect(find.textContaining(fmtNum(16.88)), findsWidgets);
      router.go('/banks/detail');
      await tester.pumpAndSettle();
      await until(find.textContaining('تحويل من صندوق التجربة'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await withDisk(lab.store.close);
    },
    skip: !DirectoryPilotBuild.signupEnabled,
  );
}
