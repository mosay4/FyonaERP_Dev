import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/router/role_config.dart';

/// Regression: every route reachable from the business home MUST be in the
/// route allow-list — otherwise the router guard silently bounces it back to
/// /dashboard (the exact bug that made «المعاملات» and «عرض الكل» fail).
void main() {
  const reachableFromBusinessHome = [
    '/sales/add', '/sales', '/purchases/add',
    '/customers', '/suppliers', '/inventory',
    '/business/transactions', '/business/transactions/details',
    '/business/income-expense',
  ];

  test('business personas can open every home-reachable route', () {
    for (final persona in ['owner', 'owner_both', 'super_admin']) {
      for (final route in reachableFromBusinessHome) {
        expect(
          isRouteAllowed(route, persona, preferredUsageMode: 'business'),
          isTrue,
          reason: '$route must be allowed for $persona',
        );
      }
    }
  });

  test('the transactions details path is covered by its prefix', () {
    expect(
      isRouteAllowed('/business/transactions/details', 'owner',
          preferredUsageMode: 'business'),
      isTrue,
    );
  });
}
