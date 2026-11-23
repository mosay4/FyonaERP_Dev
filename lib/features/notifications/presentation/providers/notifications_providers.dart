import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core_business/data/local_directory/directory_database.dart'
    show BusinessSyncNotice;
import '../../../core_business/data/local_ledger/business_money.dart';
import '../../../core_business/presentation/providers/business_sync_provider.dart';
import '../../data/models/notification_models.dart';
import '../../di/notifications_providers.dart';

/// Device notices of the Business workspace (an operation cancelled because
/// another person did the same thing first) shown as system notifications.
NotificationItem businessSyncNotification(BusinessSyncNotice n) {
  final by = '${n.details['by_name'] ?? ''}'.trim();
  final summary = n.details['summary'] is Map ? n.details['summary'] as Map : const {};
  final amount = summary['amount_minor'] is num
      ? '${BusinessMoney.display((summary['amount_minor'] as num).abs().toInt())} ${summary['currency'] ?? ''}'.trim()
      : '';
  final what = '${summary['description'] ?? ''}'.trim();
  final who = by.isEmpty ? 'مستخدم آخر' : by;
  final operation = [
    if (what.isNotEmpty) what else 'العملية',
    if (amount.isNotEmpty) 'بمبلغ $amount',
  ].join(' ');
  final message = switch (n.kind) {
    'debtOverpaid' =>
      'أُلغيت عملية «$operation» لأن $who حصّل نفس المبلغ قبلك، فاعتمد النظام عمليته. إذا ما زالت مطلوبة نفّذها مرة أخرى الآن.',
    _ =>
      'أُلغيت عملية «$operation» لأن $who نفّذ نفس العملية قبلك، فاعتمد النظام عمليته. إذا ما زالت مطلوبة نفّذها مرة أخرى الآن.',
  };
  return NotificationItem(
    id: 'business-sync:${n.id}',
    type: 'warning',
    title: 'تم إلغاء عملية',
    message: message,
    isRead: n.read,
    createdAt: DateTime.fromMicrosecondsSinceEpoch(n.createdUs, isUtc: true).toLocal(),
    isSystem: true,
  );
}

Future<List<NotificationItem>> _withDeviceNotices(
  Ref ref,
  List<NotificationItem> items,
) async {
  try {
    final notices = await ref.watch(businessSyncNoticesProvider.future);
    if (notices.isEmpty) return items;
    return [...notices.map(businessSyncNotification), ...items]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  } catch (_) {
    return items;
  }
}

final notificationListProvider = FutureProvider<List<NotificationItem>>((ref) async {
  final service = ref.watch(notificationServiceProvider);
  try {
    final result = await service.getAll();
    return _withDeviceNotices(ref, result.cast<NotificationItem>());
  } catch (_) {
    // Offline-first guarantee: ANY failure (connectivity, transient 5xx,
    // cache-row parse hiccup) falls back to the local mirror if one exists,
    // else an empty list. The page then shows "no notifications yet" instead
    // of a full-screen server error.
    try {
      final cached = await service.getCached();
      return _withDeviceNotices(ref, cached.cast<NotificationItem>());
    } catch (_) {
      return _withDeviceNotices(ref, <NotificationItem>[]);
    }
  }
});

/// Last background warming of the notifications mirror (throttles the
/// fire-and-forget list fetch below so the bell poll doesn't hammer the API).
DateTime? _lastNotifListWarm;

final unreadCountProvider = FutureProvider<int>((ref) async {
  var device = 0;
  try {
    device = (await ref.watch(businessSyncNoticesProvider.future))
        .where((n) => !n.read)
        .length;
  } catch (_) {}
  return device + await _serverUnread(ref);
});

Future<int> _serverUnread(Ref ref) async {
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
}

final markReadProvider = FutureProvider.family<void, String>((ref, id) async {
  if (id.startsWith('business-sync:')) {
    await markBusinessSyncNoticesRead(ref);
    return;
  }
  final service = ref.watch(notificationServiceProvider);
  await service.markRead(id);
});

final markAllReadProvider = FutureProvider<void>((ref) async {
  await markBusinessSyncNoticesRead(ref);
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
