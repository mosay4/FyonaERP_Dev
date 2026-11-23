import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models/notification_models.dart';
import '../../di/notifications_providers.dart';

final notificationListProvider = FutureProvider<List<NotificationItem>>((ref) async {
  final service = ref.watch(notificationServiceProvider);
  try {
    final result = await service.getAll();
    return result.cast<NotificationItem>();
  } catch (_) {
    // Offline-first guarantee: ANY failure (connectivity, transient 5xx,
    // cache-row parse hiccup) falls back to the local mirror if one exists,
    // else an empty list. The page then shows "no notifications yet" instead
    // of a full-screen server error.
    try {
      final cached = await service.getCached();
      return cached.cast<NotificationItem>();
    } catch (_) {
      return <NotificationItem>[];
    }
  }
});

/// Last background warming of the notifications mirror (throttles the
/// fire-and-forget list fetch below so the bell poll doesn't hammer the API).
DateTime? _lastNotifListWarm;

final unreadCountProvider = FutureProvider<int>((ref) async {
  // Offline-first: the bell must ALWAYS render. Never let a network error
  // turn this provider into an error state on cold offline starts.
  try {
    final service = ref.watch(notificationServiceProvider);
    final count = await service.getUnreadCount();
    // Warm the list mirror in the background (throttled) so the last
    // received notifications stay viewable offline even if the page itself
    // was never opened while online. getAll() caches on success internally.
    final now = DateTime.now();
    if (count > 0 &&
        (_lastNotifListWarm == null ||
            now.difference(_lastNotifListWarm!).inMinutes >= 5)) {
      _lastNotifListWarm = now;
      unawaited(service.getAll().then((_) {}).catchError((_) => <dynamic>[]));
    }
    return count;
  } catch (_) {
    return 0;
  }
});

final markReadProvider = FutureProvider.family<void, String>((ref, id) async {
  final service = ref.watch(notificationServiceProvider);
  await service.markRead(id);
});

final markAllReadProvider = FutureProvider<void>((ref) async {
  final service = ref.watch(notificationServiceProvider);
  await service.markAllRead();
});

final notificationPreferencesProvider = FutureProvider<NotificationPreferences>((ref) async {
  final service = ref.watch(notificationServiceProvider);
  return service.getPreferences();
});

final remindersProvider = FutureProvider<List<Reminder>>((ref) async {
  final service = ref.watch(notificationServiceProvider);
  return service.getReminders();
});
