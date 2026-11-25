import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/repositories/personal_cache_repository.dart';
import '../../../../core/di/providers.dart' show apiClientProvider;
import '../../../../core/network/api_client.dart';
import '../../../../core/network/network_quality_interceptor.dart';
import '../../../../core/services/connectivity_service.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../data/ledger/personal_ledger.dart';
import '../../data/ledger/personal_relay_config.dart';
import '../../data/ledger/personal_relay_store.dart';
import '../../data/ledger/personal_relay_sync.dart';
import '../../di/personal_providers.dart' show personalFinanceServiceProvider;
import 'financial_tree_provider.dart';
import 'personal_providers.dart';

/// Bumped whenever another device's Personal changes were stored here.
final personalRelayRevisionProvider = StateProvider<int>((ref) => 0);

/// The relay endpoints through the app's API client (Bearer login).
final class PersonalRelayHttp implements PersonalRelayTransport {
  PersonalRelayHttp(this.client, this.cancel);

  final ApiClient client;
  final CancelToken cancel;

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, Object?> body, {
    Duration? receive,
  }) async {
    try {
      final response = await client.post<dynamic>(
        '/personal-relay$path',
        data: body,
        cancelToken: cancel,
        options: Options(
          receiveTimeout: receive,
          // A held long poll says nothing about the network quality.
          extra: {
            if (receive != null && receive > const Duration(seconds: 20))
              NetworkQualityInterceptor.skipKey: true,
          },
        ),
      );
      final raw = response.data;
      final data = raw is Map ? raw['data'] : null;
      if (data is Map) return Map<String, dynamic>.from(data);
      if (raw is Map && raw['success'] == true) return const {};
      throw const FormatException('Invalid relay response');
    } on DioException catch (e) {
      if (e.response?.statusCode == 403) throw const PersonalRelayForbidden();
      rethrow;
    }
  }
}

/// Carries this user's Personal operations between their devices
/// ([PersonalRelaySync]): sends right after every local save, receives with
/// a long poll, and every 10 s / on reconnect / on resume. Skipped while
/// offline (a very poor link counts as offline). Saving never waits for it.
/// The old server sync keeps running beside it until the Stage 6 cutover.
final _personalRelayRuntimeProvider = Provider.autoDispose<void>((ref) {
  if (!PersonalRelayConfig.enabled) return;
  final user = ref.watch(currentUserProvider);
  if (user == null || user.id.isEmpty) return;
  final network = ref.watch(connectivityServiceProvider);
  final client = ref.watch(apiClientProvider);
  final cancel = CancelToken();
  final transport = PersonalRelayHttp(client, cancel);
  PersonalRelaySync? sync;
  PersonalLedgerDatabase? syncDb;
  var pushing = false, pushAgain = false, listening = false;

  bool current() =>
      !cancel.isCancelled && ref.read(currentUserProvider)?.id == user.id;

  bool awake() =>
      current() &&
      network.isOnline &&
      WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused;

  Future<PersonalRelaySync> engine() async {
    final db = await PersonalLedger.active();
    if (PersonalLedger.owner != user.id) {
      throw const PersonalLedgerUnavailable('other_user');
    }
    final known = sync;
    if (known != null && identical(syncDb, db) && !db.isClosed) return known;
    syncDb = db;
    return sync = PersonalRelaySync(
      store: PersonalRelayStore(db),
      transport: transport,
      namespace: PersonalCacheRepository.stableIdSync(user.id),
    );
  }

  void changed() {
    if (!current()) return;
    ref.read(personalRelayRevisionProvider.notifier).state++;
    // Screens re-read the device copy.
    unawaited(ref.read(personalFinanceProvider.notifier).load());
    unawaited(ref.read(budgetProvider.notifier).load());
    unawaited(ref.read(recurringProvider.notifier).load());
    unawaited(ref.read(categoryProvider.notifier).load());
    try {
      unawaited(ref.read(financialTreeProvider.notifier).refresh());
    } catch (_) {}
  }

  void failed(Object error) {
    if (error is PersonalRelayForbidden) sync?.forget();
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
          await (await engine()).push();
        } while (pushAgain && awake());
      } catch (error) {
        // Offline, expired login, server busy: it waits in the outbox.
        failed(error);
      } finally {
        pushing = false;
      }
    }());
  }

  void listen() {
    if (listening || !awake()) return;
    listening = true;
    unawaited(() async {
      var quiet = false;
      try {
        while (awake()) {
          try {
            final s = await engine();
            final round = await s.receive(wait: quiet ? 20 : 0);
            if (s.snapshotApplied) {
              s.snapshotApplied = false;
              // Both copies may hold the same cash currency: keep one.
              try {
                await ref
                    .read(personalFinanceServiceProvider)
                    .sweepDuplicateCashAccounts();
              } catch (_) {}
            }
            if (round.changed) changed();
            quiet = round.quiet;
          } catch (error) {
            failed(error);
            quiet = false;
            if (!awake()) break;
            await Future<void>.delayed(const Duration(seconds: 10));
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

  final writes = PersonalRelayCapture.localWrites.stream.listen((_) => pushSoon());
  final connectivity = network.onConnectivityChanged.listen((online) {
    if (online) wake();
  });
  final lifecycle = AppLifecycleListener(onResume: wake);
  final timer = Timer.periodic(const Duration(seconds: 10), (_) => wake());
  scheduleMicrotask(wake);
  ref.onDispose(() {
    cancel.cancel();
    writes.cancel();
    connectivity.cancel();
    lifecycle.dispose();
    timer.cancel();
  });
});

/// Mounted once inside the signed-in app (Personal and Business modes: the
/// Personal ledger belongs to the user either way).
class PersonalRelayRuntime extends ConsumerWidget {
  const PersonalRelayRuntime({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(_personalRelayRuntimeProvider);
    return child;
  }
}
