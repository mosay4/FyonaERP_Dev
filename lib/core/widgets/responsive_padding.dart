import 'package:flutter/material.dart';
import '../responsive/responsive_helper.dart';
import '../responsive/breakpoints.dart';

class ResponsivePadding extends StatelessWidget {
  final Widget child;

  const ResponsivePadding({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return Padding(
      padding: ResponsiveHelper.screenPadding(width),
      child: child,
    );
  }
}

class ResponsiveContentContainer extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;

  const ResponsiveContentContainer({
    super.key,
    required this.child,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final maxWidth = Breakpoints.contentMaxWidth(width);
    final effectivePadding = padding ?? ResponsiveHelper.screenPadding(width);

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: effectivePadding,
          child: child,
        ),
      ),
    );
  }
}
