import 'package:flutter/foundation.dart';
import '../../../../core/database/database_helper.dart';
import '../../../../core/database/repositories/settings_repository.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/offline/offline_guard.dart';
import '../../../../core/services/interfaces/all_services.dart';
import '../../data/models/notification_models.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';

class NotificationServiceImpl implements NotificationService {
  final ApiClient? apiClient;
  final SettingsRepository? localRepo;
  int? userId;

  NotificationServiceImpl({this.apiClient, this.localRepo, this.userId});

  /// Saves a fetched list into the local SQLite cache (mirror for offline).
  /// NOTE: rows are written with NULL organization/user ids ON PURPOSE — the
  /// local `notifications` table enforces foreign keys, and the mirror
  /// namespace ids (org 0 / hashed user) do not exist in the local tables,
  /// which used to fail EVERY insert silently and left offline permanently
  /// empty. NULL skips FK checks, and the mirror is appointment-bounded below.
  Future<void> _cacheLocally(List<NotificationItem> items) async {
    final repo = localRepo;
    if (repo == null) return;
    var inserted = 0;
    try {
      for (final it in items) {
        final created = _encodeDate(it.createdAt);
        try {
          await repo.insertNotification({
            'organization_id': null,
            'user_id': null,
            'type': it.type.isNotEmpty ? it.type : 'info',
            'title': it.title.isNotEmpty ? it.title : '—',
            'message': it.message,
            'is_read': it.isRead ? 1 : 0,
            'created_at': created,
          });
          inserted++;
        } catch (e) {
          debugPrint('[NOTIF_CACHE] insert failed: ${e.toString()}');
          // One bad row must never abort the rest of the mirror.
          continue;
        }
      }
      // Deduplicate (keep the newest row per title+type+message) and bound
      // the mirror to the newest 100 rows.
      await DatabaseHelper.rawDelete(
        'DELETE FROM notifications WHERE id NOT IN ('
        'SELECT id FROM notifications ORDER BY id DESC LIMIT 100)',
      );
      debugPrint('[NOTIF_CACHE] fetched=${items.length} inserted=$inserted');
    } catch (e) {
      debugPrint('[NOTIF_CACHE] cacheLocally error: ${e.toString()}');
    }
  }

  String _encodeDate(DateTime? d) {
    final t = d ?? DateTime.now();
    return '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
  }

  Future<String?> _userIdStr() {
    final uid = userId;
    if (uid != null) return Future.value(uid.toString());
    return Future.value(null);
  }

  Future<List<Map<String, dynamic>>> _readCached() async {
    final repo = localRepo;
    if (repo == null) return [];
    try {
      final byOrg = await repo.getNotifications(0);
      if (byOrg.isNotEmpty) {
        debugPrint('[NOTIF_CACHE] read byOrg(0)=${byOrg.length}');
        return byOrg;
      }
      final uid = userId;
      if (uid != null) {
        final byUser = await repo.getUserNotifications(uid);
        if (byUser.isNotEmpty) {
          debugPrint('[NOTIF_CACHE] read byUser=$uid=${byUser.length}');
          return byUser;
        }
      }
    } catch (e) {
      debugPrint('[NOTIF_CACHE] scoped read failed: ${e.toString()}');
      // fall through to the widest possible read below
    }
    // Last resort: read every cached notification row regardless of scope so
    // offline the user ALWAYS sees whatever was synced during the last online
    // session. The dedupe cleanup in _cacheLocally keeps this bounded.
    try {
      final rows = await DatabaseHelper.query(
        'notifications',
        orderBy: 'created_at DESC',
        limit: 50,
      );
      debugPrint('[NOTIF_CACHE] lastResort rows=${(rows?.length ?? 0)}');
      if (rows != null && rows.isNotEmpty) {
        return rows.cast<Map<String, dynamic>>().toList();
      }
    } catch (e) {
      debugPrint('[NOTIF_CACHE] lastResort failed: ${e.toString()}');
    }
    return [];
  }

  @override
  Future<List> getAll({int limit = 50, bool? unreadOnly}) async {
    if (apiClient != null) {
      try {
        final params = <String, dynamic>{'per_page': limit, 'page': 1};
        if (unreadOnly == true) params['unread_only'] = true;
        final response = await apiClient!.get(ApiEndpoints.notifications, queryParameters: params);
        final data = response.data;
        final list = data is List ? data : (data is Map ? data['data'] : []);
        final List items;
        if (list is Map) {
          items = ((list['items'] ?? const []) as List)
              .map((j) => NotificationItem.fromJson(j as Map<String, dynamic>))
              .toList();
        } else {
          items = (list as List).map((j) => NotificationItem.fromJson(j as Map<String, dynamic>)).toList();
        }
        await _cacheLocally(items.cast<NotificationItem>().toList());
        return items;
      } catch (e) {
        // Offline-first: on connectivity problems return the local mirror
        // (possibly empty) instead of throwing, so the notifications page
        // shows the last received items — or a friendly offline empty state
        // — rather than a full-screen error.
        debugPrint('[NOTIF] getAll exception: ${e.toString()} '
            'connectivity=${isConnectivityError(e)}');
        if (isConnectivityError(e)) {
          final cached = await _readCached();
          return cached.map((r) => NotificationItem.fromJson(<String, dynamic>{
            'id': r['id'].toString(),
            'title': r['title'],
            'message': r['message'],
            'type': r['type'],
            'is_read': (r['is_read'] ?? 0) == 1,
            'created_at': r['created_at']?.toString() ?? '',
          })).toList();
        }
        throw Exception(AppLocalizations.t('notificationsFailedToLoadNotifications', {'e': e.toString()}));
      }
    }
    return [];
  }

  /// Offline mirror reader: returns ONLY what is stored locally — never
  /// touches the network. Used by the provider fallback so the notifications
  /// screen always renders (empty state when nothing was ever received).
  @override
  Future<List> getCached({int limit = 50}) async {
    try {
      final cached = await _readCached();
      return cached.take(limit).map((r) => NotificationItem.fromJson(<String, dynamic>{
        'id': r['id'].toString(),
        'title': r['title'],
        'message': r['message'],
        'type': r['type'],
        'is_read': (r['is_read'] ?? 0) == 1,
        'created_at': r['created_at']?.toString() ?? '',
      })).toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<int> getUnreadCount() async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get(ApiEndpoints.notificationsUnreadCount);
        final data = response.data;
        if (data is int) return data;
        if (data is Map) {
          if (data['count'] != null) return data['count'] as int;
          final inner = data['data'];
          if (inner is Map && inner['count'] != null) return inner['count'] as int;
        }
      } catch (e) {
        throw Exception(AppLocalizations.t('notificationsFailedToLoadUnread', {'e': e.toString()}));
      }
    }
    return 0;
  }

  @override
  Future<void> markRead(String id) async {
    if (apiClient != null) {
      try {
        await apiClient!.post(ApiEndpoints.notificationRead(id.toString()));
        return;
      } catch (e) {
        throw Exception(AppLocalizations.t('notificationsFailedToSetNotification', {'e': e.toString()}));
      }
    }
  }

  @override
  Future<void> markAllRead() async {
    if (apiClient != null) {
      try {
        await apiClient!.post(ApiEndpoints.notificationsReadAll);
        return;
      } catch (e) {
        throw Exception(AppLocalizations.t('notificationsFailedToSetAll', {'e': e.toString()}));
      }
    }
  }

  Future<NotificationPreferences> getPreferences() async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get(ApiEndpoints.notificationPreferences);
        final data = response.data;
        final prefs = data is Map ? (data['data'] ?? data) : {};
        return NotificationPreferences.fromJson(prefs as Map<String, dynamic>);
      } catch (e) {
        throw Exception(AppLocalizations.t('notificationsFailedToLoadNotification', {'e': e.toString()}));
      }
    }
    return const NotificationPreferences();
  }

  Future<void> updatePreferences(NotificationPreferences prefs) async {
    if (apiClient != null) {
      try {
        await apiClient!.put(ApiEndpoints.notificationPreferences, data: prefs.toJson());
        return;
      } catch (e) {
        throw Exception(AppLocalizations.t('notificationsFailedToSaveNotification', {'e': e.toString()}));
      }
    }
  }

  Future<List<Reminder>> getReminders() async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get(ApiEndpoints.reminders);
        final data = response.data;
        final list = data is List ? data : (data is Map ? data['data'] : []);
        return (list as List).map((j) => Reminder.fromJson(j as Map<String, dynamic>)).toList();
      } catch (e) {
        throw Exception(AppLocalizations.t('notificationsFailedToLoadReminders', {'e': e.toString()}));
      }
    }
    return [];
  }

  Future<Reminder> createReminder({
    required String title,
    String? message,
    required DateTime remindAt,
    String repeat = 'none',
  }) async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.post(
          ApiEndpoints.reminders,
          data: {
            'title': title,
            if (message != null) 'message': message,
            'remind_at': remindAt.toUtc().toIso8601String(),
            'repeat': repeat,
          },
        );
        final data = response.data;
        final item = data is Map ? (data['data'] ?? data) : {};
        return Reminder.fromJson(item as Map<String, dynamic>);
      } catch (e) {
        throw Exception(AppLocalizations.t('notificationsFailedToCreateReminder', {'e': e.toString()}));
      }
    }
    throw Exception(AppLocalizations.t('notificationsNoConnectionToServer'));
  }

  Future<void> updateReminder(Reminder reminder) async {
    if (apiClient != null) {
      try {
        await apiClient!.patch(
          ApiEndpoints.reminder(reminder.id),
          data: {
            'title': reminder.title,
            if (reminder.message != null) 'message': reminder.message,
            'remind_at': reminder.remindAt.toUtc().toIso8601String(),
            'repeat': reminder.repeat,
            'is_active': reminder.isActive,
          },
        );
        return;
      } catch (e) {
        throw Exception(AppLocalizations.t('notificationsReminderUpdateFailed', {'e': e.toString()}));
      }
    }
  }

  Future<void> deleteReminder(String id) async {
    if (apiClient != null) {
      try {
        await apiClient!.delete(ApiEndpoints.reminder(id));
        return;
      } catch (e) {
        throw Exception(AppLocalizations.t('notificationsFailedToDeleteReminder', {'e': e.toString()}));
      }
    }
  }

  Future<void> generateTestNotification() async {
    if (apiClient != null) {
      try {
        await apiClient!.post(ApiEndpoints.notificationsTest);
        return;
      } catch (e) {
        throw Exception(AppLocalizations.t('notificationsFailedToCreateTest', {'e': e.toString()}));
      }
    }
  }
}
