import 'dart:io';

import '../../../../core/backup/backup_providers.dart';
import '../../../../core/utils/document_number.dart';
import '../../../branches/data/branch_api.dart';
import '../../data/local_directory/directory_database.dart';
import '../../data/local_directory/directory_pilot.dart';
import '../../data/local_directory/directory_secure_storage.dart';

/// What a reset of the whole Business account did.
typedef BusinessResetResult = ({int otherDevices, bool backupKept});

/// Factory reset of the owner's Business account, on a device ledger
/// (owner, 28-11): every branch's records, banks, balances, products,
/// invoices and the Business Sara conversation are emptied — on this phone,
/// on the owner's other phones and in every employee's copy of this
/// workspace (their personal data is never touched).
///
/// 1. A last backup copy is written to the phone first and kept (the
///    automatic refresh never replaces it), so the data can come back.
/// 2. The server drops what is still on its way and tells every other
///    device of the account to empty its copy.
/// 3. This phone empties its own copy (its import history too); the next
///    backup starts a new set.
///
/// The caller clears the screens' state afterwards.
Future<BusinessResetResult> resetBusinessAccount(BackupRead read) async {
  final scope = read(businessLocalLedgerScopeProvider);
  final store = read(directoryPilotStoreProvider);
  final owner = scope != null && !scope.member;
  String? replica;
  var kept = false;
  final coordinator = read(backupCoordinatorProvider);
  final space = owner ? await resolveBackupSpace(read, BackupKind.business) : null;
  if (owner) {
    if (space != null) {
      try {
        await coordinator.runNow(space, force: true);
        kept = await coordinator.saveToDevice(space) != null;
      } catch (_) {
        // No room / no folder: the reset still goes on (the cloud copy stays).
      }
    }
    replica = await store.withSync(scope, (db) => db.syncReplicaId());
  }
  final server = await read(branchApiProvider).resetAllBusiness(replicaId: replica);
  if (owner) {
    await store.withSync(scope, (db) => db.syncWipe());
    try {
      final root = await businessDirectoryRoot();
      final registry = File('${root.path}/imports/${scope.workspace.storageId}.sqlite');
      if (await registry.exists()) await registry.delete();
    } catch (_) {}
    if (space != null) await coordinator.startNewSet(space.id);
  }
  DocumentSerials.put(const {});
  return (otherDevices: (server['devices_told'] as num?)?.toInt() ?? 0, backupKept: kept);
}
