import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/section_scope.dart';

/// Information Clicker preferences: on/off + long-press duration.
///
/// Stored PER SECTION (personal / business) so changing them in one section
/// never affects the other. Persisted locally only — never touches
/// notifications, sync or backup.
class HelpClickerSettings {
  final bool enabled;
  final int seconds;
  const HelpClickerSettings({this.enabled = true, this.seconds = 2});

  HelpClickerSettings copyWith({bool? enabled, int? seconds}) =>
      HelpClickerSettings(
        enabled: enabled ?? this.enabled,
        seconds: seconds ?? this.seconds,
      );
}

class HelpClickerNotifier extends Notifier<HelpClickerSettings> {
  static const _kEnabled = 'help_clicker_enabled';
  static const _kSeconds = 'help_clicker_seconds';
  static const minSeconds = 1;
  static const maxSeconds = 15;

  AppSection _section = AppSection.business;
  String _k(String base) => '${base}_${_section.name}';

  @override
  HelpClickerSettings build() {
    _section = ref.watch(activeSectionProvider);
    _load();
    return const HelpClickerSettings();
  }

  Future<void> _load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      // Section key first, then the legacy global key (migration/back-compat).
      final seconds =
          (sp.getInt(_k(_kSeconds)) ?? sp.getInt(_kSeconds) ?? 2)
              .clamp(minSeconds, maxSeconds);
      state = HelpClickerSettings(
        enabled: sp.getBool(_k(_kEnabled)) ?? sp.getBool(_kEnabled) ?? true,
        seconds: seconds,
      );
    } catch (_) {}
  }

  Future<void> setEnabled(bool value) async {
    state = state.copyWith(enabled: value);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_k(_kEnabled), value);
    } catch (_) {}
  }

  Future<void> setSeconds(int value) async {
    final clamped = value.clamp(minSeconds, maxSeconds);
    state = state.copyWith(seconds: clamped);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_k(_kSeconds), clamped);
    } catch (_) {}
  }
}

final helpClickerProvider =
    NotifierProvider<HelpClickerNotifier, HelpClickerSettings>(
        HelpClickerNotifier.new);
