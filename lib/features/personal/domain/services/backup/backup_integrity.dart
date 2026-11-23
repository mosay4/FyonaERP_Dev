import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

/// Backup integrity + validation for schema 4.0.0 (Personal only).
///
/// Design rules (P0 financial data):
/// - Canonical encoding (recursively sorted keys, compact) is the ONLY input
///   to checksum/HMAC, so verification is byte-stable across app versions.
/// - SHA-256 checksum detects corruption; HMAC-SHA256 (per-user key)
///   detects tampering. Without the key we report authenticity as
///   *unverified* — we never claim tamper-proofing we cannot prove.
/// - Validation is pure (no I/O) and returns structured issues; the caller
///   maps codes to localized messages. Nothing here touches Sync, finance
///   logic, or any other system.
class BackupIntegrity {
  BackupIntegrity._();

  static const String currentSchema = '4.0.0';
  static const Set<String> readableSchemas = {'4.0.0', '3.0.0'};

  /// Deterministic JSON: maps sorted by key, lists kept in order, compact.
  static String canonicalJson(dynamic value) {
    if (value is Map) {
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      final buf = StringBuffer('{');
      var first = true;
      for (final k in keys) {
        if (!first) buf.write(',');
        first = false;
        buf.write(jsonEncode(k));
        buf.write(':');
        buf.write(canonicalJson(value[k]));
      }
      buf.write('}');
      return buf.toString();
    }
    if (value is List) {
      final buf = StringBuffer('[');
      var first = true;
      for (final e in value) {
        if (!first) buf.write(',');
        first = false;
        buf.write(canonicalJson(e));
      }
      buf.write(']');
      return buf.toString();
    }
    return jsonEncode(value);
  }

  static Map<String, dynamic> _sealable(Map<String, dynamic> snapshot) {
    final copy = Map<String, dynamic>.from(snapshot)
      ..remove('checksum')
      ..remove('hmac');
    return copy;
  }

  static String computeChecksum(Map<String, dynamic> snapshot) {
    return sha256.convert(utf8.encode(canonicalJson(_sealable(snapshot)))).toString();
  }

  /// Empty key → '' (checksum-only mode, authenticity unverified).
  static String computeHmac(Map<String, dynamic> snapshot, String keyB64) {
    if (keyB64.isEmpty) return '';
    try {
      final key = base64.decode(keyB64);
      return Hmac(sha256, key)
          .convert(utf8.encode(canonicalJson(_sealable(snapshot))))
          .toString();
    } catch (_) {
      return '';
    }
  }

  /// Adds `checksum` (always) and `hmac` (when a key is available).
  static Map<String, dynamic> sealSnapshot(
    Map<String, dynamic> snapshot, {
    String hmacKeyB64 = '',
  }) {
    final sealed = Map<String, dynamic>.from(snapshot)
      ..remove('checksum')
      ..remove('hmac');
    sealed['checksum'] = computeChecksum(sealed);
    final hmac = computeHmac(sealed, hmacKeyB64);
    if (hmac.isNotEmpty) sealed['hmac'] = hmac;
    return sealed;
  }

  /// Full pre-restore validation. NEVER touches the database.
  /// [hmacKeyB64] empty → checksum-only, authenticity reported unverified.
  static BackupValidationResult validateSnapshot(
    Map<String, dynamic> data, {
    String hmacKeyB64 = '',
  }) {
    final issues = <BackupIssue>[];

    final schema = data['schema_version']?.toString();
    if (schema == null || schema.isEmpty) {
      issues.add(const BackupIssue('missing_schema'));
      return BackupValidationResult.invalid(issues);
    }
    if (schema != currentSchema) {
      issues.add(BackupIssue('unknown_schema', {'schema': schema}));
      return BackupValidationResult.invalid(issues);
    }

    final createdAt = data['created_at']?.toString();
    if (createdAt == null || createdAt.isEmpty || DateTime.tryParse(createdAt) == null) {
      issues.add(const BackupIssue('bad_date'));
    }

    // Integrity: checksum first (corruption), then HMAC (tampering).
    final storedChecksum = data['checksum']?.toString() ?? '';
    if (storedChecksum.isEmpty) {
      issues.add(const BackupIssue('missing_checksum'));
    } else if (computeChecksum(data) != storedChecksum) {
      issues.add(const BackupIssue('checksum_mismatch'));
      return BackupValidationResult.invalid(issues);
    }
    var authenticity = 'unverified';
    final storedHmac = data['hmac']?.toString() ?? '';
    if (storedHmac.isNotEmpty && hmacKeyB64.isNotEmpty) {
      if (computeHmac(data, hmacKeyB64) == storedHmac) {
        authenticity = 'verified';
      } else {
        issues.add(const BackupIssue('tamper_detected'));
        return BackupValidationResult.invalid(issues);
      }
    }

    // Entity shape validation (mirrors the server dry-run).
    issues.addAll(validateEntities(data['entities']));

    // Declared counts must match actual content.
    final counts = data['counts'];
    if (counts is Map) {
      final entities = data['entities'];
      if (entities is Map) {
        counts.forEach((key, value) {
          final list = entities[key.toString()];
          final actual = list is List ? list.length : 0;
          final declared = value is num ? value.toInt() : -1;
          if (declared >= 0 && declared != actual) {
            issues.add(BackupIssue('count_mismatch', {'entity': key.toString()}));
          }
        });
      }
    }

    if (issues.isEmpty) {
      return BackupValidationResult.valid(authenticity: authenticity);
    }
    return BackupValidationResult.invalid(issues, authenticity: authenticity);
  }

  /// Validates the `entities` section shape. Pure; shared semantics with the
  /// server-side dry run (field names must stay in sync with
  /// `personal_finance.py::_validate_restore_payload`).
  static List<BackupIssue> validateEntities(dynamic entities) {
    final issues = <BackupIssue>[];
    if (entities == null) {
      issues.add(const BackupIssue('missing_entities'));
      return issues;
    }
    if (entities is! Map) {
      issues.add(const BackupIssue('bad_entities'));
      return issues;
    }

    List<Map<String, dynamic>> section(String name) {
      final raw = entities[name];
      if (raw == null) return const [];
      if (raw is! List) {
        issues.add(BackupIssue('bad_section', {'entity': name}));
        return const [];
      }
      final out = <Map<String, dynamic>>[];
      for (var i = 0; i < raw.length; i++) {
        final e = raw[i];
        if (e is! Map) {
          issues.add(BackupIssue('bad_row', {'entity': '$name[$i]'}));
          continue;
        }
        out.add(Map<String, dynamic>.from(e));
      }
      return out;
    }

    final accounts = section('accounts');
    final transactions = section('transactions');
    final goals = section('goals');
    final debts = section('debts');
    final payments = section('debt_payments');
    final budgets = section('budgets');
    final recurring = section('recurring');

    Set<String> idsOf(List<Map<String, dynamic>> items, String label) {
      final seen = <String>{};
      for (var i = 0; i < items.length; i++) {
        final id = items[i]['id']?.toString() ?? '';
        if (id.isEmpty || !_isUuid(id)) {
          issues.add(BackupIssue('bad_uuid', {'entity': '$label[$i]'}));
          continue;
        }
        if (!seen.add(id)) {
          issues.add(BackupIssue('duplicate_id', {'entity': '$label[$i]'}));
        }
      }
      return seen;
    }

    final accIds = idsOf(accounts, 'accounts');
    idsOf(transactions, 'transactions');
    final goalIds = idsOf(goals, 'goals');
    final debtIds = idsOf(debts, 'debts');
    idsOf(payments, 'debt_payments');
    final budIds = idsOf(budgets, 'budgets');
    idsOf(recurring, 'recurring');

    final catIds = <String>{};
    for (var bi = 0; bi < budgets.length; bi++) {
      final cats = budgets[bi]['categories'];
      if (cats == null) continue;
      if (cats is! List) {
        issues.add(BackupIssue('bad_section', {'entity': 'budgets[$bi].categories'}));
        continue;
      }
      for (var ci = 0; ci < cats.length; ci++) {
        final c = cats[ci];
        if (c is! Map) {
          issues.add(BackupIssue('bad_row', {'entity': 'budgets[$bi].categories[$ci]'}));
          continue;
        }
        final id = c['id']?.toString() ?? '';
        if (id.isEmpty || !_isUuid(id)) {
          issues.add(BackupIssue('bad_uuid', {'entity': 'budgets[$bi].categories[$ci]'}));
          continue;
        }
        if (!catIds.add(id)) {
          issues.add(BackupIssue('duplicate_id', {'entity': 'budgets[$bi].categories[$ci]'}));
        }
      }
    }

    String? ref(dynamic raw, Set<String> allowed, String field) {
      if (raw == null || raw.toString().isEmpty) return null;
      final key = raw.toString();
      if (!_isUuid(key)) {
        issues.add(BackupIssue('bad_uuid', {'entity': field}));
        return null;
      }
      if (!allowed.contains(key)) {
        issues.add(BackupIssue('orphan', {'entity': field}));
        return null;
      }
      return key;
    }

    void money(dynamic raw, String field) {
      if (raw == null) {
        issues.add(BackupIssue('missing_field', {'entity': field}));
        return;
      }
      if (!_isMoney(raw)) {
        issues.add(BackupIssue('bad_amount', {'entity': field}));
      }
    }

    void text(dynamic raw, String field, {bool required = false}) {
      if (raw == null) {
        if (required) issues.add(BackupIssue('missing_field', {'entity': field}));
        return;
      }
      if (required && raw.toString().trim().isEmpty) {
        issues.add(BackupIssue('missing_field', {'entity': field}));
      }
    }

    for (var i = 0; i < accounts.length; i++) {
      final a = accounts[i];
      text(a['bank_name'], 'accounts[$i].bank_name', required: true);
      money(a['balance'] ?? 0, 'accounts[$i].balance');
      text(a['currency'], 'accounts[$i].currency', required: true);
    }
    for (var i = 0; i < transactions.length; i++) {
      final t = transactions[i];
      text(t['tx_type'], 'transactions[$i].tx_type', required: true);
      money(t['amount'], 'transactions[$i].amount');
      if (t['category'] == null) {
        issues.add(BackupIssue('missing_field', {'entity': 'transactions[$i].category'}));
      }
      ref(t['bank_account_id'], accIds, 'transactions[$i].bank_account_id');
      ref(t['goal_id'], goalIds, 'transactions[$i].goal_id');
      ref(t['debt_id'], debtIds, 'transactions[$i].debt_id');
      ref(t['budget_id'], budIds, 'transactions[$i].budget_id');
      ref(t['budget_category_id'], catIds, 'transactions[$i].budget_category_id');
      for (final k in ['goal_amount', 'debt_amount', 'exchange_rate']) {
        if (t[k] != null) money(t[k], 'transactions[$i].$k');
      }
    }
    for (var i = 0; i < goals.length; i++) {
      final g = goals[i];
      text(g['name'], 'goals[$i].name', required: true);
      money(g['target_amount'], 'goals[$i].target_amount');
      ref(g['budget_id'], budIds, 'goals[$i].budget_id');
    }
    for (var i = 0; i < debts.length; i++) {
      final d = debts[i];
      final dtype = d['debt_type']?.toString();
      if (dtype != 'payable' && dtype != 'receivable') {
        issues.add(BackupIssue('bad_value', {'entity': 'debts[$i].debt_type'}));
      }
      text(d['person_name'], 'debts[$i].person_name', required: true);
      money(d['amount'], 'debts[$i].amount');
      ref(d['budget_id'], budIds, 'debts[$i].budget_id');
    }
    for (var i = 0; i < payments.length; i++) {
      final p = payments[i];
      if (p['debt_id'] == null || p['debt_id'].toString().isEmpty) {
        issues.add(BackupIssue('missing_field', {'entity': 'debt_payments[$i].debt_id'}));
      } else {
        ref(p['debt_id'], debtIds, 'debt_payments[$i].debt_id');
      }
      money(p['amount'], 'debt_payments[$i].amount');
      ref(p['budget_id'], budIds, 'debt_payments[$i].budget_id');
    }
    for (var bi = 0; bi < budgets.length; bi++) {
      final b = budgets[bi];
      text(b['name'], 'budgets[$bi].name', required: true);
      money(b['total_amount'], 'budgets[$bi].total_amount');
      final cats = b['categories'];
      if (cats is List) {
        for (var ci = 0; ci < cats.length; ci++) {
          final c = cats[ci];
          if (c is! Map) continue;
          final Map cm = c;
          text(cm['name'], 'budgets[$bi].categories[$ci].name', required: true);
          money(cm['amount'], 'budgets[$bi].categories[$ci].amount');
          ref(cm['goal_id'], goalIds, 'budgets[$bi].categories[$ci].goal_id');
          ref(cm['debt_id'], debtIds, 'budgets[$bi].categories[$ci].debt_id');
        }
      }
    }
    for (var i = 0; i < recurring.length; i++) {
      final r = recurring[i];
      text(r['tx_type'], 'recurring[$i].tx_type', required: true);
      money(r['amount'], 'recurring[$i].amount');
      if (r['category'] == null) {
        issues.add(BackupIssue('missing_field', {'entity': 'recurring[$i].category'}));
      }
      const freqs = {'daily', 'weekly', 'monthly', 'yearly'};
      if (r['frequency'] != null && !freqs.contains(r['frequency'].toString())) {
        issues.add(BackupIssue('bad_value', {'entity': 'recurring[$i].frequency'}));
      }
      ref(r['bank_account_id'], accIds, 'recurring[$i].bank_account_id');
    }
    return issues;
  }

  static final _uuidRe = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  static bool _isUuid(String v) => _uuidRe.hasMatch(v);

  /// Exact-money check: numeric or numeric-string, finite, parseable.
  /// Comparison elsewhere MUST use string/Decimal semantics, never double.
  static bool _isMoney(dynamic v) {
    if (v is num) return v.isFinite;
    if (v is String) {
      final t = v.trim();
      if (t.isEmpty) return false;
      return double.tryParse(t) != null &&
          !t.toLowerCase().contains('nan') &&
          !t.toLowerCase().contains('inf');
    }
    return false;
  }

  /// Migrate a schema-3.0.0 snapshot to 4.0.0 shape. The old file already
  /// carries raw tables + a lossy `personal_finance` mirror; the migration
  /// re-wraps with 4.0.0 metadata, normalizes preferences to typed form,
  /// rebuilds `entities` from the old mirror section (amounts as strings,
  /// original IDs kept), and recomputes counts. Anything unmigratable
  /// throws (caller must refuse, never partial-restore).
  static Map<String, dynamic> migrate30to40(
    Map<String, dynamic> old, {
    required String serverUserUuid,
    required int localUserId,
    required String appVersion,
  }) {
    if (old['schema_version']?.toString() != '3.0.0') {
      throw const BackupMigrationError('not_a_30_snapshot');
    }
    String moneyStr(dynamic v) {
      if (v == null) return '0';
      if (v is String) return v.trim().isEmpty ? '0' : v.trim();
      if (v is num) return v.toString();
      return '0';
    }

    Map<String, dynamic> asMap(dynamic v) =>
        v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
    List<Map<String, dynamic>> asList(dynamic v) {
      if (v is! List) return const [];
      return v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }

    final pf = asMap(old['personal_finance']);
    final entities = <String, dynamic>{
      'accounts': asList(pf['bank_accounts']),
      'transactions': asList(pf['transactions']),
      'goals': asList(pf['savings_goals']),
      'debts': asList(pf['debts']),
      'debt_payments': const [],
      'budgets': asList(pf['budgets']).map((b) {
        final m = Map<String, dynamic>.from(b);
        m['total_amount'] = moneyStr(m['total_amount'] ?? m['amount']);
        m['period_type'] = (m['period_type'] ?? 'monthly').toString();
        final cats = asList(m['categories']).map((c) {
          final cm = Map<String, dynamic>.from(c);
          cm['amount'] = moneyStr(cm['amount'] ?? cm['allocated_amount']);
          // Old files carry categories without IDs: mint stable UUIDs now
          // so the migrated snapshot validates and links resolve.
          final cid = cm['id']?.toString() ?? '';
          if (!_isUuid(cid)) cm['id'] = newUuid();
          return cm;
        }).toList();
        m['categories'] = cats;
        return m;
      }).toList(),
      'recurring': asList(pf['recurring']),
    };
    // Normalize every money field to its exact string form.
    for (final a in entities['accounts'] as List) {
      (a as Map<String, dynamic>)['balance'] = moneyStr(a['balance']);
    }
    for (final t in entities['transactions'] as List) {
      final m = t as Map<String, dynamic>;
      m['amount'] = moneyStr(m['amount']);
      for (final k in ['goal_amount', 'debt_amount', 'exchange_rate']) {
        if (m[k] != null) m[k] = moneyStr(m[k]);
      }
    }
    for (final g in entities['goals'] as List) {
      final m = g as Map<String, dynamic>;
      m['target_amount'] = moneyStr(m['target_amount']);
      m['current_amount'] = moneyStr(m['current_amount']);
    }
    for (final d in entities['debts'] as List) {
      (d as Map<String, dynamic>)['amount'] = moneyStr(d['amount']);
    }

    // Old `shared_preferences` were raw values: normalize to typed form.
    final typedPrefs = <String, dynamic>{};
    final oldPrefs = asMap(old['shared_preferences']);
    oldPrefs.forEach((key, value) {
      final k = key.toString();
      if (value is bool) {
        typedPrefs[k] = {'type': 'bool', 'value': value};
      } else if (value is int) {
        typedPrefs[k] = {'type': 'int', 'value': value};
      } else if (value is double) {
        typedPrefs[k] = {'type': 'double', 'value': value};
      } else if (value is String) {
        typedPrefs[k] = {'type': 'string', 'value': value};
      } else if (value is List) {
        typedPrefs[k] = {
          'type': 'string-list',
          'value': value.map((e) => e.toString()).toList()
        };
      }
    });

    final tables = <String, dynamic>{};
    old.forEach((key, value) {
      final k = key.toString();
      if (value is List &&
          k != 'checksum' &&
          k != 'hmac' &&
          k != 'personal_finance' &&
          k != 'shared_preferences') {
        tables[k] = value;
      }
    });

    final counts = <String, dynamic>{};
    entities.forEach((key, value) {
      if (value is List) counts[key.toString()] = value.length;
    });

    return {
      'schema_version': currentSchema,
      'backup_id': newUuid(),
      'created_at': DateTime.now().toIso8601String(),
      'app_version': appVersion,
      'user_uuid': serverUserUuid,
      'local_user_id': localUserId,
      'source': 'device',
      'counts': counts,
      'tables': tables,
      'preferences': typedPrefs,
      'entities': entities,
      'meta': {
        'migrated_from': '3.0.0',
        'migrated_at': DateTime.now().toIso8601String(),
      },
    };
  }

  /// Random UUID v4 (no new dependency: uses dart:math secure random).
  static String newUuid() {
    final r = math.Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String h(List<int> x) =>
        x.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
    return '${h(b.sublist(0, 4))}-${h(b.sublist(4, 6))}-'
        '${h(b.sublist(6, 8))}-${h(b.sublist(8, 10))}-${h(b.sublist(10, 16))}';
  }
}

class BackupIssue {
  final String code;
  final Map<String, dynamic> params;
  const BackupIssue(this.code, [Map<String, dynamic>? params])
      : params = params ?? const {};
}

class BackupValidationResult {
  final bool ok;
  final List<BackupIssue> errors;
  final String authenticity; // 'verified' | 'unverified'

  const BackupValidationResult._(this.ok, this.errors, this.authenticity);

  factory BackupValidationResult.valid({String authenticity = 'unverified'}) =>
      BackupValidationResult._(true, const [], authenticity);

  factory BackupValidationResult.invalid(List<BackupIssue> errors,
          {String authenticity = 'unverified'}) =>
      BackupValidationResult._(false, errors, authenticity);
}

class BackupMigrationError implements Exception {
  final String code;
  const BackupMigrationError(this.code);
}
