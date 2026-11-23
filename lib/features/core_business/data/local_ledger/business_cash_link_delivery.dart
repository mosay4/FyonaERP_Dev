import '../local_directory/directory_database.dart';
import '../local_directory/directory_pilot.dart';
import '../local_directory/directory_scope.dart';

typedef CashLinkRequest =
    Future<Map<String, Object?>> Function(
      String path,
      Map<String, Object?>? body,
    );

/// The background adapter used by both the Business app and the live QA probe.
/// HTTP is outside SQLCipher; a failed prepare response is always retryable.
Future<bool> runBusinessCashLink({
  required DirectoryAccess scope,
  required String sessionId,
  required DirectoryPilotStore store,
  required DirectoryAccess? Function() current,
  required CashLinkRequest request,
}) async {
  if (scope.cashLinkId == null) return false;
  DirectoryAccess? allowedScope() {
    final currentScope = current();
    return currentScope?.cashLinkId == scope.cashLinkId &&
            currentScope?.financialCutover == true &&
            sameDirectoryScope(scope, currentScope)
        ? currentScope
        : null;
  }

  final grant = BusinessLedgerAccess(scope, {
    BusinessLedgerAction.syncCash,
  }, cashSessionId: sessionId);
  final bound = await store.withLedger(
    grant,
    allowedScope,
    (ledger) => ledger.cashSync.replicaCheckpoint(grant, sessionId),
  );
  if (bound != null) return false;

  Future<Map<String, Object?>?> apply(BusinessCashLink link) =>
      store.withLedger(
        grant,
        allowedScope,
        (ledger) => ledger.cashSync.reconcileLink(
          grant,
          link,
          allowed: () => allowedScope() != null,
        ),
      );

  final link = BusinessCashLink.parse(
    await request('/link', null),
    scope,
    sessionId,
  );
  final receipt = await apply(link);
  if (link.state != 'pending') return link.state == 'ready';
  if (receipt == null) return false;
  if (allowedScope() == null) throw const DirectoryAccessDenied();
  final saved = BusinessCashLink.parse(
    await request('/link/prepared', receipt),
    scope,
    sessionId,
  );
  if (saved.state != 'pending') await apply(saved);
  return saved.state == 'ready';
}
