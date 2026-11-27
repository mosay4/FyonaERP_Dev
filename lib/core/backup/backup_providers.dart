import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/branches/data/branch_scope.dart';
import '../../features/core_business/data/local_directory/directory_database.dart';
import '../../features/core_business/data/local_directory/directory_pilot.dart';
import '../../features/core_business/data/local_directory/directory_scope.dart';
import '../../features/core_business/data/local_directory/directory_secure_storage.dart';
import '../../features/personal/data/ledger/personal_ledger.dart';
import '../../features/personal/di/personal_providers.dart';
import '../di/providers.dart';
import '../media/media_store.dart';
import 'backup_bridges.dart';
import 'backup_cloud.dart';
import 'backup_coordinator.dart';

enum BackupKind { personal, business }

/// `ref.read` of a Ref or a WidgetRef.
typedef BackupRead = T Function<T>(ProviderListenable<T> provider);

final backupCoordinatorProvider = Provider<BackupCoordinator>((ref) {
  final c = BackupCoordinator(remoteFor: (s) => ApiBackupRemote(ref.read(apiClientProvider), s));
  ref.onDispose(c.stop);
  return c;
});

/// The Business branch whose ledger this device may back up: the owner's
/// own device ledger only (employees and connected branches: none).
DirectoryAccess? backupBusinessScope(BackupRead read) {
  final scope = read(businessLocalLedgerScopeProvider);
  if (scope == null || scope.member) return null;
  return scope;
}

/// Same conditions as the existing branch backups: the branch is still the
/// selected, writable one when the restore commits.
bool backupBusinessAllowed(BackupRead read, DirectoryAccess scope) =>
    !BranchScope.allMode &&
    !BranchScope.readOnly &&
    BranchScope.branchId == scope.branchId &&
    BranchScope.organizationId == scope.workspace.organizationId &&
    sameDirectoryScope(read(businessLocalLedgerScopeProvider), scope);

Future<BackupSpace?> resolveBackupSpace(BackupRead read, BackupKind kind) async {
  try {
    if (kind == BackupKind.personal) {
      final db = await PersonalLedger.active();
      final key = await PersonalLedger.keys.read(db.storageId);
      if (key == null) return null;
      final svc = read(backupServiceProvider);
      return BackupSpace(
        id: 'p-${db.storageId.substring(0, 20)}',
        section: MediaSection.personal,
        dbPath: db.path,
        dbKeyHex: key,
        extras: () => BackupBridges.personalExtras(svc),
      );
    }
    final scope = backupBusinessScope(read);
    if (scope == null) return null;
    final key = await const SecureDirectoryKeys().read(scope.workspace.storageId);
    if (key == null) return null;
    return BackupSpace(
      id: 'b-${scope.workspace.storageId.substring(0, 20)}',
      section: MediaSection.business,
      dbPath: DirectoryDatabase.filePath(await businessDirectoryRoot(), scope.workspace),
      dbKeyHex: key,
    );
  } catch (_) {
    return null;
  }
}

/// Starts the background schedule (every 2 minutes; disabled spaces are
/// skipped inside the coordinator).
final backupSchedulerProvider = Provider<void>((ref) {
  final c = ref.read(backupCoordinatorProvider);
  c.start(() async => [
        for (final k in BackupKind.values)
          if (await resolveBackupSpace(ref.read, k) case final s?) s,
      ]);
});
