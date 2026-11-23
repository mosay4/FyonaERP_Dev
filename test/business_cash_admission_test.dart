import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:uuid/uuid.dart';

import 'support/business_cash_test_checkpoint.dart';
import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

void main() {
  test(
    'a stale count cannot freeze the till and a canceled plan preserves it',
    () async {
      final temp = await Directory.systemTemp.createTemp('fyona-cash-link-');
      final session = _id(), account = _id(), plan = _id();
      final scope = DirectoryAccess(
        workspace: DirectoryWorkspace(
          server: 'http://localhost:18083/api/v1',
          organizationId: _id(),
          accountId: _id(),
        ),
        branchId: _id(),
        readable: {},
        writable: {},
        financialCutover: true,
        cashLinkId: plan,
      );
      final db = await DirectoryDatabase.open(
        root: temp,
        workspace: scope.workspace,
        keys: FixtureDirectoryKeys(),
      );
      addTearDown(() async {
        await db.close();
        await temp.delete(recursive: true);
      });
      final ledger = db.ledger;
      final access = BusinessLedgerAccess(scope, {
        BusinessLedgerAction.syncCash,
        BusinessLedgerAction.createBank,
        BusinessLedgerAction.moveMoney,
        BusinessLedgerAction.readBank,
        BusinessLedgerAction.checkBankReconciliation,
      }, cashSessionId: session);
      await ledger.createAccount(
        access,
        commandId: account,
        bankName: 'كاش',
        accountName: 'حساب الكاش',
        accountNumber: 'CASH',
        currency: 'SAR',
        openingMinor: 50000,
      );
      Future<String> measure() async =>
          (await ledger.checkBankReconciliation(
                access,
                id: _id(),
                entries: [
                  (
                    accountId: account,
                    actualMinor: 50000,
                    expectedMinor: 50000,
                  ),
                ],
                allowed: () => true,
              ))['ref_code']
              as String;
      BusinessCashLink frame(
        String ref, {
        String state = 'pending',
        bool reported = true,
      }) {
        final checkpoint = cashTestCheckpoint(scope, account, balance: 50000);
        return BusinessCashLink.parse(
          {
            'id': plan,
            'organization_id': scope.workspace.organizationId,
            'actor_id': scope.workspace.accountId,
            'branch_id': scope.branchId,
            'session_id': session,
            if (reported) ...{
              'account_id': account,
              'currency': 'SAR',
              'balance_minor': 50000,
              'checkpoint': {'sequence': 0, 'digest': checkpoint.digest},
            },
            'role': 'primary',
            'check_ref': ref,
            'state': state,
          },
          scope,
          session,
        );
      }

      Future<void> move(bool withdraw) => ledger.move(
        access,
        commandId: _id(),
        accountId: account,
        amountMinor: 125,
        withdraw: withdraw,
      );
      final stale = await measure();
      await move(true);
      await move(false);
      // The count no longer matches the balance: the device waits and the
      // till stays writable instead of freezing on a stale number.
      expect(
        await ledger.cashSync.reconcileLink(
          access,
          frame(stale, reported: false),
          allowed: () => true,
        ),
        isNull,
      );
      await expectLater(
        ledger.cashSync.reconcileLink(
          access,
          frame(stale),
          allowed: () => true,
        ),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      final ref = await measure();
      final reserved = await ledger.cashSync.reconcileLink(
        access,
        frame(ref),
        allowed: () => true,
      );
      expect(reserved!['account_id'], account);
      await expectLater(move(true), throwsA(isA<BusinessLedgerError>()));
      await ledger.cashSync.reconcileLink(
        access,
        frame(ref, state: 'canceled'),
        allowed: () => true,
      );
      expect(await ledger.cashSync.replicaCheckpoint(access, session), isNull);
      await move(true);
      expect((await ledger.accounts(access)).single['balance_minor'], 49875);
    },
  );
}
