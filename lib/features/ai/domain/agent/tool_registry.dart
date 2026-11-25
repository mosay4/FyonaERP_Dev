/// Centralized Tool Registry for Sara AI Agent.
///
/// Every operation available in the app is registered here with:
/// - Canonical name (English, language-independent)
/// - Parameter schema (required/optional, types, allowed values)
/// - Validation rules
/// - Risk level (low/medium/high/critical)
/// - Whether confirmation is needed
/// - Route for deep navigation
///
/// The backend uses this to tell OpenAI which tools are available.
/// The Flutter side uses this for parameter collection and validation.
enum ToolCategory { read, write, navigate, analytics }
enum RiskLevel { low, medium, high, critical }
enum ParamType { string, number, bool, date, enum_ }

class ParamSchema {
  final String name;
  final ParamType type;
  final bool required;
  final String descriptionAr;
  final String descriptionEn;
  final dynamic defaultValue;
  final List<String>? allowedValues;
  final double? min;
  final double? max;
  final int? maxLength;
  final String? pattern;

  const ParamSchema({
    required this.name,
    required this.type,
    this.required = false,
    required this.descriptionAr,
    required this.descriptionEn,
    this.defaultValue,
    this.allowedValues,
    this.min,
    this.max,
    this.maxLength,
    this.pattern,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type.name,
    'required': required,
    'description_ar': descriptionAr,
    'description_en': descriptionEn,
    'default': defaultValue,
    if (allowedValues != null) 'allowed_values': allowedValues,
    if (min != null) 'min': min,
    if (max != null) 'max': max,
    if (maxLength != null) 'max_length': maxLength,
    if (pattern != null) 'pattern': pattern,
  };
}

class ToolDefinition {
  final String name;
  final String nameAr;
  final String descriptionAr;
  final String descriptionEn;
  final ToolCategory category;
  final RiskLevel riskLevel;
  final bool requiresConfirmation;
  final List<ParamSchema> params;
  final String? routeTemplate;
  final String? entityType;
  final List<String> verificationQueries;

  const ToolDefinition({
    required this.name,
    required this.nameAr,
    required this.descriptionAr,
    required this.descriptionEn,
    required this.category,
    this.riskLevel = RiskLevel.low,
    this.requiresConfirmation = false,
    this.params = const [],
    this.routeTemplate,
    this.entityType,
    this.verificationQueries = const [],
  });

  ToolCategory get toolCategory => category;

  List<ParamSchema> get requiredParams => params.where((p) => p.required).toList();
  List<ParamSchema> get optionalParams => params.where((p) => !p.required).toList();

  Map<String, dynamic> toOpenAiTool() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': descriptionEn,
      'parameters': {
        'type': 'object',
        'properties': {
          for (final p in params)
            p.name: {
              'type': p.type == ParamType.enum_ ? 'string' : p.type.name,
              'description': p.descriptionEn,
              if (p.allowedValues != null) 'enum': p.allowedValues,
              if (p.min != null) 'minimum': p.min,
              if (p.max != null) 'maximum': p.max,
            },
        },
        'required': requiredParams.map((p) => p.name).toList(),
      },
    },
  };

  Map<String, dynamic> toJson() => {
    'name': name,
    'name_ar': nameAr,
    'description_ar': descriptionAr,
    'description_en': descriptionEn,
    'category': category.name,
    'risk_level': riskLevel.name,
    'requires_confirmation': requiresConfirmation,
    'params': params.map((p) => p.toJson()).toList(),
    'route_template': routeTemplate,
    'entity_type': entityType,
  };
}

/// Central registry of all tools. Access via `AgentToolRegistry.tools`.
class AgentToolRegistry {
  AgentToolRegistry._();

  static const List<ToolDefinition> tools = [
    // ═══════════════════════════════════════════════════════════════
    //  READ TOOLS
    // ═══════════════════════════════════════════════════════════════
    ToolDefinition(
      name: 'get_balance',
      nameAr: 'الرصيد',
      descriptionAr: 'عرض الأرصدة مفصولة حسب العملة، مع إجمالي محوّل اختياري',
      descriptionEn: 'Show balances separated by currency, with optional converted total',
      category: ToolCategory.read,
      entityType: 'account',
      params: [
        ParamSchema(name: 'currency', type: ParamType.string, required: false, descriptionAr: 'عملة الإجمالي المحوّل (اختياري)', descriptionEn: 'Target currency for converted total (optional)'),
      ],
    ),
    ToolDefinition(
      name: 'get_bank_accounts',
      nameAr: 'الحسابات البنكية',
      descriptionAr: 'عرض جميع الحسابات البنكية مع الأرصدة',
      descriptionEn: 'List all bank accounts with balances',
      category: ToolCategory.read,
      entityType: 'bank',
      routeTemplate: '/personal/banks',
    ),
    ToolDefinition(
      name: 'get_transactions',
      nameAr: 'المعاملات',
      descriptionAr: 'عرض المعاملات المالية مع إمكانية التصفية',
      descriptionEn: 'List financial transactions with optional filters',
      category: ToolCategory.read,
      entityType: 'transaction',
      params: [
        ParamSchema(name: 'account_id', type: ParamType.string, descriptionAr: 'معرف الحساب', descriptionEn: 'Account ID filter'),
        ParamSchema(name: 'month', type: ParamType.number, descriptionAr: 'الشهر', descriptionEn: 'Month filter', min: 1, max: 12),
        ParamSchema(name: 'year', type: ParamType.number, descriptionAr: 'السنة', descriptionEn: 'Year filter'),
        ParamSchema(name: 'tx_type', type: ParamType.enum_, descriptionAr: 'نوع المعاملة', descriptionEn: 'Transaction type', allowedValues: ['income', 'expense', 'transfer']),
      ],
    ),
    ToolDefinition(
      name: 'get_savings_goals',
      nameAr: 'الأهداف',
      descriptionAr: 'عرض جميع أهداف الادخار',
      descriptionEn: 'List all savings goals',
      category: ToolCategory.read,
      entityType: 'goal',
      routeTemplate: '/personal/savings',
    ),
    ToolDefinition(
      name: 'get_debts',
      nameAr: 'الديون',
      descriptionAr: 'عرض جميع الديون ( المدينة والدائنة)',
      descriptionEn: 'List all debts (payable and receivable)',
      category: ToolCategory.read,
      entityType: 'debt',
      routeTemplate: '/personal/debts',
    ),
    ToolDefinition(
      name: 'get_budgets',
      nameAr: 'الميزانيات',
      descriptionAr: 'عرض الميزانيات الشهرية',
      descriptionEn: 'Show monthly budgets',
      category: ToolCategory.read,
      entityType: 'budget',
      routeTemplate: '/personal/budget',
    ),
    ToolDefinition(
      name: 'get_recurring',
      nameAr: 'المعاملات المتكررة',
      descriptionAr: 'عرض المعاملات المتكررة النشطة',
      descriptionEn: 'Show active recurring transactions',
      category: ToolCategory.read,
      entityType: 'recurring',
      routeTemplate: '/personal/recurring',
    ),
    ToolDefinition(
      name: 'get_categories',
      nameAr: 'التصنيفات',
      descriptionAr: 'عرض تصنيفات المصروفات',
      descriptionEn: 'Show expense categories',
      category: ToolCategory.read,
      entityType: 'category',
    ),
    ToolDefinition(
      name: 'search_entity',
      nameAr: 'بحث',
      descriptionAr: 'البحث عن عنصر محدد بالاسم أو المعرف',
      descriptionEn: 'Search for a specific entity by name or ID',
      category: ToolCategory.read,
      params: [
        ParamSchema(name: 'query', type: ParamType.string, required: true, descriptionAr: 'نص البحث', descriptionEn: 'Search text'),
        ParamSchema(name: 'entity_type', type: ParamType.enum_, required: true, descriptionAr: 'نوع العنصر', descriptionEn: 'Entity type', allowedValues: ['bank', 'goal', 'debt', 'budget', 'recurring', 'transaction']),
      ],
    ),
    ToolDefinition(
      name: 'get_entity_detail',
      nameAr: 'تفاصيل عنصر',
      descriptionAr: 'عرض تفاصيل عنصر محدد',
      descriptionEn: 'Show details of a specific entity',
      category: ToolCategory.read,
      params: [
        ParamSchema(name: 'entity_type', type: ParamType.enum_, required: true, descriptionAr: 'نوع العنصر', descriptionEn: 'Entity type', allowedValues: ['bank', 'goal', 'debt', 'budget', 'recurring']),
        ParamSchema(name: 'entity_id', type: ParamType.string, required: true, descriptionAr: 'معرف العنصر', descriptionEn: 'Entity ID'),
      ],
    ),
    ToolDefinition(
      name: 'get_operation_status',
      nameAr: 'حالة عملية',
      descriptionAr: 'التحقق من الحالة الحالية الموثقة لعملية سابقة (مؤكدة/معلقة/فاشلة) بالمعرف',
      descriptionEn: 'Check the current verified state of a past operation by ID (confirmed/pending/failed)',
      category: ToolCategory.read,
      params: [
        ParamSchema(name: 'entity_type', type: ParamType.enum_, required: true, descriptionAr: 'نوع العنصر', descriptionEn: 'Entity type', allowedValues: ['bank', 'transaction', 'goal', 'debt', 'budget', 'recurring']),
        ParamSchema(name: 'entity_id', type: ParamType.string, required: true, descriptionAr: 'معرف العنصر', descriptionEn: 'Entity ID'),
      ],
    ),

    // ═══════════════════════════════════════════════════════════════
    //  WRITE TOOLS — TRANSACTIONS
    // ═══════════════════════════════════════════════════════════════
    ToolDefinition(
      name: 'create_transaction',
      requiresConfirmation: true,
      nameAr: 'إضافة معاملة',
      descriptionAr: 'إضافة معاملة مالية (دخل أو مصروف)',
      descriptionEn: 'Add a financial transaction (income or expense)',
      category: ToolCategory.write,
      riskLevel: RiskLevel.medium,
      entityType: 'transaction',
      verificationQueries: ['get_transactions'],
      params: [
        ParamSchema(name: 'type', type: ParamType.enum_, required: true, descriptionAr: 'نوع المعاملة', descriptionEn: 'Transaction type', allowedValues: ['income', 'expense']),
        ParamSchema(name: 'amount', type: ParamType.number, required: true, descriptionAr: 'المبلغ', descriptionEn: 'Amount', min: 0.01),
        ParamSchema(name: 'category', type: ParamType.string, required: true, descriptionAr: 'التصنيف', descriptionEn: 'Category'),
        ParamSchema(name: 'date', type: ParamType.date, required: false, descriptionAr: 'التاريخ (YYYY-MM-DD)', descriptionEn: 'Date (YYYY-MM-DD)'),
        ParamSchema(name: 'description', type: ParamType.string, required: false, descriptionAr: 'الوصف', descriptionEn: 'Description'),
        ParamSchema(name: 'account_id', type: ParamType.string, required: false, descriptionAr: 'معرف الحساب البنكي', descriptionEn: 'Bank account ID'),
        ParamSchema(name: 'currency', type: ParamType.string, required: false, descriptionAr: 'العملة', descriptionEn: 'Currency', defaultValue: 'SAR'),
      ],
    ),
    ToolDefinition(
      name: 'create_transfer',
      requiresConfirmation: true,
      nameAr: 'تحويل أموال',
      descriptionAr: 'تحويل أموال بين حسابين بنكيين',
      descriptionEn: 'Transfer money between two bank accounts',
      category: ToolCategory.write,
      riskLevel: RiskLevel.medium,
      entityType: 'transaction',
      params: [
        ParamSchema(name: 'from_account_id', type: ParamType.string, required: true, descriptionAr: 'معرف الحساب المحول منه', descriptionEn: 'Source account ID'),
        ParamSchema(name: 'to_account_id', type: ParamType.string, required: true, descriptionAr: 'معرف الحساب المحول إليه', descriptionEn: 'Destination account ID'),
        ParamSchema(name: 'from_currency', type: ParamType.string, descriptionAr: 'عملة المصدر', descriptionEn: 'Source currency'),
        ParamSchema(name: 'to_currency', type: ParamType.string, descriptionAr: 'عملة الاستلام', descriptionEn: 'Destination currency'),
        ParamSchema(name: 'exchange_rate', type: ParamType.number, descriptionAr: 'سعر الصرف المعتمد للتنفيذ', descriptionEn: 'Confirmed exchange rate'),
        ParamSchema(name: 'destination_amount', type: ParamType.number, descriptionAr: 'المبلغ المستلم', descriptionEn: 'Destination amount'),
        ParamSchema(name: 'amount', type: ParamType.number, required: true, descriptionAr: 'المبلغ', descriptionEn: 'Amount', min: 0.01),
      ],
    ),

    // ═══════════════════════════════════════════════════════════════
    //  WRITE TOOLS — BANK ACCOUNTS
    // ═══════════════════════════════════════════════════════════════
    ToolDefinition(
      name: 'create_bank_account',
      nameAr: 'إضافة حساب بنكي',
      descriptionAr: 'إنشاء حساب بنكي جديد',
      descriptionEn: 'Create a new bank account',
      category: ToolCategory.write,
      riskLevel: RiskLevel.low,
      entityType: 'bank',
      routeTemplate: '/personal/banks',
      verificationQueries: ['get_bank_accounts'],
      params: [
        ParamSchema(name: 'bank_name', type: ParamType.string, required: true, descriptionAr: 'اسم البنك', descriptionEn: 'Bank name'),
        ParamSchema(name: 'currency', type: ParamType.string, required: true, descriptionAr: 'العملة', descriptionEn: 'Currency', allowedValues: ['SAR', 'USD', 'EUR', 'GBP', 'YER', 'YER_OLD', 'YER_NEW', 'AED', 'EGP']),
        ParamSchema(name: 'opening_balance', type: ParamType.number, required: false, descriptionAr: 'الرصيد الابتدائي', descriptionEn: 'Opening balance', defaultValue: 0),
        ParamSchema(name: 'notes', type: ParamType.string, required: false, descriptionAr: 'ملاحظات', descriptionEn: 'Notes'),
        ParamSchema(name: 'account_type', type: ParamType.string, required: false, descriptionAr: 'نوع الحساب: جاري أو توفير', descriptionEn: 'Account type: checking or savings', allowedValues: ['checking', 'savings'], defaultValue: 'checking'),
      ],
    ),
    ToolDefinition(
      name: 'update_bank_account',
      nameAr: 'تعديل حساب بنكي',
      descriptionAr: 'تعديل حساب بنكي موجود',
      descriptionEn: 'Update an existing bank account',
      category: ToolCategory.write,
      riskLevel: RiskLevel.medium,
      entityType: 'bank',
      // Moves money / changes a balance: a confirmation card first.
      requiresConfirmation: true,
      params: [
        ParamSchema(name: 'account_id', type: ParamType.string, required: true, descriptionAr: 'معرف الحساب', descriptionEn: 'Account ID'),
        ParamSchema(name: 'bank_name', type: ParamType.string, required: false, descriptionAr: 'الاسم الجديد', descriptionEn: 'New name'),
        ParamSchema(name: 'currency', type: ParamType.string, required: false, descriptionAr: 'العملة الجديدة', descriptionEn: 'New currency'),
        ParamSchema(name: 'balance', type: ParamType.number, required: false, descriptionAr: 'الرصيد الجديد', descriptionEn: 'New balance'),
        ParamSchema(name: 'notes', type: ParamType.string, required: false, descriptionAr: 'ملاحظات جديدة', descriptionEn: 'New notes'),
      ],
    ),
    ToolDefinition(
      name: 'delete_bank_account',
      nameAr: 'حذف حساب بنكي',
      descriptionAr: 'حذف حساب بنكي نهائياً',
      descriptionEn: 'Permanently delete a bank account',
      category: ToolCategory.write,
      riskLevel: RiskLevel.critical,
      requiresConfirmation: true,
      entityType: 'bank',
      params: [
        ParamSchema(name: 'account_id', type: ParamType.string, required: true, descriptionAr: 'معرف الحساب', descriptionEn: 'Account ID'),
      ],
    ),
    // «حذف البنك بالكامل» on the banks screen: every currency account of
    // one bank. Cash can never be deleted as a whole (same as the button).
    ToolDefinition(
      name: 'delete_bank',
      nameAr: 'حذف البنك بالكامل',
      descriptionAr: 'حذف بنك بكل عملاته وحساباته نهائياً (الكاش لا يُحذف)',
      descriptionEn: 'Permanently delete a whole bank with all its currency accounts (cash cannot be deleted)',
      category: ToolCategory.write,
      riskLevel: RiskLevel.critical,
      requiresConfirmation: true,
      entityType: 'bank',
      params: [
        ParamSchema(name: 'bank_name', type: ParamType.string, required: true, descriptionAr: 'اسم البنك', descriptionEn: 'Bank name'),
      ],
    ),

    // ═══════════════════════════════════════════════════════════════
    //  WRITE TOOLS — SAVINGS GOALS
    // ═══════════════════════════════════════════════════════════════
    ToolDefinition(
      name: 'create_savings_goal',
      nameAr: 'إنشاء هدف ادخار',
      descriptionAr: 'إنشاء هدف ادخار جديد',
      descriptionEn: 'Create a new savings goal',
      category: ToolCategory.write,
      riskLevel: RiskLevel.low,
      entityType: 'goal',
      routeTemplate: '/personal/savings',
      verificationQueries: ['get_savings_goals'],
      params: [
        ParamSchema(name: 'name', type: ParamType.string, required: true, descriptionAr: 'اسم الهدف', descriptionEn: 'Goal name'),
        ParamSchema(name: 'target_amount', type: ParamType.number, required: true, descriptionAr: 'المبلغ المستهدف', descriptionEn: 'Target amount', min: 0.01),
        ParamSchema(name: 'current_amount', type: ParamType.number, required: false, descriptionAr: 'المبلغ الحالي', descriptionEn: 'Current amount', defaultValue: 0),
        ParamSchema(name: 'deadline', type: ParamType.date, required: false, descriptionAr: 'تاريخ الاستحقاق', descriptionEn: 'Deadline'),
        ParamSchema(name: 'notes', type: ParamType.string, required: false, descriptionAr: 'ملاحظات', descriptionEn: 'Notes'),
      ],
    ),
    ToolDefinition(
      name: 'update_savings_goal',
      nameAr: 'تعديل هدف ادخار',
      descriptionAr: 'تعديل هدف ادخار موجود',
      descriptionEn: 'Update an existing savings goal',
      category: ToolCategory.write,
      riskLevel: RiskLevel.low,
      entityType: 'goal',
      params: [
        ParamSchema(name: 'goal_id', type: ParamType.string, required: true, descriptionAr: 'معرف الهدف', descriptionEn: 'Goal ID'),
        ParamSchema(name: 'name', type: ParamType.string, required: false, descriptionAr: 'الاسم الجديد', descriptionEn: 'New name'),
        ParamSchema(name: 'target_amount', type: ParamType.number, required: false, descriptionAr: 'المبلغ المستهدف الجديد', descriptionEn: 'New target amount'),
        ParamSchema(name: 'deadline', type: ParamType.date, required: false, descriptionAr: 'تاريخ الاستحقاق الجديد', descriptionEn: 'New deadline'),
      ],
    ),
    ToolDefinition(
      name: 'contribute_to_goal',
      nameAr: 'إضافة مبلغ لهدف',
      descriptionAr: 'إضافة مبلغ إلى هدف ادخار موجود',
      descriptionEn: 'Contribute amount to an existing savings goal',
      category: ToolCategory.write,
      riskLevel: RiskLevel.low,
      entityType: 'goal',
      // Moves money / changes a balance: a confirmation card first.
      requiresConfirmation: true,
      params: [
        ParamSchema(name: 'goal_id', type: ParamType.string, required: true, descriptionAr: 'معرف الهدف', descriptionEn: 'Goal ID'),
        ParamSchema(name: 'amount', type: ParamType.number, required: true, descriptionAr: 'المبلغ', descriptionEn: 'Amount', min: 0.01),
      ],
    ),
    ToolDefinition(
      name: 'delete_savings_goal',
      nameAr: 'حذف هدف ادخار',
      descriptionAr: 'حذف هدف ادخار نهائياً',
      descriptionEn: 'Permanently delete a savings goal',
      category: ToolCategory.write,
      riskLevel: RiskLevel.high,
      requiresConfirmation: true,
      entityType: 'goal',
      params: [
        ParamSchema(name: 'goal_id', type: ParamType.string, required: true, descriptionAr: 'معرف الهدف', descriptionEn: 'Goal ID'),
      ],
    ),

    // ═══════════════════════════════════════════════════════════════
    //  WRITE TOOLS — DEBTS
    // ═══════════════════════════════════════════════════════════════
    ToolDefinition(
      name: 'create_debt',
      nameAr: 'إنشاء دين',
      descriptionAr: 'إنشاء دين جديد (قرض أو دين على المستخدم)',
      descriptionEn: 'Create a new debt (payable or receivable)',
      category: ToolCategory.write,
      riskLevel: RiskLevel.medium,
      entityType: 'debt',
      routeTemplate: '/personal/debts',
      verificationQueries: ['get_debts'],
      params: [
        ParamSchema(name: 'person_name', type: ParamType.string, required: true, descriptionAr: 'اسم الدائن/المدين', descriptionEn: 'Person name'),
        ParamSchema(name: 'amount', type: ParamType.number, required: true, descriptionAr: 'المبلغ', descriptionEn: 'Amount', min: 0.01),
        ParamSchema(name: 'debt_type', type: ParamType.enum_, required: true, descriptionAr: 'نوع الدين', descriptionEn: 'Debt type', allowedValues: ['payable', 'receivable']),
        ParamSchema(name: 'currency', type: ParamType.string, required: false, descriptionAr: 'العملة (مثل SAR وYER_OLD وYER_NEW — القديم والجديد عملتان مختلفتان)', descriptionEn: 'Currency code (e.g. SAR, YER_OLD, YER_NEW)', defaultValue: 'SAR'),
        ParamSchema(name: 'due_date', type: ParamType.date, required: false, descriptionAr: 'تاريخ الاستحقاق', descriptionEn: 'Due date'),
        ParamSchema(name: 'notes', type: ParamType.string, required: false, descriptionAr: 'ملاحظات', descriptionEn: 'Notes'),
      ],
    ),
    ToolDefinition(
      name: 'update_debt',
      nameAr: 'تعديل دين',
      descriptionAr: 'تعديل دين موجود',
      descriptionEn: 'Update an existing debt',
      category: ToolCategory.write,
      riskLevel: RiskLevel.medium,
      entityType: 'debt',
      // Moves money / changes a balance: a confirmation card first.
      requiresConfirmation: true,
      params: [
        ParamSchema(name: 'debt_id', type: ParamType.string, required: true, descriptionAr: 'معرف الدين', descriptionEn: 'Debt ID'),
        ParamSchema(name: 'person_name', type: ParamType.string, required: false, descriptionAr: 'الاسم الجديد', descriptionEn: 'New name'),
        ParamSchema(name: 'amount', type: ParamType.number, required: false, descriptionAr: 'المبلغ الجديد', descriptionEn: 'New amount'),
        ParamSchema(name: 'due_date', type: ParamType.date, required: false, descriptionAr: 'تاريخ الاستحقاق الجديد', descriptionEn: 'New due date'),
        ParamSchema(name: 'notes', type: ParamType.string, required: false, descriptionAr: 'ملاحظات جديدة', descriptionEn: 'New notes'),
      ],
    ),
    ToolDefinition(
      name: 'pay_debt',
      nameAr: 'سداد دين',
      descriptionAr: 'سداد مبلغ من دين موجود',
      descriptionEn: 'Pay off part of an existing debt',
      category: ToolCategory.write,
      riskLevel: RiskLevel.medium,
      entityType: 'debt',
      // Moves money / changes a balance: a confirmation card first.
      requiresConfirmation: true,
      params: [
        ParamSchema(name: 'debt_id', type: ParamType.string, required: true, descriptionAr: 'معرف الدين', descriptionEn: 'Debt ID'),
        ParamSchema(name: 'amount', type: ParamType.number, required: true, descriptionAr: 'المبلغ المدفوع', descriptionEn: 'Payment amount', min: 0.01),
        ParamSchema(name: 'notes', type: ParamType.string, required: false, descriptionAr: 'ملاحظات', descriptionEn: 'Notes'),
      ],
    ),
    ToolDefinition(
      name: 'delete_debt',
      nameAr: 'حذف دين',
      descriptionAr: 'حذف دين نهائياً',
      descriptionEn: 'Permanently delete a debt',
      category: ToolCategory.write,
      riskLevel: RiskLevel.critical,
      requiresConfirmation: true,
      entityType: 'debt',
      params: [
        ParamSchema(name: 'debt_id', type: ParamType.string, required: true, descriptionAr: 'معرف الدين', descriptionEn: 'Debt ID'),
      ],
    ),

    // ═══════════════════════════════════════════════════════════════
    //  WRITE TOOLS — BUDGETS
    // ═══════════════════════════════════════════════════════════════
    ToolDefinition(
      name: 'create_budget',
      nameAr: 'إنشاء ميزانية',
      descriptionAr: 'إنشاء ميزانية جديدة باسم ومبلغ محددين (مثال: ميزانية "مشتريات" بمبلغ 5000)',
      descriptionEn: 'Create a new budget with a given NAME and AMOUNT (e.g. budget "groceries" with amount 5000). Both name and a positive amount are required.',
      category: ToolCategory.write,
      riskLevel: RiskLevel.low,
      entityType: 'budget',
      routeTemplate: '/personal/budget',
      verificationQueries: ['get_budgets'],
      params: [
        ParamSchema(name: 'name', type: ParamType.string, required: true, descriptionAr: 'اسم الميزانية', descriptionEn: 'Budget name'),
        ParamSchema(name: 'amount', type: ParamType.number, required: true, descriptionAr: 'مبلغ الميزانية', descriptionEn: 'Budget amount', min: 0.01),
        ParamSchema(name: 'category', type: ParamType.string, required: false, descriptionAr: 'الفئة', descriptionEn: 'Category'),
        ParamSchema(name: 'categories', type: ParamType.string, required: false, descriptionAr: 'الأصناف داخل نفس الميزانية كنص JSON: [{"name":"طيران","amount":300000}] — الباقي يبقى بدون تصنيف', descriptionEn: 'Categories inside the same budget as a JSON string: [{"name":"flights","amount":300000}]'),
        ParamSchema(name: 'currency', type: ParamType.string, required: false, descriptionAr: 'العملة', descriptionEn: 'Currency code (e.g. SAR, USD, YER_OLD, YER_NEW)', defaultValue: 'SAR'),
        ParamSchema(name: 'month', type: ParamType.number, required: false, descriptionAr: 'الشهر', descriptionEn: 'Month', min: 1, max: 12),
        ParamSchema(name: 'year', type: ParamType.number, required: false, descriptionAr: 'السنة', descriptionEn: 'Year'),
        ParamSchema(name: 'notes', type: ParamType.string, required: false, descriptionAr: 'ملاحظات', descriptionEn: 'Notes'),
      ],
    ),
    ToolDefinition(
      name: 'update_budget',
      nameAr: 'تعديل ميزانية',
      descriptionAr: 'تعديل ميزانية شهرية موجودة',
      descriptionEn: 'Update an existing monthly budget',
      category: ToolCategory.write,
      riskLevel: RiskLevel.low,
      entityType: 'budget',
      params: [
        ParamSchema(name: 'budget_id', type: ParamType.string, required: true, descriptionAr: 'معرف الميزانية', descriptionEn: 'Budget ID'),
        ParamSchema(name: 'amount', type: ParamType.number, required: false, descriptionAr: 'المبلغ الجديد', descriptionEn: 'New amount'),
        ParamSchema(name: 'category', type: ParamType.string, required: false, descriptionAr: 'الفئة الجديدة', descriptionEn: 'New category'),
      ],
    ),
    ToolDefinition(
      name: 'delete_budget',
      nameAr: 'حذف ميزانية',
      descriptionAr: 'حذف ميزانية نهائياً',
      descriptionEn: 'Permanently delete a budget',
      category: ToolCategory.write,
      riskLevel: RiskLevel.high,
      requiresConfirmation: true,
      entityType: 'budget',
      params: [
        ParamSchema(name: 'budget_id', type: ParamType.string, required: true, descriptionAr: 'معرف الميزانية', descriptionEn: 'Budget ID'),
      ],
    ),

    // ═══════════════════════════════════════════════════════════════
    //  WRITE TOOLS — RECURRING TRANSACTIONS
    // ═══════════════════════════════════════════════════════════════
    ToolDefinition(
      name: 'create_recurring',
      nameAr: 'إنشاء معاملة متكررة',
      descriptionAr: 'إنشاء معاملة مالية متكررة (اشتراك شهري، إيجار...)',
      descriptionEn: 'Create a recurring transaction (monthly subscription, rent...)',
      category: ToolCategory.write,
      riskLevel: RiskLevel.low,
      entityType: 'recurring',
      routeTemplate: '/personal/recurring',
      verificationQueries: ['get_recurring'],
      params: [
        ParamSchema(name: 'name', type: ParamType.string, required: true, descriptionAr: 'الاسم', descriptionEn: 'Name'),
        ParamSchema(name: 'amount', type: ParamType.number, required: true, descriptionAr: 'المبلغ', descriptionEn: 'Amount', min: 0.01),
        ParamSchema(name: 'tx_type', type: ParamType.enum_, required: true, descriptionAr: 'نوع المعاملة', descriptionEn: 'Transaction type', allowedValues: ['income', 'expense']),
        ParamSchema(name: 'frequency', type: ParamType.enum_, required: true, descriptionAr: 'التكرار', descriptionEn: 'Frequency', allowedValues: ['daily', 'weekly', 'monthly', 'yearly']),
        ParamSchema(name: 'category', type: ParamType.string, required: false, descriptionAr: 'التصنيف', descriptionEn: 'Category'),
        ParamSchema(name: 'notes', type: ParamType.string, required: false, descriptionAr: 'ملاحظات', descriptionEn: 'Notes'),
      ],
    ),
    ToolDefinition(
      name: 'update_recurring',
      nameAr: 'تعديل معاملة متكررة',
      descriptionAr: 'تعديل معاملة متكررة موجودة',
      descriptionEn: 'Update an existing recurring transaction',
      category: ToolCategory.write,
      riskLevel: RiskLevel.low,
      entityType: 'recurring',
      params: [
        ParamSchema(name: 'recurring_id', type: ParamType.string, required: true, descriptionAr: 'معرف المعاملة', descriptionEn: 'Recurring ID'),
        ParamSchema(name: 'name', type: ParamType.string, required: false, descriptionAr: 'الاسم الجديد', descriptionEn: 'New name'),
        ParamSchema(name: 'amount', type: ParamType.number, required: false, descriptionAr: 'المبلغ الجديد', descriptionEn: 'New amount'),
        ParamSchema(name: 'frequency', type: ParamType.enum_, required: false, descriptionAr: 'التكرار الجديد', descriptionEn: 'New frequency', allowedValues: ['daily', 'weekly', 'monthly', 'yearly']),
        ParamSchema(name: 'category', type: ParamType.string, required: false, descriptionAr: 'التصنيف الجديد', descriptionEn: 'New category'),
      ],
    ),
    ToolDefinition(
      name: 'delete_recurring',
      nameAr: 'حذف معاملة متكررة',
      descriptionAr: 'حذف معاملة متكررة نهائياً',
      descriptionEn: 'Permanently delete a recurring transaction',
      category: ToolCategory.write,
      riskLevel: RiskLevel.high,
      requiresConfirmation: true,
      entityType: 'recurring',
      params: [
        ParamSchema(name: 'recurring_id', type: ParamType.string, required: true, descriptionAr: 'معرف المعاملة', descriptionEn: 'Recurring ID'),
      ],
    ),
    ToolDefinition(
      name: 'execute_recurring_now',
      nameAr: 'تنفيذ متكررة الآن',
      descriptionAr: 'تنفيذ معاملة متكررة فوراً بنفس مبلغها وعملتها وحسابها وتصنيفها',
      descriptionEn: 'Execute a recurring transaction now: create a transaction from its stored amount/currency/account/category',
      category: ToolCategory.write,
      riskLevel: RiskLevel.medium,
      entityType: 'recurring',
      // Moves money / changes a balance: a confirmation card first.
      requiresConfirmation: true,
      params: [
        ParamSchema(name: 'recurring_id', type: ParamType.string, required: true, descriptionAr: 'معرف المعاملة المتكررة', descriptionEn: 'Recurring ID'),
        // «تنفيذ الآن» with a chosen bank (rules set to pick the account at
        // execution, or the user names another account).
        ParamSchema(name: 'bank_account_id', type: ParamType.string, required: false, descriptionAr: 'الحساب البنكي للتنفيذ (اختياري)', descriptionEn: 'Bank account to execute from/into (optional)'),
        ParamSchema(name: 'currency', type: ParamType.string, required: false, descriptionAr: 'عملة التنفيذ (اختياري)', descriptionEn: 'Execution currency (optional)'),
      ],
    ),
    ToolDefinition(
      name: 'skip_recurring',
      nameAr: 'تخطي مرة',
      descriptionAr: 'تخطي الموعد القادم لمعاملة متكررة مفعلة (ينقلها للموعد الذي بعده دون تنفيذ)',
      descriptionEn: 'Skip the next occurrence of an active recurring transaction (moves it to the following date, nothing executed)',
      category: ToolCategory.write,
      riskLevel: RiskLevel.low,
      entityType: 'recurring',
      params: [
        ParamSchema(name: 'recurring_id', type: ParamType.string, required: true, descriptionAr: 'معرف المعاملة المتكررة', descriptionEn: 'Recurring ID'),
      ],
    ),
    ToolDefinition(
      name: 'postpone_recurring',
      nameAr: 'تأجيل متكررة',
      descriptionAr: 'تأجيل الموعد القادم لمعاملة متكررة مفعلة إلى تاريخ لاحق',
      descriptionEn: 'Postpone the next occurrence of an active recurring transaction to a later date',
      category: ToolCategory.write,
      riskLevel: RiskLevel.low,
      entityType: 'recurring',
      params: [
        ParamSchema(name: 'recurring_id', type: ParamType.string, required: true, descriptionAr: 'معرف المعاملة المتكررة', descriptionEn: 'Recurring ID'),
        ParamSchema(name: 'days', type: ParamType.number, required: false, descriptionAr: 'عدد أيام التأجيل من اليوم (1 غداً، 3، 7...)', descriptionEn: 'Days from today (1 = tomorrow, 3, 7...)', min: 1, max: 366),
        ParamSchema(name: 'new_date', type: ParamType.date, required: false, descriptionAr: 'التاريخ الجديد (YYYY-MM-DD)', descriptionEn: 'New date (YYYY-MM-DD)'),
      ],
    ),
    ToolDefinition(
      name: 'activate_recurring',
      nameAr: 'تفعيل متكررة',
      descriptionAr: 'تفعيل معاملة متكررة معطلة',
      descriptionEn: 'Activate an inactive recurring transaction',
      category: ToolCategory.write,
      riskLevel: RiskLevel.low,
      entityType: 'recurring',
      params: [
        ParamSchema(name: 'recurring_id', type: ParamType.string, required: true, descriptionAr: 'معرف المعاملة المتكررة', descriptionEn: 'Recurring ID'),
      ],
    ),
    ToolDefinition(
      name: 'deactivate_recurring',
      nameAr: 'تعطيل متكررة',
      descriptionAr: 'تعطيل معاملة متكررة مفعلة',
      descriptionEn: 'Deactivate an active recurring transaction',
      category: ToolCategory.write,
      riskLevel: RiskLevel.low,
      entityType: 'recurring',
      params: [
        ParamSchema(name: 'recurring_id', type: ParamType.string, required: true, descriptionAr: 'معرف المعاملة المتكررة', descriptionEn: 'Recurring ID'),
      ],
    ),

    // ═══════════════════════════════════════════════════════════════
    //  CURRENCIES & EXCHANGE RATES
    // ═══════════════════════════════════════════════════════════════
    ToolDefinition(
      name: 'get_currencies',
      nameAr: 'العملات',
      descriptionAr: 'عرض العملات المفعلة والمميزة حسب الحسابات — YER و YER_NEW منفصلتان',
      descriptionEn: 'List enabled currencies (distinct from accounts) — YER and YER_NEW are separate',
      category: ToolCategory.read,
      entityType: 'currency',
      params: [],
    ),
    ToolDefinition(
      name: 'add_currency',
      nameAr: 'إضافة عملة',
      descriptionAr: 'تفعيل عملة جديدة (يضيفها للمجموعة وينشئ حساب كاش إن لزم)',
      descriptionEn: 'Enable a new currency (adds to enabled set and ensures cash account)',
      category: ToolCategory.write,
      riskLevel: RiskLevel.low,
      entityType: 'currency',
      params: [
        ParamSchema(name: 'currency_code', type: ParamType.string, required: true, descriptionAr: 'رمز العملة', descriptionEn: 'Currency code', pattern: r'^[A-Z][A-Z0-9_]{2,9}$'),
      ],
    ),
    ToolDefinition(
      name: 'delete_currency',
      nameAr: 'حذف عملة',
      descriptionAr: 'تعطيل عملة (يزيلها من المجموعة فقط — لا يحذف بيانات مالية)',
      descriptionEn: 'Disable a currency (removes from enabled set only — does not delete financial data)',
      category: ToolCategory.write,
      riskLevel: RiskLevel.critical,
      requiresConfirmation: true,
      entityType: 'currency',
      params: [
        ParamSchema(name: 'currency_code', type: ParamType.string, required: true, descriptionAr: 'رمز العملة', descriptionEn: 'Currency code', pattern: r'^[A-Z][A-Z0-9_]{2,9}$'),
      ],
    ),
    ToolDefinition(
      name: 'get_exchange_rate',
      nameAr: 'سعر الصرف',
      descriptionAr: 'قراءة سعر الصرف الحقيقي من المحرك الحالي — لا يخترع سعراً',
      descriptionEn: 'Get the real exchange rate from the current engine — never invents',
      category: ToolCategory.read,
      entityType: 'exchange_rate',
      params: [
        ParamSchema(name: 'from_currency', type: ParamType.string, required: true, descriptionAr: 'العملة المصدر', descriptionEn: 'Source currency'),
        ParamSchema(name: 'to_currency', type: ParamType.string, required: true, descriptionAr: 'العملة الهدف', descriptionEn: 'Target currency'),
      ],
    ),
    ToolDefinition(
      name: 'add_exchange_rate',
      nameAr: 'إضافة سعر صرف',
      descriptionAr: 'إضافة سعر صرف شخصي (from→to) — يرفض rate<=0 أو عملات غير صالحة',
      descriptionEn: 'Add a personal exchange rate (from→to) — rejects rate<=0 or invalid codes',
      category: ToolCategory.write,
      riskLevel: RiskLevel.low,
      entityType: 'exchange_rate',
      params: [
        ParamSchema(name: 'from_currency', type: ParamType.string, required: true, descriptionAr: 'العملة المصدر', descriptionEn: 'Source currency'),
        ParamSchema(name: 'to_currency', type: ParamType.string, required: true, descriptionAr: 'العملة الهدف', descriptionEn: 'Target currency'),
        ParamSchema(name: 'rate', type: ParamType.number, required: true, descriptionAr: 'سعر الصرف', descriptionEn: 'Exchange rate', min: 0.000001),
      ],
    ),
    ToolDefinition(
      name: 'update_exchange_rate',
      nameAr: 'تعديل سعر صرف',
      descriptionAr: 'تعديل سعر صرف شخصي موجود',
      descriptionEn: 'Update an existing personal exchange rate',
      category: ToolCategory.write,
      riskLevel: RiskLevel.low,
      entityType: 'exchange_rate',
      params: [
        ParamSchema(name: 'from_currency', type: ParamType.string, required: true, descriptionAr: 'العملة المصدر', descriptionEn: 'Source currency'),
        ParamSchema(name: 'to_currency', type: ParamType.string, required: true, descriptionAr: 'العملة الهدف', descriptionEn: 'Target currency'),
        ParamSchema(name: 'rate', type: ParamType.number, required: true, descriptionAr: 'السعر الجديد', descriptionEn: 'New rate', min: 0.000001),
      ],
    ),
    ToolDefinition(
      name: 'get_debt_payments',
      nameAr: 'مدفوعات الدين',
      descriptionAr: 'عرض مدفوعات دين محدد',
      descriptionEn: 'List payments for a specific debt',
      category: ToolCategory.read,
      entityType: 'debt',
      params: [
        ParamSchema(name: 'debt_id', type: ParamType.string, required: true, descriptionAr: 'معرف الدين', descriptionEn: 'Debt ID'),
      ],
    ),

    // ═══════════════════════════════════════════════════════════════
    //  WRITE TOOLS — TRANSACTIONS (DELETE)
    // ═══════════════════════════════════════════════════════════════
    ToolDefinition(
      name: 'delete_transaction',
      nameAr: 'حذف معاملة',
      descriptionAr: 'حذف معاملة مالية نهائياً',
      descriptionEn: 'Permanently delete a transaction',
      category: ToolCategory.write,
      riskLevel: RiskLevel.high,
      requiresConfirmation: true,
      entityType: 'transaction',
      params: [
        ParamSchema(name: 'transaction_id', type: ParamType.string, required: true, descriptionAr: 'معرف المعاملة', descriptionEn: 'Transaction ID'),
      ],
    ),
    // ═══════════════════════════════════════════════════════════════
    //  WRITE TOOLS — CATEGORIES / FINANCIAL TREE / MERCHANT LINKS
    //  (by name; the device resolves and lists choices when unclear)
    // ═══════════════════════════════════════════════════════════════
    ToolDefinition(
      name: 'add_category',
      nameAr: 'إضافة تصنيف',
      descriptionAr: 'إضافة تصنيف مصروفات (اسم عربي وإنجليزي)',
      descriptionEn: 'Add a spending category (Arabic + English name)',
      category: ToolCategory.write,
      entityType: 'category',
      params: [
        ParamSchema(name: 'name_ar', type: ParamType.string, required: true, descriptionAr: 'الاسم بالعربية', descriptionEn: 'Arabic name'),
        ParamSchema(name: 'name_en', type: ParamType.string, required: true, descriptionAr: 'الاسم بالإنجليزية', descriptionEn: 'English name'),
      ],
    ),
    ToolDefinition(
      name: 'update_category',
      nameAr: 'تعديل تصنيف',
      descriptionAr: 'تعديل اسم تصنيف',
      descriptionEn: 'Rename a spending category',
      category: ToolCategory.write,
      entityType: 'category',
      params: [
        ParamSchema(name: 'category_name', type: ParamType.string, required: true, descriptionAr: 'اسم التصنيف الحالي', descriptionEn: 'Current category name'),
        ParamSchema(name: 'new_name_ar', type: ParamType.string, required: false, descriptionAr: 'الاسم العربي الجديد', descriptionEn: 'New Arabic name'),
        ParamSchema(name: 'new_name_en', type: ParamType.string, required: false, descriptionAr: 'الاسم الإنجليزي الجديد', descriptionEn: 'New English name'),
      ],
    ),
    ToolDefinition(
      name: 'delete_category',
      nameAr: 'حذف تصنيف',
      descriptionAr: 'حذف تصنيف غير مستخدم في معاملات',
      descriptionEn: 'Delete a category not used by transactions',
      category: ToolCategory.write,
      riskLevel: RiskLevel.high,
      requiresConfirmation: true,
      entityType: 'category',
      params: [
        ParamSchema(name: 'category_name', type: ParamType.string, required: true, descriptionAr: 'اسم التصنيف', descriptionEn: 'Category name'),
      ],
    ),
    ToolDefinition(
      name: 'create_financial_tree',
      nameAr: 'إنشاء شجرة مالية',
      descriptionAr: 'إنشاء شجرة مالية جديدة',
      descriptionEn: 'Create a financial tree',
      category: ToolCategory.write,
      entityType: 'financial_tree',
      params: [
        ParamSchema(name: 'name', type: ParamType.string, required: true, descriptionAr: 'اسم الشجرة', descriptionEn: 'Tree name'),
        ParamSchema(name: 'client_name', type: ParamType.string, required: false, descriptionAr: 'اسم العميل', descriptionEn: 'Client name'),
        ParamSchema(name: 'base_amount', type: ParamType.number, required: false, descriptionAr: 'المبلغ الأساسي', descriptionEn: 'Base amount', min: 0),
        ParamSchema(name: 'currency', type: ParamType.string, required: false, descriptionAr: 'العملة', descriptionEn: 'Currency'),
        ParamSchema(name: 'notes', type: ParamType.string, required: false, descriptionAr: 'ملاحظات', descriptionEn: 'Notes'),
      ],
    ),
    ToolDefinition(
      name: 'update_financial_tree',
      nameAr: 'تعديل شجرة مالية',
      descriptionAr: 'تعديل بيانات شجرة مالية',
      descriptionEn: 'Edit a financial tree',
      category: ToolCategory.write,
      entityType: 'financial_tree',
      params: [
        ParamSchema(name: 'tree_name', type: ParamType.string, required: false, descriptionAr: 'اسم الشجرة', descriptionEn: 'Tree name'),
        ParamSchema(name: 'new_name', type: ParamType.string, required: false, descriptionAr: 'الاسم الجديد', descriptionEn: 'New name'),
        ParamSchema(name: 'client_name', type: ParamType.string, required: false, descriptionAr: 'اسم العميل', descriptionEn: 'Client name'),
        ParamSchema(name: 'base_amount', type: ParamType.number, required: false, descriptionAr: 'المبلغ الأساسي', descriptionEn: 'Base amount', min: 0),
        ParamSchema(name: 'currency', type: ParamType.string, required: false, descriptionAr: 'العملة', descriptionEn: 'Currency'),
        ParamSchema(name: 'notes', type: ParamType.string, required: false, descriptionAr: 'ملاحظات', descriptionEn: 'Notes'),
      ],
    ),
    ToolDefinition(
      name: 'delete_financial_tree',
      nameAr: 'حذف شجرة مالية',
      descriptionAr: 'حذف شجرة مالية بكل بنودها نهائياً',
      descriptionEn: 'Permanently delete a financial tree with all its items',
      category: ToolCategory.write,
      riskLevel: RiskLevel.critical,
      requiresConfirmation: true,
      entityType: 'financial_tree',
      params: [
        ParamSchema(name: 'tree_name', type: ParamType.string, required: true, descriptionAr: 'اسم الشجرة', descriptionEn: 'Tree name'),
      ],
    ),
    ToolDefinition(
      name: 'add_tree_node',
      nameAr: 'إضافة بند للشجرة',
      descriptionAr: 'إضافة بند إلى شجرة مالية',
      descriptionEn: 'Add an item to a financial tree',
      category: ToolCategory.write,
      entityType: 'financial_tree',
      params: [
        ParamSchema(name: 'name', type: ParamType.string, required: true, descriptionAr: 'اسم البند', descriptionEn: 'Item name'),
        ParamSchema(name: 'node_type', type: ParamType.enum_, required: false, descriptionAr: 'نوع البند', descriptionEn: 'Item type', allowedValues: ['income', 'expense', 'asset', 'investment', 'debt', 'liability', 'transfer', 'saving', 'payment', 'receivable', 'custom']),
        ParamSchema(name: 'amount', type: ParamType.number, required: false, descriptionAr: 'المبلغ', descriptionEn: 'Amount', min: 0),
        ParamSchema(name: 'tree_name', type: ParamType.string, required: false, descriptionAr: 'اسم الشجرة', descriptionEn: 'Tree name'),
        ParamSchema(name: 'parent_name', type: ParamType.string, required: false, descriptionAr: 'البند الأب (افتراضياً الجذر)', descriptionEn: 'Parent item (default root)'),
        ParamSchema(name: 'currency', type: ParamType.string, required: false, descriptionAr: 'العملة', descriptionEn: 'Currency'),
        ParamSchema(name: 'notes', type: ParamType.string, required: false, descriptionAr: 'ملاحظات', descriptionEn: 'Notes'),
      ],
    ),
    ToolDefinition(
      name: 'update_tree_node',
      nameAr: 'تعديل بند في الشجرة',
      descriptionAr: 'تعديل أو نقل بند في شجرة مالية',
      descriptionEn: 'Edit or move a financial tree item',
      category: ToolCategory.write,
      entityType: 'financial_tree',
      params: [
        ParamSchema(name: 'node_name', type: ParamType.string, required: true, descriptionAr: 'اسم البند', descriptionEn: 'Item name'),
        ParamSchema(name: 'tree_name', type: ParamType.string, required: false, descriptionAr: 'اسم الشجرة', descriptionEn: 'Tree name'),
        ParamSchema(name: 'new_name', type: ParamType.string, required: false, descriptionAr: 'الاسم الجديد', descriptionEn: 'New name'),
        ParamSchema(name: 'node_type', type: ParamType.enum_, required: false, descriptionAr: 'نوع البند', descriptionEn: 'Item type', allowedValues: ['income', 'expense', 'asset', 'investment', 'debt', 'liability', 'transfer', 'saving', 'payment', 'receivable', 'custom']),
        ParamSchema(name: 'amount', type: ParamType.number, required: false, descriptionAr: 'المبلغ', descriptionEn: 'Amount', min: 0),
        ParamSchema(name: 'currency', type: ParamType.string, required: false, descriptionAr: 'العملة', descriptionEn: 'Currency'),
        ParamSchema(name: 'notes', type: ParamType.string, required: false, descriptionAr: 'ملاحظات', descriptionEn: 'Notes'),
        ParamSchema(name: 'new_parent_name', type: ParamType.string, required: false, descriptionAr: 'نقله تحت بند', descriptionEn: 'Move under item'),
      ],
    ),
    ToolDefinition(
      name: 'delete_tree_node',
      nameAr: 'حذف بند من الشجرة',
      descriptionAr: 'حذف بند من شجرة مالية مع فروعه',
      descriptionEn: 'Delete a financial tree item with its branch',
      category: ToolCategory.write,
      riskLevel: RiskLevel.high,
      requiresConfirmation: true,
      entityType: 'financial_tree',
      params: [
        ParamSchema(name: 'node_name', type: ParamType.string, required: true, descriptionAr: 'اسم البند', descriptionEn: 'Item name'),
        ParamSchema(name: 'tree_name', type: ParamType.string, required: false, descriptionAr: 'اسم الشجرة', descriptionEn: 'Tree name'),
      ],
    ),
    ToolDefinition(
      name: 'accept_merchant_invite',
      nameAr: 'قبول ربط تاجر',
      descriptionAr: 'قبول طلب ربط من تاجر',
      descriptionEn: 'Accept a merchant link request',
      category: ToolCategory.write,
      riskLevel: RiskLevel.medium,
      requiresConfirmation: true,
      entityType: 'merchant',
      params: [
        ParamSchema(name: 'merchant_name', type: ParamType.string, required: false, descriptionAr: 'اسم التاجر', descriptionEn: 'Merchant name'),
      ],
    ),
    ToolDefinition(
      name: 'reject_merchant_invite',
      nameAr: 'رفض ربط تاجر',
      descriptionAr: 'رفض طلب ربط من تاجر',
      descriptionEn: 'Reject a merchant link request',
      category: ToolCategory.write,
      entityType: 'merchant',
      params: [
        ParamSchema(name: 'merchant_name', type: ParamType.string, required: false, descriptionAr: 'اسم التاجر', descriptionEn: 'Merchant name'),
      ],
    ),
    ToolDefinition(
      name: 'unlink_merchant',
      nameAr: 'فك ربط تاجر',
      descriptionAr: 'فك الربط مع تاجر (الديون تبقى)',
      descriptionEn: 'Unlink a merchant (debts stay)',
      category: ToolCategory.write,
      riskLevel: RiskLevel.critical,
      requiresConfirmation: true,
      entityType: 'merchant',
      params: [
        ParamSchema(name: 'merchant_name', type: ParamType.string, required: true, descriptionAr: 'اسم التاجر', descriptionEn: 'Merchant name'),
      ],
    ),

    // ═══════════════════════════════════════════════════════════════
    //  NAVIGATION TOOLS
    // ═══════════════════════════════════════════════════════════════
    ToolDefinition(
      name: 'open_screen',
      nameAr: 'فتح شاشة',
      descriptionAr: 'التنقل إلى شاشة محددة في التطبيق',
      descriptionEn: 'Navigate to a specific screen in the app',
      category: ToolCategory.navigate,
      params: [
        ParamSchema(name: 'screen', type: ParamType.string, required: true, descriptionAr: 'اسم الشاشة', descriptionEn: 'Screen name', allowedValues: [
          // NOTE: analytics is NOT a screen — financial questions are answered
          // from live data via get_financial_analytics, never via navigation.
          'personal', 'banks', 'transactions', 'savings', 'debts', 'budget', 'recurring', 'reports', 'transfer', 'settings', 'categories',
        ]),
      ],
    ),
    ToolDefinition(
      name: 'open_entity',
      nameAr: 'فتح عنصر',
      descriptionAr: 'فتح عنصر محدد (حساب، هدف، دين...)',
      descriptionEn: 'Open a specific entity (account, goal, debt...)',
      category: ToolCategory.navigate,
      params: [
        ParamSchema(name: 'entity_type', type: ParamType.enum_, required: true, descriptionAr: 'نوع العنصر', descriptionEn: 'Entity type', allowedValues: ['bank', 'goal', 'debt', 'budget', 'recurring', 'transaction']),
        ParamSchema(name: 'entity_id', type: ParamType.string, required: true, descriptionAr: 'معرف العنصر', descriptionEn: 'Entity ID'),
      ],
    ),
  ];

  static ToolDefinition? findByName(String name) {
    try {
      return tools.firstWhere((t) => t.name == name);
    } catch (_) {
      return null;
    }
  }

  static List<ToolDefinition> findByCategory(ToolCategory category) {
    return tools.where((t) => t.toolCategory == category).toList();
  }

  static List<ToolDefinition> get readTools => findByCategory(ToolCategory.read);
  static List<ToolDefinition> get writeTools => findByCategory(ToolCategory.write);
  static List<ToolDefinition> get navigationTools => findByCategory(ToolCategory.navigate);

  static List<Map<String, dynamic>> toOpenAiTools() {
    return tools.map((t) => t.toOpenAiTool()).toList();
  }
}
