import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/di/providers.dart' show secureStorageProvider;
import '../../../../core/network/api_client.dart' show serverBaseUrlProvider;
import '../../../../core/services/connectivity_service.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../branches/data/branch_epoch.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../core_business/data/local_directory/directory_database.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../../core_business/data/local_directory/directory_secure_storage.dart';
import '../../../core_business/data/local_ledger/business_relay_identity.dart';
import '../../../core_business/presentation/providers/business_relay_http_provider.dart';
import '../../data/employee_device_finance.dart';

bool employeeSelfWorkspaceRoute(String path, {bool readOnly = false}) =>
    path == '/employee-profile' ||
    path == '/employee-profile/receipt' ||
    path == '/job-requests' ||
    (readOnly && (path == '/employees/salary' || path == '/employees/debts'));

EmployeeReadSelection? _selection(String server, String? account) =>
    account == null
    ? null
    : resolveEmployeeReadSelection(
        server: server,
        account: account,
        organization: BranchScope.organizationId,
        branch: BranchScope.branchId,
        token: BranchScope.token,
        allMode: BranchScope.allMode,
      );

final employeeDeviceSelectionProvider = Provider<EmployeeReadSelection?>((ref) {
  if (!employeeDeviceFinanceEnabled) return null;
  ref.watch(branchEpochProvider);
  ref.watch(branchTokenRefreshProvider);
  final account = ref.watch(
    authProvider.select(
      (auth) =>
          auth.isAuthenticated &&
              auth.user?.hasPhone == true &&
              auth.user?.isActive == true
          ? auth.user?.id
          : null,
    ),
  );
  return _selection(ref.watch(serverBaseUrlProvider), account);
});

final employeeDeviceCacheProvider = Provider<BusinessEmployeeReadCache>((ref) {
  final cache = BusinessEmployeeReadCache(
    () async => Directory(
      p.join((await businessDirectoryRoot()).path, 'employee_read_v1'),
    ),
    const _EmployeeKeys(),
  );
  ref.onDispose(() => unawaited(cache.close()));
  return cache;
});

class _EmployeeKeys implements DirectoryKeyStore {
  const _EmployeeKeys();
  @override
  Future<String?> read(String id) =>
      const SecureDirectoryKeys().read('employee-read-$id');
  @override
  Future<void> write(String id, String key) =>
      const SecureDirectoryKeys().write('employee-read-$id', key);
}

DirectoryWorkspace _workspace(EmployeeReadSelection scope) =>
    DirectoryWorkspace(
      server: scope.server,
      accountId: scope.account,
      organizationId: scope.organization,
    );

final _copyRevision = StateProvider<int>((ref) => 0);
final employeeDeviceCopyProvider =
    FutureProvider.autoDispose<EmployeeReadCopy?>((ref) async {
      final scope = ref.watch(employeeDeviceSelectionProvider);
      if (scope == null) return null;
      ref.watch(_copyRevision);
      final cache = ref.watch(employeeDeviceCacheProvider);
      final secure = ref.watch(secureStorageProvider);
      var active = true;
      Timer? expiry;
      ref.onDispose(() {
        active = false;
        expiry?.cancel();
      });
      final first = await readBusinessRelayIdentity(secure, scope.account);
      if (!active || first == null) return null;
      final data = await cache.read(_workspace(scope), scope.branch);
      final last = await readBusinessRelayIdentity(secure, scope.account);
      if (!active ||
          last?.sessionId != first.sessionId ||
          _selection(scope.server, scope.account) != scope) {
        return null;
      }
      final copy = EmployeeReadCopy.parse(data, scope, first.sessionId);
      if (copy != null)
        expiry = Timer(
          copy.expires.difference(DateTime.now()),
          ref.invalidateSelf,
        );
      return copy;
    });

final _runtime = Provider.autoDispose<void>((ref) {
  if (!employeeDeviceFinanceEnabled) return;
  final member = ref.watch(employeeDeviceSelectionProvider);
  final owner = ref.watch(businessLocalLedgerScopeProvider);
  if (owner == null && member == null) return;
  final container = ref.container;
  final server = member?.server ?? owner!.workspace.server;
  final account = member?.account ?? owner!.workspace.accountId;
  final secure = ref.watch(secureStorageProvider);
  final network = ref.watch(connectivityServiceProvider);
  final ownerStore = owner == null
      ? null
      : ref.watch(directoryPilotStoreProvider);
  final cache = member == null ? null : ref.watch(employeeDeviceCacheProvider);
  bool current() => member != null
      ? _selection(server, account) == member &&
            container.read(employeeDeviceSelectionProvider) == member
      : !BranchScope.readOnly &&
            BranchScope.organizationId == owner!.workspace.organizationId &&
            BranchScope.branchId == owner.branchId &&
            sameDirectoryScope(
              owner,
              container.read(businessLocalLedgerScopeProvider),
            );
  final http = EmployeeFinanceTransport(
    ref.watch(businessRelayHttpProvider),
    server,
    () => readBusinessRelayIdentity(secure, account),
    () => current() ? BranchScope.token : null,
  );
  final sent = <String, String>{};
  var busy = false;
  Future<void> tick() async {
    if (busy || !http.active || !network.isOnline || !current()) return;
    busy = true;
    final token = BranchScope.token;
    bool selected() => http.active && current() && BranchScope.token == token;
    try {
      final auth = await http.identity();
      if (!selected() || auth == null) return;
      if (member != null) {
        Map<String, dynamic>? data;
        try {
          data = await http.request(auth, 'GET', '/me');
          if (EmployeeReadCopy.parse(data, member, auth.sessionId) == null)
            return;
        } on DioException catch (error) {
          if (!const {401, 403, 404}.contains(error.response?.statusCode))
            return;
          // A live denial replaces the copy, not just the screen in memory.
        }
        if (!selected() || (await http.identity())?.sessionId != auth.sessionId)
          return;
        final changed = await cache!.replace(
          _workspace(member),
          member.branch,
          data,
          current: selected,
        );
        if (changed && selected())
          container.read(_copyRevision.notifier).state++;
        return;
      }
      final result = await http.request(auth, 'GET', '/owner');
      for (final target in (result['targets'] as List).whereType<Map>()) {
        if (!selected() || !network.isOnline) return;
        final id = target['employee_id'];
        if (id is! String || !isDirectoryId(id)) continue;
        try {
          final grant = BusinessLedgerAccess(owner!, {
            BusinessLedgerAction.readEmployeeFinance,
          });
          final rows = await ownerStore!.withLedger(
            grant,
            () => selected() ? owner : null,
            (ledger) => ledger.employeeDeliveryReceipts(grant, id),
          );
          final revision = target['grant_revision'];
          final fingerprint = jsonEncode([auth.sessionId, revision, rows]);
          if (!selected() || !network.isOnline || sent[id] == fingerprint)
            continue;
          await http.request(
            auth,
            'PUT',
            '/owner/$id',
            body: {
              'grant_revision': revision,
              'expected_version': target['version'],
              'receipts': rows,
            },
          );
          sent[id] = fingerprint;
        } catch (_) {
          // One denied employee or a lost response must not block the others.
        }
      }
    } catch (_) {
      // Publication and refresh are outside all employee/owner saves.
    } finally {
      busy = false;
    }
  }

  final changes = network.onConnectivityChanged.listen((online) {
    if (online) unawaited(tick());
  });
  final lifecycle = AppLifecycleListener(onResume: () => unawaited(tick()));
  final poll = Timer.periodic(const Duration(seconds: 15), (_) {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused)
      unawaited(tick());
  });
  scheduleMicrotask(tick);
  ref.onDispose(() {
    http.dispose();
    unawaited(changes.cancel());
    lifecycle.dispose();
    poll.cancel();
  });
});

class EmployeeDeviceFinanceRuntime extends ConsumerWidget {
  const EmployeeDeviceFinanceRuntime({required this.child, super.key});
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(_runtime);
    return child;
  }
}
