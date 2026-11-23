import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';

void main() {
  test('AppColors primary color is correct', () {
    expect(AppColors.primary, const Color(0xFFA01530));
  });
}
