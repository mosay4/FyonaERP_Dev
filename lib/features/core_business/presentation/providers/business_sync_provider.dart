import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/config/directory_pilot_build.dart';
import '../../../../core/di/providers.dart' show secureStorageProvider;
import '../../../../core/services/connectivity_service.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../../branches/data/branch_scope.dart';
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
///
/// * Sending: right after every local save (and on reconnect/resume).
/// * Receiving: a long poll held open by the relay, so the other device's work
///   shows up within a second or two while both are online.
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
  String? replica;
  Future<void>? registering;
  var pushing = false, pushAgain = false, listening = false;

  bool current() =>
      !cancel.isCancelled &&
      sameDirectoryScope(scope, ref.read(businessLocalLedgerScopeProvider));

  bool awake() =>
      current() &&
      network.isOnline &&
      WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused;

  Future<Map<String, dynamic>> send(
    String path,
    Map<String, Object?> body, {
    Duration? receive,
  }) async {
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
        receiveTimeout: receive,
        headers: {
          'Authorization': 'Bearer ${auth.accessToken}',
          // Names the organization this device works in (an employee works
          // in the employer's).
          if (BranchScope.token != null) 'X-Branch-Token': BranchScope.token!,
        },
      ),
    );
    final data = response.data?['data'];
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Invalid relay response');
    }
    return data;
  }

  /// A device the relay no longer knows (e.g. retired) registers again and
  /// rejoins with a full copy.
  void forgetOn403(Object error) {
    if (error is DioException && error.response?.statusCode == 403) {
      replica = null;
    }
  }

  Future<T> local<T>(Future<T> Function(DirectoryDatabase db) action) =>
      store.withSync(scope, action);

  void changed() {
    if (!current()) return;
    ref.read(businessSyncRevisionProvider.notifier).state++;
    ref.read(businessBankRevisionProvider.notifier).state++;
    ref.read(businessOperationsRevisionProvider.notifier).state++;
  }

  Future<String> ready() async {
    final known = replica;
    if (known != null) return known;
    await (registering ??= () async {
      final id = await local((db) => db.syncReplicaId());
      final user = ref.read(currentUserProvider);
      if (user != null) {
        await local(
          (db) => db.syncSetAuthor(
            userId: user.id,
            name: (user.fullName ?? user.username ?? '').trim(),
          ),
        );
      }
      final reg = await send('/register', {'replica_id': id});
      if (reg['resync_required'] == true) {
        await local((db) => db.syncMarkResync(true));
      }
      replica = id;
    }().whenComplete(() => registering = null));
    return replica!;
  }

  /// Everything saved here leaves the device; nothing made here is lost even
  /// before a resync.
  Future<void> push() async {
    final id = await ready();
    while (current()) {
      final out = await local((db) => db.syncOutbox(limit: 100));
      if (out.isEmpty) break;
      final reply = await send('/push', {
        'replica_id': id,
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
      await send('/snapshot/request', {'replica_id': id});
    }
  }

  void pushSoon() {
    if (!awake()) return;
    if (pushing) {
      pushAgain = true;
      return;
    }
    pushing = true;
    unawaited(() async {
      try {
        do {
          pushAgain = false;
          await push();
        } while (pushAgain && awake());
      } catch (error) {
        // Offline, expired login, server busy: it waits in the outbox.
        forgetOn403(error);
        if (error is DioException && error.response?.statusCode == 410) {
          // Access was removed: what was done here after that is cancelled,
          // and the user is told why.
          try {
            await local((db) => db.syncRejectOutbox());
            changed();
          } catch (_) {}
        }
      } finally {
        pushing = false;
      }
    }());
  }

  /// One receive round. Returns whether the relay had nothing more.
  Future<bool> receive({required int wait}) async {
    final id = await ready();
    final batch = await send(
      '/pull',
      {'replica_id': id, 'wait': wait},
      receive: Duration(seconds: wait + 20),
    );
    final items = [
      for (final raw in batch['items'] as List? ?? const [])
        Map<String, Object?>.from(raw as Map),
    ];
    if (batch['resync_required'] == true &&
        !await local((db) => db.syncResyncPending())) {
      await local((db) => db.syncMarkResync(true));
      await send('/snapshot/request', {'replica_id': id});
    }
    final ack = <String>[];
    final ops = <BusinessSyncDelivery>[];
    var stored = false;
    for (final item in items) {
      final payload = jsonDecode(
        utf8.decode(base64Decode(item['payload'] as String)),
      );
      switch (item['kind']) {
        case 'snapshot_request':
          final target = (payload as Map)['replica_id'] as String;
          final branches = (payload['branch_ids'] as List?)?.cast<String>();
          await push(); // a copy is complete only with nothing unsent
          final snapshot = await local(
            (db) => db.syncSnapshot(branchIds: branches?.toSet()),
          );
          if (snapshot == null) continue;
          await send('/snapshot/serve', {
            'replica_id': id,
            'target': target,
            'payload': snapshot,
          });
          ack.add(item['id'] as String);
        case 'snapshot':
          await local(
            (db) => db.syncApplySnapshot(Map<String, Object?>.from(payload as Map)),
          );
          await send('/snapshot/applied', {'replica_id': id});
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
    final drained = batch['drained'] == true;
    // Even with nothing new, a drained inbox lets this device decide its own
    // pending conflicts for good.
    if (ops.isNotEmpty || drained) {
      ack.addAll(
        await local(
          (db) => db.syncApply(
            ops,
            drained: drained,
            head: (batch['head'] as num?)?.toInt() ?? 0,
          ),
        ),
      );
      stored = stored || ops.isNotEmpty;
    }
    if (ack.isNotEmpty) {
      await send('/ack', {'replica_id': id, 'ids': ack});
    }
    if (stored) changed();
    return drained && items.isEmpty;
  }

  void listen() {
    if (listening || !awake()) return;
    listening = true;
    unawaited(() async {
      var quiet = false;
      try {
        while (awake()) {
          try {
            quiet = await receive(wait: quiet ? 20 : 0);
          } catch (error) {
            forgetOn403(error);
            quiet = false;
            if (!awake()) break;
            await Future<void>.delayed(const Duration(seconds: 5));
          }
        }
      } finally {
        listening = false;
      }
    }());
  }

  void wake() {
    pushSoon();
    listen();
  }

  final writes = businessSyncLocalWrites.stream.listen((_) => pushSoon());
  final subscription = network.onConnectivityChanged.listen((online) {
    if (online) wake();
  });
  final lifecycle = AppLifecycleListener(onResume: wake);
  final timer = Timer.periodic(const Duration(seconds: 30), (_) => wake());
  scheduleMicrotask(wake);
  ref.onDispose(() {
    cancel.cancel();
    writes.cancel();
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
