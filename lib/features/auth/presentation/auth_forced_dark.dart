import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/route_names.dart';

/// The sign-in flow (login + its directly related public screens: create
/// account, e-mail OTP verification, forgot-password OTP/reset) always
/// renders in the dark theme, whatever the user picked in settings.
///
/// The user's saved theme preference is never touched: the app root only
/// swaps the *effective* [ThemeMode] (and the mode-aware [AppColors]
/// palette) while one of these routes is on screen.
class AuthForcedDark {
  AuthForcedDark._();

  static const Set<String> paths = {
    RouteNames.login,
    RouteNames.register,
    RouteNames.verifyEmail,
    RouteNames.forgotPassword,
  };

  static bool isForcedPath(String path) => paths.contains(path);

  /// Effective theme for the app root.
  static ThemeMode effectiveMode(ThemeMode userMode, String path) =>
      isForcedPath(path) ? ThemeMode.dark : userMode;

  static final Expando<_ForcedDarkListenable> _cache = Expando();

  /// Notifies only when the current route enters/leaves the sign-in flow,
  /// so the app root does not rebuild on every navigation.
  static ValueListenable<bool> listenable(GoRouter router) =>
      _cache[router] ??= _ForcedDarkListenable(router);
}

class _ForcedDarkListenable extends ValueNotifier<bool> {
  _ForcedDarkListenable(this._router) : super(_compute(_router)) {
    _router.routerDelegate.addListener(_sync);
  }

  final GoRouter _router;

  static bool _compute(GoRouter r) {
    try {
      return AuthForcedDark.isForcedPath(
          r.routerDelegate.currentConfiguration.uri.path);
    } catch (_) {
      return false;
    }
  }

  void _sync() {
    final next = _compute(_router);
    if (next == value) return;
    // The initial route is set while the Router builds — never mark the
    // root dirty mid-build; apply it right after this frame instead.
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => value = _compute(_router));
      SchedulerBinding.instance.scheduleFrame();
      return;
    }
    value = next;
  }
}
