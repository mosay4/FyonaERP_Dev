import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_ledger_database.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_local_cutover.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_relay_config.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../support/personal_ledger_test_support.dart';

const _user = 'user-1';

/// In-memory `/personal-local`: the same export bytes on every call, the
/// first ack starts the grace period.
final class _FakeServer implements PersonalLocalTransport {
  _FakeServer(this.entities, {this.user = _user});

  final Map<String, List<Map<String, dynamic>>> entities;
  final String user;
  bool online = true;
  bool purged = false;
  bool tamper = false;
  final calls = <String>[];
  final acks = <Map<String, Object?>>[];
  List<int>? _body;

  List<int> get body => _body ??= utf8.encode(jsonEncode({
        'format': 'fyona-personal-baseline',
        'v': 1,
        'snapshot_id': 'snap-1',
        'user_id': user,
        'entities': entities,
        'counts': {for (final e in entities.entries) e.key: e.value.length},
        'balances': {
          for (final a in entities['personal_bank_account'] ?? const [])
            a['id']: a['balance'],
        },
      }));

  String get digest => sha256.convert(body).toString();

  @override
  Future<Map<String, dynamic>> get(String path) async {
    if (!online) throw const PersonalLocalHttpError(null, 'offline');
    calls.add('GET $path');
    return {
      'local': true,
      'needed': acks.isEmpty && !purged,
      'imported': acks.isNotEmpty,
      'rows': purged ? 0 : entities.values.fold<int>(0, (a, l) => a + l.length),
      'purged': purged,
    };
  }

  @override
  Future<Map<String, dynamic>> post(String path, Map<String, Object?> b) async {
    if (!online) throw const PersonalLocalHttpError(null, 'offline');
    calls.add('POST $path');
    if (path == '/export') {
      if (purged) throw const PersonalLocalHttpError(410, 'purged');
      return {
        'snapshot_id': 'snap-1',
        'digest': tamper ? '0' * 64 : digest,
        'body': base64Encode(body),
      };
    }
    if (path == '/ack') {
      if (b['digest'] != digest) throw const PersonalLocalHttpError(409, 'No matching export');
      acks.add(b);
      return {'imported_at': 'now', 'purge_after': 'later'};
    }
    throw StateError(path);
  }
}

final class _NotLocalServer implements PersonalLocalTransport {
  @override
  Future<Map<String, dynamic>> get(String path) async =>
      throw const PersonalLocalHttpError(404, 'غير متاح');

  @override
  Future<Map<String, dynamic>> post(String path, Map<String, Object?> body) async =>
      throw const PersonalLocalHttpError(404, 'غير متاح');
}

Map<String, List<Map<String, dynamic>>> _baseline() => {
      'personal_bank_account': [
        {'id': 'acct-1', 'bank_name': 'الراجحي', 'currency': 'SAR', 'balance': 1500.25},
        {'id': 'acct-2', 'bank_name': 'كاش', 'currency': 'USD', 'balance': 20.0},
        {'id': 'acct-gone', 'bank_name': 'قديم', 'currency': 'SAR', 'balance': 5.0},
      ],
      'personal_budget': [
        {
          'id': 'bud-1', 'name': 'شهري', 'total_amount': 1000.0, 'spent': 50.0,
          'categories': [
            {'id': 'cat-1', 'budget_id': 'bud-1', 'name': 'طعام', 'spent_amount': 50.0},
          ],
        },
      ],
      'personal_budget_category': [
        {'id': 'cat-1', 'budget_id': 'bud-1', 'name': 'طعام', 'spent_amount': 50.0},
      ],
      'personal_savings_goal': [],
      'personal_debt': [
        {'id': 'debt-1', 'person_name': 'أحمد', 'amount': 300.0, 'paid': 100.0},
      ],
      'personal_debt_payment': [
        {'id': 'pay-1', 'debt_id': 'debt-1', 'amount': 100.0},
      ],
      'personal_recurring_transaction': [],
      'personal_transaction': [
        {'id': 'tx-1', 'tx_type': 'expense', 'amount': 50.0, 'bank_account_id': 'acct-1'},
      ],
    };

void main() {
  late PersonalLedgerDatabase db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    PersonalRelayConfig.enabled = true;
    PersonalLocalMode.debugReset();
    PersonalLocalCutover.debugStep = null;
    final dir = Directory.systemTemp.createTempSync('personal-local-cutover-');
    db = await PersonalLedgerDatabase.open(
      root: dir,
      owner: _user,
      keys: MemoryPersonalLedgerKeys(),
    );
  });
  tearDown(() async {
    PersonalRelayConfig.enabled = PersonalRelayConfig.build;
    PersonalLocalCutover.debugStep = null;
    PersonalLocalMode.debugReset();
    await db.close();
  });

  Future<Map<String, dynamic>?> row(String type, String id) async {
    final r = await db.rawQuery(
      'SELECT data_json FROM personal_rows WHERE entity_type = ? AND id = ? AND deleted = 0',
      [type, id],
    );
    return r.isEmpty ? null : jsonDecode(r.first['data_json'] as String) as Map<String, dynamic>;
  }

  Future<int> count(String table) async =>
      (await db.rawQuery('SELECT COUNT(*) AS c FROM $table')).first['c'] as int;

  Future<void> putRow(String type, String id, Map<String, dynamic> data) => db.rawInsert(
        'INSERT INTO personal_rows (user_id, entity_type, id, data_json, updated_us, deleted, version) '
        'VALUES (7, ?, ?, ?, 0, 0, 0)',
        [type, id, jsonEncode(data)],
      );

  PersonalLocalCutover cutover(
    _FakeServer server, {
    Future<void> Function()? drain,
    Future<bool> Function()? relayIdle,
  }) =>
      PersonalLocalCutover(
        db: db,
        transport: server,
        namespace: 7,
        drain: drain,
        relayIdle: relayIdle,
      );

  test('imports the baseline once (upsert by id): adds what is missing, takes the '
      'server values over plain server copies, keeps rows changed here and deleted rows, '
      'verifies, acknowledges and retires the old sync', () async {
    final server = _FakeServer(_baseline());
    // Changed here through the relay (an expense after the server copy).
    await putRow('personal_bank_account', 'acct-1',
        {'id': 'acct-1', 'bank_name': 'الراجحي', 'currency': 'SAR', 'balance': 1400.25});
    await db.rawInsert(
      "INSERT INTO personal_relay_rows (entity_type, id, last_seq, deleted) VALUES ('personal_bank_account', 'acct-1', 3, 0)",
    );
    // A stale copy of the server row (old sync pull, no history here).
    await putRow('personal_bank_account', 'acct-2', {
      'id': 'acct-2', 'bank_name': 'كاش', 'currency': 'USD', 'balance': 7.0,
      '_sync_version': 4,
    });
    // An old write never sent: newer here, kept.
    await putRow('personal_transaction', 'tx-1',
        {'id': 'tx-1', 'tx_type': 'expense', 'amount': 55.0, 'bank_account_id': 'acct-1'});
    await db.rawInsert(
      'INSERT INTO personal_outbox (operation_id, table_name, entity_type, entity_id, operation, data, status, created_at, user_id) '
      "VALUES ('op-unsent', 'personal_transaction', 'personal_transaction', 'tx-1', 'UPDATE', '{}', 'failed', ?, 7)",
      [DateTime.now().toUtc().toIso8601String()],
    );
    // Deleted here (relay tombstone): must not come back.
    await db.rawInsert(
      "INSERT INTO personal_relay_rows (entity_type, id, deleted) VALUES ('personal_bank_account', 'acct-gone', 1)",
    );
    var drained = 0;
    expect(await cutover(server, drain: () async => drained++).run(), isTrue);

    expect(drained, 1);
    expect((await row('personal_bank_account', 'acct-1'))!['balance'], 1400.25);
    final acct2 = (await row('personal_bank_account', 'acct-2'))!;
    expect(acct2['balance'], 20.0); // the server's value
    expect(acct2['_sync_version'], 4); // device-local metadata kept
    expect((await row('personal_transaction', 'tx-1'))!['amount'], 55.0);
    expect(await row('personal_bank_account', 'acct-gone'), isNull);
    expect((await row('personal_budget', 'bud-1'))!['categories'], hasLength(1));
    expect(await row('personal_budget_category', 'cat-1'), isNull); // inside its budget
    expect(await row('personal_debt_payment', 'pay-1'), isNotNull);
    // The baseline is not a relay operation (every device imports the
    // export itself); only the unsent old write travels, as it is here.
    final ops = await db.rawQuery('SELECT payload FROM personal_relay_outbox');
    final changes = [
      for (final o in ops)
        for (final c in (jsonDecode(o['payload'] as String) as Map)['c'] as List) c as Map,
    ];
    expect(changes.map((c) => '${c['t']}/${c['id']}'), ['personal_transaction/tx-1']);
    expect(changes.single['data']['amount'], 55.0);
    expect(server.acks, [
      {'snapshot_id': 'snap-1', 'digest': server.digest},
    ]);
    expect(PersonalLocalMode.oldSyncRetired, isTrue);
    final st = await cutover(server).state();
    expect(st['state'], 'done');
    expect(st['added'], isNot(contains('personal_bank_account')));
    expect(st['replaced'], containsPair('personal_bank_account', 1));
    expect(st['kept'], containsPair('personal_bank_account', 2));
    expect(st['kept'], containsPair('personal_transaction', 1));

    // Idempotent: nothing more is fetched or confirmed.
    server.calls.clear();
    expect(await cutover(server).run(), isTrue);
    expect(server.calls, isEmpty);
    expect(server.acks, hasLength(1));
  });

  test('resumes after a crash at any step with the same result', () async {
    final server = _FakeServer(_baseline());
    for (final crashAt in ['drained', 'imported', 'acked']) {
      PersonalLocalCutover.debugStep = (step) async {
        if (step == crashAt) throw StateError('crash at $step');
      };
      expect(await cutover(server).run(), isFalse, reason: crashAt);
    }
    PersonalLocalCutover.debugStep = null;
    expect(await cutover(server).run(), isTrue);
    expect(await count('personal_rows'), 7);
    // The import is one transaction: a re-run adds nothing twice.
    expect((await row('personal_bank_account', 'acct-1'))!['balance'], 1500.25);
    expect(server.acks.map((a) => a['digest']).toSet(), {server.digest});
    expect(await cutover(server).isDone(), isTrue);
  });

  test('a wrong digest imports nothing, confirms nothing, and a calm notice '
      'appears only after repeated failures', () async {
    final server = _FakeServer(_baseline())..tamper = true;
    for (var i = 0; i < PersonalLocalCutover.noticeAfterFailures - 1; i++) {
      expect(await cutover(server).run(), isFalse);
      expect(PersonalLocalMode.notice.value, isNull);
    }
    expect(await cutover(server).run(), isFalse);
    expect(PersonalLocalMode.notice.value, PersonalLocalNotice.cutoverFailing);
    expect(await count('personal_rows'), 0);
    expect(server.acks, isEmpty);
    expect(PersonalLocalMode.oldSyncRetired, isFalse);

    server.tamper = false;
    expect(await cutover(server).run(), isTrue);
    expect(PersonalLocalMode.notice.value, isNull);
    expect(await count('personal_rows'), 7);
  });

  test('the import waits until the relay inbox is drained (no failure counted)', () async {
    final server = _FakeServer(_baseline());
    var idle = false;
    expect(await cutover(server, relayIdle: () async => idle).run(), isFalse);
    expect(await count('personal_rows'), 0);
    expect(server.acks, isEmpty);
    final st = await cutover(server).state();
    expect(st['state'], 'export');
    expect(st['failures'], isNull);
    expect(PersonalLocalMode.notice.value, isNull);
    idle = true;
    expect(await cutover(server, relayIdle: () async => idle).run(), isTrue);
    expect(await count('personal_rows'), 7);
    expect(server.acks, hasLength(1));
  });

  test('a server without device-only Personal (404) keeps the old sync on', () async {
    final server = _NotLocalServer();
    expect(PersonalLocalMode.active, isTrue);
    expect(await cutover(_FakeServer(const {})).isDone(), isFalse);
    expect(
      await PersonalLocalCutover(db: db, transport: server, namespace: 7).run(),
      isFalse,
    );
    expect(PersonalLocalMode.serverDeclined, isTrue);
    expect(PersonalLocalMode.active, isFalse);
    expect(PersonalLocalMode.oldSyncRetired, isFalse);
  });

  test('a done cutover still clears what was queued in the old outbox meanwhile', () async {
    final server = _FakeServer(_baseline());
    expect(await cutover(server).run(), isTrue);
    await db.rawInsert(
      'INSERT INTO personal_relay_outbox (op_id, payload, created_us) VALUES (?, ?, ?)',
      ['relay-op', '{"v":1,"c":[]}', DateTime.utc(2026, 11, 1).microsecondsSinceEpoch],
    );
    await db.rawInsert(
      'INSERT INTO personal_outbox (operation_id, table_name, entity_type, entity_id, operation, data, status, created_at, user_id) '
      "VALUES ('op-late', 'personal_transaction', 'personal_transaction', 'tx-1', 'UPDATE', '{}', 'pending', ?, 7)",
      [DateTime.utc(2026, 11, 20).toIso8601String()],
    );
    PersonalLocalMode.debugReset();
    expect(await cutover(server).run(), isTrue);
    expect(PersonalLocalMode.oldSyncRetired, isTrue);
    expect(await count('personal_outbox'), 0);
    // Written after the relay existed: it already travelled as a relay op.
    expect(await count('personal_relay_outbox'), 1);
  });

  test('a baseline of another user is refused', () async {
    final server = _FakeServer(_baseline(), user: 'someone-else');
    expect(await cutover(server).run(), isFalse);
    expect(await count('personal_rows'), 0);
    expect(server.acks, isEmpty);
  });

  test('offline: nothing happens, no failure is counted, it retries later', () async {
    final server = _FakeServer(_baseline())..online = false;
    expect(await cutover(server).run(), isFalse);
    expect((await cutover(server).state())['failures'], isNull);
    server.online = true;
    expect(await cutover(server).run(), isTrue);
  });

  test('already purged on the server: done without an import', () async {
    final server = _FakeServer(_baseline())..purged = true;
    expect(await cutover(server).run(), isTrue);
    expect(await count('personal_rows'), 0);
    expect(server.calls, isNot(contains('POST /export')));
  });

  test('old outbox rows written before the relay existed become relay operations; '
      'the old outbox is emptied', () async {
    Future<void> queue(String type, String id, String op, DateTime at) => db.rawInsert(
          'INSERT INTO personal_outbox (operation_id, table_name, entity_type, entity_id, operation, data, status, created_at, user_id) '
          "VALUES (?, ?, ?, ?, ?, '{}', 'pending', ?, 7)",
          ['op-$id-$op', type, type, id, op, at.toUtc().toIso8601String()],
        );
    final relayStart = DateTime.utc(2026, 11, 1);
    await db.rawInsert(
      'INSERT INTO personal_relay_outbox (op_id, payload, created_us, seq) VALUES (?, ?, ?, 1)',
      ['first-relay-op', '{"v":1,"c":[]}', relayStart.microsecondsSinceEpoch],
    );
    await putRow('personal_transaction', 'tx-old', {'id': 'tx-old', 'amount': 12.5});
    await putRow('personal_transaction', 'tx-new', {'id': 'tx-new', 'amount': 3.0});
    await queue('personal_transaction', 'tx-old', 'INSERT', DateTime.utc(2026, 10, 30));
    await queue('personal_debt', 'debt-x', 'DELETE', DateTime.utc(2026, 10, 30));
    await queue('personal_transaction', 'tx-new', 'INSERT', DateTime.utc(2026, 11, 5));

    expect(await PersonalLocalCutover.convertOutbox(db), 2);
    expect(await count('personal_outbox'), 0);
    final ops = await db.rawQuery(
      "SELECT payload FROM personal_relay_outbox WHERE op_id != 'first-relay-op'",
    );
    final changes = [
      for (final o in ops)
        for (final c in (jsonDecode(o['payload'] as String) as Map)['c'] as List) c as Map,
    ];
    expect(changes.map((c) => '${c['t']}/${c['id']}/${c['k']}').toSet(),
        {'personal_transaction/tx-old/i', 'personal_debt/debt-x/d'});
    expect(changes.firstWhere((c) => c['id'] == 'tx-old')['data'], {'id': 'tx-old', 'amount': 12.5});
  });

  test('the device-only guard refusal is recognised', () {
    expect(PersonalLocalMode.refusalCode({'code': 'personal_local'}), 'personal_local');
    expect(PersonalLocalMode.refusalCode({'code': 'update_required'}), 'update_required');
    expect(PersonalLocalMode.refusalCode({'detail': 'x'}), isNull);
    expect(PersonalLocalMode.refusalCode('x'), isNull);
  });
}
