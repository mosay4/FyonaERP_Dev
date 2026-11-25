import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/database/repositories/personal_cache_repository.dart';
import '../../../../core/di/providers.dart' show apiClientProvider;
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/network/network_quality_interceptor.dart';
import '../../../../core/services/connectivity_service.dart';
import '../../../../core/services/sync_engine.dart' show syncEngineProvider;
import '../../../../shared/providers/current_user_provider.dart';
import '../../data/ledger/personal_ledger.dart';
import '../../data/ledger/personal_local_cutover.dart';
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

/// The one-time move endpoints (`/personal-local`) through the API client.
final class PersonalLocalHttp implements PersonalLocalTransport {
  PersonalLocalHttp(this.client, this.cancel);

  final ApiClient client;
  final CancelToken cancel;

  Future<Map<String, dynamic>> _call(Future<Response<dynamic>> Function() send) async {
    try {
      final raw = (await send()).data;
      final data = raw is Map ? raw['data'] : null;
      if (data is Map) return Map<String, dynamic>.from(data);
      throw const PersonalLocalHttpError(0, 'invalid answer');
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final body = e.response?.data;
      throw PersonalLocalHttpError(
        status,
        body is Map ? '${body['message'] ?? body['detail'] ?? ''}' : null,
      );
    }
  }

  @override
  Future<Map<String, dynamic>> get(String path) =>
      _call(() => client.get<dynamic>('/personal-local$path', cancelToken: cancel));

  @override
  Future<Map<String, dynamic>> post(String path, Map<String, Object?> body) =>
      _call(() => client.post<dynamic>(
            '/personal-local$path',
            data: body,
            cancelToken: cancel,
            options: Options(receiveTimeout: const Duration(seconds: 120)),
          ));
}

/// Carries this user's Personal operations between their devices
/// ([PersonalRelaySync]): sends right after every local save, receives with
/// a long poll, and every 10 s / on reconnect / on resume. Skipped while
/// offline (a very poor link counts as offline). Saving never waits for it.
/// It also runs the one-time cutover of the user's old server Personal data
/// ([PersonalLocalCutover]); after it the old server sync is off.
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
  var cutting = false, cutoverDone = false, noticeChecked = false;
  // The last relay round found nothing more (the cutover import waits).
  var relayQuiet = false;
  PersonalLocalMode.oldSyncRetired = false;
  PersonalLocalMode.serverDeclined = false;

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

  /// The one-time move of the old server Personal data (resumable).
  void cutover() {
    if (cutting || cutoverDone || !awake()) return;
    cutting = true;
    unawaited(() async {
      try {
        final db = await PersonalLedger.active();
        if (PersonalLedger.owner != user.id || !current()) return;
        final done = await PersonalLocalCutover(
          db: db,
          transport: PersonalLocalHttp(client, cancel),
          namespace: PersonalCacheRepository.stableIdSync(user.id),
          drain: () => ref.read(syncEngineProvider).processQueue(),
          relayIdle: () async =>
              relayQuiet && !await (await engine()).store.hasParked(),
        ).run();
        if (done && current()) {
          cutoverDone = true;
          changed();
        }
      } catch (_) {
        // Tried again on the next wake.
      } finally {
        cutting = false;
      }
    }());
  }

  /// A new device that found no other device to copy from: suggest (once)
  /// restoring a local backup.
  Future<void> checkGaveUp(PersonalRelaySync s) async {
    if (noticeChecked) return;
    if (await s.store.resync() != 'gave_up') return;
    noticeChecked = true;
    if (await s.store.read('notice_restore') == '1') return;
    await s.store.write('notice_restore', '1');
    if (current()) {
      PersonalLocalMode.notice.value ??= PersonalLocalNotice.restoreBackup;
    }
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
            await checkGaveUp(s);
            quiet = round.quiet;
            relayQuiet = round.quiet;
            if (quiet && !cutoverDone) cutover();
          } catch (error) {
            failed(error);
            quiet = false;
            relayQuiet = false;
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
    cutover();
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
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        const Positioned(
          left: 12,
          right: 12,
          bottom: 24,
          child: PersonalLocalNoticeBar(),
        ),
      ],
    );
  }
}

/// A calm, dismissible note about device-only Personal data
/// ([PersonalLocalMode.notice]): restore a local backup on a device that
/// found no other device, the old data move still retrying, or «update the
/// app» when the server says so.
class PersonalLocalNoticeBar extends StatelessWidget {
  const PersonalLocalNoticeBar({super.key});

  static String text(PersonalLocalNotice n) => switch (n) {
        PersonalLocalNotice.restoreBackup =>
          AppLocalizations.t('personalLocalNoticeRestore'),
        PersonalLocalNotice.cutoverFailing =>
          AppLocalizations.t('personalLocalNoticeRetrying'),
        PersonalLocalNotice.updateRequired =>
          AppLocalizations.t('personalLocalNoticeUpdate'),
      };

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PersonalLocalNotice?>(
      valueListenable: PersonalLocalMode.notice,
      builder: (context, notice, _) {
        if (notice == null) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Material(
          key: const ValueKey('personal-local-notice'),
          elevation: 3,
          borderRadius: BorderRadius.circular(14),
          color: scheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(14, 8, 4, 8),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(child: Text(text(notice))),
                if (notice == PersonalLocalNotice.restoreBackup)
                  TextButton(
                    onPressed: () {
                      PersonalLocalMode.notice.value = null;
                      try {
                        GoRouter.of(context).push('/personal/backup');
                      } catch (_) {}
                    },
                    child: Text(AppLocalizations.t('personalLocalNoticeRestoreAction')),
                  ),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => PersonalLocalMode.notice.value = null,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
