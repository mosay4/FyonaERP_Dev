import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_ledger_database.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_relay_config.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_relay_crypto.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_relay_store.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_relay_sync.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../support/fake_personal_relay.dart';
import '../../support/personal_ledger_test_support.dart';

const _secret = 'سر-شخصي-plaintext-4417';

/// One install of the app for the same user: its own encrypted ledger and
/// relay conversation.
final class _Replica {
  _Replica(this.name, this.db, this.transport, {int namespace = 7})
    : sync = PersonalRelaySync(
        store: PersonalRelayStore(db),
        transport: transport,
        namespace: namespace,
      );

  final String name;
  final PersonalLedgerDatabase db;
  final PersonalRelayTransport transport;
  final PersonalRelaySync sync;
  PersonalRelayStore get store => sync.store;

  static Future<_Replica> open(FakePersonalRelay relay, String name, {int namespace = 7}) async {
    final dir = Directory.systemTemp.createTempSync('personal-relay-$name-');
    final db = await PersonalLedgerDatabase.open(
      root: dir,
      owner: 'user-1',
      keys: MemoryPersonalLedgerKeys(),
    );
    return _Replica(name, db, relay.client(name), namespace: namespace);
  }

  /// One user intent: rows written (null = deleted) in one transaction,
  /// captured as one relay operation — what PersonalCacheRepository does.
  Future<void> commit(Map<(String, String), Map<String, dynamic>?> rows) async {
    final cap = PersonalRelayCapture.begin()!;
    await db.transaction((tx) async {
      for (final MapEntry(key: (type, id), value: row) in rows.entries) {
        if (row == null) {
          await cap.drop(tx, type, id);
          await tx.rawDelete(
            'DELETE FROM personal_rows WHERE entity_type = ? AND id = ?',
            [type, id],
          );
        } else {
          await cap.put(tx, type, id, row);
          await tx.rawInsert(
            'INSERT OR REPLACE INTO personal_rows (user_id, entity_type, id, data_json, updated_us, deleted, version) '
            'VALUES (7, ?, ?, ?, 0, 0, 0)',
            [type, id, jsonEncode(row)],
          );
        }
      }
      await cap.seal(tx);
    });
  }

  Future<Map<String, dynamic>?> row(String type, String id) async {
    final r = await db.rawQuery(
      'SELECT data_json FROM personal_rows WHERE entity_type = ? AND id = ? AND deleted = 0',
      [type, id],
    );
    return r.isEmpty ? null : jsonDecode(r.first['data_json'] as String) as Map<String, dynamic>;
  }

  Future<double?> balance(String id) async =>
      ((await row('personal_bank_account', id))?['balance'] as num?)?.toDouble();

  Future<void> round() async {
    await sync.push();
    await sync.receive();
    await sync.push();
  }

  Future<int> unsent() async => (await db.rawQuery(
    'SELECT COUNT(*) AS c FROM personal_relay_outbox WHERE seq IS NULL',
  )).first['c'] as int;
}

Future<void> _settle(List<_Replica> all, {int rounds = 5}) async {
  for (var i = 0; i < rounds; i++) {
    for (final r in all) {
      await r.round();
    }
  }
}

Map<String, dynamic> _bank(String name, double balance) => {
  'id': 'bank-1',
  'bank_name': name,
  'currency': 'SAR',
  'balance': balance,
};

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() {
    PersonalRelayConfig.enabled = true;
    PersonalRelaySync.snapshotWait = const Duration(minutes: 30);
    PersonalRelaySync.keyWait = const Duration(minutes: 30);
  });
  tearDown(() => PersonalRelayConfig.enabled = PersonalRelayConfig.build);

  /// A (first device, makes the key), then B and C join with snapshots.
  Future<(FakePersonalRelay, _Replica, _Replica, _Replica)> three() async {
    final relay = FakePersonalRelay();
    final a = await _Replica.open(relay, 'a');
    await a.round();
    final b = await _Replica.open(relay, 'b');
    await b.round();
    await _settle([a, b]);
    final c = await _Replica.open(relay, 'c');
    await c.round();
    await _settle([a, b, c]);
    for (final r in [a, b, c]) {
      expect(await r.store.resync(), '', reason: r.name);
      expect(await r.store.keyring(), hasLength(1), reason: r.name);
    }
    return (relay, a, b, c);
  }

  test('a commit travels as one op, applied once and in order elsewhere', () async {
    final (relay, a, b, c) = await three();
    await a.commit({('personal_bank_account', 'bank-1'): _bank('Main', 100)});
    await a.commit({
      ('personal_transaction', 'tx-1'): {'id': 'tx-1', 'amount': 20, 'tx_type': 'expense', 'note': _secret},
      ('personal_bank_account', 'bank-1'): _bank('Main', 80),
    });
    expect(await a.unsent(), 2);
    await _settle([a, b, c]);
    for (final r in [b, c]) {
      expect(await r.balance('bank-1'), 80, reason: r.name);
      expect((await r.row('personal_transaction', 'tx-1'))?['note'], _secret);
    }
    // Ack deleted every payload from the relay.
    expect(await a.unsent(), 0);
    expect(relay.head, greaterThan(0));
  });

  test('counters converge as deltas across 3 replicas; other fields: last by sequence', () async {
    final (_, a, b, c) = await three();
    await a.commit({('personal_bank_account', 'bank-1'): _bank('Main', 100)});
    await _settle([a, b, c]);
    // Offline at the same time on the three devices.
    await a.commit({('personal_bank_account', 'bank-1'): _bank('Main', 110)}); // +10
    await b.commit({('personal_bank_account', 'bank-1'): _bank('Renamed B', 70)}); // −30
    await c.commit({('personal_bank_account', 'bank-1'): _bank('Renamed C', 105)}); // +5
    // Sequence order: B, then C (C's rename is the last writer), then A.
    await b.sync.push();
    await c.sync.push();
    await a.sync.push();
    await _settle([a, b, c]);
    for (final r in [a, b, c]) {
      final row = await r.row('personal_bank_account', 'bank-1');
      expect(row?['balance'], 85, reason: r.name);
      expect(row?['bank_name'], 'Renamed C', reason: r.name);
    }
  });

  test('a delete is a tombstone that wins over later updates', () async {
    final (_, a, b, c) = await three();
    await a.commit({('personal_savings_goal', 'g1'): {'id': 'g1', 'name': 'Car', 'current_amount': 10, 'target_amount': 100}});
    await _settle([a, b, c]);
    await a.commit({('personal_savings_goal', 'g1'): null});
    await b.commit({('personal_savings_goal', 'g1'): {'id': 'g1', 'name': 'Car 2', 'current_amount': 60, 'target_amount': 100}});
    await a.sync.push();
    await b.sync.push(); // B's update is sequenced AFTER the delete
    await _settle([a, b, c]);
    for (final r in [a, b, c]) {
      expect(await r.row('personal_savings_goal', 'g1'), isNull, reason: r.name);
    }
    final clock = await c.db.rawQuery(
      "SELECT deleted FROM personal_relay_rows WHERE entity_type = 'personal_savings_goal' AND id = 'g1'",
    );
    expect(clock.single['deleted'], 1);
  });

  test('duplicate op ids are applied once; a retried push keeps its sequence', () async {
    final (relay, a, b, _) = await three();
    await a.commit({('personal_bank_account', 'bank-1'): _bank('Main', 100)});
    await _settle([a, b]);
    await a.commit({('personal_bank_account', 'bank-1'): _bank('Main', 150)});
    final op = (await a.store.unsent()).single;
    final payload = jsonDecode(op.payload) as Map<String, dynamic>;
    expect(await b.store.applyOp(opId: op.id, seq: 999, payload: payload, namespace: 7), isTrue);
    expect(await b.store.applyOp(opId: op.id, seq: 999, payload: payload, namespace: 7), isFalse);
    expect(await b.balance('bank-1'), 150);
    // Push twice (lost reply): the relay returns the same sequence.
    final first = relay.handle('/push', {
      'replica_id': await a.store.replicaId(),
      'items': [{'id': op.id, 'kind': 'ops', 'payload': base64Encode([1, 2, 3])}],
    });
    final again = relay.handle('/push', {
      'replica_id': await a.store.replicaId(),
      'items': [{'id': op.id, 'kind': 'ops', 'payload': base64Encode([1, 2, 3])}],
    });
    expect((again['items'] as List).single['seq'], (first['items'] as List).single['seq']);
  });

  test('new device: key granted device-to-device, snapshot applied, later ops not applied twice', () async {
    final relay = FakePersonalRelay();
    final a = await _Replica.open(relay, 'a');
    await a.round();
    await a.commit({
      ('personal_bank_account', 'bank-1'): _bank('Main', 100),
      ('personal_category', 'cat-1'): {'id': 'cat-1', 'name': 'Food', 'name_ar': 'طعام'},
    });
    await a.sync.push();
    // The new phone registers (resync), asks for the key and a copy.
    final d = await _Replica.open(relay, 'd', namespace: 3);
    await d.sync.ready();
    expect(await d.store.resync(), 'waiting');
    expect(await d.store.keyring(), isEmpty);
    // Meanwhile A keeps working: this op reaches D's inbox AND the snapshot.
    await a.commit({('personal_bank_account', 'bank-1'): _bank('Main', 130)});
    await a.sync.push();
    await a.round(); // grants the key, serves the snapshot
    await d.round();
    await _settle([a, d]);
    expect(await d.store.resync(), '');
    expect(await d.store.keyring(), await a.store.keyring());
    expect(await d.balance('bank-1'), 130); // not 160: the op was in the copy
    expect((await d.row('personal_category', 'cat-1'))?['name_ar'], 'طعام');
    // New rows land in D's own namespace.
    final ns = await d.db.rawQuery("SELECT user_id FROM personal_rows WHERE id = 'bank-1'");
    expect(ns.single['user_id'], 3);
    // And D now follows the log.
    await a.commit({('personal_bank_account', 'bank-1'): _bank('Main', 135)});
    await _settle([a, d]);
    expect(await d.balance('bank-1'), 135);
  });

  test('a device that already had data merges: its own rows reach the others', () async {
    final relay = FakePersonalRelay();
    final a = await _Replica.open(relay, 'a');
    await a.round();
    await a.commit({('personal_bank_account', 'bank-1'): _bank('Main', 100)});
    await a.sync.push();
    final b = await _Replica.open(relay, 'b');
    // B has rows from before it joined (made offline).
    await b.commit({('personal_debt', 'debt-b'): {'id': 'debt-b', 'person_name': 'Ali', 'amount': 50, 'paid': 0}});
    await _settle([a, b]);
    expect(await b.balance('bank-1'), 100);
    expect((await a.row('personal_debt', 'debt-b'))?['person_name'], 'Ali');
  });

  test('resync after the relay dropped what waited (retention): a fresh copy', () async {
    final (relay, a, b, _) = await three();
    await a.commit({('personal_bank_account', 'bank-1'): _bank('Main', 100)});
    await _settle([a, b]);
    await a.commit({('personal_bank_account', 'bank-1'): _bank('Main', 40)});
    await a.sync.push();
    relay.expire(await b.store.replicaId()); // B missed it for good
    await b.round();
    expect(await b.store.resync(), 'waiting');
    await _settle([a, b]);
    expect(await b.store.resync(), '');
    expect(await b.balance('bank-1'), 40);
  });

  test('no other device answers: the new device goes on with its own data', () async {
    final relay = FakePersonalRelay();
    final a = await _Replica.open(relay, 'a');
    await a.round(); // then this phone is lost (never comes back)
    final d = await _Replica.open(relay, 'd');
    await d.commit({('personal_bank_account', 'bank-d'): {'id': 'bank-d', 'balance': 5}});
    await d.round();
    expect(await d.store.resync(), 'waiting');
    PersonalRelaySync.snapshotWait = Duration.zero;
    PersonalRelaySync.keyWait = Duration.zero;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await d.round();
    await d.round();
    expect(await d.store.resync(), 'gave_up');
    expect(await d.store.keyring(), hasLength(1)); // made its own key
    expect(await d.balance('bank-d'), 5); // local data kept
    expect(await d.unsent(), 0); // and sent
  });

  test('offline: writes wait in the outbox; online again: delivered', () async {
    final (_, a, b, _) = await three();
    a.transport.online = false;
    await a.commit({('personal_bank_account', 'bank-1'): _bank('Main', 100)});
    await expectLater(a.sync.push(), throwsA(isA<StateError>()));
    expect(await a.unsent(), 1);
    a.transport.online = true;
    await _settle([a, b]);
    expect(await a.unsent(), 0);
    expect(await b.balance('bank-1'), 100);
  });

  test('the relay only ever stores ciphertext and public keys', () async {
    final (relay, a, b, _) = await three();
    await a.commit({('personal_transaction', 'tx-s'): {'id': 'tx-s', 'description': _secret, 'amount': 1}});
    await _settle([a, b]);
    expect((await b.row('personal_transaction', 'tx-s'))?['description'], _secret);
    final needle = utf8.encode(_secret);
    bool contains(List<int> hay) {
      for (var i = 0; i + needle.length <= hay.length; i++) {
        var ok = true;
        for (var j = 0; j < needle.length && ok; j++) {
          ok = hay[i + j] == needle[j];
        }
        if (ok) return true;
      }
      return false;
    }

    expect(relay.stored.any(contains), isFalse);
    // Data keys never cross in clear either.
    for (final key in (await a.store.keyring()).values) {
      expect(relay.stored.any((s) => utf8.decode(s, allowMalformed: true).contains(base64Encode(key))), isFalse);
    }
    // Sealed for one op id: moved to another id it does not open.
    final sealed = relay.stored.firstWhere(PersonalRelayCrypto.isEnvelope);
    await expectLater(
      PersonalRelayCrypto.open(bytes: sealed, keyring: await a.store.keyring(), context: 'op:other'),
      throwsA(anything),
    );
  });

  test('account types, financial trees and rates ride the relay', () async {
    final (_, a, b, _) = await three();
    Future<void> chooseType(_Replica r, String type, int at) async {
      final cap = PersonalRelayCapture.begin()!;
      await r.db.transaction((tx) async {
        // What PersonalAccountTypeStore.save writes, plus its relay change.
        for (final (k, v) in [
          ('bank_account_types_v3', jsonEncode({'bank-1': type})),
          ('bank_account_types_v3_at', jsonEncode({'bank-1': at})),
        ]) {
          await tx.rawInsert(
            "INSERT OR REPLACE INTO personal_kv (key, type, value, updated_us) VALUES (?, 'string', ?, 0)",
            [k, v],
          );
        }
        cap.accountType('bank-1', type, at);
        await cap.seal(tx);
      });
    }

    Future<Object?> typesOf(_Replica r) async => jsonDecode(
      (await r.db.rawQuery(
        "SELECT value FROM personal_kv WHERE key = 'bank_account_types_v3'",
      )).single['value'] as String,
    );

    await chooseType(a, 'savings', 500);
    final capA = PersonalRelayCapture.begin()!;
    await a.db.transaction((tx) async {
      capA.kv('financial_trees_v1', type: 'string', value: '[{"id":"t1"}]');
      capA.kv('bank_account_types_relay_pending', type: 'bool', value: 'true');
      capA.rate('USD', 'SAR', 3.75);
      await capA.seal(tx);
    });
    await _settle([a, b]);
    final kv = {
      for (final r in await b.db.rawQuery('SELECT key, value FROM personal_kv'))
        r['key']: r['value'],
    };
    expect(await typesOf(b), {'bank-1': 'savings'});
    expect(kv['financial_trees_v1'], '[{"id":"t1"}]');
    // Device flags never travel.
    expect(kv.containsKey('bank_account_types_relay_pending'), isFalse);
    final rates = await b.db.rawQuery(
      'SELECT rate FROM personal_exchange_rates WHERE from_currency = ?',
      ['USD'],
    );
    expect(rates.single['rate'], 3.75);
    // A later choice on B wins on A; an older one never overrides it.
    await chooseType(b, 'checking', 900);
    await _settle([a, b]);
    expect(await typesOf(a), {'bank-1': 'checking'});
    expect(
      await a.store.applyOp(
        opId: 'old-op',
        seq: 10000,
        payload: {
          'c': [
            {'t': '_acct', 'id': 'bank-1', 'k': 'u', 'data': {'t': 'savings', 'at': 100}},
          ],
        },
        namespace: 7,
      ),
      isTrue,
    );
    expect(await typesOf(a), {'bank-1': 'checking'});
  });

  test('concurrent edits of different fields both survive', () async {
    final (_, a, b, c) = await three();
    await a.commit({('personal_debt', 'd1'): {'id': 'd1', 'person_name': 'Ali', 'description': '', 'amount': 100, 'paid': 0}});
    await _settle([a, b, c]);
    await a.commit({('personal_debt', 'd1'): {'id': 'd1', 'person_name': 'Ali Hassan', 'description': '', 'amount': 100, 'paid': 0}});
    await c.commit({('personal_debt', 'd1'): {'id': 'd1', 'person_name': 'Ali', 'description': 'rent', 'amount': 100, 'paid': 40}});
    await c.sync.push();
    await a.sync.push();
    await _settle([a, b, c]);
    for (final r in [a, b, c]) {
      final row = await r.row('personal_debt', 'd1');
      expect(row?['person_name'], 'Ali Hassan', reason: r.name);
      expect(row?['description'], 'rent', reason: r.name);
      expect(row?['paid'], 40, reason: r.name);
      expect(row?['remaining'], 60, reason: r.name);
    }
  });

  test('a ledger from the previous version gets the relay tables on open', () async {
    final dir = Directory.systemTemp.createTempSync('personal-relay-upgrade-');
    final keys = MemoryPersonalLedgerKeys();
    var db = await PersonalLedgerDatabase.open(root: dir, owner: 'u', keys: keys);
    for (final t in ['personal_relay_outbox', 'personal_relay_rows', 'personal_relay_parked']) {
      await db.rawExecutor.execute('DROP TABLE $t');
    }
    await db.rawExecutor.execute('PRAGMA user_version = 1');
    await db.close();
    db = await PersonalLedgerDatabase.open(root: dir, owner: 'u', keys: keys);
    final tables = {
      for (final r in await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'")) r['name'],
    };
    expect(tables, containsAll(['personal_relay_outbox', 'personal_relay_rows', 'personal_relay_parked']));
    await db.close();
  });
}
