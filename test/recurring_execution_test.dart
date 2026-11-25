import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/personal_recurring_form_page.dart';
import 'package:fyona_flutter/features/personal/services/recurring_reminder_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/personal_ledger_test_support.dart';

/// Recurring execution rules (user-mandated):
///
/// 1. No pre-selected frequency; the execution-day picker only offers days
///    matching the chosen frequency.
/// 2. Missing execution time defaults to 09:00 AM (fireAt default).
/// 3. Automatic execution NEVER fires before the exact day + time; manual
///    "execute now" is a separate path and stays untouched.
void main() {
  group('isRecurringExecDaySelectable', () {
    test('nothing selectable without a frequency', () {
      final day = DateTime(2026, 9, 19);
      expect(isRecurringExecDaySelectable(null, null, day), isFalse);
      expect(isRecurringExecDaySelectable('sometimes', null, day), isFalse);
    });

    test('daily allows every day', () {
      expect(isRecurringExecDaySelectable('daily', null, DateTime(2026, 9, 19)), isTrue);
      expect(isRecurringExecDaySelectable('daily', DateTime(2026, 9, 1), DateTime(2026, 9, 20)), isTrue);
    });

    test('weekly without anchor allows all; with anchor locks the weekday', () {
      final monday = DateTime(2026, 9, 21); // Monday
      final tuesday = DateTime(2026, 9, 22);
      expect(isRecurringExecDaySelectable('weekly', null, monday), isTrue);
      expect(isRecurringExecDaySelectable('weekly', null, tuesday), isTrue);
      expect(isRecurringExecDaySelectable('weekly', monday, monday.add(const Duration(days: 7))), isTrue);
      expect(isRecurringExecDaySelectable('weekly', monday, tuesday), isFalse);
    });

    test('monthly without anchor allows 1-28; with anchor locks the day', () {
      expect(isRecurringExecDaySelectable('monthly', null, DateTime(2026, 9, 15)), isTrue);
      expect(isRecurringExecDaySelectable('monthly', null, DateTime(2026, 9, 29)), isFalse);
      expect(isRecurringExecDaySelectable('monthly', null, DateTime(2026, 9, 28)), isTrue);
      final anchor = DateTime(2026, 9, 5);
      expect(isRecurringExecDaySelectable('monthly', anchor, DateTime(2026, 10, 5)), isTrue);
      expect(isRecurringExecDaySelectable('monthly', anchor, DateTime(2026, 10, 6)), isFalse);
    });

    test('yearly without anchor allows all; with anchor locks month+day', () {
      final anchor = DateTime(2026, 3, 10);
      expect(isRecurringExecDaySelectable('yearly', null, DateTime(2027, 5, 1)), isTrue);
      expect(isRecurringExecDaySelectable('yearly', anchor, DateTime(2027, 3, 10)), isTrue);
      expect(isRecurringExecDaySelectable('yearly', anchor, DateTime(2027, 3, 11)), isFalse);
      expect(isRecurringExecDaySelectable('yearly', anchor, DateTime(2027, 4, 10)), isFalse);
    });
  });

  group('RecurringReminderService.fireAt', () {
    RecurringTransaction rule({DateTime? nextDate, String? reminderTime}) {
      return RecurringTransaction(
        id: 'r1',
        type: 'expense',
        amount: 100,
        category: 'test',
        frequency: 'monthly',
        nextDate: nextDate,
        reminderTime: reminderTime,
      );
    }

    test('missing time defaults to 09:00 AM', () {
      final at = RecurringReminderService.fireAt(rule(nextDate: DateTime(2026, 9, 19)));
      expect(at, DateTime(2026, 9, 19, 9, 0));
    });

    test('explicit time is honored', () {
      final at = RecurringReminderService.fireAt(
          rule(nextDate: DateTime(2026, 9, 19), reminderTime: '18:30'));
      expect(at, DateTime(2026, 9, 19, 18, 30));
    });

    test('dateless rule has no fire instant', () {
      expect(RecurringReminderService.fireAt(rule()), isNull);
    });
  });

  group('processDueRecurring time gate', () {
    const uid = 77;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

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
      svc.setUserId(uid);
      return svc;
    }

    Future<void> cleanDb() async {
      await (await testLedger()).rawDelete(
          'DELETE FROM personal_entity_cache WHERE user_id = ?', [uid.toString()]);
      await (await testLedger()).rawDelete('DELETE FROM sync_queue');
    }

    setUp(() async => cleanDb());
    tearDown(() async => cleanDb());

    Future<String> seedAccount(PersonalFinanceService svc) async {
      await svc.addBankAccount(
          bankName: 'Gate Bank', currency: 'USD', openingBalance: 1000);
      final cache = PersonalCacheRepository();
      final all = await cache.getCollection(uid, 'personal_bank_account');
      return (all
              .firstWhere((r) => (r['bank_name']?.toString() ?? '') == 'Gate Bank')['id']
              ?.toString() ??
          '');
    }

    Future<double> accountBalance() async {
      final cache = PersonalCacheRepository();
      final all = await cache.getCollection(uid, 'personal_bank_account');
      final row = all
          .firstWhere((r) => (r['bank_name']?.toString() ?? '') == 'Gate Bank');
      return double.tryParse(row['balance']?.toString() ?? '0') ?? 0;
    }

    Future<RecurringTransaction> storedRule() async {
      final cache = PersonalCacheRepository();
      final rows =
          await cache.getCollection(uid, 'personal_recurring_transaction');
      return RecurringTransaction.fromServer(
          Map<String, dynamic>.from(rows.single));
    }

    test('auto rule does NOT execute before its exact time', () async {
      final svc = makeService();
      final accountId = await seedAccount(svc);
      expect(accountId, isNotEmpty);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      await svc.addRecurring(RecurringTransaction(
        id: '',
        type: 'expense',
        amount: 100,
        category: 'test',
        frequency: 'daily',
        nextDate: today,
        bankAccountId: accountId,
        currency: 'USD',
        accountType: 'fixed',
        executionType: 'auto',
        reminderTime: '23:59',
      ));

      final executed = await svc.processDueRecurring();
      expect(executed, isEmpty);
      expect(await accountBalance(), 1000);
    });

    test('auto rule DOES execute once its time has arrived', () async {
      final svc = makeService();
      final accountId = await seedAccount(svc);
      expect(accountId, isNotEmpty);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      await svc.addRecurring(RecurringTransaction(
        id: '',
        type: 'expense',
        amount: 100,
        category: 'test',
        frequency: 'daily',
        nextDate: today,
        bankAccountId: accountId,
        currency: 'USD',
        accountType: 'fixed',
        executionType: 'auto',
        reminderTime: '00:00',
      ));

      final executed = await svc.processDueRecurring();
      expect(executed.length, 1);
      expect(await accountBalance(), 900);
      // The occurrence advances so it never double-fires the same day.
      final stored = await storedRule();
      expect(stored.nextDate, isNotNull);
      expect(
          stored.nextDate!
              .isAfter(DateTime(now.year, now.month, now.day)),
          isTrue);
      // The execution stamp itself must survive the round-trip.
      expect(stored.lastExecutedAt, isNotNull);
    });

    test('non-auto rule is NEVER auto-executed, even past its time', () async {
      final svc = makeService();
      final accountId = await seedAccount(svc);
      expect(accountId, isNotEmpty);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      await svc.addRecurring(RecurringTransaction(
        id: '',
        type: 'expense',
        amount: 100,
        category: 'test',
        frequency: 'daily',
        nextDate: today,
        bankAccountId: accountId,
        currency: 'USD',
        accountType: 'fixed',
        executionType: 'reminder',
        reminderTime: '00:00',
      ));

      final executed = await svc.processDueRecurring();
      expect(executed, isEmpty);
      expect(await accountBalance(), 1000);
    });
  });
}
