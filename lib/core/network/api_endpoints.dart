class ApiEndpoints {
  static const String basePath = '';

  // Health
  static const String health = '$basePath/health';
  static const String healthReady = '$basePath/health/ready';
  static const String healthLive = '$basePath/health/live';

  // Banners (public home promo)
  static const String banners = '$basePath/banners';
  static String bannerClick(String id) => '$basePath/banners/$id/click';
  static String bannerView(String id) => '$basePath/banners/$id/view';
  static String bannerWatch(String id) => '$basePath/banners/$id/watch';
  static String adminBanners = '$basePath/admin/banners';

  // Auth
  static const String refresh = '$basePath/auth/refresh';
  static const String logout = '$basePath/auth/logout';
  static const String me = '$basePath/auth/me';

  // Customers
  static const String customers = '$basePath/customers';
  static String customer(String id) => '$basePath/customers/$id';

  // Suppliers
  static const String suppliers = '$basePath/suppliers';
  static String supplier(String id) => '$basePath/suppliers/$id';

  // Categories
  static const String categories = '$basePath/categories';
  static String category(String id) => '$basePath/categories/$id';

  // Products
  static const String products = '$basePath/products';
  static String product(String id) => '$basePath/products/$id';

  // Inventory
  static const String inventoryMovements = '$basePath/inventory/movements';
  static String inventoryMovementsProduct(String id) => '$basePath/inventory/movements/product/$id';

  // Invoices
  static const String invoices = '$basePath/invoices';
  static String invoice(String id) => '$basePath/invoices/$id';
  static String invoiceStatus(String id) => '$basePath/invoices/$id/status';
  static String invoicePayments(String id) => '$basePath/invoices/$id/payments';

  // Sales
  static const String salesOrders = '$basePath/sales/orders';
  static String salesOrder(String id) => '$basePath/sales/orders/$id';
  static String salesOrderStatus(String id) => '$basePath/sales/orders/$id/status';
  static const String salesReturns = '$basePath/sales/returns';
  static const String salesQuotes = '$basePath/sales/quotes';
  static const String salesDeliveries = '$basePath/sales/deliveries';

  // Purchases
  static const String purchaseOrders = '$basePath/purchases/orders';
  static String purchaseOrder(String id) => '$basePath/purchases/orders/$id';
  static String purchaseOrderStatus(String id) => '$basePath/purchases/orders/$id/status';
  static const String purchaseReceipts = '$basePath/purchases/receipts';
  static const String purchaseBills = '$basePath/purchases/bills';
  static String purchaseBillPay(String id) => '$basePath/purchases/bills/$id/pay';

  // Accounting
  static const String accountingInit = '$basePath/accounting/init';
  static const String accounts = '$basePath/accounting/accounts';
  static const String journal = '$basePath/accounting/journal';
  static String journalPost(String id) => '$basePath/accounting/journal/$id/post';
  static const String trialBalance = '$basePath/accounting/trial-balance';
  static const String profitLoss = '$basePath/accounting/profit-loss';
  static const String balanceSheet = '$basePath/accounting/balance-sheet';

  // HR
  static const String departments = '$basePath/hr/departments';
  static const String positions = '$basePath/hr/positions';
  static const String employees = '$basePath/hr/employees';
  static String employee(String id) => '$basePath/hr/employees/$id';
  static const String attendance = '$basePath/hr/attendance';
  static const String leaves = '$basePath/hr/leaves';
  static String leaveAction(String id) => '$basePath/hr/leaves/$id/action';
  static const String payroll = '$basePath/hr/payroll';
  static String payrollProcess(String id) => '$basePath/hr/payroll/$id/process';

  // Reports
  static const String kpi = '$basePath/reports/kpi';
  static const String reportsSales = '$basePath/reports/sales';
  static const String reportsInventory = '$basePath/reports/inventory';

  // AI
  static const String aiInsights = '$basePath/ai/insights';
  static String aiForecast(String metric) => '$basePath/ai/forecast/$metric';
  static const String aiQuery = '$basePath/ai/query';
  static const String aiQueryAudio = '$basePath/ai/query-audio';
  static const String aiQueryAttachment = '$basePath/ai/query-attachment';
  static const String aiSpeak = '$basePath/ai/speak';

  // Banking
  static const String bankingAccounts = '$basePath/banking/accounts';
  static String bankingTransactions(String id) => '$basePath/banking/accounts/$id/transactions';
  static const String bankingTransfer = '$basePath/banking/transfer';
  static String bankingDeposit(String id) => '$basePath/banking/accounts/$id/deposit';
  static String bankingWithdraw(String id) => '$basePath/banking/accounts/$id/withdraw';
  static String bankingStatement(String id) => '$basePath/banking/accounts/$id/statement';

  // Sync
  static const String syncPush = '$basePath/sync/push';
  static const String syncPull = '$basePath/sync/pull';
  static const String syncStatus = '$basePath/sync/status';
  static const String syncHealth = '$basePath/sync/health';
  static const String syncConflicts = '$basePath/sync/conflicts';
  static const String syncLogs = '$basePath/sync/logs';

  // Notifications
  static const String notifications = '$basePath/notifications';
  static const String notificationsUnreadCount = '$basePath/notifications/unread-count';
  static const String notificationsReadAll = '$basePath/notifications/read-all';
  static const String notificationsTest = '$basePath/notifications/test';
  static String notificationRead(String id) => '$basePath/notifications/$id/read';

  // Push device registration
  static const String pushDevices = '$basePath/push/devices';
  static String pushDevice(String token) => '$basePath/push/devices/$token';

  // Notification Preferences
  static const String notificationPreferences = '$basePath/notification-preferences';

  // Reminders
  static const String reminders = '$basePath/reminders';
  static String reminder(String id) => '$basePath/reminders/$id';

  // Stripe Payments
  static const String stripePlans = '$basePath/payments/stripe/plans';
  static String stripePlan(String id) => '$basePath/payments/stripe/plans/$id';
  static const String stripePaymentIntent = '$basePath/payments/stripe/create-payment-intent';
  static const String stripeSettings = '$basePath/payments/stripe/settings';
  static const String stripeTestConnection = '$basePath/payments/stripe/test-connection';
  static const String stripePayments = '$basePath/payments/stripe/payments';
  static const String stripeSubscriptions = '$basePath/payments/stripe/subscriptions';
  // Auto-renew (independent layer — one-time endpoints above untouched).
  static const String stripeSetupIntent = '$basePath/payments/stripe/setup-intent';
  static const String stripeAutoRenewEnable = '$basePath/payments/stripe/auto-renew/enable';
  static const String stripeAutoRenewActivate = '$basePath/payments/stripe/auto-renew/activate';
  static const String stripeAutoRenewDisable = '$basePath/payments/stripe/auto-renew/disable';
  static const String stripeAutoRenewStatus = '$basePath/payments/stripe/auto-renew/status';

  // Personal Finance
  static const String personalFinanceStats = '$basePath/personal/finance/stats';
  static const String personalFinanceAccounts = '$basePath/personal/finance/accounts';
  static String personalFinanceAccount(String id) => '$basePath/personal/finance/accounts/$id';
  static const String personalFinanceTransactions = '$basePath/personal/finance/transactions';
  static String personalFinanceTransaction(String id) => '$basePath/personal/finance/transactions/$id';
  static const String personalFinanceGoals = '$basePath/personal/finance/goals';
  static String personalFinanceGoal(String id) => '$basePath/personal/finance/goals/$id';
  static String personalFinanceGoalContribute(String id) => '$basePath/personal/finance/goals/$id/contribute';
  static const String personalFinanceDebts = '$basePath/personal/finance/debts';
  static String personalFinanceDebt(String id) => '$basePath/personal/finance/debts/$id';
  static String personalFinanceDebtPayments(String id) => '$basePath/personal/finance/debts/$id/payments';
  static const String personalFinanceBudgets = '$basePath/personal/finance/budgets';
  static String personalFinanceBudget(String id) => '$basePath/personal/finance/budgets/$id';
  static String personalFinanceBudgetAggregation(String id) => '$basePath/personal/finance/budgets/$id/aggregation';
  static const String personalFinanceRecurring = '$basePath/personal/finance/recurring';
  static String personalFinanceRecurringItem(String id) => '$basePath/personal/finance/recurring/$id';
  static const String personalFinanceCategories = '$basePath/personal/finance/categories';
  static const String personalFinanceReset = '$basePath/personal/finance/reset';
  static const String personalFinanceBulkRestore = '$basePath/personal/finance/restore';
  static const String userBackups = '$basePath/backups';
  static const String userBackupKey = '$basePath/backups/key';
  static String userBackup(String id) => '$basePath/backups/$id';
  static String userBackupDownload(String id) => '$basePath/backups/$id/download';
}
