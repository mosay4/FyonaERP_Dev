import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/backup/backup_bridges.dart';
import 'package:fyona_flutter/core/backup/backup_crypto.dart';
import 'package:fyona_flutter/core/backup/backup_worker.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/data/account_type_store.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_ledger.dart';
import 'package:fyona_flutter/features/personal/domain/services/backup/backup_integrity.dart';
import 'package:fyona_flutter/features/personal/domain/services/backup/backup_snapshot.dart';
import 'package:fyona_flutter/features/personal/domain/services/backup_service.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/personal_ledger_test_support.dart';

const _user = 'aaaaaaaa-0000-4000-8000-00000000000a';
const _bank = '0b0b0b0b-1111-4111-8111-000000000001';
String _tx(Object i) => '0c0c0c0c-2222-4222-8222-${'$i'.hashCode.toRadixString(16).padLeft(12, '0').substring(0, 12)}';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    installPersonalLedgerForTests();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({'enabled_currencies_x': ['SAR', 'USD']});
    await resetPersonalLedger();
  });
  tearDown(resetPersonalLedger);

  test('personal: continuous backup, device lost, restored through the regular restore', () async {
    final ns = PersonalCacheRepository.stableIdSync(_user);
    final finance = PersonalFinanceService(
        apiClient: ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9'))), cache: PersonalCacheRepository());
    finance.setUserId(ns);
    final svc = BackupService(financeService: finance)..bindIdentity(localUserId: ns, serverUserUuid: _user);
    final cache = PersonalCacheRepository();
    await cache.upsertItem(ns, 'personal_bank_account', _bank,
        {'id': _bank, 'bank_name': 'Cash', 'currency': 'SAR', 'balance': 1500.75});
    for (var i = 0; i < 50; i++) {
      await cache.upsertItem(ns, 'personal_transaction', _tx(i),
          {'id': _tx(i), 'amount': 10.25 + i, 'bank_account_id': _bank, 'note': 'مصروف $i'});
    }
    PersonalAccountTypeStore.now = () => 42;
    await PersonalAccountTypeStore.save(_bank, 'savings');

    final live = await PersonalLedger.active();
    final dbKey = personalLedgerTestKeys.memory[live.storageId]!;
    final key = await BackupKeys.newKey();
    final kb = await BackupKeys.keyBytes(key);
    final dir = await Directory.systemTemp.createTemp('fyona-bk-personal-');
    var state = <String, dynamic>{};
    Future<void> run() async {
      final r = await runBackupJob(BackupJob(dbPath: live.path, dbKeyHex: dbKey, backupKey: kb, wrappedKey: const {},
          scope: 'personal', localRoot: '${dir.path}/sets', state: state, extras: await BackupBridges.personalExtras(svc)));
      expect(r.error, isNull);
      state = r.state;
    }

    await run();
    // Work after the first backup is captured and carried by the next run.
    await cache.upsertItem(ns, 'personal_transaction', _tx('late'), {'id': _tx('late'), 'amount': 999.5, 'bank_account_id': _bank});
    await cache.removeItem(ns, 'personal_transaction', _tx(3));
    await run();

    final before = await BackupSnapshotBuilder.build(localUserId: ns, serverUserUuid: _user, appVersion: 't');

    // The verified copy converts to exactly the snapshot the live ledger gives.
    final copy = '${dir.path}/copy.sqlite';
    final out = await runRestoreJob(setRoot: '${dir.path}/sets', backupId: state['id'] as String, backupKey: kb,
        targetPath: copy, dbKeyHex: dbKey);
    expect(out.problems, isEmpty);
    final copyDb = await openLedgerFile(copy, dbKey);
    final fromCopy = await BackupBridges.personalSnapshot(copyDb, out.extras, localUserId: ns, appVersion: 't');
    await copyDb.close();
    expect(fromCopy['tables'], before['tables']);
    expect(fromCopy['entities'], before['entities']);
    expect(fromCopy['preferences'], before['preferences']);
    final v = BackupIntegrity.validateSnapshot(BackupIntegrity.sealSnapshot(fromCopy));
    expect(v.errors.map((e) => '${e.code}:${e.params}'), isEmpty);
    final v0 = BackupIntegrity.validateSnapshot(BackupIntegrity.sealSnapshot(before));
    expect(v0.errors.map((e) => '${e.code}:${e.params}'), isEmpty);

    // Device lost: ledger gone. Restore via the regular path.
    await resetPersonalLedger();
    expect(await cache.getCollection(ns, 'personal_transaction'), isEmpty);
    final res = await BackupBridges.applyPersonal(svc, copy, dbKey, out.extras, appVersion: 't');
    expect(res.success, isTrue, reason: res.message);
    final txs = await cache.getCollection(ns, 'personal_transaction');
    expect(txs.length, 50); // 50 + late − deleted
    expect(txs.any((t) => t['id'] == _tx('late') && t['amount'] == 999.5), isTrue);
    expect(txs.any((t) => t['id'] == _tx(3)), isFalse);
    expect((await cache.getCollection(ns, 'personal_bank_account')).single['balance'], 1500.75);
    expect(await PersonalAccountTypeStore.load(), {_bank: 'savings'});
    await dir.delete(recursive: true);
  });
}
