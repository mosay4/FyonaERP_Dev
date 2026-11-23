class Tables {
  static const String organizations = '''
    CREATE TABLE IF NOT EXISTS organizations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      legal_name TEXT,
      cr_number TEXT,
      tax_number TEXT,
      address TEXT,
      phone TEXT,
      email TEXT,
      logo TEXT,
      business_type TEXT,
      onboarding_completed INTEGER DEFAULT 0,
      currency TEXT DEFAULT 'SAR',
      locale TEXT DEFAULT 'ar_SA',
      is_active INTEGER DEFAULT 1,
      subscription_plan TEXT,
      subscription_status TEXT DEFAULT 'trial',
      subscription_start_date TEXT,
      subscription_end_date TEXT,
      trial_start_date TEXT,
      trial_end_date TEXT,
      created_at TEXT,
      updated_at TEXT
    )
  ''';

  static const String users = '''
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT NOT NULL UNIQUE,
      email TEXT UNIQUE,
      password_hash TEXT,
      full_name TEXT,
      phone TEXT,
      role TEXT NOT NULL DEFAULT 'employee',
      is_active INTEGER DEFAULT 1,
      status TEXT DEFAULT 'active',
      trial_start_date TEXT,
      trial_end_date TEXT,
      subscription_plan TEXT,
      subscription_start_date TEXT,
      subscription_end_date TEXT,
      mfa_enabled INTEGER DEFAULT 0,
      mfa_secret TEXT,
      mfa_backup_codes TEXT,
      is_platform_admin INTEGER DEFAULT 0,
      last_login TEXT,
      last_ip TEXT,
      password_changed_at TEXT,
      preferred_usage_mode TEXT,
      personal_trial_activated INTEGER DEFAULT 0,
      business_trial_activated INTEGER DEFAULT 0,
      organization_id INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      created_at TEXT,
      updated_at TEXT
    )
  ''';

  static const String userSessions = '''
    CREATE TABLE IF NOT EXISTS user_sessions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      token TEXT NOT NULL,
      refresh_token TEXT,
      ip_address TEXT,
      device_info TEXT,
      is_active INTEGER DEFAULT 1,
      last_activity TEXT,
      created_at TEXT
    )
  ''';

  static const String permissions = '''
    CREATE TABLE IF NOT EXISTS permissions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      organization_id INTEGER REFERENCES organizations(id) ON DELETE CASCADE,
      role TEXT NOT NULL,
      resource TEXT NOT NULL,
      can_create INTEGER DEFAULT 0,
      can_read INTEGER DEFAULT 0,
      can_update INTEGER DEFAULT 0,
      can_delete INTEGER DEFAULT 0,
      UNIQUE(organization_id, role, resource)
    )
  ''';

  static const String auditLogs = '''
    CREATE TABLE IF NOT EXISTS audit_logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
      organization_id INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      action TEXT NOT NULL,
      resource TEXT NOT NULL,
      resource_id TEXT,
      details TEXT,
      ip_address TEXT,
      created_at TEXT
    )
  ''';

  static const String settings = '''
    CREATE TABLE IF NOT EXISTS settings (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      organization_id INTEGER NOT NULL UNIQUE REFERENCES organizations(id) ON DELETE CASCADE,
      company_name TEXT,
      logo TEXT,
      cr_number TEXT,
      tax_number TEXT,
      address TEXT,
      phone TEXT,
      email TEXT,
      default_currency TEXT DEFAULT 'SAR',
      tax_rate REAL DEFAULT 0.0,
      invoice_prefix TEXT,
      trial_days INTEGER DEFAULT 1,
      trial_max_invoices INTEGER DEFAULT 10,
      trial_max_customers INTEGER DEFAULT 20,
      trial_max_products INTEGER DEFAULT 30,
      notes TEXT,
      invoice_primary_color TEXT DEFAULT '#6B0F1A',
      invoice_font_color TEXT DEFAULT '#323232',
      invoice_accent_color TEXT DEFAULT '#C8A03C',
      invoice_footer TEXT DEFAULT 'شكراً لتعاملكم معنا',
      maintenance_mode INTEGER DEFAULT 0,
      smtp_host TEXT,
      smtp_port INTEGER DEFAULT 587,
      smtp_username TEXT,
      smtp_password TEXT,
      smtp_use_tls INTEGER DEFAULT 1,
      email_from TEXT,
      invoice_template TEXT DEFAULT 'standard',
      invoice_header TEXT,
      invoice_terms TEXT,
      contract_template TEXT,
      receipt_config TEXT,
      updated_at TEXT
    )
  ''';

  static const String backups = '''
    CREATE TABLE IF NOT EXISTS backups (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      file_path TEXT NOT NULL,
      size_bytes INTEGER DEFAULT 0,
      organization_id INTEGER REFERENCES organizations(id) ON DELETE CASCADE,
      created_at TEXT
    )
  ''';

  static const String subscriptionPlans = '''
    CREATE TABLE IF NOT EXISTS subscription_plans (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      name_ar TEXT NOT NULL,
      price_monthly REAL NOT NULL,
      price_yearly REAL NOT NULL,
      price_yearly_text TEXT,
      max_invoices INTEGER,
      max_customers INTEGER,
      max_products INTEGER,
      max_users INTEGER DEFAULT 1,
      features TEXT,
      feature_groups TEXT,
      badge_color TEXT,
      badge_icon TEXT,
      is_active INTEGER DEFAULT 1,
      created_at TEXT
    )
  ''';

  static const String subscriptionRequests = '''
    CREATE TABLE IF NOT EXISTS subscription_requests (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      organization_id INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      plan_id INTEGER NOT NULL REFERENCES subscription_plans(id) ON DELETE CASCADE,
      period TEXT NOT NULL DEFAULT 'monthly',
      status TEXT NOT NULL DEFAULT 'pending',
      payment_proof TEXT,
      admin_notes TEXT,
      requested_at TEXT,
      reviewed_at TEXT,
      reviewed_by INTEGER REFERENCES users(id) ON DELETE SET NULL
    )
  ''';

  static const String notifications = '''
    CREATE TABLE IF NOT EXISTS notifications (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      organization_id INTEGER REFERENCES organizations(id) ON DELETE CASCADE,
      user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
      type TEXT NOT NULL,
      title TEXT NOT NULL,
      message TEXT,
      is_read INTEGER DEFAULT 0,
      created_at TEXT
    )
  ''';

  static const String apiKeys = '''
    CREATE TABLE IF NOT EXISTS api_keys (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      key TEXT NOT NULL UNIQUE,
      organization_id INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      is_active INTEGER DEFAULT 1,
      created_at TEXT,
      last_used_at TEXT
    )
  ''';

  static const String currencyRates = '''
    CREATE TABLE IF NOT EXISTS currency_rates (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      organization_id INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      currency TEXT NOT NULL,
      rate REAL NOT NULL DEFAULT 1.0,
      is_active INTEGER DEFAULT 1,
      updated_at TEXT,
      UNIQUE(organization_id, currency)
    )
  ''';

  static const String personalWallets = '''
    CREATE TABLE IF NOT EXISTS personal_wallets (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL UNIQUE,
      balance REAL DEFAULT 0.0,
      currency TEXT DEFAULT 'SAR',
      created_at TEXT,
      updated_at TEXT
    )
  ''';

  static const String personalTransactions = '''
    CREATE TABLE IF NOT EXISTS personal_transactions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      tx_type TEXT NOT NULL,
      amount REAL NOT NULL DEFAULT 0.0,
      category TEXT NOT NULL,
      description TEXT,
      payment_method TEXT,
      bank_account_id INTEGER,
      currency TEXT NOT NULL DEFAULT 'SAR',
      date TEXT,
      created_at TEXT
    )
  ''';

  static const String savingsGoals = '''
    CREATE TABLE IF NOT EXISTS savings_goals (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      target_amount REAL NOT NULL DEFAULT 0.0,
      current_amount REAL DEFAULT 0.0,
      currency TEXT DEFAULT 'SAR',
      deadline TEXT,
      icon TEXT DEFAULT 'SAVINGS',
      notes TEXT,
      is_completed INTEGER DEFAULT 0,
      created_at TEXT,
      updated_at TEXT
    )
  ''';

  static const String spendingCategories = '''
    CREATE TABLE IF NOT EXISTS spending_categories (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      name_ar TEXT NOT NULL,
      icon TEXT DEFAULT 'CATEGORY',
      color TEXT DEFAULT '#6B0F1A',
      sort_order INTEGER DEFAULT 0,
      is_active INTEGER DEFAULT 1,
      created_at TEXT
    )
  ''';

  static const String personalBankAccounts = '''
    CREATE TABLE IF NOT EXISTS personal_bank_accounts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      bank_name TEXT NOT NULL,
      currency TEXT DEFAULT 'SAR',
      balance REAL DEFAULT 0.0,
      account_type TEXT DEFAULT 'checking',
      notes TEXT,
      sort_order INTEGER DEFAULT 0,
      is_active INTEGER DEFAULT 1,
      created_at TEXT,
      updated_at TEXT
    )
  ''';

  static const String personalBankTransactions = '''
    CREATE TABLE IF NOT EXISTS personal_bank_transactions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      account_id INTEGER NOT NULL,
      date TEXT,
      tx_type TEXT NOT NULL,
      amount REAL NOT NULL DEFAULT 0.0,
      currency TEXT DEFAULT 'SAR',
      description TEXT,
      transfer_to_account_id INTEGER,
      created_at TEXT
    )
  ''';

  static const String personalDebts = '''
    CREATE TABLE IF NOT EXISTS personal_debts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      debt_type TEXT NOT NULL,
      person_name TEXT NOT NULL,
      amount REAL NOT NULL DEFAULT 0.0,
      paid REAL DEFAULT 0.0,
      status TEXT DEFAULT 'active',
      currency TEXT NOT NULL DEFAULT 'SAR',
      description TEXT,
      due_date TEXT,
      is_paid INTEGER DEFAULT 0,
      paid_date TEXT,
      reminder INTEGER DEFAULT 0,
      created_at TEXT,
      updated_at TEXT
    )
  ''';

  static const String personalDebtPayments = '''
    CREATE TABLE IF NOT EXISTS personal_debt_payments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      debt_id INTEGER NOT NULL,
      user_id INTEGER NOT NULL,
      amount REAL NOT NULL,
      payment_method TEXT DEFAULT 'cash',
      bank_account_id INTEGER,
      payment_date TEXT NOT NULL,
      notes TEXT,
      created_at TEXT
    )
  ''';

  static const String personalExchangeRates = '''
    CREATE TABLE IF NOT EXISTS personal_exchange_rates (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      from_currency TEXT NOT NULL,
      to_currency TEXT NOT NULL,
      rate REAL NOT NULL DEFAULT 1.0,
      created_at TEXT,
      updated_at TEXT
    )
  ''';

  static const String personalRecurringTransactions = '''
    CREATE TABLE IF NOT EXISTS personal_recurring_transactions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      tx_type TEXT NOT NULL,
      amount REAL NOT NULL DEFAULT 0.0,
      category TEXT NOT NULL,
      description TEXT,
      frequency TEXT NOT NULL DEFAULT 'monthly',
      interval_value INTEGER DEFAULT 1,
      next_date TEXT,
      payment_method TEXT,
      bank_account_id INTEGER,
      currency TEXT NOT NULL DEFAULT 'SAR',
      is_active INTEGER DEFAULT 1,
      created_at TEXT,
      updated_at TEXT
    )
  ''';

  static const String userInvitations = '''
    CREATE TABLE IF NOT EXISTS user_invitations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      organization_id INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      email TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'employee',
      token TEXT NOT NULL UNIQUE,
      status TEXT DEFAULT 'pending',
      invited_by_user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
      expires_at TEXT NOT NULL,
      created_at TEXT,
      accepted_at TEXT
    )
  ''';

  static const String fileUploads = '''
    CREATE TABLE IF NOT EXISTS file_uploads (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      file_name TEXT NOT NULL,
      file_path TEXT NOT NULL,
      file_size INTEGER DEFAULT 0,
      mime_type TEXT,
      folder TEXT,
      organization_id INTEGER REFERENCES organizations(id) ON DELETE CASCADE,
      uploaded_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
      created_at TEXT
    )
  ''';

  static const String emailPreferences = '''
    CREATE TABLE IF NOT EXISTS email_preferences (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      organization_id INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      notify_invoice INTEGER DEFAULT 1,
      notify_payment INTEGER DEFAULT 1,
      notify_low_stock INTEGER DEFAULT 1,
      notify_contract INTEGER DEFAULT 1,
      notify_payroll INTEGER DEFAULT 1,
      notify_debt INTEGER DEFAULT 1,
      email_from_name TEXT,
      created_at TEXT,
      updated_at TEXT
    )
  ''';

  static const String emailTemplates = '''
    CREATE TABLE IF NOT EXISTS email_templates (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      organization_id INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      subject TEXT NOT NULL,
      body TEXT NOT NULL,
      is_html INTEGER DEFAULT 1,
      variables TEXT,
      created_at TEXT,
      updated_at TEXT
    )
  ''';

  static const String emailLogs = '''
    CREATE TABLE IF NOT EXISTS email_logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      organization_id INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      recipient TEXT NOT NULL,
      subject TEXT NOT NULL,
      body TEXT,
      status TEXT DEFAULT 'sent',
      error_message TEXT,
      sent_at TEXT
    )
  ''';

  static const String trashItems = '''
    CREATE TABLE IF NOT EXISTS trash_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      resource_type TEXT NOT NULL,
      resource_id INTEGER NOT NULL,
      data_json TEXT,
      deleted_by INTEGER,
      organization_id INTEGER REFERENCES organizations(id) ON DELETE CASCADE,
      created_at TEXT
    )
  ''';

  static const String aiSuggestions = '''
    CREATE TABLE IF NOT EXISTS ai_suggestions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      organization_id INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      suggestion_type TEXT NOT NULL,
      title TEXT NOT NULL,
      description TEXT,
      data TEXT,
      is_read INTEGER DEFAULT 0,
      created_at TEXT
    )
  ''';

  static const String userPreferences = '''
    CREATE TABLE IF NOT EXISTS user_preferences (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
      pdf_primary_color TEXT DEFAULT '#6B0F1A',
      pdf_accent_color TEXT DEFAULT '#C8A03C',
      pdf_font_color TEXT DEFAULT '#323232',
      pdf_page_size TEXT DEFAULT 'A4',
      pdf_orientation TEXT DEFAULT 'portrait',
      pdf_show_logo INTEGER DEFAULT 1,
      pdf_show_footer INTEGER DEFAULT 1,
      pdf_footer_text TEXT DEFAULT 'شكراً لتعاملكم معنا',
      pdf_signature_path TEXT,
      pdf_stamp_path TEXT,
      pdf_font_name TEXT DEFAULT 'Amiri',
      pdf_logo_path TEXT,
      pdf_extra_config TEXT,
      updated_at TEXT
    )
  ''';

  /// Durable operation journal (outbox).
  ///
  /// Each row is ONE user intent, carrying a globally-unique `operation_id`
  /// (idempotency key), the semantic `operation_type` (TRANSACTION_CREATE,
  /// GOAL_CONTRIBUTE, DEBT_PAYMENT_DELETE, BANK_CREATE, …), the immutable
  /// `occurred_at` (when the user performed it — NEVER overwritten by sync
  /// time), the owning user/device, optional dependency metadata and a retry
  /// schedule. Rows are only archived (never dropped) after the server
  /// confirms the exact operation. Status values: pending | syncing | failed |
  /// conflict.
  static const String syncQueue = '''
    CREATE TABLE IF NOT EXISTS sync_queue (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      operation_id TEXT UNIQUE,
      operation_type TEXT,
      table_name TEXT NOT NULL,
      entity_type TEXT,
      entity_id TEXT,
      record_id INTEGER,
      user_id INTEGER,
      device_id TEXT,
      operation TEXT NOT NULL,
      data TEXT,
      base_version INTEGER DEFAULT 0,
      source TEXT DEFAULT 'ui',
      status TEXT NOT NULL DEFAULT 'pending',
      error_message TEXT,
      retry_count INTEGER DEFAULT 0,
      depends_on TEXT,
      occurred_at TEXT,
      next_attempt_at TEXT,
      created_at TEXT,
      updated_at TEXT,
      op_revision INTEGER,
      payload_hash TEXT,
      idempotency_key TEXT
    )
  ''';

  /// Immutable archive of confirmed/failed operations — the local sync ledger.
  /// Kept for audit/traceability even after the outbox row is removed.
  static const String syncOperationLog = '''
    CREATE TABLE IF NOT EXISTS sync_operation_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      operation_id TEXT,
      operation_type TEXT,
      entity_type TEXT,
      entity_id TEXT,
      operation TEXT,
      status TEXT NOT NULL,
      device_id TEXT,
      user_id INTEGER,
      occurred_at TEXT,
      created_at TEXT,
      synced_at TEXT,
      retry_count INTEGER DEFAULT 0,
      attempts INTEGER DEFAULT 0,
      error_message TEXT,
      response_json TEXT
    )
  ''';

  static const String syncCursor = '''
    CREATE TABLE IF NOT EXISTS sync_cursor (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      entity_type TEXT NOT NULL UNIQUE,
      last_synced_at TEXT,
      last_version INTEGER DEFAULT 0,
      last_pull_at TEXT
    )
  ''';

  static const String syncDeviceInfo = '''
    CREATE TABLE IF NOT EXISTS sync_device_info (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      device_id TEXT NOT NULL UNIQUE,
      user_id INTEGER,
      created_at TEXT,
      updated_at TEXT
    )
  ''';

  /// Stable mapping from the real user id string (server UUID) to a stable
  /// local INTEGER namespace. Purely derived values (e.g. String.hashCode)
  /// are NOT stable across app runs, which silently orphaned offline data —
  /// this table guarantees the SAME user always gets the SAME local id.
  static const String stableUserIdMap = '''
    CREATE TABLE IF NOT EXISTS stable_user_ids (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      real_user_id TEXT NOT NULL UNIQUE,
      local_user_id INTEGER NOT NULL UNIQUE,
      created_at TEXT
    )
  ''';

  static const String syncLog = '''
    CREATE TABLE IF NOT EXISTS sync_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sync_type TEXT NOT NULL CHECK(sync_type IN ('push', 'pull')),
      table_name TEXT,
      record_id INTEGER,
      operation TEXT,
      status TEXT NOT NULL CHECK(status IN ('success', 'failed')),
      message TEXT,
      created_at TEXT
    )
  ''';

  static const String syncMetadata = '''
    CREATE TABLE IF NOT EXISTS sync_metadata (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      table_name TEXT NOT NULL UNIQUE,
      last_synced_at TEXT,
      last_server_updated_at TEXT
    )
  ''';

  static const String personalEntityCache = '''
    CREATE TABLE IF NOT EXISTS personal_entity_cache (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      entity_type TEXT NOT NULL,
      remote_id TEXT NOT NULL,
      data_json TEXT NOT NULL,
      updated_at TEXT,
      UNIQUE(user_id, entity_type, remote_id)
    )
  ''';

  static const String personalBudgets = '''
    CREATE TABLE IF NOT EXISTS personal_budgets (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      period_type TEXT DEFAULT 'monthly',
      start_date TEXT,
      end_date TEXT,
      custom_days INTEGER,
      total_amount REAL NOT NULL DEFAULT 0.0,
      total_spent REAL DEFAULT 0.0,
      currency TEXT DEFAULT 'SAR',
      bank_account_ids TEXT DEFAULT '[]',
      budget_types TEXT DEFAULT '["expenses"]',
      created_at TEXT,
      updated_at TEXT
    )
  ''';

  static const String budgetCategories = '''
    CREATE TABLE IF NOT EXISTS budget_categories (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      budget_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      type TEXT NOT NULL DEFAULT 'expense',
      allocated_amount REAL NOT NULL DEFAULT 0.0,
      spent_amount REAL DEFAULT 0.0,
      currency TEXT DEFAULT 'SAR',
      created_at TEXT,
      FOREIGN KEY (budget_id) REFERENCES personal_budgets(id) ON DELETE CASCADE
    )
  ''';

  static const List<String> allTables = [
    organizations,
    users,
    userSessions,
    permissions,
    auditLogs,
    settings,
    backups,
    subscriptionPlans,
    subscriptionRequests,
    notifications,
    apiKeys,
    currencyRates,
    personalWallets,
    personalTransactions,
    savingsGoals,
    spendingCategories,
    personalBankAccounts,
    personalBankTransactions,
    personalDebts,
    personalDebtPayments,
    personalExchangeRates,
    personalRecurringTransactions,
    personalBudgets,
    budgetCategories,
    userInvitations,
    fileUploads,
    emailPreferences,
    emailTemplates,
    emailLogs,
    trashItems,
    aiSuggestions,
    userPreferences,
    syncQueue,
    syncOperationLog,
    syncCursor,
    syncDeviceInfo,
    stableUserIdMap,
    syncLog,
    syncMetadata,
    personalEntityCache,
  ];

  static const List<String> indexes = [
    'CREATE INDEX IF NOT EXISTS idx_users_org_role ON users(organization_id, role)',
    'CREATE INDEX IF NOT EXISTS idx_user_sessions_user ON user_sessions(user_id)',
    'CREATE INDEX IF NOT EXISTS idx_user_sessions_token ON user_sessions(token)',
    'CREATE INDEX IF NOT EXISTS idx_audit_logs_org_action ON audit_logs(organization_id, action)',
    'CREATE INDEX IF NOT EXISTS idx_notifications_org_user ON notifications(organization_id, user_id)',
    'CREATE INDEX IF NOT EXISTS idx_personal_tx_user_date ON personal_transactions(user_id, date)',
    'CREATE INDEX IF NOT EXISTS idx_subreq_org_status ON subscription_requests(organization_id, status)',
    'CREATE INDEX IF NOT EXISTS idx_audit_logs_created ON audit_logs(created_at)',
    'CREATE INDEX IF NOT EXISTS idx_users_email ON users(email)',
    'CREATE INDEX IF NOT EXISTS idx_user_invitations_token ON user_invitations(token)',
    'CREATE INDEX IF NOT EXISTS idx_sync_queue_status ON sync_queue(status, created_at)',
    'CREATE INDEX IF NOT EXISTS idx_sync_queue_entity ON sync_queue(entity_type, entity_id)',
    'CREATE INDEX IF NOT EXISTS idx_sync_queue_user ON sync_queue(user_id, status)',
    'CREATE INDEX IF NOT EXISTS idx_sync_oplog_entity ON sync_operation_log(entity_type, entity_id)',
    'CREATE INDEX IF NOT EXISTS idx_sync_oplog_created ON sync_operation_log(created_at)',
  ];
}
