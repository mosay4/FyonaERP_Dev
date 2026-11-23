import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Budget categories: stable client UUIDs + mirror persistence + linkage.
///
/// Regression coverage for "sometimes saved, sometimes not": categories used
/// to reach the mirror without ids (and the server minted different ones),
/// so links and progress flickered with sync timing. Now ids are assigned
/// at the first local commit and travel end to end.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final uuidRe = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  PersonalFinanceService makeService() {
    final dio = Dio(BaseOptions(
      baseUrl: 'http://127.0.0.1:9',
      connectTimeout: const Duration(seconds: 2),
      receiveTimeout: const Duration(seconds: 2),
    ));
    final svc = PersonalFinanceService(
      apiClient: ApiClient(dio: dio),
      cache: PersonalCacheRepository(),
    );
    svc.setUserId(7);
    return svc;
  }

  Future<void> cleanDb() async {
    await DatabaseHelper.rawDelete('DELETE FROM personal_entity_cache');
    await DatabaseHelper.rawDelete('DELETE FROM sync_queue');
  }

  setUp(() async => cleanDb());
  tearDown(() async => cleanDb());

  PersonalBudget testBudget() => PersonalBudget(
        id: '',
        name: 'Monthly',
        totalAmount: 2000,
        currency: 'SAR',
        categories: [
          BudgetCategory(id: '', name: 'Food', type: 'expense', allocatedAmount: 800, currency: 'SAR'),
          BudgetCategory(id: '', name: 'Rent', type: 'expense', allocatedAmount: 700, currency: 'SAR'),
        ],
      );

  Future<Map<String, dynamic>> mirrorBudget(String id) async {
    final cache = PersonalCacheRepository();
    final all = await cache.getCollection(7, 'personal_budget');
    return Map<String, dynamic>.from(
        all.firstWhere((r) => (r['id']?.toString() ?? '') == id));
  }

  group('offline budget categories', () {
    test('create assigns stable UUIDs and persists categories in mirror',
        () async {
      final svc = makeService();
      await svc.addBudget(testBudget());

      final cache = PersonalCacheRepository();
      final all = await cache.getCollection(7, 'personal_budget');
      expect(all.length, 1);
      final row = all.first;
      final cats = (row['categories'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      expect(cats.length, 2, reason: 'mirror must keep both categories');
      final ids = cats.map((c) => c['id'].toString()).toList();
      expect(ids.toSet().length, 2, reason: 'ids must be unique');
      for (final id in ids) {
        expect(uuidRe.hasMatch(id), isTrue, reason: 'bad id: $id');
      }
      final food = cats.firstWhere((c) => c['name'] == 'Food');
      expect((food['allocated_amount'] as num).toDouble(), 800.0);
      expect(row['id'].toString(), isNotEmpty);
    });

    test('staged INSERT carries category ids for the server', () async {
      final svc = makeService();
      await svc.addBudget(testBudget());

      final ops = await DatabaseHelper.rawQuery(
        "SELECT data FROM sync_queue WHERE entity_type = 'personal_budget' "
        "AND operation = 'INSERT'",
      );
      expect(ops.length, 1);
      final data =
          jsonDecode(ops.first['data'] as String) as Map<String, dynamic>;
      final cats = (data['categories'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      expect(cats.length, 2);
      for (final c in cats) {
        expect(uuidRe.hasMatch(c['id'].toString()), isTrue);
      }
      // Mirror and staged op agree on the same ids.
      final mirror = await mirrorBudget(data['id'].toString());
      final mirrorCats = (mirror['categories'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      expect(
        mirrorCats.map((c) => c['id']).toSet(),
        cats.map((c) => c['id']).toSet(),
      );
    });

    test('update preserves server ids and fills missing ones', () async {
      const serverId = '11111111-2222-4333-8444-555555555555';
      final svc = makeService();
      final cache = PersonalCacheRepository();
      await cache.upsertItem(7, 'personal_budget', 'bud-u', {
        'id': 'bud-u',
        'name': 'Monthly',
        'amount': 2000.0,
        'currency': 'SAR',
        'categories': [
          {
            'id': serverId,
            'name': 'Food',
            'allocated_amount': 800.0,
            'currency': 'SAR'
          },
        ],
      });

      await svc.updateBudget(PersonalBudget(
        id: 'bud-u',
        name: 'Monthly',
        totalAmount: 2000,
        currency: 'SAR',
        categories: [
          BudgetCategory(
              id: serverId,
              name: 'Food',
              type: 'expense',
              allocatedAmount: 900,
              currency: 'SAR'),
          BudgetCategory(
              id: '',
              name: 'New',
              type: 'expense',
              allocatedAmount: 100,
              currency: 'SAR'),
        ],
      ));

      final ops = await DatabaseHelper.rawQuery(
        "SELECT data FROM sync_queue WHERE entity_type = 'personal_budget' "
        "AND entity_id = 'bud-u' AND operation = 'UPDATE'",
      );
      expect(ops.length, 1);
      final data =
          jsonDecode(ops.first['data'] as String) as Map<String, dynamic>;
      final cats = (data['categories'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final food = cats.firstWhere((c) => c['name'] == 'Food');
      expect(food['id'], serverId,
          reason: 'server id must never be rewritten');
      final foodAmt = (food['allocated_amount'] ?? food['amount']) as num?;
      expect(foodAmt?.toDouble(), 900.0);
      final added = cats.firstWhere((c) => c['name'] == 'New');
      expect(uuidRe.hasMatch(added['id'].toString()), isTrue,
          reason: 'new category gets a stable UUID');
    });

    test('offline tx links to the category id, progress inputs agree',
        () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();
      await cache.upsertItem(7, 'personal_bank_account', 'acc-bc', {
        'id': 'acc-bc',
        'bank_name': 'B',
        'currency': 'SAR',
        'balance': 5000.0,
        'is_active': true,
      });
      await svc.addBudget(testBudget());

      final budgets = await cache.getCollection(7, 'personal_budget');
      final budgetId = budgets.first['id'].toString();
      final catId = ((budgets.first['categories'] as List).first
              as Map)['id']
          .toString();

      await svc.addTransaction(
        type: 'expense',
        amount: 200,
        category: 'Food',
        date: DateTime.now(),
        accountId: 'acc-bc',
        currency: 'SAR',
        budgetId: budgetId,
        budgetCategoryId: catId,
      );

      final txs = await cache.getCollection(7, 'personal_transaction');
      expect(txs.length, 1);
      expect(txs.first['budget_category_id'], catId,
          reason: 'tx must reference the stable category id');
      // The mirror budget still carries the same category (progress inputs).
      final mirror = await mirrorBudget(budgetId);
      final mirrorCats = (mirror['categories'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      expect(mirrorCats.any((c) => c['id'] == catId), isTrue);
    });

    test('toServerJson carries ids for the sync payload', () {
      const cid = '22222222-3333-4444-8555-666666666666';
      final b = PersonalBudget(
        id: 'bud-s',
        name: 'M',
        totalAmount: 100,
        categories: [
          BudgetCategory(
              id: cid, name: 'X', type: 'expense', allocatedAmount: 10),
        ],
      );
      final send = b.toServerJson();
      final cats = send['categories'] as List;
      expect(cats.length, 1);
      expect((cats.first as Map)['id'], cid);
    });
  });
}
