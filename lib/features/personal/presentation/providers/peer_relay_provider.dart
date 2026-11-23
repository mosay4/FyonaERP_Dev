import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart' show apiClientProvider;
import '../../../../core/services/connectivity_service.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../data/merchant_api.dart';
import '../../data/peer_store.dart';

/// Bumped when a linked merchant's debts or a conversation changed on this
/// device, so open screens re-read the device copy.
final peerRevisionProvider = StateProvider<int>((ref) => 0);

/// Receives what linked merchants/parties sent through the peer relay, keeps
/// it on this device, acknowledges it (the relay then deletes it), and sends
/// chat written offline as soon as the connection is back.
final _peerRelayRuntimeProvider = Provider.autoDispose<void>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) return;
  final network = ref.watch(connectivityServiceProvider);
  final client = ref.watch(apiClientProvider);
  final store = PeerStore.of(user.id);
  var running = false, alive = true, registered = false;

  Future<void> cycle() async {
    final device = await PeerStore.deviceId();
    if (!registered) {
      await client.post('/peer-relay/register', data: {'device_id': device});
      registered = true;
    }
    await ref.read(merchantApiProvider).sendQueuedChat();
    final r = await client.post('/peer-relay/pull', data: {'device_id': device});
    final data = r.data is Map ? (r.data as Map)['data'] : null;
    final items = (data is Map ? data['items'] : null) as List? ?? const [];
    if (items.isEmpty) return;
    final ack = <String>[];
    for (final raw in items.whereType<Map>()) {
      try {
        final payload = jsonDecode(utf8.decode(base64Decode('${raw['payload']}')));
        final link = '${raw['link_id']}';
        switch (raw['kind']) {
          case 'debt_snapshot':
            await store.saveDebtSnapshot(link, Map<String, dynamic>.from(payload as Map));
          case 'chat':
            await store.mergeChat(link, [Map<String, dynamic>.from(payload as Map)]);
        }
        ack.add('${raw['id']}');
      } catch (_) {
        // Unreadable here: leave it for a newer app version.
      }
    }
    if (ack.isNotEmpty) {
      await client.post('/peer-relay/ack', data: {'device_id': device, 'ids': ack});
      if (alive) ref.read(peerRevisionProvider.notifier).state++;
    }
  }

  void tick() {
    if (running || !alive || !network.isOnline ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused) {
      return;
    }
    running = true;
    unawaited(cycle().catchError((_) {}).whenComplete(() => running = false));
  }

  final sub = network.onConnectivityChanged.listen((online) {
    if (online) tick();
  });
  final lifecycle = AppLifecycleListener(onResume: tick);
  final timer = Timer.periodic(const Duration(seconds: 10), (_) => tick());
  scheduleMicrotask(tick);
  ref.onDispose(() {
    alive = false;
    sub.cancel();
    lifecycle.dispose();
    timer.cancel();
  });
});

class PeerRelayRuntime extends ConsumerWidget {
  const PeerRelayRuntime({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(_peerRelayRuntimeProvider);
    return child;
  }
}
