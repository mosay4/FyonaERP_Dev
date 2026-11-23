import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/core/services/currency/enabled_currencies_service.dart'
    show loadEnabledCurrencies, saveEnabledCurrencies;
import 'package:fyona_flutter/core/utils/currency_formatter.dart';
import 'agent_trace.dart';
import 'sara_currency_names.dart';
import 'param_normalizer.dart';
import 'sara_money.dart';
import 'verification_gateway.dart';
import '../../../personal/domain/services/personal_finance_service.dart';
import '../../../personal/data/models/personal_models.dart';

/// Single source of truth for Sara bubble tone. Callers must use this —
/// never map success/bool to emoji on their own (that is exactly how
/// pending-verification states used to render as false ✅/❌).
String saraToneOf(ToolExecutionResult r) {
  switch (r.verificationStatus) {
    case 'local_pending':
      return '⏳';
    case 'unverifiable':
      return '⚠️';
    default:
      return r.success ? '✅' : '❌';
  }
}

/// Safe type conversion helpers — prevents 'String is not subtype of num' errors.
/// Handles Arabic-Indic / Persian digits and Arabic separators too.
num? _toNum(dynamic v) {
  if (v == null) return null;
  if (v is num) return v;
  if (v is String) {
    final cleaned = ParamNormalizer.normalizeDigits(v)
        .replaceAll(RegExp(r'[,\s]'), '')
        .replaceAll(RegExp(r'[^\d.\-]'), '');
    return num.tryParse(cleaned);
  }
  return null;
}

int? _toInt(dynamic v) => _toNum(v)?.toInt();
double? _toDouble(dynamic v) => _toNum(v)?.toDouble();

/// Backend error → clean one-line Arabic message (never raw DioException).
String _cleanError(Object e, String fallback) {
  final s = e.toString();
  // DioException: prefer the server-provided message/detail.
  final detailMatch = RegExp(r"'detail':\s*'([^']+)'").firstMatch(s);
  if (detailMatch != null) return detailMatch.group(1)!;
  final msgMatch = RegExp(r"'message':\s*'([^']+)'").firstMatch(s);
  if (msgMatch != null) return msgMatch.group(1)!;
  // Pydantic 422 bodies: surface the first human-readable bit.
  final ctxMatch = RegExp(r'"msg":\s*"([^"]+)"').firstMatch(s);
  if (ctxMatch != null) return 'بيانات غير صالحة: ${ctxMatch.group(1)}';
  return fallback;
}

/// Backend UUID for entity ids. Returns null for null/empty values.
/// Entity ids are UUID strings end to end — never ints, never 0.
String? _toId(dynamic v) {
  if (v == null) return null;
  if (v is num) {
    if (v == 0) return null;
    return v.toString();
  }
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

/// Structured result of a tool execution.
///
/// Unified P2 result shape: every tool returns at least success/state,
/// tool, operation/entity identity, user message/data, error info,
/// retryability and verification. `verified` is true ONLY for a confirmed
/// write (or an error-free read payload carrying no verification claim) —
/// a WRITE never reports success=true while unverified (the gateway sets
/// success=true solely on successConfirmed).
class ToolExecutionResult {
  final String tool;
  final bool success;
  final String messageAr;
  final String messageEn;
  final String? entityId;
  final String? entityType;
  final String? route;
  final String? verificationStatus;
  final Map<String, dynamic>? data;
  final String? errorCode;
  final String? operationId;
  final bool retryable;
  final bool verified;

  const ToolExecutionResult({
    required this.tool,
    required this.success,
    required this.messageAr,
    required this.messageEn,
    this.entityId,
    this.entityType,
    this.route,
    this.verificationStatus,
    this.data,
    this.errorCode,
    this.operationId,
    this.retryable = false,
    this.verified = false,
  });

  String message(String lang) => lang == 'ar' ? messageAr : messageEn;
}

/// Executes tools using PersonalFinanceService.
/// Each tool: execute → verify (via [SaraVerificationGateway]) → return result.
class ToolExecutor {
  final PersonalFinanceService _service;
  final SaraVerificationGateway _verify;
  final CurrencyEngine? _fxEngine;

  ToolExecutor(
    this._service, {
    SaraVerificationGateway? verify,
    ApiClient? apiClient,
    CurrencyEngine? fxEngine,
  })  : _fxEngine = fxEngine,
        _verify = verify ??
            SaraVerificationGateway.forService(
              _service,
              apiClient: apiClient,
            );

  /// Maps a gateway verdict to the tool result contract. The ONLY place
  /// where success/message/tone are derived — tool methods must not invent
  /// their own success claims.
  ToolExecutionResult _adapt(
    SaraVerificationResult v, {
    required String tool,
    String? entityType,
    String? route,
    Map<String, dynamic>? data,
  }) {
    final saraType = v.queueEntityType == null
        ? entityType
        : (SaraVerificationGateway.saraTypeFor(v.queueEntityType!) ??
            entityType);
    final confirmed = v.state == SaraVerificationState.successConfirmed;
    return ToolExecutionResult(
      tool: tool,
      success: confirmed,
      messageAr: v.messageAr,
      messageEn: v.messageEn,
      entityId: v.entityId,
      entityType: saraType,
      route: route ?? v.route,
      verificationStatus: _statusString(v.state),
      data: {...?v.data, ...?data},
      errorCode: v.errorCode,
      // The entity id is the operation reference for gateway writes.
      operationId: v.entityId,
      // Only confirmed writes are verified; failed/pending states may be
      // retried except contract-level rejections (none here — all gateway
      // failures are retryable by nature).
      retryable: !confirmed,
      verified: confirmed,
    );
  }

  static String _statusString(SaraVerificationState s) {
    switch (s) {
      case SaraVerificationState.successConfirmed:
        return 'confirmed';
      case SaraVerificationState.successLocalPendingSync:
        return 'local_pending';
      case SaraVerificationState.failed:
        return 'failed';
      case SaraVerificationState.verificationFailed:
        return 'unverifiable';
      case SaraVerificationState.notFound:
        return 'not_found';
      case SaraVerificationState.syncFailed:
        return 'sync_failed';
    }
  }

  /// Exact-field resolver for just-created rows (used only to obtain the
  /// real ID; every later stage is strictly by that ID). Returns the last
  /// exact match or null.
  Future<String?> _resolveCreatedId(
    Future<List<dynamic>> Function() listOf,
    bool Function(Map<String, dynamic>) matches,
  ) async {
    final list = await listOf();
    Map<String, dynamic>? best;
    for (final e in list) {
      late Map<String, dynamic> m;
      try {
        m = Map<String, dynamic>.from((e as dynamic).toJson() as Map);
      } catch (_) {
        continue;
      }
      if (matches(m)) best = m;
    }
    return best?['id']?.toString();
  }

  /// Execute a tool by name with params.
  Future<ToolExecutionResult> execute(String toolName, Map<String, dynamic> params) async {
    final trace = AgentTraceBuilder()..start('')..setTool(toolName)..setToolArgs(params);
    final sw = Stopwatch()..start();

    try {
      if (const {'create_transaction', 'create_transfer', 'create_bank_account', 'create_debt', 'pay_debt', 'contribute_to_goal', 'create_recurring', 'create_budget', 'create_savings_goal'}.contains(toolName)) {
        final enabled = await loadEnabledCurrencies(_service.currentUserId.toString());
        final requested = params.entries.where((e) => e.key == 'currency' || e.key.endsWith('_currency'))
            .map((e) => saraCurrencyId('${e.value}')).where((c) => c.isNotEmpty).toSet();
        final ids = params.entries.where((e) => const {'account_id', 'bank_account_id', 'from_account_id', 'to_account_id'}.contains(e.key))
            .map((e) => '${e.value}').toSet();
        if (ids.isNotEmpty) {
          for (final account in await _service.getBankAccounts()) {
            if (ids.contains(account.id)) requested.add(saraCurrencyId(account.currency));
          }
        }
        final denied = requested.difference(enabled);
        if (denied.isNotEmpty) return ToolExecutionResult(tool: toolName, success: false,
          messageAr: 'فعّل العملة أولًا ثم أعد العملية: ${denied.map((c) => currencyName(c, locale: 'ar')).join('، ')}',
          messageEn: 'Enable the currency first: ${denied.join(', ')}', errorCode: 'CURRENCY_NOT_ENABLED', verified: false);
      }
      final result = await _executeTool(toolName, params);
      sw.stop();
      trace
        ..setExecution(result.success, result.messageAr)
        ..setVerification(result.verificationStatus ?? 'skipped');
      AgentTraceStore.instance.record(trace.build(elapsed: sw.elapsedMilliseconds));
      return result;
    } catch (e, st) {
      sw.stop();
      debugPrint('ToolExecutor error ($toolName): $e\n$st');
      trace
        ..setExecution(false, e.toString())
        ..setError(e.toString());
      AgentTraceStore.instance.record(trace.build(elapsed: sw.elapsedMilliseconds));
      // Extract a user-friendly message from DioExceptions
      String friendlyMsg;
      if (e is DioException) {
        final statusCode = e.response?.statusCode;
        if (statusCode == 422) {
          friendlyMsg = 'البيانات المُرسلة غير صالحة — تأكد من صحة المعرفات والمبالغ.';
        } else if (statusCode == 404) {
          friendlyMsg = 'العنصر المطلوب غير موجود.';
        } else if (statusCode == 401 || statusCode == 403) {
          friendlyMsg = 'ليس لديك صلاحية لتنفيذ هذا الإجراء.';
        } else {
          friendlyMsg = 'خطأ في الاتصال بالخادم (كود: $statusCode).';
        }
      } else {
        friendlyMsg = 'حدث خطأ غير متوقع.';
      }
      return ToolExecutionResult(
        tool: toolName,
        success: false,
        messageAr: friendlyMsg,
        messageEn: friendlyMsg,
        errorCode: 'EXECUTION_ERROR',
        retryable: true,
        verified: false,
      );
    }
  }

  Future<ToolExecutionResult> _executeTool(String name, Map<String, dynamic> p) async {
    switch (name) {
      // ═══════ READ TOOLS ═══════
      case 'get_balance': return _getBalance(p);
      case 'get_bank_accounts': return _getBankAccounts();
      case 'get_transactions': return _getTransactions(p);
      case 'get_savings_goals': return _getSavingsGoals();
      case 'get_debts': return _getDebts();
      case 'get_budgets': return _getBudgets();
      case 'get_recurring': return _getRecurring();
      case 'get_categories': return _getCategories();
      case 'search_entity': return _searchEntity(p);
      case 'get_entity_detail': return _getEntityDetail(p);
      case 'get_operation_status': return _getOperationStatus(p);

      // ═══════ WRITE TOOLS — TRANSACTIONS ═══════
      case 'create_transaction': return _createTransaction(p);
      case 'create_transfer': return _createTransfer(p);
      case 'delete_transaction': return _deleteTransaction(p);

      // ═══════ WRITE TOOLS — BANK ACCOUNTS ═══════
      case 'create_bank_account': return _createBankAccount(p);
      case 'update_bank_account': return _updateBankAccount(p);
      case 'delete_bank_account': return _deleteBankAccount(p);

      // ═══════ WRITE TOOLS — SAVINGS GOALS ═══════
      case 'create_savings_goal': return _createSavingsGoal(p);
      case 'update_savings_goal': return _updateSavingsGoal(p);
      case 'contribute_to_goal': return _contributeToGoal(p);
      case 'delete_savings_goal': return _deleteSavingsGoal(p);

      // ═══════ WRITE TOOLS — DEBTS ═══════
      case 'create_debt': return _createDebt(p);
      case 'update_debt': return _updateDebt(p);
      case 'pay_debt': return _payDebt(p);
      case 'delete_debt': return _deleteDebt(p);

      // ═══════ WRITE TOOLS — BUDGETS ═══════
      case 'create_budget': return _createBudget(p);
      case 'update_budget': return _updateBudget(p);
      case 'delete_budget': return _deleteBudget(p);

      // ═══════ WRITE TOOLS — RECURRING ═══════
      case 'create_recurring': return _createRecurring(p);
      case 'update_recurring': return _updateRecurring(p);
      case 'delete_recurring': return _deleteRecurring(p);
      case 'execute_recurring_now': return _executeRecurringNow(p);
      case 'activate_recurring': return _activateRecurring(p);
      case 'deactivate_recurring': return _deactivateRecurring(p);

      // ═══════ CURRENCIES & EXCHANGE RATES ═══════
      case 'get_currencies': return _getCurrencies();
      case 'add_currency': return _addCurrency(p);
      case 'delete_currency': return _deleteCurrency(p);
      case 'get_exchange_rate': return _getExchangeRate(p);
      case 'add_exchange_rate': return _addExchangeRate(p);
      case 'update_exchange_rate': return _updateExchangeRate(p);

      // ═══════ DEBT PAYMENTS ═══════
      case 'get_debt_payments': return _getDebtPayments(p);

      default:
        return ToolExecutionResult(
          tool: name, success: false,
          messageAr: 'أداة غير معروفة: $name',
          messageEn: 'Unknown tool: $name',
          errorCode: 'UNKNOWN_TOOL',
          retryable: false,
          verified: false,
        );
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  READ TOOLS
  // ═══════════════════════════════════════════════════════════════

  Future<ToolExecutionResult> _getBalance(Map<String, dynamic> p) async {
    final accounts = await _service.getBankAccounts();
    final totals = groupAmounts(
      accounts,
      (a) => a.balance,
      (a) => a.currency,
    );
    final details = accounts
        .map((a) =>
            '${a.bankName}: ${fmtNum(a.balance)} ${saraCurrencyId(a.currency)}')
        .join('\n');
    final target = saraCurrencyId(p['currency'] as String? ?? '');
    // Optional unified total: engine rates only, never invented.
    String? convertedLine;
    String? convertedLineEn;
    Map<String, dynamic>? convertedData;
    if (target.isNotEmpty && totals.isNotEmpty) {
      final conv = convertBuckets(
        totals,
        target,
        (from, to) => _fxEngine?.getRate(from, to),
      );
      if (conv.missing.isEmpty) {
        convertedLine =
            'الإجمالي المحوّل إلى $target: ${fmtNum(conv.total)}';
        convertedLineEn =
            'Total converted to $target: ${fmtNum(conv.total)}';
        convertedData = {
          'target_currency': target,
          'converted_total': conv.total,
        };
      } else {
        convertedLine =
            'تعذر التحويل إلى $target: لا يوجد سعر صرف صالح لـ ${conv.missing.join('، ')} — المبالغ أعلاه مفصولة حسب العملة.';
        convertedLineEn =
            'Cannot convert to $target: no valid rate for ${conv.missing.join(', ')} — amounts above stay separated by currency.';
      }
    }
    final breakdown = formatBreakdown(totals, arabic: true);
    final breakdownEn = formatBreakdown(totals, arabic: false);
    return ToolExecutionResult(
      tool: 'get_balance',
      success: true,
      messageAr: 'الأرصدة حسب العملة:\n$breakdown\n$details'
          '${convertedLine == null ? '' : '\n$convertedLine'}',
      messageEn: 'Balances by currency:\n$breakdownEn\n$details'
          '${convertedLineEn == null ? '' : '\n$convertedLineEn'}',
      data: {
        'by_currency': totals.map((k, v) => MapEntry(k, {
              'currency_id': k,
              'currency': k,
              'amount': v,
            })),
        if (convertedData != null) ...convertedData,
        'accounts': accounts.length,
      },
      verificationStatus: 'verified',
    );
  }

  Future<ToolExecutionResult> _getBankAccounts() async {
    final accounts = await _service.getBankAccounts();
    final list = accounts.map((a) => {
      'id': a.id, 'name': a.bankName, 'balance': a.balance,
      'currency': a.currency, 'type': a.accountType,
    }).toList();
    return ToolExecutionResult(
      tool: 'get_bank_accounts', success: true,
      messageAr: 'لديك ${accounts.length} حساب بنكي',
      messageEn: 'You have ${accounts.length} bank accounts',
      data: {'accounts': list},
      verificationStatus: 'verified',
    );
  }

  Future<ToolExecutionResult> _getTransactions(Map<String, dynamic> p) async {
    final txs = await _service.getTransactions(
      accountId: _toId(p['account_id']),
      month: _toInt(p['month']) ?? 0,
      year: _toInt(p['year']) ?? 0,
    );
    final income = groupAmounts(
      txs.where((t) => t.type == 'income'),
      (t) => t.amount,
      (t) => t.currency,
    );
    final expense = groupAmounts(
      txs.where((t) => t.type != 'income'),
      (t) => t.amount,
      (t) => t.currency,
    );
    return ToolExecutionResult(
      tool: 'get_transactions', success: true,
      messageAr: 'تم العثور على ${txs.length} معاملة\n'
          'الدخل ${formatBreakdown(income, arabic: true)}\n'
          'المصروف ${formatBreakdown(expense, arabic: true)}',
      messageEn: 'Found ${txs.length} transactions\n'
          'Income ${formatBreakdown(income, arabic: false)}\n'
          'Expense ${formatBreakdown(expense, arabic: false)}',
      data: {
        'count': txs.length,
        'income_by_currency': income,
        'expense_by_currency': expense,
      },
      verificationStatus: 'verified',
    );
  }

  Future<ToolExecutionResult> _getSavingsGoals() async {
    final goals = await _service.getSavingsGoals();
    final list = goals.map((g) => {
      'id': g.id, 'name': g.name, 'target': g.targetAmount,
      'current': g.currentAmount,
      'currency_id': saraCurrencyId(g.currency),
      'currency': saraCurrencyId(g.currency),
      'progress': '${(g.progress * 100).round()}%',
    }).toList();
    final targets = groupAmounts(
      goals, (g) => g.targetAmount, (g) => g.currency);
    final currents = groupAmounts(
      goals, (g) => g.currentAmount, (g) => g.currency);
    return ToolExecutionResult(
      tool: 'get_savings_goals', success: true,
      messageAr: 'لديك ${goals.length} أهداف ادخار\n'
          'المستهدف ${formatBreakdown(targets, arabic: true)}\n'
          'الحالي ${formatBreakdown(currents, arabic: true)}',
      messageEn: 'You have ${goals.length} savings goals\n'
          'Target ${formatBreakdown(targets, arabic: false)}\n'
          'Current ${formatBreakdown(currents, arabic: false)}',
      data: {'goals': list},
      verificationStatus: 'verified',
    );
  }

  Future<ToolExecutionResult> _getDebts() async {
    final debts = await _service.getDebts();
    final list = debts.map((d) => {
      'id': d.id, 'person_name': d.personName, 'amount': d.amount,
      'paid': d.paid, 'remaining': d.remaining,
      'currency_id': saraCurrencyId(d.currency),
      'currency': saraCurrencyId(d.currency),
    }).toList();
    final outstanding = groupAmounts(
      debts, (d) => d.remaining, (d) => d.currency);
    return ToolExecutionResult(
      tool: 'get_debts', success: true,
      messageAr: 'لديك ${debts.length} ديون\n'
          'المتبقي ${formatBreakdown(outstanding, arabic: true)}',
      messageEn: 'You have ${debts.length} debts\n'
          'Outstanding ${formatBreakdown(outstanding, arabic: false)}',
      data: {'debts': list, 'count': debts.length},
      verificationStatus: 'verified',
    );
  }

  Future<ToolExecutionResult> _getBudgets() async {
    final now = DateTime.now();
    final budgets = await _service.getBudgets(now.month, now.year);
    final list = budgets.map((b) => {
      'id': b.id, 'name': b.name, 'total_amount': b.totalAmount,
      'spent': b.totalSpent,
      'currency_id': saraCurrencyId(b.currency),
      'currency': saraCurrencyId(b.currency),
    }).toList();
    final allocated = groupAmounts(
      budgets, (b) => b.totalAmount, (b) => b.currency);
    return ToolExecutionResult(
      tool: 'get_budgets', success: true,
      messageAr: 'لديك ${budgets.length} ميزانيات لهذا الشهر\n'
          'المخصص ${formatBreakdown(allocated, arabic: true)}',
      messageEn: 'You have ${budgets.length} budgets this month\n'
          'Allocated ${formatBreakdown(allocated, arabic: false)}',
      data: {'budgets': list, 'count': budgets.length},
      verificationStatus: 'verified',
    );
  }

  Future<ToolExecutionResult> _getRecurring() async {
    final recurring = await _service.getRecurring();
    final list = recurring.map((r) => {
      'id': r.id, 'name': r.name, 'amount': r.amount,
      'frequency': r.frequency, 'type': r.type,
      'currency_id': saraCurrencyId(r.currency),
      'currency': saraCurrencyId(r.currency),
    }).toList();
    final amounts = groupAmounts(
      recurring, (r) => r.amount, (r) => r.currency);
    return ToolExecutionResult(
      tool: 'get_recurring', success: true,
      messageAr: 'لديك ${recurring.length} معاملات متكررة\n'
          'المبالغ ${formatBreakdown(amounts, arabic: true)}',
      messageEn: 'You have ${recurring.length} recurring transactions\n'
          'Amounts ${formatBreakdown(amounts, arabic: false)}',
      data: {'recurring': list, 'count': recurring.length},
      verificationStatus: 'verified',
    );
  }

  Future<ToolExecutionResult> _getCategories() async {
    final cats = await _service.getCategories();
    return ToolExecutionResult(
      tool: 'get_categories', success: true,
      messageAr: 'التصنيفات: ${cats.map((c) => c.nameAr).join(', ')}',
      messageEn: 'Categories: ${cats.map((c) => c.name).join(', ')}',
      data: {'categories': cats.map((c) => c.nameAr).toList()},
      verificationStatus: 'verified',
    );
  }

  Future<ToolExecutionResult> _searchEntity(Map<String, dynamic> p) async {
    final query = (p['query'] as String?)?.toLowerCase() ?? '';
    final type = p['entity_type'] as String? ?? '';
    String? found;
    String? foundId;

    switch (type) {
      case 'bank':
        final accounts = await _service.getBankAccounts();
        for (final a in accounts) {
          if (a.bankName.toLowerCase().contains(query)) {
            found = a.bankName;
            foundId = a.id;
            break;
          }
        }
      case 'goal':
        final goals = await _service.getSavingsGoals();
        for (final g in goals) {
          if (g.name.toLowerCase().contains(query)) {
            found = g.name;
            foundId = g.id;
            break;
          }
        }
      case 'debt':
        final debts = await _service.getDebts();
        for (final d in debts) {
          if (d.personName.toLowerCase().contains(query)) {
            found = d.personName;
            foundId = d.id;
            break;
          }
        }
    }

    if (found != null) {
      return ToolExecutionResult(
        tool: 'search_entity', success: true,
        messageAr: 'تم العثور على: $found (ID: $foundId)',
        messageEn: 'Found: $found (ID: $foundId)',
        entityId: foundId, entityType: type,
        data: {'name': found, 'id': foundId},
        verificationStatus: 'verified',
      );
    }

    return ToolExecutionResult(
      tool: 'search_entity', success: true,
      messageAr: 'لم يتم العثور على نتائج لـ "$query" في $type',
      messageEn: 'No results found for "$query" in $type',
      data: {'results': 0},
      verificationStatus: 'verified',
    );
  }

  Future<ToolExecutionResult> _getEntityDetail(Map<String, dynamic> p) async {
    final type = p['entity_type'] as String? ?? '';
    final id = _toId(p['entity_id']) ?? '';

    switch (type) {
      case 'bank':
        final account = await _service.getBankAccount(id);
        if (account != null) {
          return ToolExecutionResult(
            tool: 'get_entity_detail', success: true,
            messageAr: '${account.bankName}: ${account.balance} ${account.currency}',
            messageEn: '${account.bankName}: ${account.balance} ${account.currency}',
            entityId: id, entityType: type, data: account.toJson(),
            verificationStatus: 'verified',
          );
        }
      case 'goal':
        final goals = await _service.getSavingsGoals();
        final goal = goals.where((g) => g.id == id).firstOrNull;
        if (goal != null) {
          return ToolExecutionResult(
            tool: 'get_entity_detail', success: true,
            messageAr: '${goal.name}: ${goal.currentAmount}/${goal.targetAmount}',
            messageEn: '${goal.name}: ${goal.currentAmount}/${goal.targetAmount}',
            entityId: id, entityType: type, data: goal.toJson(),
            verificationStatus: 'verified',
          );
        }
      case 'debt':
        final debt = await _service.getDebt(id);
        if (debt != null) {
          return ToolExecutionResult(
            tool: 'get_entity_detail', success: true,
            messageAr: '${debt.personName}: ${debt.amount} (${debt.paid} مدفوع)',
            messageEn: '${debt.personName}: ${debt.amount} (${debt.paid} paid)',
            entityId: id, entityType: type, data: debt.toJson(),
            verificationStatus: 'verified',
          );
        }
    }

    return ToolExecutionResult(
      tool: 'get_entity_detail', success: false,
      messageAr: 'لم يتم العثور على العنصر',
      messageEn: 'Entity not found',
      errorCode: 'NOT_FOUND',
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  WRITE TOOLS — TRANSACTIONS
  // ═══════════════════════════════════════════════════════════════

  Future<ToolExecutionResult> _createTransaction(Map<String, dynamic> p) async {
    final type = p['type'] as String? ?? 'expense';
    final amount = _toDouble(p['amount']) ?? 0;
    final category = p['category'] as String? ?? '';
    final date = p['date'] != null ? DateTime.tryParse(p['date'] as String) ?? DateTime.now() : DateTime.now();
    final description = p['description'] as String?;
    final accountId = _toId(p['account_id']);
    final currencyExplicit = (p['currency'] as String?)?.trim().isNotEmpty == true;
    final currency = saraCurrencyId(p['currency'] as String? ?? 'SAR');
    // Ownership check: if account_id is provided, ensure it belongs to current user.
    // The target account is pinned here and never replaced by another account.
    PersonalBankAccount? target;
    var mismatchBanks = const <PersonalBankAccount>[];
    if (accountId != null && accountId.isNotEmpty) {
      try {
        final banks = await _service.getBankAccounts();
        mismatchBanks = banks;
        target = banks.where((b) => b.id == accountId).firstOrNull;
        if (target == null) {
          return const ToolExecutionResult(tool: 'create_transaction', success: false, messageAr: 'الحساب غير موجود', messageEn: 'Account not found', errorCode: 'NOT_FOUND', retryable: false, verified: false);
        }
      } catch (_) {}
    }
    // Generic account/currency binding with stored-rate auto-conversion:
    // requested == account's own → unchanged. Requested differs and the
    // BANK (all rows sharing the bank name) holds a single currency →
    // auto-convert the amount at the stored exchange rate (real engine
    // only; never invented) and write the converted values. Bank holds
    // several currencies, or no stored rate → refuse with the real,
    // numbered options (CURRENCY_MISMATCH) so the user picks. Applies
    // only when BOTH account and currency are explicit, so legacy callers
    // without a currency keep their previous behavior.
    var effCurrency = currency;
    var effAmount = amount;
    Map<String, dynamic>? conversion;
    if (target != null && currencyExplicit && currency != target.currency) {
      final pinned = target;
      final groupRows = mismatchBanks
          .where((b) => b.bankName.trim() == pinned.bankName.trim())
          .toList();
      final distinct = groupRows
          .map((b) => b.currency.trim().toUpperCase())
          .where((c) => c.isNotEmpty)
          .toSet();
      final rate = distinct.length == 1
          ? _fxEngine?.getRate(currency, distinct.single)
          : null;
      if (distinct.length == 1 && rate != null && rate > 0 && rate.isFinite) {
        effCurrency = distinct.single;
        effAmount = amount * rate;
        conversion = {
          'from_currency': currency,
          'from_amount': amount,
          'to_currency': effCurrency,
          'to_amount': effAmount,
          'rate': rate,
        };
      } else {
        return _currencyMismatch(
          tool: 'create_transaction',
          banks: mismatchBanks,
          target: target,
          requestedCurrency: currency,
          amount: amount,
          type: type,
        );
      }
    }

    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor('create_transaction', {
        'type': type, 'amount': amount, 'category': category,
        'date': date.toIso8601String(), 'description': description,
        'account_id': accountId, 'currency': currency,
      }),
      run: () async {
        bool ok;
        try {
          ok = await _service.addTransaction(
            type: type, amount: effAmount, category: category,
            date: date, description: description, accountId: accountId, currency: effCurrency,
          );
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'create_transaction',
            queueEntityType: 'personal_transaction',
            messageAr: 'فشل في إضافة المعاملة',
            messageEn: 'Failed to add transaction',
            errorCode: 'SAVE_FAILED',
          );
        }
        if (!ok) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'create_transaction',
            queueEntityType: 'personal_transaction',
            messageAr: 'فشل في إضافة المعاملة',
            messageEn: 'Failed to add transaction',
            errorCode: 'SAVE_FAILED',
          );
        }
        return _verify.verifyCreate(
          tool: 'create_transaction',
          queueEntityType: 'personal_transaction',
          resolveId: () => _resolveCreatedId(
            () => _service.getTransactions(),
            (m) =>
                (m['tx_type']?.toString() ?? '') == type &&
                ((m['amount'] as num?)?.toDouble() ?? -1) == effAmount &&
                (m['category']?.toString() ?? '') == category &&
                _sameDay(m['date']?.toString(), date),
          ),
          successAr: conversion == null
              ? 'تم إضافة ${type == "income" ? "دخل" : "مصروف"} بمبلغ $amount ($category)'
              : 'تمت إضافة ${_fmtNum(effAmount)} $effCurrency إلى "${target?.bankName ?? ''}" (تعادل ${_fmtNum(amount)} $currency بسعر الصرف ${_fmtNum((conversion['rate'] as num).toDouble())})',
          successEn: conversion == null
              ? 'Added ${type == "income" ? "income" : "expense"} of $amount ($category)'
              : 'Added ${_fmtNum(effAmount)} $effCurrency to "${target?.bankName ?? ''}" (equals ${_fmtNum(amount)} $currency at rate ${_fmtNum((conversion['rate'] as num).toDouble())})',
          failureAr: 'فشل في إضافة المعاملة',
          failureEn: 'Failed to add transaction',
        );
      },
    );
    // The conversion rides nested under 'conversion' (same envelope shape as
    // the backend dual path) so callers read result.data['conversion'].
    return _adapt(v,
        tool: 'create_transaction',
        entityType: 'transaction',
        data: conversion == null ? null : {'conversion': conversion});
  }

  /// Compact number formatting for conversion messages: whole values print
  /// without decimals, others trimmed to 4 significant decimals.
  static String _fmtNum(double v) {
    if (!v.isFinite) return v.toString();
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
    var s = v.toStringAsFixed(4);
    while (s.contains('.') && (s.endsWith('0'))) {
      s = s.substring(0, s.length - 1);
    }
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    return s;
  }

  /// Generic pre-write account/currency binding. Refuses the write when the
  /// explicitly requested currency differs from the target account's own
  /// currency and returns the real, numbered options instead: FX conversions
  /// (real engine rates only) into the target account's own currencies, plus
  /// sibling accounts that natively support the requested currency.
  /// Never writes, never converts, never auto-picks. Fully generic: derived
  /// only from the user's account rows (grouped by bank name) and the engine.
  ToolExecutionResult _currencyMismatch({
    required String tool,
    required List<PersonalBankAccount> banks,
    required PersonalBankAccount target,
    required String requestedCurrency,
    required double amount,
    required String type,
  }) {
    final requested = requestedCurrency.trim().toUpperCase();
    // Distinct currencies of the target account group (same bank name).
    final groupRows = banks
        .where((b) => b.bankName.trim() == target.bankName.trim())
        .toList();
    final groupCurrencies = <String>[];
    final rowByCurrency = <String, PersonalBankAccount>{};
    for (final b in groupRows) {
      final c = b.currency.trim().toUpperCase();
      if (c.isEmpty || c == requested) continue;
      if (!rowByCurrency.containsKey(c)) {
        rowByCurrency[c] = b;
        groupCurrencies.add(c);
      }
    }
    // FX options: real engine rates only; unavailable pairs are omitted
    // (never rate=1 between different currencies, never invented).
    final fxOptions = <Map<String, dynamic>>[];
    for (final c in groupCurrencies) {
      final rate = _fxEngine?.getRate(requested, c);
      if (rate == null || rate <= 0 || !rate.isFinite) continue;
      fxOptions.add({
        'currency': c,
        'account_id': rowByCurrency[c]!.id,
        'account_name': rowByCurrency[c]!.bankName,
        'rate': rate,
        'converted': amount * rate,
      });
    }
    // Sibling accounts (any bank) natively supporting the requested currency.
    final siblings = <Map<String, dynamic>>[];
    for (final b in banks) {
      if (b.id == target.id) continue;
      if (b.currency.trim().toUpperCase() != requested) continue;
      siblings.add({
        'account_id': b.id,
        'account_name': b.bankName,
        'currency': b.currency.trim().toUpperCase(),
      });
    }
    return ToolExecutionResult(
      tool: tool,
      success: false,
      messageAr:
          'حساب "${target.bankName}" لا يدعم العملة $requested.',
      messageEn:
          'Account "${target.bankName}" does not support $requested.',
      errorCode: 'CURRENCY_MISMATCH',
      retryable: false,
      verified: false,
      data: {
        'account_id': target.id,
        'account_name': target.bankName,
        'account_currency': target.currency.trim().toUpperCase(),
        'requested_currency': requested,
        'amount': amount,
        'type': type,
        'account_currencies':
            groupRows.map((b) => b.currency.trim().toUpperCase()).toSet().toList(),
        'sibling_accounts': siblings,
        'fx_options': fxOptions,
      },
    );
  }

  /// Calendar-day equality tolerant to ISO/Z suffix differences.
  static bool _sameDay(String? a, DateTime b) {
    if (a == null || a.isEmpty) return false;
    final d = DateTime.tryParse(a);
    if (d == null) return false;
    return d.year == b.year && d.month == b.month && d.day == b.day;
  }

  Future<ToolExecutionResult> _createTransfer(Map<String, dynamic> p) async {
    final fromId = _toId(p['from_account_id']) ?? '';
    final toId = _toId(p['to_account_id']) ?? '';
    final amount = _toDouble(p['amount']) ?? 0;

    final accounts = await _service.getBankAccounts();
    final from = accounts.where((a) => a.id == fromId).firstOrNull;
    final to = accounts.where((a) => a.id == toId).firstOrNull;

    if (from == null || to == null) {
      return ToolExecutionResult(
        tool: 'create_transfer', success: false,
        messageAr: 'لم يتم العثور على أحد الحسابين',
        messageEn: 'One or both accounts not found',
        errorCode: 'ACCOUNT_NOT_FOUND',
      );
    }
    if ((p['from_currency'] != null && p['from_currency'] != from.currency) ||
        (p['to_currency'] != null && p['to_currency'] != to.currency)) {
      return ToolExecutionResult(tool: 'create_transfer', success: false,
        messageAr: 'تغيرت عملة أحد الحسابين. جهز التحويل مرة أخرى بسعر الصرف الصحيح.',
        messageEn: 'An account currency changed. Prepare the transfer again with a new quote.',
        errorCode: 'QUOTE_CURRENCY_CHANGED', verified: false);
    }

    // Real FX rate or stop: a silent 1.0 across currencies invents money.
    double rate;
    if (from.currency == to.currency) {
      rate = 1.0;
    } else {
      final r = _toDouble(p['exchange_rate']) ?? _fxEngine?.getRate(from.currency, to.currency);
      if (r == null || r <= 0) {
        return ToolExecutionResult(
          tool: 'create_transfer', success: false,
          messageAr: 'لا يوجد سعر صرف حقيقي من ${from.currency} إلى ${to.currency} — تم إيقاف التحويل. حدّث أسعار الصرف أولاً.',
          messageEn: 'No real exchange rate from ${from.currency} to ${to.currency} — transfer stopped. Update exchange rates first.',
          errorCode: 'NO_FX_RATE',
        );
      }
      rate = r;
    }
    final converted = from.currency == to.currency ? amount : amount * rate;
    final fromBefore = from.balance;
    final toBefore = to.balance;
    // Both sides stay currency-tagged: never present source and destination
    // as one number. Same-currency keeps the short form.
    final sameCur = from.currency == to.currency;
    final okAr = sameCur
        ? 'تم تحويل $amount ${from.currency} من ${from.bankName} إلى ${to.bankName}'
        : 'تم تحويل $amount ${from.currency} من ${from.bankName} إلى ${fmtNum(converted)} ${to.currency} في ${to.bankName} (السعر $rate)';
    final okEn = sameCur
        ? 'Transferred $amount ${from.currency} from ${from.bankName} to ${to.bankName}'
        : 'Transferred $amount ${from.currency} from ${from.bankName} to ${fmtNum(converted)} ${to.currency} in ${to.bankName} (rate $rate)';
    const failAr = 'فشل في التحويل';
    const failEn = 'Transfer failed';

    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor('create_transfer', {
        'from_account_id': fromId, 'to_account_id': toId, 'amount': amount,
      }),
      run: () async {
        bool ok;
        try {
          ok = await _service.transferBetweenAccounts(
            fromId: fromId, toId: toId, amount: amount,
            fromCurrency: from.currency, toCurrency: to.currency, rate: rate,
          );
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'create_transfer',
            queueEntityType: 'personal_transaction',
            messageAr: failAr, messageEn: failEn,
            errorCode: 'TRANSFER_FAILED',
          );
        }
        if (!ok) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'create_transfer',
            queueEntityType: 'personal_transaction',
            messageAr: failAr, messageEn: failEn,
            errorCode: 'TRANSFER_FAILED',
          );
        }
        // Verify BOTH legs by ID with exact balance deltas.
        final vFrom = await _verify.verifyUpdate(
          tool: 'create_transfer',
          queueEntityType: 'personal_bank_account',
          entityId: fromId,
          expectFields: {'balance': fromBefore - amount},
          successAr: okAr, successEn: okEn,
          failureAr: failAr, failureEn: failEn,
        );
        final vTo = await _verify.verifyUpdate(
          tool: 'create_transfer',
          queueEntityType: 'personal_bank_account',
          entityId: toId,
          expectFields: {'balance': toBefore + converted},
          successAr: okAr, successEn: okEn,
          failureAr: failAr, failureEn: failEn,
        );
        return _combineTransfer(vFrom, vTo);
      },
    );
    return _adapt(v, tool: 'create_transfer', entityType: 'transaction', data: {
      'source_currency_id': saraCurrencyId(from.currency),
      'source_amount': amount,
      'destination_currency_id': saraCurrencyId(to.currency),
      'destination_amount': converted,
      'exchange_rate': rate,
    });
  }

  /// Combines the two transfer-leg verdicts: worst state wins, so a
  /// half-applied transfer can never render as success.
  SaraVerificationResult _combineTransfer(
      SaraVerificationResult a, SaraVerificationResult b) {
    int rank(SaraVerificationState s) {
      if (s == SaraVerificationState.failed ||
          s == SaraVerificationState.notFound) {
        return 5;
      }
      if (s == SaraVerificationState.syncFailed) return 4;
      if (s == SaraVerificationState.verificationFailed) return 3;
      if (s == SaraVerificationState.successLocalPendingSync) return 2;
      return 1;
    }

    final worst = rank(a.state) >= rank(b.state) ? a : b;
    return SaraVerificationResult(
      state: worst.state,
      tool: 'create_transfer',
      entityId: worst.entityId,
      queueEntityType: worst.queueEntityType,
      serverConfirmed: worst.serverConfirmed,
      syncState: worst.syncState,
      messageAr: worst.messageAr,
      messageEn: worst.messageEn,
      errorCode: worst.errorCode,
      data: worst.data,
      row: worst.row,
    );
  }

  Future<ToolExecutionResult> _deleteTransaction(Map<String, dynamic> p) async {
    final id = _toId(p['transaction_id']) ?? '';
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor(
          'delete_transaction', {'transaction_id': id}),
      run: () async {
        try {
          await _service.deleteTransaction(id);
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'delete_transaction',
            queueEntityType: 'personal_transaction',
            messageAr: 'فشل حذف المعاملة',
            messageEn: 'Failed to delete transaction',
            errorCode: 'SAVE_FAILED',
          );
        }
        return _verify.verifyDelete(
          tool: 'delete_transaction',
          queueEntityType: 'personal_transaction',
          entityId: id,
          successAr: 'تم حذف المعاملة',
          successEn: 'Transaction deleted',
          failureAr: 'فشل حذف المعاملة',
          failureEn: 'Failed to delete transaction',
        );
      },
    );
    return _adapt(v, tool: 'delete_transaction', entityType: 'transaction');
  }

  // ═══════════════════════════════════════════════════════════════
  //  WRITE TOOLS — BANK ACCOUNTS
  // ═══════════════════════════════════════════════════════════════

  Future<ToolExecutionResult> _createBankAccount(Map<String, dynamic> p) async {
    final bankName = p['bank_name'] as String? ?? '';
    final currency = p['currency'] as String? ?? 'SAR';
    final openingBalance = _toDouble(p['opening_balance']) ?? 0;

    if (bankName.isEmpty) {
      return ToolExecutionResult(
        tool: 'create_bank_account', success: false,
        messageAr: 'اسم البنك مطلوب',
        messageEn: 'Bank name is required',
        errorCode: 'MISSING_BANK_NAME',
      );
    }

    // Duplicate check: same bank name + same currency
    final existing = await _service.getBankAccounts();
    final duplicate = existing.where((a) =>
      a.bankName.toLowerCase() == bankName.toLowerCase() &&
      a.currency.toUpperCase() == currency.toUpperCase()
    ).firstOrNull;
    if (duplicate != null) {
      return ToolExecutionResult(
        tool: 'create_bank_account', success: false,
        messageAr: 'الحساب "$bankName" بالعملة $currency موجود مسبقاً (ID: ${duplicate.id})',
        messageEn: 'Account "$bankName" in $currency already exists (ID: ${duplicate.id})',
        entityId: duplicate.id, entityType: 'bank',
        errorCode: 'DUPLICATE_ACCOUNT',
      );
    }

    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor('create_bank_account', {
        'bank_name': bankName, 'currency': currency,
        'opening_balance': openingBalance,
      }),
      run: () async {
        try {
          await _service.addBankAccount(
            bankName: bankName, currency: currency, openingBalance: openingBalance,
          );
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'create_bank_account',
            queueEntityType: 'personal_bank_account',
            messageAr: 'فشل في إنشاء الحساب',
            messageEn: 'Failed to create account',
            errorCode: 'SAVE_FAILED',
          );
        }
        return _verify.verifyCreate(
          tool: 'create_bank_account',
          queueEntityType: 'personal_bank_account',
          resolveId: () => _resolveCreatedId(
            () => _service.getBankAccounts(),
            (m) =>
                (m['bank_name']?.toString() ?? '').toLowerCase() ==
                    bankName.toLowerCase() &&
                (m['currency']?.toString() ?? '').toUpperCase() ==
                    currency.toUpperCase() &&
                ((m['balance'] as num?)?.toDouble() ?? -1) == openingBalance,
          ),
          successAr: 'تم إنشاء حساب "$bankName" بالعملة $currency',
          successEn: 'Created account "$bankName" in $currency',
          failureAr: 'فشل في إنشاء الحساب — لم يتم العثور عليه بعد الإنشاء',
          failureEn: 'Failed to create account — not found after creation',
          route: '/personal/banks',
        );
      },
    );
    return _adapt(v,
        tool: 'create_bank_account', entityType: 'bank', route: '/personal/banks');
  }

  Future<ToolExecutionResult> _updateBankAccount(Map<String, dynamic> p) async {
    final id = _toId(p['account_id']) ?? '';
    if (id.isEmpty) {
      return ToolExecutionResult(
        tool: 'update_bank_account', success: false,
        messageAr: 'معرف الحساب غير صالح',
        messageEn: 'Invalid account ID',
        errorCode: 'INVALID_ID',
      );
    }
    final expect = <String, dynamic>{
      if (p['bank_name'] != null) 'bank_name': p['bank_name'],
      if (p['balance'] != null) 'balance': _toDouble(p['balance']),
      if (p['notes'] != null) 'notes': p['notes'],
    };
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor('update_bank_account', {
        'account_id': id, 'bank_name': p['bank_name'],
        'balance': p['balance'], 'notes': p['notes'],
      }),
      run: () async {
        try {
          await _service.updateBankAccount(
            id,
            bankName: p['bank_name'] as String?,
            balance: _toDouble(p['balance']),
            notes: p['notes'] as String?,
          );
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'update_bank_account',
            queueEntityType: 'personal_bank_account',
            messageAr: 'فشل التحديث',
            messageEn: 'Update failed',
            errorCode: 'SAVE_FAILED',
          );
        }
        return _verify.verifyUpdate(
          tool: 'update_bank_account',
          queueEntityType: 'personal_bank_account',
          entityId: id,
          expectFields: expect.isEmpty ? null : expect,
          successAr: 'تم تحديث الحساب',
          successEn: 'Account updated',
          failureAr: 'فشل التحديث',
          failureEn: 'Update failed',
        );
      },
    );
    return _adapt(v, tool: 'update_bank_account', entityType: 'bank');
  }

  Future<ToolExecutionResult> _deleteBankAccount(Map<String, dynamic> p) async {
    final id = _toId(p['account_id']) ?? '';
    if (id.isEmpty) {
      return const ToolExecutionResult(tool: 'delete_bank_account', success: false, messageAr: 'معرف الحساب غير صالح', messageEn: 'Invalid account ID', errorCode: 'INVALID_ID', retryable: false, verified: false);
    }
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor(
          'delete_bank_account', {'account_id': id}),
      run: () async {
        // Ownership check: ensure the account belongs to current user
        try {
          final banks = await _service.getBankAccounts();
          if (!banks.any((b) => b.id == id)) {
            return const SaraVerificationResult(state: SaraVerificationState.notFound, tool: 'delete_bank_account', queueEntityType: 'personal_bank_account', messageAr: 'الحساب غير موجود', messageEn: 'Account not found', errorCode: 'NOT_FOUND');
          }
        } catch (_) {}
        try {
          await _service.deleteBankAccount(id);
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'delete_bank_account',
            queueEntityType: 'personal_bank_account',
            messageAr: 'فشل حذف الحساب البنكي',
            messageEn: 'Failed to delete bank account',
            errorCode: 'SAVE_FAILED',
          );
        }
        return _verify.verifyDelete(
          tool: 'delete_bank_account',
          queueEntityType: 'personal_bank_account',
          entityId: id,
          successAr: 'تم حذف الحساب البنكي',
          successEn: 'Bank account deleted',
          failureAr: 'فشل حذف الحساب البنكي',
          failureEn: 'Failed to delete bank account',
        );
      },
    );
    return _adapt(v, tool: 'delete_bank_account', entityType: 'bank');
  }

  // ═══════════════════════════════════════════════════════════════
  //  WRITE TOOLS — SAVINGS GOALS
  // ═══════════════════════════════════════════════════════════════

  Future<ToolExecutionResult> _createSavingsGoal(Map<String, dynamic> p) async {
    final name = p['name'] as String? ?? '';
    final target = _toDouble(p['target_amount']) ?? 0;

    if (name.isEmpty) {
      return ToolExecutionResult(
        tool: 'create_savings_goal', success: false,
        messageAr: 'اسم الهدف مطلوب',
        messageEn: 'Goal name is required',
        errorCode: 'MISSING_NAME',
      );
    }
    if (target <= 0) {
      return ToolExecutionResult(
        tool: 'create_savings_goal', success: false,
        messageAr: 'المبلغ المستهدف يجب أن يكون أكبر من صفر',
        messageEn: 'Target amount must be greater than zero',
        errorCode: 'INVALID_TARGET',
      );
    }

    // Duplicate check: same goal name
    final existing = await _service.getSavingsGoals();
    final duplicate = existing.where((g) =>
      g.name.toLowerCase() == name.toLowerCase()
    ).firstOrNull;
    if (duplicate != null) {
      return ToolExecutionResult(
        tool: 'create_savings_goal', success: false,
        messageAr: 'هدف "$name" موجود مسبقاً (ID: ${duplicate.id})',
        messageEn: 'Goal "$name" already exists (ID: ${duplicate.id})',
        entityId: duplicate.id, entityType: 'goal',
        errorCode: 'DUPLICATE_GOAL',
      );
    }

    final goal = SavingsGoal(
      id: '', name: name, targetAmount: target,
      currentAmount: _toDouble(p['current_amount']) ?? 0,
      deadline: p['deadline'] as String?,
    );
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor('create_savings_goal', {
        'name': name, 'target_amount': target,
      }),
      run: () async {
        try {
          await _service.addSavingsGoal(goal);
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'create_savings_goal',
            queueEntityType: 'personal_savings_goal',
            messageAr: 'فشل في إنشاء الهدف',
            messageEn: 'Failed to create goal',
            errorCode: 'SAVE_FAILED',
          );
        }
        return _verify.verifyCreate(
          tool: 'create_savings_goal',
          queueEntityType: 'personal_savings_goal',
          resolveId: () => _resolveCreatedId(
            () => _service.getSavingsGoals(),
            (m) =>
                (m['name']?.toString() ?? '') == name &&
                ((m['target_amount'] as num?)?.toDouble() ?? -1) == target,
          ),
          successAr: 'تم إنشاء هدف "$name" بمبلغ $target',
          successEn: 'Created goal "$name" with target $target',
          failureAr: 'فشل في إنشاء الهدف',
          failureEn: 'Failed to create goal',
          route: '/personal/savings',
        );
      },
    );
    return _adapt(v,
        tool: 'create_savings_goal', entityType: 'goal', route: '/personal/savings');
  }

  Future<ToolExecutionResult> _updateSavingsGoal(Map<String, dynamic> p) async {
    final goals = await _service.getSavingsGoals();
    final rawId = p['goal_id'] ?? p['goal_name'] ?? p['name'];
    String? id;

    if (rawId != null) {
      final asId = _toId(rawId);
      if (asId != null && goals.any((g) => g.id == asId)) {
        id = asId;
      } else {
        final match = goals.where((g) =>
          g.name.toLowerCase().toString().contains(rawId.toString().toLowerCase()) ||
          rawId.toString().toLowerCase().contains(g.name.toLowerCase())
        ).firstOrNull;
        if (match != null) id = match.id;
      }
    }

    if (id == null || id.isEmpty) {
      final names = goals.map((g) => '"${g.name}"').join(', ');
      return ToolExecutionResult(
        tool: 'update_savings_goal', success: false,
        messageAr: goals.isEmpty ? 'لا توجد أهداف ادخار.' : 'لم أجد هدفاً مطابقاً. الأهداف: $names',
        messageEn: goals.isEmpty ? 'No goals found.' : 'No matching goal. Available: $names',
        errorCode: 'NOT_FOUND',
      );
    }

    final existing = goals.where((g) => g.id == id).firstOrNull;
    if (existing == null) {
      return ToolExecutionResult(
        tool: 'update_savings_goal', success: false,
        messageAr: 'لم يتم العثور على الهدف',
        messageEn: 'Goal not found',
        errorCode: 'NOT_FOUND',
      );
    }

    final updated = SavingsGoal(
      id: id,
      name: (p['name'] as String?) ?? existing.name,
      targetAmount: _toDouble(p['target_amount']) ?? existing.targetAmount,
      currentAmount: existing.currentAmount,
      deadline: (p['deadline'] as String?) ?? existing.deadline,
      currency: existing.currency,
      icon: existing.icon,
    );
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor('update_savings_goal', {
        'goal_id': id, 'name': updated.name,
        'target_amount': updated.targetAmount,
      }),
      run: () async {
        try {
          await _service.updateSavingsGoal(updated);
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'update_savings_goal',
            queueEntityType: 'personal_savings_goal',
            messageAr: 'فشل تحديث الهدف',
            messageEn: 'Failed to update goal',
            errorCode: 'SAVE_FAILED',
          );
        }
        return _verify.verifyUpdate(
          tool: 'update_savings_goal',
          queueEntityType: 'personal_savings_goal',
          entityId: id,
          expectFields: {
            'name': updated.name,
            'target_amount': updated.targetAmount,
          },
          successAr: 'تم تحديث الهدف "${updated.name}"',
          successEn: 'Updated goal "${updated.name}"',
          failureAr: 'فشل تحديث الهدف',
          failureEn: 'Failed to update goal',
        );
      },
    );
    return _adapt(v, tool: 'update_savings_goal', entityType: 'goal');
  }

  Future<ToolExecutionResult> _contributeToGoal(Map<String, dynamic> p) async {
    final amount = _toDouble(p['amount']) ?? 0;

    if (amount <= 0) {
      return ToolExecutionResult(
        tool: 'contribute_to_goal', success: false,
        messageAr: 'المبلغ يجب أن يكون أكبر من صفر',
        messageEn: 'Amount must be greater than zero',
        errorCode: 'INVALID_AMOUNT',
      );
    }

    // Resolve goal: try UUID first, then search by name
    final goals = await _service.getSavingsGoals();
    final rawId = p['goal_id'] ?? p['goal_name'] ?? p['name'];
    String? goalId;

    if (rawId != null) {
      final asId = _toId(rawId);
      if (asId != null && goals.any((g) => g.id == asId)) {
        goalId = asId;
      } else {
        // Not a UUID — search by name
        final match = goals.where((g) =>
          g.name.toLowerCase().toString().contains(rawId.toString().toLowerCase()) ||
          rawId.toString().toLowerCase().contains(g.name.toLowerCase())
        ).firstOrNull;
        if (match != null) goalId = match.id;
      }
    }

    if (goalId == null || goalId.isEmpty) {
      final names = goals.map((g) => '"${g.name}"').join(', ');
      return ToolExecutionResult(
        tool: 'contribute_to_goal', success: false,
        messageAr: goals.isEmpty
          ? 'لا توجد أهداف ادخار. أنشئ هدفاً أولاً.'
          : 'لم أجد هدفاً مطابقاً. الأهداف المتاحة: $names',
        messageEn: goals.isEmpty
          ? 'No savings goals found. Create one first.'
          : 'No matching goal found. Available goals: $names',
        errorCode: 'NOT_FOUND',
      );
    }

    final beforeAmount = goals
        .where((g) => g.id == goalId)
        .firstOrNull
        ?.currentAmount;
    if (beforeAmount == null) {
      return ToolExecutionResult(
        tool: 'contribute_to_goal', success: false,
        messageAr: 'لم يتم العثور على الهدف',
        messageEn: 'Goal not found',
        errorCode: 'NOT_FOUND',
      );
    }

    final gid = goalId;
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor(
          'contribute_to_goal', {'goal_id': gid, 'amount': amount}),
      run: () async {
        try {
          await _service.contributeToGoal(gid, amount);
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'contribute_to_goal',
            queueEntityType: 'personal_savings_goal',
            messageAr: 'فشل إضافة المساهمة',
            messageEn: 'Failed to add contribution',
            errorCode: 'SAVE_FAILED',
          );
        }
        // Amount truth: currentAmount must grow by exactly the contribution.
        return _verify.verifyUpdate(
          tool: 'contribute_to_goal',
          queueEntityType: 'personal_savings_goal',
          entityId: gid,
          expectFields: {'current_amount': beforeAmount + amount},
          successAr: 'تمت إضافة $amount',
          successEn: 'Added $amount',
          failureAr: 'فشل إضافة المساهمة — لم يتغير مبلغ الهدف بالقيمة المتوقعة',
          failureEn: 'Contribution failed — goal amount did not change as expected',
        );
      },
    );
    final out = _adapt(v, tool: 'contribute_to_goal', entityType: 'goal');
    if (v.row != null) {
      final cur = (v.row!['current_amount'] as num?)?.toDouble();
      final tgt = (v.row!['target_amount'] as num?)?.toDouble();
      final name = v.row!['name']?.toString() ?? '';
      return ToolExecutionResult(
        tool: out.tool, success: out.success,
        messageAr: '${out.messageAr} "${name.isEmpty ? '' : name}". المبلغ الحالي: ${cur ?? '?'}',
        messageEn: '${out.messageEn} "${name.isEmpty ? '' : name}". Current: ${cur ?? '?'} of ${tgt ?? '?'}',
        entityId: out.entityId, entityType: out.entityType,
        route: '/personal/savings', verificationStatus: out.verificationStatus,
        data: {...?out.data, 'current': cur, 'target': tgt},
        errorCode: out.errorCode,
      );
    }
    return _adapt(v,
        tool: 'contribute_to_goal', entityType: 'goal', route: '/personal/savings');
  }

  Future<ToolExecutionResult> _deleteSavingsGoal(Map<String, dynamic> p) async {
    final goals = await _service.getSavingsGoals();
    final rawId = p['goal_id'] ?? p['goal_name'] ?? p['name'];
    String? id;

    if (rawId != null) {
      final asId = _toId(rawId);
      if (asId != null && goals.any((g) => g.id == asId)) {
        id = asId;
      } else {
        final match = goals.where((g) =>
          g.name.toLowerCase().toString().contains(rawId.toString().toLowerCase()) ||
          rawId.toString().toLowerCase().contains(g.name.toLowerCase())
        ).firstOrNull;
        if (match != null) id = match.id;
      }
    }

    if (id == null || id.isEmpty) {
      final names = goals.map((g) => '"${g.name}"').join(', ');
      return ToolExecutionResult(
        tool: 'delete_savings_goal', success: false,
        messageAr: goals.isEmpty ? 'لا توجد أهداف ادخار.' : 'لم أجد هدفاً مطابقاً. الأهداف: $names',
        messageEn: goals.isEmpty ? 'No goals found.' : 'No matching goal. Available: $names',
        errorCode: 'NOT_FOUND',
      );
    }

    final goalId = id;
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor(
          'delete_savings_goal', {'goal_id': goalId}),
      run: () async {
        try {
          await _service.deleteSavingsGoal(goalId);
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'delete_savings_goal',
            queueEntityType: 'personal_savings_goal',
            messageAr: 'فشل حذف هدف الادخار',
            messageEn: 'Failed to delete savings goal',
            errorCode: 'SAVE_FAILED',
          );
        }
        return _verify.verifyDelete(
          tool: 'delete_savings_goal',
          queueEntityType: 'personal_savings_goal',
          entityId: goalId,
          successAr: 'تم حذف هدف الادخار',
          successEn: 'Savings goal deleted',
          failureAr: 'فشل حذف هدف الادخار',
          failureEn: 'Failed to delete savings goal',
        );
      },
    );
    return _adapt(v, tool: 'delete_savings_goal', entityType: 'goal');
  }

  // ═══════════════════════════════════════════════════════════════
  //  WRITE TOOLS — DEBTS
  // ═══════════════════════════════════════════════════════════════

  Future<ToolExecutionResult> _createDebt(Map<String, dynamic> p) async {
    final personName = p['person_name'] as String? ?? '';
    final amount = _toDouble(p['amount']) ?? 0;
    final debtType = p['debt_type'] as String? ?? 'payable';
    // Currency is mandatory for a correct debt record: YER_OLD and YER_NEW
    // are different currencies and must never be mixed.
    var currency = ((p['currency'] as String?) ?? 'SAR').trim().toUpperCase();
    if (currency.isEmpty) currency = 'SAR';

    if (personName.isEmpty) {
      return ToolExecutionResult(
        tool: 'create_debt', success: false,
        messageAr: 'اسم الشخص مطلوب',
        messageEn: 'Person name is required',
        errorCode: 'MISSING_PERSON_NAME',
      );
    }
    if (amount <= 0) {
      return ToolExecutionResult(
        tool: 'create_debt', success: false,
        messageAr: 'المبلغ يجب أن يكون أكبر من صفر',
        messageEn: 'Amount must be greater than zero',
        errorCode: 'INVALID_AMOUNT',
      );
    }

    final debt = PersonalDebt(
      id: '', type: debtType, personName: personName, amount: amount,
      dueDate: p['due_date'] != null ? DateTime.tryParse(p['due_date'] as String) : null,
      description: p['notes'] as String?,
      currency: currency,
    );
    final directionAr = debtType == 'receivable' ? 'دين لك' : 'دين عليك';
    final directionEn = debtType == 'receivable' ? 'receivable (owed to you)' : 'payable (you owe)';
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor('create_debt', {
        'person_name': personName, 'amount': amount, 'debt_type': debtType,
        'currency': currency,
      }),
      run: () async {
        try {
          await _service.addDebt(debt);
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'create_debt',
            queueEntityType: 'personal_debt',
            messageAr: 'فشل في إنشاء الدين',
            messageEn: 'Failed to create debt',
            errorCode: 'SAVE_FAILED',
          );
        }
        return _verify.verifyCreate(
          tool: 'create_debt',
          queueEntityType: 'personal_debt',
          resolveId: () => _resolveCreatedId(
            () => _service.getDebts(),
            (m) =>
                (m['person_name']?.toString() ?? '') == personName &&
                ((m['amount'] as num?)?.toDouble() ?? -1) == amount &&
                ((m['currency']?.toString() ?? 'SAR').toUpperCase() == currency),
          ),
          successAr: 'تم إنشاء $directionAr "$personName" بمبلغ $amount $currency',
          successEn: 'Created $directionEn "$personName" of $amount $currency',
          failureAr: 'فشل في إنشاء الدين',
          failureEn: 'Failed to create debt',
          route: '/personal/debts',
        );
      },
    );
    return _adapt(v,
        tool: 'create_debt', entityType: 'debt', route: '/personal/debts');
  }

  Future<ToolExecutionResult> _updateDebt(Map<String, dynamic> p) async {
    final debts = await _service.getDebts();
    final rawId = p['debt_id'] ?? p['person_name'] ?? p['name'];
    String? id;

    if (rawId != null) {
      final asId = _toId(rawId);
      if (asId != null && debts.any((d) => d.id == asId)) {
        id = asId;
      } else {
        final match = debts.where((d) =>
          d.personName.toLowerCase().toString().contains(rawId.toString().toLowerCase()) ||
          rawId.toString().toLowerCase().contains(d.personName.toLowerCase())
        ).firstOrNull;
        if (match != null) id = match.id;
      }
    }

    if (id == null || id.isEmpty) {
      final names = debts.map((d) => '"${d.personName}"').join(', ');
      return ToolExecutionResult(
        tool: 'update_debt', success: false,
        messageAr: debts.isEmpty ? 'لا توجد ديون.' : 'لم أجد ديناً مطابقاً. الديون: $names',
        messageEn: debts.isEmpty ? 'No debts found.' : 'No matching debt. Available: $names',
        errorCode: 'NOT_FOUND',
      );
    }

    final existing = debts.where((d) => d.id == id).firstOrNull;
    if (existing == null) {
      return ToolExecutionResult(
        tool: 'update_debt', success: false,
        messageAr: 'لم يتم العثور على الدين',
        messageEn: 'Debt not found',
        errorCode: 'NOT_FOUND',
      );
    }

    final updated = existing.copyWith(
      personName: (p['person_name'] as String?) ?? existing.personName,
      amount: _toDouble(p['amount']) ?? existing.amount,
      dueDate: p['due_date'] != null ? DateTime.tryParse(p['due_date'] as String) ?? existing.dueDate : existing.dueDate,
      description: (p['notes'] as String?) ?? existing.description,
    );
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor('update_debt', {
        'debt_id': id, 'person_name': updated.personName,
        'amount': updated.amount,
      }),
      run: () async {
        try {
          await _service.updateDebt(updated);
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'update_debt',
            queueEntityType: 'personal_debt',
            messageAr: 'فشل تحديث الدين',
            messageEn: 'Failed to update debt',
            errorCode: 'SAVE_FAILED',
          );
        }
        return _verify.verifyUpdate(
          tool: 'update_debt',
          queueEntityType: 'personal_debt',
          entityId: id,
          expectFields: {
            'person_name': updated.personName,
            'amount': updated.amount,
          },
          successAr: 'تم تحديث الدين "${updated.personName}"',
          successEn: 'Updated debt "${updated.personName}"',
          failureAr: 'فشل تحديث الدين',
          failureEn: 'Failed to update debt',
        );
      },
    );
    return _adapt(v, tool: 'update_debt', entityType: 'debt');
  }

  Future<ToolExecutionResult> _payDebt(Map<String, dynamic> p) async {
    final amount = _toDouble(p['amount']) ?? 0;

    if (amount <= 0) {
      return ToolExecutionResult(
        tool: 'pay_debt', success: false,
        messageAr: 'المبلغ يجب أن يكون أكبر من صفر',
        messageEn: 'Amount must be greater than zero',
        errorCode: 'INVALID_AMOUNT',
      );
    }

    // Resolve debt: try UUID first, then search by person name
    final debts = await _service.getDebts();
    final rawId = p['debt_id'] ?? p['person_name'] ?? p['name'];
    String? debtId;

    if (rawId != null) {
      final asId = _toId(rawId);
      if (asId != null && debts.any((d) => d.id == asId)) {
        debtId = asId;
      } else {
        final match = debts.where((d) =>
          d.personName.toLowerCase().toString().contains(rawId.toString().toLowerCase()) ||
          rawId.toString().toLowerCase().contains(d.personName.toLowerCase())
        ).firstOrNull;
        if (match != null) debtId = match.id;
      }
    }

    if (debtId == null || debtId.isEmpty) {
      final names = debts.map((d) => '"${d.personName}"').join(', ');
      return ToolExecutionResult(
        tool: 'pay_debt', success: false,
        messageAr: debts.isEmpty
          ? 'لا توجد ديون. أنشئ ديناً أولاً.'
          : 'لم أجد ديناً مطابقاً. الديون المتاحة: $names',
        messageEn: debts.isEmpty
          ? 'No debts found. Create one first.'
          : 'No matching debt found. Available debts: $names',
        errorCode: 'NOT_FOUND',
      );
    }

    final debtBefore = debts.where((d) => d.id == debtId).firstOrNull;
    if (debtBefore == null) {
      return ToolExecutionResult(
        tool: 'pay_debt', success: false,
        messageAr: 'لم يتم العثور على الدين',
        messageEn: 'Debt not found',
        errorCode: 'NOT_FOUND',
      );
    }
    if (amount > debtBefore.remaining) {
      return ToolExecutionResult(
        tool: 'pay_debt', success: false,
        messageAr: 'المبلغ $amount أكبر من المتبقي ${debtBefore.remaining}',
        messageEn: 'Amount $amount exceeds remaining ${debtBefore.remaining}',
        errorCode: 'AMOUNT_EXCEEDS_REMAINING',
      );
    }

    final beforePaid = debtBefore.paid;
    final did = debtId;
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor(
          'pay_debt', {'debt_id': did, 'amount': amount}),
      run: () async {
        try {
          await _service.payDebt(did, amount, DateTime.now(),
              notes: p['notes'] as String?);
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'pay_debt',
            queueEntityType: 'personal_debt',
            messageAr: 'فشل سداد الدين',
            messageEn: 'Failed to pay debt',
            errorCode: 'SAVE_FAILED',
          );
        }
        // Amount truth: paid must grow by exactly the paid amount.
        return _verify.verifyUpdate(
          tool: 'pay_debt',
          queueEntityType: 'personal_debt',
          entityId: did,
          expectFields: {'paid': beforePaid + amount},
          successAr: 'تم سداد $amount من دين "${debtBefore.personName}"',
          successEn: 'Paid $amount from debt "${debtBefore.personName}"',
          failureAr: 'فشل سداد الدين — لم يتغير المبلغ المسدد بالقيمة المتوقعة',
          failureEn: 'Debt payment failed — paid amount did not change as expected',
        );
      },
    );
    final out = _adapt(v, tool: 'pay_debt', entityType: 'debt');
    if (v.row != null) {
      final rem = (v.row!['amount'] as num? ?? 0).toDouble() -
          (v.row!['paid'] as num? ?? 0).toDouble();
      return ToolExecutionResult(
        tool: out.tool, success: out.success,
        messageAr: '${out.messageAr}. المتبقي: $rem',
        messageEn: '${out.messageEn}. Remaining: $rem',
        entityId: out.entityId, entityType: out.entityType,
        route: out.route, verificationStatus: out.verificationStatus,
        data: {...?out.data, 'remaining': rem}, errorCode: out.errorCode,
      );
    }
    return out;
  }

  Future<ToolExecutionResult> _deleteDebt(Map<String, dynamic> p) async {
    final debts = await _service.getDebts();
    final rawId = p['debt_id'] ?? p['person_name'] ?? p['name'];
    String? id;

    if (rawId != null) {
      final asId = _toId(rawId);
      if (asId != null && debts.any((d) => d.id == asId)) {
        id = asId;
      } else {
        final match = debts.where((d) =>
          d.personName.toLowerCase().toString().contains(rawId.toString().toLowerCase()) ||
          rawId.toString().toLowerCase().contains(d.personName.toLowerCase())
        ).firstOrNull;
        if (match != null) id = match.id;
      }
    }

    if (id == null || id.isEmpty) {
      final names = debts.map((d) => '"${d.personName}"').join(', ');
      return ToolExecutionResult(
        tool: 'delete_debt', success: false,
        messageAr: debts.isEmpty ? 'لا توجد ديون.' : 'لم أجد ديناً مطابقاً. الديون: $names',
        messageEn: debts.isEmpty ? 'No debts found.' : 'No matching debt. Available: $names',
        errorCode: 'NOT_FOUND',
      );
    }

    final debtId = id;
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor(
          'delete_debt', {'debt_id': debtId}),
      run: () async {
        try {
          await _service.deleteDebt(debtId);
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'delete_debt',
            queueEntityType: 'personal_debt',
            messageAr: 'فشل حذف الدين',
            messageEn: 'Failed to delete debt',
            errorCode: 'SAVE_FAILED',
          );
        }
        return _verify.verifyDelete(
          tool: 'delete_debt',
          queueEntityType: 'personal_debt',
          entityId: debtId,
          successAr: 'تم حذف الدين',
          successEn: 'Debt deleted',
          failureAr: 'فشل حذف الدين',
          failureEn: 'Failed to delete debt',
        );
      },
    );
    return _adapt(v, tool: 'delete_debt', entityType: 'debt');
  }

  // ═══════════════════════════════════════════════════════════════
  //  WRITE TOOLS — BUDGETS
  // ═══════════════════════════════════════════════════════════════

  /// Parse the optional `categories` param (JSON string list of
  /// `{name, amount}`) into BudgetCategory rows inside the same budget.
  /// Never throws: unparseable input yields no categories (a category-free
  /// budget), and entries with an empty name or non-positive amount are
  /// skipped instead of guessed.
  List<BudgetCategory> _parseBudgetCategories(dynamic raw, String currency) {
    if (raw == null) return const [];
    List<dynamic> items;
    if (raw is List) {
      items = raw;
    } else if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw.trim());
        if (decoded is! List) return const [];
        items = decoded;
      } catch (_) {
        return const [];
      }
    } else {
      return const [];
    }
    final out = <BudgetCategory>[];
    for (final e in items) {
      if (e is! Map) continue;
      final cname = (e['name']?.toString() ?? '').trim();
      final camount = _toDouble(e['amount']) ?? 0;
      if (cname.isEmpty || camount <= 0) continue;
      out.add(BudgetCategory(
        id: '',
        name: cname,
        type: 'expense',
        allocatedAmount: camount,
        currency: currency,
      ));
    }
    return out;
  }

  Future<ToolExecutionResult> _createBudget(Map<String, dynamic> p) async {
    final name = ((p['name'] as String?) ?? (p['category'] as String?) ?? '').trim();
    final amount = _toDouble(p['amount']) ?? 0;
    var currency = ((p['currency'] as String?) ?? 'SAR').trim().toUpperCase();
    if (currency.isEmpty) currency = 'SAR';

    // Pre-validate locally so the user gets a clear question instead of a
    // raw 422 from the server. The slot-filling flow re-asks for anything
    // reported missing here.
    if (name.isEmpty) {
      return ToolExecutionResult(
        tool: 'create_budget', success: false,
        messageAr: 'ما اسم الميزانية التي تريد إنشاءها؟',
        messageEn: 'What is the name of the budget to create?',
        errorCode: 'MISSING_NAME',
      );
    }
    if (amount <= 0) {
      return ToolExecutionResult(
        tool: 'create_budget', success: false,
        messageAr: 'كم مبلغ ميزانية "$name"؟ أحتاج مبلغاً أكبر من صفر.',
        messageEn: 'How much is the "$name" budget? I need an amount greater than zero.',
        errorCode: 'INVALID_AMOUNT',
      );
    }

    // One budget per request: optional categories (JSON string list of
    // {name, amount}) live INSIDE this same budget — the remainder of the
    // total simply stays uncategorized. Invalid entries are skipped, never
    // guessed; an empty/absent list means a category-free budget.
    final budget = PersonalBudget(
      id: '',
      name: name,
      periodType: 'monthly',
      totalAmount: amount,
      currency: currency,
      budgetTypes: ['expenses'],
      categories: _parseBudgetCategories(p['categories'], currency),
    );
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor(
          'create_budget', {'name': name, 'amount': amount}),
      run: () async {
        try {
          await _service.addBudget(budget);
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'create_budget',
            queueEntityType: 'personal_budget',
            messageAr: 'تعذر إنشاء ميزانية "$name": ${_cleanError(e, 'حدث خطأ أثناء إنشاء الميزانية')}',
            messageEn: 'Could not create budget "$name"',
            errorCode: 'SAVE_FAILED',
          );
        }
        return _verify.verifyCreate(
          tool: 'create_budget',
          queueEntityType: 'personal_budget',
          resolveId: () => _resolveCreatedId(
            () => _service.getAllBudgets(),
            (m) =>
                (m['name']?.toString() ?? '') == name &&
                ((m['total_amount'] as num?)?.toDouble() ?? -1) == amount,
          ),
          successAr: budget.categories.isEmpty
              ? 'تم إنشاء ميزانية "$name" بمبلغ $amount $currency'
              : 'تم إنشاء ميزانية "$name" بمبلغ $amount $currency مع ${budget.categories.length} أصناف: ${budget.categories.map((c) => '${c.name} ${c.allocatedAmount}').join('، ')}',
          successEn: budget.categories.isEmpty
              ? 'Created budget "$name" of $amount $currency'
              : 'Created budget "$name" of $amount $currency with ${budget.categories.length} categories',
          failureAr: 'لم أتمكن من تأكيد إنشاء ميزانية "$name"، حاول مرة أخرى.',
          failureEn: 'Could not verify budget "$name" creation, please retry.',
          route: '/personal/budget',
        );
      },
    );
    return _adapt(v,
        tool: 'create_budget', entityType: 'budget', route: '/personal/budget');
  }

  Future<ToolExecutionResult> _updateBudget(Map<String, dynamic> p) async {
    final id = _toId(p['budget_id']) ?? '';
    if (id.isEmpty) {
      return ToolExecutionResult(
        tool: 'update_budget', success: false,
        messageAr: 'معرف الميزانية غير صالح',
        messageEn: 'Invalid budget ID',
        errorCode: 'INVALID_ID',
      );
    }
    final budgets = await _service.getAllBudgets();
    final existing = budgets.where((b) => b.id == id).firstOrNull;
    if (existing == null) {
      return ToolExecutionResult(
        tool: 'update_budget', success: false,
        messageAr: 'لم يتم العثور على الميزانية',
        messageEn: 'Budget not found',
        errorCode: 'NOT_FOUND',
      );
    }

    final updated = PersonalBudget(
      id: id,
      name: (p['name'] as String?) ?? existing.name,
      periodType: existing.periodType,
      totalAmount: _toDouble(p['amount']) ?? existing.totalAmount,
      currency: existing.currency,
      budgetTypes: existing.budgetTypes,
      categories: existing.categories,
    );
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor('update_budget', {
        'budget_id': id, 'name': updated.name,
        'amount': updated.totalAmount,
      }),
      run: () async {
        try {
          await _service.updateBudget(updated);
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'update_budget',
            queueEntityType: 'personal_budget',
            messageAr: 'فشل تحديث الميزانية',
            messageEn: 'Failed to update budget',
            errorCode: 'SAVE_FAILED',
          );
        }
        return _verify.verifyUpdate(
          tool: 'update_budget',
          queueEntityType: 'personal_budget',
          entityId: id,
          expectFields: {
            'name': updated.name,
            'total_amount': updated.totalAmount,
          },
          successAr: 'تم تحديث ميزانية "${updated.name}"',
          successEn: 'Updated budget "${updated.name}"',
          failureAr: 'فشل تحديث الميزانية',
          failureEn: 'Failed to update budget',
        );
      },
    );
    return _adapt(v, tool: 'update_budget', entityType: 'budget');
  }

  Future<ToolExecutionResult> _deleteBudget(Map<String, dynamic> p) async {
    final id = _toId(p['budget_id']) ?? '';
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor(
          'delete_budget', {'budget_id': id}),
      run: () async {
        try {
          await _service.deleteBudget(id);
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'delete_budget',
            queueEntityType: 'personal_budget',
            messageAr: 'فشل حذف الميزانية',
            messageEn: 'Failed to delete budget',
            errorCode: 'SAVE_FAILED',
          );
        }
        return _verify.verifyDelete(
          tool: 'delete_budget',
          queueEntityType: 'personal_budget',
          entityId: id,
          successAr: 'تم حذف الميزانية',
          successEn: 'Budget deleted',
          failureAr: 'فشل حذف الميزانية',
          failureEn: 'Failed to delete budget',
        );
      },
    );
    return _adapt(v, tool: 'delete_budget', entityType: 'budget');
  }

  // ═══════════════════════════════════════════════════════════════
  //  WRITE TOOLS — RECURRING
  // ═══════════════════════════════════════════════════════════════

  Future<ToolExecutionResult> _createRecurring(Map<String, dynamic> p) async {
    final name = p['name'] as String? ?? '';
    final amount = _toDouble(p['amount']) ?? 0;
    final txType = p['tx_type'] as String? ?? 'expense';
    final frequency = p['frequency'] as String? ?? 'monthly';

    final rt = RecurringTransaction(
      id: '', type: txType, amount: amount,
      category: (p['category'] as String?) ?? name,
      description: name, frequency: frequency,
    );
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor('create_recurring', {
        'name': name, 'amount': amount, 'tx_type': txType,
        'frequency': frequency,
      }),
      run: () async {
        try {
          await _service.addRecurring(rt);
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'create_recurring',
            queueEntityType: 'personal_recurring_transaction',
            messageAr: 'فشل إنشاء المعاملة المتكررة',
            messageEn: 'Failed to create recurring transaction',
            errorCode: 'SAVE_FAILED',
          );
        }
        return _verify.verifyCreate(
          tool: 'create_recurring',
          queueEntityType: 'personal_recurring_transaction',
          resolveId: () => _resolveCreatedId(
            () => _service.getRecurring(),
            (m) =>
                (m['description']?.toString() ?? '') == name &&
                ((m['amount'] as num?)?.toDouble() ?? -1) == amount &&
                (m['frequency']?.toString() ?? '') == frequency,
          ),
          successAr: 'تم إنشاء معاملة متكررة "$name" بمبلغ $amount ($frequency)',
          successEn: 'Created recurring "$name" of $amount ($frequency)',
          failureAr: 'فشل إنشاء المعاملة المتكررة',
          failureEn: 'Failed to create recurring transaction',
          route: '/personal/recurring',
        );
      },
    );
    return _adapt(v,
        tool: 'create_recurring',
        entityType: 'recurring',
        route: '/personal/recurring');
  }

  Future<ToolExecutionResult> _updateRecurring(Map<String, dynamic> p) async {
    final id = _toId(p['recurring_id']) ?? '';
    final recs = await _service.getRecurring();
    final existing = recs.where((r) => r.id == id).firstOrNull;
    if (existing == null) {
      return ToolExecutionResult(
        tool: 'update_recurring', success: false,
        messageAr: 'لم يتم العثور على المعاملة',
        messageEn: 'Recurring transaction not found',
        errorCode: 'NOT_FOUND',
      );
    }

    final updated = RecurringTransaction(
      id: id, type: existing.type,
      amount: _toDouble(p['amount']) ?? existing.amount,
      category: (p['category'] as String?) ?? existing.category,
      description: (p['name'] as String?) ?? existing.description,
      frequency: (p['frequency'] as String?) ?? existing.frequency,
      intervalValue: existing.intervalValue, currency: existing.currency,
      isActive: existing.isActive,
    );
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor('update_recurring', {
        'recurring_id': id, 'amount': updated.amount,
        'frequency': updated.frequency,
      }),
      run: () async {
        try {
          await _service.updateRecurring(updated);
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'update_recurring',
            queueEntityType: 'personal_recurring_transaction',
            messageAr: 'فشل تحديث المعاملة المتكررة',
            messageEn: 'Failed to update recurring transaction',
            errorCode: 'SAVE_FAILED',
          );
        }
        return _verify.verifyUpdate(
          tool: 'update_recurring',
          queueEntityType: 'personal_recurring_transaction',
          entityId: id,
          expectFields: {
            'amount': updated.amount,
            'frequency': updated.frequency,
          },
          successAr: 'تم تحديث المعاملة المتكررة',
          successEn: 'Recurring transaction updated',
          failureAr: 'فشل تحديث المعاملة المتكررة',
          failureEn: 'Failed to update recurring transaction',
        );
      },
    );
    return _adapt(v, tool: 'update_recurring', entityType: 'recurring');
  }

  Future<ToolExecutionResult> _deleteRecurring(Map<String, dynamic> p) async {
    final id = _toId(p['recurring_id']) ?? '';
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor(
          'delete_recurring', {'recurring_id': id}),
      run: () async {
        try {
          await _service.deleteRecurring(id);
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'delete_recurring',
            queueEntityType: 'personal_recurring_transaction',
            messageAr: 'فشل حذف المعاملة المتكررة',
            messageEn: 'Failed to delete recurring transaction',
            errorCode: 'SAVE_FAILED',
          );
        }
        return _verify.verifyDelete(
          tool: 'delete_recurring',
          queueEntityType: 'personal_recurring_transaction',
          entityId: id,
          successAr: 'تم حذف المعاملة المتكررة',
          successEn: 'Recurring transaction deleted',
          failureAr: 'فشل حذف المعاملة المتكررة',
          failureEn: 'Failed to delete recurring transaction',
        );
      },
    );
    return _adapt(v, tool: 'delete_recurring', entityType: 'recurring');
  }

  Future<ToolExecutionResult> _executeRecurringNow(Map<String, dynamic> p) async {
    final recurringId = _toId(p['recurring_id']);
    if (recurringId == null || recurringId.isEmpty) {
      return const ToolExecutionResult(
        tool: 'execute_recurring_now', success: false,
        messageAr: 'معرف المعاملة المتكررة مطلوب',
        messageEn: 'Recurring ID is required',
        errorCode: 'INVALID_ID', retryable: false, verified: false,
      );
    }
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor(
          'execute_recurring_now', {'recurring_id': recurringId}),
      run: () async {
        List<RecurringTransaction> recs;
        try {
          recs = await _service.getRecurring();
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.verificationFailed,
            tool: 'execute_recurring_now',
            queueEntityType: 'personal_recurring_transaction',
            messageAr: 'تعذر قراءة المعاملة المتكررة',
            messageEn: 'Could not read recurring transaction',
            errorCode: 'UNVERIFIED',
          );
        }
        RecurringTransaction? target;
        for (final r in recs) {
          if (r.id == recurringId) { target = r; break; }
        }
        if (target == null) {
          return const SaraVerificationResult(
            state: SaraVerificationState.notFound,
            tool: 'execute_recurring_now',
            queueEntityType: 'personal_recurring_transaction',
            messageAr: 'المعاملة المتكررة غير موجودة',
            messageEn: 'Recurring transaction not found',
            errorCode: 'NOT_FOUND',
          );
        }
        if (!target.isActive) {
          return const SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'execute_recurring_now',
            queueEntityType: 'personal_recurring_transaction',
            messageAr: 'المعاملة المتكررة معطلة — فعلها أولاً قبل التنفيذ',
            messageEn: 'Recurring transaction is inactive — activate it first',
            errorCode: 'INACTIVE',
          );
        }
        if (target.amount <= 0 || target.type.isEmpty) {
          return const SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'execute_recurring_now',
            queueEntityType: 'personal_recurring_transaction',
            messageAr: 'بيانات المعاملة المتكررة غير مكتملة',
            messageEn: 'Recurring transaction data is incomplete',
            errorCode: 'INVALID_RECURRENCE',
          );
        }
        List<PersonalTransaction> before = const [];
        try {
          before = await _service.getTransactions();
        } catch (_) {}
        final beforeIds = before.map((t) => t.id).toSet();
        try {
          await _service.executeRecurringNow(target, manual: true);
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'execute_recurring_now',
            queueEntityType: 'personal_transaction',
            messageAr: _cleanError(e, 'فشل تنفيذ المعاملة المتكررة'),
            messageEn: _cleanError(e, 'Failed to execute recurring transaction'),
            errorCode: 'SAVE_FAILED',
          );
        }
        // Resolve the freshly created transaction id (no name guessing — the
        // only reliable marker is "not in before").
        String? newId;
        try {
          final after = await _service.getTransactions();
          DateTime? bestDate;
          for (final t in after) {
            if (beforeIds.contains(t.id)) continue;
            final d = t.date;
            if (bestDate == null || (d != null && d.isAfter(bestDate))) {
              bestDate = d;
              newId = t.id;
            }
          }
          if (newId == null) {
            try {
              newId = after.firstWhere((t) => !beforeIds.contains(t.id)).id;
            } catch (_) {}
          }
        } catch (_) {}
        return _verify.verifyCreate(
          tool: 'execute_recurring_now',
          queueEntityType: 'personal_transaction',
          resolveId: () async => newId,
          successAr: 'تم تنفيذ المعاملة المتكررة "${target.name}" بمبلغ ${target.amount} ${saraCurrencyId(target.currency)}',
          successEn: 'Executed recurring "${target.name}" for ${target.amount} ${saraCurrencyId(target.currency)}',
          failureAr: 'فشل تنفيذ المعاملة المتكررة',
          failureEn: 'Failed to execute recurring transaction',
        );
      },
    );
    // Transaction is the entity created — surface its id.
    return _adapt(v, tool: 'execute_recurring_now', entityType: 'transaction');
  }

  Future<ToolExecutionResult> _activateRecurring(Map<String, dynamic> p) async {
    return _toggleRecurring(p, true);
  }

  Future<ToolExecutionResult> _deactivateRecurring(Map<String, dynamic> p) async {
    return _toggleRecurring(p, false);
  }

  Future<ToolExecutionResult> _toggleRecurring(
      Map<String, dynamic> p, bool desired) async {
    final recurringId = _toId(p['recurring_id']);
    if (recurringId == null || recurringId.isEmpty) {
      return ToolExecutionResult(
        tool: desired ? 'activate_recurring' : 'deactivate_recurring',
        success: false,
        messageAr: 'معرف المعاملة المتكررة مطلوب',
        messageEn: 'Recurring ID is required',
        errorCode: 'INVALID_ID', retryable: false, verified: false,
      );
    }
    final tool = desired ? 'activate_recurring' : 'deactivate_recurring';
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor(tool, {'recurring_id': recurringId}),
      run: () async {
        List<RecurringTransaction> recs;
        try {
          recs = await _service.getRecurring();
        } catch (_) {
          return SaraVerificationResult(
            state: SaraVerificationState.verificationFailed,
            tool: tool,
            queueEntityType: 'personal_recurring_transaction',
            messageAr: 'تعذر قراءة المعاملة المتكررة',
            messageEn: 'Could not read recurring transaction',
            errorCode: 'UNVERIFIED',
          );
        }
        RecurringTransaction? target;
        for (final r in recs) {
          if (r.id == recurringId) { target = r; break; }
        }
        if (target == null) {
          return SaraVerificationResult(
            state: SaraVerificationState.notFound,
            tool: tool,
            queueEntityType: 'personal_recurring_transaction',
            messageAr: 'المعاملة المتكررة غير موجودة',
            messageEn: 'Recurring transaction not found',
            errorCode: 'NOT_FOUND',
          );
        }
        if (target.isActive == desired) {
          // Idempotent — already in desired state, confirm current truth.
          return _verify.verifyUpdate(
            tool: tool,
            queueEntityType: 'personal_recurring_transaction',
            entityId: recurringId,
            expectFields: {'is_active': desired ? 1 : 0},
            successAr: desired ? 'المعاملة المتكررة مفعلة بالفعل' : 'المعاملة المتكررة معطلة بالفعل',
            successEn: desired ? 'Recurring transaction is already active' : 'Recurring transaction is already inactive',
            failureAr: 'فشل التحقق من حالة المعاملة المتكررة',
            failureEn: 'Failed to verify recurring transaction state',
          );
        }
        try {
          await _service.toggleRecurringActive(recurringId, desired);
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: tool,
            queueEntityType: 'personal_recurring_transaction',
            messageAr: _cleanError(e, 'فشل تحديث حالة المعاملة المتكررة'),
            messageEn: _cleanError(e, 'Failed to update recurring transaction'),
            errorCode: 'SAVE_FAILED',
          );
        }
        return _verify.verifyUpdate(
          tool: tool,
          queueEntityType: 'personal_recurring_transaction',
          entityId: recurringId,
          expectFields: {'is_active': desired ? 1 : 0},
          successAr: desired ? 'تم تفعيل المعاملة المتكررة' : 'تم تعطيل المعاملة المتكررة',
          successEn: desired ? 'Recurring transaction activated' : 'Recurring transaction deactivated',
          failureAr: 'فشل تحديث حالة المعاملة المتكررة',
          failureEn: 'Failed to update recurring transaction state',
        );
      },
    );
    return _adapt(v, tool: tool, entityType: 'recurring');
  }

  // ═══════════════════════════════════════════════════════════════
  //  CURRENCIES & EXCHANGE RATES
  // ═══════════════════════════════════════════════════════════════

  bool _isValidCurrencyCode(String code) {
    return RegExp(r'^[A-Z][A-Z0-9_]{2,9}$').hasMatch(code);
  }

  Future<ToolExecutionResult> _getCurrencies() async {
    try {
      final enabled = await loadEnabledCurrencies(_service.currentUserId.toString());
      final banks = await _service.getBankAccounts();
      final distinct = <String>{};
      for (final b in banks) {
        final c = saraCurrencyId(b.currency);
        if (c.isNotEmpty) distinct.add(c);
      }
      final all = <String>{...enabled, ...distinct, ...?_fxEngine?.availableCurrencies, ...saraCurrencyNamesAr.keys}.toList()..sort();
      final data = all.map((c) => {
        'currency_code': c,
        'currency_id': c,
        'enabled': enabled.contains(c),
        'has_account': distinct.contains(c),
      }).toList();
      return ToolExecutionResult(
        tool: 'get_currencies', success: true,
        messageAr: 'العملات المفعلة:\n${enabled.map((c) => currencyName(c, locale: 'ar')).join('، ')}\n\nالكتالوج الكامل متاح للتخصيص؛ لا تُستخدم العملات غير المفعلة في العمليات.',
        messageEn: 'Available currencies: ${all.join(', ')}',
        data: {'currencies': data},
        verificationStatus: 'verified', verified: true,
      );
    } catch (e) {
      return ToolExecutionResult(
        tool: 'get_currencies', success: false,
        messageAr: _cleanError(e, 'فشل قراءة العملات'),
        messageEn: _cleanError(e, 'Failed to read currencies'),
        errorCode: 'READ_FAILED', retryable: true, verified: false,
      );
    }
  }

  Future<ToolExecutionResult> _addCurrency(Map<String, dynamic> p) async {
    final code = saraCurrencyId(p['currency_code'] as String? ?? '');
    if (code.isEmpty || !_isValidCurrencyCode(code)) {
      return const ToolExecutionResult(
        tool: 'add_currency', success: false,
        messageAr: 'رمز العملة غير صالح',
        messageEn: 'Invalid currency code',
        errorCode: 'INVALID_CURRENCY', retryable: false, verified: false,
      );
    }
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor('add_currency', {'currency_code': code}),
      run: () async {
        Set<String> enabled;
        try {
          enabled = await loadEnabledCurrencies(_service.currentUserId.toString());
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.verificationFailed,
            tool: 'add_currency',
            queueEntityType: 'currency',
            messageAr: _cleanError(e, 'تعذر قراءة العملات'),
            messageEn: _cleanError(e, 'Could not read currencies'),
            errorCode: 'UNVERIFIED',
          );
        }
        if (enabled.contains(code)) {
          // Idempotent — already enabled.
          return SaraVerificationResult(
            state: SaraVerificationState.successConfirmed,
            tool: 'add_currency',
            queueEntityType: 'currency',
            entityId: code,
            messageAr: 'العملة $code مفعلة بالفعل',
            messageEn: 'Currency $code is already enabled',
            serverConfirmed: true, syncState: 'none',
          );
        }
        final next = {...enabled, code};
        try {
          await saveEnabledCurrencies(next, _service.currentUserId.toString());
          // Ensure cash account exists for the new currency (existing service, local-first).
          try {
            await _service.ensureCashAccounts([code]);
          } catch (_) {}
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'add_currency',
            queueEntityType: 'currency',
            messageAr: _cleanError(e, 'فشل إضافة العملة'),
            messageEn: _cleanError(e, 'Failed to add currency'),
            errorCode: 'SAVE_FAILED',
          );
        }
        // Verify by re-reading enabled set.
        try {
          final after = await loadEnabledCurrencies(_service.currentUserId.toString());
          if (after.contains(code)) {
            return SaraVerificationResult(
              state: SaraVerificationState.successConfirmed,
              tool: 'add_currency',
              queueEntityType: 'currency',
              entityId: code,
              messageAr: 'تم تفعيل العملة $code',
              messageEn: 'Currency $code enabled',
              serverConfirmed: true, syncState: 'none',
            );
          }
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'add_currency',
            queueEntityType: 'currency',
            messageAr: 'فشل التحقق من تفعيل العملة $code',
            messageEn: 'Failed to verify currency $code',
            errorCode: 'UNVERIFIED',
          );
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.verificationFailed,
            tool: 'add_currency',
            queueEntityType: 'currency',
            messageAr: _cleanError(e, 'تعذر التحقق من العملة'),
            messageEn: _cleanError(e, 'Could not verify currency'),
            errorCode: 'UNVERIFIED',
          );
        }
      },
    );
    return _adapt(v, tool: 'add_currency', entityType: 'currency');
  }

  Future<ToolExecutionResult> _deleteCurrency(Map<String, dynamic> p) async {
    final code = saraCurrencyId(p['currency_code'] as String? ?? '');
    if (code.isEmpty || !_isValidCurrencyCode(code)) {
      return const ToolExecutionResult(
        tool: 'delete_currency', success: false,
        messageAr: 'رمز العملة غير صالح',
        messageEn: 'Invalid currency code',
        errorCode: 'INVALID_CURRENCY', retryable: false, verified: false,
      );
    }
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor('delete_currency', {'currency_code': code}),
      run: () async {
        Set<String> enabled;
        try {
          enabled = await loadEnabledCurrencies(_service.currentUserId.toString());
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.verificationFailed,
            tool: 'delete_currency',
            queueEntityType: 'currency',
            messageAr: _cleanError(e, 'تعذر قراءة العملات'),
            messageEn: _cleanError(e, 'Could not read currencies'),
            errorCode: 'UNVERIFIED',
          );
        }
        if (!enabled.contains(code)) {
          return SaraVerificationResult(
            state: SaraVerificationState.successConfirmed,
            tool: 'delete_currency',
            queueEntityType: 'currency',
            entityId: code,
            messageAr: 'العملة $code معطلة بالفعل',
            messageEn: 'Currency $code is already disabled',
            serverConfirmed: true, syncState: 'none',
          );
        }
        final next = {...enabled}..remove(code);
        try {
          await saveEnabledCurrencies(next, _service.currentUserId.toString());
          // Do NOT auto-delete financial data (accounts/transactions) — just disable.
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'delete_currency',
            queueEntityType: 'currency',
            messageAr: _cleanError(e, 'فشل تعطيل العملة'),
            messageEn: _cleanError(e, 'Failed to disable currency'),
            errorCode: 'SAVE_FAILED',
          );
        }
        try {
          final after = await loadEnabledCurrencies(_service.currentUserId.toString());
          if (!after.contains(code)) {
            return SaraVerificationResult(
              state: SaraVerificationState.successConfirmed,
              tool: 'delete_currency',
              queueEntityType: 'currency',
              entityId: code,
              messageAr: 'تم تعطيل العملة $code',
              messageEn: 'Currency $code disabled',
              serverConfirmed: true, syncState: 'none',
            );
          }
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: 'delete_currency',
            queueEntityType: 'currency',
            messageAr: 'فشل التحقق من تعطيل العملة $code',
            messageEn: 'Failed to verify currency $code',
            errorCode: 'UNVERIFIED',
          );
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.verificationFailed,
            tool: 'delete_currency',
            queueEntityType: 'currency',
            messageAr: _cleanError(e, 'تعذر التحقق من العملة'),
            messageEn: _cleanError(e, 'Could not verify currency'),
            errorCode: 'UNVERIFIED',
          );
        }
      },
    );
    return _adapt(v, tool: 'delete_currency', entityType: 'currency');
  }

  Future<ToolExecutionResult> _getExchangeRate(Map<String, dynamic> p) async {
    final from = saraCurrencyId(p['from_currency'] as String? ?? '');
    final to = saraCurrencyId(p['to_currency'] as String? ?? '');
    if (from.isEmpty || to.isEmpty || !_isValidCurrencyCode(from) || !_isValidCurrencyCode(to)) {
      return const ToolExecutionResult(
        tool: 'get_exchange_rate', success: false,
        messageAr: 'رمز العملة غير صالح',
        messageEn: 'Invalid currency code',
        errorCode: 'INVALID_CURRENCY', retryable: false, verified: false,
      );
    }
    if (from == to) {
      return ToolExecutionResult(
        tool: 'get_exchange_rate', success: true,
        messageAr: 'سعر $from إلى $to هو 1',
        messageEn: 'Rate $from to $to is 1',
        data: {'from_currency': from, 'to_currency': to, 'rate': 1.0, 'available': true},
        verificationStatus: 'verified', verified: true,
      );
    }
    try {
      double? rate;
      String source = 'unknown';
      // 1) Try the global/YER engine first (real engine, never invented).
      if (_fxEngine != null) {
        rate = _fxEngine!.getRate(from, to);
        if (rate != null) source = 'engine';
      }
      // 2) Fallback to personal custom rates (local SQLite).
      if (rate == null) {
        try {
          final rates = await _service.getExchangeRates();
          for (final r in rates) {
            if (saraCurrencyId(r.fromCurrency) == from && saraCurrencyId(r.toCurrency) == to) {
              rate = r.rate;
              source = 'personal';
              break;
            }
          }
          // Try reverse via personal rates (1/rate) if direct not found? No, keep distinct.
        } catch (_) {}
      }
      if (rate == null || rate <= 0 || rate.isNaN || rate.isInfinite) {
        return ToolExecutionResult(
          tool: 'get_exchange_rate', success: true,
          messageAr: 'لا يوجد سعر صرف متاح من $from إلى $to',
          messageEn: 'No exchange rate available from $from to $to',
          data: {'from_currency': from, 'to_currency': to, 'rate': null, 'available': false},
          verificationStatus: 'verified', verified: true,
        );
      }
      return ToolExecutionResult(
        tool: 'get_exchange_rate', success: true,
        messageAr: 'سعر $from إلى $to هو $rate',
        messageEn: 'Rate from $from to $to is $rate',
        data: {'from_currency': from, 'to_currency': to, 'rate': rate, 'available': true, 'source': source},
        verificationStatus: 'verified', verified: true,
      );
    } catch (e) {
      return ToolExecutionResult(
        tool: 'get_exchange_rate', success: false,
        messageAr: _cleanError(e, 'فشل قراءة سعر الصرف'),
        messageEn: _cleanError(e, 'Failed to read exchange rate'),
        errorCode: 'READ_FAILED', retryable: true, verified: false,
      );
    }
  }

  Future<ToolExecutionResult> _addExchangeRate(Map<String, dynamic> p) async {
    return _setExchangeRate(p, isUpdate: false);
  }

  Future<ToolExecutionResult> _updateExchangeRate(Map<String, dynamic> p) async {
    return _setExchangeRate(p, isUpdate: true);
  }

  Future<ToolExecutionResult> _setExchangeRate(Map<String, dynamic> p, {required bool isUpdate}) async {
    final from = saraCurrencyId(p['from_currency'] as String? ?? '');
    final to = saraCurrencyId(p['to_currency'] as String? ?? '');
    final rate = _toDouble(p['rate']);
    final tool = isUpdate ? 'update_exchange_rate' : 'add_exchange_rate';
    if (from.isEmpty || to.isEmpty || !_isValidCurrencyCode(from) || !_isValidCurrencyCode(to)) {
      return ToolExecutionResult(
        tool: tool, success: false,
        messageAr: 'رمز العملة غير صالح',
        messageEn: 'Invalid currency code',
        errorCode: 'INVALID_CURRENCY', retryable: false, verified: false,
      );
    }
    if (from == to) {
      return ToolExecutionResult(
        tool: tool, success: false,
        messageAr: 'العملة المصدر والهدف يجب أن تكونا مختلفتين',
        messageEn: 'Source and target currencies must be different',
        errorCode: 'INVALID_PARAMS', retryable: false, verified: false,
      );
    }
    if (rate == null || rate <= 0 || rate.isNaN || rate.isInfinite) {
      return ToolExecutionResult(
        tool: tool, success: false,
        messageAr: 'سعر الصرف يجب أن يكون أكبر من صفر',
        messageEn: 'Exchange rate must be greater than zero',
        errorCode: 'INVALID_RATE', retryable: false, verified: false,
      );
    }
    final v = await _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor(tool, {'from_currency': from, 'to_currency': to, 'rate': rate}),
      run: () async {
        bool ok;
        try {
          ok = await _service.addExchangeRate(fromCurrency: from, toCurrency: to, rate: rate);
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: tool,
            queueEntityType: 'personal_exchange_rate',
            messageAr: _cleanError(e, 'فشل حفظ سعر الصرف'),
            messageEn: _cleanError(e, 'Failed to save exchange rate'),
            errorCode: 'SAVE_FAILED',
          );
        }
        if (!ok) {
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: tool,
            queueEntityType: 'personal_exchange_rate',
            messageAr: 'فشل حفظ سعر الصرف',
            messageEn: 'Failed to save exchange rate',
            errorCode: 'SAVE_FAILED',
          );
        }
        // Verify by re-reading.
        try {
          final rates = await _service.getExchangeRates();
          for (final r in rates) {
            if (saraCurrencyId(r.fromCurrency) == from && saraCurrencyId(r.toCurrency) == to) {
              if ((r.rate - rate).abs() <= 0.000001) {
                return SaraVerificationResult(
                  state: SaraVerificationState.successConfirmed,
                  tool: tool,
                  queueEntityType: 'personal_exchange_rate',
                  entityId: r.id.toString(),
                  messageAr: isUpdate ? 'تم تعديل سعر الصرف من $from إلى $to: $rate' : 'تم إضافة سعر الصرف من $from إلى $to: $rate',
                  messageEn: isUpdate ? 'Exchange rate updated from $from to $to: $rate' : 'Exchange rate added from $from to $to: $rate',
                  serverConfirmed: true, syncState: 'none',
                );
              }
              return SaraVerificationResult(
                state: SaraVerificationState.failed,
                tool: tool,
                queueEntityType: 'personal_exchange_rate',
                messageAr: 'فشل التحقق من سعر الصرف',
                messageEn: 'Failed to verify exchange rate',
                errorCode: 'UNVERIFIED',
              );
            }
          }
          return SaraVerificationResult(
            state: SaraVerificationState.failed,
            tool: tool,
            queueEntityType: 'personal_exchange_rate',
            messageAr: 'سعر الصرف غير موجود بعد الحفظ',
            messageEn: 'Exchange rate not found after save',
            errorCode: 'NOT_FOUND',
          );
        } catch (e) {
          return SaraVerificationResult(
            state: SaraVerificationState.verificationFailed,
            tool: tool,
            queueEntityType: 'personal_exchange_rate',
            messageAr: _cleanError(e, 'تعذر التحقق من سعر الصرف'),
            messageEn: _cleanError(e, 'Could not verify exchange rate'),
            errorCode: 'UNVERIFIED',
          );
        }
      },
    );
    return _adapt(v, tool: tool, entityType: 'exchange_rate');
  }

  Future<ToolExecutionResult> _getDebtPayments(Map<String, dynamic> p) async {
    final debtId = _toId(p['debt_id']);
    if (debtId == null || debtId.isEmpty) {
      return const ToolExecutionResult(tool: 'get_debt_payments', success: false, messageAr: 'معرف الدين مطلوب', messageEn: 'Debt ID is required', errorCode: 'INVALID_ID', retryable: false, verified: false);
    }
    try {
      final payments = await _service.getDebtPayments(debtId);
      final data = payments.map((e) => {'id': e.id, 'amount': e.amount, 'date': e.paymentDate?.toIso8601String()}).toList();
      return ToolExecutionResult(
        tool: 'get_debt_payments', success: true,
        messageAr: 'تم جلب ${payments.length} دفعة للدين',
        messageEn: 'Found ${payments.length} payments for debt',
        data: {'payments': data}, verificationStatus: 'verified', verified: true,
      );
    } catch (e) {
      return ToolExecutionResult(tool: 'get_debt_payments', success: false, messageAr: _cleanError(e, 'فشل جلب مدفوعات الدين'), messageEn: _cleanError(e, 'Failed to get debt payments'), errorCode: 'READ_FAILED', retryable: true, verified: false);
    }
  }

  /// Re-evaluates a past operation's CURRENT truth (surfaces later sync
  /// failures instead of replaying the write).
  Future<ToolExecutionResult> _getOperationStatus(Map<String, dynamic> p) async {
    final rawType = (p['entity_type'] as String?)?.trim().toLowerCase() ?? '';
    final id = _toId(p['entity_id']) ?? '';
    const allowed = [
      'bank', 'transaction', 'goal', 'debt', 'budget', 'recurring'
    ];
    if (!allowed.contains(rawType) || id.isEmpty) {
      return ToolExecutionResult(
        tool: 'get_operation_status', success: false,
        messageAr: 'نوع العملية أو المعرف غير صالح',
        messageEn: 'Invalid operation type or ID',
        errorCode: 'INVALID_PARAMS',
      );
    }
    final queueType =
        SaraVerificationGateway.saraToQueueType[rawType] ?? rawType;
    final v = await _verify.checkOperation(
      tool: 'get_operation_status',
      queueEntityType: queueType,
      entityId: id,
    );
    return _adapt(v, tool: 'get_operation_status', entityType: rawType);
  }
}
