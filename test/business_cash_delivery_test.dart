import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_cash_delivery.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

final class _Replica {
  _Replica(this.scope, this.sessionId, this.root, this.keys)
    : store = DirectoryPilotStore(root: () async => root, keys: keys),
      active = scope;

  final DirectoryAccess scope;
  final String sessionId;
  final Directory root;
  final FixtureDirectoryKeys keys;
  final DirectoryPilotStore store;
  DirectoryAccess? active;
  late final access = BusinessLedgerAccess(
    scope,
    BusinessLedgerAction.values.toSet(),
    cashSessionId: sessionId,
  );

  Future<T> ledger<T>(Future<T> Function(BusinessLedger) fn) =>
      store.withLedger(access, () => active, fn);

  Future<void> prepare(
    String account,
    BusinessCashCheckpoint checkpoint, {
    int balance = 10000,
    String? secondAccount,
    bool settlementProtocol = false,
  }) async {
    await store.remember(scope, {
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
    for (final (id, currency, opening) in [
      (account, 'SAR', balance),
      if (secondAccount != null) (secondAccount, 'USD', 5000),
    ]) {
      await ledger(
        (l) => l.createAccount(
          access,
          commandId: id,
          bankName: 'Cash',
          accountName: 'Fixture $currency',
          accountNumber: '1',
          currency: currency,
          openingMinor: opening,
        ),
      );
      await ledger(
        (l) => l.cashSync.provision(
          access,
          id,
          grantVersion: 1,
          allowNegative: false,
        ),
      );
    }
    await expectLater(
      ledger(
        (l) => l.cashSync.bindReplica(
          access,
          sessionId: sessionId,
          checkpoint: (sequence: checkpoint.sequence, digest: '0' * 64),
        ),
      ),
      throwsA(isA<DirectoryAccessDenied>()),
    );
    await ledger(
      (l) => l.cashSync.bindReplica(
        access,
        sessionId: sessionId,
        checkpoint: checkpoint,
        settlementProtocol: settlementProtocol,
      ),
    );
  }

  Future<int> balance() async =>
      (await ledger((l) => l.accounts(access))).single['balance_minor'] as int;
}

final class _Wire {
  _Wire(this.proc)
    : _err = proc.stderr.transform(utf8.decoder).join(),
      _frames = StreamIterator(
        proc.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );

  final Process proc;
  final Future<String> _err;
  final StreamIterator<String> _frames;
  late final Map<String, Object?> init;
  var sent = 0;

  static Future<_Wire> open(String python, String socket, {bool v3 = false}) async {
    final proc = await Process.start(
      python,
      ['backend/tests/support/business_cash_wire_fixture.py', if (v3) 'settlement'],
      includeParentEnvironment: false,
      environment: {
        'PYTHONPATH': '${Directory.current.path}/backend',
        'PYTHONDONTWRITEBYTECODE': '1',
        'FYONA_TEST_CUTOVER_SOCKET': socket,
      },
    );
    final wire = _Wire(proc);
    addTearDown(wire.close);
    wire.init = await wire._next();
    return wire;
  }

  Future<Map<String, Object?>> _next() async {
    if (!await _frames.moveNext().timeout(const Duration(seconds: 10))) {
      fail('Missing isolated wire reply: ${await _err}');
    }
    return jsonDecode(_frames.current) as Map<String, dynamic>;
  }

  Future<Map<String, Object?>> rpc(
    String action,
    String name,
    Map<String, Object?> body, {
    bool raw = false,
  }) async {
    sent++;
    proc.stdin.writeln(jsonEncode({
      'action': action,
      'actor': name,
      'body': raw ? body : {'checkpoint': init['checkpoint'], ...body},
    }));
    await proc.stdin.flush();
    return _next();
  }

  Future<void> close() async {
    await proc.stdin.close();
    final status = await proc.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        proc.kill();
        return -1;
      },
    );
    await _frames.cancel();
    expect(status, 0, reason: await _err);
  }

  Future<_Replica> replica(Directory root, String name) async {
    final raw = (init['devices'] as Map)[name] as Map;
    final replica = _Replica(
      DirectoryAccess(
        workspace: DirectoryWorkspace(
          server: DirectoryPilotBuild.baseUrl,
          accountId: raw['actor_id'] as String,
          organizationId: init['organization_id'] as String,
        ),
        branchId: init['branch_id'] as String,
        readable: DirectoryPartyKind.values.toSet(),
        writable: DirectoryPartyKind.values.toSet(),
        financialCutover: true,
      ),
      raw['session_id'] as String,
      await root.createTemp('$name-'),
      FixtureDirectoryKeys(),
    );
    addTearDown(replica.store.close);
    return replica;
  }
}

void main() {
  final socket = Platform.environment['FYONA_TEST_CUTOVER_SOCKET'];
  final python = Platform.environment['FYONA_TEST_CASH_WIRE_PYTHON'];

  test(
    'two owner sessions and an employee receive their own durable cash delivery',
    () async {
      final wire = await _Wire.open(python!, socket!);
      final init = wire.init;
      final checkpoint = init['checkpoint'] as Map;
      final rpc = wire.rpc;

      final till = init['account_id'] as String;
      final root = await Directory.systemTemp.createTemp(
        'fyona-business-cash-wire-',
      );
      addTearDown(() => root.delete(recursive: true));
      Future<_Replica> replica(String name) => wire.replica(root, name);
      final devices = {
        for (final name in ['first', 'second', 'employee'])
          name: await replica(name),
      };
      expect(
        devices['first']!.scope.workspace.storageId,
        devices['second']!.scope.workspace.storageId,
      );
      expect(devices['first']!.sessionId, isNot(devices['second']!.sessionId));
      final commands = {
        for (final name in devices.keys) name: const Uuid().v4(),
      };
      for (final entry in devices.entries) {
        final d = entry.value;
        await d.prepare(till, (
          sequence: checkpoint['sequence'] as int,
          digest: checkpoint['digest'] as String,
        ));
        if (entry.key == 'employee') continue;
        await d.ledger(
          (l) => l.move(
            d.access,
            commandId: commands[entry.key]!,
            accountId: till,
            amountMinor: 9000,
            withdraw: true,
            expenseCategory: 'Rent',
          ),
        );
        expect(await d.balance(), 1000);
      }
      final first = devices['first']!;
      final second = devices['second']!;
      final employee = devices['employee']!;
      var loseFirstReply = true;
      var loseSecondAck = true;
      final senders = {
        for (final entry in devices.entries)
          entry.key: BusinessCashDelivery(
            scope: entry.value.scope,
            sessionId: entry.value.sessionId,
            store: entry.value.store,
            current: () => entry.value.active,
            send: (message, body) async {
              if (entry.key == 'second' &&
                  message == BusinessCashMessage.ack &&
                  loseSecondAck) {
                loseSecondAck = false;
                throw const SocketException(
                  'ack lost before it reached the authority',
                );
              }
              final frame = await rpc(message.name, entry.key, body, raw: true);
              if (entry.key == 'first' &&
                  message == BusinessCashMessage.withdraw &&
                  loseFirstReply) {
                loseFirstReply = false;
                throw const SocketException(
                  'response lost after server commit',
                );
              }
              return frame;
            },
          ),
      };
      await expectLater(
        senders['first']!.runOnce(),
        throwsA(isA<SocketException>()),
      );
      expect(
        await first.ledger((l) => l.cashSync.pending(first.access)),
        hasLength(1),
      );
      expect((await rpc('stats', 'first', {}))['count'], 1);
      await expectLater(
        BusinessCashDelivery(
          scope: first.scope,
          sessionId: second.sessionId,
          store: first.store,
          current: () => first.active,
          send: (_, __) async => fail(
            'A copied or switched session must not send from this store',
          ),
        ).runOnce(),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      await expectLater(
        BusinessCashDelivery(
          scope: employee.scope,
          sessionId: employee.sessionId,
          store: employee.store,
          current: () => employee.active,
          send: (message, body) async =>
              rpc(message.name, 'second', body, raw: true),
        ).runOnce(),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      expect(await employee.balance(), 10000);
      expect(
        (await rpc('poll', 'second', {
          'branch_id': init['branch_id'],
        }))['error'],
        'invalid_body',
      ); // A client cannot choose another authority scope.

      final raw = await databaseFactoryFfi.openDatabase(
        DirectoryDatabase.filePath(second.root, second.scope.workspace),
        options: OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: (db) async => db.execute(
            'PRAGMA key = "x\'${second.keys.memory[second.scope.workspace.storageId]}\'"',
          ),
        ),
      );
      addTearDown(raw.close);
      await raw.execute('''
      CREATE TRIGGER fail_delivery BEFORE INSERT ON business_local_bank_legs
      WHEN NEW.command_id = '${commands['first']}'
      BEGIN SELECT RAISE(ABORT, 'fixture interrupted save'); END
    ''');
      await expectLater(
        senders['second']!.runOnce(),
        throwsA(isA<DatabaseException>()),
      );
      expect(
        await second.balance(),
        10000,
      ); // Rejected save reversed; inbound write not yet saved.
      expect((await rpc('poll', 'second', {}))['data'], hasLength(1));
      await raw.execute('DROP TRIGGER fail_delivery');
      await expectLater(
        senders['second']!.runOnce(),
        throwsA(isA<SocketException>()),
      );
      expect(await second.balance(), 1000);
      expect((await rpc('poll', 'second', {}))['data'], hasLength(1));
      await second.store.close();
      second.active = null;
      await expectLater(
        senders['second']!.runOnce(),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      second.active = second.scope;
      await senders['first']!.runOnce();
      expect((await rpc('stats', 'first', {}))['count'], 1);
      await senders['second']!.runOnce();
      expect(
        (await rpc('stats', 'second', {}))['count'],
        1,
      ); // Employee has not received.
      expect((await rpc('poll', 'second', {}))['data'], isEmpty);
      expect(await employee.balance(), 10000);
      await senders['employee']!.runOnce();
      await employee.store.close();
      expect(await employee.balance(), 1000);
      expect((await rpc('stats', 'second', {}))['count'], 0);
      expect(await first.balance(), 1000);
      expect(await second.balance(), 1000);
      final conflicts = await second.ledger(
        (l) => l.cashSync.conflicts(second.access),
      );
      expect(conflicts.single['command_id'], commands['second']);
      expect(conflicts.single['blocked_by'], commands['first']);
      expect(conflicts.single['seen'], 0);
      await second.ledger(
        (l) => l.cashSync.markConflictRead(second.access, commands['second']!),
      );
      await second.store.close();
      expect(
        (await second.ledger(
          (l) => l.cashSync.conflicts(second.access),
        )).single['seen'],
        1,
      );
      expect(
        await first.ledger((l) => l.cashSync.conflicts(first.access)),
        isEmpty,
      );
      final expenses = await second.ledger(
        (l) => l.manualMovements(
          second.access,
          showExpenses: true,
          showIncome: false,
        ),
      );
      expect(
        expenses.single['source_id'],
        commands['first'],
      ); // No rejected expense in totals.
      final legs = await second.ledger((l) => l.statement(second.access, till));
      expect(legs.map((r) => r['delta_minor']), [-9000, 9000, -9000, 10000]);

      // A fourth, independently encrypted device joins only from a fresh
      // reconciled cash checkpoint. The already purged transit cannot stand
      // in for a snapshot or reconstruct the earlier history.
      expect((await rpc('poll', 'late', {}))['error'], 'denied');
      expect(
        (await rpc(
          'fixture_admit',
          'late',
          Map<String, Object?>.from(checkpoint),
          raw: true,
        ))['error'],
        'stale_checkpoint',
      );
      final latest = await rpc('fixture_checkpoint', 'late', {}, raw: true);
      final lateReplica = await replica('late');
      final resource = (latest['accounts'] as List).single as List;
      expect(resource, [till, 'SAR', 1000, false]);
      final binding = (
        sequence: latest['sequence'] as int,
        digest: latest['digest'] as String,
      );
      await lateReplica.prepare(till, binding, balance: resource[2] as int);
      expect(
        await rpc('fixture_admit', 'late', {
          'sequence': binding.sequence,
          'digest': binding.digest,
        }, raw: true),
        {'admitted': true},
      );
      final lateRuntime = BusinessCashDelivery(
        scope: lateReplica.scope,
        sessionId: lateReplica.sessionId,
        store: lateReplica.store,
        current: () => lateReplica.active,
        send: (message, body) => rpc(message.name, 'late', body, raw: true),
      );
      await lateRuntime.runOnce();
      expect(await lateReplica.balance(), 1000);
      await first.ledger(
        (ledger) => ledger.move(
          first.access,
          commandId: const Uuid().v4(),
          accountId: till,
          amountMinor: 500,
          withdraw: true,
        ),
      );
      await senders['first']!.runOnce();
      await senders['second']!.runOnce();
      await senders['employee']!.runOnce();
      expect((await rpc('stats', 'first', {}))['count'], 1);
      await lateRuntime.runOnce();
      await lateReplica.store.close();
      await lateRuntime.runOnce();
      expect(await lateReplica.balance(), 500);
      expect((await rpc('stats', 'first', {}))['count'], 0);
    },
    skip:
        socket == null || python == null || !DirectoryPilotBuild.signupEnabled,
  );

  test(
    'shared settlement is durable offline, ordered, rolled back and acknowledged after apply',
    () async {
      final wire = await _Wire.open(python!, socket!, v3: true);
      final init = wire.init;
      final till = init['account_id'] as String;
      final usd = init['second_account_id'] as String;
      final rawPoint = init['checkpoint'] as Map;
      final point = (
        sequence: rawPoint['sequence'] as int,
        digest: rawPoint['digest'] as String,
      );
      final root = await Directory.systemTemp.createTemp('fyona-settlement-wire-');
      addTearDown(() => root.delete(recursive: true));
      final first = await wire.replica(root, 'first');
      final second = await wire.replica(root, 'second');
      for (final replica in [first, second]) {
        await replica.prepare(till, point, secondAccount: usd, settlementProtocol: true);
      }
      final check = const Uuid().v4(), competing = const Uuid().v4();
      const privateNote = 'Local-only adjustment notes';
      final rows = [
        (accountId: till, expectedMinor: 10000, actualMinor: 9000),
        (accountId: usd, expectedMinor: 5000, actualMinor: 5300),
      ];
      Future<Map<String, dynamic>> detail(_Replica d, String id) =>
          d.ledger((l) => l.bankReconciliationDetail(d.access, id));
      Future<Map<Object?, Object?>> balances(_Replica d) async => {
        for (final a in await d.ledger((l) => l.accounts(d.access)))
          a['id']: a['balance_minor'],
      };
      Future<Map<String, dynamic>> approve(
        _Replica d, String id, {
        String notes = privateNote, bool Function()? allowed,
      }) => d.ledger((l) => l.approveBankReconciliation(
        d.access, id: id, entries: rows, notes: notes, allowed: allowed ?? () => true,
      ));
      for (final (replica, id) in [(first, check), (second, competing)]) {
        await replica.ledger((l) => l.checkBankReconciliation(
          replica.access, id: id, entries: rows, allowed: () => true,
        ));
      }
      var permitted = 0;
      await expectLater(
        approve(first, check, allowed: () => permitted++ == 0),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      expect(await first.ledger((l) => l.cashSync.pendingEqualization(first.access)), isNull);
      final staged = await approve(first, check);
      expect(staged['status'], 'checked');
      expect(staged['authority_state'], 'queued');
      expect(await approve(first, check), staged);
      await expectLater(approve(first, check, notes: 'different'), throwsA(isA<BusinessLedgerError>()));
      await approve(second, competing);
      await expectLater(
        first.ledger((l) => l.move(first.access, commandId: const Uuid().v4(),
          accountId: till, amountMinor: 500, withdraw: true)),
        throwsA(isA<BusinessCashEqualizationPending>()),
      );
      expect(await balances(first), {till: 10000, usd: 5000});
      expect(wire.sent, 0);

      final backup = File('${root.path}/queued.fyonabiz');
      final code = BusinessBackupCode.generate();
      await first.ledger((l) => l.captureBackup(first.access, id: const Uuid().v4(),
        destination: backup, code: code, allowed: () => true));
      final restoreRoot = await root.createTemp('restored-');
      final restoreKeys = FixtureDirectoryKeys();
      Future<DirectoryDatabase> openRestore() => DirectoryDatabase.open(
        root: restoreRoot, keys: restoreKeys, workspace: first.scope.workspace,
      );
      var restored = await openRestore();
      addTearDown(() => restored.close());
      expect(await restored.ledger.restoreBackup(
        first.access, source: backup, code: code, allowed: () => true,
      ), (alreadyRestored: false, hasSharedHistory: true));
      await restored.close();
      restored = await openRestore();
      expect((await restored.ledger.bankReconciliationDetail(first.access, check))['authority_state'], 'suspended');
      expect(await restored.ledger.cashSync.replicaCheckpoint(first.access, first.sessionId), isNull);
      await expectLater(restored.ledger.cashSync.bindReplica(
        first.access, sessionId: first.sessionId, checkpoint: point, settlementProtocol: true,
      ), throwsA(isA<DirectoryAccessDenied>()));

      var lostFirstResponse = false, lostSecondAck = false, lostFirstAckResponse = false;
      var firstAcks = 0;
      BusinessCashDelivery relay(_Replica d, String name) => BusinessCashDelivery(
        scope: d.scope, sessionId: d.sessionId, store: d.store, current: () => d.active,
        send: (_, _) async => fail('An admitted v3 replica must not downgrade to v2'),
        sendV3: (message, body) async {
          if (message == BusinessCashMessage.settle) {
            expect(jsonEncode(body), isNot(contains(privateNote)));
            expect(body.keys, unorderedEquals([
              'command_id', 'observed_through', 'grant_version', 'entries', 'checkpoint',
            ]));
          }
          if (name == 'second' && message == BusinessCashMessage.ack && !lostSecondAck) {
            lostSecondAck = true;
            throw const SocketException('ack lost before commit');
          }
          if (name == 'first' && message == BusinessCashMessage.ack) firstAcks++;
          final result = await wire.rpc(message.name, name, body, raw: true);
          if (name == 'first' && message == BusinessCashMessage.settle && !lostFirstResponse) {
            lostFirstResponse = true;
            throw const SocketException('response lost after commit');
          }
          if (name == 'first' && message == BusinessCashMessage.ack && !lostFirstAckResponse) {
            lostFirstAckResponse = true;
            throw const SocketException('ack response lost after commit');
          }
          return result;
        },
      );
      final a = relay(first, 'first'), b = relay(second, 'second');
      await expectLater(a.runOnce(), throwsA(isA<SocketException>()));
      expect((await detail(first, check))['authority_state'], 'queued');
      expect(await balances(first), {till: 10000, usd: 5000});
      expect((await wire.rpc('stats', 'first', {}))['count'], 1);
      await expectLater(b.runOnce(), throwsA(isA<SocketException>()));
      expect((await detail(second, competing))['authority_reason'], 'staleMeasurement');
      expect(await balances(second), {till: 9000, usd: 5300});

      await first.store.close();
      final raw = await databaseFactoryFfi.openDatabase(
        DirectoryDatabase.filePath(first.root, first.scope.workspace),
        options: OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: (db) => db.execute(
            'PRAGMA key = "x\'${first.keys.memory[first.scope.workspace.storageId]}\'"',
          ),
        ),
      );
      addTearDown(raw.close);
      await raw.execute('''
        CREATE TRIGGER stop_settlement BEFORE UPDATE OF status ON business_reconciliations
        BEGIN SELECT RAISE(ABORT, 'fixture blocked the last write'); END
      ''');
      await expectLater(a.runOnce(), throwsA(isA<DatabaseException>()));
      expect(firstAcks, 0);
      expect(await balances(first), {till: 10000, usd: 5000});
      expect((await detail(first, check))['status'], 'checked');
      await raw.execute('DROP TRIGGER stop_settlement');
      await expectLater(a.runOnce(), throwsA(isA<SocketException>()));
      expect(firstAcks, 1);
      await first.store.close();
      await second.store.close();
      second.active = null;
      final sent = wire.sent;
      await expectLater(b.runOnce(), throwsA(isA<DirectoryAccessDenied>()));
      expect(wire.sent, sent);
      second.active = second.scope;
      await b.runOnce();
      await a.runOnce();
      expect((await wire.rpc('stats', 'first', {}))['count'], 1); // Third replica not yet delivered.
      await wire.rpc('fixture_revoke', 'employee', {});
      expect((await wire.rpc('poll', 'employee', {}))['error'], 'denied');
      expect((await wire.rpc('stats', 'first', {}))['count'], 0);
      for (final d in [first, second]) {
        expect(await balances(d), {till: 9000, usd: 5300});
        for (final id in [till, usd]) {
          expect(await d.ledger((l) => l.statement(d.access, id)), hasLength(2));
        }
      }
      final approved = await detail(first, check);
      expect(approved['status'], 'approved');
      expect(approved['authority_state'], 'accepted');
      expect(approved['notes'], privateNote);
      expect(await approve(first, check), approved);
      expect((await detail(second, competing))['status'], 'checked');
      expect(await first.ledger((l) => l.cashSync.pendingEqualization(first.access)), isNull);
    },
    skip: socket == null || python == null || !DirectoryPilotBuild.signupEnabled,
  );
}
