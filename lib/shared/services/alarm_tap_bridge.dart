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
// Consumed at startup, on AppLifecycleState.resumed AND when the native
// side reports a tap on a running app (onAlarmReceived /
// onReminderReceived). The same payload seen again within [dedupeWindow]
// is ignored (a resume right after a routed tap); a later tap of the same
// reminder (snoozed, fired again) opens it again.
// Same MethodChannel name the debt service uses today.
// ─────────────────────────────────────────────────────────────
class AlarmTapBridge {
  AlarmTapBridge._();

  static const MethodChannel _native =
      MethodChannel('com.fyona.erp/alarm_native');

  static String? _lastHandledSig;
  static DateTime? _lastHandledAt;

  static const Duration dedupeWindow = Duration(seconds: 90);

  /// Called with every routed tap (kind, refId) — the debt service marks
  /// that reminder as seen so its in-app alarm does not pop over the
  /// screen the tap just opened.
  static void Function(String kind, String refId)? onTap;

  /// Test seam: the native pending payload.
  @visibleForTesting
  static Future<Object?> Function()? debugReadPayload;

  @visibleForTesting
  static void resetDedupeForTests() {
    _lastHandledSig = null;
    _lastHandledAt = null;
  }

  /// The exact screen a reminder tap opens: the route stored with the
  /// alarm; for older alarms (no route) the one its kind and id give.
  static String routeFor(String kind, String refId, String route) {
    if (route.trim().isNotEmpty) return route.trim();
    if (refId.isEmpty) return '';
    return switch (kind) {
      'recurring' => ReminderCodec.recurringRouteFor(refId),
      // Sara digests always carry their route; an empty one opens the
      // Personal home rather than a wrong record.
      'sara' => RouteNames.personalDashboard,
      _ => ReminderCodec.debtRouteFor(refId),
    };
  }

  /// Consumes one pending native alarm tap (if any) and routes it.
  /// Returns true when a tap was consumed + routed/queued.
  static Future<bool> consumeAndRoute({
    String homeRoute = RouteNames.personalDashboard,
  }) async {
    Map<dynamic, dynamic> payload;
    try {
      final read = debugReadPayload;
      final raw = read != null
          ? await read()
          : await _native.invokeMethod<dynamic>('getInitialAlarmPayload');
      if (raw is! Map) return false;
      payload = raw;
    } catch (_) {
      // Native side not present (or no pending tap) — safe no-op.
      return false;
    }
    try {
      final kind = payload['kind']?.toString() ?? '';
      final refId = payload['refId']?.toString() ?? '';
      final route = routeFor(kind, refId, payload['route']?.toString() ?? '');
      if (route.isEmpty) return false;
      final sig = '$kind|$refId|$route';
      final now = DateTime.now();
      final last = _lastHandledAt;
      if (sig == _lastHandledSig &&
          last != null &&
          now.difference(last) < dedupeWindow) {
        return true; // this very tap was already routed
      }
      _lastHandledSig = sig;
      _lastHandledAt = now;
      try {
        onTap?.call(kind, refId);
      } catch (_) {}
      NotificationRouter.navigateOrQueue(route, homeRoute: homeRoute);
      return true;
    } catch (_) {
      return false;
    }
  }
}
