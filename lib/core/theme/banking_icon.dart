import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';

class BankingIcon extends StatelessWidget {
  final List<List<dynamic>> icon;
  final double size;
  final Color? color;
  final double? strokeWidth;

  const BankingIcon({
    super.key,
    required this.icon,
    this.size = 24,
    this.color,
    this.strokeWidth,
  });

  @override
  Widget build(BuildContext context) {
    return HugeIcon(
      icon: icon,
      size: size,
      color: color,
      strokeWidth: strokeWidth,
    );
  }
}
