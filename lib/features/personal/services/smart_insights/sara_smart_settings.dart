import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../shared/providers/current_user_provider.dart';

// ─────────────────────────────────────────────────────────────
// Per-user settings for Sara's smart notifications (Personal ›
// Profile › Preferences). Stored in SharedPreferences keyed by user id,
// like the other Personal preferences.
//
// The switch governs ONLY Sara's periodic / smart notifications (daily
// digest: goal plan, spending insights, log reminder, encouragement, and
// the instant big-expense / budget-over heads-up). It never touches
// system, admin, security, subscription, FCM/server notifications, nor
// the reminders the user explicitly set per item (recurring bills, debt
// due-date alarms) — those are user-created reminders, not Sara's.
// ─────────────────────────────────────────────────────────────

class SaraSmartSettings {
  final bool enabled;

  /// Minutes after midnight chosen by the user; null = automatic (the
  /// user's detected peak hour, 20:00 fallback).
  final int? minutes;

  /// Last peak hour detected by the engine (for the "Auto (…)" label).
  final int peakHour;

  const SaraSmartSettings({
    this.enabled = true,
    this.minutes,
    this.peakHour = 20,
  });

  /// Effective daily fire time (minutes after midnight).
  int get effectiveMinutes => minutes ?? peakHour * 60;

  bool get isAuto => minutes == null;

  SaraSmartSettings copyWith({
    bool? enabled,
    int? minutes,
    bool clearMinutes = false,
    int? peakHour,
  }) =>
      SaraSmartSettings(
        enabled: enabled ?? this.enabled,
        minutes: clearMinutes ? null : (minutes ?? this.minutes),
        peakHour: peakHour ?? this.peakHour,
      );
}

class SaraSmartSettingsStore {
  SaraSmartSettingsStore._();

  static String enabledKey(String uid) => 'sara_smart_notif_enabled_$uid';
  static String timeKey(String uid) => 'sara_smart_notif_time_$uid';
  static String peakKey(String uid) => 'sara_smart_notif_peak_$uid';

  static Future<SaraSmartSettings> load(String uid) async {
    try {
      final p = await SharedPreferences.getInstance();
      final t = p.getInt(timeKey(uid));
      return SaraSmartSettings(
        enabled: p.getBool(enabledKey(uid)) ?? true,
        minutes: (t == null || t < 0 || t >= 24 * 60) ? null : t,
        peakHour: p.getInt(peakKey(uid)) ?? 20,
      );
    } catch (_) {
      return const SaraSmartSettings();
    }
  }

  static Future<void> save(String uid, SaraSmartSettings s) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(enabledKey(uid), s.enabled);
      if (s.minutes == null) {
        await p.remove(timeKey(uid));
      } else {
        await p.setInt(timeKey(uid), s.minutes!);
      }
    } catch (_) {}
  }

  static Future<void> savePeakHour(String uid, int hour) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(peakKey(uid), hour);
    } catch (_) {}
  }
}

class SaraSmartSettingsNotifier extends StateNotifier<SaraSmartSettings> {
  final String uid;
  SaraSmartSettingsNotifier(this.uid) : super(const SaraSmartSettings()) {
    _load();
  }

  bool _loaded = false;
  bool get loaded => _loaded;

  Future<void> _load() async {
    final s = await SaraSmartSettingsStore.load(uid);
    if (!mounted) return;
    _loaded = true;
    state = s;
  }

  Future<void> setEnabled(bool v) async {
    state = state.copyWith(enabled: v);
    await SaraSmartSettingsStore.save(uid, state);
  }

  /// [minutes] null → back to automatic (peak hour).
  Future<void> setMinutes(int? minutes) async {
    state = minutes == null
        ? state.copyWith(clearMinutes: true)
        : state.copyWith(minutes: minutes.clamp(0, 24 * 60 - 1));
    await SaraSmartSettingsStore.save(uid, state);
  }

  Future<void> notePeakHour(int hour) async {
    if (state.peakHour == hour) return;
    state = state.copyWith(peakHour: hour);
    await SaraSmartSettingsStore.savePeakHour(uid, hour);
  }
}

final saraSmartSettingsProvider =
    StateNotifierProvider<SaraSmartSettingsNotifier, SaraSmartSettings>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  return SaraSmartSettingsNotifier(uid);
});
