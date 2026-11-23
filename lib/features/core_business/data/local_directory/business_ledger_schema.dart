part of 'directory_database.dart';

Future<void> _createBusinessLedger(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE business_deleted_directory_parties (
      branch_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      party_id TEXT NOT NULL,
      deleted_us INTEGER NOT NULL,
      PRIMARY KEY (branch_id, kind, party_id),
      FOREIGN KEY (branch_id, kind, party_id)
        REFERENCES directory_parties (branch_id, kind, id)
    )
  ''');
  await db.execute('''
    CREATE TABLE business_ledger_commands (
      branch_id TEXT NOT NULL,
      id TEXT NOT NULL,
      fingerprint TEXT NOT NULL,
      result TEXT NOT NULL,
      PRIMARY KEY (branch_id, id)
    )
  ''');
  await db.execute('''
    CREATE TABLE business_ledger_policy (
      branch_id TEXT PRIMARY KEY NOT NULL,
      allow_negative INTEGER NOT NULL CHECK (allow_negative IN (0, 1))
    )
  ''');
  await db.execute('''
    CREATE TABLE business_local_accounts (
      branch_id TEXT NOT NULL,
      id TEXT NOT NULL,
      bank_name TEXT NOT NULL,
      account_name TEXT NOT NULL,
      account_number TEXT NOT NULL,
      account_type TEXT NOT NULL,
      iban TEXT,
      currency TEXT NOT NULL,
      balance_minor INTEGER NOT NULL
        CHECK (balance_minor BETWEEN -${BusinessMoney.maxMinor} AND ${BusinessMoney.maxMinor}),
      created_us INTEGER NOT NULL,
      PRIMARY KEY (branch_id, id)
    )
  ''');
  await db.execute('''
    CREATE TABLE business_local_bank_legs (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      branch_id TEXT NOT NULL,
      command_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      delta_minor INTEGER NOT NULL CHECK (delta_minor != 0),
      balance_minor INTEGER NOT NULL,
      description TEXT NOT NULL,
      expense_category TEXT,
      created_us INTEGER NOT NULL,
      fx_rate TEXT,
      UNIQUE (branch_id, command_id, account_id),
      FOREIGN KEY (branch_id, account_id)
        REFERENCES business_local_accounts (branch_id, id),
      FOREIGN KEY (branch_id, command_id)
        REFERENCES business_ledger_commands (branch_id, id)
        DEFERRABLE INITIALLY DEFERRED
    )
  ''');
  await db.execute('''
    CREATE INDEX business_local_bank_legs_by_account
    ON business_local_bank_legs (branch_id, account_id, sequence DESC)
  ''');
  await db.execute('''
    CREATE UNIQUE INDEX business_debt_groups_scope
    ON business_debt_groups (branch_id, kind, party_id, id)
  ''');
  await _createLedgerDebts(db);
  await _createOpeningDebtHistory(db);
  await db.execute('''
    CREATE TABLE business_shared_cash (
      branch_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      grant_version INTEGER NOT NULL CHECK (grant_version > 0),
      allow_negative INTEGER NOT NULL CHECK (allow_negative IN (0, 1)),
      PRIMARY KEY (branch_id, account_id),
      FOREIGN KEY (branch_id, account_id) REFERENCES business_local_accounts (branch_id, id)
    )
  ''');
  await db.execute('''
    CREATE TABLE business_cash_outbox (
      branch_id TEXT NOT NULL,
      command_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
      currency TEXT NOT NULL,
      grant_version INTEGER NOT NULL,
      PRIMARY KEY (branch_id, command_id),
      FOREIGN KEY (branch_id, account_id) REFERENCES business_shared_cash (branch_id, account_id),
      FOREIGN KEY (branch_id, command_id, account_id)
        REFERENCES business_local_bank_legs (branch_id, command_id, account_id)
    )
  ''');
  await db.execute('''
    CREATE TABLE business_cash_decisions (
      branch_id TEXT NOT NULL,
      command_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      amount_minor INTEGER NOT NULL,
      currency TEXT NOT NULL,
      sequence INTEGER NOT NULL CHECK (sequence > 0),
      decision TEXT NOT NULL,
      blocked_by TEXT,
      PRIMARY KEY (branch_id, command_id),
      FOREIGN KEY (branch_id, command_id, account_id)
        REFERENCES business_local_bank_legs (branch_id, command_id, account_id)
    )
  ''');
}

Future<void> _createLedgerDebts(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE business_local_debts (
      branch_id TEXT NOT NULL,
      id TEXT NOT NULL,
      kind TEXT NOT NULL,
      party_id TEXT NOT NULL,
      group_id TEXT,
      invoice_date TEXT NOT NULL,
      number TEXT NOT NULL,
      currency TEXT NOT NULL,
      total_minor INTEGER NOT NULL
        CHECK (total_minor BETWEEN 0 AND ${BusinessMoney.maxMinor}),
      paid_minor INTEGER NOT NULL CHECK (paid_minor BETWEEN 0 AND ${BusinessMoney.maxMinor}),
      created_us INTEGER NOT NULL,
      opening_quantity TEXT NOT NULL DEFAULT '1',
      opening_unit_minor INTEGER CHECK (opening_unit_minor BETWEEN 0 AND ${BusinessMoney.maxMinor}),
      revision INTEGER NOT NULL DEFAULT 0,
      cancelled_us INTEGER,
      PRIMARY KEY (branch_id, id),
      UNIQUE (branch_id, number),
      FOREIGN KEY (branch_id, kind, party_id)
        REFERENCES directory_parties (branch_id, kind, id),
      FOREIGN KEY (branch_id, kind, party_id, group_id)
        REFERENCES business_debt_groups (branch_id, kind, party_id, id)
    )
  ''');
  await db.execute('''
    CREATE INDEX business_local_debts_by_party
    ON business_local_debts (branch_id, kind, party_id, invoice_date, created_us, id)
  ''');
  await db.execute('''
    CREATE TABLE business_local_payment_parts (
      branch_id TEXT NOT NULL,
      command_id TEXT NOT NULL,
      invoice_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      method TEXT NOT NULL,
      date TEXT NOT NULL,
      payment_currency TEXT NOT NULL,
      debt_currency TEXT NOT NULL,
      exchange_rate TEXT NOT NULL,
      original_minor INTEGER NOT NULL CHECK (original_minor >= 0),
      applied_minor INTEGER NOT NULL CHECK (applied_minor > 0),
      PRIMARY KEY (branch_id, command_id, invoice_id),
      FOREIGN KEY (branch_id, invoice_id)
        REFERENCES business_local_debts (branch_id, id),
      FOREIGN KEY (branch_id, command_id, account_id)
        REFERENCES business_local_bank_legs (branch_id, command_id, account_id)
        DEFERRABLE INITIALLY DEFERRED
    )
  ''');
  await db.execute('''
    CREATE INDEX business_local_payment_parts_by_invoice
    ON business_local_payment_parts (branch_id, invoice_id)
  ''');
}

Future<void> _createOpeningDebtHistory(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE business_opening_debt_edits (
      branch_id TEXT NOT NULL,
      command_id TEXT NOT NULL,
      invoice_id TEXT NOT NULL,
      revision INTEGER NOT NULL,
      account_id TEXT NOT NULL,
      old_quantity TEXT,
      new_quantity TEXT,
      old_unit_minor INTEGER,
      new_unit_minor INTEGER,
      created_us INTEGER NOT NULL,
      PRIMARY KEY (branch_id, command_id),
      UNIQUE (branch_id, invoice_id, revision),
      FOREIGN KEY (branch_id, invoice_id) REFERENCES business_local_debts (branch_id, id),
      FOREIGN KEY (branch_id, command_id) REFERENCES business_ledger_commands (branch_id, id)
        DEFERRABLE INITIALLY DEFERRED
    )
  ''');
}

Future<void> _upgradeLedgerDebts(DatabaseExecutor db) async {
  // Introduce document revisions and allow edits below the amount already
  // paid (the original UI does not refund when merely editing a price).
  // sqflite runs the version migration in one transaction, with FKs on.
  await db.execute(
    'ALTER TABLE business_local_payment_parts RENAME TO business_v3_payment_parts',
  );
  await db.execute(
    'ALTER TABLE business_local_debts RENAME TO business_v3_debts',
  );
  await db.execute('DROP INDEX business_local_payment_parts_by_invoice');
  await db.execute('DROP INDEX business_local_debts_by_party');
  await _createLedgerDebts(db);
  await db.execute('''
    INSERT INTO business_local_debts
      (branch_id, id, kind, party_id, group_id, invoice_date, number, currency,
       total_minor, paid_minor, created_us)
    SELECT branch_id, id, kind, party_id, group_id, invoice_date, number, currency,
           total_minor, paid_minor, created_us
    FROM business_v3_debts
  ''');
  await db.execute('''
    INSERT INTO business_local_payment_parts
    SELECT * FROM business_v3_payment_parts
  ''');
  await db.execute('DROP TABLE business_v3_payment_parts');
  await db.execute('DROP TABLE business_v3_debts');
  await _createOpeningDebtHistory(db);
}

Future<void> _createCashConflictReads(DatabaseExecutor db) => db.execute('''
  CREATE TABLE business_cash_conflict_reads (
    branch_id TEXT NOT NULL,
    command_id TEXT NOT NULL,
    PRIMARY KEY (branch_id, command_id),
    FOREIGN KEY (branch_id, command_id)
      REFERENCES business_cash_decisions (branch_id, command_id)
  )
''');

Future<void> _createBusinessCashReplica(DatabaseExecutor db) => db.execute('''
  CREATE TABLE business_cash_replica (
    branch_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    checkpoint_sequence INTEGER NOT NULL CHECK (checkpoint_sequence >= 0),
    checkpoint_digest TEXT NOT NULL CHECK (length(checkpoint_digest) = 64)
  )
''');

Future<void> _createBusinessBankManagement(DatabaseExecutor db) async {
  await db.execute(
    'ALTER TABLE business_local_accounts ADD COLUMN closed_us INTEGER',
  );
  await db.execute('''
    ALTER TABLE business_local_accounts ADD COLUMN is_active INTEGER NOT NULL
      DEFAULT 1 CHECK (is_active IN (0, 1))
  ''');
  await db.execute('''
    ALTER TABLE business_local_accounts ADD COLUMN cash_stashed INTEGER NOT NULL
      DEFAULT 0 CHECK (cash_stashed IN (0, 1))
  ''');
  await db.execute(
    'ALTER TABLE business_local_bank_legs ADD COLUMN currency TEXT',
  );
  await db.execute(
    'ALTER TABLE business_local_bank_legs ADD COLUMN reference TEXT',
  );
  await db.execute('''
    ALTER TABLE business_local_bank_legs ADD COLUMN legacy INTEGER NOT NULL
      DEFAULT 0 CHECK (legacy IN (0, 1))
  ''');
  await db.execute('''
    ALTER TABLE business_local_bank_legs ADD COLUMN hidden INTEGER NOT NULL
      DEFAULT 0 CHECK (hidden IN (0, 1))
  ''');
  // No earlier schema let the user change the currency on an account:
  // its current currency is the original currency of every existing leg.
  await db.execute('''
    UPDATE business_local_bank_legs SET currency = (
      SELECT a.currency FROM business_local_accounts a
      WHERE a.branch_id = business_local_bank_legs.branch_id
        AND a.id = business_local_bank_legs.account_id
    )
  ''');
  await db.execute('''
    CREATE TABLE business_bank_account_edits (
      branch_id TEXT NOT NULL,
      command_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      previous TEXT NOT NULL,
      current TEXT NOT NULL,
      created_us INTEGER NOT NULL,
      PRIMARY KEY (branch_id, command_id, account_id),
      FOREIGN KEY (branch_id, account_id) REFERENCES business_local_accounts (branch_id, id),
      FOREIGN KEY (branch_id, command_id) REFERENCES business_ledger_commands (branch_id, id)
        DEFERRABLE INITIALLY DEFERRED
    )
  ''');
  await db.execute('''
    CREATE TABLE business_bank_projection_receipts (
      branch_id TEXT PRIMARY KEY,
      snapshot_id TEXT NOT NULL,
      digest TEXT NOT NULL,
      FOREIGN KEY (branch_id) REFERENCES business_cutover_archives (branch_id)
    )
  ''');
  await db.execute('''
    ALTER TABLE business_cutover_archives ADD COLUMN bank_policy INTEGER
      CHECK (bank_policy IN (0, 1))
  ''');
}

Future<void> _createOpeningCutoverProjection(DatabaseExecutor db) async {
  await db.execute(
    'ALTER TABLE business_local_debts ADD COLUMN opening_item_id TEXT',
  );
  await db.execute(
    'ALTER TABLE business_local_debts ADD COLUMN legacy_receivable_id TEXT',
  );
  await db.execute('''
    ALTER TABLE business_debt_groups ADD COLUMN group_kind TEXT NOT NULL DEFAULT 'manual'
      CHECK (group_kind IN ('manual', 'auto'))
  ''');
  await db.execute('ALTER TABLE business_debt_groups ADD COLUMN period TEXT');
  // PostgreSQL has no payment-to-bank-transaction FK; one bank leg can cover
  // several payments or an advance. Do not manufacture a financial posting
  // or infer such a link from amount, timestamp or text.
  await db.execute('''
    CREATE TABLE business_imported_opening_payments (
      branch_id TEXT NOT NULL,
      id TEXT NOT NULL,
      invoice_id TEXT NOT NULL,
      account_id TEXT,
      method TEXT NOT NULL,
      date TEXT NOT NULL,
      payment_currency TEXT NOT NULL,
      debt_currency TEXT NOT NULL,
      exchange_rate TEXT NOT NULL,
      original_minor INTEGER NOT NULL CHECK (original_minor >= 0),
      applied_minor INTEGER NOT NULL CHECK (applied_minor > 0),
      created_us INTEGER NOT NULL,
      PRIMARY KEY (branch_id, id),
      FOREIGN KEY (branch_id, invoice_id) REFERENCES business_local_debts (branch_id, id),
      FOREIGN KEY (branch_id, account_id) REFERENCES business_local_accounts (branch_id, id)
    )
  ''');
  await db.execute('''
    CREATE INDEX business_imported_opening_payments_by_invoice
      ON business_imported_opening_payments (branch_id, invoice_id)
  ''');
  await db.execute('''
    CREATE VIEW business_debt_payment_history AS
      SELECT p.branch_id, p.command_id, p.invoice_id, p.account_id, p.method,
        p.date, p.payment_currency, p.debt_currency, p.exchange_rate,
        p.original_minor, p.applied_minor, p.command_id AS id, l.created_us
      FROM business_local_payment_parts p
      JOIN business_local_bank_legs l ON l.branch_id = p.branch_id
        AND l.command_id = p.command_id AND l.account_id = p.account_id
      UNION ALL
      SELECT branch_id, NULL AS command_id, invoice_id, account_id, method, date,
        payment_currency, debt_currency, exchange_rate, original_minor, applied_minor,
        id, created_us
      FROM business_imported_opening_payments
  ''');
  await db.execute('''
    CREATE TABLE business_opening_projection_receipts (
      branch_id TEXT PRIMARY KEY,
      snapshot_id TEXT NOT NULL,
      digest TEXT NOT NULL,
      FOREIGN KEY (branch_id) REFERENCES business_bank_projection_receipts (branch_id)
    )
  ''');
}
