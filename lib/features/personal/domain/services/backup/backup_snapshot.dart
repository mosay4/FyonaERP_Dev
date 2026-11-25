import 'package:shared_preferences/shared_preferences.dart';

import '../../../../../core/database/database_helper.dart';
import '../../../../../core/database/repositories/personal_cache_repository.dart';
import '../../../data/ledger/personal_ledger.dart';
import '../../../data/ledger/personal_ledger_backup.dart';
import '../../../data/ledger/personal_ledger_migration.dart';
import 'backup_integrity.dart';

/// Schema-4.0.0 snapshot builder (Personal only).
///
/// A snapshot has three data pillars:
/// 1. `tables`: verbatim rows of the curated personal tables — the exact
///    source for LOCAL restore (IDs, timestamps, amounts untouched).
/// 2. `entities`: canonical financial entities (IDs preserved, money as
///    exact strings) built from the local mirror — the source for SERVER
///    restore and for validation.
/// 3. `preferences`: typed user-data preferences (StringList-safe).
///
/// Deliberately EXCLUDED (never snapshotted, never restored):
/// sync_queue/sync_log/sync_metadata/sync_cursor/sync_device_info (stale
/// operational state), user_sessions, business tables (untouched by
/// personal backup/restore by design), notification/token/UI caches.
/// Nothing here changes Sync or finance logic — it only reads.
class BackupSnapshotBuilder {
  BackupSnapshotBuilder._();

  /// Verbatim SQLite tables included in a snapshot (local-restore source).
  /// `budget_categories` is included (it was missing before: RC fix).
  /// `users` is included sanitized for reference but NEVER reinserted on
  /// restore (login state is preserved).
  static const List<String> snapshotTables = [
    'personal_wallets',
    'personal_transactions',
    'savings_goals',
    'spending_categories',
    'personal_bank_accounts',
    'personal_bank_transactions',
    'personal_debts',
    'personal_debt_payments',
    'personal_exchange_rates',
    'personal_recurring_transactions',
    'personal_budgets',
    'budget_categories',
    'personal_entity_cache',
    'file_uploads',
    'users',
  ];

  static const List<String> sensitiveUserColumns = [
    'password_hash',
    'mfa_secret',
    'mfa_backup_codes',
    'last_ip',
  ];

  /// User-data preference keys included in a snapshot.
  /// Device/session/token/UI keys are never snapshotted.
  static const List<String> userPrefPrefixes = [
    'enabled_currencies_',
    'money_format_',
    'bank_account_types_',
    'financial_tree_nodes_',
  ];
  static const Set<String> userPrefExactKeys = {
    'wallet_currency',
    'debt_display_currency',
    'backup_auto_sync_enabled',
    'backup_last_sync_row_count',
    'financial_trees_v1',
    'financial_tree_reports_v1',
  };

  /// Mirror entity types that feed the `entities` section.
  static const List<String> mirrorEntityTypes = [
    'personal_bank_account',
    'personal_transaction',
    'personal_savings_goal',
    'personal_debt',
    'personal_budget',
    'personal_recurring_transaction',
  ];

  /// Builds the unsealed 4.0.0 snapshot map (caller seals via
  /// [BackupIntegrity.sealSnapshot]).
  static Future<Map<String, dynamic>> build({
    required int localUserId,
    required String serverUserUuid,
    required String appVersion,
    String source = 'device',
    PersonalCacheRepository? cache,
  }) async {
    final tables = <String, dynamic>{};
    for (final table in snapshotTables) {
      try {
        // Personal tables come from the user's encrypted ledger (same
        // archive shape as before); the rest from the app database.
        var rows = PersonalLedgerBackup.isLedgerTable(table)
            ? await PersonalLedgerBackup.exportTable(table)
            : await DatabaseHelper.query(table);
        if (table == 'users') {
          rows = rows.map((row) {
            final clean = Map<String, dynamic>.from(row);
            for (final col in sensitiveUserColumns) {
              clean.remove(col);
            }
            return clean;
          }).toList();
        }
        tables[table] = rows;
      } catch (_) {
        tables[table] = <Map<String, dynamic>>[];
      }
    }

    final preferences = await _readUserPrefs();
    final entities = await _buildEntities(
      cache ?? PersonalCacheRepository(),
      localUserId,
    );

    final counts = <String, dynamic>{};
    entities.forEach((key, value) {
      if (value is List) counts[key] = value.length;
    });

    return {
      'schema_version': BackupIntegrity.currentSchema,
      'backup_id': BackupIntegrity.newUuid(),
      'created_at': DateTime.now().toIso8601String(),
      'app_version': appVersion,
      'user_uuid': serverUserUuid,
      'local_user_id': localUserId,
      'source': source,
      'counts': counts,
      'tables': tables,
      'preferences': preferences,
      'entities': entities,
      'meta': {'snapshot_quiesced': true},
    };
  }

  /// Typed user preferences (StringList-safe — the old mapper dropped them).
  static Future<Map<String, dynamic>> _readUserPrefs() async {
    final out = <String, dynamic>{};
    try {
      final p = await SharedPreferences.getInstance();
      for (final key in p.getKeys()) {
        final allowed = userPrefExactKeys.contains(key) ||
            userPrefPrefixes.any(key.startsWith);
        if (!allowed) continue;
        final val = p.get(key);
        if (val is bool) {
          out[key] = {'type': 'bool', 'value': val};
        } else if (val is int) {
          out[key] = {'type': 'int', 'value': val};
        } else if (val is double) {
          out[key] = {'type': 'double', 'value': val};
        } else if (val is String) {
          out[key] = {'type': 'string', 'value': val};
        } else if (val is List) {
          out[key] = {
            'type': 'string-list',
            'value': val.map((e) => e.toString()).toList()
          };
        }
      }
    } catch (_) {}
    // Trees and account types now live in the encrypted ledger under the
    // same keys: export them exactly as the preference entries they were.
    try {
      final kv = await PersonalLedgerKv.all();
      for (final e in kv.entries) {
        final allowed = userPrefExactKeys.contains(e.key) ||
            userPrefPrefixes.any(e.key.startsWith);
        if (!allowed) continue;
        final val = e.value;
        if (val is bool) {
          out[e.key] = {'type': 'bool', 'value': val};
        } else if (val is int) {
          out[e.key] = {'type': 'int', 'value': val};
        } else if (val is double) {
          out[e.key] = {'type': 'double', 'value': val};
        } else if (val is String) {
          out[e.key] = {'type': 'string', 'value': val};
        } else if (val is List) {
          out[e.key] = {
            'type': 'string-list',
            'value': val.map((x) => x.toString()).toList(),
          };
        }
      }
    } catch (_) {}
    return out;
  }

  /// Writes typed preferences back (all types incl. StringList).
  static Future<void> writeUserPrefs(Map<String, dynamic> prefs) async {
    try {
      final p = await SharedPreferences.getInstance();
      for (final entry in prefs.entries) {
        final key = entry.key.toString();
        final node = entry.value;
        if (node is! Map) continue;
        final type = node['type']?.toString();
        final value = node['value'];
        if (PersonalLedgerMigration.isLedgerPrefKey(key)) {
          // Restored into the encrypted ledger, never back to plaintext.
          Object? typed;
          switch (type) {
            case 'bool':
              typed = value is bool ? value : null;
            case 'int':
              typed = value is int ? value : null;
            case 'double':
              typed = value is num ? value.toDouble() : null;
            case 'string':
              typed = value?.toString();
            case 'string-list':
              typed = value is List
                  ? value.map((e) => e.toString()).toList()
                  : null;
          }
          if (typed != null) await PersonalLedgerKv.put(key, typed);
          continue;
        }
        switch (type) {
          case 'bool':
            if (value is bool) await p.setBool(key, value);
            break;
          case 'int':
            if (value is int) await p.setInt(key, value);
            break;
          case 'double':
            if (value is num) await p.setDouble(key, value.toDouble());
            break;
          case 'string':
            if (value != null) await p.setString(key, value.toString());
            break;
          case 'string-list':
            if (value is List) {
              await p.setStringList(
                  key, value.map((e) => e.toString()).toList());
            }
            break;
        }
      }
    } catch (_) {}
  }

  /// Exact-money string: keeps the original representation, never computes.
  static String moneyStr(dynamic v) {
    if (v == null) return '0';
    if (v is String) return v.trim().isEmpty ? '0' : v.trim();
    if (v is num) return v.toString();
    return '0';
  }

  /// Canonical entities from the local mirror (server-shaped rows, original
  /// UUIDs kept). Debt payments are derived from debt-linked transactions —
  /// the same derivation the app's own offline fallback uses — with the
  /// transaction UUID as the stable payment id (idempotent across retries).
  static Future<Map<String, dynamic>> _buildEntities(
    PersonalCacheRepository cache,
    int localUserId,
  ) async {
    Map<String, dynamic> asMap(dynamic v) =>
        v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

    Future<List<Map<String, dynamic>>> mirror(String type) async {
      try {
        final rows = await cache.getCollection(localUserId, type);
        return rows.map(asMap).where((m) => m.isNotEmpty).toList();
      } catch (_) {
        return const [];
      }
    }

    final accounts = await mirror('personal_bank_account');
    final txs = await mirror('personal_transaction');
    final goals = await mirror('personal_savings_goal');
    final debts = await mirror('personal_debt');
    final budgets = await mirror('personal_budget');
    final recurring = await mirror('personal_recurring_transaction');

    final entities = <String, dynamic>{
      'accounts': accounts
          .map((m) => {
                'id': m['id']?.toString(),
                'bank_name': m['bank_name']?.toString() ?? '',
                'currency': (m['currency']?.toString() ?? 'SAR'),
                'balance': moneyStr(m['balance']),
                'notes': m['notes']?.toString(),
                if (m['sort_order'] != null) 'sort_order': m['sort_order'],
                if (m['is_active'] != null) 'is_active': m['is_active'],
                'created_at': m['created_at']?.toString(),
                'updated_at': m['updated_at']?.toString(),
              })
          .toList(),
      'transactions': txs
          .map((m) => {
                'id': m['id']?.toString(),
                'tx_type': m['tx_type']?.toString() ?? 'expense',
                'amount': moneyStr(m['amount']),
                'currency': (m['currency']?.toString() ?? 'SAR'),
                'category': m['category']?.toString() ?? '',
                'description': m['description']?.toString(),
                'bank_account_id': m['bank_account_id']?.toString(),
                'budget_id': m['budget_id']?.toString(),
                'budget_category_id': m['budget_category_id']?.toString(),
                'goal_id': m['goal_id']?.toString(),
                'debt_id': m['debt_id']?.toString(),
                'goal_amount':
                    m['goal_amount'] == null ? null : moneyStr(m['goal_amount']),
                'debt_amount':
                    m['debt_amount'] == null ? null : moneyStr(m['debt_amount']),
                'payment_method': m['payment_method']?.toString(),
                'date': m['date']?.toString(),
                'client_operation_id':
                    m['client_operation_id']?.toString(),
                'created_at': m['created_at']?.toString(),
                'updated_at': m['updated_at']?.toString(),
                'exchange_rate': m['exchange_rate'] == null
                    ? null
                    : moneyStr(m['exchange_rate']),
                'exchange_rate_currency':
                    m['exchange_rate_currency']?.toString(),
                'fx_source': m['fx_source']?.toString(),
              })
          .toList(),
      'goals': goals
          .map((m) => {
                'id': m['id']?.toString(),
                'name': m['name']?.toString() ?? '',
                'target_amount': moneyStr(m['target_amount']),
                'current_amount': moneyStr(m['current_amount']),
                'currency': (m['currency']?.toString() ?? 'SAR'),
                'deadline': m['deadline']?.toString(),
                'icon': m['icon']?.toString() ?? 'SAVINGS',
                'notes': m['notes']?.toString(),
                'budget_id': m['budget_id']?.toString(),
                'is_completed': m['is_completed'] == true || m['is_completed'] == 1,
                'created_at': m['created_at']?.toString(),
                'updated_at': m['updated_at']?.toString(),
              })
          .toList(),
      'debts': debts
          .map((m) => {
                'id': m['id']?.toString(),
                'debt_type': m['debt_type']?.toString() ?? 'payable',
                'person_name': m['person_name']?.toString() ?? '',
                'amount': moneyStr(m['amount']),
                'currency': (m['currency']?.toString() ?? 'SAR'),
                'description': m['description']?.toString() ??
                    m['notes']?.toString(),
                'due_date': m['due_date']?.toString(),
                'is_paid': m['is_paid'] == true || m['is_paid'] == 1,
                'reminder': m['reminder'] == true || m['reminder'] == 1,
                'budget_id': m['budget_id']?.toString(),
                'created_at': m['created_at']?.toString(),
                'updated_at': m['updated_at']?.toString(),
              })
          .toList(),
      'budgets': budgets.map((m) {
        final cats = <Map<String, dynamic>>[];
        final rawCats = m['categories'];
        if (rawCats is List) {
          for (final c in rawCats) {
            if (c is! Map) continue;
            final cm = Map<String, dynamic>.from(c);
            cats.add({
              'id': cm['id']?.toString(),
              'name': cm['name']?.toString() ?? '',
              'type': cm['type']?.toString() ?? 'expense',
              'amount': moneyStr(cm['allocated_amount'] ?? cm['amount']),
              if (cm['spent_amount'] != null)
                'spent_amount': moneyStr(cm['spent_amount']),
              'currency': cm['currency']?.toString() ??
                  m['currency']?.toString() ??
                  'SAR',
              'goal_id': cm['goal_id']?.toString(),
              'debt_id': cm['debt_id']?.toString(),
              'created_at': cm['created_at']?.toString(),
              'updated_at': cm['updated_at']?.toString(),
            });
          }
        }
        return {
          'id': m['id']?.toString(),
          'name': m['name']?.toString() ?? '',
          'period_type': m['period_type']?.toString() ?? 'monthly',
          'start_date': m['start_date']?.toString(),
          'end_date': m['end_date']?.toString(),
          'custom_days': m['custom_days'],
          'total_amount': moneyStr(m['total_amount']),
          'currency': (m['currency']?.toString() ?? 'SAR'),
          'bank_account_ids': m['bank_account_ids'],
          'budget_types': m['budget_types'],
          'categories': cats,
          'created_at': m['created_at']?.toString(),
          'updated_at': m['updated_at']?.toString(),
        };
      }).toList(),
      'recurring': recurring
          .map((m) => {
                'id': m['id']?.toString(),
                'name': m['name']?.toString(),
                'tx_type': m['tx_type']?.toString() ?? 'expense',
                'amount': moneyStr(m['amount']),
                'currency': (m['currency']?.toString() ?? 'SAR'),
                'category': m['category']?.toString() ?? '',
                'description': m['description']?.toString(),
                'frequency': m['frequency']?.toString() ?? 'monthly',
                'interval_value': m['interval_value'],
                'next_run_date': m['next_run_date']?.toString() ??
                    m['next_date']?.toString(),
                'account_type': m['account_type']?.toString() ?? 'fixed',
                'bank_account_id': m['bank_account_id']?.toString(),
                'execution_type':
                    m['execution_type']?.toString() ?? 'auto',
                'reminder_time': m['reminder_time']?.toString(),
                'payment_method': m['payment_method']?.toString(),
                'approximate_start_day': m['approximate_start_day'],
                'approximate_end_day': m['approximate_end_day'],
                'last_executed_at': m['last_executed_at']?.toString(),
                'is_active': m['is_active'] == null
                    ? true
                    : (m['is_active'] == true || m['is_active'] == 1),
                'created_at': m['created_at']?.toString(),
                'updated_at': m['updated_at']?.toString(),
              })
          .toList(),
    };

    // Debt payments derived from debt-linked transactions (same derivation
    // as the app's offline getDebtPayments fallback). The transaction UUID
    // doubles as the stable payment id → repeated restores stay identical.
    final payments = <Map<String, dynamic>>[];
    for (final t in txs) {
      final debtId = t['debt_id']?.toString() ?? '';
      if (debtId.isEmpty) continue;
      final txType = t['tx_type']?.toString() ?? '';
      if (txType != 'expense' && txType != 'income') continue;
      final debtAmount = t['debt_amount'];
      final amount = t['amount'];
      payments.add({
        'id': t['id']?.toString(),
        'debt_id': debtId,
        'amount': moneyStr(debtAmount ?? amount),
        'currency': t['currency']?.toString() ?? 'SAR',
        'payment_date': t['date']?.toString(),
        'notes': t['description']?.toString(),
        'budget_id': t['budget_id']?.toString(),
      });
    }
    entities['debt_payments'] = payments;
    return entities;
  }
}
