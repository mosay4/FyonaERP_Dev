import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/di/providers.dart';
import 'package:fyona_flutter/core/network/api_endpoints.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/core/router/shell_keys.dart';
import 'package:fyona_flutter/shared/services/notification_channels.dart';
import 'package:fyona_flutter/shared/services/notification_router.dart';
import 'package:fyona_flutter/features/auth/di/auth_providers.dart';
import 'package:fyona_flutter/features/subscription/presentation/providers/subscription_providers.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/utils/bilingual_text.dart';

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService(ref);
});

final saraBadgeCountProvider = StateProvider<int>((ref) => 0);

final notificationsBadgeProvider = StateProvider<int>((ref) => 0);

class NotificationService {
  final Ref _ref;
  late final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;
  int _nextId = 1000;
  Timer? _pollTimer;
  int _lastUnread = 0;
  int _tickCount = 0;

  /// The SINGLE shared local-notifications plugin for the whole app.
  /// RecurringReminderService and every other surface use this instance —
  /// never create another one.
  static FlutterLocalNotificationsPlugin? sharedPlugin;

  /// Last server notification id buzzed from the 60s poll (persisted, so a
  /// restart / reconnect never re-buzzes the same row).
  static const String lastSeenPrefsKey = 'notif_last_seen_id';

  /// Payloads recently shown via the FCM foreground bridge (action_payload
  /// → time). The 60s poll must not buzz a SECOND device notification for
  /// the same event the bridge already displayed while foregrounded.
  static final Map<String, DateTime> _recentBridged = {};

  /// Records a tray notification painted by the FCM foreground bridge.
  static void noteBridged(String actionPayload) {
    try {
      final key = actionPayload.trim();
      if (key.isEmpty) return;
      _recentBridged[key] = DateTime.now();
      if (_recentBridged.length > 30) {
        final cutoff = DateTime.now().subtract(const Duration(minutes: 5));
        _recentBridged.removeWhere((_, ts) => ts.isBefore(cutoff));
      }
    } catch (_) {}
  }

  /// True when the same event was bridged to the tray moments ago.
  static bool wasRecentlyBridged(String actionPayload,
      {Duration window = const Duration(seconds: 120)}) {
    try {
      final ts = _recentBridged[actionPayload.trim()];
      if (ts == null) return false;
      return DateTime.now().difference(ts) <= window;
    } catch (_) {
      return false;
    }
  }

  /// Persisted tray-event identity (survives restarts — NOT time-only).
  ///
  /// The same logical event reaches the device through different paths
  /// (FCM foreground bridge vs 60s server poll) carrying identical
  /// (action_payload, title, body) triples — the backend builds both from
  /// the same strings. The key normalizes the body head (some paths
  /// truncate long bodies) so both sides compute the SAME key for the same
  /// event and DIFFERENT keys for different events.
  static const String _seenEventsPrefsKey = 'fcm_seen_tray_events_v1';
  static const int _seenEventsMax = 300;

  /// Canonical event key shared by the bridge and the poll. Pure.
  static String trayEventKey({
    required String actionPayload,
    required String title,
    required String body,
  }) {
    final b = body.trim();
    final head = b.length <= 120 ? b : b.substring(0, 120);
    return '${actionPayload.trim()}\n${title.trim()}\n$head';
  }

  /// Atomically claims a tray slot for [key]: true = newly claimed (caller
  /// MUST show), false = already shown (caller MUST skip). Fail-open on
  /// storage errors (better a rare duplicate than a lost notification).
  static Future<bool> tryClaimTrayKey(String key) async {
    try {
      if (key.trim().isEmpty) return true;
      final prefs = await SharedPreferences.getInstance();
      final seen = prefs.getStringList(_seenEventsPrefsKey) ?? <String>[];
      if (seen.contains(key)) return false;
      seen.add(key);
      while (seen.length > _seenEventsMax) {
        seen.removeAt(0);
      }
      await prefs.setStringList(_seenEventsPrefsKey, seen);
      return true;
    } catch (_) {
      return true;
    }
  }

  /// Releases a claim when the show itself failed, so a later path (e.g.
  /// the server poll) can still deliver the event. Never throws.
  static Future<void> releaseTrayKey(String key) async {
    try {
      if (key.trim().isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final seen = prefs.getStringList(_seenEventsPrefsKey) ?? <String>[];
      if (seen.remove(key)) {
        await prefs.setStringList(_seenEventsPrefsKey, seen);
      }
    } catch (_) {}
  }

  NotificationService(this._ref);

  /// Shared plugin accessor for static services (recurring reminders).
  FlutterLocalNotificationsPlugin get plugin => _plugin;

  Future<void> init() async {
    if (_initialized) return;
    // Request notification permission on Android 13+
    if (Platform.isAndroid) {
      final androidPlugin = FlutterLocalNotificationsPlugin();
      final androidPermissions = androidPlugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (androidPermissions != null) {
        await androidPermissions.requestNotificationsPermission();
      }
    }
    _plugin = FlutterLocalNotificationsPlugin();
    const androidSettings = AndroidInitializationSettings('@drawable/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    await _plugin.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: _onNotificationTap,
    );
    // Pre-create ALL FIVE channels from the central spec (delete + recreate
    // so already-installed devices pick up sound changes — channel sound
    // is immutable on Android). Suggestions/Sara/server/subscription use
    // sound_1, recurring uses sound_2.
    if (Platform.isAndroid) {
      final androidImpl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (androidImpl != null) {
        for (final spec in NotificationChannels.all) {
          final ch = spec.channel(
            name: AppLocalizations.t(spec.nameKey),
            description: AppLocalizations.t(spec.descKey),
          );
          try {
            await androidImpl.deleteNotificationChannel(channelId: ch.id);
          } catch (_) {}
          try {
            await androidImpl.createNotificationChannel(ch);
          } catch (_) {}
        }
      }
    }
    sharedPlugin = _plugin;
    _initialized = true;
  }

  // ── Permission UX (central) ──

  /// Returns true when OS notifications may be posted. Requests once when
  /// merely denied; never claims device delivery when denied.
  Future<bool> ensureNotificationsEnabled() async {
    try {
      var status = await Permission.notification.status;
      if (status.isGranted) return true;
      if (status.isPermanentlyDenied || status.isRestricted) return false;
      status = await Permission.notification.request();
      return status.isGranted;
    } catch (_) {
      return true; // best effort (fail-open, matches legacy behavior)
    }
  }

  static String _fb(String key, String fallback) {
    try {
      final v = AppLocalizations.t(key);
      if (v.isEmpty || v == key) return fallback;
      return v;
    } catch (_) {
      return fallback;
    }
  }

  /// Guidance dialog shown when the OS denied notifications: explains that
  /// device delivery is unavailable and deep-links to app settings.
  static Future<void> showNotificationsDeniedDialog(
      BuildContext context) async {
    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(_fb('notifPermissionDeniedTitle',
              'Notifications are off')),
          content: Text(_fb(
              'notifPermissionDeniedBody',
              'FYONA cannot deliver reminders on this device while '
              'notifications are disabled. Open app settings to turn them on.')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(AppLocalizations.t('cancel')),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  Navigator.of(ctx).pop();
                } catch (_) {}
                try {
                  await openAppSettings();
                } catch (_) {}
              },
              child: Text(
                  _fb('notifOpenSettings', 'Open settings')),
            ),
          ],
        ),
      );
    } catch (_) {}
  }

  /// Cold-start tap on a LOCAL notification: routes it now when the
  /// navigator exists, otherwise queues it for the app shell flush.
  Future<void> handleColdStartTap() async {
    try {
      if (!_initialized) await init();
      final details = await _plugin.getNotificationAppLaunchDetails();
      final payload = details?.notificationResponse?.payload;
      if (details?.didNotificationLaunchApp == true &&
          payload != null &&
          payload.isNotEmpty) {
        final ctx = _getContext();
        if (ctx == null) {
          if (!_pendingTapPayloads.contains(payload)) {
            _pendingTapPayloads.add(payload);
          }
        } else {
          // ctx is the live root-navigator context (no widget mounted
          // state exists to check here).
          // ignore: use_build_context_synchronously
          _goPayload(ctx, payload);
        }
      }
    } catch (_) {}
  }

  /// Shows a notification delivered by FCM while the app is in the foreground.
  /// Reliability: one bounded recovery (re-init + single retry). If the
  /// retry also fails the exception propagates so the caller can release
  /// its tray claim and let the server poll deliver the same row instead —
  /// the event is never silently lost AND never double-shown.
  Future<void> showFcmNotification({
    required String title,
    required String body,
    required String payload,
  }) async {
    if (!_initialized) await init();
    try {
      await _showFcmOnce(title: title, body: body, payload: payload);
    } catch (_) {
      try {
        _initialized = false;
        await init();
      } catch (_) {}
      await _showFcmOnce(title: title, body: body, payload: payload);
    }
  }

  Future<void> _showFcmOnce({
    required String title,
    required String body,
    required String payload,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      'suggestions_channel',
      AppLocalizations.t('notifChannelSuggestName'),
      channelDescription: AppLocalizations.t('notifChannelSuggestDesc'),
      importance: Importance.high,
      priority: Priority.high,
      autoCancel: true,
      icon: 'ic_launcher',
      color: const Color(0xFF000000),
      sound: const RawResourceAndroidNotificationSound('sound_1'),
      // Heads-up eligibility on OEM skins (Samsung et al.): explicit
      // public visibility + message category so the high-importance
      // channel is allowed to banner while the screen is on.
      visibility: NotificationVisibility.public,
      category: AndroidNotificationCategory.message,
      playSound: true,
      enableVibration: true,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: 'sound_1.mp3',
    );
    await _plugin.show(
      id: _nextId++,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      ),
      payload: payload,
    );
  }

  /// Taps that arrive before the navigator exists (cold start) are queued
  /// and flushed once the app is ready — tapping never silently dies.
  final List<String> _pendingTapPayloads = [];

  void flushPendingTaps() {
    if (_pendingTapPayloads.isEmpty) return;
    final ctx = _getContext();
    if (ctx == null) return;
    final queued = List<String>.from(_pendingTapPayloads);
    _pendingTapPayloads.clear();
    for (final payload in queued) {
      _goPayload(ctx, payload);
    }
  }

  void _goPayload(BuildContext ctx, String payload) {
    // Every tap delegates to the central NotificationRouter (query params
    // preserved — 'notifications?id=X' keeps its id). The sara badge reset
    // stays here via callback; home resolves per usage mode as before.
    var home = RouteNames.dashboard;
    try {
      final mode = _ref.read(authProvider).user?.preferredUsageMode;
      if (mode == 'personal') home = RouteNames.personalDashboard;
    } catch (_) {}
    NotificationRouter.navigate(
      ctx,
      payload,
      homeRoute: home,
      onSaraTap: () {
        try {
          _ref.read(saraBadgeCountProvider.notifier).state = 0;
        } catch (_) {}
      },
    );
  }

  void _onNotificationTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    final ctx = _getContext();
    if (ctx == null) {
      if (!_pendingTapPayloads.contains(payload)) _pendingTapPayloads.add(payload);
      return;
    }
    _goPayload(ctx, payload);
  }

  BuildContext? _getContext() {
    return rootNavigatorKey.currentContext;
  }

  Future<void> showSaraWelcome({String mode = 'personal'}) async {
    if (!_initialized) await init();
    final id = _nextId++;
    final saraTitle = AppLocalizations.t('notifSaraTeamTitle');
    final String saraBody;
    final String saraBodyLong;
    if (mode == 'business') {
      saraBody = AppLocalizations.t('notifSaraBusinessBody');
      saraBodyLong = AppLocalizations.t('notifSaraBusinessLong');
    } else {
      saraBody = AppLocalizations.t('notifSaraPersonalBody');
      saraBodyLong = AppLocalizations.t('notifSaraPersonalBody');
    }
    // Show heads-up notification (auto-cancels after 3 sec)
    final androidHeadsUp = AndroidNotificationDetails(
      'sara_channel',
      AppLocalizations.t('notifChannelSaraName'),
      channelDescription: AppLocalizations.t('notifChannelSaraDesc'),
      importance: Importance.high,
      priority: Priority.high,
      timeoutAfter: 3000,
      autoCancel: true,
      icon: 'ic_launcher',
      color: const Color(0xFF000000),
      sound: const RawResourceAndroidNotificationSound('sound_1'),
    );
    const iosHeadsUp = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: 'sound_1.mp3',
    );
    await _plugin.show(
      id: id,
      title: saraTitle,
      body: saraBody,
      notificationDetails: NotificationDetails(
        android: androidHeadsUp,
        iOS: iosHeadsUp,
      ),
      payload: 'home',
    );
    _ref.read(saraBadgeCountProvider.notifier).state++;
    // After heads-up disappears, show persistent notification
    await Future.delayed(const Duration(seconds: 4));
    final androidPersist = AndroidNotificationDetails(
      'sara_channel',
      AppLocalizations.t('notifChannelSaraName'),
      channelDescription: AppLocalizations.t('notifChannelSaraDesc'),
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      autoCancel: true,
      icon: 'ic_launcher',
      color: const Color(0xFF000000),
      sound: const RawResourceAndroidNotificationSound('sound_1'),
    );
    await _plugin.show(
      id: id,
      title: saraTitle,
      body: saraBodyLong,
      notificationDetails: NotificationDetails(
        android: androidPersist,
        iOS: iosHeadsUp,
      ),
      payload: 'home',
    );
  }

  Future<void> showSaraNotification(String title, String body) async {
    if (!_initialized) await init();
    final id = _nextId++;
    final androidDetails = AndroidNotificationDetails(
      'sara_channel',
      AppLocalizations.t('notifChannelSaraName'),
      channelDescription: AppLocalizations.t('notifChannelSaraDesc'),
      importance: Importance.high,
      priority: Priority.high,
      autoCancel: true,
      icon: 'ic_launcher',
      color: const Color(0xFF000000),
      sound: const RawResourceAndroidNotificationSound('sound_1'),
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: 'sound_1.mp3',
    );
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      ),
      payload: 'sara',
    );
    _ref.read(saraBadgeCountProvider.notifier).state++;
  }

  /// Inventory expiry alert (Business). Dedup is enforced by the caller via
  /// [tryClaimTrayKey], so the same product never alerts twice the same day.
  Future<void> showInventoryExpiry(String title, String body) async {
    if (!_initialized) await init();
    final id = _nextId++;
    final androidDetails = AndroidNotificationDetails(
      'inventory_channel',
      AppLocalizations.t('notifChannelInventoryName'),
      channelDescription: AppLocalizations.t('notifChannelInventoryDesc'),
      importance: Importance.high,
      priority: Priority.high,
      autoCancel: true,
      icon: 'ic_launcher',
      color: const Color(0xFF000000),
      sound: const RawResourceAndroidNotificationSound('sound_1'),
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: 'sound_1.mp3',
    );
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      ),
      payload: 'inventory',
    );
  }

  // ── Subscription welcome (plan activation) ──
  /// Stable once-scope for the activation welcome: free plans key by user,
  /// paid plans key by user + invoice (falling back to plan + start date).
  /// Guarantees the greeting shows exactly once per activation, no matter
  /// how many times the invoice screen is reopened.
  static String welcomeScopeKey({
    required String userId,
    required bool isFree,
    String? invoiceNo,
    String? plan,
    String? start,
  }) {
    if (isFree) return 'trial:$userId';
    final detail = (invoiceNo ?? '').isNotEmpty
        ? invoiceNo!
        : '${plan ?? ''}|${start ?? ''}';
    return 'paid:$userId:$detail';
  }

  /// Shows the activation welcome on the device exactly once per scope.
  /// Pass [scopeKey] directly (trial path), or let it be derived from
  /// ([userId], [isFree], [invoiceNo]/[plan]+[start]) for the paid invoice
  /// path: `showSubscriptionWelcomeOnce(isFree: false, invoiceNo: no,
  /// userId: uid)`. An empty uid derives no scope and returns false.
  /// Never throws — callers must not break.
  Future<bool> showSubscriptionWelcomeOnce({
    String? scopeKey,
    bool isFree = false,
    String? invoiceNo,
    String? plan,
    String? start,
    String? userId,
    String? deepLink,
  }) async {
    try {
      var scope = (scopeKey ?? '').trim();
      if (scope.isEmpty) {
        final uid = (userId ?? '').trim();
        if (uid.isEmpty) return false;
        scope = welcomeScopeKey(
          userId: uid,
          isFree: isFree,
          invoiceNo: invoiceNo,
          plan: plan,
          start: start,
        );
      }
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('sub_welcome_$scope') == true) return false;
      await showSubscriptionWelcome(deepLink: deepLink);
      try {
        await prefs.setBool('sub_welcome_$scope', true);
      } catch (_) {}
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Professional activation greeting on the device notification tray.
  /// Tapping it opens [deepLink] (the paid invoice when provided), falling
  /// back to the app home (dashboard per usage mode) for free activations.
  Future<void> showSubscriptionWelcome({String? deepLink}) async {
    try {
      if (!_initialized) await init();
      final tapRoute =
          (deepLink ?? '').trim().isNotEmpty ? deepLink!.trim() : 'home';
      final androidDetails = AndroidNotificationDetails(
        'subscription_channel',
        AppLocalizations.t('notifChannelSubName'),
        channelDescription: AppLocalizations.t('notifChannelSubDesc'),
        importance: Importance.high,
        priority: Priority.high,
        autoCancel: true,
        icon: 'ic_launcher',
        color: const Color(0xFF000000),
        sound: const RawResourceAndroidNotificationSound('sound_1'),
        visibility: NotificationVisibility.public,
        category: AndroidNotificationCategory.message,
        playSound: true,
        enableVibration: true,
      );
      // subscription_channel is created centrally at startup (init) —
      // no lazy recreate here.
      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'sound_1.mp3',
      );
      await _plugin.show(
        id: _nextId++,
        title: AppLocalizations.t('subWelcomeTitle'),
        body: AppLocalizations.t('subWelcomeBody'),
        notificationDetails: NotificationDetails(
          android: androidDetails,
          iOS: iosDetails,
        ),
        payload: tapRoute,
      );
    } catch (_) {}
  }

  // ── Server polling (in-app notifications) ──

  void startPolling({Duration interval = const Duration(seconds: 60)}) {
    stopPolling();
    _pollTimer = Timer.periodic(interval, (_) {
      _pollUnread();
      _refreshSubscriptionSnapshot();
    });
    _pollUnread();
    _refreshSubscriptionSnapshot();
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Keeps the subscription status, profile and plans page fresh so that an
  /// admin-approved plan shows up without the user having to log out/in.
  Future<void> _refreshSubscriptionSnapshot() async {
    _tickCount++;
    try {
      _ref.invalidate(subscriptionStatusProvider);
      if (_tickCount % 2 == 0) {
        await _ref.read(authStateProvider.notifier).refreshProfile();
      }
    } catch (_) {}
  }

  Future<void> _pollUnread() async {
    try {
      final api = _ref.read(apiClientProvider);
      final response = await api.get(ApiEndpoints.notificationsUnreadCount);
      final data = response.data;
      int count = 0;
      if (data is int) {
        count = data;
      } else if (data is Map) {
        if (data['count'] != null) {
          count = data['count'] as int;
        } else {
          final inner = data['data'];
          if (inner is Map && inner['count'] != null) count = inner['count'] as int;
        }
      }
      if (count > _lastUnread && _lastUnread > 0) {
        _notifyLatest();
      }
      _lastUnread = count;
      _ref.read(notificationsBadgeProvider.notifier).state = count;
    } catch (_) {}
  }

  /// Records a buzzed server row id (permanent backstop). Never throws.
  static Future<void> _recordLastSeenId(String? notifId) async {
    if (notifId == null || notifId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(lastSeenPrefsKey, notifId);
    } catch (_) {}
  }

  Future<void> _notifyLatest() async {
    try {
      final api = _ref.read(apiClientProvider);
      final response = await api.get(ApiEndpoints.notifications, queryParameters: {'limit': 1});
      final data = response.data;
      final raw = data is List
          ? data
          : (data is Map
              ? (data['data'] is Map ? data['data']['items'] : data['data'])
              : <dynamic>[]);
      if (raw is List && raw.isNotEmpty && _initialized) {
        final item = raw.first as Map;
        final actionPayload = item['action_payload']?.toString() ?? '';
        // Single-FEATURE maintenance rows are IN-APP only: they must never
        // buzz the device (only section/application rows surface there).
        if (actionPayload.startsWith('maintenance-feature')) {
          return;
        }
        // Subscription rows are NOT skipped: if FCM already painted the
        // tray (foreground bridge / background handler / OS notification{}),
        // the bridged + tray-key guards below suppress the duplicate. When
        // FCM never arrived (force-stop, token gap), THIS poll is the only
        // device-side backstop — skipping it dropped the notification.
        final defaultTitle = AppLocalizations.t('fcmDefaultTitle');
        final defaultBody = AppLocalizations.t('notifDefaultBody');
        final notifId = item['id']?.toString();
        if (wasRecentlyBridged(actionPayload)) {
          await _recordLastSeenId(notifId);
          return;
        }
        // Persisted last-seen guard: never re-buzz the same server row on
        // a 60s re-poll / reconnect, even across restarts.
        if (notifId != null && notifId.isNotEmpty) {
          try {
            final prefs = await SharedPreferences.getInstance();
            if (prefs.getString(lastSeenPrefsKey) == notifId) return;
          } catch (_) {}
        }
        // Event-identity claim: the same event via bridge + poll paints
        // exactly once (persisted — restarts included). Distinct events
        // always have distinct (payload, title, body-head) triples.
        final rowTitle = item['title']?.toString() ?? defaultTitle;
        final rowBody =
            localizedText(item['message']?.toString() ?? defaultBody);
        final trayKey = trayEventKey(
          actionPayload: actionPayload,
          title: rowTitle,
          body: rowBody,
        );
        try {
          if (!await tryClaimTrayKey(trayKey)) {
            await _recordLastSeenId(notifId);
            return;
          }
        } catch (_) {}
        // Subscription deep-links keep their original action_payload
        // (e.g. /subscription/invoice?invoice_no=…); everything else opens
        // the notifications list at that row.
        final String deepLink;
        if (actionPayload.startsWith('/')) {
          deepLink = actionPayload;
        } else if (notifId != null && notifId.isNotEmpty) {
          deepLink = 'notifications?id=$notifId';
        } else {
          deepLink = 'notifications';
        }
        final isSubscription = actionPayload.startsWith('/subscription');
        final channelId =
            isSubscription ? 'subscription_channel' : 'server_channel';
        final channelName = isSubscription
            ? AppLocalizations.t('notifChannelSubName')
            : AppLocalizations.t('notifChannelAppName');
        final channelDesc = isSubscription
            ? AppLocalizations.t('notifChannelSubDesc')
            : AppLocalizations.t('notifChannelAppDesc');
        try {
          await _plugin.show(
            id: _nextId++,
            title: rowTitle,
            body: rowBody,
            notificationDetails: NotificationDetails(
              android: AndroidNotificationDetails(
                channelId,
                channelName,
                channelDescription: channelDesc,
                importance: Importance.high,
                priority: Priority.high,
                autoCancel: true,
                icon: 'ic_launcher',
                color: const Color(0xFF000000),
                sound: const RawResourceAndroidNotificationSound('sound_1'),
                visibility: NotificationVisibility.public,
                category: AndroidNotificationCategory.message,
                playSound: true,
                enableVibration: true,
              ),
              iOS: DarwinNotificationDetails(
                presentAlert: true,
                presentBadge: true,
                presentSound: true,
                sound: 'sound_1.mp3',
              ),
            ),
            payload: deepLink,
          );
        } catch (_) {
          // Show failed: release the claim so the next tick retries instead
          // of losing the event, and do NOT advance last-seen.
          try {
            await releaseTrayKey(trayKey);
          } catch (_) {}
          return;
        }
        await _recordLastSeenId(notifId);
      }
    } catch (_) {}
  }
}
