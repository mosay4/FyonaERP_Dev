import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

/// Branded floating notification for every new app toast: solid
/// success-green / danger-red (never plain white), framed, Cairo font,
/// leading status icon. Readable on both light and dark themes.
void showFyonaSnack(BuildContext context, String message,
    {required bool success}) {
  final color = success ? AppColors.success : AppColors.danger;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        children: [
          Icon(
              success
                  ? Icons.check_circle_rounded
                  : Icons.error_outline_rounded,
              color: Colors.white,
              size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message,
                style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white)),
          ),
        ],
      ),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.white.withAlpha(90)),
      ),
      duration: const Duration(seconds: 3),
    ),
  );
}
