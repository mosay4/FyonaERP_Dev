import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/router/role_config.dart';

/// ROOT-CAUSE regression test: pressing المطابقة/التقارير used to bounce
/// straight back to the dashboard because the route guard's allowlist
/// (`isRouteAllowed`) didn't know the new paths. Every reconciliation and
/// reports route MUST be allowed for the business personas.
void main() {
  test('business owner: every reconciliation + reports route is allowed',
      () {
    const routes = [
      '/reconciliation',
      '/reconciliation/bank',
      '/reconciliation/bank/run?ids=a1',
      '/reconciliation/inventory',
      '/reconciliation/inventory/count',
      '/reconciliation/archive',
      '/reconciliation/detail?id=x',
      '/reports',
      '/reports/view?kind=sales',
    ];
    for (final r in routes) {
      expect(isRouteAllowed(r, 'owner', preferredUsageMode: 'business'), true,
          reason: 'owner should reach $r');
      expect(isRouteAllowed(r, 'owner_both'), true,
          reason: 'owner_both should reach $r');
      expect(isRouteAllowed(r, 'super_admin'), true,
          reason: 'super_admin should reach $r');
      expect(isRouteAllowed(r, 'staff'), true,
          reason: 'staff should reach $r (backend enforces permissions)');
    }
  });

  test('personal mode still cannot open business reconciliation/reports',
      () {
    expect(isRouteAllowed('/reconciliation', 'owner_personal'), false);
    expect(isRouteAllowed('/reports', 'personal'), false);
  });

  /// ROOT-CAUSE regression: the debt-notification bell bounced the user to the
  /// home screen because `/debt-notifications` matched no allowed prefix. The
  /// business/personal centers and the legacy path MUST be allowed everywhere
  /// they can be tapped.
  test('commercial-debt notification routes are allowed in their contexts',
      () {
    expect(isRouteAllowed('/debts/notifications', 'owner',
        preferredUsageMode: 'business'), true);
    expect(isRouteAllowed('/debts/notifications', 'staff'), true);
    expect(isRouteAllowed('/personal/debt-notifications', 'owner_personal'),
        true);
    expect(isRouteAllowed('/personal/debt-notifications', 'personal'), true);
    // Legacy bare path (older pushes / deep links) works in both modes.
    expect(isRouteAllowed('/debt-notifications', 'owner',
        preferredUsageMode: 'business'), true);
    expect(isRouteAllowed('/debt-notifications', 'owner_personal'), true);
    // A business user must not be silently routed into the personal center.
    expect(isRouteAllowed('/personal/debt-notifications', 'owner',
        preferredUsageMode: 'business'), false);
  });
}
