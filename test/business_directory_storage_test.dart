import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_party.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'support/business_commerce_test_schema.dart';
import 'support/directory_test_keys.dart';

void main() {
  final folder = Platform.environment['FYONA_DIRECTORY_CRASH_FIXTURE'];
  if (folder != null) {
    _crashProbe(
      Directory(folder),
      Platform.environment['FYONA_DIRECTORY_CRASH_STEP']!,
    );
    return;
  }

  final workspace = _workspace();
  final access = _access(workspace);
  final other = _access(workspace, branch: _branchB);
  late Directory root;
  late FixtureDirectoryKeys keys;
  late DirectoryDatabase db;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fyona-directory-');
    keys = FixtureDirectoryKeys();
    db = await DirectoryDatabase.open(
      root: root,
      workspace: workspace,
      keys: keys,
    );
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  test(
    'real encrypted file and durable IDs, with no plaintext fallback',
    () async {
      const label = 'بيانات العميل الخاصة-encrypted-record';
      final id = (await db.create(
        access,
        _c,
        name: label,
        phone: '5550000101',
      )).id;
      await db.create(access, _s, name: 'Synthetic Supplier');
      await db.close();
      final file = File(DirectoryDatabase.filePath(root, workspace));
      final bytes = await file.readAsBytes();
      final raw = utf8.decode(bytes, allowMalformed: true);
      expect(raw, isNot(contains(label)));
      expect(raw, isNot(contains('5550000101')));
      expect(raw.startsWith('SQLite format 3'), isFalse);
      final key = keys.memory.remove(workspace.storageId)!;
      await expectLater(
        DirectoryDatabase.open(root: root, workspace: workspace, keys: keys),
        throwsA(isA<DirectoryKeyUnavailable>()),
      );
      final dataAfterMissingKey = await file.readAsBytes();
      expect(dataAfterMissingKey, bytes);
      keys.memory[workspace.storageId] = List.filled(64, 'a').join();
      await expectLater(
        DirectoryDatabase.open(root: root, workspace: workspace, keys: keys),
        throwsA(isA<DatabaseException>()),
      );
      expect(await file.readAsBytes(), bytes);
      keys.memory[workspace.storageId] = key;
      db = await DirectoryDatabase.open(
        root: root,
        workspace: workspace,
        keys: keys,
      );
      expect((await db.search(access, _c, 'العميل')).single.id, id);
      expect(
        (await db.search(access, _s, 'SUPPLIER')).single.name,
        'Synthetic Supplier',
      );
    },
  );

  test(
    'account, organization and branch isolation; write requires its own permission',
    () async {
      await db.create(access, _c, name: 'Branch one');
      await db.create(other, _c, name: 'Branch two');
      expect((await db.search(access, _c, '')).single.name, 'Branch one');
      expect(await db.search(other, _c, 'one'), isEmpty);
      final viewer = _access(workspace, readable: {_c}, writable: {});
      expect((await db.search(viewer, _c, '')).single.name, 'Branch one');
      await expectLater(
        db.search(viewer, _s, ''),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      await expectLater(
        db.create(viewer, _c, name: 'Denied'),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      for (final scope in [
        _workspace(account: 'b722efef-8a1c-4830-885b-3ad90492e839'),
        _workspace(org: '1f683120-9e30-4876-ac15-6dd2decafaa6'),
        _workspace(server: 'http://localhost:18083/api/v1'),
      ]) {
        final denied = _access(scope);
        await expectLater(
          db.search(denied, _c, ''),
          throwsA(isA<DirectoryAccessDenied>()),
        );
        final separate = await DirectoryDatabase.open(
          root: root,
          workspace: scope,
          keys: keys,
        );
        expect(await separate.search(denied, _c, ''), isEmpty);
        expect(
          keys.memory[scope.storageId],
          isNot(keys.memory[workspace.storageId]),
        );
        await separate.close();
      }
    },
  );

  test(
    'lookup and updates retain identity, scope, history and encryption',
    () async {
      final party = await db.create(
        access,
        _c,
        name: 'Original party',
        phone: '55574',
      );
      final supplier = await db.create(other, _s, name: 'Different branch');
      await expectLater(
        db.find(other, _c, party.id),
        throwsA(isA<DirectoryPartyNotFound>()),
      );
      await expectLater(
        db.update(access, _s, supplier.id, name: 'No crossing'),
        throwsA(isA<DirectoryPartyNotFound>()),
      );
      await db.update(
        access,
        _c,
        party.id,
        name: '  الاسم الجديد ',
        phone: ' ',
      );
      final edited = await db.find(access, _c, party.id);
      expect(edited.name, 'الاسم الجديد');
      expect(edited.phone, party.phone);
      expect(edited.createdAt, party.createdAt);
      expect((await db.search(access, _c, 'الجديد')).single.id, party.id);
      expect(await db.search(access, _c, 'Original'), isEmpty);
      await db.close();
      db = await DirectoryDatabase.open(
        root: root,
        workspace: workspace,
        keys: keys,
      );
      expect((await db.find(access, _c, party.id)).name, 'الاسم الجديد');
    },
  );

  test(
    'the APK v1 schema upgrades without replacing encrypted records',
    () async {
      await db.close();
      final path = DirectoryDatabase.filePath(root, workspace);
      final key = keys.memory[workspace.storageId]!;
      final v1 = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          onConfigure: (db) async => db.execute('PRAGMA key = "x\'$key\'"'),
          singleInstance: false,
        ),
      );
      const id = 'bde02dff-9c1d-4c56-bf33-cbad9abc5aad';
      await v1.transaction((txn) async {
        // Reconstruct the pre-group schema from the current empty fixture.
        await removeCommerceFixtureSchema(txn);
        await txn.execute('DROP VIEW business_debt_payment_history');
        for (final table in [
          'business_opening_projection_receipts',
          'business_imported_opening_payments',
          'business_bank_projection_receipts',
          'business_bank_account_edits',
          'business_cutover_rows',
          'business_cutover_archives',
          'business_opening_debt_edits',
          'business_cash_conflict_reads',
          'business_deleted_directory_parties',
          'business_cash_decisions',
          'business_cash_outbox',
          'business_shared_cash',
          'business_local_payment_parts',
          'business_local_debts',
          'business_local_bank_legs',
          'business_local_accounts',
          'business_ledger_policy',
          'business_ledger_commands',
        ]) {
          await txn.execute('DROP TABLE $table');
        }
        await txn.execute('DROP TABLE business_debt_groups');
        await txn.execute('DROP INDEX directory_party_scope');
        await txn.execute('PRAGMA user_version = 1');
        await txn.insert('directory_parties', {
          'kind': 'customer',
          'id': id,
          'branch_id': access.branchId,
          'name': 'Already on phone',
          'folded_name': 'already on phone',
          'created_us': 1,
          'origin': 'device',
        });
      });
      await v1.close();
      db = await DirectoryDatabase.open(
        root: root,
        workspace: workspace,
        keys: keys,
      );
      expect((await db.find(access, _c, id)).name, 'Already on phone');
      await db.createGroup(access, _c, id, 'Original group');
      final group = (await db.groups(access, _c, id)).single;
      expect(group['count'], 0);
      await db.renameGroup(access, _c, id, '${group['id']}', 'Renamed offline');
      final sameBranch = await db.create(access, _s, name: 'Other party');
      expect(await db.groups(access, _s, sameBranch.id), isEmpty);
      await expectLater(
        db.renameGroup(access, _s, sameBranch.id, '${group['id']}', 'Wrong'),
        throwsA(isA<DirectoryPartyNotFound>()),
      );
      await expectLater(
        db.groups(other, _c, id),
        throwsA(isA<DirectoryPartyNotFound>()),
      );
      await db.close();
      db = await DirectoryDatabase.open(
        root: root,
        workspace: workspace,
        keys: keys,
      );
      expect(
        (await db.groups(access, _c, id)).single['name'],
        'Renamed offline',
      );
    },
  );

  test(
    'atomic scoped fixture import retains every ID and can be repeated',
    () async {
      const snapshotId = '2ad0186a-2d2b-46eb-a45f-6076675f52f4';
      final supplier = _record(
        workspace,
        'Seeded supplier',
        kind: _s,
        email: 'QASEED@example.test',
      );
      final customer = _record(workspace, 'عميل تجريبي', phone: '555001');
      final batch = [supplier, customer];
      await db.importFixture(access, batch, snapshotId: snapshotId);
      await db.importFixture(access, batch, snapshotId: snapshotId);
      expect((await db.search(access, _c, '5001')).single.id, customer.id);
      expect((await db.search(access, _s, 'qaseed@')).single.id, supplier.id);
      expect(
        (await db.search(access, _s, '')).single.createdAt,
        supplier.createdAt,
      );
      expect(await db.hasFixture(access, snapshotId), isTrue);
      expect(await db.hasFixture(other, snapshotId), isFalse);
      // Legacy edits may already have created a duplicate. Import keeps the
      // two IDs rather than merging people or silently dropping either row.
      final legacyTwin = DirectoryParty.fromFixture(_c, {
        'id': const Uuid().v4(),
        'organization_id': workspace.organizationId,
        'branch_id': _branchA,
        'name': customer.name,
        'phone': customer.phone,
        'created_at': customer.createdAt.toIso8601String(),
      });
      await db.importFixture(access, [legacyTwin]);
      expect(
        (await db.search(access, _c, customer.name)).map((r) => r.id).toSet(),
        {customer.id, legacyTwin.id},
      );
      final forged = _record(workspace, 'Private branch', branch: _branchB);
      await expectLater(
        db.importFixture(access, [forged]),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      final outsider = _record(
        _workspace(org: '1f683120-9e30-4876-ac15-6dd2decafaa6'),
        'Other organization',
      );
      await expectLater(
        db.importFixture(access, [outsider]),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      final conflict = _record(workspace, 'Different row', id: customer.id);
      await expectLater(
        db.importFixture(access, [
          _record(workspace, 'Should roll back'),
          conflict,
        ], snapshotId: '99f90edf-b5ab-47ee-a547-e38b50541b4c'),
        throwsA(isA<DirectoryImportConflict>()),
      );
      expect(await db.search(access, _c, 'roll back'), isEmpty);
      expect(
        await db.hasFixture(access, '99f90edf-b5ab-47ee-a547-e38b50541b4c'),
        isFalse,
      );
    },
  );

  test(
    'concurrent taps, same command replay, and original duplicate rules',
    () async {
      final id = const Uuid().v4();
      final rows = await Future.wait(
        List.generate(
          8,
          (_) => db.create(
            access,
            _c,
            name: '  Samir test  ',
            phone: '15550001111',
            id: id,
          ),
        ),
      );
      expect(rows.map((party) => party.id).toSet(), {id});
      expect(await db.search(access, _c, ''), hasLength(1));
      await expectLater(
        db.create(access, _c, name: 'SAMIR TEST'),
        throwsA(
          isA<DirectoryValidation>().having(
            (e) => e.problem,
            'problem',
            DirectoryValidationProblem.duplicateName,
          ),
        ),
      );
      await expectLater(
        db.create(access, _c, name: 'Second customer', phone: ' 15550001111 '),
        throwsA(
          isA<DirectoryValidation>().having(
            (e) => e.problem,
            'problem',
            DirectoryValidationProblem.duplicatePhone,
          ),
        ),
      );
      await expectLater(
        db.create(access, _c, name: 'X'),
        throwsA(
          isA<DirectoryValidation>().having(
            (e) => e.problem,
            'problem',
            DirectoryValidationProblem.nameLength,
          ),
        ),
      );
      await db.create(access, _s, name: 'SAMIR TEST', phone: '15550001111');
      await db.create(other, _c, name: 'SAMIR TEST', phone: '15550001111');
      expect(await db.search(access, _c, 'samir'), hasLength(1));
    },
  );

  test('current first-page ordering and search across stored fields', () async {
    final rows = List.generate(
      26,
      (i) => _record(
        workspace,
        'Customer ${i.toString().padLeft(2, '0')}',
        phone: '555012${i.toString().padLeft(2, '0')}',
        date: DateTime.utc(2026, 1, 1, 0, i),
      ),
    );
    await db.importFixture(access, rows);
    final result = await db.search(access, _c, '');
    expect(result, hasLength(20));
    expect(result.first.id, rows.last.id);
    expect(result.last.id, rows[6].id);
    expect((await db.search(access, _c, 'customer 01')).single.id, rows[1].id);
    expect((await db.search(access, _c, '501200')).single.id, rows[0].id);
  });
}

const _c = DirectoryPartyKind.customer;
const _s = DirectoryPartyKind.supplier;
const _branchA = 'da2e39ff-3990-4c16-863d-293fb902b93d';
const _branchB = 'da2e39ff-3990-4c16-863d-293fb902b93e';

DirectoryWorkspace _workspace({
  String server = 'http://127.0.0.1:18083/api/v1',
  String account = 'b722efef-8a1c-4830-885b-3ad90492e837',
  String org = '0f683120-9e30-4876-ac15-6dd2decafaa6',
}) =>
    DirectoryWorkspace(server: server, accountId: account, organizationId: org);

DirectoryAccess _access(
  DirectoryWorkspace scope, {
  String branch = _branchA,
  Set<DirectoryPartyKind> readable = const {_c, _s},
  Set<DirectoryPartyKind> writable = const {_c, _s},
}) => DirectoryAccess(
  workspace: scope,
  branchId: branch,
  readable: readable,
  writable: writable,
);

DirectoryParty _record(
  DirectoryWorkspace workspace,
  String name, {
  String branch = _branchA,
  DirectoryPartyKind kind = _c,
  String? id,
  String? phone,
  String? email,
  DateTime? date,
}) => DirectoryParty(
  id: id ?? const Uuid().v4(),
  kind: kind,
  organizationId: workspace.organizationId,
  branchId: branch,
  name: name,
  phone: phone,
  email: email,
  createdAt: date ?? DateTime.utc(2026, 1, 1),
);

/// Separate flutter tester processes are used for both sides of the crash.
/// A driver traps the genuine SQLite transaction immediately before COMMIT.
/// POSIX SIGKILL simulates a killed host app, not a graceful exception.
void _crashProbe(Directory root, String step) {
  test('separate process and durable transaction: $step', () async {
    final workspace = _workspace();
    final access = _access(workspace);
    final keys = FixtureDirectoryKeys(root);
    final db = await DirectoryDatabase.open(
      root: root,
      workspace: workspace,
      keys: keys,
    );
    if (step == 'stage') {
      await db.create(access, _c, name: 'Previously committed customer');
      await db.close();
      final raw = await databaseFactoryFfi.openDatabase(
        DirectoryDatabase.filePath(root, workspace),
        options: OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: (db) async {
            final key = await keys.read(workspace.storageId);
            await db.execute('PRAGMA key = "x\'$key\'"');
            await db.execute('PRAGMA synchronous = FULL');
          },
        ),
      );
      // Same table, engine and transaction semantics as DirectoryDatabase.
      // Hold the transaction open after writing and prove committed data
      // survives while uncommitted work never appears after process death.
      await raw.transaction((txn) async {
        await txn.insert('directory_parties', {
          'kind': 'customer',
          'id': const Uuid().v4(),
          'branch_id': _branchA,
          'name': 'Interrupted customer',
          'folded_name': 'interrupted customer',
          'phone': '555-FIRST-PART',
          'created_us': 123,
          'origin': 'device',
        });
        final journal = File(
          '${DirectoryDatabase.filePath(root, workspace)}-journal',
        );
        expect(await journal.exists(), isTrue);
        expect(
          utf8.decode(await journal.readAsBytes(), allowMalformed: true),
          isNot(contains('Previously committed customer')),
        );
        await File(
          '${root.path}/killed-during-transaction',
        ).writeAsString('$pid', flush: true);
        Process.killPid(pid, ProcessSignal.sigkill);
        fail('SIGKILL did not terminate the tester');
      }, exclusive: true);
    } else {
      expect(
        await File('${root.path}/killed-during-transaction').exists(),
        isTrue,
      );
      final rows = await db.search(access, _c, '');
      expect(rows.map((r) => r.name), ['Previously committed customer']);
      expect(await db.search(access, _c, '555-FIRST-PART'), isEmpty);
      await db.create(access, _s, name: 'Saved after restart');
    }
    await db.close();
  });
}
