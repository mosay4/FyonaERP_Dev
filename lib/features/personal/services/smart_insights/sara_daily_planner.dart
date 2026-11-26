import 'dart:math' as math;

import 'sara_insight_engine.dart';
import 'sara_notice_composer.dart';

// ─────────────────────────────────────────────────────────────
// SaraDailyPlanner — pure scheduling decisions for the daily digest.
//
// Scheduled notification content is frozen when scheduled, so the app
// re-plans on start / resume / every (debounced) Personal data change,
// and pre-schedules the next few days with sensible content so Sara
// still shows up even when the app is not opened.
//
// Guarantees:
//  - at most ONE digest per calendar day;
//  - a day whose digest already fired is not scheduled again — unless the
//    user changed the time AFTER it fired and the new time is still ahead
//    that day: the chosen time always holds (one pending alarm per day);
//  - the chosen time always gets a notification: when nothing new is
//    worth saying, a short check-in is sent;
//  - warnings respect a cooldown (same warning ≤ once every 3 days,
//    and never in a digest after an instant alert said it already).
// ─────────────────────────────────────────────────────────────

class SaraSlot {
  final DateTime fireAt;
  final String dayKey; // yyyymmdd
  final SaraNotice notice;
  const SaraSlot(
      {required this.fireAt, required this.dayKey, required this.notice});
}

/// Cooldown record: when (day) and by which path a key was used.
class SaraCooldownEntry {
  final String day; // yyyymmdd
  final String src; // 'digest' | 'instant'
  const SaraCooldownEntry(this.day, this.src);

  Map<String, String> toJson() => {'d': day, 's': src};
  static SaraCooldownEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final d = raw['d']?.toString() ?? '';
    if (d.length != 8) return null;
    return SaraCooldownEntry(d, raw['s']?.toString() ?? 'digest');
  }
}

class SaraDailyPlanner {
  SaraDailyPlanner._();

  static const int cooldownDays = 3;
  /// Days pre-scheduled: Sara keeps showing up for a week even when the
  /// app (or the Personal section) is not opened.
  static const int daysAhead = 7;

  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  static DateTime? parseDayKey(String k) {
    if (k.length != 8) return null;
    final y = int.tryParse(k.substring(0, 4));
    final m = int.tryParse(k.substring(4, 6));
    final d = int.tryParse(k.substring(6, 8));
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  static int _daysBetween(String a, String b) {
    final da = parseDayKey(a);
    final db = parseDayKey(b);
    if (da == null || db == null) return 9999;
    return db.difference(da).inHours ~/ 24;
  }

  /// Quiet period per notice family: rare insights (a forgotten
  /// subscription, the month-end outlook, a no-spend streak) must not
  /// come back every few days.
  static int cooldownFor(String key) {
    if (key.startsWith('subs:')) return 45;
    if (key.startsWith('proj:good')) return 31;
    if (key.startsWith('proj:short')) return 7;
    if (key.startsWith('payday:')) return 20;
    if (key == 'nospend') return 7;
    if (key.startsWith('debt:late')) return 7;
    if (key.startsWith('goal:due')) return 5;
    if (key.startsWith('enc:')) return 5;
    return cooldownDays;
  }

  /// Is [key] allowed in the digest of [day]?
  static bool cooldownAllows(
      Map<String, SaraCooldownEntry> cooldown, String key, String day) {
    final e = cooldown[key];
    if (e == null) return true;
    // Re-planning the same day's digest may keep its own warning.
    if (e.src == 'digest' && e.day == day) return true;
    return _daysBetween(e.day, day).abs() >= cooldownFor(key);
  }

  static List<SaraSlot> plan({
    required SaraInsightInput input,
    required DateTime now,
    required int minutesOfDay,
    required String? lastFiredDay,
    required Map<String, SaraCooldownEntry> cooldown,
    required SaraTr tr,
    required SaraMoney money,
    int days = daysAhead,
    int? lastFiredAtMs,
    int? timeChangedAtMs,
  }) {
    return _slots(
      now: now,
      minutesOfDay: minutesOfDay,
      lastFiredDay: lastFiredDay,
      lastFiredAtMs: lastFiredAtMs,
      timeChangedAtMs: timeChangedAtMs,
      days: days,
      notice: (fireAt, key, first) {
        try {
          final analysis = SaraInsightEngine.analyze(input.atTime(fireAt));
          return SaraNoticeComposer.digest(
                analysis,
                firstSlot: first,
                allowed: (k) => cooldownAllows(cooldown, k, key),
                tr: tr,
                money: money,
              ) ??
              checkIn(tr);
        } catch (_) {
          // Unexpected data must never cost the user their notification.
          return checkIn(tr);
        }
      },
    );
  }

  /// The chosen time with a calm check-in each day — used when the
  /// Personal data is not available in this session (or could not be
  /// analysed): Sara still shows up at the user's time.
  static List<SaraSlot> planCheckIns({
    required DateTime now,
    required int minutesOfDay,
    required String? lastFiredDay,
    required SaraTr tr,
    int days = daysAhead,
    int? lastFiredAtMs,
    int? timeChangedAtMs,
  }) =>
      _slots(
        now: now,
        minutesOfDay: minutesOfDay,
        lastFiredDay: lastFiredDay,
        lastFiredAtMs: lastFiredAtMs,
        timeChangedAtMs: timeChangedAtMs,
        days: days,
        notice: (_, _, _) => checkIn(tr),
      );

  static List<SaraSlot> _slots({
    required DateTime now,
    required int minutesOfDay,
    required String? lastFiredDay,
    required int days,
    required SaraNotice Function(DateTime fireAt, String key, bool first) notice,
    int? lastFiredAtMs,
    int? timeChangedAtMs,
  }) {
    final out = <SaraSlot>[];
    // The time was changed after the last digest fired: its day may get
    // one more digest at the new time (the owner expects the new time to
    // hold the same day).
    final retimed = timeChangedAtMs != null &&
        timeChangedAtMs > (lastFiredAtMs ?? _dayStartMs(lastFiredDay));
    final h = (minutesOfDay ~/ 60).clamp(0, 23);
    final m = (minutesOfDay % 60).clamp(0, 59);
    var first = true;
    for (var i = 0; i <= days && out.length < days; i++) {
      final day = DateTime(now.year, now.month, now.day + i);
      final fireAt = DateTime(day.year, day.month, day.day, h, m);
      if (!fireAt.isAfter(now.add(const Duration(seconds: 30)))) continue;
      final key = dayKey(day);
      if (lastFiredDay != null && key.compareTo(lastFiredDay) <= 0 &&
          !(retimed && key == lastFiredDay)) {
        continue;
      }
      final n = notice(fireAt, key, first);
      first = false;
      out.add(SaraSlot(fireAt: fireAt, dayKey: key, notice: n));
    }
    return out;
  }

  static int _dayStartMs(String? day) =>
      (day == null ? null : parseDayKey(day))?.millisecondsSinceEpoch ?? 0;

  /// The digest of a day with nothing new to say: the user chose this time,
  /// so Sara still shows up — a calm check-in that opens the wallet.
  static SaraNotice checkIn(SaraTr tr) => SaraNotice(
        kind: 'checkIn',
        title: tr('saraNotifCheckInTitle'),
        body: tr('saraNotifCheckInBody'),
        route: SaraRoutes.transactions,
      );

  /// Cooldown map after scheduling [slots]: releases the reservations of
  /// digests that have NOT fired yet (they are being re-planned now), then
  /// reserves the new slots' warnings. Entries older than 30 days drop.
  static Map<String, SaraCooldownEntry> reserve(
    Map<String, SaraCooldownEntry> cooldown,
    List<SaraSlot> slots, {
    required DateTime now,
    String? lastFiredDay,
  }) {
    final out = Map<String, SaraCooldownEntry>.from(cooldown);
    final today = dayKey(now);
    out.removeWhere((k, e) {
      if (_daysBetween(e.day, today) > math.max(30, cooldownFor(k))) {
        return true;
      }
      if (e.src != 'digest') return false;
      if (e.day.compareTo(today) < 0) return false; // past: delivered
      // Today's digest that already fired stays reserved.
      return lastFiredDay == null || e.day.compareTo(lastFiredDay) > 0;
    });
    for (final s in slots) {
      final k = s.notice.cooldownKey;
      if (k == null) continue;
      out[k] = SaraCooldownEntry(s.dayKey, 'digest');
    }
    return out;
  }
}
