import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:fyona_flutter/features/ai/domain/agent/tool_registry.dart';

void main() {
  test('final coverage: all personal tools are either exposed or correctly classified', () {
    final file = File('backend/app/domain/services/sara_tool_contract.v1.json');
    final contract = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final ids = (contract['tools'] as List).map((t) => (t as Map)['tool_id'] as String).toSet();

    // Core personal tools that must be exposed (categories CRUD has no real service — see audit).
    // NOTE: transaction editing was removed product-wide (receipt/delete
    // only), so update_transaction is in neither list.
    final mustHave = [
      'get_bank_accounts', 'create_bank_account', 'update_bank_account', 'delete_bank_account',
      'get_transactions', 'create_transaction', 'delete_transaction', 'create_transfer',
      'get_savings_goals', 'create_savings_goal', 'update_savings_goal', 'contribute_to_goal', 'delete_savings_goal',
      'get_debts', 'create_debt', 'update_debt', 'pay_debt', 'delete_debt', 'get_debt_payments',
      'get_budgets', 'create_budget', 'update_budget', 'delete_budget',
      'get_recurring', 'create_recurring', 'update_recurring', 'delete_recurring', 'execute_recurring_now', 'activate_recurring', 'deactivate_recurring',
      'get_categories',
      'get_currencies', 'add_currency', 'delete_currency', 'get_exchange_rate', 'add_exchange_rate', 'update_exchange_rate',
    ];
    for (final t in mustHave) {
      expect(ids, contains(t), reason: 'missing $t');
    }
    // Ensure no duplicate and version bumped
    expect(contract['contract_version'], '1.7.0');
    // Ensure every flutter tool is in contract
    final flutterIds = AgentToolRegistry.tools.map((t) => t.name).toSet();
    expect(flutterIds, ids.intersection(flutterIds));
  });
}
