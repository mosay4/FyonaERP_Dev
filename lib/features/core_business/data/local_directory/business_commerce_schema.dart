part of 'directory_database.dart';

const _commerceReceipts = 'business_commerce_projection_receipts';
const _commerceBranches = 'business_commerce_branches';
const _commerceProducts = 'business_commerce_products';
const _commerceUnits = 'business_commerce_units';
const _commerceBarcodes = 'business_commerce_barcodes';
const _commercePrices = 'business_commerce_prices';
const _commerceStock = 'business_commerce_stock';
const _commerceInvoices = 'business_commerce_invoices';
const _commerceLines = 'business_commerce_invoice_lines';
const _commerceEdits = 'business_commerce_invoice_edits';
const _commercePayments = 'business_commerce_invoice_payments';
const _commerceBalances = 'business_commerce_party_balances';
const _commerceReturns = 'business_commerce_returns';
const _commerceReturnLines = 'business_commerce_return_lines';
const _commerceLots = 'business_commerce_lots';
const _commerceConsumptions = 'business_commerce_lot_consumptions';
const _commerceMovements = 'business_commerce_stock_movements';

/// Schema v18: a unit may carry its own photo (e.g. a carton), stored in the
/// encrypted ledger like a product image and synced with the unit row.
/// Idempotent: a database created at v18 runs it right after its tables.
Future<void> _upgradeUnitImages(DatabaseExecutor db) async {
  final columns = await db.rawQuery('PRAGMA table_info($_commerceUnits)');
  if (columns.any((column) => column['name'] == 'image')) return;
  await db.execute('ALTER TABLE $_commerceUnits ADD COLUMN image TEXT');
}

// Branch stock is exact to 0.001 in PostgreSQL. Document lines, lots and
// movements came from floating-point columns with finer precision. Keep them
// independently at 0.000001 and reject input that would require rounding.
Future<void> _createBusinessCommerce(DatabaseExecutor db) async {
  await db.execute(
    'CREATE TABLE $_commerceBranches (branch_id TEXT PRIMARY KEY, name TEXT NOT NULL)',
  );
  Future<void> table(String name, String columns) => db.execute('''
    CREATE TABLE $name (
      branch_id TEXT NOT NULL,
      id TEXT NOT NULL,
      $columns,
      PRIMARY KEY (branch_id, id)
    )
  ''');
  await table(_commerceProducts, '''
    name TEXT NOT NULL,
    name_ar TEXT,
    sku TEXT,
    barcode TEXT,
    description TEXT,
    unit TEXT,
    price_minor INTEGER NOT NULL,
    cost_minor INTEGER,
    cost_currency TEXT,
    min_stock_4 INTEGER,
    is_service INTEGER NOT NULL CHECK (is_service IN (0, 1)),
    is_active INTEGER NOT NULL CHECK (is_active IN (0, 1)),
    expiry_date TEXT,
    image TEXT,
    notes TEXT,
    created_us INTEGER NOT NULL,
    deleted_us INTEGER
  ''');
  await table(_commerceUnits, '''
    product_id TEXT NOT NULL,
    name TEXT NOT NULL,
    factor_4 INTEGER NOT NULL CHECK (factor_4 > 0),
    family TEXT,
    barcode TEXT,
    sale_minor INTEGER,
    purchase_minor INTEGER,
    is_base INTEGER NOT NULL CHECK (is_base IN (0, 1)),
    is_active INTEGER NOT NULL CHECK (is_active IN (0, 1)),
    UNIQUE (branch_id, product_id, name),
    UNIQUE (branch_id, product_id, id),
    FOREIGN KEY (branch_id, product_id) REFERENCES $_commerceProducts (branch_id, id)
  ''');
  await table(_commerceBarcodes, '''
    product_id TEXT NOT NULL,
    unit_id TEXT,
    barcode TEXT NOT NULL,
    UNIQUE (branch_id, barcode),
    FOREIGN KEY (branch_id, product_id) REFERENCES $_commerceProducts (branch_id, id),
    FOREIGN KEY (branch_id, product_id, unit_id)
      REFERENCES $_commerceUnits (branch_id, product_id, id)
  ''');
  await table(_commercePrices, '''
    product_id TEXT NOT NULL,
    currency TEXT NOT NULL,
    price_minor INTEGER NOT NULL,
    buy_minor INTEGER,
    UNIQUE (branch_id, product_id, currency),
    FOREIGN KEY (branch_id, product_id) REFERENCES $_commerceProducts (branch_id, id)
  ''');
  await table(_commerceStock, '''
    product_id TEXT NOT NULL,
    quantity_milli INTEGER NOT NULL,
    avg_cost_4 INTEGER NOT NULL,
    UNIQUE (branch_id, product_id),
    FOREIGN KEY (branch_id, product_id) REFERENCES $_commerceProducts (branch_id, id)
  ''');
  await table(_commerceInvoices, '''
    number TEXT NOT NULL,
    invoice_type TEXT NOT NULL,
    party_kind TEXT NOT NULL,
    party_id TEXT,
    group_id TEXT CHECK (group_id IS NULL OR party_id IS NOT NULL),
    date TEXT NOT NULL,
    due_date TEXT,
    currency TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('draft', 'confirmed', 'paid', 'partially_paid', 'cancelled')),
    subtotal_minor INTEGER NOT NULL,
    discount_type TEXT,
    discount_value_2 INTEGER NOT NULL,
    discount_minor INTEGER NOT NULL,
    tax_type TEXT,
    tax_rate_2 INTEGER NOT NULL,
    tax_minor INTEGER NOT NULL,
    total_minor INTEGER NOT NULL CHECK (total_minor >= 0),
    paid_minor INTEGER NOT NULL CHECK (paid_minor >= 0),
    balance_minor INTEGER NOT NULL CHECK (balance_minor >= 0),
    notes TEXT,
    terms TEXT,
    idempotency_key TEXT,
    created_by TEXT,
    created_us INTEGER NOT NULL,
    deleted_us INTEGER,
    confirmed_us INTEGER,
    cancelled_us INTEGER,
    CHECK ((invoice_type = 'sale' AND party_kind = 'customer') OR
      (invoice_type = 'purchase' AND party_kind = 'supplier')),
    UNIQUE (branch_id, number),
    UNIQUE (branch_id, idempotency_key),
    UNIQUE (branch_id, id, invoice_type),
    FOREIGN KEY (branch_id, party_kind, party_id)
      REFERENCES directory_parties (branch_id, kind, id),
    FOREIGN KEY (branch_id, party_kind, party_id, group_id)
      REFERENCES business_debt_groups (branch_id, kind, party_id, id)
  ''');
  await table(_commerceLines, '''
    invoice_id TEXT NOT NULL,
    product_id TEXT,
    unit_id TEXT CHECK (unit_id IS NULL OR product_id IS NOT NULL),
    unit_name TEXT,
    description TEXT NOT NULL,
    quantity_micro INTEGER NOT NULL CHECK (quantity_micro > 0),
    base_micro INTEGER NOT NULL CHECK (base_micro >= 0),
    factor_4 INTEGER CHECK (factor_4 > 0),
    unit_minor INTEGER NOT NULL,
    discount_minor INTEGER NOT NULL,
    tax_rate_2 INTEGER NOT NULL,
    total_minor INTEGER NOT NULL,
    is_service INTEGER NOT NULL CHECK (is_service IN (0, 1)),
    image TEXT,
    cost_total_minor INTEGER,
    profit_minor INTEGER,
    original_minor INTEGER,
    price_currency TEXT,
    exchange_rate TEXT,
    UNIQUE (branch_id, invoice_id, id),
    FOREIGN KEY (branch_id, invoice_id) REFERENCES $_commerceInvoices (branch_id, id),
    FOREIGN KEY (branch_id, product_id) REFERENCES $_commerceProducts (branch_id, id),
    FOREIGN KEY (branch_id, product_id, unit_id) REFERENCES $_commerceUnits (branch_id, product_id, id)
  ''');
  await table(_commerceEdits, '''
    invoice_id TEXT NOT NULL,
    item_id TEXT NOT NULL,
    description TEXT,
    old_quantity_micro INTEGER,
    new_quantity_micro INTEGER,
    old_unit_minor INTEGER,
    new_unit_minor INTEGER,
    changed_by TEXT,
    created_us INTEGER NOT NULL,
    FOREIGN KEY (branch_id, invoice_id, item_id)
      REFERENCES $_commerceLines (branch_id, invoice_id, id)
  ''');
  await table(_commercePayments, '''
    invoice_id TEXT NOT NULL,
    account_id TEXT,
    method TEXT NOT NULL,
    date TEXT NOT NULL,
    payment_currency TEXT NOT NULL,
    debt_currency TEXT NOT NULL,
    exchange_rate TEXT NOT NULL,
    original_minor INTEGER NOT NULL CHECK (original_minor >= 0),
    applied_minor INTEGER NOT NULL CHECK (applied_minor > 0),
    reference TEXT,
    notes TEXT,
    rate_source TEXT,
    rate_us INTEGER,
    created_by TEXT,
    created_us INTEGER NOT NULL,
    FOREIGN KEY (branch_id, invoice_id) REFERENCES $_commerceInvoices (branch_id, id),
    FOREIGN KEY (branch_id, account_id) REFERENCES business_local_accounts (branch_id, id)
  ''');
  await table(_commerceBalances, '''
    invoice_id TEXT NOT NULL,
    amount_minor INTEGER NOT NULL CHECK (amount_minor >= 0),
    paid_minor INTEGER NOT NULL CHECK (paid_minor >= 0),
    status TEXT NOT NULL CHECK (status IN ('open', 'partial', 'paid', 'cancelled')),
    UNIQUE (branch_id, invoice_id),
    FOREIGN KEY (branch_id, invoice_id) REFERENCES $_commerceInvoices (branch_id, id)
  ''');
  await table(_commerceReturns, '''
    invoice_id TEXT NOT NULL,
    invoice_type TEXT NOT NULL,
    number TEXT NOT NULL,
    date TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('draft', 'confirmed', 'cancelled')),
    total_minor INTEGER NOT NULL CHECK (total_minor >= 0),
    reason TEXT,
    notes TEXT,
    created_by TEXT,
    created_us INTEGER NOT NULL,
    UNIQUE (branch_id, invoice_type, number),
    UNIQUE (branch_id, invoice_id, id),
    FOREIGN KEY (branch_id, invoice_id, invoice_type)
      REFERENCES $_commerceInvoices (branch_id, id, invoice_type)
  ''');
  await table(_commerceReturnLines, '''
    return_id TEXT NOT NULL,
    invoice_id TEXT NOT NULL,
    item_id TEXT NOT NULL,
    product_id TEXT,
    description TEXT NOT NULL,
    quantity_micro INTEGER NOT NULL CHECK (quantity_micro > 0),
    unit_minor INTEGER NOT NULL,
    total_minor INTEGER NOT NULL,
    FOREIGN KEY (branch_id, invoice_id, return_id)
      REFERENCES $_commerceReturns (branch_id, invoice_id, id),
    FOREIGN KEY (branch_id, invoice_id, item_id)
      REFERENCES $_commerceLines (branch_id, invoice_id, id),
    FOREIGN KEY (branch_id, product_id) REFERENCES $_commerceProducts (branch_id, id)
  ''');
  await table(_commerceLots, '''
    product_id TEXT NOT NULL,
    supplier_id TEXT,
    purchase_invoice_id TEXT,
    item_id TEXT,
    unit_id TEXT,
    received_micro INTEGER NOT NULL CHECK (received_micro >= 0),
    remaining_micro INTEGER NOT NULL CHECK (remaining_micro BETWEEN 0 AND received_micro),
    unit_cost_4 INTEGER NOT NULL,
    currency TEXT,
    exchange_rate TEXT,
    purchase_date TEXT,
    expiry_date TEXT,
    lot_number TEXT,
    source TEXT,
    created_us INTEGER NOT NULL,
    FOREIGN KEY (branch_id, product_id) REFERENCES $_commerceProducts (branch_id, id),
    FOREIGN KEY (branch_id, purchase_invoice_id) REFERENCES $_commerceInvoices (branch_id, id),
    FOREIGN KEY (branch_id, item_id) REFERENCES $_commerceLines (branch_id, id),
    FOREIGN KEY (branch_id, product_id, unit_id) REFERENCES $_commerceUnits (branch_id, product_id, id)
  ''');
  await table(_commerceConsumptions, '''
    lot_id TEXT NOT NULL,
    item_id TEXT,
    quantity_micro INTEGER NOT NULL CHECK (quantity_micro > 0),
    unit_cost_4 INTEGER NOT NULL,
    currency TEXT,
    created_us INTEGER NOT NULL,
    FOREIGN KEY (branch_id, lot_id) REFERENCES $_commerceLots (branch_id, id),
    FOREIGN KEY (branch_id, item_id) REFERENCES $_commerceLines (branch_id, id)
  ''');
  await table(_commerceMovements, '''
    product_id TEXT NOT NULL,
    movement_type TEXT NOT NULL,
    quantity_micro INTEGER NOT NULL,
    unit_minor INTEGER NOT NULL,
    total_minor INTEGER NOT NULL,
    currency TEXT,
    reason TEXT,
    old_micro INTEGER,
    new_micro INTEGER,
    difference_micro INTEGER,
    reference_type TEXT,
    reference_id TEXT,
    notes TEXT,
    created_by TEXT,
    created_us INTEGER NOT NULL,
    FOREIGN KEY (branch_id, product_id) REFERENCES $_commerceProducts (branch_id, id)
  ''');
  for (final (tableName, column) in [
    (_commerceInvoices, 'invoice_type, date, id'),
    (_commerceInvoices, 'party_kind, party_id, group_id'),
    (_commerceLines, 'invoice_id, id'),
    (_commerceEdits, 'invoice_id, created_us, id'),
    (_commercePayments, 'invoice_id, created_us, id'),
    (_commerceReturns, 'invoice_id, date, created_us, id'),
    (_commerceReturnLines, 'invoice_id, item_id, return_id'),
    (_commerceLots, 'product_id, expiry_date, purchase_date, created_us, id'),
    (_commerceConsumptions, 'item_id, created_us, id'),
    (_commerceMovements, 'product_id, created_us, id'),
  ]) {
    final key = column.split(',').first;
    await db.execute(
      'CREATE INDEX ${tableName}_$key ON $tableName (branch_id, $column)',
    );
  }
  await db.execute(
    'CREATE INDEX ${_commercePayments}_account ON $_commercePayments (branch_id, account_id)',
  );
  await db.execute('''
    CREATE TABLE $_commerceReceipts (
      branch_id TEXT PRIMARY KEY,
      snapshot_id TEXT NOT NULL,
      digest TEXT NOT NULL,
      FOREIGN KEY (branch_id) REFERENCES $_openingProjectionReceipts (branch_id)
    )
  ''');
}
