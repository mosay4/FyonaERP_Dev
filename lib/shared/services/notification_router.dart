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

  /// Set by the app shell: makes the section of [route] the active one
  /// before a tap opens it (a Personal debt reminder tapped while the app
  /// was left in Business would otherwise be bounced to the Business home).
  /// Returns once the switch is done; never throws into the router.
  static Future<void> Function(String route)? prepareSection;

  /// How many times one tap may be re-queued after a gate (account entry,
  /// phone entry, sign-in…) bounced its navigation.
  static const int maxBounces = 3;
  static final Map<String, int> _bounces = {};

  @visibleForTesting
  static void resetForTests() {
    _pending.clear();
    _bounces.clear();
    prepareSection = null;
  }

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
    if (p.startsWith('/')) {
      // Admin-console routes don't exist in the app: open the inbox.
      if (p.startsWith('/admin')) return RouteNames.notifications;
      return p;
    }

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
      // Product expiry / low stock alerts.
      case 'inventory':
        return '/inventory$query';
      // Scheduled reminders have no screen of their own: the inbox shows them.
      case 'reminders':
        return RouteNames.notifications;
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
    // Any other named payload still opens the notification inbox (where the
    // full text lives) instead of doing nothing.
    return RouteNames.notifications;
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
      return isGate(loc);
    } catch (_) {
      return false;
    }
  }

  /// Locations that decide the next screen themselves: a tap navigated
  /// while one of them is showing would be overridden, so it waits.
  static bool isGate(String loc) =>
      loc == RouteNames.splash ||
      // Account entry decides the home screen right after: navigating
      // now would be overridden, so the tap waits for it.
      loc == '/account-entry' ||
      loc == RouteNames.login ||
      loc == RouteNames.reentry ||
      loc == RouteNames.chooseUsage ||
      loc == RouteNames.phoneEntry ||
      loc.isEmpty ||
      loc == '/';

  /// The router's guards are async: a tap delivered a moment before the
  /// session/entitlements are settled can be redirected to account entry,
  /// which then opens the home screen — and the tap would be lost. When
  /// the navigation that follows ends on a gate instead of [route], the tap
  /// is queued again and delivered after the gate (bounded by [maxBounces]).
  /// No timers: the router's own change notification is observed once.
  static void _confirmDelivery(BuildContext ctx, String payload, String route) {
    final GoRouter router;
    try {
      router = GoRouter.of(ctx);
    } catch (_) {
      return;
    }
    final target = Uri.tryParse(route)?.path ?? route;
    final delegate = router.routerDelegate;
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    late final VoidCallback listener;
    listener = () {
      delegate.removeListener(listener);
      try {
        if (DateTime.now().isAfter(deadline)) return;
        final loc = delegate.currentConfiguration.uri.path;
        if (loc == target || !isGate(loc)) {
          _bounces.remove(payload);
          return;
        }
        final n = (_bounces[payload] ?? 0) + 1;
        if (n > maxBounces) {
          _bounces.remove(payload);
          return;
        }
        _bounces[payload] = n;
        queuePending(payload);
      } catch (_) {}
    };
    delegate.addListener(listener);
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
      final prepare = prepareSection;
      if (prepare == null) {
        _confirmDelivery(ctx, payload, route);
        ctx.go(route);
        return true;
      }
      // Switch to the route's section first, then open the exact screen.
      Future<void>(() => prepare(route))
          .timeout(const Duration(seconds: 5))
          .catchError((_) {})
          .whenComplete(() {
        final live = rootNavigatorKey.currentContext;
        if (live == null || !live.mounted) {
          queuePending(payload);
          return;
        }
        try {
          _confirmDelivery(live, payload, route);
          live.go(route);
        } catch (_) {}
      });
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
