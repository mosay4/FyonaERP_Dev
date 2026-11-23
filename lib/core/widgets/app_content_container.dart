import 'package:flutter/material.dart';

class AppContentContainer extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;

  const AppContentContainer({
    super.key,
    required this.child,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200),
        child: Padding(
          padding: padding ?? _responsivePadding(width),
          child: child,
        ),
      ),
    );
  }

  EdgeInsets _responsivePadding(double width) {
    if (width >= 1440) return const EdgeInsets.symmetric(horizontal: 64, vertical: 32);
    if (width >= 1200) return const EdgeInsets.symmetric(horizontal: 40, vertical: 28);
    if (width >= 992) return const EdgeInsets.symmetric(horizontal: 40, vertical: 24);
    if (width >= 768) return const EdgeInsets.symmetric(horizontal: 24, vertical: 20);
    return const EdgeInsets.symmetric(horizontal: 16, vertical: 16);
  }
}
