import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/config/directory_pilot_build.dart';
import '../../../../core/di/providers.dart' show secureStorageProvider;
import '../../../../core/services/connectivity_service.dart';
import '../../../branches/data/branch_epoch.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../data/local_directory/directory_pilot.dart';
import '../../data/local_directory/directory_scope.dart';
import '../../data/local_ledger/business_cash_delivery.dart';
import '../../data/local_ledger/business_cash_link_delivery.dart';
import '../../data/local_ledger/business_relay_identity.dart';
import 'business_ledger_session.dart';
import 'business_relay_http_provider.dart';

final _cashRelayRuntimeProvider = Provider.autoDispose<void>((ref) {
  if (!DirectoryPilotBuild.enabled || !businessCashRelayEnabled) return;
  ref.watch(branchEpochProvider);
  final scope = ref.watch(businessLocalLedgerScopeProvider);
  final bankDetails = ref.watch(employeeCanProvider('banks.details'));
  final bankBalances = ref.watch(employeeCanProvider('banks.balances'));
  if (scope == null ||
      scope.workspace.server != DirectoryPilotBuild.baseUrl ||
      !bankDetails ||
      !bankBalances)
    return;
  final network = ref.watch(connectivityServiceProvider);
  final http = ref.watch(businessRelayHttpProvider);
  final store = ref.watch(directoryPilotStoreProvider);
  final secure = ref.watch(secureStorageProvider);
  final cancel = CancelToken();
  var running = false;

  bool current() =>
      !cancel.isCancelled &&
      !BranchScope.allMode &&
      BranchScope.organizationId == scope.workspace.organizationId &&
      BranchScope.branchId == scope.branchId &&
      sameDirectoryScope(scope, ref.read(businessLocalLedgerScopeProvider)) &&
      ref.read(employeeCanProvider('banks.details')) &&
      ref.read(employeeCanProvider('banks.balances'));

  void tick() {
    if (running ||
        !current() ||
        !network.isOnline ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused)
      return;
    running = true;
    unawaited(() async {
      try {
        final session = await readBusinessCashSession(
          secure,
          scope.workspace.accountId,
        );
        if (session == null || !current()) return;
        Future<Map<String, Object?>> send(
          String path,
          Map<String, Object?>? body,
        ) async {
          final auth = await readBusinessRelayIdentity(
            secure,
            scope.workspace.accountId,
          );
          final token = BranchScope.token;
          if (auth == null ||
              auth.sessionId != session ||
              token == null ||
              !current() ||
              !network.isOnline) {
            throw const DirectoryAccessDenied();
          }
          final response = await http.request<Map<String, dynamic>>(
            '${scope.workspace.server}/business/cash-relay$path',
            data: body,
            cancelToken: cancel,
            options: Options(
              method: body == null ? 'GET' : 'POST',
              followRedirects: false,
              headers: {
                'Authorization': 'Bearer ${auth.accessToken}',
                'X-Branch-Token': token,
                // Comparison only; the authority derives identity from JWT.
                'X-Business-Replica-Session': session,
              },
            ),
          );
          if (!current() ||
              await readBusinessCashSession(
                    secure,
                    scope.workspace.accountId,
                  ) !=
                  session) {
            throw const DirectoryAccessDenied();
          }
          final data = response.data?['data'];
          if (data is! Map<String, dynamic>) {
            throw const FormatException('Invalid cash relay response');
          }
          return data;
        }

        void updated() {
          if (!current()) return;
          ref.read(businessBankRevisionProvider.notifier).state++;
          ref.read(businessOperationsRevisionProvider.notifier).state++;
        }

        if (scope.cashLinkId != null &&
            ref.read(employeeCanProvider('reconciliation.bank')) &&
            ref.read(employeeCanProvider('reconciliation.equalize'))) {
          final attached = await runBusinessCashLink(
            scope: scope,
            sessionId: session,
            store: store,
            request: send,
            current: () =>
                current() &&
                    ref.read(employeeCanProvider('reconciliation.bank')) &&
                    ref.read(employeeCanProvider('reconciliation.equalize'))
                ? ref.read(businessLocalLedgerScopeProvider)
                : null,
          );
          if (attached) updated();
        }
        await BusinessCashDelivery(
          scope: scope,
          sessionId: session,
          store: store,
          current: () => current() ? scope : null,
          changed: updated,
          send: (action, body) => send('/v2/${action.name}', body),
          sendV3: (action, body) => send('/v3/${action.name}', body),
        ).runOnce();
      } catch (_) {
        // Unadmitted replicas do no network I/O. Transport failures retain the
        // outbox; local save/feedback never depend on this background cycle.
      } finally {
        running = false;
      }
    }());
  }

  final subscription = network.onConnectivityChanged.listen((online) {
    if (online) tick();
  });
  final lifecycle = AppLifecycleListener(onResume: tick);
  final timer = Timer.periodic(const Duration(seconds: 30), (_) => tick());
  ref.listen(businessBankRevisionProvider, (_, __) => tick());
  scheduleMicrotask(tick);
  ref.onDispose(() {
    cancel.cancel();
    subscription.cancel();
    lifecycle.dispose();
    timer.cancel();
  });
});

/// This listener exists only inside the Business UI and requires a local
/// checkpoint. It never provisions a previously single-device branch.
class BusinessCashRelayRuntime extends ConsumerWidget {
  const BusinessCashRelayRuntime({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(_cashRelayRuntimeProvider);
    return child;
  }
}
