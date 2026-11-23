enum DeviceType {
  phoneSmall,
  phone,
  phoneLarge,
  tablet,
  tabletLarge,
  desktop,
}

class Breakpoints {
  Breakpoints._();

  static const double phoneSmall = 360;
  static const double phone = 400;
  static const double phoneLarge = 480;
  static const double tablet = 600;
  static const double tabletLarge = 768;
  static const double desktop = 1024;
  static const double desktopWide = 1440;

  static DeviceType deviceType(double width) {
    if (width < phoneSmall) return DeviceType.phoneSmall;
    if (width < phoneLarge) return DeviceType.phone;
    if (width < tablet) return DeviceType.phoneLarge;
    if (width < tabletLarge) return DeviceType.tablet;
    if (width < desktop) return DeviceType.tabletLarge;
    return DeviceType.desktop;
  }

  static bool isPhone(double width) => width < tablet;
  static bool isTablet(double width) => width >= tablet && width < desktop;
  static bool isDesktop(double width) => width >= desktop;

  static int gridColumns(double width) {
    if (width < tablet) return 1;
    if (width < desktop) return 2;
    return 4;
  }

  static double navHeight(double width) {
    if (width < tablet) return 64;
    if (width < desktop) return 72;
    return 80;
  }

  static double dialogWidth(double width) {
    if (width < tablet) return width * 0.92;
    if (width < desktop) return 480;
    return 560;
  }

  static double contentMaxWidth(double width) {
    if (isDesktop(width)) return 1200;
    return width;
  }
}
