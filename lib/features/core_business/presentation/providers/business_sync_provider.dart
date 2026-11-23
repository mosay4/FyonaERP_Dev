import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/config/directory_pilot_build.dart';
import '../../../../core/di/providers.dart' show secureStorageProvider;
import '../../../../core/services/connectivity_service.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../data/local_directory/directory_database.dart';
import '../../data/local_directory/directory_pilot.dart';
import '../../data/local_directory/directory_scope.dart';
import '../../data/local_ledger/business_relay_identity.dart';
import 'business_ledger_session.dart';
import 'business_relay_http_provider.dart';

/// Bumped whenever operations from other devices were stored here, so open
/// screens re-read the local database (no network wait, no spinner).
final businessSyncRevisionProvider = StateProvider<int>((ref) => 0);

/// Unread system notices (e.g. an operation cancelled because another device
/// did the same thing first).
final businessSyncNoticesProvider =
    FutureProvider<List<BusinessSyncNotice>>((ref) async {
      ref.watch(businessSyncRevisionProvider);
      final scope = ref.watch(businessLocalLedgerScopeProvider);
      if (scope == null) return const [];
      final store = ref.watch(directoryPilotStoreProvider);
      return store.withSync(scope, (db) => db.syncNotices());
    });

Future<void> markBusinessSyncNoticesRead(Ref ref) async {
  try {
    final scope = ref.read(businessLocalLedgerScopeProvider);
    if (scope == null) return;
    await ref
        .read(directoryPilotStoreProvider)
        .withSync(scope, (db) => db.syncMarkNoticesRead());
    ref.read(businessSyncRevisionProvider.notifier).state++;
  } catch (_) {}
}

/// Moves this device's Business operations to the relay and stores the
/// operations of the other devices. Saving never waits for it.
final _businessSyncRuntimeProvider = Provider.autoDispose<void>((ref) {
  if (!DirectoryPilotBuild.enabled) return;
  final scope = ref.watch(businessLocalLedgerScopeProvider);
  if (scope == null || scope.workspace.server != DirectoryPilotBuild.baseUrl) {
    return;
  }
  final network = ref.watch(connectivityServiceProvider);
  final http = ref.watch(businessRelayHttpProvider);
  final store = ref.watch(directoryPilotStoreProvider);
  final secure = ref.watch(secureStorageProvider);
  final cancel = CancelToken();
  var running = false;
  var again = false;
  var registered = false;

  bool current() =>
      !cancel.isCancelled &&
      sameDirectoryScope(scope, ref.read(businessLocalLedgerScopeProvider));

  Future<Map<String, dynamic>> send(String path, Map<String, Object?> body) async {
    final auth = await readBusinessRelayIdentity(
      secure,
      scope.workspace.accountId,
    );
    if (auth == null || !current() || !network.isOnline) {
      throw const DirectoryAccessDenied();
    }
    final response = await http.post<Map<String, dynamic>>(
      '${scope.workspace.server}/business-relay$path',
      data: body,
      cancelToken: cancel,
      options: Options(
        followRedirects: false,
        headers: {'Authorization': 'Bearer ${auth.accessToken}'},
      ),
    );
    final data = response.data?['data'];
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Invalid relay response');
    }
    return data;
  }

  Future<T> local<T>(Future<T> Function(DirectoryDatabase db) action) =>
      store.withSync(scope, action);

  void changed() {
    if (!current()) return;
    ref.read(businessSyncRevisionProvider.notifier).state++;
    ref.read(businessBankRevisionProvider.notifier).state++;
    ref.read(businessOperationsRevisionProvider.notifier).state++;
  }

  Future<void> cycle() async {
    final replica = await local((db) => db.syncReplicaId());
    final user = ref.read(currentUserProvider);
    if (user != null) {
      await local(
        (db) => db.syncSetAuthor(
          userId: user.id,
          name: (user.fullName ?? user.username ?? '').trim(),
        ),
      );
    }
    if (!registered) {
      final reg = await send('/register', {'replica_id': replica});
      registered = true;
      if (reg['resync_required'] == true) {
        await local((db) => db.syncMarkResync(true));
      }
    }
    // 1) What this device did goes out first — even before a resync, so
    //    nothing made here is lost.
    while (current()) {
      final out = await local((db) => db.syncOutbox(limit: 100));
      if (out.isEmpty) break;
      final reply = await send('/push', {
        'replica_id': replica,
        'items': [
          for (final op in out)
            {'id': op.id, 'branch_id': op.branchId, 'kind': 'ops', 'payload': op.payload},
        ],
      });
      await local(
        (db) => db.syncPushed({
          for (final item in reply['items'] as List)
            '${(item as Map)['id']}': item['seq'] as int,
        }),
      );
    }
    if (await local((db) => db.syncResyncPending())) {
      await send('/snapshot/request', {'replica_id': replica});
    }
    // 2) What the other devices did comes in, in arrival order.
    var stored = false;
    while (current()) {
      final batch = await send('/pull', {'replica_id': replica});
      final items = [
        for (final raw in batch['items'] as List? ?? const [])
          Map<String, Object?>.from(raw as Map),
      ];
      if (batch['resync_required'] == true &&
          !await local((db) => db.syncResyncPending())) {
        await local((db) => db.syncMarkResync(true));
        await send('/snapshot/request', {'replica_id': replica});
      }
      if (items.isEmpty) break;
      final ack = <String>[];
      final ops = <BusinessSyncDelivery>[];
      for (final item in items) {
        final payload = jsonDecode(
          utf8.decode(base64Decode(item['payload'] as String)),
        );
        switch (item['kind']) {
          case 'snapshot_request':
            final target = (payload as Map)['replica_id'] as String;
            final snapshot = await local((db) => db.syncSnapshot());
            // With unsent work the copy would be incomplete: answer later.
            if (snapshot == null) continue;
            await send('/snapshot/serve', {
              'replica_id': replica,
              'target': target,
              'payload': snapshot,
            });
            ack.add(item['id'] as String);
          case 'snapshot':
            await local(
              (db) => db.syncApplySnapshot(Map<String, Object?>.from(payload as Map)),
            );
            await send('/snapshot/applied', {'replica_id': replica});
            ack.add(item['id'] as String);
            stored = true;
          default:
            ops.add((
              id: item['id'] as String,
              seq: item['seq'] as int?,
              kind: 'ops',
              branchId: item['branch_id'] as String?,
              payload: Map<String, Object?>.from(payload as Map),
            ));
        }
      }
      if (ops.isNotEmpty) {
        ack.addAll(
          await local(
            (db) => db.syncApply(
              ops,
              drained: batch['drained'] == true,
              head: (batch['head'] as num?)?.toInt() ?? 0,
            ),
          ),
        );
        stored = true;
      }
      if (ack.isNotEmpty) {
        await send('/ack', {'replica_id': replica, 'ids': ack});
      }
      if (batch['drained'] == true) break;
    }
    if (stored) changed();
  }

  void tick() {
    if (!current() ||
        !network.isOnline ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused) {
      return;
    }
    if (running) {
      again = true;
      return;
    }
    running = true;
    unawaited(() async {
      try {
        do {
          again = false;
          await cycle();
        } while (again && current());
      } catch (_) {
        // Offline, expired login, server busy: everything waits safely in the
        // local outbox/inbox and the next tick carries on. Saving and every
        // text the user sees never depend on this cycle.
      } finally {
        running = false;
      }
    }());
  }

  final subscription = network.onConnectivityChanged.listen((online) {
    if (online) tick();
  });
  final lifecycle = AppLifecycleListener(onResume: tick);
  final timer = Timer.periodic(const Duration(seconds: 15), (_) => tick());
  // A local save goes out as soon as possible.
  ref.listen(businessBankRevisionProvider, (_, _) => tick());
  ref.listen(businessOperationsRevisionProvider, (_, _) => tick());
  scheduleMicrotask(tick);
  ref.onDispose(() {
    cancel.cancel();
    subscription.cancel();
    lifecycle.dispose();
    timer.cancel();
  });
});

/// Mounted once inside the Business UI.
class BusinessSyncRuntime extends ConsumerWidget {
  const BusinessSyncRuntime({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(_businessSyncRuntimeProvider);
    return child;
  }
}
