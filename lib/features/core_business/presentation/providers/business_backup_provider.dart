import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../branches/data/branch_epoch.dart';
import '../../../branches/data/branch_scope.dart';
import '../../data/local_directory/directory_pilot.dart';
import '../../data/local_directory/directory_secure_storage.dart';
import '../../data/local_ledger/business_local_backups.dart';

final businessBackupRootProvider = Provider<Future<Directory> Function()>(
  (ref) =>
      () async => Directory(
        p.join((await businessDirectoryRoot()).path, 'backup_archives'),
      ),
);

/// The ledger selector already requires the enrolled owner and signed
/// financial grant. A directory-only or employee context never exports it.
final localBusinessBackupsProvider = Provider<LocalBusinessBackups?>((ref) {
  ref.watch(branchEpochProvider);
  final scope = ref.watch(businessLocalLedgerScopeProvider);
  if (scope == null) return null;
  final container = ref.container;
  var current = true;
  ref.onDispose(() => current = false);
  return LocalBusinessBackups(
    scope,
    ref.watch(directoryPilotStoreProvider),
    ref.watch(businessBackupRootProvider),
    () =>
        current &&
            !BranchScope.allMode &&
            !BranchScope.readOnly &&
            BranchScope.branchId == scope.branchId &&
            BranchScope.organizationId == scope.workspace.organizationId
        ? container.read(businessLocalLedgerScopeProvider)
        : null,
  );
});
