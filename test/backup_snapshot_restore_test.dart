import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:fyona_flutter/core/backup/account_backup_keys.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/domain/services/backup/backup_integrity.dart';
import 'package:fyona_flutter/features/personal/domain/services/backup/backup_snapshot.dart';
import 'package:fyona_flutter/features/personal/domain/services/backup_service.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_ledger.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_ledger_backup.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_local_cutover.dart';
import 'support/personal_ledger_test_support.dart';

/// Backup/Restore 4.0.0 verification (Personal only).
///
/// - Pure integrity/validation/migration tests (no I/O).
/// - Service round-trips against the real local DB (sqflite ffi) with the
///   native storage channel mocked as an in-memory file store.
/// - Money is compared EXACTLY (string form) — any 0.01 drift fails.
/// - Server paths use a Dio interceptor (offline vs verified success).
void main() {
  const uid = 7101;
  const serverUuid = '11111111-2222-3333-4444-555555555555';

  // ── In-memory native file store (mocks com.fyona.erp/backup_storage) ──
  // Mirrors the NEW native contract: writes never delete anything; the
  // Dart layer retires exact URIs explicitly after verification.
  final nativeFiles = <String, String>{};
  final nativeNames = <String, String>{};
  var nativeSeq = 0;
  // When true, the next native write fails (atomicity probe).
  var nativeFailNextWrite = false;

  PersonalFinanceService makeService({Dio? dio}) {
    final d = dio ??
        Dio(BaseOptions(
          baseUrl: 'http://127.0.0.1:9',
          connectTimeout: const Duration(seconds: 2),
          receiveTimeout: const Duration(seconds: 2),
        ));
    final svc = PersonalFinanceService(
      apiClient: ApiClient(dio: d),
      cache: PersonalCacheRepository(),
    );
    svc.setUserId(uid);
    return svc;
  }

  BackupService makeBackup({Dio? dio}) {
    final d = dio ?? Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9'));
    return BackupService(
      financeService: makeService(dio: d),
      apiClient: ApiClient(dio: d),
    );
  }

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.fyona.erp/backup_storage'),
      (call) async {
        switch (call.method) {
          case 'saveAtomic':
            {
              if (nativeFailNextWrite) {
                nativeFailNextWrite = false;
                return {'success': false, 'message': 'injected failure'};
              }
              final args = call.arguments as Map;
              final content = args['content'] as String;
              final name =
                  (args['fileName'] as String?) ?? 'FYONA_ERP_Backup.json';
              nativeSeq++;
              final uri = 'mock://backup/$nativeSeq';
              nativeFiles[uri] = content;
              nativeNames[uri] = name;
              return {
                'success': true,
                'uri': uri,
                'filePath': 'Download/FYONA ERP/$name',
                'fileName': name,
                'fileSize': utf8.encode(content).length,
                'relativePath': 'Download/FYONA ERP/',
              };
            }
          case 'updateExistingBackup':
            {
              if (nativeFailNextWrite) {
                nativeFailNextWrite = false;
                return {'success': false, 'message': 'injected failure'};
              }
              // Mirrors the native contract: the given row is overwritten in
              // place, so the SAME uri comes back (no rotation).
              final args = call.arguments as Map;
              final content = args['content'] as String;
              final uri = (args['uri'] as String?) ?? '';
              if (uri.isEmpty || !nativeFiles.containsKey(uri)) {
                return {'success': false, 'message': 'row gone'};
              }
              nativeFiles[uri] = content;
              nativeNames[uri] = 'FYONA_ERP_Backup.json';
              return {
                'success': true,
                'uri': uri,
                'fileSize': utf8.encode(content).length,
                'fileName': 'FYONA_ERP_Backup.json',
                'relativePath': 'Download/FYONA ERP/',
              };
            }
          case 'readDocumentContent':
            {
              final uri = (call.arguments as Map)['uri'] as String;
              final content = nativeFiles[uri];
              if (content == null) return {'success': false};
              return {
                'success': true,
                'content': content,
                'size': utf8.encode(content).length,
              };
            }
          case 'overwriteFixedBackup':
            {
              if (nativeFailNextWrite) {
                nativeFailNextWrite = false;
                return {'success': false, 'message': 'injected failure'};
              }
              final args = call.arguments as Map;
              final uri = args['uri'] as String;
              final content = args['content'] as String;
              if (!nativeFiles.containsKey(uri)) {
                return {'success': false, 'message': 'row gone'};
              }
              nativeFiles[uri] = content;
              return {
                'success': true,
                'uri': uri,
                'fileSize': utf8.encode(content).length,
              };
            }
          case 'deleteBackupByUri':
            {
              final uri = (call.arguments as Map)['uri'] as String;
              nativeFiles.remove(uri);
              nativeNames.remove(uri);
              return {'success': true};
            }
          case 'listBackups':
            return {
              'success': true,
              'backups': [
                for (final e in nativeFiles.entries)
                  {
                    'uri': e.key,
                    'name': nativeNames[e.key] ?? 'FYONA_ERP_Backup.json',
                    'size': utf8.encode(e.value).length,
                    'dateModified':
                        DateTime.now().millisecondsSinceEpoch ~/ 1000,
                    'relativePath': 'Download/FYONA ERP/',
                  }
              ],
            };
          case 'requestStoragePermission':
            return {'needed': false, 'granted': true};
        }
        return null;
      },
    );
  });

  Future<void> cleanDb() async {
    await (await testLedger()).rawDelete(
        'DELETE FROM personal_entity_cache WHERE user_id = ?', [uid]);
    await (await testLedger()).rawDelete('DELETE FROM sync_queue');
    for (final t in BackupSnapshotBuilder.snapshotTables) {
      try {
        await _wipeTable(t);
      } catch (_) {}
    }
    await (await testLedger()).rawDelete('DELETE FROM personal_kv');
    nativeFiles.clear();
    nativeNames.clear();
    final prefs = await SharedPreferences.getInstance();
    for (final k in prefs.getKeys().toList()) {
      if (k.startsWith('enabled_currencies_') ||
          k.startsWith('money_format_') ||
          k.startsWith('backup_') ||
          k == 'wallet_currency' ||
          k == 'debt_display_currency') {
        await prefs.remove(k);
      }
    }
  }

  // Device files are encrypted with the account key (fetched from the
  // server in the app): a fixed test key here, no network.
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    AccountBackupKeys.fetchOverride = (_) async => base64Encode(List.filled(32, 3));
    await cleanDb();
  });
  tearDown(() async {
    AccountBackupKeys.fetchOverride = null;
    await cleanDb();
  });

  // Seeds a rich multi-currency dataset through the REAL service path
  // (local-first mirror writes), returns the built snapshot maps.
  Future<Map<String, dynamic>> seedRich(PersonalFinanceService svc) async {
    await svc.addBankAccount(
        bankName: 'Cash Old', currency: 'YER_OLD', openingBalance: 54000.50);
    await svc.addBankAccount(
        bankName: 'Vault USD', currency: 'USD', openingBalance: 100.25);
    await svc.addBankAccount(
        bankName: 'Main SAR', currency: 'SAR', openingBalance: 10000);
    final banks = await svc.getBankAccounts();
    final cash =
        banks.firstWhere((b) => b.bankName == 'Cash Old').id;
    final vault =
        banks.firstWhere((b) => b.bankName == 'Vault USD').id;
    await svc.addTransaction(
      type: 'expense', amount: 10.99, category: 'food',
      description: 'lunch', currency: 'SAR', accountId: cash,
      date: DateTime.utc(2026, 5, 1, 10, 30),
    );
    await svc.addTransaction(
      type: 'income', amount: 5000, category: 'salary',
      description: 'may', currency: 'SAR', accountId: cash,
      date: DateTime.utc(2026, 5, 2, 9, 0),
    );
    await svc.transferBetweenAccounts(
      fromId: vault, toId: cash, amount: 100,
      fromCurrency: 'USD', toCurrency: 'YER_OLD', rate: 540,
    );
    await svc.addSavingsGoal(SavingsGoal(
      id: '', name: 'Car', targetAmount: 500000, currency: 'YER_NEW',
      deadline: '2027-01-01',
    ));
    await svc.addDebt(PersonalDebt(
      id: '', type: 'receivable', personName: 'Ali', amount: 1000000,
      currency: 'YER_OLD', dueDate: DateTime.utc(2026, 11, 23),
    ));
    final debts = await svc.getDebts();
    final debtId = debts.firstWhere((d) => d.personName == 'Ali').id;
    await svc.payDebt(debtId, 50000.25, DateTime.utc(2026, 6, 1),
        currency: 'YER_OLD');
    await svc.addBudget(PersonalBudget(
      id: '', name: 'Trip', totalAmount: 1000000, currency: 'SAR',
      categories: [
        BudgetCategory(
            id: '', name: 'flights', type: 'expense',
            allocatedAmount: 300000, currency: 'SAR'),
        BudgetCategory(
            id: '', name: 'stay', type: 'expense',
            allocatedAmount: 100000, currency: 'SAR'),
      ],
    ));
    await svc.addRecurring(RecurringTransaction(
      id: '', name: 'Rent', type: 'expense', amount: 1500,
      currency: 'SAR', category: 'rent', frequency: 'monthly',
      nextDate: DateTime.utc(2026, 10, 1), bankAccountId: cash,
    ));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('enabled_currencies_7101',
        ['YER_OLD', 'YER_NEW', 'SAR', 'USD']);
    await prefs.setString('wallet_currency', 'SAR');
    return {'cash': cash, 'vault': vault, 'debtId': debtId};
  }

  group('integrity (pure)', () {
    Map<String, dynamic> sample() => {
          'schema_version': '4.0.0',
          'backup_id': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
          'created_at': '2026-09-24T00:00:00.000Z',
          'app_version': 't',
          'user_uuid': serverUuid,
          'local_user_id': uid,
          'source': 'device',
          'counts': {
            'accounts': 1,
            'transactions': 0,
            'goals': 0,
            'debts': 0,
            'debt_payments': 0,
            'budgets': 0,
            'recurring': 0
          },
          'tables': {},
          'preferences': {},
          'entities': {
            'accounts': [
              {
                'id': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee1',
                'bank_name': 'Cash',
                'currency': 'YER_OLD',
                'balance': '54000.50',
                'notes': null
              }
            ],
            'transactions': [],
            'goals': [],
            'debts': [],
            'debt_payments': [],
            'budgets': [],
            'recurring': [],
          },
          'meta': {},
        };

    test('seal then validate: ok + verified with key', () {
      const key =
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
      final sealed = BackupIntegrity.sealSnapshot(sample(), hmacKeyB64: key);
      expect(sealed['checksum'], isNotEmpty);
      expect(sealed['hmac'], isNotEmpty);
      final res = BackupIntegrity.validateSnapshot(sealed, hmacKeyB64: key);
      expect(res.ok, isTrue);
      expect(res.authenticity, 'verified');
    });

    test('tampered byte fails checksum', () {
      final sealed = BackupIntegrity.sealSnapshot(sample());
      sealed['counts'] = {
        'accounts': 999,
        'transactions': 0,
        'goals': 0,
        'debts': 0,
        'debt_payments': 0,
        'budgets': 0,
        'recurring': 0
      };
      final res = BackupIntegrity.validateSnapshot(sealed);
      expect(res.ok, isFalse);
      expect(res.errors.map((e) => e.code), contains('checksum_mismatch'));
    });

    test('tamper with recomputed checksum fails hmac', () {
      const key =
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
      final sealed = BackupIntegrity.sealSnapshot(sample(), hmacKeyB64: key);
      final originalHmac = sealed['hmac'] as String;
      expect(originalHmac.isNotEmpty, isTrue);
      // Attacker edits data, recomputes the (keyless) checksum, but must
      // keep the original HMAC: without the key it cannot be reforged.
      final tampered = Map<String, dynamic>.from(sealed);
      tampered['counts'] = {
        'accounts': 999,
        'transactions': 0,
        'goals': 0,
        'debts': 0,
        'debt_payments': 0,
        'budgets': 0,
        'recurring': 0
      };
      tampered.remove('checksum');
      tampered.remove('hmac');
      tampered['checksum'] = BackupIntegrity.computeChecksum(tampered);
      tampered['hmac'] = originalHmac;
      final res =
          BackupIntegrity.validateSnapshot(tampered, hmacKeyB64: key);
      expect(res.ok, isFalse);
      expect(res.errors.map((e) => e.code), contains('tamper_detected'));
    });

    test('checksum-only mode is valid but unverified', () {
      final sealed = BackupIntegrity.sealSnapshot(sample());
      final res = BackupIntegrity.validateSnapshot(sealed);
      expect(res.ok, isTrue);
      expect(res.authenticity, 'unverified');
    });

    test('unknown schema rejected', () {
      final bad = sample()..['schema_version'] = '9.9.9';
      final res = BackupIntegrity.validateSnapshot(
          BackupIntegrity.sealSnapshot(bad));
      expect(res.ok, isFalse);
      expect(res.errors.map((e) => e.code), contains('unknown_schema'));
    });

    test('orphan + duplicate + bad amount detected', () {
      final s = sample();
      final ents = s['entities'] as Map<String, dynamic>;
      (ents['transactions'] as List).add({
        'id': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee2',
        'tx_type': 'expense',
        'amount': '5',
        'currency': 'SAR',
        'category': 'x',
        'bank_account_id': 'ffffffff-ffff-ffff-ffff-ffffffffffff',
      });
      (ents['accounts'] as List).add((ents['accounts'] as List).first);
      (ents['debts'] as List).add({
        'id': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee3',
        'debt_type': 'maybe',
        'person_name': '',
        'amount': 'NaN',
        'currency': 'SAR',
      });
      final res = BackupIntegrity.validateSnapshot(
          BackupIntegrity.sealSnapshot(s));
      expect(res.ok, isFalse);
      final codes = res.errors.map((e) => e.code).toSet();
      expect(codes, containsAll(['orphan', 'duplicate_id', 'bad_amount']));
    });

    test('canonical encoding is key-order stable', () {
      final a = {'z': 1, 'a': {'y': 2, 'b': 3}, 'm': [3, 2]};
      final b = {'m': [3, 2], 'a': {'b': 3, 'y': 2}, 'z': 1};
      expect(BackupIntegrity.canonicalJson(a),
          BackupIntegrity.canonicalJson(b));
    });

    test('migrate30to40 produces valid 4.0.0', () {
      final old = {
        'schema_version': '3.0.0',
        'created_at': '2026-01-01T00:00:00.000Z',
        'app_version': 'old',
        'backup_type': 'full_snapshot',
        'personal_bank_accounts': [
          {
            'id': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee1',
            'bank_name': 'Cash',
            'balance': 100,
            'currency': 'SAR'
          }
        ],
        'personal_finance': {
          'bank_accounts': [
            {
              'id': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee1',
              'bank_name': 'Cash',
              'balance': 100,
              'currency': 'SAR'
            }
          ],
          'transactions': [],
          'savings_goals': [],
          'debts': [],
          'budgets': [
            {
              'id': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee2',
              'name': 'Trip',
              'amount': 1000,
              'currency': 'SAR',
              'categories': [
                {'name': 'fly', 'amount': 300}
              ]
            }
          ],
          'recurring': [],
        },
        'shared_preferences': {
          'wallet_currency': 'SAR',
          'enabled_currencies_1': ['SAR', 'USD'],
        },
      };
      final migrated = BackupIntegrity.migrate30to40(
        Map<String, dynamic>.from(old),
        serverUserUuid: serverUuid,
        localUserId: uid,
        appVersion: 't',
      );
      expect(migrated['schema_version'], '4.0.0');
      final sealed = BackupIntegrity.sealSnapshot(migrated);
      final res = BackupIntegrity.validateSnapshot(sealed);
      expect(res.ok, isTrue,
          reason: res.errors.map((e) => e.code).join(','));
      final ents = sealed['entities'] as Map;
      expect((ents['budgets'] as List).single['total_amount'], '1000');
      expect(sealed['user_uuid'], serverUuid);
    });
  });

  group('snapshot builder', () {
    test('builds typed prefs incl StringList + entities with string money',
        () async {
      final svc = makeService();
      await seedRich(svc);
      final snap = await BackupSnapshotBuilder.build(
        localUserId: uid,
        serverUserUuid: serverUuid,
        appVersion: 't',
      );
      expect(snap['schema_version'], '4.0.0');
      expect(snap['user_uuid'], serverUuid);
      final prefs = snap['preferences'] as Map;
      expect(prefs['enabled_currencies_7101'], {
        'type': 'string-list',
        'value': ['YER_OLD', 'YER_NEW', 'SAR', 'USD']
      });
      final ents = snap['entities'] as Map;
      expect((ents['accounts'] as List).length, 3);
      final txs = ents['transactions'] as List;
      expect(txs.length, greaterThanOrEqualTo(4));
      for (final t in txs) {
        expect((t as Map)['amount'], isA<String>());
      }
      // Transfer legs preserved as two rows.
      final legs = txs
          .where((t) =>
              (t as Map)['category'] == 'تحويل' &&
              ((t['tx_type'] == 'transfer_out') ||
                  (t['tx_type'] == 'expense' &&
                      (t['description'] ?? '') == 'تحويل بين الحسابات')))
          .toList();
      expect(legs.length, greaterThanOrEqualTo(1));
      // Debt-derived payments present.
      expect((ents['debt_payments'] as List).length, greaterThanOrEqualTo(1));
      // Budget categories inside the single budget.
      final budgets = ents['budgets'] as List;
      expect(budgets.length, 1);
      expect(
          ((budgets.single as Map)['categories'] as List).length, 2);
      // writeUserPrefs round-trips StringList.
      final p = await SharedPreferences.getInstance();
      await p.remove('enabled_currencies_7101');
      await BackupSnapshotBuilder.writeUserPrefs(
          Map<String, dynamic>.from(prefs));
      expect(p.getStringList('enabled_currencies_7101'),
          ['YER_OLD', 'YER_NEW', 'SAR', 'USD']);
    });
  });

  group('device round-trip (mock native file)', () {
    Future<Map<String, dynamic>> fullCycle({bool mutate = true}) async {
      final bs = makeBackup();
      final svc = makeService();
      await seedRich(svc);
      final before = await fingerprintForSvc();
      final save = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(save.success, isTrue, reason: save.message);
      // Read back through the native mock (exact file bytes).
      final uri = save.fileUri!;
      final doc = await BackupService.readDocumentContent(uri);
      final content = (doc!['content'] as String?) ?? '';
      expect(content.isNotEmpty, isTrue);
      final read = await bs.readBackupContent(
        content,
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      expect(read.success, isTrue, reason: read.message);
      expect(read.validation!.authenticity, 'unverified');

      if (mutate) {
        // Change everything: add + delete rows.
        await svc.addTransaction(
          type: 'expense', amount: 1, category: 'x', currency: 'SAR',
          date: DateTime.utc(2026, 7, 1),
        );
        final debts = await svc.getDebts();
        for (final d in debts) {
          await svc.deleteDebt(d.id);
        }
      }
      final restored = await bs.restoreFromBackup(
        read.data!,
        userId: uid,
        serverUserUuid: serverUuid,
        skipServer: true,
      );
      expect(restored.success, isTrue, reason: restored.message);
      expect(restored.serverState, 'skipped');
      final after = await fingerprintForSvc();
      return {'before': before, 'after': after};
    }

    test('mutate + restore: snapshot rows exact, extras preserved, no dups',
        () async {
      final r = await fullCycle();
      final before = r['before'] as Map<String, dynamic>;
      final after = r['after'] as Map<String, dynamic>;
      expect(after.keys.toSet(), before.keys.toSet());
      for (final k in before.keys) {
        final beforeRows = (before[k] as List).cast<Map<String, dynamic>>();
        final afterRows =
            (after[k] as List).cast<Map<String, dynamic>>();
        final afterById = <String, Map<String, dynamic>>{};
        for (final row in afterRows) {
          final id = _fpKey(k, row);
          expect(afterById.containsKey(id), isFalse,
              reason: 'duplicate $k:$id');
          afterById[id] = row;
        }
        // Every snapshot row present with exact values.
        for (final row in beforeRows) {
          final id = _fpKey(k, row);
          expect(afterById.containsKey(id), isTrue,
              reason: 'missing $k:$id');
          expect(jsonEncode(afterById[id]), jsonEncode(row),
              reason: 'changed $k:$id');
        }
      }
      // The extra transaction added after backup still exists (no silent
      // delete), and the deleted debt came back from the backup.
      Map<String, dynamic> decodeRow(dynamic r) => Map<String, dynamic>.from(
          jsonDecode((r as Map)['data_json'] as String) as Map);
      final txs = (after['personal_entity_cache'] as List)
          .where((r) =>
              (r as Map)['entity_type'] == 'personal_transaction')
          .map(decodeRow)
          .toList();
      expect(txs.any((m) => m['category'] == 'x'), isTrue);
      final debts = (after['personal_entity_cache'] as List)
          .where((r) => (r as Map)['entity_type'] == 'personal_debt')
          .toList();
      expect(debts.length, 1);
    });

    test('same amount/date/bank, different IDs: both kept (no fuzzy merge)',
        () async {
      final bs = makeBackup();
      final svc = makeService();
      final ids = await seedRich(svc);
      final cash = ids['cash'] as String;
      for (var i = 0; i < 2; i++) {
        await svc.addTransaction(
          type: 'expense', amount: 250, category: 'food',
          description: 'twin', currency: 'SAR', accountId: cash,
          date: DateTime.utc(2026, 5, 10, 12, 0),
        );
      }
      final cache = PersonalCacheRepository();
      final twins = (await cache.getCollection(uid, 'personal_transaction'))
          .where((m) =>
              m['bank_account_id']?.toString() == cash &&
              (m['date']?.toString() ?? '').startsWith('2026-05-10'))
          .toList();
      expect(twins.length, 2);
      final t1 = twins[0]['id'].toString();
      final t2 = twins[1]['id'].toString();
      expect(t1 == t2, isFalse);
      final save = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(save.success, isTrue, reason: save.message);
      final doc = await BackupService.readDocumentContent(save.fileUri!);
      final read = await bs.readBackupContent(
        (doc!['content'] as String?) ?? '',
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      final res = await bs.restoreFromBackup(
        read.data!,
        userId: uid,
        serverUserUuid: serverUuid,
        skipServer: true,
      );
      expect(res.success, isTrue, reason: res.message);
      final rows = await cache.getCollection(uid, 'personal_transaction');
      final matches = rows
          .where((m) =>
              m['bank_account_id']?.toString() == cash &&
              (m['date']?.toString() ?? '').startsWith('2026-05-10'))
          .toList();
      expect(matches.map((m) => m['id']).toSet(), containsAll([t1, t2]));
    });

    test('same ID present locally is updated, never duplicated', () async {
      final bs = makeBackup();
      final svc = makeService();
      await seedRich(svc);
      final save = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      final doc = await BackupService.readDocumentContent(save.fileUri!);
      final read = await bs.readBackupContent(
        (doc!['content'] as String?) ?? '',
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      // Corrupt one local row's amount, then restore: value returns, no dup.
      final cache = PersonalCacheRepository();
      final txs = await cache.getCollection(uid, 'personal_transaction');
      final victim = Map<String, dynamic>.from(txs.first);
      final before = await fingerprintForSvc();
      final beforeCount =
          (before['personal_entity_cache'] as List).length;
      await (await testLedger()).rawUpdate(
        'UPDATE personal_entity_cache SET data_json = ? '
        'WHERE user_id = ? AND entity_type = ? AND remote_id = ?',
        [
          jsonEncode({...victim, 'amount': 999999.0}),
          uid,
          'personal_transaction',
          victim['id'],
        ],
      );
      final res = await bs.restoreFromBackup(
        read.data!,
        userId: uid,
        serverUserUuid: serverUuid,
        skipServer: true,
      );
      expect(res.success, isTrue, reason: res.message);
      final after = await cache.getCollection(uid, 'personal_transaction');
      expect(after.length, txs.length);
      final fixed = after.firstWhere((m) => m['id'] == victim['id']);
      expect(fixed['amount'], victim['amount']);
      final afterFp = await fingerprintForSvc();
      expect((afterFp['personal_entity_cache'] as List).length,
          beforeCount);
    });

    test('reset then restore returns exact state', () async {
      final bs = makeBackup();
      final svc = makeService();
      await seedRich(svc);
      final before = await fingerprintForSvc();
      final save = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(save.success, isTrue);
      // Simulate full local reset of personal tables.
      for (final t in BackupService.restoreTables) {
        try {
          await _wipeTable(t);
        } catch (_) {}
      }
      final wiped = await fingerprintForSvc();
      for (final k in wiped.keys) {
        expect((wiped[k] as List), isEmpty, reason: 'table $k wiped');
      }
      final doc = await BackupService.readDocumentContent(save.fileUri!);
      final read = await bs.readBackupContent(
        (doc!['content'] as String?) ?? '',
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      expect(read.success, isTrue);
      final restored = await bs.restoreFromBackup(
        read.data!,
        userId: uid,
        serverUserUuid: serverUuid,
        skipServer: true,
      );
      expect(restored.success, isTrue, reason: restored.message);
      final after = await fingerprintForSvc();
      for (final k in before.keys) {
        expect(jsonEncode(after[k]), jsonEncode(before[k]), reason: 'table $k');
      }
    });

    test('repeated restore is identical', () async {
      final bs = makeBackup();
      final svc = makeService();
      await seedRich(svc);
      final save = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      final doc = await BackupService.readDocumentContent(save.fileUri!);
      final read = await bs.readBackupContent(
        (doc!['content'] as String?) ?? '',
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      final r1 = await bs.restoreFromBackup(read.data!,
          userId: uid, serverUserUuid: serverUuid, skipServer: true);
      final mid = await fingerprintForSvc();
      final r2 = await bs.restoreFromBackup(read.data!,
          userId: uid, serverUserUuid: serverUuid, skipServer: true);
      final after = await fingerprintForSvc();
      expect(r1.success && r2.success, isTrue);
      expect(jsonEncode(after), jsonEncode(mid));
    });

    test('corrupted file refused, DB untouched', () async {
      final bs = makeBackup();
      final svc = makeService();
      await seedRich(svc);
      final before = await fingerprintForSvc();
      final read = await bs.readBackupContent('{broken json');
      expect(read.success, isFalse);
      final after = await fingerprintForSvc();
      expect(jsonEncode(after), jsonEncode(before));
    });

    test('unknown schema refused, DB untouched', () async {
      final bs = makeBackup();
      final svc = makeService();
      await seedRich(svc);
      final before = await fingerprintForSvc();
      final read = await bs.readBackupContent(jsonEncode({
        'schema_version': '9.9.9',
        'created_at': DateTime.now().toIso8601String(),
        'counts': {},
        'tables': {},
        'entities': {},
      }));
      expect(read.success, isFalse);
      final after = await fingerprintForSvc();
      expect(jsonEncode(after), jsonEncode(before));
    });

    test('foreign-user snapshot refused', () async {
      final bs = makeBackup();
      final svc = makeService();
      await seedRich(svc);
      final save = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      final doc = await BackupService.readDocumentContent(save.fileUri!);
      final read = await bs.readBackupContent(
        (doc!['content'] as String?) ?? '',
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      final res = await bs.restoreFromBackup(
        read.data!,
        userId: uid,
        serverUserUuid: 'other-user-uuid',
      );
      expect(res.success, isFalse);
    });

    test('empty database is never written over a backup', () async {
      final bs = makeBackup();
      // No data at all: save must refuse instead of writing an empty file.
      final save = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(save.success, isFalse);
      expect(nativeFiles, isEmpty);
    });

    test('concurrent save + auto-backup never corrupts the file', () async {
      final bs = makeBackup();
      final svc = makeService();
      await seedRich(svc);
      final first = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(first.success, isTrue);
      await BackupService.setAutoSyncEnabled(true);
      final results = await Future.wait([
        bs.saveBackup(localUserId: uid, serverUserUuid: serverUuid),
        bs.autoSync(localUserId: uid, serverUserUuid: serverUuid),
      ]);
      // Exactly one wins; the other reports busy/failure — both honest.
      expect(results.where((r) => r.success).length, 1);
      final uri = await BackupService.getSavedUri();
      expect(uri, isNotNull);
      final doc = await BackupService.readDocumentContent(uri!);
      final content = (doc!['content'] as String?) ?? '';
      final read = await bs.readBackupContent(
        content,
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      expect(read.success, isTrue, reason: read.message);
      await BackupService.setAutoSyncEnabled(false);
    });

    test('failed native write keeps the previous backup intact', () async {
      final bs = makeBackup();
      final svc = makeService();
      await seedRich(svc);
      final first = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(first.success, isTrue);
      final doc = await BackupService.readDocumentContent(first.fileUri!);
      final goodContent = (doc!['content'] as String?) ?? '';
      nativeFailNextWrite = true;
      final failed = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(failed.success, isFalse);
      final stillThere =
          await BackupService.readDocumentContent(first.fileUri!);
      expect((stillThere!['content'] as String?) ?? '', goodContent);
    });

    test('reset present: auto-backup skips, restore still works', () async {
      final bs = makeBackup();
      final svc = makeService();
      await seedRich(svc);
      final first = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(first.success, isTrue);
      // Simulate full reset with the backup file present.
      for (final t in BackupService.restoreTables) {
        try {
          await _wipeTable(t);
        } catch (_) {}
      }
      await BackupService.setAutoSyncEnabled(true);
      final skipped = await bs.autoSync(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(skipped.success, isTrue);
      final doc = await BackupService.readDocumentContent(first.fileUri!);
      final read = await bs.readBackupContent(
        (doc!['content'] as String?) ?? '',
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      expect(read.success, isTrue, reason: read.message);
      final res = await bs.restoreFromBackup(
        read.data!,
        userId: uid,
        serverUserUuid: serverUuid,
        skipServer: true,
      );
      expect(res.success, isTrue, reason: res.message);
      final rows =
          await PersonalCacheRepository().getCollection(uid, 'personal_bank_account');
      expect(rows.length, 3);
      await BackupService.setAutoSyncEnabled(false);
    });

    test('auto-backup skips decreased rows, manual save writes', () async {
      final bs = makeBackup();
      final svc = makeService();
      await seedRich(svc);
      final first = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(first.success, isTrue);
      final firstContent =
          (await BackupService.readDocumentContent(first.fileUri!))!['content'];
      // Simulate reset: wipe personal tables.
      for (final t in BackupService.restoreTables) {
        try {
          await _wipeTable(t);
        } catch (_) {}
      }
      await BackupService.setAutoSyncEnabled(true);
      final skipped = await bs.autoSync(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(skipped.success, isTrue);
      final stillThere =
          (await BackupService.readDocumentContent(first.fileUri!))!['content'];
      expect(stillThere, firstContent);
      await BackupService.setAutoSyncEnabled(false);
    });
  });

  group('merge + rotation + identity', () {
    Future<void> insertMirrorBank({
      required String remoteId,
      required String name,
      required String currency,
      required double balance,
    }) async {
      await (await testLedger()).rawInsert(
        'INSERT OR REPLACE INTO personal_entity_cache '
        '(user_id, entity_type, remote_id, data_json, updated_at) '
        'VALUES (?, ?, ?, ?, ?)',
        [
          uid,
          'personal_bank_account',
          remoteId,
          jsonEncode({
            'id': remoteId,
            'bank_name': name,
            'currency': currency,
            'balance': balance,
          }),
          DateTime.now().toIso8601String(),
        ],
      );
    }

    Future<List<Map<String, dynamic>>> mirrorBanks() =>
        PersonalCacheRepository()
            .getCollection(uid, 'personal_bank_account');

    test('cash stub merges: one row, snapshot values, txs remapped',
        () async {
      final bs = makeBackup();
      final svc = makeService();
      await seedRich(svc);
      final save = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(save.success, isTrue, reason: save.message);
      // Simulate post-reset stub: same logical cash, fresh UUID, zero.
      const stubId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee1';
      await (await testLedger()).rawDelete(
          'DELETE FROM personal_entity_cache WHERE user_id = ? AND entity_type = ?',
          [uid, 'personal_bank_account']);
      await insertMirrorBank(
          remoteId: stubId,
          name: 'Cash Old',
          currency: 'YER_OLD',
          balance: 0);
      final doc = await BackupService.readDocumentContent(save.fileUri!);
      final read = await bs.readBackupContent(
        (doc!['content'] as String?) ?? '',
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      final res = await bs.restoreFromBackup(
        read.data!,
        userId: uid,
        serverUserUuid: serverUuid,
        skipServer: true,
      );
      expect(res.success, isTrue, reason: res.message);
      expect(res.mergedAccounts, 1);
      final snapAccs =
          ((read.data!['entities'] as Map)['accounts'] as List)
              .cast<Map<String, dynamic>>();
      final snapCash = snapAccs.firstWhere((m) =>
          m['bank_name'] == 'Cash Old' && m['currency'] == 'YER_OLD');
      final banks = await mirrorBanks();
      final cashOld = banks
          .where((m) =>
              m['bank_name'] == 'Cash Old' && m['currency'] == 'YER_OLD')
          .toList();
      expect(cashOld.length, 1);
      expect(cashOld.single['id'], stubId);
      expect(cashOld.single['balance'].toString(),
          snapCash['balance'].toString());
      // No duplicate rows overall for the three seeded accounts.
      expect(banks.length, 3);
      // Transactions that pointed at the old snapshot id now point
      // at the survivor.
      final txs = await PersonalCacheRepository()
          .getCollection(uid, 'personal_transaction');
      final oldSnapId = (read.data!['entities'] as Map)['accounts'][0]['id'];
      expect(
          txs.any((m) => m['bank_account_id'] == oldSnapId), isFalse);
    });

    test('Bank A USD/SAR + Bank B USD: no duplication, no loss', () async {
      final bs = makeBackup();
      final svc = makeService();
      for (final spec in [
        ['Bank A', 'USD', 10.0],
        ['Bank A', 'SAR', 20.0],
        ['Bank B', 'USD', 30.0],
      ]) {
        await svc.addBankAccount(
          bankName: spec[0] as String,
          currency: spec[1] as String,
          openingBalance: (spec[2] as num).toDouble(),
        );
      }
      final save = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(save.success, isTrue, reason: save.message);
      // Simulate reset stubs with fresh UUIDs.
      await (await testLedger()).rawDelete(
          'DELETE FROM personal_entity_cache WHERE user_id = ? AND entity_type = ?',
          [uid, 'personal_bank_account']);
      const stubs = ['s1-1111-1111-1111-111111111111',
          's2-2222-2222-2222-222222222222',
          's3-3333-3333-3333-333333333333'];
      final specs = [
        ['Bank A', 'USD', 0.0],
        ['Bank A', 'SAR', 0.0],
        ['Bank B', 'USD', 0.0],
      ];
      for (var i = 0; i < 3; i++) {
        await insertMirrorBank(
          remoteId: stubs[i],
          name: specs[i][0] as String,
          currency: specs[i][1] as String,
          balance: (specs[i][2] as num).toDouble(),
        );
      }
      final doc = await BackupService.readDocumentContent(save.fileUri!);
      final read = await bs.readBackupContent(
        (doc!['content'] as String?) ?? '',
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      final res = await bs.restoreFromBackup(
        read.data!,
        userId: uid,
        serverUserUuid: serverUuid,
        skipServer: true,
      );
      expect(res.success, isTrue, reason: res.message);
      expect(res.mergedAccounts, 3);
      final banks = await mirrorBanks();
      expect(banks.length, 3);
      Map<String, dynamic> by(String n, String c) => banks.firstWhere((m) =>
          m['bank_name'] == n && m['currency'] == c);
      expect(by('Bank A', 'USD')['balance'], 10.0);
      expect(by('Bank A', 'SAR')['balance'], 20.0);
      expect(by('Bank B', 'USD')['balance'], 30.0);
    });

    test('manual save overwrites the newest version, others untouched',
        () async {
      final bs = makeBackup();
      final svc = makeService();
      await seedRich(svc);
      final v1 = await bs.createDeviceBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      final v2 = await bs.createDeviceBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(v1.success && v2.success, isTrue);
      expect(await BackupService.getSavedUri(), v2.fileUri);
      // New data since v2.
      await svc.addTransaction(
        type: 'income', amount: 777, category: 'bonus', currency: 'SAR',
        date: DateTime.utc(2026, 7, 3),
      );
      // Manual-save path: resolve newest, overwrite it in place.
      final target = await BackupService.resolveLatestDeviceUri();
      expect(target, v2.fileUri);
      final manual = await bs.overwriteLatestBackup(
          uri: target!,
          localUserId: uid,
          serverUserUuid: serverUuid);
      expect(manual.success, isTrue, reason: manual.message);
      // Same two files; v1 bytes identical; v2 carries the new data; the
      // tracked uri never moved.
      expect(nativeFiles.length, 2);
      final v1doc = await BackupService.readDocumentContent(v1.fileUri!);
      final v2doc = await BackupService.readDocumentContent(v2.fileUri!);
      // Amounts serialize as exact strings ("777.0"); v1 must not have it.
      final key = SecretKey(List.filled(32, 3));
      final v1plain = await BackupEnvelope.openText(v1doc!['content'] as String, key);
      final v2plain = await BackupEnvelope.openText(v2doc!['content'] as String, key);
      expect(v1plain.contains('"amount": "777.0"'),
          isFalse,
          reason: 'older versions are never touched');
      expect(v2plain.contains('"amount": "777.0"'),
          isTrue,
          reason: 'newest version carries the fresh data');
      expect(await BackupService.getSavedUri(), v2.fileUri);
    });

    test('divergent category ids merge onto live rows, never duplicate',
        () async {
      final bs = makeBackup();
      final svc = makeService();
      await seedRich(svc);
      // Snapshot with the original category ids.
      final snap = await bs.buildSnapshot(
        localUserId: uid,
        serverUserUuid: serverUuid,
      );
      // Simulate a recreated budget: same names, fresh UUIDs in the mirror.
      final cache = PersonalCacheRepository();
      const freshFlight = '11111111-1111-4111-8111-111111111111';
      const freshStay = '22222222-2222-4222-8222-222222222222';
      final budgets = await cache.getCollection(uid, 'personal_budget');
      expect(budgets.length, 1);
      final live = Map<String, dynamic>.from(budgets.single);
      final liveCats = (live['categories'] as List)
          .map((c) => Map<String, dynamic>.from(c as Map))
          .toList();
      expect(liveCats.length, 2);
      liveCats[0]['id'] = freshFlight;
      liveCats[1]['id'] = freshStay;
      live['categories'] = liveCats;
      await cache.upsertItem(
          uid, 'personal_budget', live['id'].toString(), live);
      final read = await bs.readBackupContent(
        const JsonEncoder.withIndent('  ').convert(snap),
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      expect(read.success, isTrue, reason: read.message);
      final res = await bs.restoreFromBackup(
        read.data!,
        userId: uid,
        serverUserUuid: serverUuid,
        skipServer: true,
      );
      expect(res.success, isTrue, reason: res.message);
      // Exactly one row per category name, carrying the SNAPSHOT ids —
      // nothing duplicated, repeat restores stay identical.
      Future<List<Map<String, dynamic>>> liveCatRows() async {
        final all = await cache.getCollection(uid, 'personal_budget');
        expect(all.length, 1);
        return (all.single['categories'] as List)
            .map((c) => Map<String, dynamic>.from(c as Map))
            .toList();
      }

      var cats = await liveCatRows();
      expect(cats.length, 2);
      expect(cats.map((c) => c['name']).toSet(), {'flights', 'stay'});
      // Every transaction category link resolves to a live row.
      final txs = await cache.getCollection(uid, 'personal_transaction');
      final catIds = cats.map((c) => c['id'].toString()).toSet();
      for (final t in txs) {
        final cid = (t['budget_category_id'] ?? '').toString();
        if (cid.isNotEmpty) expect(catIds.contains(cid), isTrue);
      }
      final r2 = await bs.restoreFromBackup(
        read.data!,
        userId: uid,
        serverUserUuid: serverUuid,
        skipServer: true,
      );
      expect(r2.success, isTrue);
      cats = await liveCatRows();
      expect(cats.length, 2);
    });

    test('fixed file is overwritten in place (no rotation, no collision)',
        () async {
      final bs = makeBackup();
      final svc = makeService();
      await seedRich(svc);
      final first = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(first.success, isTrue);
      final firstUri = first.fileUri!;
      await svc.addTransaction(
        type: 'income', amount: 7, category: 'x', currency: 'SAR',
        date: DateTime.utc(2026, 7, 2),
      );
      final second = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(second.success, isTrue);
      // Same URI (bytes overwritten in place — a stale same-name row can
      // never break the insert), still exactly one file, prefs unchanged.
      expect(second.fileUri, firstUri);
      expect(nativeFiles.containsKey(firstUri), isTrue);
      expect(nativeFiles.length, 1);
      expect(await BackupService.getSavedUri(), firstUri);
      final doc = await BackupService.readDocumentContent(firstUri);
      final read = await bs.readBackupContent(
        (doc!['content'] as String?) ?? '',
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      expect(read.success, isTrue, reason: read.message);
    });

    test('safety backup uses distinct name and spares the main file',
        () async {
      final bs = makeBackup();
      final svc = makeService();
      await seedRich(svc);
      final main = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      final mainContent =
          (await BackupService.readDocumentContent(main.fileUri!))!['content'];
      final s1 = await bs.saveSafetyBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      final s2 = await bs.saveSafetyBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      final s3 = await bs.saveSafetyBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(s1.success && s2.success && s3.success, isTrue);
      // Main file untouched, saved URI still points at it.
      final stillMain =
          (await BackupService.readDocumentContent(main.fileUri!))!['content'];
      expect(stillMain, mainContent);
      expect(await BackupService.getSavedUri(), main.fileUri);
      // Pruned to the latest 2 safety files + main file.
      final safetyCount = nativeNames.values
          .where((n) => n.startsWith('FYONA_ERP_Backup_safety_'))
          .length;
      expect(safetyCount, 2);
      expect(nativeFiles.length, 3);
    });

    test('unbound identity refuses loudly', () async {
      final bare = BackupService(
        financeService: makeService(),
        apiClient: ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9'))),
      );
      final res = await bare.saveBackup();
      expect(res.success, isFalse);
      expect(res.message, 'backupErrNoIdentity');
    });

    test('pending superseded converges instead of clearing silently',
        () async {
      PersonalLocalMode.serverDeclined = true; // a server keeping Personal data
      addTearDown(() => PersonalLocalMode.serverDeclined = false);
      final bs = makeBackup(dio: serverDio(online: false));
      final svc = makeService();
      await seedRich(svc);
      final save = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      final doc = await BackupService.readDocumentContent(save.fileUri!);
      final read = await bs.readBackupContent(
        (doc!['content'] as String?) ?? '',
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      final res = await bs.restoreFromBackup(
        read.data!,
        userId: uid,
        serverUserUuid: serverUuid,
      );
      expect(res.success, isTrue);
      expect(res.serverState, 'pending_offline');
      // File rotates (new snapshot supersedes the pending one).
      await svc.addTransaction(
        type: 'income', amount: 7, category: 'x', currency: 'SAR',
        date: DateTime.utc(2026, 7, 2),
      );
      final save2 = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(save2.success, isTrue);
      // Retry converges with the CURRENT file instead of dropping intent.
      final bs2 = makeBackup(dio: serverDio(online: true));
      final done = await bs2.completePendingServerRestore();
      expect(done, isTrue);
      expect(await BackupService.getPendingServerRestore(), isNull);
    });

    test('auto-backup fires after budget writes (DB hook)', () async {
      final bs = makeBackup();
      bs.bindIdentity(localUserId: uid, serverUserUuid: serverUuid);
      final svc = makeService();
      await seedRich(svc);
      final first = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(first.success, isTrue);
      await BackupService.setAutoSyncEnabled(true);
      await svc.addBudget(PersonalBudget(
        id: '',
        name: 'AutoCover',
        totalAmount: 500,
        currency: 'SAR',
      ));
      await Future<void>.delayed(const Duration(seconds: 3));
      final uri = await BackupService.getSavedUri();
      final doc = await BackupService.readDocumentContent(uri!);
      final content = await BackupEnvelope.openText((doc!['content'] as String?) ?? '', SecretKey(List.filled(32, 3)));
      expect(content.contains('AutoCover'), isTrue);
      await BackupService.setAutoSyncEnabled(false);
    });

    test('reinstall discovery: prefs gone, file still found+valid',
        () async {
      final bs = makeBackup();
      final svc = makeService();
      await seedRich(svc);
      final save = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(save.success, isTrue);
      // Simulate reinstall: all prefs (incl. saved URI) wiped.
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      final files = await BackupService.listBackups();
      expect(files.isNotEmpty, isTrue);
      final doc = await BackupService.readDocumentContent(files.first.uri);
      final content = (doc!['content'] as String?) ?? '';
      final read = await bs.readBackupContent(
        content,
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      expect(read.success, isTrue, reason: read.message);
      // No cached HMAC key after reinstall: valid but unverified.
      expect(read.validation!.authenticity, 'unverified');
    });
  });

  group('server paths (intercepted Dio)', () {
    // These model a server that still keeps Personal data (not a
    // device-only Personal server): the backup's server layer applies.
    setUp(() => PersonalLocalMode.serverDeclined = true);
    tearDown(() => PersonalLocalMode.serverDeclined = false);
    test('offline upload fails explicitly, nothing stored', () async {
      final bs = makeBackup(dio: serverDio(online: false));
      final res = await bs.uploadServerBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(res.success, isFalse);
      final last = await BackupService.getLastServerBackup();
      expect(last, isNull);
    });

    test('online upload stores version metadata', () async {
      final bs = makeBackup(dio: serverDio(online: true));
      final svc = makeService();
      await seedRich(svc);
      final res = await bs.uploadServerBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(res.success, isTrue, reason: res.message);
      expect(res.meta?['version'], 3);
      final last = await BackupService.getLastServerBackup();
      expect(last?['version'], 3);
    });

    test('server restore verified end-to-end (mock)', () async {
      final Map<String, dynamic> reply = {
        'expected': <String, dynamic>{
          'accounts': 3,
          'transactions': 4,
          'goals': 1,
          'debts': 1,
          'debt_payments': 1,
          'budgets': 1,
          'recurring': 1,
          'budget_categories': 2
        },
      };
      reply['restored'] = Map<String, dynamic>.from(
          reply['expected'] as Map<String, dynamic>);
      final bs = makeBackup(
          dio: serverDio(online: true, restoreReply: {
            ...reply,
            'verified': true,
          }));
      final svc = makeService();
      await seedRich(svc);
      await svc.addTransaction(
        type: 'expense', amount: 1, category: 'x', currency: 'SAR',
        date: DateTime.utc(2026, 7, 1),
      );
      final save = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(save.success, isTrue);
      final doc = await BackupService.readDocumentContent(save.fileUri!);
      final read = await bs.readBackupContent(
        (doc!['content'] as String?) ?? '',
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      expect(read.success, isTrue);
      final before = await fingerprintForSvc();
      final res = await bs.restoreFromBackup(
        read.data!,
        userId: uid,
        serverUserUuid: serverUuid,
      );
      expect(res.success, isTrue, reason: res.message);
      expect(res.serverState, 'verified');
      final after = await fingerprintForSvc();
      expect(jsonEncode(after), jsonEncode(before));
    });

    test('server failure keeps local restore + pending + safe retry',
        () async {
      // First attempt: server layer fails (unverified reply).
      final failing = makeBackup(
          dio: serverDio(online: true, restoreReply: {
            'expected': {'accounts': 1},
            'restored': {'accounts': 0},
            'verified': false,
          }));
      final svc = makeService();
      await seedRich(svc);
      final save = await failing.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      final doc = await BackupService.readDocumentContent(save.fileUri!);
      final read = await failing.readBackupContent(
        (doc!['content'] as String?) ?? '',
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      final before = await fingerprintForSvc();
      final partial = await failing.restoreFromBackup(
        read.data!,
        userId: uid,
        serverUserUuid: serverUuid,
      );
      // Local layer applied and verified; server layer failed loudly.
      expect(partial.success, isTrue, reason: partial.message);
      expect(partial.serverState, 'failed');
      expect(partial.checks, containsAll(['data', 'relations']));
      expect(await BackupService.getPendingServerRestore(), isNotNull);
      final mid = await fingerprintForSvc();
      // Snapshot rows exact (extras allowed, none here).
      for (final k in before.keys) {
        final bRows = (before[k] as List).cast<Map<String, dynamic>>();
        final mRows =
            (mid[k] as List).cast<Map<String, dynamic>>();
        final mById = <String, Map<String, dynamic>>{};
        for (final r in mRows) {
          mById[r['id']?.toString() ?? '${r['entity_type']}:${r['remote_id']}'] =
              r;
        }
        for (final r in bRows) {
          final id = r['id']?.toString() ??
              '${r['entity_type']}:${r['remote_id']}';
          expect(mById.containsKey(id), isTrue, reason: '$k:$id');
        }
      }
      // Retry with a healthy server completes without duplicating.
      final healthy = makeBackup(dio: serverDio(online: true));
      final retried = await healthy.completePendingServerRestore();
      expect(retried, isTrue);
      expect(await BackupService.getPendingServerRestore(), isNull);
      final txs = await PersonalCacheRepository()
          .getCollection(uid, 'personal_transaction');
      final ids = txs.map((m) => m['id'].toString()).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('old server without key route restores locally, no blind POST',
        () async {
      var bulkCalled = false;
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9'));
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.endsWith('/backups/key')) {
            handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response(
                  requestOptions: options, statusCode: 404, data: {}),
            ));
            return;
          }
          if (options.path.endsWith('/personal/finance/restore')) {
            bulkCalled = true;
          }
          handler.reject(DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          ));
        },
      ));
      final bs = makeBackup(dio: dio);
      final svc = makeService();
      await seedRich(svc);
      final save = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      final doc = await BackupService.readDocumentContent(save.fileUri!);
      final read = await bs.readBackupContent(
        (doc!['content'] as String?) ?? '',
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      final res = await bs.restoreFromBackup(
        read.data!,
        userId: uid,
        serverUserUuid: serverUuid,
      );
      expect(res.success, isTrue, reason: res.message);
      expect(res.serverState, 'unsupported');
      expect(bulkCalled, isFalse);
    });

    test('unverified server reply: local verified, server failed+pending',
        () async {
      final bs = makeBackup(
          dio: serverDio(online: true, restoreReply: {
            'expected': {'accounts': 3},
            'restored': {'accounts': 1},
            'verified': false,
          }));
      final svc = makeService();
      await seedRich(svc);
      final save = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      final doc = await BackupService.readDocumentContent(save.fileUri!);
      final read = await bs.readBackupContent(
        (doc!['content'] as String?) ?? '',
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      final before = await fingerprintForSvc();
      final res = await bs.restoreFromBackup(
        read.data!,
        userId: uid,
        serverUserUuid: serverUuid,
      );
      // Local layer verified; server layer failed loudly with safe retry.
      expect(res.success, isTrue, reason: res.message);
      expect(res.serverState, 'failed');
      expect(res.checks, containsAll(['data', 'relations']));
      expect(res.checks, isNot(contains('server')));
      expect(await BackupService.getPendingServerRestore(), isNotNull);
      // Snapshot rows exact locally (extras allowed, none here).
      final after = await fingerprintForSvc();
      for (final k in before.keys) {
        final bRows = (before[k] as List).cast<Map<String, dynamic>>();
        final aRows =
            (after[k] as List).cast<Map<String, dynamic>>();
        expect(aRows.length, bRows.length, reason: 'table $k');
      }
    });

    test('offline restore defers server layer, stays pending', () async {
      final bs = makeBackup(dio: serverDio(online: false));
      final svc = makeService();
      await seedRich(svc);
      final save = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      await svc.addTransaction(
        type: 'expense', amount: 1, category: 'x', currency: 'SAR',
        date: DateTime.utc(2026, 7, 1),
      );
      final doc = await BackupService.readDocumentContent(save.fileUri!);
      final read = await bs.readBackupContent(
        (doc!['content'] as String?) ?? '',
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      final res = await bs.restoreFromBackup(
        read.data!,
        userId: uid,
        serverUserUuid: serverUuid,
      );
      expect(res.success, isTrue, reason: res.message);
      expect(res.serverState, 'pending_offline');
      expect(await BackupService.getPendingServerRestore(), isNotNull);
    });
  });

  group('scale', () {
    test(
        '10k transactions snapshot + validate in reasonable time',
        () async {
      final svc = makeService();
      await svc.addBankAccount(
          bankName: 'Scale', currency: 'SAR', openingBalance: 1000000);
      final banks = await svc.getBankAccounts();
      final accId = banks.firstWhere((b) => b.bankName == 'Scale').id;
      final cache = PersonalCacheRepository();
      final now = DateTime.now().toIso8601String();
      await (await testLedger()).transaction((tx) async {
        for (var i = 0; i < 10000; i++) {
          final id = BackupIntegrity.newUuid();
          await tx.rawInsert(
            'INSERT OR REPLACE INTO personal_entity_cache '
            '(user_id, entity_type, remote_id, data_json, updated_at) '
            'VALUES (?, ?, ?, ?, ?)',
            [
              uid,
              'personal_transaction',
              id,
              jsonEncode({
                'id': id,
                'tx_type': i.isEven ? 'expense' : 'income',
                'amount': (i % 1000) + 0.99,
                'currency': const ['SAR', 'USD', 'YER_OLD', 'YER_NEW'][i % 4],
                'category': 'cat${i % 50}',
                'description': 'bulk $i',
                'bank_account_id': accId,
                'date': now,
              }),
              now,
            ],
          );
        }
      });
      final sw = Stopwatch()..start();
      final bs = makeBackup();
      final save = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(save.success, isTrue, reason: save.message);
      expect(sw.elapsed.inSeconds, lessThan(120));
      final doc = await BackupService.readDocumentContent(save.fileUri!);
      final read = await bs.readBackupContent(
        (doc!['content'] as String?) ?? '',
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      expect(read.success, isTrue, reason: read.message);
      final ents = read.data!['entities'] as Map;
      expect((ents['transactions'] as List).length, 10000);
      // Wipe only transactions, restore, compare counts back.
      await (await testLedger()).rawDelete(
          "DELETE FROM personal_entity_cache WHERE user_id = ? AND entity_type = 'personal_transaction'",
          [uid]);
      final res = await bs.restoreFromBackup(
        read.data!,
        userId: uid,
        serverUserUuid: serverUuid,
        skipServer: true,
      );
      expect(res.success, isTrue, reason: res.message);
      final rows = await cache.getCollection(uid, 'personal_transaction');
      expect(rows.length, 10000);
    }, timeout: const Timeout(Duration(minutes: 4)));
  });

  group('golden round-trip (strict equality)', () {
    // These model a server that still keeps Personal data (not a
    // device-only Personal server): the backup's server layer applies.
    setUp(() => PersonalLocalMode.serverDeclined = true);
    tearDown(() => PersonalLocalMode.serverDeclined = false);
    /// Seeds EVERYTHING the runtime depends on: mirror entities with real
    /// links across 6 currencies, raw legacy rows, prefs (typed), trees,
    /// uploads. Returns stable ids for assertions.
    Future<Map<String, String>> seedGolden(PersonalFinanceService svc) async {
      final ids = <String, String>{};
      // Banks: cash row per currency bucket + named banks.
      const banks = [
        ['Cash', 'USD', 100.0],
        ['Cash', 'SAR', 200.0],
        ['Cash', 'OMR', 300.0],
        ['Cash', 'YER_OLD', 400.0],
        ['Cash', 'YER_NEW', 500.0],
        ['Cash', 'EUR', 600.0],
        ['Bank A', 'USD', 1000.0],
        ['Bank A', 'SAR', 2000.0],
        ['Bank B', 'USD', 3000.0],
      ];
      for (var i = 0; i < banks.length; i++) {
        await svc.addBankAccount(
          bankName: banks[i][0] as String,
          currency: banks[i][1] as String,
          openingBalance: (banks[i][2] as num).toDouble(),
        );
      }
      final allBanks = await svc.getBankAccounts();
      PersonalBankAccount by(String n, String c) => allBanks.firstWhere(
          (b) => b.bankName == n && b.currency == c);
      ids['cashUSD'] = by('Cash', 'USD').id;
      ids['bankAUSD'] = by('Bank A', 'USD').id;

      // Goal + contribution (linked tx).
      await svc.addSavingsGoal(SavingsGoal(
        id: '',
        name: 'Car',
        targetAmount: 20000,
        currency: 'SAR',
        deadline: '2027-06-01',
      ));
      final goal =
          (await svc.getSavingsGoals()).firstWhere((g) => g.name == 'Car');
      ids['goal'] = goal.id;
      await svc.contributeToGoal(
        goal.id,
        1500,
        description: 'first',
        currency: 'SAR',
        bankAccountId: ids['cashUSD']!,
      );

      // Debt (owed to me) + payment in another currency + due date/time.
      await svc.addDebt(PersonalDebt(
        id: '',
        type: 'receivable',
        personName: 'Ali',
        amount: 1000000,
        currency: 'YER_OLD',
        dueDate: DateTime.utc(2026, 11, 23, 12, 0, 0),
      ));
      final debt =
          (await svc.getDebts()).firstWhere((d) => d.personName == 'Ali');
      ids['debt'] = debt.id;
      await svc.payDebt(
        debt.id,
        50000.25,
        DateTime.utc(2026, 6, 1, 18, 45, 10),
        currency: 'YER_OLD',
      );

      // Budget with categories incl. goal/debt links.
      await svc.addBudget(PersonalBudget(
        id: '',
        name: 'Trip',
        totalAmount: 1000000,
        currency: 'SAR',
        categories: [
          BudgetCategory(
              id: '',
              name: 'flights',
              type: 'expense',
              allocatedAmount: 300000,
              currency: 'SAR'),
          BudgetCategory(
              id: '',
              name: 'stay',
              type: 'expense',
              allocatedAmount: 100000,
              currency: 'SAR',
              goalId: goal.id,
              debtId: debt.id),
        ],
      ));
      final budgets = await svc.getAllBudgets();
      final trip = budgets.firstWhere((b) => b.name == 'Trip');
      ids['budget'] = trip.id;
      ids['catFly'] = trip.categories
          .firstWhere((c) => c.name == 'flights')
          .id;

      // Transaction linked to goal + budget + category.
      await svc.addTransaction(
        type: 'expense',
        amount: 250.75,
        category: 'travel',
        description: 'tickets',
        currency: 'EUR',
        accountId: by('Bank A', 'USD').id,
        goalId: goal.id,
        budgetId: trip.id,
        budgetCategoryId: ids['catFly']!,
        date: DateTime.utc(2026, 4, 5, 14, 30, 45),
      );
      // Transfer pair (two legs, distinct UUIDs).
      await svc.transferBetweenAccounts(
        fromId: by('Bank A', 'USD').id,
        toId: by('Bank B', 'USD').id,
        amount: 100,
        fromCurrency: 'USD',
        toCurrency: 'USD',
        rate: 1,
      );

      // Recurring with full schedule.
      await svc.addRecurring(RecurringTransaction(
        id: '',
        name: 'Rent',
        type: 'expense',
        amount: 1500,
        category: 'rent',
        description: 'monthly',
        frequency: 'monthly',
        intervalValue: 1,
        nextDate: DateTime.utc(2026, 10, 1, 9, 0, 0),
        bankAccountId: by('Bank A', 'SAR').id,
        currency: 'SAR',
        accountType: 'fixed',
        executionType: 'reminder',
        reminderTime: '08:30',
        approximateStartDay: 1,
        approximateEndDay: 5,
        lastExecutedAt: DateTime.utc(2026, 9, 1, 9, 0, 0),
      ));

      // Raw legacy rows (verbatim path): spending categories, rates,
      // wallet, bank-transaction leg, debt payment row, upload.
      final now = DateTime.now().toIso8601String();
      await (await testLedger()).rawInsert(
        'INSERT INTO spending_categories '
        '(user_id, name, name_ar, icon, color, sort_order, is_active, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [uid, 'food', 'طعام', 'FOOD', '#111111', 1, 1, now],
      );
      await (await testLedger()).rawInsert(
        'INSERT INTO personal_exchange_rates '
        '(user_id, from_currency, to_currency, rate, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [uid, 'USD', 'SAR', 3.75, now, now],
      );
      await (await testLedger()).rawInsert(
        'INSERT INTO personal_wallets '
        '(user_id, balance, currency, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?)',
        [uid, 42.5, 'SAR', now, now],
      );
      await DatabaseHelper.rawInsert(
        'INSERT INTO file_uploads '
        '(file_name, file_path, file_size, mime_type, folder, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        ['receipt.pdf', '/r/receipt.pdf', 1234, 'application/pdf', 'personal', now],
      );

      // Typed prefs incl. trees.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          'enabled_currencies_$uid', ['USD', 'SAR', 'YER_OLD', 'YER_NEW', 'EUR', 'OMR']);
      await prefs.setString('wallet_currency', 'USD');
      await prefs.setString('debt_display_currency', 'SAR');
      await prefs.setBool('money_format_${uid}_sep', true);
      await prefs.setBool('money_format_${uid}_dec', false);
      await prefs.setString('bank_account_types_v3', '{"x":1}');
      await prefs.setString('financial_trees_v1', '{"trees":[]}');
      await prefs.setString(
          'financial_tree_reports_v1', '{"reports":[]}');
      await prefs.setString(
          'financial_tree_nodes_t1', '{"nodes":[]}');
      return ids;
    }

    /// Typed user prefs fingerprint (mirrors the snapshot allowlist).
    Future<Map<String, dynamic>> fingerprintPrefs() async {
      final prefs = await SharedPreferences.getInstance();
      final out = <String, dynamic>{};
      const prefixes = [
        'enabled_currencies_',
        'money_format_',
        'bank_account_types_',
        'financial_tree_nodes_',
      ];
      const exact = {
        'wallet_currency',
        'debt_display_currency',
        'backup_auto_sync_enabled',
        'backup_last_sync_row_count',
        'financial_trees_v1',
        'financial_tree_reports_v1',
      };
      for (final k in prefs.getKeys()) {
        if (exact.contains(k) || prefixes.any(k.startsWith)) {
          out[k] = prefs.get(k);
        }
      }
      // Backup runtime keys (device state, preserved across restore).
      for (final k in [
        'backup_last_time',
        'backup_saved_uri',
        'backup_saved_file_path',
        'backup_saved_file_name'
      ]) {
        if (prefs.containsKey(k)) out[k] = prefs.get(k);
      }
      // Trees / account types live in the encrypted ledger now.
      for (final e in (await PersonalLedgerKv.all()).entries) {
        if (exact.contains(e.key) || prefixes.any(e.key.startsWith)) {
          out[e.key] = e.value;
        }
      }
      return out;
    }

    void expectFingerprintsEqual(
        Map<String, dynamic> before, Map<String, dynamic> after) {
      expect(after.keys.toSet(), before.keys.toSet());
      for (final k in before.keys) {
        if (k == 'prefs') continue;
        expect(jsonEncode(after[k]), jsonEncode(before[k]),
            reason: 'table $k');
      }
      final bp = before['prefs'] as Map<String, dynamic>;
      final ap = after['prefs'] as Map<String, dynamic>;
      // backup_* runtime keys are device state (write timestamps/URIs),
      // not user data: compare user-data prefs exactly, runtime keys only
      // for presence.
      Map<String, dynamic> userOnly(Map<String, dynamic> m) {
        final out = Map<String, dynamic>.from(m);
        out.removeWhere((k, _) => k.toString().startsWith('backup_'));
        return out;
      }

      final bu = userOnly(bp);
      final au = userOnly(ap);
      expect(au.keys.toSet(), bu.keys.toSet());
      for (final k in bu.keys) {
        expect(jsonEncode(au[k]), jsonEncode(bu[k]), reason: 'pref $k');
      }
    }

    Future<Map<String, dynamic>> fullFingerprint() async {
      final fp = await fingerprintForSvc();
      fp['prefs'] = await fingerprintPrefs();
      return fp;
    }

    test('golden device: exact equality incl prefs/links/times', () async {
      final bs = makeBackup();
      final svc = makeService();
      final ids = await seedGolden(svc);
      final before = await fullFingerprint();
      final save = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(save.success, isTrue, reason: save.message);
      // Wipe everything (tables + user prefs, keep backup runtime keys).
      for (final t in BackupService.restoreTables) {
        try {
          await _wipeTable(t);
        } catch (_) {}
      }
      final prefs = await SharedPreferences.getInstance();
      for (final k in (await fingerprintPrefs()).keys.toList()) {
        if (!k.startsWith('backup_')) {
          await prefs.remove(k);
          await PersonalLedgerKv.remove(k);
        }
      }
      final doc = await BackupService.readDocumentContent(save.fileUri!);
      final read = await bs.readBackupContent(
        (doc!['content'] as String?) ?? '',
        serverUserUuid: serverUuid,
        localUserId: uid,
      );
      expect(read.success, isTrue, reason: read.message);
      final res = await bs.restoreFromBackup(
        read.data!,
        userId: uid,
        serverUserUuid: serverUuid,
        skipServer: true,
      );
      expect(res.success, isTrue, reason: res.message);
      expect(res.checks, containsAll(['data', 'relations']));
      final after = await fullFingerprint();
      expectFingerprintsEqual(before, after);
      // Spot-check links survived with original IDs.
      final cache = PersonalCacheRepository();
      final txs = await cache.getCollection(uid, 'personal_transaction');
      final linked = txs.where((m) => m['goal_id'] == ids['goal']).toList();
      // Contribution tx + tickets tx both link the goal.
      expect(linked.length, 2);
      final tickets =
          linked.singleWhere((m) => m['category'] == 'travel');
      expect(tickets['budget_id'], ids['budget']);
      expect(tickets['budget_category_id'], ids['catFly']);
      expect((tickets['date']?.toString() ?? ''),
          startsWith('2026-04-05T14:30:45'));
      final debts = await cache.getCollection(uid, 'personal_debt');
      expect(
          (debts.singleWhere((m) => m['id'] == ids['debt'])['due_date']
                  ?.toString() ??
              ''),
          startsWith('2026-11-23T12:00'));
      final recs =
          await cache.getCollection(uid, 'personal_recurring_transaction');
      final rent = recs.singleWhere((m) => m['name'] == 'Rent');
      expect((rent['next_run_date']?.toString() ?? ''),
          startsWith('2026-10-01T09:00'));
      expect(rent['reminder_time'], '08:30');
      expect((rent['last_executed_at']?.toString() ?? ''),
          startsWith('2026-09-01T09:00'));
    });

    test('golden server: blob identical + restore exact', () async {
      // Capture upload bytes, serve them back on download/list.
      var stored = <String, dynamic>{'bytes': <int>[], 'name': ''};
      List<int> uploaded() => List<int>.from(stored['bytes'] as List);
      Dio serverDio() {
        final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9'));
        dio.interceptors.add(InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.endsWith('/backups/key')) {
              handler.resolve(Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'success': true,
                  'data': {
                    'key_b64':
                        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
                  }
                },
              ));
              return;
            }
            if (options.path.endsWith('/backups') &&
                options.method == 'POST') {
              final form = options.data as FormData;
              final file = form.files.single.value as MultipartFile;
              // Capture the REAL outgoing bytes so download echoes them.
              file.finalize().toList().then((chunks) {
                final bytes =
                    chunks.expand((c) => c).toList();
                stored = {
                  'bytes': bytes,
                  'name': file.filename ?? '',
                };
                handler.resolve(Response(
                  requestOptions: options,
                  statusCode: 201,
                  data: {
                    'success': true,
                    'data': {
                      'id': '33333333-3333-3333-3333-333333333333',
                      'version': 1,
                      'filename': file.filename,
                      'size_bytes': bytes.length,
                      'record_count': 1,
                      'checksum': 'x',
                      'hmac_verified': true,
                      'status': 'complete',
                    }
                  },
                ));
              });
              return;
            }
            if (options.path.endsWith('/backups') &&
                options.method == 'GET') {
              handler.resolve(Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'success': true,
                  'data': {
                    'backups': [
                      {
                        'id': '33333333-3333-3333-3333-333333333333',
                        'version': 1,
                        'filename': stored['name'],
                        'size_bytes': 10,
                        'record_count': 1,
                        'checksum': 'x',
                        'hmac_verified': true,
                        'status': 'complete',
                        'created_at': '2026-09-24T00:00:00.000Z',
                      }
                    ],
                    'latest': null,
                  }
                },
              ));
              return;
            }
            if (options.path.contains('/download')) {
              handler.resolve(Response(
                requestOptions: options,
                statusCode: 200,
                data: uploaded(),
              ));
              return;
            }
            if (options.path.endsWith('/personal/finance/restore')) {
              handler.resolve(Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'success': true,
                  'data': {'expected': {}, 'verified': true}
                },
              ));
              return;
            }
            handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response:
                  Response(requestOptions: options, statusCode: 404, data: {}),
            ));
          },
        ));
        return dio;
      }

      final bs = makeBackup(dio: serverDio());
      final svc = makeService();
      await seedGolden(svc);
      final before = await fullFingerprint();
      // The mock captures the REAL uploaded bytes and echoes them on
      // download, so this exercises the true blob round-trip. Byte
      // equality of the stored blob itself is additionally proven
      // server-side (upload→download test).
      final up = await bs.uploadServerBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      expect(up.success, isTrue, reason: up.message);
      // Wipe everything (device + prefs user keys).
      for (final t in BackupService.restoreTables) {
        try {
          await _wipeTable(t);
        } catch (_) {}
      }
      final prefs = await SharedPreferences.getInstance();
      for (final k in (await fingerprintPrefs()).keys.toList()) {
        if (!k.startsWith('backup_')) {
          await prefs.remove(k);
          await PersonalLedgerKv.remove(k);
        }
      }
      final res = await bs.restoreServerBackup(
        '33333333-3333-3333-3333-333333333333',
        localUserId: uid,
        serverUserUuid: serverUuid,
      );
      expect(res.success, isTrue, reason: res.message);
      expect(res.serverState, 'verified');
      final after = await fullFingerprint();
      expectFingerprintsEqual(before, after);
    });

    test('idempotent 3x restores + twins stay two', () async {
      final bs = makeBackup();
      final svc = makeService();
      await seedGolden(svc);
      // Twins: same everything, different IDs.
      for (var i = 0; i < 2; i++) {
        await svc.addTransaction(
          type: 'expense',
          amount: 500,
          category: 'food',
          description: 'twin meal',
          currency: 'SAR',
          accountId: (await svc.getBankAccounts())
              .firstWhere((b) => b.bankName == 'Bank A')
              .id,
          date: DateTime.utc(2026, 5, 5, 12, 0, 0),
        );
      }
      final save = await bs.saveBackup(
          localUserId: uid, serverUserUuid: serverUuid);
      final doc = await BackupService.readDocumentContent(save.fileUri!);
      final stored = (doc!['content'] as String?) ?? '';
      // The file on the device is encrypted; opened with the account key.
      expect(BackupEnvelope.isSealedText(stored), isTrue);
      final plain = await BackupEnvelope.openText(stored, SecretKey(List.filled(32, 3)));
      Map<String, dynamic> readData() => (jsonDecode(plain) as Map<String, dynamic>);
      for (var round = 0; round < 3; round++) {
        final data = readData();
        final issues =
            BackupIntegrity.validateSnapshot(data);
        expect(issues.ok, isTrue);
        final res = await bs.restoreFromBackup(
          data,
          userId: uid,
          serverUserUuid: serverUuid,
          skipServer: true,
        );
        expect(res.success, isTrue, reason: res.message);
      }
      final cache = PersonalCacheRepository();
      final txs = await cache.getCollection(uid, 'personal_transaction');
      final twins = txs
          .where((m) =>
              (m['amount'] as num?)?.toDouble() == 500.0 &&
              (m['date']?.toString() ?? '').startsWith('2026-05-05'))
          .toList();
      expect(twins.length, 2);
      expect(twins[0]['id'], isNot(twins[1]['id']));
    });
  });

  group('financial strictness', () {
    test('amounts survive as exact strings (YER_OLD 54000.50)', () async {
      final svc = makeService();
      await seedRich(svc);
      final snap = await BackupSnapshotBuilder.build(
        localUserId: uid,
        serverUserUuid: serverUuid,
        appVersion: 't',
      );
      final ents = snap['entities'] as Map;
      final accs = ents['accounts'] as List;
      final cash = accs.firstWhere(
          (a) => (a as Map)['currency'] == 'YER_OLD') as Map;
      // Balance moves with transactions (finance logic); the snapshot must
      // carry the mirror value EXACTLY (string-identical, no recomputation).
      final cache = PersonalCacheRepository();
      final mirror = await cache.getCollection(7101, 'personal_bank_account');
      final mirrorCash = mirror.firstWhere(
          (m) => (m['currency']?.toString() ?? '') == 'YER_OLD');
      expect(cash['balance'], mirrorCash['balance']?.toString());
      expect(cash['id'], mirrorCash['id']?.toString());
      final txs = ents['transactions'] as List;
      final lunch = (txs).firstWhere(
          (t) => (t as Map)['category'] == 'food') as Map;
      expect(lunch['amount'], '10.99');
      // Currencies never merged.
      final currencies =
          accs.map((a) => (a as Map)['currency']).toSet();
      expect(currencies, containsAll(['YER_OLD', 'USD', 'SAR']));
    });
  });
}

/// Test fingerprint keyed by STABLE identity (mirror cache rows by
/// remote_id — their autoincrement `id` legitimately changes when a row is
/// re-inserted, exactly like the service verify does).
Dio serverDio({required bool online, Map<String, dynamic>? restoreReply}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9'));
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) {
      if (!online) {
        handler.reject(DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          message: 'SocketException: offline',
        ));
        return;
      }
      if (options.path.endsWith('/backups/key')) {
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'success': true,
            'data': {'key_b64': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='}
          },
        ));
        return;
      }
      if (options.path.endsWith('/backups') && options.method == 'POST') {
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 201,
          data: {
            'success': true,
            'data': {
              'id': '22222222-2222-2222-2222-222222222222',
              'version': 3,
              'filename': 'FYONA_ERP_Backup_v3_x.json',
              'size_bytes': 10,
              'record_count': 5,
              'checksum': 'x',
              'hmac_verified': true,
              'status': 'complete',
            }
          },
        ));
        return;
      }
      if (options.path.endsWith('/personal/finance/restore')) {
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'success': true,
            'data': restoreReply ??
                {
                  'expected': {'accounts': 3},
                  'restored': {'accounts': 3},
                  'verified': true,
                }
          },
        ));
        return;
      }
      handler.reject(DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: options, statusCode: 404, data: {}),
      ));
    },
  ));
  return dio;
}

Future<Map<String, dynamic>> fingerprintForSvc() async {
  final fp = <String, dynamic>{};
  for (final t in BackupService.restoreTables) {
    try {
      final rows = await _tableRows(t);
      final norm = rows
          .map((r) {
            final m = Map<String, dynamic>.from(r)..remove('updated_at');
            // Mirror autoincrement ids are meaningless across restore;
            // remote_id is the stable identity (service verify agrees).
            if (t == 'personal_entity_cache') m.remove('id');
            return m;
          })
          .toList();
      norm.sort((a, b) => _fpKey(t, a).compareTo(_fpKey(t, b)));
      fp[t] = norm;
    } catch (_) {
      fp[t] = [];
    }
  }
  return fp;
}

String _fpKey(String table, Map<String, dynamic> r) {
  if (table == 'personal_entity_cache') {
    return '${r['entity_type']}:${r['remote_id']}';
  }
  return r['id']?.toString() ?? '';
}

Future<void> _wipeTable(String t) async {
  if (PersonalLedgerBackup.isLedgerTable(t)) {
    await (await testLedger()).rawDelete('DELETE FROM $t');
  } else {
    await DatabaseHelper.rawDelete('DELETE FROM $t');
  }
}

Future<List<Map<String, dynamic>>> _tableRows(String t) async =>
    PersonalLedgerBackup.isLedgerTable(t)
        ? (await testLedger()).query(t)
        : DatabaseHelper.query(t);
