import 'package:flutter/foundation.dart';

/// Structured, controllable logging for the offline-first sync pipeline.
///
/// Disabled by default in release builds; can be forced at runtime through
/// [SyncLogger.enabled] (e.g. a debug toggle). Log lines are intentionally
/// compact (`[SYNC] phase k=v k=v`) so they can be grepped from device logs
/// without drowning useful output.
class SyncLogger {
  static bool enabled = false;

  @visibleForTesting
  static List<String> captured = [];

  static void _log(String phase, Map<String, Object?> fields) {
    if (!enabled && !kDebugMode) return;
    final buf = StringBuffer('[SYNC] $phase');
    fields.forEach((k, v) {
      if (v == null) return;
      buf.write(' $k=$v');
    });
    final line = buf.toString();
    if (captured.length > 2000) {
      captured.removeRange(0, 1000);
    }
    captured.add(line);
    debugPrint(line);
  }

  static void info(String phase, [Map<String, Object?> fields = const {}]) =>
      _log(phase, fields);

  static void error(String phase, Object error, [Map<String, Object?> fields = const {}]) =>
      _log('$phase:ERROR', {...fields, 'error': error.toString()});

  static void clear() => captured.clear();
}
