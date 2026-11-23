import 'package:flutter/material.dart';
import 'breakpoints.dart';

class ResponsiveBuilder extends StatelessWidget {
  final Widget Function(
    BuildContext context,
    double width,
    DeviceType deviceType,
  ) builder;

  const ResponsiveBuilder({
    super.key,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final deviceType = Breakpoints.deviceType(width);
        return builder(context, width, deviceType);
      },
    );
  }
}

class DeviceWidget extends StatelessWidget {
  final Widget? phone;
  final Widget? tablet;
  final Widget? desktop;

  const DeviceWidget({
    super.key,
    this.phone,
    this.tablet,
    this.desktop,
  });

  @override
  Widget build(BuildContext context) {
    return ResponsiveBuilder(
      builder: (context, width, type) {
        if (type == DeviceType.desktop && desktop != null) return desktop!;
        if ((type == DeviceType.tablet || type == DeviceType.tabletLarge) && tablet != null) return tablet!;
        return phone ?? tablet ?? desktop ?? const SizedBox.shrink();
      },
    );
  }
}

class VisibilityByDevice extends StatelessWidget {
  final Widget child;
  final bool showOnPhone;
  final bool showOnTablet;
  final bool showOnDesktop;

  const VisibilityByDevice({
    super.key,
    required this.child,
    this.showOnPhone = true,
    this.showOnTablet = true,
    this.showOnDesktop = true,
  });

  @override
  Widget build(BuildContext context) {
    return ResponsiveBuilder(
      builder: (context, width, type) {
        final isPhone = Breakpoints.isPhone(width);
        final isTablet = Breakpoints.isTablet(width);
        final isDesktop = Breakpoints.isDesktop(width);

        if (isPhone && !showOnPhone) return const SizedBox.shrink();
        if (isTablet && !showOnTablet) return const SizedBox.shrink();
        if (isDesktop && !showOnDesktop) return const SizedBox.shrink();
        return child;
      },
    );
  }
}
