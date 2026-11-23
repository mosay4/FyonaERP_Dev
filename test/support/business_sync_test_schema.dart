import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Fixtures that rebuild an older schema version by hand must also remove the
/// device-sync bookkeeping (schema v16): its capture triggers reference
/// columns that older versions did not have. Reopening recreates both.
Future<void> removeBusinessSyncSchema(DatabaseExecutor db) async {
  for (final row in await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'business_sync_%'",
  )) {
    await db.execute('DROP TRIGGER IF EXISTS "${row['name']}"');
  }
  for (final table in const [
    'business_sync_outbox',
    'business_sync_log',
    'business_sync_changes',
    'business_sync_rows',
    'business_sync_state',
    'business_sync_notices',
    'business_employees',
  ]) {
    await db.execute('DROP TABLE IF EXISTS $table');
  }
}
