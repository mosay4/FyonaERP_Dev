import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/shared/services/notification_router.dart';
import 'package:fyona_flutter/shared/services/reminder_codec.dart';

// ─────────────────────────────────────────────────────────────
// AlarmTapBridge — consumes the native pending alarm tap
// (`getInitialAlarmPayload`, implemented by the native side) and
// routes it through the central NotificationRouter.
//
// Consumed at startup AND on AppLifecycleState.resumed; repeats are
// deduped so a resume never re-fires an already-handled tap.
// Same MethodChannel name the debt service uses today.
// ─────────────────────────────────────────────────────────────
class AlarmTapBridge {
  AlarmTapBridge._();

  static const MethodChannel _native =
      MethodChannel('com.fyona.erp/alarm_native');

  static String? _lastHandledSig;

  @visibleForTesting
  static void resetDedupeForTests() => _lastHandledSig = null;

  /// Consumes one pending native alarm tap (if any) and routes it.
  /// Returns true when a tap was consumed + routed/queued.
  static Future<bool> consumeAndRoute({
    String homeRoute = RouteNames.personalDashboard,
  }) async {
    Map<dynamic, dynamic> payload;
    try {
      final raw = await _native.invokeMethod<dynamic>('getInitialAlarmPayload');
      if (raw is! Map) return false;
      payload = raw;
    } catch (_) {
      // Native side not present (or no pending tap) — safe no-op.
      return false;
    }
    try {
      final kind = payload['kind']?.toString() ?? '';
      final refId = payload['refId']?.toString() ?? '';
      var route = payload['route']?.toString() ?? '';
      if (refId.isEmpty && route.isEmpty) return false;
      if (route.isEmpty) {
        route = kind == 'debt'
            ? ReminderCodec.debtRouteFor(refId)
            : ReminderCodec.recurringRouteFor(refId);
      }
      final sig = '$kind|$refId|$route';
      if (sig == _lastHandledSig) return false; // already handled
      _lastHandledSig = sig;
      NotificationRouter.navigateOrQueue(route, homeRoute: homeRoute);
      return true;
    } catch (_) {
      return false;
    }
  }
}
