import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/personal/data/merchant_api.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/merchant_debt_pages.dart';
import 'package:uuid/uuid.dart';

import 'support/business_cash_test_checkpoint.dart';
import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

void main() {
  testWidgets(
    'the original Business alerts tab reads one reversed withdrawal offline',
    (tester) async {
      final scope = DirectoryAccess(
        workspace: DirectoryWorkspace(
          server: DirectoryPilotBuild.baseUrl,
          accountId: _id(),
          organizationId: _id(),
        ),
        branchId: _id(),
        readable: DirectoryPartyKind.values.toSet(),
        writable: DirectoryPartyKind.values.toSet(),
        financialCutover: true,
      );
      final session = _id();
      final access = BusinessLedgerAccess(
        scope, BusinessLedgerAction.values.toSet(), cashSessionId: session,
      );
      final selected = StateProvider<DirectoryAccess?>((_) => scope);
      final denied = StateProvider<Set<String>>((_) => {});
      final account = _id();
      final command = _id();
      final earlier = _id();
      late DirectoryPilotStore store;
      late Directory root;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('fyona-cash-alert-widget-');
        store = DirectoryPilotStore(root: () async => root, keys: FixtureDirectoryKeys());
        await AppLocalizations.preload('ar');
        await store.remember(scope, {
          'status': 'active',
          'business_setup_completed': true,
          'sections': {'business': {
            'active': true,
            'end_date': DateTime.now().add(const Duration(days: 1)).toIso8601String(),
          }},
        });
        await store.withLedger(access, () => scope, (ledger) async {
          await ledger.createAccount(
            access, commandId: account, bankName: 'Cash', accountName: 'QA',
            accountNumber: '1', currency: 'SAR', openingMinor: 1000,
          );
          await ledger.cashSync.provision(access, account, grantVersion: 1, allowNegative: false);
          await ledger.cashSync.bindReplica(
            access, sessionId: session,
            checkpoint: cashTestCheckpoint(scope, account, balance: 1000),
          );
          await ledger.move(
            access, commandId: command, accountId: account, amountMinor: 1000, withdraw: true,
          );
          for (var i = 0; i < 2; i++) {
            await ledger.cashSync.decide(
              access, commandId: command, sequence: 2, blockedBy: earlier,
              decision: BusinessCashDecision.insufficientBalance,
            );
          }
        });
        await store.close();
      });
      addTearDown(() async {
        await store.close();
        await root.delete(recursive: true);
      });
      final online = ConnectivityService(debugOnline: false);
      addTearDown(online.dispose);
      var remote = 0;
      final container = ProviderContainer(overrides: [
        directoryPilotStoreProvider.overrideWithValue(store),
        businessLocalLedgerScopeProvider.overrideWith((ref) => ref.watch(selected)),
        employeeCanProvider.overrideWith((ref, key) => !ref.watch(denied).contains(key)),
        connectivityServiceProvider.overrideWithValue(online),
        merchantApiProvider.overrideWith((_) {
          remote++;
          throw StateError('No remote notifications should run offline');
        }),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const DebtNotificationsPage(initialTab: 1),
        ),
      ));
      final note = find.text('تم عكس سحب 10.00 SAR. السبب: الرصيد غير كافٍ.');
      for (var i = 0; i < 30 && note.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
        expect(find.byType(CircularProgressIndicator), findsNothing);
      }
      expect(note, findsOneWidget);
      await tester.tap(note);
      await tester.pumpAndSettle();
      expect(find.textContaining(earlier), findsOneWidget);
      container.read(denied.notifier).state = {'transactions'};
      await tester.pumpAndSettle();
      expect(find.textContaining(earlier), findsNothing);
      container.read(selected.notifier).state = null;
      await tester.pumpAndSettle();
      expect(find.text('غير مصرح بالوصول'), findsOneWidget);
      expect(note, findsNothing);
      expect(remote, 0);

      // Closing the sheet did not create an extra receipt or clear the
      // notification from disk. The read itself was committed in this scope.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        final local = await store.withLedger(access, () => scope,
            (ledger) => ledger.cashSync.conflicts(access));
        expect(local.single['seen'], 1);
      });
      expect(tester.takeException(), isNull);
    },
    skip: !DirectoryPilotBuild.signupEnabled,
  );
}
