import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/subscription/data/models/subscription_models.dart';

void main() {
  group('PlanKey', () {
    test('maps plan keys to backend numeric ids', () {
      expect(PlanKey.personal.backendId, 1);
      expect(PlanKey.business.backendId, 2);
      expect(PlanKey.premium.backendId, 3);
    });

    test('fromKey resolves string keys', () {
      expect(PlanKey.fromKey('personal'), PlanKey.personal);
      expect(PlanKey.fromKey('business'), PlanKey.business);
      expect(PlanKey.fromKey('premium'), PlanKey.premium);
    });

    test('fromKey returns null for unknown or null values', () {
      expect(PlanKey.fromKey('personal-plan'), isNull);
      expect(PlanKey.fromKey('123'), isNull);
      expect(PlanKey.fromKey(null), isNull);
    });

    test('keys are never parsed as numbers', () {
      for (final k in PlanKey.values) {
        expect(k.name, isNot(matches('^[0-9]+\$')));
      }
    });
  });
}
