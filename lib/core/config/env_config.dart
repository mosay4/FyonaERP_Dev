import 'package:flutter/foundation.dart';

class EnvConfig {
  EnvConfig._();

  static bool get isDebug => kDebugMode;
  static bool get isRelease => kReleaseMode;
  static bool get isProfile => kProfileMode;

  static bool get isAndroid =>
      defaultTargetPlatform == TargetPlatform.android;

  static bool get isIOS => defaultTargetPlatform == TargetPlatform.iOS;

  static bool get isWindows =>
      defaultTargetPlatform == TargetPlatform.windows;

  static bool get isMacOS => defaultTargetPlatform == TargetPlatform.macOS;

  static bool get isLinux => defaultTargetPlatform == TargetPlatform.linux;

  static bool get isWeb => kIsWeb;

  static bool get isMobile => isAndroid || isIOS;

  static bool get isDesktop => isWindows || isMacOS || isLinux;
}
