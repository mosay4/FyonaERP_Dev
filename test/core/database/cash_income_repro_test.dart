import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Reproduction for: "income to CASH while online shows the transaction but
/// the cash balance stays 0 (banks work fine; offline works fine)".
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    try {
      await DatabaseHelper.close();
    } catch (_) {}
    final path = '${await getDatabasesPath()}/fyona_erp.db';
    final db = await databaseFactory.openDatabase(path);
    await db.delete('personal_entity_cache');
    await db.delete('sync_queue');
    await db.close();
  });

  tearDown(() async {
    try {
      await DatabaseHelper.close();
    } catch (_) {}
  });

  test('cash income bumps the cash mirror balance (no network)', () async {
    final cache = PersonalCacheRepository();
    // NOTE: PersonalFinanceService requires a cache; apiClient is null so any
    // network path throws — reads served from a seeded mirror stay offline.
    final service = PersonalFinanceService(cache: cache);
    service.setUserId(21);

    await cache.upsertItem(21, 'personal_bank_account', 'cash-usd-1', {
      'id': 'cash-usd-1',
      'bank_name': 'كاش',
      'currency': 'USD',
      'balance': 0.0,
    });

    final ok = await service.addTransaction(
      type: 'income',
      amount: 100,
      category: 'راتب',
      date: DateTime.now(),
      accountId: 'cash-usd-1',
      currency: 'USD',
    );
    expect(ok, isTrue);

    final rows = await cache.getCollection(21, 'personal_bank_account');
    final cash = rows.firstWhere((r) => r['id'] == 'cash-usd-1');
    // ignore: avoid_print
    print('CASH_BALANCE_AFTER_INCOME=${cash['balance']}');
    expect((cash['balance'] as num).toDouble(), 100.0);

    final txs = await cache.getCollection(21, 'personal_transaction');
    expect(txs.length, 1);
  });

  test('stale server pull does not clobber unconfirmed cash bump', () async {
    final cache = PersonalCacheRepository();
    final service = PersonalFinanceService(cache: cache);
    service.setUserId(22);

    await cache.upsertItem(22, 'personal_bank_account', 'cash-usd-2', {
      'id': 'cash-usd-2',
      'bank_name': 'كاش',
      'currency': 'USD',
      'balance': 0.0,
      '_sync_version': 3,
    });

    expect(
      await service.addTransaction(
        type: 'income',
        amount: 250,
        category: 'راتب',
        date: DateTime.now(),
        accountId: 'cash-usd-2',
        currency: 'USD',
      ),
      isTrue,
    );

    // Server snapshot from BEFORE the replay (stale balance 0).
    await cache.replaceCollection(22, 'personal_bank_account', [
      {
        'id': 'cash-usd-2',
        'bank_name': 'كاش',
        'currency': 'USD',
        'balance': 0.0,
        '_sync_version': 3,
      }
    ]);

    final rows = await cache.getCollection(22, 'personal_bank_account');
    final cash = rows.firstWhere((r) => r['id'] == 'cash-usd-2');
    // ignore: avoid_print
    print('CASH_BALANCE_AFTER_STALE_PULL=${cash['balance']}');
    expect((cash['balance'] as num).toDouble(), 250.0);

    // The read path must also serve the local truth, not the stale server row.
    final merged = await cache.mergePendingInto(22, 'personal_bank_account', [
      {
        'id': 'cash-usd-2',
        'bank_name': 'كاش',
        'currency': 'USD',
        'balance': 0.0,
      }
    ]);
    expect(
      (merged.firstWhere((r) => r['id'] == 'cash-usd-2')['balance'] as num)
          .toDouble(),
      250.0,
    );
  });
}
