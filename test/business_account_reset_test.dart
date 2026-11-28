// Reset of the whole Business account: the owner's phone empties its copy,
// every other device gets the relay's «reset» and empties its copy too;
// nothing old comes back, and the devices keep syncing afterwards.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

/// The relay as the devices see it (as in business_sync_engine_test).
final class _Relay {
  int head = 0;
  final ops = <String, ({int seq, String from, Map<String, Object?> payload, String? branch})>{};
  final inbox = <String, Set<String>>{};

  Future<void> push(DirectoryDatabase db, String replica) async {
    final sequenced = <String, int>{};
    for (final op in await db.syncOutbox()) {
      final seen = ops[op.id];
      final seq = seen?.seq ?? ++head;
      if (seen == null) {
        ops[op.id] = (seq: seq, from: replica, payload: op.payload, branch: op.branchId);
        for (final other in inbox.keys) {
          if (other != replica) inbox[other]!.add(op.id);
        }
      }
      sequenced[op.id] = seq;
    }
    await db.syncPushed(sequenced);
  }

  Future<void> pull(DirectoryDatabase db, String replica) async {
    final ids = inbox[replica]!.toList()..sort((a, b) => ops[a]!.seq.compareTo(ops[b]!.seq));
    final stored = await db.syncApply([
      for (final id in ids) (id: id, seq: ops[id]!.seq, kind: 'ops', branchId: ops[id]!.branch, payload: ops[id]!.payload),
    ], drained: true, head: head);
    for (final id in stored) {
      inbox[replica]!.remove(id);
    }
  }
}

void main() {
  if (!DirectoryPilotBuild.signupEnabled) {
    test('business reset', () {}, skip: 'needs the QA directory defines');
    return;
  }
  sqfliteFfiInit();

  test('reset: both devices empty, same device identity, nothing old returns, sync works after', () async {
    final tmp = await Directory.systemTemp.createTemp('fyona-reset-');
    addTearDown(() => tmp.delete(recursive: true));
    final w = DirectoryWorkspace(server: DirectoryPilotBuild.baseUrl, accountId: _id(), organizationId: _id());
    final scope = DirectoryAccess(workspace: w, branchId: _id(), readable: DirectoryPartyKind.values.toSet(),
        writable: DirectoryPartyKind.values.toSet(), financialCutover: true);
    final grant = BusinessLedgerAccess(scope, BusinessLedgerAction.values.toSet());
    final relay = _Relay();

    Future<(DirectoryDatabase, String)> open(Directory root) async {
      final db = await DirectoryDatabase.open(root: root, workspace: w, keys: FixtureDirectoryKeys(root));
      final replica = await db.syncReplicaId();
      await db.syncSetAuthor(userId: w.accountId, name: 'owner');
      relay.inbox.putIfAbsent(replica, () => {});
      return (db, replica);
    }

    Future<void> round(DirectoryDatabase a, String ra, DirectoryDatabase b, String rb) async {
      for (var i = 0; i < 2; i++) {
        await relay.push(a, ra);
        await relay.push(b, rb);
        await relay.pull(a, ra);
        await relay.pull(b, rb);
      }
    }

    Future<Map<String, Object?>> facts(DirectoryDatabase db) async => {
          'customers': [for (final p in await db.search(scope, DirectoryPartyKind.customer, '')) p.name]..sort(),
          'accounts': (await db.ledger.accounts(grant)).length,
        };

    final rootA = Directory('${tmp.path}/a')..createSync();
    final rootB = Directory('${tmp.path}/b')..createSync();
    final (dbA, repA) = await open(rootA);
    final (dbB, repB) = await open(rootB);
    // Data made on A, copied to B.
    await dbA.ledger.addPartyWithOpeningDebt(grant, DirectoryPartyKind.customer,
        commandId: _id(), name: 'عميل قديم', amountMinor: 5000, currency: 'SAR');
    await dbA.ledger.createAccount(grant, commandId: _id(), bankName: 'كاش', accountName: 'كاش',
        accountNumber: 'CASH', currency: 'SAR', openingMinor: 9000, managed: true);
    await round(dbA, repA, dbB, repB);
    expect((await facts(dbB))['customers'], ['عميل قديم']);
    // B made something offline that is still on its way when A resets.
    await dbB.ledger.addPartyWithOpeningDebt(grant, DirectoryPartyKind.customer,
        commandId: _id(), name: 'عميل في الطريق', amountMinor: 0, currency: 'SAR');
    await relay.push(dbB, repB);

    // The reset: the server drops what is on its way; A empties itself; B
    // receives «reset» and empties its copy.
    relay.ops.clear();
    for (final box in relay.inbox.values) {
      box.clear();
    }
    await dbA.syncWipe();
    await dbB.syncWipe();
    for (final db in [dbA, dbB]) {
      expect(await facts(db), {'customers': <String>[], 'accounts': 0});
      expect(await db.syncOutbox(), isEmpty);
    }
    expect(await dbA.syncReplicaId(), repA, reason: 'the device stays itself');
    expect(await dbB.syncReplicaId(), repB);

    // Life goes on: a new customer on A reaches B; nothing old returns.
    await dbA.ledger.addPartyWithOpeningDebt(grant, DirectoryPartyKind.customer,
        commandId: _id(), name: 'عميل جديد', amountMinor: 0, currency: 'SAR');
    await round(dbA, repA, dbB, repB);
    expect((await facts(dbB))['customers'], ['عميل جديد']);
    expect((await facts(dbA))['customers'], ['عميل جديد']);
    await dbA.close();
    await dbB.close();
  });
}
