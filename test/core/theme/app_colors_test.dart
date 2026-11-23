import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';

void main() {
  group('AppColors', () {
    test('primary color is correct', () {
      expect(AppColors.primary, const Color(0xFFA01530));
    });

    test('background colors defined', () {
      expect(AppColors.background, isNotNull);
      expect(AppColors.surface, isNotNull);
      expect(AppColors.surfaceVariant, isNotNull);
    });

    test('semantic colors defined', () {
      expect(AppColors.success, isNotNull);
      expect(AppColors.warning, isNotNull);
      expect(AppColors.danger, isNotNull);
      expect(AppColors.info, isNotNull);
    });

    test('text colors defined', () {
      expect(AppColors.textPrimary, isNotNull);
      expect(AppColors.textSecondary, isNotNull);
    });
  });

  group('statusColor', () {
    test('returns success for paid status', () {
      expect(AppColors.statusColor('paid'), AppColors.success);
    });

    test('returns danger for cancelled status', () {
      expect(AppColors.statusColor('cancelled'), AppColors.danger);
    });

    test('returns info for confirmed status', () {
      expect(AppColors.statusColor('confirmed'), AppColors.info);
    });

    test('returns secondary for unknown status', () {
      expect(AppColors.statusColor('unknown'), AppColors.textSecondary);
    });
  });

  group('accountTypeColor', () {
    test('returns success for asset', () {
      expect(AppColors.accountTypeColor('asset'), AppColors.success);
    });

    test('returns warning for liability', () {
      expect(AppColors.accountTypeColor('liability'), AppColors.warning);
    });

    test('returns danger for expense', () {
      expect(AppColors.accountTypeColor('expense'), AppColors.danger);
    });
  });
}
