import 'package:flutter/foundation.dart';

class StartupLogger {
  static bool get enabled => kDebugMode;
  static void log(String event, [String? detail]) {
    if (!enabled) return;
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    if (detail != null) {
      debugPrint('[$ts][STARTUP] $event — $detail');
    } else {
      debugPrint('[$ts][STARTUP] $event');
    }
  }

  static void error(String event, Object e, [StackTrace? st]) {
    if (!enabled) return;
    debugPrint('[STARTUP][ERROR] $event: $e');
    if (st != null) debugPrint('$st');
  }
}
