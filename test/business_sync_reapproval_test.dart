import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:uuid/uuid.dart';

import 'support/business_cash_test_checkpoint.dart';
import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

void main() {
  final workspace = DirectoryWorkspace(
    server: 'http://localhost:18083/api/v1',
    accountId: _id(),
    organizationId: _id(),
  );
  final scope = DirectoryAccess(
    workspace: workspace,
    branchId: _id(),
    readable: {},
    writable: {},
    financialCutover: true,
  );
  final all = BusinessLedgerAction.values.toSet();
  late Directory root;
  late DirectoryDatabase db;
  late String account;
  BusinessLedger ledger() => db.ledger;
  BusinessLedgerAccess inSession(String session) =>
      BusinessLedgerAccess(scope, all, cashSessionId: session);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fyona-reapproval-');
    db = await DirectoryDatabase.open(
      root: root,
      workspace: workspace,
      keys: FixtureDirectoryKeys(),
    );
    account = _id();
    await ledger().createAccount(
      inSession(_id()),
      commandId: account,
      bankName: 'Cash',
      accountName: 'Till',
      accountNumber: '1',
      currency: 'SAR',
      openingMinor: 10000,
    );
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<DirectoryDatabase> restoreIntoCopy() async {
    final file = File('${root.path}/state.fyonabiz');
    final code = BusinessBackupCode.generate();
    await ledger().captureBackup(
      inSession(_id()),
      id: _id(),
      destination: file,
      code: code,
      allowed: () => true,
    );
    final copy = await DirectoryDatabase.open(
      root: await root.createTemp('recovery-'),
      workspace: workspace,
      keys: FixtureDirectoryKeys(),
    );
    addTearDown(copy.close);
    expect(
      await copy.ledger.restoreBackup(
        inSession(_id()),
        source: file,
        code: code,
        allowed: () => true,
      ),
      (alreadyRestored: false, hasSharedHistory: true),
    );
    return copy;
  }

  test(
    're-approval seals restored requests and only then permits a fresh admission',
    () async {
      final session = _id();
      final scoped = inSession(session);
      await ledger().cashSync.provision(
        scoped,
        account,
        grantVersion: 1,
        allowNegative: false,
      );
      await ledger().cashSync.bindReplica(
        scoped,
        sessionId: session,
        checkpoint: cashTestCheckpoint(scope, account, balance: 10000),
      );
      final pending = _id();
      await ledger().cashSync.withdraw(
        scoped,
        commandId: pending,
        accountId: account,
        amountMinor: 250,
        description: 'سحب قبل الاستعادة',
      );
      expect(
        (await ledger().cashSync.pending(scoped)).single['command_id'],
        pending,
      );

      final copy = await restoreIntoCopy();
      final restored = inSession(_id());
      // The restored node is frozen: no session of any kind may be admitted.
      await expectLater(
        copy.ledger.cashSync.bindReplica(
          restored,
          sessionId: restored.cashSessionId!,
          checkpoint: cashTestCheckpoint(scope, account, balance: 9750),
        ),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      expect((await copy.ledger.cashSync.pending(restored)).single['command_id'], pending);

      final approvalCommand = _id();
      final receipt = await copy.ledger.approveRecoveredSync(
        restored,
        commandId: approvalCommand,
      );
      expect(receipt['sealed_count'], 1);
      expect((receipt['sealed'] as List).single['command_id'], pending);
      expect(await copy.ledger.approveRecoveredSync(restored, commandId: approvalCommand), receipt);
      await expectLater(
        copy.ledger.approveRecoveredSync(restored, commandId: _id()),
        throwsA(
          isA<BusinessLedgerError>().having(
            (e) => e.problem,
            'problem',
            BusinessLedgerProblem.noChanges,
          ),
        ),
      );

      // The sealed request is visible forever and never enters a delivery.
      expect(await copy.ledger.cashSync.pending(restored), isEmpty);
      final sealed = await copy.ledger.suspendedRequests(restored);
      expect(sealed.single['command_id'], pending);
      expect(sealed.single['kind'], 'withdrawal');
      expect((sealed.single['payload'] as Map)['amount_minor'], 250);

      // Only now may a fresh session and checkpoint be admitted.
      final fresh = _id();
      final freshAccess = inSession(fresh);
      final checkpoint = cashTestCheckpoint(scope, account, balance: 9750);
      await copy.ledger.cashSync.bindReplica(
        freshAccess,
        sessionId: fresh,
        checkpoint: checkpoint,
      );
      expect(await copy.ledger.cashSync.replicaCheckpoint(freshAccess, fresh), checkpoint);
      // A live command staged after the approval is pending again, while the
      // sealed past stays visible and unservable.
      await copy.ledger.cashSync.withdraw(
        freshAccess,
        commandId: _id(),
        accountId: account,
        amountMinor: 100,
        description: 'سحب بعد الاعتماد',
      );
      expect((await copy.ledger.cashSync.pending(freshAccess)).map((row) => row['amount_minor']), [100]);
      expect((await copy.ledger.suspendedRequests(freshAccess)).map((row) => row['amount_minor']), [250]);
    },
  );

  test(
    'a restored settlement request stays suspended after re-approval',
    () async {
      final session = _id();
      final scoped = inSession(session);
      await ledger().cashSync.provision(
        scoped,
        account,
        grantVersion: 1,
        allowNegative: false,
      );
      await ledger().cashSync.bindReplica(
        scoped,
        sessionId: session,
        checkpoint: cashTestCheckpoint(scope, account, balance: 10000),
        settlementProtocol: true,
      );
      final recon = _id();
      final entries = [(accountId: account, expectedMinor: 10000, actualMinor: 8800)];
      await ledger().checkBankReconciliation(
        scoped,
        id: recon,
        entries: entries,
        allowed: () => true,
      );
      final staged = await ledger().approveBankReconciliation(
        scoped,
        id: recon,
        entries: entries,
        allowed: () => true,
      );
      expect(staged['authority_state'], 'queued');

      final copy = await restoreIntoCopy();
      final restored = inSession(_id());
      expect(
        (await copy.ledger.bankReconciliationDetail(restored, recon))['authority_state'],
        'suspended',
      );
      final receipt = await copy.ledger.approveRecoveredSync(
        restored,
        commandId: _id(),
      );
      expect(receipt['sealed_count'], 1);
      expect((receipt['sealed'] as List).single['kind'], 'equalization');
      expect((receipt['sealed'] as List).single['recon_id'], recon);
      // Re-approval never revives the request.
      expect(
        (await copy.ledger.bankReconciliationDetail(restored, recon))['authority_state'],
        'suspended',
      );
      expect(
        (await copy.ledger.suspendedRequests(restored)).map((row) => row['kind']),
        ['equalization'],
      );

      // A fresh admission may decide only fresh requests.
      final fresh = _id();
      final freshAccess = inSession(fresh);
      await copy.ledger.cashSync.bindReplica(
        freshAccess,
        sessionId: fresh,
        checkpoint: cashTestCheckpoint(scope, account, balance: 10000),
        settlementProtocol: true,
      );
      final next = _id();
      await copy.ledger.checkBankReconciliation(
        freshAccess,
        id: next,
        entries: entries,
        allowed: () => true,
      );
      expect(
        (await copy.ledger.approveBankReconciliation(
          freshAccess,
          id: next,
          entries: entries,
          allowed: () => true,
        ))['authority_state'],
        'queued',
      );
      expect(
        (await copy.ledger.bankReconciliationDetail(freshAccess, next))['authority_state'],
        'queued',
      );
      expect(
        (await copy.ledger.bankReconciliationDetail(freshAccess, recon))['authority_state'],
        'suspended',
      );
    },
  );
}
