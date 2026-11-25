import '../../../personal/data/models/personal_models.dart';
import '../../../personal/domain/services/personal_analytics.dart';
import '../../../personal/domain/services/personal_finance_service.dart';
import 'tool_executor.dart';

/// Personal Sara's reads on THIS phone (Stage 5, docs/PERSONAL_LOCAL_PLAN.md).
///
/// The Personal ledger lives only on the user's devices, so the server
/// never reads it: when Sara needs data the server pauses with
/// `device_calls` (`{id, method: TOOL, path: <tool>, params}`) and this
/// router answers each from the same PersonalFinanceService the screens use.
/// Answers keep the server's result shapes (the model and the prompt read
/// them unchanged) and stay compact: lists are bounded, the loop trims the
/// rest ([SaraDeviceLoop.compact]).
///
/// The flutter-owned read tools (balances, categories, currencies, debt
/// payments, operation status) are answered by the existing on-device read
/// cases of [ToolExecutor].
class PersonalDeviceRouter {
  final PersonalFinanceService service;
  final ToolExecutor? executor;
  final String language;
  final DateTime Function() _now;

  PersonalDeviceRouter(this.service, {this.executor, this.language = 'ar', DateTime Function()? now})
      : _now = now ?? DateTime.now;

  bool get _en => language == 'en';

  /// Reads answered by [ToolExecutor]'s own read cases.
  static const executorReads = {
    'get_balance', 'get_transactions', 'get_categories', 'get_currencies',
    'get_debt_payments', 'get_operation_status',
  };

  /// Every Personal read this phone answers (mirrors the server's
  /// DEVICE_READ_TOOLS in sara_personal_device.py).
  static const supportedTools = {
    'get_banking_data', 'get_financial_summary', 'get_sales_data',
    'get_financial_analytics', 'get_expenses_data', 'search_all_transactions',
    'get_bank_accounts', 'get_savings_goals', 'get_debts', 'get_budgets',
    'get_recurring', 'search_entity', 'get_entity_detail', ...executorReads,
  };

  static const _maxRows = 50;

  /// Answers one call. Never throws: a failure comes back as data so Sara
  /// can say what could not be read.
  Future<Map<String, dynamic>> handle(Map<String, dynamic> call) async {
    final tool = '${call['path'] ?? ''}';
    final params = call['params'] is Map ? Map<String, dynamic>.from(call['params'] as Map) : <String, dynamic>{};
    if ('${call['method'] ?? 'TOOL'}'.toUpperCase() != 'TOOL' || !supportedTools.contains(tool)) {
      return _fail(_en ? 'This read is not available on the device.' : 'هذه القراءة غير متاحة على الجهاز.');
    }
    try {
      if (executorReads.contains(tool)) return await _viaExecutor(tool, params);
      final data = await _read(tool, params);
      if (data is Map && data['error'] != null) return _fail('${data['error']}');
      return {'success': true, 'data': data};
    } catch (error) {
      final text = '$error'.replaceFirst(RegExp(r'^[A-Za-z]*(Exception|Error)[: ]*'), '').trim();
      return _fail(text.isEmpty || text.length > 300
          ? (_en ? 'The device could not read this data.' : 'تعذرت قراءة هذه البيانات من الجهاز.')
          : text);
    }
  }

  static Map<String, dynamic> _fail(String reason) => {'success': false, 'error': reason, 'message': reason};

  Future<Map<String, dynamic>> _viaExecutor(String tool, Map<String, dynamic> params) async {
    final ex = executor ?? ToolExecutor(service);
    final r = await ex.execute(tool, params);
    if (!r.success) return {..._fail(r.message(language)), 'error_code': r.errorCode};
    return {'success': true, 'data': {'message': r.message(language), ...?r.data}};
  }

  Future<Object?> _read(String tool, Map<String, dynamic> p) async {
    switch (tool) {
      case 'get_bank_accounts':
        return {'accounts': await _accounts()};
      case 'get_banking_data':
        return {
          'accounts': await _accounts(),
          if (p['include_transactions'] == true || '${p['include_transactions']}' == 'true')
            'transactions': [for (final t in (await _txs()).take(_limit(p, 10))) _shortTx(t)],
        };
      case 'get_savings_goals':
        return {'savings_goals': [for (final g in await service.getSavingsGoals()) _goal(g)]};
      case 'get_debts':
        return {'debts': [for (final d in await service.getDebts()) _debt(d)]};
      case 'get_budgets':
        return {'budgets': [for (final b in await service.getAllBudgets()) _budget(b)]};
      case 'get_recurring':
        return {'recurring': [for (final r in await service.getRecurring()) _recurring(r)]};
      case 'get_financial_summary':
      case 'get_sales_data':
        return _summary(_bounds(p));
      case 'get_expenses_data':
        return _expenses(_bounds(p), p);
      case 'search_all_transactions':
        return _search(p);
      case 'search_entity':
        return _searchEntity(p);
      case 'get_entity_detail':
        return _entityDetail(p);
      case 'get_financial_analytics':
        return _analytics(_bounds(p));
    }
    throw StateError(_en ? 'Unknown read.' : 'قراءة غير معروفة.');
  }

  // ── shapes (same keys as the server's former table reads) ──
  static String _money(num v) => '${PyDecimal.money(v)}';
  static String _code(String c) => (c.isEmpty ? 'SAR' : c).toUpperCase();

  Future<List<Map<String, dynamic>>> _accounts() async => [
    for (final a in await service.getBankAccounts())
      {'id': a.id, 'name': a.bankName, 'currency': a.currency, 'balance': _money(a.balance), 'type': 'bank'},
  ];

  static Map<String, dynamic> _goal(SavingsGoal g) => {
    'id': g.id, 'name': g.name, 'target_amount': _money(g.targetAmount),
    'current_amount': _money(g.currentAmount), 'currency': _code(g.currency),
  };

  static Map<String, dynamic> _debt(PersonalDebt d) => {
    'id': d.id, 'person_name': d.personName, 'amount': _money(d.amount),
    'remaining': _money(d.remaining), 'currency': d.currency, 'debt_type': d.type, 'is_paid': d.isPaid,
  };

  static Map<String, dynamic> _budget(PersonalBudget b) => {
    'id': b.id, 'name': b.name, 'amount': _money(b.totalAmount), 'currency': b.currency,
  };

  static Map<String, dynamic> _recurring(RecurringTransaction r) => {
    'id': r.id, 'name': r.name, 'amount': _money(r.amount), 'currency': r.currency, 'is_active': r.isActive,
  };

  static String _day(DateTime? t) => t == null ? '' : pyIso(t).substring(0, 10);

  static Map<String, dynamic> _shortTx(PersonalTransaction t) => {
    'description': t.description, 'amount': _money(t.amount),
    'currency_id': _code(t.currency), 'currency': _code(t.currency),
    'type': t.type, 'category': t.category, 'date': _day(t.date),
  };

  static int _limit(Map<String, dynamic> p, int fallback) {
    final v = int.tryParse('${p['limit'] ?? ''}') ?? fallback;
    return v < 1 ? 1 : (v > _maxRows ? _maxRows : v);
  }

  Future<List<PersonalTransaction>> _txs() async {
    final all = [...await service.getTransactions()];
    all.sort((a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)));
    return all;
  }

  AnalyticsBounds _bounds(Map<String, dynamic> p) => p['bounds'] is Map
      ? AnalyticsBounds.fromJson(Map<String, dynamic>.from(p['bounds'] as Map))
      : AnalyticsBounds.thisMonthUtc(_now());

  static bool _inside(PersonalTransaction t, AnalyticsBounds b) {
    final d = t.date?.toUtc();
    return d != null && !d.isBefore(b.startAt) && d.isBefore(b.endAt);
  }

  Future<Map<String, dynamic>> _summary(AnalyticsBounds b) async {
    final income = <String, PyDecimal>{}, expense = <String, PyDecimal>{};
    for (final t in (await service.getTransactions()).where((t) => _inside(t, b))) {
      final bucket = t.type == 'income' ? income : t.type == 'expense' ? expense : null;
      if (bucket == null) continue;
      final code = _code(t.currency);
      bucket[code] = (bucket[code] ?? PyDecimal.zero) + PyDecimal.money(t.amount);
    }
    final codes = {...income.keys, ...expense.keys}.toList()..sort();
    return {
      'period': b.period,
      'by_currency': [
        for (final c in codes)
          {
            'currency_id': c, 'currency': c,
            'income': '${income[c] ?? PyDecimal.zero}', 'expense': '${expense[c] ?? PyDecimal.zero}',
            'net': '${(income[c] ?? PyDecimal.zero) - (expense[c] ?? PyDecimal.zero)}',
          },
      ],
    };
  }

  Future<Map<String, dynamic>> _expenses(AnalyticsBounds b, Map<String, dynamic> p) async {
    final category = '${p['category'] ?? ''}'.trim();
    final rows = [
      for (final t in await _txs())
        if (t.type == 'expense' && _inside(t, b) && (category.isEmpty || t.category == category)) t,
    ];
    final byCurrency = <String, PyDecimal>{};
    final byCategory = <(String, String), PyDecimal>{};
    for (final t in rows) {
      final c = _code(t.currency), v = PyDecimal.money(t.amount);
      byCurrency[c] = (byCurrency[c] ?? PyDecimal.zero) + v;
      byCategory[(t.category, c)] = (byCategory[(t.category, c)] ?? PyDecimal.zero) + v;
    }
    final catKeys = byCategory.keys.toList()
      ..sort((x, y) => x.$1 != y.$1 ? x.$1.compareTo(y.$1) : x.$2.compareTo(y.$2));
    final shown = rows.take(_limit(p, 20)).toList();
    return {
      'period': b.period,
      'by_currency': [
        for (final c in (byCurrency.keys.toList()..sort()))
          {'currency_id': c, 'currency': c, 'total': '${byCurrency[c]}'},
      ],
      'by_category': [
        for (final k in catKeys) {'category': k.$1, 'currency_id': k.$2, 'currency': k.$2, 'total': '${byCategory[k]}'},
      ],
      'expenses': [
        for (final t in shown)
          {
            'description': t.description ?? '', 'amount': _money(t.amount),
            'currency_id': _code(t.currency), 'currency': _code(t.currency),
            'category': t.category, 'date': t.date == null ? '' : pyIso(t.date!, sep: ' '),
          },
      ],
      if (shown.length < rows.length) 'expenses_coverage': {'shown': shown.length, 'total': rows.length},
      'bank_withdrawals': const [],
      'category_filter': category.isEmpty ? null : category,
    };
  }

  /// Dates without a time are UTC midnights (the server compared them so).
  static DateTime? _utcDay(Object? v) {
    final text = '${v ?? ''}'.trim();
    if (text.isEmpty) return null;
    final t = DateTime.tryParse(text);
    if (t == null) return null;
    return t.isUtc || RegExp(r'([+-]\d{2}:?\d{2}|Z)$').hasMatch(text)
        ? t.toUtc()
        : DateTime.utc(t.year, t.month, t.day, t.hour, t.minute, t.second);
  }

  Future<Map<String, dynamic>> _search(Map<String, dynamic> p) async {
    final query = '${p['query'] ?? ''}'.trim().toLowerCase();
    final type = '${p['tx_type'] ?? ''}'.trim();
    final category = '${p['category'] ?? ''}'.trim();
    final from = _utcDay(p['from_date']), to = _utcDay(p['to_date']);
    final rows = [
      for (final t in await _txs())
        if ((query.isEmpty || (t.description ?? '').toLowerCase().contains(query)) &&
            (type.isEmpty || t.type == type) &&
            (category.isEmpty || t.category == category) &&
            (from == null || (t.date != null && !t.date!.toUtc().isBefore(from))) &&
            (to == null || (t.date != null && !t.date!.toUtc().isAfter(to))))
          t,
    ];
    final shown = rows.take(_limit(p, 20)).toList();
    return {
      'transactions': [for (final t in shown) _shortTx(t)],
      if (shown.length < rows.length) 'transactions_coverage': {'shown': shown.length, 'total': rows.length},
    };
  }

  Future<Map<String, List<Map<String, dynamic>>>> _pools() async {
    final banks = await _accounts();
    return {
      'goal': [for (final g in await service.getSavingsGoals()) _goal(g)],
      'debt': [for (final d in await service.getDebts()) _debt(d)],
      'budget': [for (final b in await service.getAllBudgets()) _budget(b)],
      'recurring': [for (final r in await service.getRecurring()) _recurring(r)],
      'bank': banks,
      'account': banks,
    };
  }

  static const _labels = {'goal': 'name', 'debt': 'person_name', 'budget': 'name',
    'recurring': 'name', 'bank': 'name', 'account': 'name'};

  Future<Map<String, dynamic>> _searchEntity(Map<String, dynamic> p) async {
    final query = '${p['query'] ?? ''}'.trim().toLowerCase();
    final type = '${p['entity_type'] ?? ''}'.trim().toLowerCase();
    if (query.isEmpty) return {'error': _en ? 'Missing search query' : 'نص البحث مفقود'};
    if (type.isNotEmpty && !_labels.containsKey(type)) {
      return {'error': _en ? 'Unknown entity type: $type' : 'نوع عنصر غير معروف: $type'};
    }
    final pools = await _pools();
    return {
      'matches': [
        for (final key in type.isEmpty ? _labels.keys : [type])
          for (final item in pools[key]!)
            if ('${item[_labels[key]] ?? ''}'.trim().toLowerCase().contains(query)) {'entity_type': key, ...item},
      ],
    };
  }

  Future<Map<String, dynamic>> _entityDetail(Map<String, dynamic> p) async {
    final type = '${p['entity_type'] ?? ''}'.trim().toLowerCase();
    final id = '${p['entity_id'] ?? ''}'.trim();
    if (!_labels.containsKey(type)) {
      return {'error': _en ? 'Unknown entity type: $type' : 'نوع عنصر غير معروف: $type'};
    }
    Map<String, dynamic>? row;
    switch (type) {
      case 'bank':
      case 'account':
        for (final a in await service.getBankAccounts()) {
          if (a.id == id) row = {'bank_name': a.bankName, 'currency': a.currency, 'balance': _money(a.balance)};
        }
      case 'goal':
        for (final g in await service.getSavingsGoals()) {
          if (g.id == id) {
            row = {'name': g.name, 'target_amount': _money(g.targetAmount), 'current_amount': _money(g.currentAmount),
              'currency': g.currency};
          }
        }
      case 'debt':
        for (final d in await service.getDebts()) {
          if (d.id == id) {
            row = {'person_name': d.personName, 'amount': _money(d.amount), 'paid': _money(d.paid),
              'currency': d.currency, 'debt_type': d.type, 'is_paid': '${d.isPaid}'};
          }
        }
      case 'budget':
        for (final b in await service.getAllBudgets()) {
          if (b.id == id) {
            row = {'name': b.name, 'total_amount': _money(b.totalAmount), 'spent': _money(b.totalSpent),
              'currency': b.currency};
          }
        }
      case 'recurring':
        for (final r in await service.getRecurring()) {
          if (r.id == id) {
            row = {'name': r.name, 'amount': _money(r.amount), 'currency': r.currency, 'is_active': '${r.isActive}'};
          }
        }
    }
    if (row == null) return {'error': _en ? 'Not found' : 'العنصر غير موجود'};
    return {'entity': {'id': id, 'entity_type': type, ...row}};
  }

  Future<Map<String, dynamic>> _analytics(AnalyticsBounds b) async {
    final debts = await service.getDebts();
    final payments = <String, List<PersonalDebtPayment>>{};
    for (final d in debts.take(10)) {
      try {
        payments[d.id] = await service.getDebtPayments(d.id);
      } catch (_) {
        payments[d.id] = const [];
      }
    }
    final rows = PersonalAnalytics.rowsFrom(
      accounts: await service.getBankAccounts(),
      transactions: await service.getTransactions(),
      budgets: await service.getAllBudgets(),
      goals: await service.getSavingsGoals(),
      debts: debts,
      payments: payments,
      recurring: await service.getRecurring(),
    );
    return PersonalAnalytics.build(
      accounts: rows['accounts']!, transactions: rows['transactions']!, budgets: rows['budgets']!,
      goals: rows['goals']!, debts: rows['debts']!, recurring: rows['recurring']!,
      bounds: b, generatedAt: _now());
  }
}
