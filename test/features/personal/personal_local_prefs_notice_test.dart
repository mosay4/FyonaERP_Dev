import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_ledger.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_ledger_migration.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_local_cutover.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_reminder_store.dart';
import 'package:fyona_flutter/features/personal/presentation/providers/personal_relay_provider.dart';
import 'package:fyona_flutter/features/personal/services/smart_insights/sara_insight_engine.dart';
import 'package:fyona_flutter/features/personal/services/smart_insights/sara_notice_composer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../support/personal_ledger_test_support.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    try {
      await DatabaseHelper.close();
    } catch (_) {}
    await resetPersonalLedger();
    PersonalLocalMode.debugReset();
  });

  test('the cash vault (stashed balances) moves from plain preferences into the ledger: '
      'copy → verify → wipe', () async {
    const vault = '{"USD":{"balance":42.5}}';
    SharedPreferences.setMockInitialValues({'cash_vault_7': vault, 'unrelated': 'x'});
    expect(PersonalLedgerMigration.isLedgerPrefKey('cash_vault_7'), isTrue);
    expect(await PersonalLedgerKv.getString('cash_vault_7'), vault);
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    expect(prefs.getString('cash_vault_7'), isNull);
    expect(prefs.getString('unrelated'), 'x');
    // New writes go to the ledger only.
    await PersonalLedgerKv.setString('cash_vault_7', '{}');
    await prefs.reload();
    expect(prefs.getString('cash_vault_7'), isNull);
    expect(await PersonalLedgerKv.getString('cash_vault_7'), '{}');
  });

  test('reminder stores with debts and amounts move into the ledger; only a redacted '
      'boot copy (when, request code, route) stays in plain preferences', () async {
    final legacy = jsonEncode({
      'debt_d1': {
        'debt': {'id': 'd1', 'person_name': 'أحمد', 'amount': 300.0, 'currency': 'SAR', 'debt_type': 'payable'},
        'millis': 1893456000000,
        'requestCode': 77,
        'route': '/personal/debts?debtId=d1',
        'kind': 'debt',
        'refId': 'd1',
      },
    });
    SharedPreferences.setMockInitialValues({PersonalReminderStore.debt: legacy});

    // Copy → verify → wipe on first read.
    final full = jsonDecode((await PersonalReminderStore.read(PersonalReminderStore.debt))!) as Map;
    expect(full['debt_d1']['debt']['person_name'], 'أحمد');
    expect(await PersonalLedgerKv.getString(PersonalReminderStore.ledgerKey(PersonalReminderStore.debt)),
        isNotNull);
    final prefs = await SharedPreferences.getInstance();
    final plain = prefs.getString(PersonalReminderStore.debt)!;
    expect(plain, isNot(contains('أحمد')));
    expect(plain, isNot(contains('300')));
    final boot = (jsonDecode(plain) as Map)['debt_d1'] as Map;
    expect(boot['millis'], 1893456000000);
    expect(boot['requestCode'], 77);
    expect(boot['_r'], 1);
    expect(boot['debt'], {'id': 'd1', 'debt_type': 'payable'});

    // Writes: full copy in the ledger, redacted in preferences. Idempotent.
    final next = jsonEncode({
      'recur_r1': {'millis': 1, 'title': 'Netflix', 'body': '45 SAR', 'requestCode': 5, 'kind': 'recurring'},
    });
    await PersonalReminderStore.write(PersonalReminderStore.recurring, next);
    expect(await PersonalReminderStore.read(PersonalReminderStore.recurring), next);
    final plainRec = prefs.getString(PersonalReminderStore.recurring)!;
    expect(plainRec, isNot(contains('Netflix')));
    expect(plainRec, isNot(contains('45 SAR')));
    expect(await PersonalReminderStore.read(PersonalReminderStore.recurring), next);

    await PersonalReminderStore.remove(PersonalReminderStore.recurring);
    expect(await PersonalReminderStore.read(PersonalReminderStore.recurring), isNull);
    expect(prefs.getString(PersonalReminderStore.recurring), isNull);
  });

  testWidgets('calm notices: restore suggestion with a link, update required, dismissible',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: PersonalLocalNoticeBar())),
    ));
    expect(find.byKey(const ValueKey('personal-local-notice')), findsNothing);

    PersonalLocalMode.notice.value = PersonalLocalNotice.restoreBackup;
    await tester.pump();
    expect(find.byKey(const ValueKey('personal-local-notice')), findsOneWidget);
    expect(find.byType(TextButton), findsOneWidget); // → restore screen

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(PersonalLocalMode.notice.value, isNull);
    expect(find.byKey(const ValueKey('personal-local-notice')), findsNothing);

    PersonalLocalMode.notice.value = PersonalLocalNotice.updateRequired;
    await tester.pump();
    expect(find.byKey(const ValueKey('personal-local-notice')), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    PersonalLocalMode.notice.value = null;
  });

  test('low balance is a deterministic device alert (no AI, no server)', () {
    const accounts = [
      InsightAccount(id: 'b', name: 'بنك', currency: 'SAR', balance: 0),
      InsightAccount(id: 'a', name: 'كاش', currency: 'USD', balance: -5),
      InsightAccount(id: 'c', name: 'توفير', currency: 'SAR', balance: 10),
    ];
    final input = SaraInsightInput(now: DateTime(2026, 11, 25), baseCurrency: 'SAR', accounts: accounts);
    expect(SaraInsightEngine.lowAccounts(input).map((a) => a.id), ['a', 'b']);
    final alert = InstantAlert(kind: 'lowBalance', account: accounts[1]);
    expect(alert.key, 'instant:low:a');
    final notice = SaraNoticeComposer.instant(
      alert,
      baseCurrency: 'SAR',
      tr: (k, [p]) => '$k ${p ?? ''}',
      money: (v, c) => '$v $c',
    );
    expect(notice.kind, 'lowBalance');
    expect(notice.route, SaraRoutes.banks);
    expect(notice.body, contains('-5.0 USD'));
  });
}
