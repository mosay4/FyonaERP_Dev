import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/shared/services/notification_router.dart';

/// Every payload the server or the device puts on a notification must open
/// a screen that really exists in the app router (taps never die or bounce).
Set<String> _routerPaths() {
  final names = File('lib/core/router/route_names.dart').readAsStringSync();
  final consts = {
    for (final m in RegExp(r"static const String (\w+)\s*=\s*'([^']+)'").allMatches(names))
      m.group(1)!: m.group(2)!,
  };
  final router = File('lib/core/router/app_router.dart').readAsStringSync();
  return {
    for (final m in RegExp(r"path:\s*(?:RouteNames\.(\w+)|'([^']+)')").allMatches(router))
      if ((m.group(1) != null ? consts[m.group(1)] : m.group(2)) case final String p) p,
  };
}

bool _exists(Set<String> paths, String route) {
  final path = Uri.parse(route).path;
  if (paths.contains(path)) return true;
  final parts = path.split('/');
  return paths.any((p) {
    final q = p.split('/');
    if (q.length != parts.length) return false;
    for (var i = 0; i < q.length; i++) {
      if (!q[i].startsWith(':') && q[i] != parts[i]) return false;
    }
    return true;
  });
}

void main() {
  final paths = _routerPaths();

  test('every backend notification payload resolves to a real screen', () {
    final payloads = <String>{};
    final re = RegExp(
        r'''(?:route|_route|invite_route|party_route|push_route|action_payload)\s*[=:]\s*f?["'](/?[a-z][^"'\s{]*)''');
    final re2 = RegExp(r'''["']route["']\s*:\s*f?["'](/?[a-z][^"'\s{]*)''');
    for (final f in Directory('../implementation/backend/app').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.py')) continue;
      final s = f.readAsStringSync();
      for (final m in [...re.allMatches(s), ...re2.allMatches(s)]) {
        payloads.add(m.group(1)!.replaceAll(RegExp(r'[?&]$'), ''));
      }
    }
    expect(payloads, isNotEmpty);
    // Non-notification uses of the same field names.
    payloads.removeWhere((p) => p == 'route' || p == 'string');
    for (final p in payloads) {
      final route = NotificationRouter.resolveRoute(p);
      expect(route, isNotNull, reason: p);
      expect(_exists(paths, route!), isTrue, reason: '$p → $route');
    }
  });

  test('device-made notifications and special payloads open real screens', () {
    for (final p in [
      'home', 'sara', 'inventory', 'reminders', 'notifications', 'sessions',
      'suggestions', 'admin_suggestions', 'maintenance-feature',
      '/admin/subscription-requests', '/subscription/invoice?invoice_no=1',
      '/personal/savings-detail/abc', '/personal/budget/detail?id=1',
      '/personal/reports/view?kind=categories&period=week',
      '/personal/quick-add?type=expense', '/branches/transfers/9',
    ]) {
      final route = NotificationRouter.resolveRoute(p)!;
      expect(_exists(paths, route), isTrue, reason: '$p → $route');
    }
  });
}
