// ─────────────────────────────────────────────────────────────
// Personal finance models — IDs are backend UUID strings end to end.
// No int mapping, no fake IDs: Database → Backend → API → Flutter.
// A missing relation is always `null`, never 0 / -1 / ''.
// ─────────────────────────────────────────────────────────────

import '../../../../core/localization/app_localizations.dart';

/// Translates the cash account name based on current locale.
/// Backend stores "كاش"; this shows "كاش" in Arabic, "CASH" in English.
String cashDisplayName() {
  final isAr = AppLocalizations.t('cancel') == 'إلغاء';
  return isAr ? 'كاش' : 'CASH';
}

/// Check if a bank name refers to the cash account.
bool isCashAccount(String name) =>
    name == 'كاش' || name == 'Cash' || name == 'CASH';

/// Returns the raw string or '' when null.
String _idStr(dynamic v) => v?.toString() ?? '';

/// Returns null when the value is null or an empty string, else the string.
/// Used for every nullable relation id (budget/category/goal/debt/account).
String? _optId(dynamic v) {
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}

class PersonalTransaction {
  /// Backend UUID (personal_transactions.id).
  final String id;
  final String type;
  final double amount;
  final String category;
  final String? description;
  final DateTime? date;
  /// Backend UUID of the bank account, or null when cash/unset.
  final String? accountId;
  final String currency;
  final String? paymentMethod;
  /// Backend UUID of the linked budget, or null.
  final String? budgetId;
  /// Backend UUID of the linked budget category, or null.
  final String? budgetCategoryId;
  /// Backend UUID of the linked savings goal, or null.
  final String? goalId;
  /// Backend UUID of the linked debt, or null.
  final String? debtId;
  /// Amount actually credited to the linked goal in goal currency (may
  /// differ from [amount] for cross-currency contributions). Used to reverse
  /// the exact credit when the transaction is deleted.
  final double? goalAmount;
  /// Execution fingerprint: when this operation actually ran, with
  /// second + fractional-second precision. The accounting [date] can be
  /// backdated and many rows share one day, so lists that must show "what
  /// ran last on top" order by this — never by UUID.
  final DateTime? createdAt;
  /// Exchange rate snapshot used at execution time (offline-first):
  /// history keeps the rate it actually used, even if live rates change.
  final double? exchangeRate;
  final String? exchangeRateCurrency;
  final String? fxSource;

  PersonalTransaction({
    required this.id,
    required this.type,
    required this.amount,
    required this.category,
    this.description,
    this.date,
    this.accountId,
    this.currency = 'SAR',
    this.paymentMethod,
    this.budgetId,
    this.budgetCategoryId,
    this.goalId,
    this.debtId,
    this.goalAmount,
    this.createdAt,
    this.exchangeRate,
    this.exchangeRateCurrency,
    this.fxSource,
  });

  factory PersonalTransaction.fromJson(Map<String, dynamic> json) => PersonalTransaction.fromServer(json);

  factory PersonalTransaction.fromServer(Map<String, dynamic> json) => PersonalTransaction(
    id: _idStr(json['id']),
    type: json['tx_type'] as String? ?? '',
    amount: (json['amount'] as num?)?.toDouble() ?? 0,
    category: json['category'] as String? ?? '',
    description: json['description'] as String?,
    date: json['date'] != null ? DateTime.tryParse(json['date'].toString()) : null,
    accountId: _optId(json['bank_account_id']),
    currency: json['currency'] as String? ?? 'SAR',
    paymentMethod: json['payment_method'] as String?,
    budgetId: _optId(json['budget_id']),
    budgetCategoryId: _optId(json['budget_category_id']),
    goalId: _optId(json['goal_id']),
    debtId: _optId(json['debt_id']),
    goalAmount: (json['goal_amount'] as num?)?.toDouble(),
    createdAt: json['created_at'] != null
        ? DateTime.tryParse(json['created_at'].toString())
        : null,
    exchangeRate: (json['exchange_rate'] as num?)?.toDouble(),
    exchangeRateCurrency: json['exchange_rate_currency'] as String?,
    fxSource: json['fx_source'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id, 'tx_type': type, 'amount': amount, 'category': category,
    if (description != null) 'description': description,
    if (date != null) 'date': date!.toIso8601String(),
    if (accountId != null) 'bank_account_id': accountId,
    'currency': currency,
    if (paymentMethod != null) 'payment_method': paymentMethod,
    if (budgetId != null) 'budget_id': budgetId,
    if (budgetCategoryId != null) 'budget_category_id': budgetCategoryId,
    if (goalId != null) 'goal_id': goalId,
    if (debtId != null) 'debt_id': debtId,
    if (goalAmount != null) 'goal_amount': goalAmount,
    if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
    if (exchangeRate != null) 'exchange_rate': exchangeRate,
    if (exchangeRateCurrency != null) 'exchange_rate_currency': exchangeRateCurrency,
    if (fxSource != null) 'fx_source': fxSource,
  };

  Map<String, dynamic> toServerJson() => {
    'tx_type': type,
    'amount': amount,
    'currency': currency,
    'category': category,
    if (description != null) 'description': description,
    if (date != null) 'date': date!.toIso8601String(),
    if (accountId != null) 'bank_account_id': accountId,
    if (paymentMethod != null) 'payment_method': paymentMethod,
    if (budgetId != null) 'budget_id': budgetId,
    if (budgetCategoryId != null) 'budget_category_id': budgetCategoryId,
    if (goalId != null) 'goal_id': goalId,
    if (debtId != null) 'debt_id': debtId,
    if (goalAmount != null) 'goal_amount': goalAmount,
    if (exchangeRate != null) 'exchange_rate': exchangeRate,
    if (exchangeRateCurrency != null) 'exchange_rate_currency': exchangeRateCurrency,
    if (fxSource != null) 'fx_source': fxSource,
  };
}

/// Canonical newest-first ordering for transaction lists (home "recent",
/// history pages, reports). Null dates sink last; ties break by id so the
/// order is stable whether rows came from the server, the offline mirror,
/// or a merge of both (online + pending).
void sortTransactionsNewestFirst(List<PersonalTransaction> list) {
  list.sort((a, b) {
    if (a.date == null && b.date == null) return b.id.compareTo(a.id);
    if (a.date == null) return 1;
    if (b.date == null) return -1;
    final c = b.date!.compareTo(a.date!);
    if (c != 0) return c;
    return b.id.compareTo(a.id);
  });
}

/// Execution order for "latest transactions" surfaces (home recent): the
/// operation that ran last is on top, strictly newest-first by execution
/// time down to fractions of a second. [PersonalTransaction.createdAt] is
/// the fingerprint (server timestamptz has microsecond precision and is
/// authoritative across devices sharing one account); [date] is only the
/// fallback, then the id for absolute stability.
void sortTransactionsNewestExecutedFirst(List<PersonalTransaction> list) {
  DateTime? stamp(PersonalTransaction t) => t.createdAt ?? t.date;
  list.sort((a, b) {
    final sa = stamp(a);
    final sb = stamp(b);
    if (sa == null && sb == null) return b.id.compareTo(a.id);
    if (sa == null) return 1;
    if (sb == null) return -1;
    final c = sb.compareTo(sa);
    if (c != 0) return c;
    if (a.date == null && b.date == null) return b.id.compareTo(a.id);
    if (a.date == null) return 1;
    if (b.date == null) return -1;
    final d = b.date!.compareTo(a.date!);
    if (d != 0) return d;
    return b.id.compareTo(a.id);
  });
}

class SavingsGoal {
  /// Backend UUID (personal_savings_goals.id).
  final String id;
  final String name;
  final double targetAmount;
  final double currentAmount;
  final String? deadline;
  final String currency;
  final String icon;
  final String? notes;
  /// Backend UUID of the linked budget, or null.
  final String? budgetId;
  final bool isCompleted;
  double get progress => targetAmount > 0 ? (currentAmount / targetAmount).clamp(0.0, 1.0) : 0;

  SavingsGoal({
    required this.id,
    required this.name,
    required this.targetAmount,
    this.currentAmount = 0,
    this.deadline,
    this.currency = 'SAR',
    this.icon = 'مدخرات',
    this.notes,
    this.budgetId,
    this.isCompleted = false,
  });

  factory SavingsGoal.fromJson(Map<String, dynamic> json) => SavingsGoal.fromServer(json);

  factory SavingsGoal.fromServer(Map<String, dynamic> json) => SavingsGoal(
    id: _idStr(json['id']),
    name: json['name'] as String? ?? '',
    targetAmount: (json['target_amount'] as num?)?.toDouble() ?? 0,
    currentAmount: (json['current_amount'] as num?)?.toDouble() ?? 0,
    deadline: json['deadline'] as String?,
    currency: json['currency'] as String? ?? 'SAR',
    icon: json['icon'] as String? ?? 'مدخرات',
    notes: json['notes'] as String?,
    budgetId: _optId(json['budget_id']),
    isCompleted: json['is_completed'] == true,
  );

  SavingsGoal copyWith({
    String? id,
    String? name,
    double? targetAmount,
    double? currentAmount,
    String? deadline,
    String? currency,
    String? icon,
    String? notes,
    String? budgetId,
    bool? isCompleted,
  }) => SavingsGoal(
    id: id ?? this.id,
    name: name ?? this.name,
    targetAmount: targetAmount ?? this.targetAmount,
    currentAmount: currentAmount ?? this.currentAmount,
    deadline: deadline ?? this.deadline,
    currency: currency ?? this.currency,
    icon: icon ?? this.icon,
    notes: notes ?? this.notes,
    budgetId: budgetId ?? this.budgetId,
    isCompleted: isCompleted ?? this.isCompleted,
  );

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'target_amount': targetAmount,
    'current_amount': currentAmount, if (deadline != null) 'deadline': deadline,
    'currency': currency, 'icon': icon,
    if (notes != null) 'notes': notes,
    if (budgetId != null) 'budget_id': budgetId,
    'is_completed': isCompleted,
  };

  Map<String, dynamic> toServerJson() => {
    'name': name,
    'target_amount': targetAmount,
    'current_amount': currentAmount,
    if (deadline != null) 'deadline': deadline,
    'currency': currency,
    'icon': icon,
    if (notes != null) 'notes': notes,
    if (budgetId != null) 'budget_id': budgetId,
  };
}

/// Device vocabulary for a Personal bank account type from any source.
///
/// The server stores `current` / `savings`; the app has always used
/// `checking` (جاري) / `savings` (توفير) / `cash`. Unknown/blank → checking.
String personalAccountTypeFromServer(String? raw) {
  final t = (raw ?? '').trim().toLowerCase();
  switch (t) {
    case 'savings':
    case 'saving':
    case 'توفير':
      return 'savings';
    case 'cash':
      return 'cash';
    default:
      return 'checking';
  }
}

/// Server vocabulary (`current` / `savings`) for a device account type.
String personalAccountTypeToServer(String? type) =>
    personalAccountTypeFromServer(type) == 'savings' ? 'savings' : 'current';

class PersonalBankAccount {
  /// Backend UUID (personal_bank_accounts.id).
  final String id;
  final String bankName;
  final double balance;
  final String currency;
  final String? notes;
  final String accountType;

  /// Server's `account_type_set`: true when the server row carries a stated
  /// type, false for legacy rows whose type was never stored on the server
  /// (they read as جاري), null when unknown (older server / local-only row).
  final bool? accountTypeSet;

  PersonalBankAccount({required this.id, required this.bankName, this.balance = 0.0, this.currency = 'SAR', this.notes, this.accountType = 'checking', this.accountTypeSet});

  factory PersonalBankAccount.fromJson(Map<String, dynamic> json) => PersonalBankAccount.fromServer(json);

  factory PersonalBankAccount.fromServer(Map<String, dynamic> json) {
    final bankName = json['bank_name'] as String? ?? '';
    return PersonalBankAccount(
      id: _idStr(json['id']),
      bankName: bankName,
      balance: (json['balance'] as num?)?.toDouble() ?? 0.0,
      currency: json['currency'] as String? ?? 'SAR',
      notes: json['notes'] as String?,
      accountType: (bankName == 'كاش' || bankName == 'Cash')
          ? 'cash'
          : personalAccountTypeFromServer(json['account_type']?.toString()),
      accountTypeSet: json['account_type_set'] is bool
          ? json['account_type_set'] as bool
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id, 'bank_name': bankName, 'balance': balance, 'currency': currency,
    'account_type': accountType,
    if (notes != null) 'notes': notes,
  };

  Map<String, dynamic> toServerJson() => {
    'bank_name': bankName,
    'currency': currency,
    if (accountType != 'cash')
      'account_type': personalAccountTypeToServer(accountType),
    if (notes != null) 'notes': notes,
  };
}

class PersonalDebt {
  /// Backend UUID (personal_debts.id).
  final String id;
  final String type;
  final String personName;
  final double amount;
  final double paid;
  final String status;
  final String? description;
  final bool isPaid;
  final DateTime? dueDate;
  final String currency;
  final bool reminder;
  /// Backend UUID of the linked budget, or null.
  final String? budgetId;

  PersonalDebt({
    required this.id,
    required this.type,
    required this.personName,
    required this.amount,
    this.paid = 0.0,
    this.status = 'active',
    this.description,
    this.isPaid = false,
    this.dueDate,
    this.currency = 'SAR',
    this.reminder = false,
    this.budgetId,
  });

  double get remaining => amount - paid;
  double get progress => amount > 0 ? (paid / amount).clamp(0.0, 1.0) : 0;
  bool get isOverdue => dueDate != null && dueDate!.isBefore(DateTime.now()) && status != 'paid';

  PersonalDebt copyWith({
    String? id,
    String? type,
    String? personName,
    double? amount,
    double? paid,
    String? status,
    String? description,
    bool? isPaid,
    DateTime? dueDate,
    String? currency,
    bool? reminder,
    String? budgetId,
  }) {
    return PersonalDebt(
      id: id ?? this.id,
      type: type ?? this.type,
      personName: personName ?? this.personName,
      amount: amount ?? this.amount,
      paid: paid ?? this.paid,
      status: status ?? this.status,
      description: description ?? this.description,
      isPaid: isPaid ?? this.isPaid,
      dueDate: dueDate ?? this.dueDate,
      currency: currency ?? this.currency,
      reminder: reminder ?? this.reminder,
      budgetId: budgetId ?? this.budgetId,
    );
  }

  factory PersonalDebt.fromJson(Map<String, dynamic> json) => PersonalDebt.fromServer(json);

  factory PersonalDebt.fromServer(Map<String, dynamic> json) {
    final isPaid = json['is_paid'] == true;
    final rem = json['reminder'] ?? json['is_reminder'] ?? json['remind_on_due'] ?? false;
    final bool remBool = rem == true || rem == 1 || rem.toString() == '1';
    final double parsedPaid = (json['paid'] as num?)?.toDouble() ?? (isPaid ? (json['amount'] as num?)?.toDouble() ?? 0 : 0);
    return PersonalDebt(
      id: _idStr(json['id']),
      type: json['debt_type'] as String? ?? '',
      personName: json['person_name'] as String? ?? '',
      amount: (json['amount'] as num?)?.toDouble() ?? 0,
      paid: parsedPaid,
      status: isPaid ? 'paid' : (json['status'] as String? ?? 'active'),
      description: json['description'] as String?,
      isPaid: isPaid,
      dueDate: json['due_date'] != null ? DateTime.tryParse(json['due_date'] as String) : null,
      currency: json['currency'] as String? ?? 'SAR',
      reminder: remBool,
      budgetId: _optId(json['budget_id']),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'debt_type': type,
    'person_name': personName,
    'amount': amount,
    'paid': paid,
    'status': status,
    if (description != null) 'description': description,
    'is_paid': isPaid,
    if (dueDate != null) 'due_date': dueDate!.toIso8601String(),
    'currency': currency,
    'reminder': reminder ? 1 : 0,
    if (budgetId != null) 'budget_id': budgetId,
  };

  Map<String, dynamic> toServerJson() => {
    'debt_type': type,
    'person_name': personName,
    'amount': amount,
    'currency': currency,
    if (description != null) 'description': description,
    if (dueDate != null) 'due_date': dueDate!.toIso8601String(),
    'reminder': reminder,
    if (budgetId != null) 'budget_id': budgetId,
  };
}

class PersonalDebtPayment {
  /// Backend UUID (personal_debt_payments.id).
  final String id;
  /// Backend UUID of the debt.
  final String debtId;
  final double amount;
  final String currency;
  final String paymentMethod;
  final String? bankAccountId;
  /// Backend UUID of the budget (copied from debt.budget_id at creation).
  final String? budgetId;
  final DateTime paymentDate;
  final String? notes;

  PersonalDebtPayment({
    required this.id,
    required this.debtId,
    required this.amount,
    this.currency = 'SAR',
    this.paymentMethod = 'cash',
    this.bankAccountId,
    this.budgetId,
    required this.paymentDate,
    this.notes,
  });

  factory PersonalDebtPayment.fromJson(Map<String, dynamic> json) => PersonalDebtPayment.fromServer(json);

  factory PersonalDebtPayment.fromServer(Map<String, dynamic> json) => PersonalDebtPayment(
    id: _idStr(json['id']),
    debtId: _idStr(json['debt_id']),
    amount: (json['amount'] as num?)?.toDouble() ?? 0,
    currency: json['currency'] as String? ?? 'SAR',
    paymentMethod: json['payment_method'] as String? ?? 'cash',
    bankAccountId: _optId(json['bank_account_id']),
    budgetId: _optId(json['budget_id']),
    paymentDate: DateTime.tryParse(json['payment_date']?.toString() ?? '') ?? DateTime.now(),
    notes: json['notes'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'debt_id': debtId,
    'amount': amount,
    'currency': currency,
    'payment_method': paymentMethod,
    if (bankAccountId != null) 'bank_account_id': bankAccountId,
    if (budgetId != null) 'budget_id': budgetId,
    'payment_date': paymentDate.toIso8601String(),
    if (notes != null) 'notes': notes,
  };

  Map<String, dynamic> toServerJson() => {
    'amount': amount,
    'payment_date': paymentDate.toIso8601String(),
    if (notes != null) 'notes': notes,
    if (bankAccountId != null) 'bank_account_id': bankAccountId,
    'payment_method': paymentMethod,
  };
}

class ExchangeRate {
  final int id;
  final String fromCurrency;
  final String toCurrency;
  final double rate;

  ExchangeRate({required this.id, required this.fromCurrency, required this.toCurrency, required this.rate});

  factory ExchangeRate.fromJson(Map<String, dynamic> json) => ExchangeRate(
    id: json['id'] as int? ?? 0,
    fromCurrency: json['from_currency'] as String? ?? '',
    toCurrency: json['to_currency'] as String? ?? '',
    rate: (json['rate'] as num?)?.toDouble() ?? 0,
  );
}

class PersonalBudget {
  /// Backend UUID (personal_budgets.id).
  final String id;
  final String userId;
  final String name;
  final String periodType; // 'daily', 'weekly', 'custom_days', 'date_range', 'monthly', 'yearly', 'multi_months'
  final DateTime? startDate;
  final DateTime? endDate;
  final int? customDays;
  final double totalAmount;
  final String currency;
  /// Backend UUIDs of linked bank accounts.
  final List<String> bankAccountIds;
  final List<String> budgetTypes; // ['expenses', 'debts', 'goals']
  final double totalSpent;
  final List<BudgetCategory> categories;

  PersonalBudget({
    required this.id,
    this.userId = '',
    required this.name,
    this.periodType = 'monthly',
    this.startDate,
    this.endDate,
    this.customDays,
    this.totalAmount = 0,
    this.currency = 'SAR',
    this.bankAccountIds = const [],
    this.budgetTypes = const ['expenses'],
    this.totalSpent = 0,
    this.categories = const [],
  });

  double get remaining => (totalAmount - totalSpent).clamp(0, double.infinity);
  bool get isOverBudget => totalSpent > totalAmount;
  double get overAmount => isOverBudget ? totalSpent - totalAmount : 0;
  double get usagePercent => totalAmount > 0 ? (totalSpent / totalAmount * 100).clamp(0, 999) : 0;
  double get progress => totalAmount > 0 ? (totalSpent / totalAmount).clamp(0.0, 1.0) : 0;
  bool get isActive => startDate != null && endDate != null
      ? DateTime.now().isAfter(startDate!) && DateTime.now().isBefore(endDate!)
      : true;
  bool get isExpired => endDate != null && DateTime.now().isAfter(endDate!);

  int get daysRemaining {
    if (endDate == null) return 999;
    final diff = endDate!.difference(DateTime.now()).inDays;
    return diff < 0 ? 0 : diff;
  }

  String get periodLabel {
    switch (periodType) {
      case 'daily': return AppLocalizations.t('periodDaily');
      case 'weekly': return AppLocalizations.t('periodWeekly');
      case 'custom_days': return AppLocalizations.t('periodCustomDays', {'days': '$customDays'});
      case 'date_range': return AppLocalizations.t('periodDateRange', {'from': _fmtDate(startDate), 'to': _fmtDate(endDate)});
      case 'monthly': return AppLocalizations.t('periodMonthly');
      case 'yearly': return AppLocalizations.t('periodYearly');
      case 'multi_months': return AppLocalizations.t('periodMultiMonths');
      default: return periodType;
    }
  }

  String _fmtDate(DateTime? d) {
    if (d == null) return '--';
    return '${d.day}/${d.month}/${d.year}';
  }

  static List<String> _parseBankIds(dynamic raw) {
    if (raw == null) return [];
    if (raw is List) {
      return raw.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
    }
    return [];
  }

  factory PersonalBudget.fromJson(Map<String, dynamic> json) => PersonalBudget.fromServer(json);

  factory PersonalBudget.fromServer(Map<String, dynamic> json) => PersonalBudget(
    id: _idStr(json['id']),
    userId: _idStr(json['user_id']),
    name: json['name'] as String? ?? json['category'] as String? ?? '',
    periodType: json['period_type'] as String? ?? json['period'] as String? ?? 'monthly',
    startDate: json['start_date'] != null ? DateTime.tryParse(json['start_date'].toString()) : null,
    endDate: json['end_date'] != null ? DateTime.tryParse(json['end_date'].toString()) : null,
    customDays: json['custom_days'] is int ? json['custom_days'] as int : int.tryParse(json['custom_days']?.toString() ?? ''),
    totalAmount: (json['total_amount'] as num?)?.toDouble() ?? (json['limit_amount'] as num?)?.toDouble() ?? (json['amount'] as num?)?.toDouble() ?? 0,
    currency: json['currency'] as String? ?? 'SAR',
    bankAccountIds: _parseBankIds(json['bank_account_ids']),
    budgetTypes: json['budget_types'] != null
        ? List<String>.from((json['budget_types'] as List).map((e) => e.toString()))
        : ['expenses'],
    totalSpent: (json['total_spent'] as num?)?.toDouble() ?? (json['current_spent'] as num?)?.toDouble() ?? (json['spent'] as num?)?.toDouble() ?? 0,
    categories: json['categories'] != null
        ? (json['categories'] as List).map((e) => BudgetCategory.fromJson(e as Map<String, dynamic>)).toList()
        : [],
  );

  PersonalBudget copyWith({
    String? id,
    String? userId,
    String? name,
    String? periodType,
    DateTime? startDate,
    DateTime? endDate,
    int? customDays,
    double? totalAmount,
    String? currency,
    List<String>? bankAccountIds,
    List<String>? budgetTypes,
    double? totalSpent,
    List<BudgetCategory>? categories,
  }) => PersonalBudget(
    id: id ?? this.id,
    userId: userId ?? this.userId,
    name: name ?? this.name,
    periodType: periodType ?? this.periodType,
    startDate: startDate ?? this.startDate,
    endDate: endDate ?? this.endDate,
    customDays: customDays ?? this.customDays,
    totalAmount: totalAmount ?? this.totalAmount,
    currency: currency ?? this.currency,
    bankAccountIds: bankAccountIds ?? this.bankAccountIds,
    budgetTypes: budgetTypes ?? this.budgetTypes,
    totalSpent: totalSpent ?? this.totalSpent,
    categories: categories ?? this.categories,
  );

  Map<String, dynamic> toJson() => {
    'id': id, 'user_id': userId, 'name': name,
    'period_type': periodType, 'currency': currency,
    'total_amount': totalAmount, 'amount': totalAmount,
    'total_spent': totalSpent, 'spent': totalSpent,
    'bank_account_ids': bankAccountIds,
    'budget_types': budgetTypes,
    'custom_days': customDays,
    if (startDate != null) 'start_date': startDate!.toIso8601String(),
    if (endDate != null) 'end_date': endDate!.toIso8601String(),
    'categories': categories.map((c) => c.toJson()).toList(),
  };

  Map<String, dynamic> toServerJson() => {
    'name': name, 'amount': totalAmount,
    'period_type': periodType, 'currency': currency,
    'bank_account_ids': bankAccountIds,
    'budget_types': budgetTypes,
    'custom_days': customDays,
    if (startDate != null) 'start_date': startDate!.toIso8601String(),
    if (endDate != null) 'end_date': endDate!.toIso8601String(),
    'categories': categories.map((c) => c.toServerJson()).toList(),
  };
}

class BudgetCategory {
  /// Backend UUID (personal_budget_categories.id).
  final String id;
  /// Backend UUID of the parent budget.
  final String budgetId;
  final String name;
  final String type; // 'expense', 'debt', 'goal'
  final double allocatedAmount;
  final double spentAmount;
  final String currency;
  /// Backend UUID of the linked goal (type == 'goal'), or null.
  final String? goalId;
  /// Backend UUID of the linked debt (type == 'debt'), or null.
  final String? debtId;

  BudgetCategory({
    required this.id,
    this.budgetId = '',
    required this.name,
    required this.type,
    this.allocatedAmount = 0,
    this.spentAmount = 0,
    this.currency = 'SAR',
    this.goalId,
    this.debtId,
  });

  double get remaining => (allocatedAmount - spentAmount).clamp(0, double.infinity);
  bool get isOver => spentAmount > allocatedAmount;
  double get overAmount => isOver ? spentAmount - allocatedAmount : 0;
  double get usagePercent => allocatedAmount > 0 ? (spentAmount / allocatedAmount * 100).clamp(0, 999) : 0;
  double get progress => allocatedAmount > 0 ? (spentAmount / allocatedAmount).clamp(0.0, 1.0) : 0;

  factory BudgetCategory.fromJson(Map<String, dynamic> json) => BudgetCategory(
    id: _idStr(json['id']),
    budgetId: _idStr(json['budget_id']),
    name: json['name'] as String? ?? '',
    type: json['type'] as String? ?? 'expense',
    allocatedAmount: (json['allocated_amount'] as num?)?.toDouble() ?? (json['amount'] as num?)?.toDouble() ?? 0,
    spentAmount: (json['spent_amount'] as num?)?.toDouble() ?? (json['spent'] as num?)?.toDouble() ?? 0,
    currency: json['currency'] as String? ?? 'SAR',
    goalId: _optId(json['goal_id']),
    debtId: _optId(json['debt_id']),
  );

  BudgetCategory copyWith({
    String? id,
    String? budgetId,
    String? name,
    String? type,
    double? allocatedAmount,
    double? spentAmount,
    String? currency,
    String? goalId,
    String? debtId,
  }) => BudgetCategory(
    id: id ?? this.id,
    budgetId: budgetId ?? this.budgetId,
    name: name ?? this.name,
    type: type ?? this.type,
    allocatedAmount: allocatedAmount ?? this.allocatedAmount,
    spentAmount: spentAmount ?? this.spentAmount,
    currency: currency ?? this.currency,
    goalId: goalId ?? this.goalId,
    debtId: debtId ?? this.debtId,
  );

  Map<String, dynamic> toJson() => {
    'id': id, 'budget_id': budgetId, 'name': name, 'type': type,
    'allocated_amount': allocatedAmount, 'amount': allocatedAmount,
    'spent_amount': spentAmount, 'spent': spentAmount,
    'currency': currency,
    if (goalId != null) 'goal_id': goalId,
    if (debtId != null) 'debt_id': debtId,
  };

  Map<String, dynamic> toServerJson() => {
    // Client UUID for never-synced categories (the server materializes the
    // same id, keeping offline transaction links valid after sync).
    if (id.isNotEmpty) 'id': id,
    'name': name, 'type': type, 'amount': allocatedAmount, 'currency': currency,
    if (goalId != null) 'goal_id': goalId,
    if (debtId != null) 'debt_id': debtId,
  };
}

/// The date after [rt]'s next occurrence — the same rule as the «تخطي مرة»
/// button (RecurringNotifier.skipOccurrence); used by Sara's skip_recurring.
DateTime nextRecurringDate(RecurringTransaction rt) {
  final current = rt.nextDate ?? DateTime.now();
  final n = rt.intervalValue < 1 ? 1 : rt.intervalValue;
  DateTime addMonths(DateTime date, int months) {
    var year = date.year;
    var month = date.month + months;
    while (month > 12) { month -= 12; year++; }
    while (month < 1) { month += 12; year--; }
    final day = date.day.clamp(1, DateTime(year, month + 1, 0).day);
    return DateTime(year, month, day);
  }
  switch (rt.frequency) {
    case 'weekly':
      return current.add(Duration(days: 7 * n));
    case 'monthly':
      return addMonths(current, n);
    case 'yearly':
      return addMonths(current, 12 * n);
    default:
      return current.add(Duration(days: n));
  }
}

class RecurringTransaction {
  /// Backend UUID.
  final String id;
  final String userId;
  final String name;
  final String type;
  final double amount;
  final String category;
  final String? description;
  final String frequency;
  final int intervalValue;
  final DateTime? nextDate;
  final String? paymentMethod;
  final String? bankAccountId;
  final String currency;
  final bool isActive;
  final String accountType; // 'fixed' | 'pick_at_execution'
  final String executionType; // 'auto' | 'reminder'
  final String? reminderTime; // HH:MM
  final int? approximateStartDay;
  final int? approximateEndDay;
  final DateTime? lastExecutedAt;

  RecurringTransaction({
    required this.id,
    this.userId = '',
    this.name = '',
    required this.type,
    required this.amount,
    required this.category,
    this.description,
    this.frequency = 'monthly',
    this.intervalValue = 1,
    this.nextDate,
    this.paymentMethod,
    this.bankAccountId,
    this.currency = 'SAR',
    this.isActive = true,
    this.accountType = 'fixed',
    this.executionType = 'auto',
    this.reminderTime,
    this.approximateStartDay,
    this.approximateEndDay,
    this.lastExecutedAt,
  });

  String get frequencyLabel {
    switch (frequency) {
      case 'daily': return AppLocalizations.t('freqDaily');
      case 'weekly': return AppLocalizations.t('freqWeekly');
      case 'monthly': return AppLocalizations.t('freqMonthly');
      case 'yearly': return AppLocalizations.t('freqYearly');
      default: return frequency;
    }
  }

  bool get isApproximate => approximateStartDay != null && approximateEndDay != null;

  RecurringTransaction copyWith({
    String? id,
    String? userId,
    String? name,
    String? type,
    double? amount,
    String? category,
    String? description,
    String? frequency,
    int? intervalValue,
    DateTime? nextDate,
    String? paymentMethod,
    String? bankAccountId,
    String? currency,
    bool? isActive,
    String? accountType,
    String? executionType,
    String? reminderTime,
    int? approximateStartDay,
    int? approximateEndDay,
    DateTime? lastExecutedAt,
  }) => RecurringTransaction(
    id: id ?? this.id,
    userId: userId ?? this.userId,
    name: name ?? this.name,
    type: type ?? this.type,
    amount: amount ?? this.amount,
    category: category ?? this.category,
    description: description ?? this.description,
    frequency: frequency ?? this.frequency,
    intervalValue: intervalValue ?? this.intervalValue,
    nextDate: nextDate ?? this.nextDate,
    paymentMethod: paymentMethod ?? this.paymentMethod,
    bankAccountId: bankAccountId ?? this.bankAccountId,
    currency: currency ?? this.currency,
    isActive: isActive ?? this.isActive,
    accountType: accountType ?? this.accountType,
    executionType: executionType ?? this.executionType,
    reminderTime: reminderTime ?? this.reminderTime,
    approximateStartDay: approximateStartDay ?? this.approximateStartDay,
    approximateEndDay: approximateEndDay ?? this.approximateEndDay,
    lastExecutedAt: lastExecutedAt ?? this.lastExecutedAt,
  );

  factory RecurringTransaction.fromJson(Map<String, dynamic> json) => RecurringTransaction.fromServer(json);

  factory RecurringTransaction.fromServer(Map<String, dynamic> json) => RecurringTransaction(
    id: _idStr(json['id']),
    userId: _idStr(json['user_id']),
    name: json['name'] as String? ?? '',
    type: json['tx_type'] as String? ?? '',
    amount: (json['amount'] as num?)?.toDouble() ?? 0,
    currency: json['currency'] as String? ?? 'SAR',
    category: json['category'] as String? ?? '',
    description: json['description'] as String?,
    frequency: json['frequency'] as String? ?? 'monthly',
    intervalValue: json['interval_value'] as int? ?? 1,
    nextDate: json['next_run_date'] != null
        ? DateTime.tryParse(json['next_run_date'].toString())
        : (json['next_date'] != null ? DateTime.tryParse(json['next_date'].toString()) : null),
    paymentMethod: json['payment_method'] as String?,
    bankAccountId: _optId(json['bank_account_id']),
    isActive: json['is_active'] == true || json['is_active'] == 1,
    accountType: json['account_type'] as String? ?? 'fixed',
    executionType: json['execution_type'] as String? ?? 'auto',
    reminderTime: json['reminder_time'] as String?,
    approximateStartDay: json['approximate_start_day'] as int?,
    approximateEndDay: json['approximate_end_day'] as int?,
    lastExecutedAt: json['last_executed_at'] != null ? DateTime.tryParse(json['last_executed_at'].toString()) : null,
  );

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'tx_type': type, 'amount': amount, 'currency': currency,
    'category': category,
    if (description != null) 'description': description,
    'frequency': frequency, 'interval_value': intervalValue,
    if (nextDate != null) 'next_date': nextDate!.toIso8601String(),
    if (paymentMethod != null) 'payment_method': paymentMethod,
    if (bankAccountId != null) 'bank_account_id': bankAccountId,
    'is_active': isActive ? 1 : 0,
    'account_type': accountType, 'execution_type': executionType,
    if (reminderTime != null) 'reminder_time': reminderTime,
    if (approximateStartDay != null) 'approximate_start_day': approximateStartDay,
    if (approximateEndDay != null) 'approximate_end_day': approximateEndDay,
    if (lastExecutedAt != null) 'last_executed_at': lastExecutedAt!.toIso8601String(),
  };

  Map<String, dynamic> toServerJson() => {
    'name': name, 'tx_type': type, 'amount': amount, 'currency': currency,
    'category': category,
    if (description != null) 'description': description,
    'frequency': frequency, 'interval_value': intervalValue,
    if (nextDate != null) 'next_run_date': nextDate!.toIso8601String(),
    'is_active': isActive,
    'account_type': accountType,
    if (bankAccountId != null) 'bank_account_id': bankAccountId,
    'execution_type': executionType,
    if (reminderTime != null) 'reminder_time': reminderTime,
    if (approximateStartDay != null) 'approximate_start_day': approximateStartDay,
    if (approximateEndDay != null) 'approximate_end_day': approximateEndDay,
    // Persisted so the same-day execution guard survives in the local mirror
    // (server replay + CRUD schemas safely ignore this extra key).
    if (lastExecutedAt != null) 'last_executed_at': lastExecutedAt!.toIso8601String(),
  };
}

class SpendingCategory {
  final String id;
  final String name;
  final String nameAr;
  final String icon;
  final String color;
  final int sortOrder;
  final bool isActive;

  SpendingCategory({
    required this.id,
    required this.name,
    required this.nameAr,
    this.icon = 'CATEGORY',
    this.color = '#6B0F1A',
    this.sortOrder = 0,
    this.isActive = true,
  });

  factory SpendingCategory.fromJson(Map<String, dynamic> json) => SpendingCategory(
    id: _idStr(json['id']).isEmpty ? (json['name'] as String? ?? '') : _idStr(json['id']),
    name: json['name'] as String? ?? '',
    nameAr: json['name_ar'] as String? ?? '',
    icon: json['icon'] as String? ?? 'CATEGORY',
    color: json['color'] as String? ?? '#6B0F1A',
    sortOrder: json['sort_order'] as int? ?? 0,
    isActive: (json['is_active'] ?? 1) == 1,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'name_ar': nameAr,
    'icon': icon,
    'color': color,
    'sort_order': sortOrder,
    'is_active': isActive ? 1 : 0,
  };
}

/// Maps a stored category value (currently Arabic) to a localization key suffix.
/// Returns null when the value has no known mapping (e.g. free-text categories).
String? personalCategoryKey(String category) {
  switch (category) {
    case 'مرتب': case 'راتب': return 'salary';
    case 'بيع': return 'sale';
    case 'هدية': case 'هدايا': return 'gift';
    case 'إيجار': return 'rent';
    case 'استثمار': return 'investment';
    case 'عمولة': return 'commission';
    case 'عمل حر': return 'freelance';
    case 'مكافأة': return 'bonus';
    case 'طعام': return 'food';
    case 'مواصلات': return 'transport';
    case 'اتصالات': return 'communication';
    case 'صحة': return 'health';
    case 'تعليم': return 'education';
    case 'ترفيه': return 'entertainment';
    case 'فواتير': return 'bills';
    case 'تسوق': return 'shopping';
    case 'سفر': return 'travel';
    case 'ادخار': return 'saving';
    case 'أخرى': return 'other';
    default: return null;
  }
}
