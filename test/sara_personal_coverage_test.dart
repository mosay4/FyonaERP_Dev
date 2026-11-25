import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/database/repositories/personal_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/features/ai/domain/agent/confirmation_handler.dart';
import 'package:fyona_flutter/features/ai/domain/agent/sara_screen_catalog.dart';
import 'package:fyona_flutter/features/ai/domain/agent/tool_executor.dart';
import 'package:fyona_flutter/features/ai/domain/agent/tool_registry.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:fyona_flutter/shared/widgets/sara_action_dispatcher.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/personal_ledger_test_support.dart';

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

PersonalFinanceService _svc(int uid) {
  final s = PersonalFinanceService(apiClient: ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9'))),
      cache: PersonalCacheRepository(), repo: PersonalRepository());
  s.setUserId(uid);
  return s;
}

void main() {
  group('Personal links open the exact screen', () {
    test('records open their own detail route (entity_id or id)', () {
      expect(saraEntityRoute({'entity_type': 'debt', 'entity_id': 'd1'}), '${RouteNames.personalDebts}?debtId=d1');
      expect(saraEntityRoute({'entity_type': 'goal', 'id': 'g1'}), '/personal/savings-detail/g1');
      expect(saraEntityRoute({'entity_type': 'budget', 'entity_id': 'b1'}), '${RouteNames.personalBudgetDetail}?id=b1');
      expect(saraEntityRoute({'entity_type': 'recurring', 'entity_id': 'r1'}), '${RouteNames.personalRecurringDetail}?id=r1');
      expect(saraEntityRoute({'entity_type': 'recurring'}), RouteNames.personalRecurring);
      expect(saraEntityRoute({'entity_type': 'bank', 'name': 'الراجحي', 'currency': 'sar'}),
          '/personal/bank-detail/${Uri.encodeComponent('الراجحي')}?currency=SAR');
      expect(SaraActionDispatcher.resolveRouteFromActions([
        SaraAction(type: SaraActionType.openEntity, params: {'entity_type': 'debt', 'entity_id': 'x'}),
      ]), '${RouteNames.personalDebts}?debtId=x');
    });

    test('every open_screen name gives a tappable link', () {
      final screens = AgentToolRegistry.findByName('open_screen')!.params.first.allowedValues!;
      for (final screen in screens) {
        expect(SaraActionDispatcher.resolveRoute(screen), isNotNull, reason: screen);
      }
      expect(SaraActionDispatcher.resolveRoute('savings'), RouteNames.personalSavings);
      expect(SaraActionDispatcher.resolveRoute('categories'), RouteNames.personalCategories);
      expect(SaraActionDispatcher.resolveRoute('recurring'), RouteNames.personalRecurring);
    });

    test('«التقارير» goes to the one Personal reports entry point', () {
      for (final name in ['التقارير', 'reports', 'Reports', 'مركز التقارير']) {
        expect(SaraActionDispatcher.resolveRoute(name), saraPersonalReportsRoute, reason: name);
      }
      expect(SaraScreenCatalog.liveRoute(RouteNames.personalReportsCenter), RouteNames.personalReports);
    });
  });

  group('sensitive operations ask first', () {
    test('money moves and balance edits need a confirmation card', () {
      for (final name in ['create_transaction', 'create_transfer', 'contribute_to_goal', 'pay_debt',
        'execute_recurring_now', 'update_bank_account', 'update_debt',
        'delete_bank_account', 'delete_debt', 'delete_savings_goal', 'delete_budget', 'delete_recurring']) {
        expect(ConfirmationHandler.requiresConfirmation(AgentToolRegistry.findByName(name)!), isTrue, reason: name);
      }
    });

    test('a refusal is never read as yes', () {
      expect(ConfirmationHandler.parseConfirmation('نعم'), ConfirmResult.confirmed);
      expect(ConfirmationHandler.parseConfirmation('نعم، نفذ'), ConfirmResult.confirmed);
      expect(ConfirmationHandler.parseConfirmation('لا'), ConfirmResult.cancelled);
      expect(ConfirmationHandler.parseConfirmation('رأيي لا'), ConfirmResult.cancelled);
      expect(ConfirmationHandler.parseConfirmation('أين البنك؟'), ConfirmResult.unknown);
      expect(ConfirmationHandler.parseConfirmation('نعم لا'), ConfirmResult.unknown);
    });
  });

  group('Sara keeps the button rules', () {
    late Directory tmp;
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      tmp = await Directory.systemTemp.createTemp('sara_personal_cov');
      PathProviderPlatform.instance = _FakePath(tmp);
    });

    test('cash cannot be deleted, a transfer cannot exceed the balance, maintenance blocks', () async {
      const uid = 8811;
      await (await testLedger()).rawDelete('DELETE FROM personal_entity_cache WHERE user_id = ?', [uid.toString()]);
      final svc = _svc(uid);
      await svc.addBankAccount(bankName: 'كاش', currency: 'SAR', openingBalance: 100);
      await svc.addBankAccount(bankName: 'الراجحي', currency: 'SAR', openingBalance: 50);
      final accounts = await svc.getBankAccounts();
      final cash = accounts.firstWhere((a) => a.bankName == 'كاش');
      final bank = accounts.firstWhere((a) => a.bankName == 'الراجحي');
      final exec = ToolExecutor(svc);
      final deleted = await exec.execute('delete_bank_account', {'account_id': cash.id});
      expect(deleted.success, isFalse);
      expect(deleted.errorCode, 'CASH_NOT_DELETABLE');
      final transfer = await exec.execute('create_transfer',
          {'from_account_id': bank.id, 'to_account_id': cash.id, 'amount': 80});
      expect(transfer.success, isFalse);
      expect(transfer.errorCode, 'INSUFFICIENT_BALANCE');
      final blocked = ToolExecutor(svc, maintenanceBlocked: (route) => route == '/personal/debts');
      final debt = await blocked.execute('create_debt', {'person_name': 'سالم', 'amount': 5, 'debt_type': 'payable'});
      expect(debt.errorCode, 'MAINTENANCE');
      expect((await svc.getBankAccounts()).length, 2);
    });
  });
}
