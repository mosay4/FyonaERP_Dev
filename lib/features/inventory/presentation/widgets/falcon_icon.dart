import 'package:flutter/material.dart';

/// Original supplied artwork, never tinted, cropped or redrawn.
class FalconIcon extends StatelessWidget {
  final double size;
  // Kept for source compatibility; artwork must retain its original colors.
  final Color? color;
  const FalconIcon({super.key, this.size = 22, this.color});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Image.asset(
      dark ? 'assets/images/falcon_dark.png' : 'assets/images/falcon_light.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      semanticLabel: 'FYONA Falcon',
      gaplessPlayback: true,
    );
  }
}
