import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/services/section_scope.dart';
import '../../core/theme/app_colors.dart';

final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

/// Holds the current theme-wave transition state.
/// [null] = no transition; [ThemeMode.light] = transitioning TO light;
/// [ThemeMode.dark] = transitioning TO dark.
final themeTransitionProvider = StateProvider<ThemeMode?>((ref) => null);

/// Theme is stored PER SECTION (personal / business). The active usage mode
/// drives which stored value applies, so toggling the theme in one section
/// never changes the other.
class ThemeModeNotifier extends Notifier<ThemeMode> {
  AppSection _section = AppSection.business;

  @override
  ThemeMode build() {
    _section = ref.watch(activeSectionProvider);
    _loadThemeMode(_section);
    // Default = light (white) until the section's saved value loads.
    AppColors.setLightMode(true);
    return ThemeMode.light;
  }

  String _key(AppSection s) => 'theme_mode_${s.name}';

  Future<void> _loadThemeMode(AppSection s) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final saved = sp.getString(_key(s));
      if (saved != null) {
        final mode = saved == 'dark' ? ThemeMode.dark : ThemeMode.light;
        AppColors.setLightMode(mode == ThemeMode.light);
        state = mode;
      }
    } catch (_) {}
  }

  /// Triggers the wave transition overlay, then switches the theme.
  Future<void> toggleTheme() async {
    if (ref.read(themeTransitionProvider) != null) return;
    final target = state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    ref.read(themeTransitionProvider.notifier).state = target;
  }

  /// Called by the overlay when the wave has fully covered the screen.
  Future<void> applyTheme(ThemeMode mode) async {
    state = mode;
    AppColors.setLightMode(mode == ThemeMode.light);
    await _saveThemeMode();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    AppColors.setLightMode(mode == ThemeMode.light);
    await _saveThemeMode();
  }

  Future<void> _saveThemeMode() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
          _key(_section), state == ThemeMode.dark ? 'dark' : 'light');
    } catch (_) {}
  }

  bool get isDark => state == ThemeMode.dark;
}
