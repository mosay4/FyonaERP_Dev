import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/core/router/shell_keys.dart';

// ─────────────────────────────────────────────────────────────
// NotificationRouter — the ONE central tap router for every
// notification surface in the app:
//
//   FCM taps (FcmService) · local-plugin taps (NotificationService) ·
//   recurring taps · native alarm taps (AlarmTapBridge)
//
// All of them delegate here. Route payloads keep their query params
// (`/personal/debts?debtId=`, `/personal/recurring/detail?id=`,
// `/notifications?id=`); slash-less payloads (`notifications?id=X`)
// are repaired, never dropped; unknown payloads are a safe no-op.
// ─────────────────────────────────────────────────────────────
class NotificationRouter {
  NotificationRouter._();

  /// Cold-start taps that arrived before the navigator existed wait here
  /// until the app shell flushes them — a tap never silently dies.
  static final List<String> _pending = [];

  static List<String> get pendingCountForTests => List.unmodifiable(_pending);

  static void queuePending(String payload) {
    if (payload.isEmpty || _pending.contains(payload)) return;
    _pending.add(payload);
  }

  /// Flush centrally-queued taps. Returns the number delivered.
  static int flushPending({
    String homeRoute = RouteNames.personalDashboard,
    void Function()? onSaraTap,
    void Function(String route)? onSubscriptionRoute,
  }) {
    if (_pending.isEmpty) return 0;
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null || _notReady(ctx)) return 0;
    final queued = List<String>.from(_pending);
    _pending.clear();
    var delivered = 0;
    for (final payload in queued) {
      if (navigate(
        ctx,
        payload,
        homeRoute: homeRoute,
        onSaraTap: onSaraTap,
        onSubscriptionRoute: onSubscriptionRoute,
      )) {
        delivered++;
      }
    }
    return delivered;
  }

  /// Pure payload → absolute app route (query preserved). Returns null
  /// when the payload is empty or unknown (caller must no-op).
  static String? resolveRoute(
    String payload, {
    String homeRoute = RouteNames.personalDashboard,
  }) {
    final p = payload.trim();
    if (p.isEmpty) return null;
    // Absolute routes (with or without query) pass through untouched —
    // this preserves ?id= / ?debtId= / invoice params.
    if (p.startsWith('/')) return p;

    final qIndex = p.indexOf('?');
    final base = qIndex < 0 ? p : p.substring(0, qIndex);
    final query = qIndex < 0 ? '' : p.substring(qIndex); // keeps '?…'

    switch (base) {
      case 'sara':
        return RouteNames.personalAi;
      case 'home':
        return homeRoute;
      case 'sessions':
        return RouteNames.sessions;
      case 'suggestions':
      case 'admin_suggestions':
        return RouteNames.suggestions;
      case 'notifications':
        return '${RouteNames.notifications}$query';
      default:
        break;
    }
    // Maintenance rows open the notifications list (in-app center).
    if (base.startsWith('maintenance-') || base.startsWith('maintenance_')) {
      return RouteNames.notifications;
    }
    // Defensive prefix form: 'notifications…' (e.g. 'notifications?id=x'
    // with extra suffixes) still lands on the list with params kept.
    if (base.startsWith('notifications')) {
      return '/$p';
    }
    // Slash-less absolute routes ('personal/debts?debtId=x',
    // 'subscription/invoice?...') are repaired, never dropped.
    if (p.startsWith('personal/') || p.startsWith('subscription/')) {
      return '/$p';
    }
    return null;
  }

  static bool _notReady(BuildContext ctx) {
    try {
      String loc;
      try {
        loc = GoRouterState.of(ctx).uri.path;
      } catch (_) {
        // The root navigator context is above the route's state scope.
        loc = GoRouter.of(ctx).routeInformationProvider.value.uri.path;
      }
      return loc == RouteNames.splash ||
          loc == RouteNames.login ||
          loc == RouteNames.reentry ||
          loc == RouteNames.chooseUsage ||
          loc.isEmpty ||
          loc == '/';
    } catch (_) {
      return false;
    }
  }

  /// Resolves [payload] and navigates. Returns true when a navigation
  /// was issued. Never throws.
  static bool navigate(
    BuildContext ctx,
    String payload, {
    String homeRoute = RouteNames.personalDashboard,
    void Function()? onSaraTap,
    void Function(String route)? onSubscriptionRoute,
  }) {
    try {
      if (_notReady(ctx)) {
        if (resolveRoute(payload, homeRoute: homeRoute) != null) {
          queuePending(payload);
        }
        return false;
      }
      final route = resolveRoute(payload, homeRoute: homeRoute);
      if (route == null) return false;
      final base = payload.trim().split('?').first;
      if (base == 'sara') {
        try {
          onSaraTap?.call();
        } catch (_) {}
      }
      if (route.startsWith('/subscription')) {
        try {
          onSubscriptionRoute?.call(route);
        } catch (_) {}
      }
      ctx.go(route);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Best-effort navigation from a context-less site (cold start, resume):
  /// navigates now when the navigator exists, otherwise queues centrally.
  static void navigateOrQueue(
    String payload, {
    String homeRoute = RouteNames.personalDashboard,
    void Function()? onSaraTap,
    void Function(String route)? onSubscriptionRoute,
  }) {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) {
      queuePending(payload);
      return;
    }
    final ok = navigate(
      ctx,
      payload,
      homeRoute: homeRoute,
      onSaraTap: onSaraTap,
      onSubscriptionRoute: onSubscriptionRoute,
    );
    if (!ok && resolveRoute(payload, homeRoute: homeRoute) != null) {
      queuePending(payload);
    }
  }
}
