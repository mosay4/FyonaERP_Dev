import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Drop child relationships first when reconstructing a pre-v12 fixture.
const inventoryCatalogueTables = [
  'business_commerce_category_links',
  'business_commerce_categories',
  'business_commerce_catalogue',
];

/// Reconstruct v6 before simulating an upgrade. Drop children before parents.
Future<void> removeCommerceFixtureSchema(Transaction txn) async {
  for (final table in inventoryCatalogueTables) {
    await txn.execute('DROP TABLE IF EXISTS $table');
  }
  await txn.execute('DROP TABLE IF EXISTS business_local_party_shares');
  await txn.execute('DROP TABLE IF EXISTS business_cash_replica');
  await txn.execute('DROP TABLE IF EXISTS business_backup_recoveries');
  await txn.execute('DROP TABLE IF EXISTS business_reconciliations');
  for (final suffix in [
    'projection_receipts',
    'stock_movements',
    'lot_consumptions',
    'lots',
    'return_lines',
    'returns',
    'party_balances',
    'invoice_payments',
    'invoice_edits',
    'invoice_lines',
    'invoices',
    'stock',
    'prices',
    'barcodes',
    'units',
    'products',
    'branches',
  ]) {
    await txn.execute('DROP TABLE business_commerce_$suffix');
  }
}
