import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/router/role_config.dart';
import 'package:fyona_flutter/core/router/route_names.dart';

void main() {
  group('Personal / Business profile separation', () {
    test('profileForMode picks the right profile per usage mode', () {
      expect(RouteNames.profileForMode('personal'), '/profile');
      expect(RouteNames.profileForMode('business'), '/business/profile');
      expect(RouteNames.profileForMode('both'), '/business/profile');
      expect(RouteNames.profileForMode(null), '/business/profile');
    });

    test('routeMode classifies both profiles correctly', () {
      expect('/profile'.routeMode, 'personal');
      expect('/business/profile'.routeMode, 'business');
    });

    test('route guard allows each profile only in its own mode', () {
      expect(
          isRouteAllowed('/profile', 'owner', preferredUsageMode: 'personal'),
          isTrue);
      expect(
          isRouteAllowed('/business/profile', 'owner',
              preferredUsageMode: 'business'),
          isTrue);
      // Cross-mode is rejected (fully separate).
      expect(
          isRouteAllowed('/business/profile', 'owner',
              preferredUsageMode: 'personal'),
          isFalse);
      expect(isRouteAllowed('/profile', 'owner', preferredUsageMode: 'business'),
          isFalse);
    });
  });
}
