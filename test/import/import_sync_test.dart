// An import on one device reaches the other through the ordinary sync (the
// import writes only through FYONA's own operations), and the same file
// imported again on the second device adds nothing twice.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/import/business_import.dart';
import 'package:fyona_flutter/core/import/import_plan.dart';
import 'package:fyona_flutter/core/import/import_source.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/core_business/data/local_commerce/local_commerce_api.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../support/directory_test_keys.dart';

String _id() => const Uuid().v4();

Map<String, dynamic> _entitlement() => {
      'status': 'active', 'business_setup_completed': true,
      'sections': {'business': {'active': true, 'end_date': DateTime.now().add(const Duration(days: 2)).toIso8601String()}},
    };

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
    test('import sync', () {}, skip: 'needs the QA directory defines');
    return;
  }
  sqfliteFfiInit();

  test('imported on device A: device B gets the same cards, products and cash once; importing again adds nothing',
      () async {
    final tmp = await Directory.systemTemp.createTemp('fyona-import-sync-');
    addTearDown(() => tmp.delete(recursive: true));
    final w = DirectoryWorkspace(server: DirectoryPilotBuild.baseUrl, accountId: _id(), organizationId: _id());
    final scope = DirectoryAccess(workspace: w, branchId: _id(), readable: DirectoryPartyKind.values.toSet(),
        writable: DirectoryPartyKind.values.toSet(), financialCutover: true);
    final grant = BusinessLedgerAccess(scope, BusinessLedgerAction.values.toSet());
    final relay = _Relay();

    // The file: customers, products, a cash box.
    final parties = File('${tmp.path}/c.csv')..writeAsStringSync('الاسم,الجوال,الرصيد,العملة\nعميل أ,0501,100,SAR\nعميل ب,0502,0,\n');
    final products = File('${tmp.path}/p.csv')..writeAsStringSync('الاسم,الباركود,سعر البيع,الكمية\nقلم,6281,2.5,10\nدفتر,6282,7,4\n');
    final cash = File('${tmp.path}/a.csv')..writeAsStringSync('الحساب,الرصيد,العملة\nالصندوق,900,SAR\n');

    Future<void> importAll(Directory root, String regPath) async {
      final store = DirectoryPilotStore(root: () async => root, keys: FixtureDirectoryKeys(root));
      await store.remember(scope, _entitlement());
      final reg = await ImportRegistry.open(regPath, '');
      final inv = LocalInventoryApi(ApiClient(dio: Dio()), LocalCommerceBridge(store, () => scope, (_) => true));
      final imp = BusinessImporter(store: store, access: scope, registry: reg,
          createProduct: inv.createProduct, deleteProduct: inv.deleteProduct);
      final existing = await imp.existingNames();
      for (final (f, target) in [(parties, ImportTarget.parties), (products, ImportTarget.products), (cash, ImportTarget.accounts)]) {
        final t = (await readImportFile(f)).single;
        final r = await ImportReview.load(t, target, autoMapColumns(target, t.columns),
            defaultCurrency: 'SAR', existing: existing, enabledCurrencies: {'SAR'});
        if (r.acceptedCount == 0) continue;
        await imp.apply(r.toPreview(), fileSha: '${sha256.convert(f.readAsBytesSync())}', fileName: f.path);
      }
      await reg.close();
      await store.close();
    }

    Future<(DirectoryDatabase, String)> open(Directory root) async {
      final db = await DirectoryDatabase.open(root: root, workspace: w, keys: FixtureDirectoryKeys(root));
      final replica = await db.syncReplicaId();
      await db.syncSetAuthor(userId: w.accountId, name: 'owner');
      relay.inbox.putIfAbsent(replica, () => {});
      return (db, replica);
    }

    Future<Map<String, Object?>> facts(DirectoryDatabase db) async {
      final accounts = await db.ledger.managedBankAccounts(grant, includeBalances: true);
      final cust = await db.search(scope, DirectoryPartyKind.customer, '');
      final rows = await db.ledger.accounts(grant);
      return {
        'customers': [for (final p in cust) p.name]..sort(),
        'cash': [for (final a in accounts) if (a['bank_name'] == 'كاش') a['balance_minor']],
        'accounts': rows.length,
      };
    }

    final rootA = Directory('${tmp.path}/a')..createSync();
    final rootB = Directory('${tmp.path}/b')..createSync();
    // Both devices exist before the import (B is the owner's second phone).
    var (dbA, repA) = await open(rootA);
    var (dbB, repB) = await open(rootB);
    await dbA.close();
    await importAll(rootA, '${tmp.path}/reg-a.sqlite');
    (dbA, repA) = await open(rootA);
    for (var i = 0; i < 2; i++) {
      await relay.push(dbA, repA);
      await relay.push(dbB, repB);
      await relay.pull(dbA, repA);
      await relay.pull(dbB, repB);
    }
    final onA = await facts(dbA);
    final onB = await facts(dbB);
    expect(onA['customers'], ['عميل أ', 'عميل ب']);
    expect(onB, onA, reason: 'device B has exactly what A imported');
    expect(onB['cash'], [90000]);

    // The owner imports the same file again on device B: nothing twice.
    await dbB.close();
    await importAll(rootB, '${tmp.path}/reg-b.sqlite');
    (dbB, repB) = await open(rootB);
    for (var i = 0; i < 2; i++) {
      await relay.push(dbA, repA);
      await relay.push(dbB, repB);
      await relay.pull(dbA, repA);
      await relay.pull(dbB, repB);
    }
    expect(await facts(dbB), onA);
    expect(await facts(dbA), onA);
    await dbA.close();
    await dbB.close();
  });
}
