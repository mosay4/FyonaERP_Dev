import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/subscription/domain/section_access.dart';

void main() {
  final now = DateTime.utc(2026, 10, 2);
  test('one expired section never blocks the other active section', () {
    final status = <String, dynamic>{'sections': {
      'personal': {'active': true, 'end_date': now.toIso8601String()},
      'business': {'active': true, 'end_date': now.add(const Duration(days: 1)).toIso8601String()},
    }};
    expect(hasSectionAccess(status, 'personal', now: now), isFalse);
    expect(hasSectionAccess(status, 'business', now: now), isTrue);
  });
  test('missing and revoked entitlements do not grant access', () {
    expect(hasSectionAccess(null, 'personal'), isFalse);
    expect(hasSectionAccess({'sections': {'personal': {
      'active': false, 'end_date': now.add(const Duration(days: 365)).toIso8601String(),
    }}}, 'personal', now: now), isFalse);
  });
  test('replaced individual subscriptions are not active alongside Premium', () {
    final status = <String, dynamic>{'subscriptions': {
      'personal': {'status': 'replaced', 'end_date': now.add(const Duration(days: 365)).toIso8601String()},
      'premium': {'status': 'active', 'end_date': now.add(const Duration(days: 30)).toIso8601String()},
    }};
    expect(hasPaidPlan(status, 'personal', now: now), isFalse);
    expect(hasPaidPlan(status, 'premium', now: now), isTrue);
  });
}
