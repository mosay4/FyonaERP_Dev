import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'branch_scope.dart';

/// Raised only after the revoked workspace's persisted scope has been cleared.
final branchRevocationProvider = StateProvider<int>((ref) => 0);
final merchantSubscriptionBlockedScopeProvider = StateProvider<String?>(
  (ref) => null,
);

bool _clearing = false;

/// A delayed error from a previously selected company must not eject the user
/// from a different company they have since switched to.
Future<bool> clearRevokedBranchScope(String? requestToken) async {
  if (_clearing ||
      requestToken == null ||
      requestToken.isEmpty ||
      requestToken != BranchScope.token)
    return false;
  _clearing = true;
  try {
    final owner = BranchScope.selectionOwner;
    try {
      await BranchScope.save(
        token: null,
        branchId: null,
        branchName: null,
        allMode: false,
        stillSelected: () => requestToken == BranchScope.token,
      );
    } on StateError {
      if (requestToken != BranchScope.token) return false;
      rethrow;
    }
    await BranchScope.setHasMembership(false);
    if (owner != null) await BranchScope.forgetNavigationCache(owner);
    return true;
  } finally {
    _clearing = false;
  }
}
