import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/features/ai/domain/agent/confirmation_handler.dart';
import 'package:fyona_flutter/features/ai/domain/agent/sara_link_fallback.dart';
import 'package:fyona_flutter/features/ai/domain/agent/tool_executor.dart';
import 'package:fyona_flutter/features/ai/domain/agent/tool_registry.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:fyona_flutter/shared/widgets/sara_action_dispatcher.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakePath extends PathProviderPlatform {
  _FakePath(this.d);
  final Directory d;
  @override
  Future<String?> getApplicationDocumentsPath() async => d.path;
  @override
  Future<String?> getTemporaryPath() async => d.path;
  @override
  Future<String?> getApplicationSupportPath() async => d.path;
}

/// Round 15: Sara never promises a button without one, and the Personal
/// screen actions that had no Sara tool (whole-bank delete, recurring
/// skip/postpone/run-now-with-bank, report PDF) are wired with the screens'
/// own guards.
void main() {
  const uid = 1515;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    PathProviderPlatform.instance = _FakePath(await Directory.systemTemp.createTemp('sara_r15'));
  });

  PersonalFinanceService svc() {
    final s = PersonalFinanceService(
      apiClient: ApiClient(dio: Dio(BaseOptions(
        baseUrl: 'http://127.0.0.1:9',
        connectTimeout: const Duration(seconds: 2),
        receiveTimeout: const Duration(seconds: 2),
      ))),
      cache: PersonalCacheRepository(),
    );
    s.setUserId(uid);
    return s;
  }

  Future<void> clean() async {
    await DatabaseHelper.rawDelete('DELETE FROM personal_entity_cache WHERE user_id = ?', [uid.toString()]);
    await DatabaseHelper.rawDelete('DELETE FROM sync_queue');
  }

  setUp(clean);
  tearDown(clean);

  group('a reply that promises a button always has one', () {
    test('owner bug: «الزر تحت جاهز» with no action still yields the reports chip', () {
      final actions = saraEnsureScreenAction(
        userQuery: 'رسلي لي زر التقارير هنا',
        reply: 'الزر تحت جاهز — اضغط عليه ويوديك مباشرة لـ التقارير.',
        actions: const [],
        arabic: true,
      );
      expect(actions, hasLength(1));
      expect(actions.first.type, SaraActionType.openScreen);
      expect(actions.first.params['route'], saraPersonalReportsRoute);
      expect(SaraActionDispatcher.resolveRouteFromActions(actions), saraPersonalReportsRoute);
    });

    test('asking again later yields the chip again (nothing deduplicated)', () {
      for (var turn = 0; turn < 3; turn++) {
        final actions = saraEnsureScreenAction(
          userQuery: 'رسلي لي زر التقارير هنا', reply: 'تفضل', actions: const [], arabic: true);
        expect(SaraActionDispatcher.resolveRouteFromActions(actions), saraPersonalReportsRoute, reason: 'turn $turn');
      }
    });

    test('an action from the server is kept untouched', () {
      const server = [SaraAction(type: SaraActionType.openScreen, params: {'screen': 'البنوك', 'route': '/personal/banks'})];
      expect(saraEnsureScreenAction(userQuery: 'افتح التقارير', reply: 'اضغط الزر', actions: server, arabic: true), same(server));
    });

    test('no screen asked and none promised: no chip', () {
      expect(saraEnsureScreenAction(userQuery: 'كم رصيدي؟', reply: 'رصيدك 500', actions: const [], arabic: true), isEmpty);
    });

    test('dialect words resolve to the right Personal screen', () {
      expect(saraScreenRouteFromText('وديني للتقارير', arabic: true), saraPersonalReportsRoute);
      expect(saraScreenRouteFromText('افتح لي الديون', arabic: true), RouteNames.personalDebts);
      expect(saraScreenRouteFromText('ابي الاشتراكات المتكررة', arabic: true), RouteNames.personalRecurring);
      expect(saraScreenRouteFromText('زر البنوك', arabic: true), RouteNames.personalBanks);
      expect(saraScreenRouteFromText('open my budget', arabic: false), RouteNames.personalBudget);
    });

    test('export_report opens the report that exports its PDF', () {
      expect(saraPersonalReportExportRoute({'kind': 'debts', 'period': 'year', 'currency': 'usd'}),
          '${RouteNames.personalReportsView}?kind=debts&period=year&currency=USD&export=1');
      expect(saraPersonalReportExportRoute({'report_type': 'transactions'}),
          '${RouteNames.personalReportsView}?kind=cashflow&export=1');
      expect(saraPersonalReportExportRoute({}), '${RouteNames.personalReportsView}?kind=overview&export=1');
    });
  });

  group('delete a whole bank (confirmation + identity, cash never)', () {
    test('needs the confirmation card', () {
      final def = AgentToolRegistry.findByName('delete_bank')!;
      expect(ConfirmationHandler.requiresConfirmation(def), isTrue);
      expect(ConfirmationHandler.buildConfirmationMessage(def, {'bank_name': 'الأهلي'}), contains('الأهلي'));
    });

    test('deletes every currency of the bank and nothing else', () async {
      final s = svc();
      await s.addBankAccount(bankName: 'الأهلي', currency: 'SAR', openingBalance: 10);
      await s.addBankAccount(bankName: 'الأهلي', currency: 'USD', openingBalance: 5);
      await s.addBankAccount(bankName: 'الراجحي', currency: 'SAR', openingBalance: 7);
      final gateCalls = <String>[];
      final exec = ToolExecutor(s, identityGate: (tool) async { gateCalls.add(tool); return true; });
      final r = await exec.execute('delete_bank', {'bank_name': 'الأهلي'});
      expect(r.verificationStatus, anyOf('confirmed', 'local_pending'));
      expect(gateCalls, ['delete_bank']);
      final left = await s.getBankAccounts();
      expect(left.map((a) => a.bankName), ['الراجحي']);
    });

    test('identity not verified → nothing deleted', () async {
      final s = svc();
      await s.addBankAccount(bankName: 'الأهلي', currency: 'SAR', openingBalance: 10);
      final exec = ToolExecutor(s, identityGate: (_) async => false);
      final r = await exec.execute('delete_bank', {'bank_name': 'الأهلي'});
      expect(r.success, isFalse);
      expect(r.errorCode, 'IDENTITY_NOT_VERIFIED');
      expect(await s.getBankAccounts(), hasLength(1));
    });

    test('cash is refused before asking identity; maintenance blocks', () async {
      final s = svc();
      await s.addBankAccount(bankName: 'كاش', currency: 'SAR', openingBalance: 10);
      var asked = false;
      final r = await ToolExecutor(s, identityGate: (_) async { asked = true; return true; })
          .execute('delete_bank', {'bank_name': 'كاش'});
      expect(r.errorCode, 'CASH_NOT_DELETABLE');
      expect(asked, isFalse);
      final m = await ToolExecutor(s, maintenanceBlocked: (route) => route == '/personal/banks')
          .execute('delete_bank', {'bank_name': 'الأهلي'});
      expect(m.errorCode, 'MAINTENANCE');
      expect(await s.getBankAccounts(), hasLength(1));
    });
  });

  group('recurring: skip, postpone, run now with a bank', () {
    Future<RecurringTransaction> seed(PersonalFinanceService s,
        {bool active = true, String accountType = 'fixed', String? bankId, DateTime? next, String category = 'إيجار'}) async {
      await s.addRecurring(RecurringTransaction(
        id: '', name: 'Rent', type: 'expense', amount: 100, category: category, description: 'Rent',
        frequency: 'monthly', currency: 'SAR', isActive: active, accountType: accountType,
        bankAccountId: bankId, nextDate: next ?? DateTime(2030, 1, 15)));
      return (await s.getRecurring()).firstWhere((r) => r.category == category);
    }

    test('skip and postpone are plain safe writes (no card), like the buttons', () {
      for (final t in ['skip_recurring', 'postpone_recurring']) {
        expect(ConfirmationHandler.requiresConfirmation(AgentToolRegistry.findByName(t)!), isFalse, reason: t);
      }
    });

    test('skip moves the next date one period', () async {
      final s = svc();
      final rec = await seed(s);
      final r = await ToolExecutor(s).execute('skip_recurring', {'recurring_id': rec.id});
      expect(r.verificationStatus, anyOf('confirmed', 'local_pending'));
      final after = (await s.getRecurring()).firstWhere((x) => x.id == rec.id);
      expect(after.nextDate, DateTime(2030, 2, 15));
      expect(await s.getTransactions(), isEmpty);
    });

    test('postpone by days; past date and inactive rule refused', () async {
      final s = svc();
      final rec = await seed(s);
      final r = await ToolExecutor(s).execute('postpone_recurring', {'recurring_id': rec.id, 'days': 3});
      expect(r.verificationStatus, anyOf('confirmed', 'local_pending'));
      final after = (await s.getRecurring()).firstWhere((x) => x.id == rec.id);
      final want = DateTime.now().add(const Duration(days: 3));
      expect([after.nextDate!.year, after.nextDate!.month, after.nextDate!.day], [want.year, want.month, want.day]);
      final past = await ToolExecutor(s).execute('postpone_recurring', {'recurring_id': rec.id, 'new_date': '2001-01-01'});
      expect(past.errorCode, 'INVALID_DATE');
      final off = await seed(s, active: false, category: 'نادي');
      expect(off.isActive, isFalse);
      final inactive = await ToolExecutor(s).execute('skip_recurring', {'recurring_id': off.id});
      expect(inactive.errorCode, 'INACTIVE');
      expect((await s.getRecurring()).firstWhere((x) => x.id == off.id).nextDate, DateTime(2030, 1, 15));
    });

    test('run now: a pick-at-execution rule asks for the bank, then runs in the chosen one', () async {
      final s = svc();
      await s.addBankAccount(bankName: 'الراجحي', currency: 'SAR', openingBalance: 1000);
      final bank = (await s.getBankAccounts()).first;
      final rec = await seed(s, accountType: 'pick_at_execution');
      expect(ConfirmationHandler.requiresConfirmation(AgentToolRegistry.findByName('execute_recurring_now')!), isTrue);
      final ask = await ToolExecutor(s).execute('execute_recurring_now', {'recurring_id': rec.id});
      expect(ask.errorCode, 'NEEDS_ACCOUNT');
      expect(await s.getTransactions(), isEmpty);
      final ran = await ToolExecutor(s).execute('execute_recurring_now', {'recurring_id': rec.id, 'bank_account_id': bank.id});
      expect(ran.entityId, isNotNull);
      final tx = (await s.getTransactions()).firstWhere((t) => t.id == ran.entityId);
      expect(tx.accountId, bank.id);
      expect(tx.amount, 100);
    });
  });
}
