import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/utils/subscription_identity.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/features/auth/presentation/providers/auth_provider.dart';

/// 1. The usage-mode question is asked ONCE per account: a second device
///    must not re-ask when the account already chose server-side.
/// 2. The trial plan always shares the free (green) identity, online or not.
void main() {
  group('needsUsageChoice', () {
    test('brand-new account on a fresh device is asked', () {
      expect(
        needsUsageChoice(
            usageMode: null, savedMode: null, serverMode: null),
        isTrue,
      );
    });

    test('returning account on a new device is NOT re-asked', () {
      expect(
        needsUsageChoice(
            usageMode: null, savedMode: null, serverMode: 'personal'),
        isFalse,
      );
    });

    test('explicitly passed mode never asks', () {
      expect(
        needsUsageChoice(
            usageMode: 'business', savedMode: null, serverMode: null),
        isFalse,
      );
    });

    test('locally saved mode never asks', () {
      expect(
        needsUsageChoice(
            usageMode: null, savedMode: 'personal', serverMode: null),
        isFalse,
      );
    });

    test('empty strings count as missing', () {
      expect(
        needsUsageChoice(usageMode: null, savedMode: '', serverMode: ''),
        isTrue,
      );
    });
  });

  group('trial identity', () {
    test('trial maps to the free identity', () {
      expect(subscriptionIdentityKey('trial'), subIdentityFree);
      expect(subscriptionIdentityKey('تجريبي'), subIdentityFree);
      expect(subscriptionIdentityKey('TRIAL'), subIdentityFree);
    });

    test('trial renders green like free', () {
      expect(subscriptionIdentityColor('trial'), AppColors.success);
      expect(subscriptionIdentityColor('free'), AppColors.success);
    });

    test('other plans keep their colors', () {
      expect(subscriptionIdentityColor('personal'), AppColors.info);
      expect(subscriptionIdentityColor('business'), AppColors.danger);
      expect(subscriptionIdentityColor('premium'), AppColors.gold);
    });
  });
}
