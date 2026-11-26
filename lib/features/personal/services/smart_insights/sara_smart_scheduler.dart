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
  /// Instant (ms) of the latest digest that fired — a time change made
  /// after it may schedule that same day again (see SaraDailyPlanner.plan).
  static const String lastFiredAtKey = 'sara_smart_last_fired_ms';
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
      var lastAt = prefs.getInt(lastFiredAtKey);
      final ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
      final all = _decode(await PersonalReminderStore.read(storeKey));
      for (final e in all.values) {
        final millis = (e['millis'] as num?)?.toInt() ?? 0;
        final day = e['day']?.toString() ?? '';
        if (millis > 0 && millis <= ms && day.length == 8) {
          if (last == null || day.compareTo(last) > 0) last = day;
          if (lastAt == null || millis > lastAt) lastAt = millis;
        }
      }
      if (last != null) await prefs.setString(lastFiredKey, last);
      if (lastAt != null) await prefs.setInt(lastFiredAtKey, lastAt);
      return last;
    } catch (_) {
      return null;
    }
  }

  /// When the latest digest fired (ms), harvested like [lastFiredDay].
  static Future<int?> lastFiredAt({DateTime? now}) async {
    try {
      await lastFiredDay(now: now);
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(lastFiredAtKey);
    } catch (_) {
      return null;
    }
  }

  /// The user picked a new daily time: moves every stored digest to it
  /// right away (the full re-plan follows), so the new time holds even if
  /// the app is closed a second later. Today's digest moves too — also
  /// when it already fired today, as long as the new time is still ahead
  /// (same request code per day: never two pending alarms for one day).
  /// A digest whose new time has passed is cancelled. Never throws.
  static Future<void> retime(int minutesOfDay, {DateTime? now}) async {
    try {
      final at = now ?? DateTime.now();
      await lastFiredDay(now: at); // remember what fired before moving it
      final all = _decode(await PersonalReminderStore.read(storeKey));
      if (all.isEmpty) return;
      final h = (minutesOfDay ~/ 60).clamp(0, 23);
      final m = (minutesOfDay % 60).clamp(0, 59);
      final limit = at.add(const Duration(seconds: 30));
      final out = <String, Map<String, dynamic>>{};
      for (final entry in all.entries) {
        final e = entry.value;
        final day = SaraDailyPlanner.parseDayKey(e['day']?.toString() ?? '');
        final millis = (e['millis'] as num?)?.toInt() ?? 0;
        final rc = (e['requestCode'] as num?)?.toInt() ?? 0;
        final fired = millis > 0 && millis <= at.millisecondsSinceEpoch;
        if (day == null || rc == 0) {
          out[entry.key] = e;
          continue;
        }
        final fireAt = DateTime(day.year, day.month, day.day, h, m);
        if (fireAt.isAfter(limit)) {
          final moved = {...e, 'millis': fireAt.millisecondsSinceEpoch};
          out[entry.key] = moved;
          await _schedule(moved, fireAt);
        } else if (fired) {
          out[entry.key] = e; // already delivered: kept as the fired record
        } else {
          await _cancel(rc); // its new time has passed
        }
      }
      await PersonalReminderStore.write(storeKey, jsonEncode(out));
    } catch (_) {}
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
  ///
  /// [keepPlanned]: days that already have a pending digest keep it (it
  /// was planned from real data); only the missing days get [slots].
  static Future<void> apply(List<SaraSlot> slots,
      {bool keepPlanned = false}) async {
    try {
      await lastFiredDay(); // harvest before overwriting the store
      final old = _decode(await PersonalReminderStore.read(storeKey));
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (keepPlanned) {
        final pending = <String, Map<String, dynamic>>{
          for (final e in old.entries)
            if (((e.value['millis'] as num?)?.toInt() ?? 0) > nowMs &&
                (e.value['day']?.toString() ?? '').length == 8)
              e.key: e.value,
        };
        final days = pending.values.map((e) => e['day'].toString()).toSet();
        slots = [for (final s in slots) if (!days.contains(s.dayKey)) s];
        if (slots.isEmpty) return;
        final store = <String, Map<String, dynamic>>{...pending};
        for (final s in slots) {
          final entry = _entry(s);
          store['sara_${s.dayKey}'] = entry;
          await _schedule(entry, s.fireAt);
        }
        await PersonalReminderStore.write(storeKey, jsonEncode(store));
        return;
      }
      final keep = slots.map((s) => requestCodeForDay(s.dayKey)).toSet();
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
        final entry = _entry(s);
        store['sara_${s.dayKey}'] = entry;
        await _schedule(entry, s.fireAt);
      }
      await PersonalReminderStore.write(storeKey, jsonEncode(store));
    } catch (_) {}
  }

  static Map<String, dynamic> _entry(SaraSlot s) => ReminderCodec.buildEntry(
        millis: s.fireAt.millisecondsSinceEpoch,
        title: s.notice.title,
        body: s.notice.body,
        kind: kind,
        refId: 'digest-${s.dayKey}',
        requestCode: requestCodeForDay(s.dayKey),
        route: s.notice.route,
        extra: {'day': s.dayKey},
      );

  /// True when a digest is pending for each of the next two days.
  static Future<bool> coversDays(DateTime now) async {
    try {
      final all = _decode(await PersonalReminderStore.read(storeKey));
      final ms = now.millisecondsSinceEpoch;
      final days = {
        for (final e in all.values)
          if (((e['millis'] as num?)?.toInt() ?? 0) > ms) e['day']?.toString()
      };
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      final after = DateTime(now.year, now.month, now.day + 2);
      return days.contains(SaraDailyPlanner.dayKey(tomorrow)) &&
          days.contains(SaraDailyPlanner.dayKey(after));
    } catch (_) {
      return false;
    }
  }

  /// The next pending digest (null when none) — shown in the settings.
  /// Reads the boot copy in preferences (times only, no texts): cheap and
  /// never opens the encrypted ledger.
  static Future<DateTime?> nextDigest({DateTime? now}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final all = _decode(prefs.getString(storeKey));
      final ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
      int? best;
      for (final e in all.values) {
        final m = (e['millis'] as num?)?.toInt() ?? 0;
        if (m > ms && (best == null || m < best)) best = m;
      }
      return best == null ? null : DateTime.fromMillisecondsSinceEpoch(best);
    } catch (_) {
      return null;
    }
  }

  /// Real end-to-end check from the settings: the same native alarm path
  /// as a digest (fires with the app closed / offline) in [after].
  static Future<bool> scheduleTest(SaraNotice n,
      {Duration after = const Duration(minutes: 1)}) async {
    try {
      final at = DateTime.now().add(after);
      final entry = ReminderCodec.buildEntry(
        millis: at.millisecondsSinceEpoch,
        title: n.title,
        body: n.body,
        kind: kind,
        refId: 'test',
        requestCode: ReminderCodec.requestCode('sara:test'),
        route: n.route,
      );
      await _schedule(entry, at);
      return true;
    } catch (_) {
      return false;
    }
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
