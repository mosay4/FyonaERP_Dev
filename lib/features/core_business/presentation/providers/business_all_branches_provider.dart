import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/config/directory_pilot_build.dart';
import '../../../../core/network/api_client.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../branches/data/branch_api.dart';
import '../../../branches/data/branch_epoch.dart';
import '../../../branches/data/branch_scope.dart';
import '../../data/local_directory/all_branches_ledger.dart';
import '../../data/local_directory/directory_pilot.dart';
import '../../data/local_directory/directory_scope.dart';

/// «جميع الفروع» is a read-only view: every add/edit/delete/transfer action
/// is hidden while it is selected. One switch for every screen.
final businessReadOnlyProvider = Provider<bool>((ref) {
  ref.watch(branchEpochProvider);
  return BranchScope.readOnly;
});

final _deviceLedgerProbeProvider = FutureProvider.family<bool, String>((
  ref,
  org,
) async {
  ref.watch(branchEpochProvider);
  final found = await ref.read(branchApiProvider).hasDeviceLedger(org);
  if (found) DeviceLedgerOrganizations.remember(org);
  return found;
});

/// The merged, read-only «جميع الفروع» view of a device-ledger organization
/// (the owner's own). Null in a single branch, for an employee, or when the
/// organization's data does not live on this device.
final businessAllBranchesProvider = Provider<BusinessAllBranches?>((ref) {
  if (!const bool.fromEnvironment('FYONA_BUSINESS_LEDGER_QA') ||
      !DirectoryPilotBuild.enabled) {
    return null;
  }
  ref.watch(branchEpochProvider);
  if (!BranchScope.allMode) return null;
  final auth = ref.watch(authProvider);
  final user = auth.user;
  final org = BranchScope.organizationId;
  final server = ref.watch(serverBaseUrlProvider);
  if (!auth.isAuthenticated ||
      user == null ||
      !user.hasPhone ||
      !user.isActive ||
      org == null ||
      org != user.organizationId ||
      server != DirectoryPilotBuild.baseUrl ||
      !DirectoryPilotBuild.signupEnabled ||
      !isDirectoryId(user.id) ||
      !isDirectoryId(org)) {
    return null;
  }
  if (!DeviceLedgerOrganizations.contains(org) &&
      ref.watch(_deviceLedgerProbeProvider(org)).valueOrNull != true) {
    return null;
  }
  final api = ref.watch(branchApiProvider);
  var alive = true;
  ref.onDispose(() => alive = false);
  return BusinessAllBranches(
    workspace: DirectoryWorkspace(
      server: server,
      accountId: user.id,
      organizationId: org,
    ),
    store: ref.watch(directoryPilotStoreProvider),
    // The owner's branches as this device knows them (also the ones born
    // offline); archived branches are not part of the merged view.
    branches: api.deviceBranchNames,
    isCurrent: () =>
        alive && BranchScope.allMode && BranchScope.organizationId == org,
  );
});
