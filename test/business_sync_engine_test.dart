import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_party.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();
const _customer = DirectoryPartyKind.customer;

/// The server, as the devices see it: sequence on arrival, one inbox per
/// device, delete once every device stored it. Mirrors business_relay.py.
final class _Relay {
  int head = 0;
  final ops = <String, ({int seq, String from, Map<String, Object?> payload, String? branch})>{};
  final inbox = <String, Set<String>>{};

  void register(String replica) => inbox.putIfAbsent(replica, () => {});

  Future<void> push(_Device d) async {
    final out = await d.db.syncOutbox();
    final sequenced = <String, int>{};
    for (final op in out) {
      final seen = ops[op.id];
      final seq = seen?.seq ?? ++head;
      if (seen == null) {
        ops[op.id] = (seq: seq, from: d.replica, payload: op.payload, branch: op.branchId);
        for (final other in inbox.keys) {
          if (other != d.replica) inbox[other]!.add(op.id);
        }
      }
      sequenced[op.id] = seq;
    }
    await d.db.syncPushed(sequenced);
  }

  Future<void> pull(_Device d) async {
    final ids = inbox[d.replica]!.toList()
      ..sort((a, b) => ops[a]!.seq.compareTo(ops[b]!.seq));
    final stored = await d.db.syncApply([
      for (final id in ids)
        (
          id: id,
          seq: ops[id]!.seq,
          kind: 'ops',
          branchId: ops[id]!.branch,
          payload: ops[id]!.payload,
        ),
    ], drained: true, head: head);
    for (final id in stored) {
      inbox[d.replica]!.remove(id);
      if (!inbox.values.any((box) => box.contains(id))) ops.remove(id);
    }
  }

  Future<void> sync(List<_Device> devices) async {
    for (final d in devices) {
      await push(d);
    }
    for (final d in devices) {
      await pull(d);
    }
  }
}

final class _Device {
  _Device(this.db, this.replica, this.access, this.directory);
  final DirectoryDatabase db;
  final String replica;
  final BusinessLedgerAccess access;
  final DirectoryAccess directory;
  BusinessLedger get ledger => db.ledger;

  Future<int> balance(String account) async => (await ledger.accounts(access))
      .singleWhere((row) => row['id'] == account)['balance_minor'] as int;
}

void main() {
  final workspace = DirectoryWorkspace(
    server: 'http://localhost:18083/api/v1',
    accountId: _id(),
    organizationId: _id(),
  );
  final branch = _id();
  final roots = <Directory>[];
  final devices = <_Device>[];
  late _Relay relay;

  Future<_Device> device(String name) async {
    final root = await Directory.systemTemp.createTemp('fyona-sync-');
    roots.add(root);
    final db = await DirectoryDatabase.open(
      root: root,
      workspace: workspace,
      keys: FixtureDirectoryKeys(),
    );
    final replica = await db.syncReplicaId();
    await db.syncSetAuthor(userId: workspace.accountId, name: name);
    relay.register(replica);
    final directory = DirectoryAccess(
      workspace: workspace,
      branchId: branch,
      readable: {_customer, DirectoryPartyKind.supplier},
      writable: {_customer, DirectoryPartyKind.supplier},
    );
    final d = _Device(
      db,
      replica,
      BusinessLedgerAccess(directory, BusinessLedgerAction.values.toSet()),
      directory,
    );
    devices.add(d);
    return d;
  }

  setUp(() => relay = _Relay());

  tearDown(() async {
    for (final d in devices) {
      await d.db.close();
    }
    devices.clear();
    for (final root in roots) {
      await root.delete(recursive: true);
    }
    roots.clear();
  });

  Future<String> openAccount(_Device d, {int opening = 0}) async {
    final id = _id();
    await d.ledger.createAccount(
      d.access,
      commandId: id,
      bankName: 'الصندوق',
      accountName: 'كاش',
      accountNumber: '1',
      currency: 'SAR',
      openingMinor: opening,
    );
    return id;
  }

  test('what one device records appears on the other, exactly once', () async {
    final a = await device('أحمد');
    final b = await device('سالم');
    final till = await openAccount(a, opening: 50000);
    final customer = await a.db.create(a.directory, _customer, name: 'عميل');
    final debt = _id();
    await a.ledger.recordOpeningDebt(
      a.access,
      DirectoryPartyReference(scope: a.directory, kind: _customer, id: customer.id),
      commandId: debt,
      amountMinor: 10000,
      currency: 'SAR',
    );
    await relay.sync([a, b]);
    // Syncing again changes nothing (no duplicates).
    await relay.sync([a, b]);

    expect(await b.balance(till), 50000);
    final parties = await b.db.search(b.directory, _customer, '');
    expect(parties.map((p) => p.name), ['عميل']);
    // Every device stored everything: nothing is left on the relay.
    expect(relay.ops, isEmpty);
  });

  test('the same remaining debt collected on two devices offline: the first '
      'to reach the server wins, the other is cancelled with a notice', () async {
    final a = await device('أحمد');
    final b = await device('سالم');
    final tillA = await openAccount(a);
    final customer = await a.db.create(a.directory, _customer, name: 'عميل');
    final ref = DirectoryPartyReference(scope: a.directory, kind: _customer, id: customer.id);
    final debt = _id();
    await a.ledger.recordOpeningDebt(a.access, ref, commandId: debt, amountMinor: 10000, currency: 'SAR');
    await relay.sync([a, b]);

    // Both offline: each collects the full 100 SAR into the same till.
    await a.ledger.settle(a.access, ref, commandId: _id(), accountId: tillA, amountMinor: 10000, currency: 'SAR', invoiceId: debt);
    await b.ledger.settle(
      b.access,
      DirectoryPartyReference(scope: b.directory, kind: _customer, id: customer.id),
      commandId: _id(), accountId: tillA, amountMinor: 10000, currency: 'SAR', invoiceId: debt,
    );
    // Locally both succeeded, as if online.
    expect(await a.balance(tillA), 10000);
    expect(await b.balance(tillA), 10000);

    // Salem's device reaches the internet first.
    await relay.push(b);
    await relay.push(a);
    await relay.pull(a);
    await relay.pull(b);

    for (final d in [a, b]) {
      // One collection only, on every device.
      expect(await d.balance(tillA), 10000, reason: 'till on ${d.replica}');
    }
    // Ahmad is told his collection was cancelled because Salem did it first.
    final notices = await a.db.syncNotices();
    expect(notices, hasLength(1));
    expect(notices.single.kind, 'debtOverpaid');
    expect(notices.single.details['by_name'], 'سالم');
    expect(await b.db.syncNotices(), isEmpty);
  });

  test('two collections that both fit are both kept (not a conflict)', () async {
    final a = await device('أحمد');
    final b = await device('سالم');
    final till = await openAccount(a);
    final customer = await a.db.create(a.directory, _customer, name: 'عميل');
    final ref = DirectoryPartyReference(scope: a.directory, kind: _customer, id: customer.id);
    final debt = _id();
    await a.ledger.recordOpeningDebt(a.access, ref, commandId: debt, amountMinor: 10000, currency: 'SAR');
    await relay.sync([a, b]);
    await a.ledger.settle(a.access, ref, commandId: _id(), accountId: till, amountMinor: 3000, currency: 'SAR', invoiceId: debt);
    await b.ledger.settle(
      b.access,
      DirectoryPartyReference(scope: b.directory, kind: _customer, id: customer.id),
      commandId: _id(), accountId: till, amountMinor: 4000, currency: 'SAR', invoiceId: debt,
    );
    await relay.sync([a, b]);
    await relay.sync([a, b]);
    for (final d in [a, b]) {
      expect(await d.balance(till), 7000);
    }
    expect(await a.db.syncNotices(), isEmpty);
    expect(await b.db.syncNotices(), isEmpty);
  });

  test('a new device receives everything through a snapshot', () async {
    final a = await device('أحمد');
    final till = await openAccount(a, opening: 2500);
    await a.db.create(a.directory, _customer, name: 'قديم');
    await relay.sync([a]);
    final c = await device('جهاز جديد');
    final snapshot = await a.db.syncSnapshot();
    expect(snapshot, isNotNull);
    await c.db.syncApplySnapshot(snapshot!);
    expect(await c.balance(till), 2500);
    expect((await c.db.search(c.directory, _customer, '')).map((p) => p.name), ['قديم']);
    // Later work keeps flowing normally.
    await c.db.create(c.directory, _customer, name: 'جديد');
    await relay.sync([a, c]);
    expect(
      (await a.db.search(a.directory, _customer, '')).map((p) => p.name).toSet(),
      {'قديم', 'جديد'},
    );
  });
}
