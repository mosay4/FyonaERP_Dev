import 'dart:async';
import 'dart:io';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fyona_flutter/core/di/providers.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_endpoints.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/core/router/shell_keys.dart';
import 'package:fyona_flutter/shared/services/notification_router.dart';
import 'package:fyona_flutter/core/config/app_config.dart';
import 'package:fyona_flutter/features/auth/di/auth_providers.dart';
import 'package:fyona_flutter/features/notifications/presentation/providers/notifications_providers.dart';
import 'package:fyona_flutter/features/profile/presentation/providers/avatar_provider.dart';
import 'package:fyona_flutter/features/subscription/presentation/providers/subscription_providers.dart';
import 'package:fyona_flutter/shared/services/notification_service.dart';
import '../../features/personal/data/active_chat.dart';

final fcmServiceProvider = Provider<FcmService>((ref) => FcmService(ref));

/// Bridges Firebase Cloud Messaging into the app:
/// - requests notification permission
/// - registers the device token with the backend (`/push/devices`)
/// - displays foreground pushes via the local notification plugin
/// - opens the right screen when a push is tapped
class FcmService {
  final Ref _ref;
  bool _initialized = false;

  FcmService(this._ref);

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final fcm = FirebaseMessaging.instance;

      try {
        await fcm.requestPermission(alert: true, badge: true, sound: true);
      } catch (_) {}
      // Android: ask once to be exempt from battery optimisation so Doze /
      // OEM killers cannot delay or drop chat pushes while the app is swiped.
      if (Platform.isAndroid) {
        try {
          await Permission.ignoreBatteryOptimizations.request();
        } catch (_) {}
      }

      // Register the current token (a valid session may or may not exist yet;
      // the API call simply fails silently when there is no access token or
      // when the network is down).
      try {
        final token = await fcm.getToken();
        if (token != null) await _registerToken(token);
        fcm.onTokenRefresh.listen((t) => _registerToken(t));
      } catch (_) {
        /* offline-safe */
      }

      // Foreground: render the push through the local notification plugin so
      // the user sees it while the app is open.
      _attachMessageListeners();

      // Tapped from a terminated state.
      try {
        final initial = await fcm.getInitialMessage();
        if (initial != null) _navigate(initial.data);
      } catch (_) {
        /* offline-safe */
      }
      // The navigator may not exist yet — flush any queued tap once the
      // first frame is ready.
      try {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => flushPendingNavigation(),
        );
      } catch (_) {}
    } catch (_) {
      // Firebase not initialized (offline or not configured) - skip FCM entirely.
      // The app works fully offline without push notifications.
    }
  }

  /// Foreground + background-tap listeners with a bounded re-attach.
  ///
  /// Root cause previously fixed here: if Firebase wasn't ready when
  /// [init] ran, `FirebaseMessaging.instance` threw and the listeners were
  /// NEVER attached for the whole session — foreground pushes died
  /// silently ("sometimes arrives, sometimes not"). The guard flag prevents
  /// double subscription; one delayed retry covers late Firebase readiness.
  bool _listenersAttached = false;

  void _attachMessageListeners() {
    if (_listenersAttached) return;
    try {
      // Foreground: render the push through the local notification plugin.
      FirebaseMessaging.onMessage.listen((message) => _showForeground(message));
      // Tapped while app was in background.
      FirebaseMessaging.onMessageOpenedApp.listen(
        (message) => _navigate(message.data),
      );
      _listenersAttached = true;
    } catch (_) {
      try {
        Future.delayed(const Duration(seconds: 10), () {
          try {
            _attachMessageListeners();
          } catch (_) {}
        });
      } catch (_) {}
    }
  }

  /// Re-syncs the FCM token with the backend (e.g. right after login, when a
  /// token may not have been registered yet). Retries once after a short
  /// delay because the API client / session may still be settling.
  Future<void> syncToken() async {
    // Late-Firebase safety: a session that started before Firebase was
    // ready gets its message listeners here for sure.
    try {
      _attachMessageListeners();
    } catch (_) {}
    var ok = false;
    try {
      final fcm = FirebaseMessaging.instance;
      final token = await fcm.getToken();
      if (token != null) {
        await _registerToken(token);
        ok = true;
      }
    } catch (_) {}
    if (ok) return;
    try {
      await Future.delayed(const Duration(seconds: 2));
    } catch (_) {}
    try {
      final fcm = FirebaseMessaging.instance;
      final token = await fcm.getToken();
      if (token != null) await _registerToken(token);
    } catch (_) {}
  }

  /// Drop every cached subscription snapshot so the invoice/plans screens
  /// re-fetch fresh server data (approve / cancel / reject / extend drives).
  void invalidateSubscriptionProviders() {
    try {
      _ref.invalidate(subscriptionStatusProvider);
    } catch (_) {}
    try {
      _ref.invalidate(subscriptionPlansProvider);
    } catch (_) {}
    try {
      _ref.invalidate(subscriptionInvoicesProvider);
    } catch (_) {}
  }

  /// Silent data event sent by the backend after an admin plan change.
  static const String subscriptionChangedEvent = 'subscription_changed';

  /// Pulls the fresh plan everywhere it is shown: status snapshot (profile
  /// card + badges read `plan_name`), plans/invoices, and the cached profile
  /// (`subscriptionPlan` → drawer badge offline fallback). Never throws.
  Future<void> refreshSubscriptionState() async {
    invalidateSubscriptionProviders();
    try {
      await _ref.read(authStateProvider.notifier).refreshProfile();
    } catch (_) {}
  }

  Future<void> _registerToken(String token) async {
    try {
      final api = _ref.read(apiClientProvider);
      // Truthful platform: the backend splits transport on it (Android
      // data-only rich render vs legacy notification{} elsewhere). Never
      // hardcode one platform for all builds.
      String platform;
      try {
        platform = Platform.isAndroid
            ? 'android'
            : (Platform.isIOS ? 'ios' : 'other');
      } catch (_) {
        platform = 'android';
      }
      await api.post(
        ApiEndpoints.pushDevices,
        data: {'token': token, 'platform': platform},
      );
    } catch (_) {}
  }

  /// Applies a silent `avatar_updated` data event for the signed-in
  /// account: downloads the new picture when newer than the held one and
  /// publishes it (watchers rebuild automatically). Never uploads, never
  /// deletes, never throws; events for other accounts are ignored.
  Future<void> _applyAvatarEvent(Map<String, dynamic> data) async {
    try {
      final avatar = data['avatar']?.toString() ?? '';
      final eventUserId = data['user_id']?.toString() ?? '';
      if (avatar.isEmpty || eventUserId.isEmpty) return;
      String? currentUserId;
      try {
        currentUserId = _ref.read(authStateProvider).user?.id;
      } catch (_) {}
      if (currentUserId == null || currentUserId != eventUserId) return;
      final absoluteUrl = avatar.startsWith('http')
          ? avatar
          : '${AppConfig.apiHostUrl}/'
                '${avatar.startsWith('/') ? avatar.substring(1) : avatar}';
      await syncAvatarFromUrl(
        _ref,
        userId: currentUserId,
        serverRel: avatar,
        absoluteUrl: absoluteUrl,
      );
    } catch (_) {}
  }

  /// In-memory foreground dedup (§11): the same subscription event must
  /// never paint two tray notifications when confirm+webhook race delivers
  /// the same payload twice within seconds.
  final Map<String, DateTime> _recentForegroundPayloads = {};

  Future<void> _showForeground(RemoteMessage message) async {
    if (suppressChatTray(
      message.data['action_payload']?.toString(),
      _ref.read(activeChatViewProvider),
    ))
      return;
    // Silent cross-device avatar events (data-only, no notification):
    // fetch the new picture immediately so it updates without opening
    // the profile page. Version comparison inside prevents stale applies.
    try {
      final data = message.data;
      if ((data['type']?.toString() ?? '') == 'avatar_updated') {
        await _applyAvatarEvent(data);
        return;
      }
      // Admin changed the plan: recolour badge / plan card now (silent).
      if ((data['type']?.toString() ?? '') == subscriptionChangedEvent) {
        await refreshSubscriptionState();
        return;
      }
    } catch (_) {}
    final notification = message.notification;
    final data = message.data;
    // Transport may be notification{} (OS paints background/terminated) or
    // data-only (local paint). Foreground ALWAYS paints here — the system
    // does not auto-show notification messages while the app is open.
    // A message with neither notification{} nor title/body is silent by
    // design (avatar path above).
    final dataTitle = (data['title']?.toString() ?? '').trim();
    var dataBody = (data['body']?.toString() ?? '').trim();
    final dataBodyEn = (data['body_en']?.toString() ?? '').trim();
    if (dataBody.isEmpty) dataBody = dataBodyEn;
    if (notification == null && dataTitle.isEmpty && dataBody.isEmpty) {
      return;
    }
    try {
      // Section/application maintenance pushes carry a body_en variant when
      // the platform is configured bilingual — pick per app language.
      final actionPayload = (data['action_payload'] ?? 'suggestions')
          .toString();
      // §11: skip a repeat of the same subscription payload shown moments
      // ago (confirm+webhook race). The backend AppNotification row remains
      // the single source of truth; this only guards the tray copy.
      if (actionPayload.startsWith('/subscription')) {
        final now = DateTime.now();
        final last = _recentForegroundPayloads[actionPayload];
        if (last != null && now.difference(last).inSeconds < 90) {
          return;
        }
        _recentForegroundPayloads[actionPayload] = now;
        // Bound the map — old entries are useless.
        if (_recentForegroundPayloads.length > 20) {
          final cutoff = now.subtract(const Duration(minutes: 5));
          _recentForegroundPayloads.removeWhere((_, ts) => ts.isBefore(cutoff));
        }
      }
      final body =
          (AppLocalizations.currentLanguage == 'en' &&
              (data['body_en']?.toString() ?? '').isNotEmpty)
          ? data['body_en'].toString()
          : (notification?.body?.isNotEmpty == true
                ? notification!.body!
                : dataBody);
      final title =
          notification?.title ??
          (dataTitle.isNotEmpty
              ? dataTitle
              : AppLocalizations.t('fcmDefaultTitle'));
      // Event-identity claim FIRST: an exact duplicate (FCM redelivery)
      // must never paint twice. On show failure the claim is released so
      // the server poll still delivers the same row — never lost either.
      final trayKey = NotificationService.trayEventKey(
        actionPayload: actionPayload,
        title: title,
        body: body,
      );
      try {
        if (!await NotificationService.tryClaimTrayKey(trayKey)) return;
      } catch (_) {}
      try {
        await _ref
            .read(notificationServiceProvider)
            .showFcmNotification(
              title: title,
              body: body,
              payload: actionPayload,
            );
      } catch (_) {
        try {
          await NotificationService.releaseTrayKey(trayKey);
        } catch (_) {}
        return;
      }
      // Painted on the tray while foregrounded — the 60s poll must not
      // buzz the same event a second time (see noteBridged).
      NotificationService.noteBridged(actionPayload);
      // Plan approved / cancelled / renewed: the badge and the plan card
      // follow immediately instead of on the next poll.
      if (actionPayload.startsWith('/subscription')) {
        unawaited(refreshSubscriptionState());
      }
      // Instant in-app refresh: the center + bell show the event NOW,
      // never waiting for the next 60s poll tick.
      try {
        _ref.invalidate(unreadCountProvider);
      } catch (_) {}
      try {
        _ref.invalidate(notificationListProvider);
      } catch (_) {}
    } catch (_) {}
  }

  /// Push taps that arrive before the navigator exists (cold start) are
  /// queued and flushed once the app is ready.
  final List<String> _pendingPayloads = [];

  void flushPendingNavigation() {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null || _pendingPayloads.isEmpty) return;
    final queued = List<String>.from(_pendingPayloads);
    _pendingPayloads.clear();
    for (final payload in queued) {
      _goPayload(ctx, payload);
    }
  }

  void _navigate(Map<String, dynamic> data) {
    final payload = (data['action_payload'] ?? 'suggestions').toString();
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) {
      if (!_pendingPayloads.contains(payload)) _pendingPayloads.add(payload);
      return;
    }
    _goPayload(ctx, payload);
  }

  void _goPayload(dynamic ctx, String payload) {
    debugPrint('[FCM_GO] payload=$payload');
    // Every tap delegates to the central NotificationRouter (query params
    // preserved — 'notifications?id=X' keeps its id; slash-less payloads
    // repaired). Subscription events still drop cached snapshots so the
    // screen opens with FRESH server data the instant the push is tapped.
    try {
      NotificationRouter.navigate(
        ctx as BuildContext,
        payload,
        homeRoute: RouteNames.personalDashboard,
        onSubscriptionRoute: (_) {
          try {
            invalidateSubscriptionProviders();
          } catch (_) {}
        },
      );
    } catch (_) {}
  }

  /// Best-effort unregistration of this device token on logout
  /// (`DELETE /push/devices/{token}`). Never throws, never blocks logout.
  Future<void> unregisterToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) return;
      final api = _ref.read(apiClientProvider);
      await api.delete(ApiEndpoints.pushDevice(token));
    } catch (_) {}
  }
}
