import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_account_type_sync.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// جاري / توفير must live on the server: sent on create/update (also when
/// queued offline), read back from server rows into the local mirror, and
/// legacy device-only types migrated up exactly once without ever turning
/// a real savings account into current.
void main() {
  const uid = 91;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  PersonalFinanceService makeService({Dio? dio}) {
    final d = dio ??
        Dio(BaseOptions(
          baseUrl: 'http://127.0.0.1:9',
          connectTimeout: const Duration(seconds: 2),
          receiveTimeout: const Duration(seconds: 2),
        ));
    return PersonalFinanceService(
      apiClient: ApiClient(dio: d),
      cache: PersonalCacheRepository(),
    )..setUserId(uid);
  }

  Dio stubServer(List<Map<String, dynamic>> rows) {
    final d = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9'));
    d.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      h.resolve(Response(
          requestOptions: o,
          statusCode: 200,
          data: {'success': true, 'data': rows}));
    }));
    return d;
  }

  Future<void> cleanDb() async {
    await DatabaseHelper.rawDelete(
        'DELETE FROM personal_entity_cache WHERE user_id = ?',
        [uid.toString()]);
    await DatabaseHelper.rawDelete('DELETE FROM sync_queue');
  }

  setUp(cleanDb);
  tearDown(cleanDb);

  Future<List<Map<String, dynamic>>> queued() async {
    final rows = await DatabaseHelper.rawQuery(
        "SELECT * FROM sync_queue WHERE entity_type = 'personal_bank_account' "
        'ORDER BY id ASC');
    return [
      for (final r in rows)
        {
          'operation': r['operation'],
          ...Map<String, dynamic>.from(
              jsonDecode(r['data'] as String) as Map),
        }
    ];
  }

  group('vocabulary', () {
    test('server current/savings ↔ device checking/savings', () {
      expect(personalAccountTypeFromServer('current'), 'checking');
      expect(personalAccountTypeFromServer('savings'), 'savings');
      expect(personalAccountTypeFromServer(null), 'checking');
      expect(personalAccountTypeToServer('checking'), 'current');
      expect(personalAccountTypeToServer('savings'), 'savings');
      expect(PersonalFinanceService.cashTypeKey('current'), 'checking');
      expect(PersonalFinanceService.cashTypeKey('savings'), 'savings');
    });

    test('fromServer reads the type and whether the server stated it', () {
      final a = PersonalBankAccount.fromServer({
        'id': 'a', 'bank_name': 'K', 'currency': 'USD',
        'account_type': 'savings', 'account_type_set': true,
      });
      expect(a.accountType, 'savings');
      expect(a.accountTypeSet, isTrue);
      final legacy = PersonalBankAccount.fromServer({
        'id': 'b', 'bank_name': 'K', 'currency': 'USD',
        'account_type': 'current', 'account_type_set': false,
      });
      expect(legacy.accountType, 'checking');
      expect(legacy.accountTypeSet, isFalse);
      final oldServer = PersonalBankAccount.fromServer(
          {'id': 'c', 'bank_name': 'K', 'currency': 'USD'});
      expect(oldServer.accountTypeSet, isNull);
    });
  });

  group('create / update payloads', () {
    test('offline create queues account_type (server vocabulary)', () async {
      final svc = makeService();
      await svc.addBankAccount(
          bankName: 'الكريمي',
          currency: 'USD',
          openingBalance: 0,
          accountType: 'savings');
      await svc.addBankAccount(
          bankName: 'الكريمي', currency: 'USD', openingBalance: 0);
      final ops = await queued();
      expect(ops.where((o) => o['operation'] == 'INSERT').map((o) => o['account_type']),
          ['savings', 'current']);
      final mine = await svc.getBankAccounts();
      final types = {for (final a in mine) a.accountType};
      expect(types, containsAll(['savings', 'checking']));
    });

    test('update queues account_type and marks the mirror typed', () async {
      final svc = makeService();
      await svc.addBankAccount(
          bankName: 'B', currency: 'SAR', openingBalance: 0);
      final id = (await svc.getBankAccounts())
          .firstWhere((a) => a.bankName == 'B')
          .id;
      await svc.updateBankAccount(id, accountType: 'savings');
      final upd = (await queued()).lastWhere((o) => o['operation'] == 'UPDATE');
      expect(upd['account_type'], 'savings');
      expect(upd['__changed'], contains('account_type'));
      final acc = (await svc.getBankAccounts()).firstWhere((a) => a.id == id);
      expect(acc.accountType, 'savings');
      expect(acc.accountTypeSet, isTrue);
    });
  });

  test('server read lands in the local mirror (reinstall restores savings)',
      () async {
    // Fresh install: empty mirror, the server holds the stated types.
    final svc = makeService(dio: stubServer([
      {
        'id': 'srv-sav', 'bank_name': 'الكريمي', 'currency': 'USD',
        'balance': 900, 'account_type': 'savings', 'account_type_set': true,
      },
      {
        'id': 'srv-cur', 'bank_name': 'الكريمي', 'currency': 'USD',
        'balance': 100, 'account_type': 'current', 'account_type_set': true,
      },
    ]));
    final accounts = await svc.getBankAccounts();
    expect(accounts.firstWhere((a) => a.id == 'srv-sav').accountType, 'savings');
    expect(accounts.firstWhere((a) => a.id == 'srv-cur').accountType, 'checking');
    final mirror = await PersonalCacheRepository()
        .getCollection(uid, 'personal_bank_account');
    expect(mirror.firstWhere((r) => r['id'] == 'srv-sav')['account_type'],
        'savings');
    // No legacy map after a reinstall → nothing to push.
    expect(planPersonalAccountTypeMigration(accounts, const {}), isEmpty);
  });

  group('legacy device map', () {
    PersonalBankAccount acc(String id, String type, bool? set) =>
        PersonalBankAccount(
            id: id, bankName: 'K', currency: 'USD',
            accountType: type, accountTypeSet: set);

    test('server-stated type wins over a stale map', () {
      final out = resolvePersonalAccountTypes(
          [acc('a', 'savings', true)], {'a': 'checking'});
      expect(out.single.accountType, 'savings');
    });

    test('untyped / older-server rows keep the device type on screen', () {
      final out = resolvePersonalAccountTypes(
          [acc('a', 'checking', false), acc('b', 'checking', null)],
          {'a': 'savings', 'b': 'savings'});
      expect(out.map((a) => a.accountType), ['savings', 'savings']);
    });

    test('only savings on rows the server never typed is pushed', () {
      final plan = planPersonalAccountTypeMigration([
        acc('untyped-sav', 'checking', false),
        acc('untyped-chk', 'checking', false),
        acc('typed', 'checking', true),
        acc('old-server', 'checking', null),
        PersonalBankAccount(
            id: 'cash', bankName: 'كاش', accountType: 'cash',
            accountTypeSet: false),
      ], {
        'untyped-sav': 'savings',
        'untyped-chk': 'checking',
        'typed': 'savings',
        'old-server': 'savings',
        'cash': 'savings',
      });
      expect(plan, {'untyped-sav': 'savings'});
    });

    test('migration push queues an update and is not repeated', () async {
      final svc = makeService(dio: stubServer([
        {
          'id': 'legacy-1', 'bank_name': 'K', 'currency': 'USD',
          'balance': 5, 'account_type': 'current', 'account_type_set': false,
        },
      ]));
      final before = await svc.getBankAccounts();
      final plan =
          planPersonalAccountTypeMigration(before, {'legacy-1': 'savings'});
      expect(plan, {'legacy-1': 'savings'});
      for (final e in plan.entries) {
        await svc.updateBankAccount(e.key, accountType: e.value);
      }
      final upd = (await queued()).single;
      expect(upd['operation'], 'UPDATE');
      expect(upd['account_type'], 'savings');
      final after = await svc.getBankAccounts();
      expect(after.single.accountType, 'savings');
      expect(planPersonalAccountTypeMigration(after, {'legacy-1': 'savings'}),
          isEmpty);
    });
  });
}
