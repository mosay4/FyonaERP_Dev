import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/ledger/personal_reminder_store.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../../core/localization/app_localizations.dart';
import '../../../../shared/services/notification_channels.dart';
import '../../../../shared/services/notification_service.dart';
import '../../../../shared/services/reminder_codec.dart';
import 'sara_daily_planner.dart';
import 'sara_notice_composer.dart';

// ─────────────────────────────────────────────────────────────
// SaraSmartScheduler — device side of Sara's smart notifications.
//
// Android: the app's NATIVE exact-alarm pipeline (same MethodChannel as
// debt / recurring reminders) with kind "sara": the alarm fires while the
// app is killed / offline, posts on the existing `sara_channel` (sound_1)
// and the tap carries the route through the native tap bridge
// (AlarmTapBridge → NotificationRouter) on cold start AND warm resume.
// The store `sara_smart_reminders_v1` is re-armed after reboot by the
// native BootReceiver.
//
// iOS: flutter_local_notifications zonedSchedule at the absolute instant
// (UTC TZDateTime, no tz database needed).
//
// Instant (event-driven) alerts use the shared plugin owned by
// NotificationService on `sara_channel`; their payload is the route, so
// local-plugin taps (warm + cold start) go through the same router.
// Never throws.
// ─────────────────────────────────────────────────────────────
class SaraSmartScheduler {
  SaraSmartScheduler._();

  static const MethodChannel _native =
      MethodChannel('com.fyona.erp/alarm_native');

  static const String storeKey = 'sara_smart_reminders_v1';
  static const String lastFiredKey = 'sara_smart_last_fired_day';
  static const String cooldownKey = 'sara_smart_cooldown_v1';
  static const String instantCountKey = 'sara_smart_instant_count_v1';
  static const String kind = 'sara';

  /// Android drawable shown as the large icon of every Sara notification.
  static const String saraLargeIcon = 'sara_avatar_notif';

  /// Test seam: 'android' | 'ios' forces the platform path.
  @visibleForTesting
  static String? debugPlatform;

  static bool get _android =>
      debugPlatform != null ? debugPlatform == 'android' : Platform.isAndroid;
  static bool get _ios =>
      debugPlatform != null ? debugPlatform == 'ios' : Platform.isIOS;

  /// Max instant heads-ups per day (never annoying).
  static const int maxInstantPerDay = 2;

  static int requestCodeForDay(String dayKey) =>
      ReminderCodec.requestCode('sara:digest:$dayKey');

  static int requestCodeForInstant(String key) =>
      ReminderCodec.requestCode('sara:instant:$key');

  static Map<String, Map<String, dynamic>> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final out = <String, Map<String, dynamic>>{};
      m.forEach((k, v) {
        if (v is Map) out[k] = Map<String, dynamic>.from(v);
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  /// Latest day whose digest already fired (harvested from the store:
  /// any stored entry whose instant has passed counts as delivered).
  static Future<String?> lastFiredDay({DateTime? now}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var last = prefs.getString(lastFiredKey);
      final ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
      final all = _decode(await PersonalReminderStore.read(storeKey));
      for (final e in all.values) {
        final millis = (e['millis'] as num?)?.toInt() ?? 0;
        final day = e['day']?.toString() ?? '';
        if (millis > 0 && millis <= ms && day.length == 8) {
          if (last == null || day.compareTo(last) > 0) last = day;
        }
      }
      if (last != null) await prefs.setString(lastFiredKey, last);
      return last;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, SaraCooldownEntry>> loadCooldown() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(cooldownKey);
      if (raw == null || raw.isEmpty) return {};
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final out = <String, SaraCooldownEntry>{};
      m.forEach((k, v) {
        final e = SaraCooldownEntry.fromJson(v);
        if (e != null) out[k] = e;
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  static Future<void> saveCooldown(Map<String, SaraCooldownEntry> m) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          cooldownKey, jsonEncode(m.map((k, v) => MapEntry(k, v.toJson()))));
    } catch (_) {}
  }

  @visibleForTesting
  static NotificationDetails detailsForTest(String body) => _details(body);

  static NotificationDetails _details(String body) {
    const spec = NotificationChannels.sara;
    return NotificationDetails(
      android: AndroidNotificationDetails(
        spec.id,
        AppLocalizations.t(spec.nameKey),
        channelDescription: AppLocalizations.t(spec.descKey),
        importance: Importance.high,
        priority: Priority.high,
        autoCancel: true,
        icon: 'ic_launcher',
        // Sara's portrait (res/drawable-nodpi/sara_avatar_notif.png) —
        // the same large icon the native alarm path uses.
        largeIcon: const DrawableResourceAndroidBitmap(saraLargeIcon),
        color: const Color(0xFF000000),
        sound: RawResourceAndroidNotificationSound(spec.sound),
        enableVibration: true,
        channelShowBadge: true,
        visibility: NotificationVisibility.public,
        category: AndroidNotificationCategory.reminder,
        // Two short lines stay readable when expanded.
        styleInformation: BigTextStyleInformation(body),
      ),
      iOS: spec.iosDetails(),
    );
  }

  /// Replaces every pending digest with [slots]. Old entries that are not
  /// re-planned are cancelled; entries that already fired are dropped
  /// from the store (their day is remembered as fired).
  static Future<void> apply(List<SaraSlot> slots) async {
    try {
      await lastFiredDay(); // harvest before overwriting the store
      final old = _decode(await PersonalReminderStore.read(storeKey));
      final keep = slots.map((s) => requestCodeForDay(s.dayKey)).toSet();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      for (final e in old.values) {
        final rc = (e['requestCode'] as num?)?.toInt() ?? 0;
        final millis = (e['millis'] as num?)?.toInt() ?? 0;
        // Do not cancel a fired one: cancelling also clears it from the
        // tray, and the user may not have read it yet.
        if (rc != 0 && !keep.contains(rc) && millis > nowMs) {
          await _cancel(rc);
        }
      }
      final store = <String, Map<String, dynamic>>{};
      for (final s in slots) {
        final rc = requestCodeForDay(s.dayKey);
        final entry = ReminderCodec.buildEntry(
          millis: s.fireAt.millisecondsSinceEpoch,
          title: s.notice.title,
          body: s.notice.body,
          kind: kind,
          refId: 'digest-${s.dayKey}',
          requestCode: rc,
          route: s.notice.route,
          extra: {'day': s.dayKey},
        );
        store['sara_${s.dayKey}'] = entry;
        await _schedule(entry, s.fireAt);
      }
      await PersonalReminderStore.write(storeKey, jsonEncode(store));
    } catch (_) {}
  }

  /// Cancels every pending Sara digest (switch off / logout).
  static Future<void> cancelAll() async {
    try {
      final old = _decode(await PersonalReminderStore.read(storeKey));
      for (final e in old.values) {
        final rc = (e['requestCode'] as num?)?.toInt() ?? 0;
        final millis = (e['millis'] as num?)?.toInt() ?? 0;
        if (rc != 0 && millis > DateTime.now().millisecondsSinceEpoch) {
          await _cancel(rc);
        }
      }
      await PersonalReminderStore.remove(storeKey);
    } catch (_) {}
  }

  /// Re-arms stored future digests (force-stop clears AlarmManager).
  static Future<void> rescheduleAll() async {
    try {
      final all = _decode(await PersonalReminderStore.read(storeKey));
      final now = DateTime.now();
      for (final e in all.values) {
        final millis = (e['millis'] as num?)?.toInt() ?? 0;
        if (millis <= now.millisecondsSinceEpoch) continue;
        await _schedule(e, DateTime.fromMillisecondsSinceEpoch(millis));
      }
    } catch (_) {}
  }

  static Future<void> _schedule(
      Map<String, dynamic> entry, DateTime fireAt) async {
    try {
      if (_android) {
        await _native.invokeMethod('scheduleReminderAlarm', {
          'millis': entry['millis'],
          'title': entry['title'],
          'body': entry['body'],
          'kind': kind,
          'refId': entry['refId'],
          'requestCode': entry['requestCode'],
          'route': entry['route'],
        });
      } else if (_ios) {
        final plugin = NotificationService.sharedPlugin;
        if (plugin == null) return;
        await plugin.zonedSchedule(
          id: (entry['requestCode'] as num).toInt(),
          scheduledDate: tz.TZDateTime.from(fireAt.toUtc(), tz.UTC),
          notificationDetails: _details(entry['body']?.toString() ?? ''),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          title: entry['title']?.toString(),
          body: entry['body']?.toString(),
          payload: entry['route']?.toString(),
        );
      }
    } catch (_) {}
  }

  static Future<void> _cancel(int rc) async {
    try {
      if (_android) {
        await _native.invokeMethod('cancelReminderAlarm', {'requestCode': rc});
      } else if (_ios) {
        await NotificationService.sharedPlugin?.cancel(id: rc);
      }
    } catch (_) {}
  }

  /// Claims one of today's instant slots (max [maxInstantPerDay]).
  static Future<bool> claimInstantSlot(String dayKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(instantCountKey) ?? '';
      final parts = raw.split(':');
      var count = 0;
      if (parts.length == 2 && parts[0] == dayKey) {
        count = int.tryParse(parts[1]) ?? 0;
      }
      if (count >= maxInstantPerDay) return false;
      await prefs.setString(instantCountKey, '$dayKey:${count + 1}');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Shows an event-driven heads-up immediately (tray + sound_1).
  static Future<bool> showNow(SaraNotice n, String key) async {
    try {
      final plugin = NotificationService.sharedPlugin;
      if (plugin == null) return false;
      await plugin.show(
        id: requestCodeForInstant(key),
        title: n.title,
        body: n.body,
        notificationDetails: _details(n.body),
        payload: n.route,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
