import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';

class DualToneHugeIcon extends StatelessWidget {
  final List<List<dynamic>> icon;
  final Color accentColor;
  final Color baseColor;
  final double size;
  final double strokeWidth;

  const DualToneHugeIcon({
    super.key,
    required this.icon,
    this.accentColor = const Color(0xFFA01530),
    this.baseColor = const Color(0xFF999999),
    this.size = 24.0,
    this.strokeWidth = 1.6,
  });

  @override
  Widget build(BuildContext context) {
    // Single crisp shape only — no stacked faint copy on top.
    return HugeIcon(
      icon: icon,
      color: accentColor,
      size: size,
      strokeWidth: strokeWidth + 0.2,
    );
  }
}

