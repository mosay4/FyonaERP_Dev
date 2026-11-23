import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart' show secureStorageProvider;
import '../../../../core/services/connectivity_service.dart';
import '../../../branches/data/branch_epoch.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../data/local_directory/directory_pilot.dart';
import '../../data/local_ledger/business_party_sharing.dart';
import '../../data/local_ledger/business_relay_identity.dart';
import 'business_ledger_session.dart';
import 'business_relay_http_provider.dart';

final businessPartyShareRevisionProvider = StateProvider<int>((ref) => 0);

final localBusinessPartySharingProvider = Provider<BusinessPartySharing?>((
  ref,
) {
  ref.watch(branchEpochProvider);
  final scope = ref.watch(businessLocalLedgerScopeProvider);
  if (scope == null) return null;
  final container = ref.container;
  var active = true;
  final secure = ref.watch(secureStorageProvider);
  bool selected() =>
      active &&
      !BranchScope.allMode &&
      !BranchScope.readOnly &&
      BranchScope.branchId == scope.branchId &&
      BranchScope.organizationId == scope.workspace.organizationId;
  final service = BusinessPartySharing(
    ref.watch(businessRelayHttpProvider),
    ref.watch(directoryPilotStoreProvider),
    scope,
    () => selected() ? container.read(businessLocalLedgerScopeProvider) : null,
    () => selected() ? BranchScope.token : null,
    (p) => active && container.read(employeeCanProvider(p)),
    () => active && container.read(connectivityServiceProvider).isOnline,
    () {
      if (selected())
        container.read(businessPartyShareRevisionProvider.notifier).state++;
    },
    () => active
        ? readBusinessRelayIdentity(secure, scope.workspace.accountId)
        : Future.value(null),
  );
  ref.onDispose(() {
    active = false;
    service.dispose();
  });
  return service;
});

final _partyShareRuntimeProvider = Provider.autoDispose<void>((ref) {
  final service = ref.watch(localBusinessPartySharingProvider);
  if (service == null) return;
  final network = ref.watch(connectivityServiceProvider);
  var active = true;
  void tick() {
    if (!active ||
        !network.isOnline ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused)
      return;
    unawaited(
      service.refresh().catchError((Object _) {
        // A publication retry is independent of local saves and UI reads.
      }),
    );
  }

  final listener = network.onConnectivityChanged.listen((online) {
    if (online) tick();
  });
  final lifecycle = AppLifecycleListener(onResume: tick);
  final poll = Timer.periodic(const Duration(seconds: 30), (_) => tick());
  ref.listen(businessBankRevisionProvider, (_, __) => tick());
  ref.listen(businessOperationsRevisionProvider, (_, __) => tick());
  scheduleMicrotask(tick);
  ref.onDispose(() {
    active = false;
    listener.cancel();
    lifecycle.dispose();
    poll.cancel();
  });
});

/// Lives inside the Business shell only, not the Personal runtime or queue.
class BusinessPartyShareRuntime extends ConsumerWidget {
  const BusinessPartyShareRuntime({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(_partyShareRuntimeProvider);
    return child;
  }
}
