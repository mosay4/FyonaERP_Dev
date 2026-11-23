import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';

void main() {
  group('LoginPage', () {
    test('FYONA color scheme is correct', () {
      expect(AppColors.primary, const Color(0xFFA01530));
      expect(AppColors.background, const Color(0xFF0A0A0A));
      expect(AppColors.surface, const Color(0xFF151515));
    });

    test('status colors are defined', () {
      expect(AppColors.statusColor('paid'), AppColors.success);
      expect(AppColors.statusColor('cancelled'), AppColors.danger);
    });
  });
}
