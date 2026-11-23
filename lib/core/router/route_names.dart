class RouteNames {
  RouteNames._();

  static const String splash = '/splash';
  static const String login = '/login';
  static const String reentry = '/reentry';
  static const String register = '/register';
  static const String verifyEmail = '/verify-email';
  static const String forgotPassword = '/forgot-password';
  static const String changePassword = '/change-password';
  static const String chooseUsage = '/choose-usage';
  static const String maintenance = '/maintenance';
  static const String onboarding = '/onboarding';
  static const String mfaSetup = '/mfa/setup';
  static const String mfaVerify = '/mfa/verify';

  // ── Dashboard ──
  static const String dashboard = '/dashboard';
  static const String personalDashboard = '/personal';
  static const String crmDashboard = '/crm-dashboard';
  static const String projectsDashboard = '/projects-dashboard';

  // ── Subscription ──
static const String subscription = '/subscription';                                            
  static const String subscriptionPay = '/subscription/pay';                                     
  static const String subscriptionPending = '/subscription/pending';
  static const String subscriptionInvoice = '/subscription/invoice';
  static const String subscriptionUpdateCard = '/subscription/update-card';
  static const String subscriptionRejected = '/subscription/rejected';
  static const String phoneEntry = '/subscription/phone-entry';

  // ── Personal Finance ──
  static const String personalTransactions = '/personal/transactions';
  static const String personalSavings = '/personal/savings';
  static const String personalMerchantAccounts = '/personal/merchant-accounts';
  static const String personalMerchantPartner = '/personal/merchant-partner';
  static const String personalAnalytics = '/personal/analytics';
  static const String personalReportsCenter = '/personal/reports-center';
  static const String personalReports = '/personal/reports';
  static const String personalBanks = '/personal/banks';
  static const String personalDebts = '/personal/debts';
  static const String personalAi = '/personal/ai';
  static const String personalTransfer = '/personal/transfer';
  static const String personalAccountTree = '/personal/account-tree';
  static const String financialTree = '/personal/financial-tree';
  static const String personalExecutive = '/personal/executive';
  static const String personalBankStatement = '/personal/bank-statement';
  static const String personalAccountDetail = '/personal/account-detail/:id';
  static const String personalBankDetail = '/personal/bank-detail/:bankName';
  static const String personalSavingsDetail = '/personal/savings-detail/:goalId';
  static const String personalAllBanksReport = '/personal/all-banks-report';
  static const String personalFinanceOverview = '/personal/finance-overview';
  static const String personalBudget = '/personal/budget';
  static const String personalBudgetAdd = '/personal/budget/add';
  static const String personalBudgetEdit = '/personal/budget/edit';
  static const String personalBudgetDetail = '/personal/budget/detail';
  static const String personalRecurring = '/personal/recurring';
  static const String personalRecurringDetail = '/personal/recurring/detail';
  static const String personalRecurringAdd = '/personal/recurring/add';
  static const String personalRecurringEdit = '/personal/recurring/edit';
  static const String personalCategories = '/personal/categories';
  static const String personalCategoryAdd = '/personal/categories/add';
  static const String personalCategoryEdit = '/personal/categories/edit';
  static const String personalBackup = '/personal/backup';
  static const String acceptInvitation = '/accept-invitation/:token';

  // ── Core Business ──
  static const String customers = '/customers';
  static const String customersAdd = '/customers/add';
  static const String customersEdit = '/customers/edit';
  static const String customersDetail = '/customers/:id';

  static const String suppliers = '/suppliers';
  static const String suppliersAdd = '/suppliers/add';
  static const String suppliersEdit = '/suppliers/edit';
  static const String suppliersDetail = '/suppliers/:id';

  static const String products = '/products';
  static const String productsAdd = '/products/add';
  static const String productsEdit = '/products/edit';
  static const String productsView = '/products/view';

  static const String inventory = '/inventory';
  static const String inventoryMovements = '/inventory/:id/movements';
  static const String inventoryCount = '/inventory/count';

  static const String sales = '/sales';
  static const String businessTransactions = '/business/transactions';
  static const String businessIncomeExpense = '/business/income-expense';
  static const String businessTransactionDetails =
      '/business/transactions/details';
  static const String salesAdd = '/sales/add';
  static const String salesEdit = '/sales/edit';
  static const String salesView = '/sales/view';

  static const String purchases = '/purchases';
  static const String purchasesAdd = '/purchases/add';
  static const String purchasesEdit = '/purchases/edit';
  static const String purchasesView = '/purchases/view';

  // ── Returns (المرتجعات) ──
  static const String returns = '/returns';
  static const String returnsAdd = '/returns/add';
  static const String returnsView = '/returns/view';
  static const String returnsPickInvoice = '/returns/pick-invoice';

  // ── Invoices center (الفواتير) ──
  static const String invoices = '/invoices';
  static const String invoicesView = '/invoices/view';
  static const String invoicesDesign = '/invoices/design';
  static const String invoicesDesignEdit = '/invoices/design/edit';

  // ── Inventory ──
  static const String inventoryProduct = '/inventory/product';
  static const String inventoryProductEdit = '/inventory/product/edit';
  static const String inventoryProductMovements = '/inventory/product/movements';
  static const String inventorySettings = '/inventory/settings';
  static const String inventoryCategories = '/inventory/categories';
  static const String inventoryCategoryDetail = '/inventory/category';
  static const String inventoryFalcon = '/inventory/falcon';

  // ── Payments & Expenses ──
  static const String payments = '/payments';
  static const String paymentsAdd = '/payments/add';
  static const String paymentsView = '/payments/view';

  static const String expenses = '/expenses';
  static const String expensesAdd = '/expenses/add';

  static const String debts = '/debts';
  static const String debtsAdd = '/debts/add';
  static const String debtsView = '/debts/view';

  // ── Accounting ──
  static const String accounts = '/accounts';
  static const String accountsAdd = '/accounts/add';
  static const String accountsEdit = '/accounts/edit/:id';
  static const String journal = '/journal';
  static const String journalAdd = '/journal/add';
  static const String ledger = '/ledger';
  static const String trialBalance = '/trial-balance';
  static const String profitLoss = '/profit-loss';
  static const String balanceSheet = '/balance-sheet';
  static const String cashFlow = '/cashflow';
  static const String fiscalYears = '/fiscal-years';

  // ── Banking ──
  static const String banks = '/banks';
  static const String banksAdd = '/banks/add';
  static const String banksView = '/banks/view';
  static const String banksTransfer = '/banks/transfer';
  static const String banksStatement = '/banks/statement';

  static const String cheques = '/cheques';
  static const String chequesNew = '/cheques/new';

  // ── HR ──
  static const String employees = '/employees';
  static const String employeesAdd = '/employees/add';
  static const String employeesEdit = '/employees/edit';
  static const String attendance = '/attendance';
  static const String leaves = '/leaves';
  static const String payroll = '/payroll';
  static const String payrollAdd = '/payroll/add';
  static const String contracts = '/contracts';
  static const String contractsAdd = '/contracts/add';

  // ── Fixed Assets ──
  static const String fixedAssets = '/fixed-assets';
  static const String fixedAssetsAdd = '/fixed-assets/add';
  static const String fixedAssetsView = '/fixed-assets/view';

  // ── Reports ──
  static const String reports = '/reports';
  static const String salesReport = '/sales-report';
  static const String purchaseReport = '/purchase-report';
  static const String cashflowReport = '/cashflow-report';
  static const String debtAging = '/debt-aging';
  static const String comparativeReport = '/comparative-report';
  static const String customReport = '/custom-report';
  static const String statement = '/statement';

  // ── HR Reports ──
  static const String hrReports = '/hr-reports';
  static const String hrPayrollSummary = '/hr-reports/payroll-summary';
  static const String hrEmployeeDistribution = '/hr-reports/employee-distribution';
  static const String hrExpiringContracts = '/hr-reports/expiring-contracts';

  // ── System ──
  static const String settings = '/settings';
  static const String settingsCompany = '/settings/company';
  static const String settingsTaxes = '/settings/taxes';
  static const String settingsCurrencies = '/settings/currencies';
  static const String users = '/users';
  static const String usersAdd = '/users/add';
  static const String invitations = '/invitations';
  static const String invitationsAdd = '/invitations/add';
  static const String notifications = '/notifications';
  static const String reminders = '/reminders';
  static const String profile = '/profile';
  static const String businessProfile = '/business/profile';

  /// Which profile to open for the current usage mode ('personal' vs
  /// business/both). Personal and Business profiles are fully separate.
  static String profileForMode(String? mode) =>
      mode == 'personal' ? profile : businessProfile;
  static const String sessions = '/sessions';
  static const String customization = '/settings/customization';
  static const String import = '/import';

  // ── AI ──
  static const String ai = '/ai';
  static const String aiSuggestions = '/ai-suggestions';

  // ── Suggestions ──
  static const String suggestions = '/suggestions';
  static const String adminSuggestions = '/admin/suggestions';

  // ── POS ──
  static const String pos = '/pos';

  // ── Recurring Invoices ──
  static const String recurringInvoices = '/recurring-invoices';

  // ── Data Import ──
  static const String smartImport = '/data-import/smart-import';

  // ── Projects ──
  static const String projectsAdd = '/projects/add';
  static const String projectsDetail = '/projects/:id';
  static const String projectsEdit = '/projects/edit';

  // ── Email ──
  static const String emailSettings = '/email/settings';
  static const String emailLogs = '/settings/email-logs';
  static const String emailCompose = '/email/compose';

  // ── Design Studio ──
  static const String designStudio = '/design-studio';

  // ── Reports center (قسم التقارير) — `reports` already defined above ──
  static const String reportsView = '/reports/view';

  // ── Reconciliation (قسم المطابقة) ──
  static const String reconciliation = '/reconciliation';
  static const String reconciliationBank = '/reconciliation/bank';
  static const String reconciliationBankSelect =
      '/reconciliation/bank/select';
  static const String reconciliationBankRun = '/reconciliation/bank/run';
  static const String reconciliationBankResult =
      '/reconciliation/bank/result';
  static const String reconciliationInventoryPick =
      '/reconciliation/inventory/pick';
  static const String reconciliationInventoryResult =
      '/reconciliation/inventory/result';
  static const String reconciliationInventory = '/reconciliation/inventory';
  static const String reconciliationArchive = '/reconciliation/archive';

  static const String businessDashboard = dashboard; // alias
}

/// Effective UI section, with employee workspace routes always in Business.
bool isPersonalSectionRoute(String route, String? preferredUsageMode) {
  final forcedBusiness = route.startsWith('/employee-profile') ||
      route.startsWith('/job-requests');
  final routeMode = route.routeMode;
  return !forcedBusiness &&
      (routeMode == 'personal' ||
          (routeMode == null && preferredUsageMode == 'personal'));
}

/// Route → section mode for platform-controls gating (personal | business).
extension RouteModeX on String {
  String? get routeMode {
    if (startsWith('/personal') ||
        startsWith('/personal/') ||
        startsWith('/settings') ||
        startsWith('/profile')) {
      return 'personal';
    }
    if (startsWith('/dashboard') ||
        startsWith('/business') ||
        startsWith('/customers') ||
        startsWith('/suppliers') ||
        startsWith('/products') ||
        startsWith('/inventory') ||
        startsWith('/sales') ||
        startsWith('/purchases') ||
        startsWith('/returns') ||
        startsWith('/invoices') ||
        startsWith('/finance') ||
        startsWith('/payments') ||
        startsWith('/expenses') ||
        startsWith('/cheques') ||
        startsWith('/debts') ||
        startsWith('/banks') ||
        startsWith('/accounts') ||
        startsWith('/journal') ||
        startsWith('/trial-balance') ||
        startsWith('/profit-loss') ||
        startsWith('/balance-sheet') ||
        startsWith('/reports') ||
        startsWith('/employees') ||
        startsWith('/payroll') ||
        startsWith('/pos') ||
        startsWith('/projects') ||
        startsWith('/contracts') ||
        startsWith('/users') ||
        startsWith('/reconciliation') ||
        startsWith('/reports')) {
      return 'business';
    }
    return null;
  }
}
