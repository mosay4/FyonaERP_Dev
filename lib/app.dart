import 'dart:async';
import 'package:flutter/material.dart';
import 'core/services/currency/currency_engine.dart';
import 'shared/widgets/premium_switch_transition.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/router/app_router.dart';
import 'core/router/shell_keys.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/app_theme.dart';
import 'core/help/information_clicker.dart';
import 'shared/widgets/language_transition_overlay.dart';
import 'core/localization/app_localizations.dart';
import 'core/network/session_timeout_provider.dart';
import 'core/utils/currency_formatter.dart';
import 'core/services/currency/money_format_service.dart';
import 'features/auth/presentation/providers/auth_provider.dart';
import 'features/auth/presentation/pages/session_lock_screen.dart';
import 'shared/providers/theme_provider.dart';
import 'shared/providers/locale_provider.dart';
import 'shared/providers/current_user_provider.dart';
import 'core/services/section_scope.dart';
import 'shared/widgets/theme_smoke_overlay.dart';
import 'shared/services/notification_service.dart';
import 'shared/services/notification_router.dart';
import 'features/personal/services/recurring_reminder_service.dart';
import 'core/services/fcm_service.dart';
import 'features/personal/presentation/providers/merchant_unread_provider.dart';
import 'features/employees/presentation/widgets/employee_presence_host.dart';

class FYONAApp extends ConsumerWidget {
  const FYONAApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    AppColors.setLightMode(themeMode == ThemeMode.light);

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        ref.read(sessionTimeoutProvider.notifier).recordActivity();
      },
      child: ValueListenableBuilder<int>(
        valueListenable: moneyFormatRevision,
        builder: (_, __, ___) => MaterialApp.router(
        title: 'FYONA ERP',
        debugShowCheckedModeBanner: false,
        themeMode: themeMode,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => _AppLockOverlay(
           child: EmployeePresenceHost(child: PremiumSwitchHost(child: _ThemeTransitionOverlay(
            child: InformationClickerOverlay(
              child: LanguageTransitionOverlay(
                // Remount the whole navigation subtree the same frame the
                // theme switches (under the smoke) so header, content and
                // bottom bar all repaint synchronously — no 1-2s lag.
                // The overlay itself sits ABOVE this key, so the smoke keeps
                // playing without restarting.
                child: KeyedSubtree(
                  key: ValueKey('nav_${themeMode == ThemeMode.light ? 'light' : 'dark'}'),
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            ),
           ))),
        ),
        routerConfig: ref.watch(goRouterProvider),
      )),
    );
  }
}

/// Shows a smoke overlay during theme transitions.
/// Soft fog rolls in, the actual theme switches underneath at peak
/// coverage, then the smoke drifts up and dissipates to reveal it.
class _ThemeTransitionOverlay extends ConsumerStatefulWidget {
  final Widget child;
  const _ThemeTransitionOverlay({required this.child});

  @override
  ConsumerState<_ThemeTransitionOverlay> createState() =>
      _ThemeTransitionOverlayState();
}

class _ThemeTransitionOverlayState
    extends ConsumerState<_ThemeTransitionOverlay> {
  Timer? _fallbackTimer;
  bool _applied = false;
  bool _cleared = false;

  @override
  void dispose() {
    _fallbackTimer?.cancel();
    super.dispose();
  }

  /// Switch the actual theme underneath the smoke (at peak coverage).
  Future<void> _applyThemeNow(ThemeMode target) async {
    if (_applied) return;
    _applied = true;
    try {
      await ref.read(themeModeProvider.notifier).applyTheme(target);
    } catch (_) {}
  }

  void _clearTransition() {
    if (_cleared) return;
    _cleared = true;
    _fallbackTimer?.cancel();
    try {
      ref.read(themeTransitionProvider.notifier).state = null;
    } catch (_) {}
  }

  void _armFallback(ThemeMode target) {
    _fallbackTimer?.cancel();
    _applied = false;
    _cleared = false;
    // Safety net: if animation callbacks never fire, apply the theme
    // and clear anyway so the button can never appear dead.
    _fallbackTimer = Timer(const Duration(milliseconds: 1800), () async {
      await _applyThemeNow(target);
      _clearTransition();
    });
  }

  @override
  Widget build(BuildContext context) {
    final target = ref.watch(themeTransitionProvider);

    if (target == null) {
      _fallbackTimer?.cancel();
      _applied = false;
      _cleared = false;
      return widget.child;
    }

    // (Re)arm the fallback each time a new transition starts.
    // Scheduling post-frame avoids setState-during-build issues.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(themeTransitionProvider) == target) {
        _armFallback(target);
      }
    });

    // dark→light: white smoke; light→dark: black smoke.
    final isLight = target == ThemeMode.light;
    final smokeColor = isLight ? Colors.white : const Color(0xFF0A0A0A);

    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: ThemeSmokeOverlay(
            key: ValueKey('theme_smoke_$target'),
            color: smokeColor,
            duration: const Duration(milliseconds: 900),
            onMidpoint: () => _applyThemeNow(target),
            onComplete: _clearTransition,
          ),
        ),
      ],
    );
  }
}

/// Sits above the root navigator and pushes a non-dismissible lock route when
/// the session times out, keeping the underlying navigation state alive.
class _AppLockOverlay extends ConsumerStatefulWidget {
  final Widget child;
  const _AppLockOverlay({required this.child});

  @override
  ConsumerState<_AppLockOverlay> createState() => _AppLockOverlayState();
}

class _AppLockOverlayState extends ConsumerState<_AppLockOverlay>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    setCurrentLocale(ref.read(localeProvider).languageCode);
    MoneyFormatService.loadAll();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      setCurrentLocale(ref.read(localeProvider).languageCode);
      // Deliver any notification tap that arrived before the navigator
      // existed (cold-start tap) now that the app is ready.
      try {
        ref.read(fcmServiceProvider).flushPendingNavigation();
      } catch (_) {}
      try {
        ref.read(notificationServiceProvider).flushPendingTaps();
      } catch (_) {}
      try {
        RecurringReminderService.flushPendingTaps();
      } catch (_) {}
      try {
        NotificationRouter.flushPending();
      } catch (_) {}
      // Cold-start safety net: keep retrying for a short window until the
      // splash/login finishes, then the queued tap opens its exact screen.
      for (final ms in [800, 1600, 3000, 5000, 8000, 12000, 20000, 30000]) {
        Future.delayed(Duration(milliseconds: ms), () {
          try {
            NotificationRouter.flushPending();
          } catch (_) {}
          try {
            ref.read(fcmServiceProvider).flushPendingNavigation();
          } catch (_) {}
          try {
            ref.read(notificationServiceProvider).flushPendingTaps();
          } catch (_) {}
        });
      }
      ref
          .read(sessionTimeoutProvider.notifier)
          .setAuthenticated(ref.read(authProvider).isAuthenticated);
      // Cold start with timeout protection ON: require PIN/biometric unlock
      // even though the idle timer just restarted (killing + reopening the
      // app must show the same lock screen as an idle timeout).
      try {
        if (ref.read(authProvider).isAuthenticated) {
          await ref
              .read(sessionTimeoutProvider.notifier)
              .lockIfProtected();
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Re-register the FCM token on every resume so pushes never silently
    // stop after a token rotation, reinstall or long background.
    try {
      ref.read(fcmServiceProvider).syncToken();
    } catch (_) {}
    try {
      ref.invalidate(debtUnreadProvider('personal'));
      ref.invalidate(debtUnreadProvider('merchant'));
      ref.invalidate(chatUnreadProvider('personal'));
      ref.invalidate(chatUnreadProvider('merchant'));
    } catch (_) {}
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    setCurrentLocale(ref.watch(localeProvider).languageCode);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(authProvider, (prev, next) {
      ref
          .read(sessionTimeoutProvider.notifier)
          .setAuthenticated(next.isAuthenticated);
      if (next.isAuthenticated && !(prev?.isAuthenticated ?? false)) {
        unawaited(ref.read(currencyEngineProvider).load());
        // Login may finish after the cold-start retry window has elapsed.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !ref.read(authProvider).isAuthenticated) return;
          try {
            NotificationRouter.flushPending();
          } catch (_) {}
          try {
            ref.read(fcmServiceProvider).flushPendingNavigation();
          } catch (_) {}
          try {
            ref.read(notificationServiceProvider).flushPendingTaps();
          } catch (_) {}
        });
      }

      // Keep the section in sync with the usage mode (drives the per-section
      // preferences: theme, language, help clicker, money format, profile).
      ref.read(activeSectionProvider.notifier).state =
          sectionFromMode(next.user?.preferredUsageMode);

      final prevId = prev?.user?.id ?? '';
      final nextId = next.user?.id ?? '';
      if (prevId != nextId && nextId.isNotEmpty) {
        final section = ref.read(activeSectionProvider).name;
        MoneyFormatService.loadAll('$nextId-$section');
      }
    });

    if (ref.watch(authProvider.select((state) => state.isAuthenticated))) {
      ref.watch(currencyEngineProvider);
    }

    // Preferences that are stored per section must re-apply when the usage
    // mode (section) changes: money format + locale.
    ref.listen<AppSection>(activeSectionProvider, (prev, next) {
      final id = ref.read(currentUserIdProvider);
      if (id.isNotEmpty) {
        MoneyFormatService.loadAll('$id-${next.name}');
      }
      setCurrentLocale(ref.read(localeProvider).languageCode);
    });

    ref.listen<SessionTimeoutState>(sessionTimeoutProvider, (prev, next) {
      final wasLocked = prev?.locked ?? false;
      final rootNavigator = rootNavigatorKey.currentState;
      if (next.locked && !wasLocked) {
        if (rootNavigator != null) {
          rootNavigator.push(
            PageRouteBuilder(
              opaque: true,
              barrierDismissible: false,
              transitionDuration: const Duration(milliseconds: 200),
              reverseTransitionDuration: const Duration(milliseconds: 200),
              pageBuilder: (_, _, _) => const SessionLockScreen(),
              transitionsBuilder: (_, animation, _, child) {
                return FadeTransition(
                  opacity: animation,
                  child: child,
                );
              },
            ),
          );
        }
      } else if (!next.locked && wasLocked) {
        if (rootNavigator != null && rootNavigator.canPop()) {
          rootNavigator.pop();
        }
      }
    });

    return widget.child;
  }
}
