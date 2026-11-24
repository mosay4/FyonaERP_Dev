import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'app.dart';
import 'core/config/app_config.dart';
import 'core/config/directory_pilot_build.dart';
import 'core/localization/app_localizations.dart';
import 'core/network/api_client.dart';
import 'core/network/api_interceptors.dart';
import 'core/startup/startup_logger.dart';
import 'core/startup/retired_business_storage.dart';
import 'core/services/fcm_service.dart';
import 'core/services/sync_engine.dart';
import 'core/router/shell_keys.dart';
import 'features/personal/services/debt_reminder_service.dart';
import 'features/personal/services/recurring_reminder_service.dart';
import 'shared/services/alarm_tap_bridge.dart';
import 'shared/providers/locale_provider.dart';
import 'shared/providers/platform_controls_provider.dart';
import 'shared/services/notification_service.dart';
import 'features/personal/data/chat_background_upload.dart';
import 'features/subscription/presentation/providers/subscription_providers.dart';
import 'features/branches/data/branch_scope.dart';
import 'features/core_business/data/local_directory/directory_pilot.dart'
    show DeviceLedgerOrganizations;
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Background/killed isolate.
  // - notification{} messages: the OS already (or will) paint the tray;
  //   we only claim the tray key + mark bridged so the 60s poll never
  //   paints a second copy of the same event.
  // - data-only messages: paint locally on suggestions_channel (SOUND 1)
  //   with the same visual as the foreground bridge (ic_launcher only).
  // Silent sync events (avatar_updated / empty title+body) stay silent.
  try {
    await Firebase.initializeApp();
  } catch (_) {}
  try {
    final data = message.data;
    if ((data['type']?.toString() ?? '') == 'avatar_updated') return;
    final notification = message.notification;
    final actionPayload =
        (data['action_payload'] ?? 'suggestions').toString();
    final notifTitle = (notification?.title ?? '').trim();
    final notifBody = (notification?.body ?? '').trim();
    final dataTitle = (data['title']?.toString() ?? '').trim();
    var body = (data['body']?.toString() ?? '').trim();
    final bodyEn = (data['body_en']?.toString() ?? '').trim();
    if (body.isEmpty) body = bodyEn;
    // Prefer OS notification strings when present (notification{} shape);
    // fall back to data[] (data-only shape).
    final title = notifTitle.isNotEmpty ? notifTitle : dataTitle;
    if (notifBody.isNotEmpty) body = notifBody;
    if (title.isEmpty && body.isEmpty) return;
    // Same persisted event-identity as the foreground bridge + poll: an
    // event already on the tray is never painted twice.
    final key = NotificationService.trayEventKey(
      actionPayload: actionPayload,
      title: title,
      body: body,
    );
    try {
      if (!await NotificationService.tryClaimTrayKey(key)) return;
    } catch (_) {}
    // OS-rendered path: system tray already owns this notification —
    // do NOT call plugin.show (that would duplicate it). Bridge marker
    // keeps the poll quiet for the same action_payload.
    if (notification != null) {
      NotificationService.noteBridged(actionPayload);
      return;
    }
    final plugin = FlutterLocalNotificationsPlugin();
    try {
      await plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@drawable/ic_launcher'),
        ),
      );
    } catch (_) {}
    // The channel normally exists (created on every foreground init), but
    // a killed-first-launch must still get the right channel + SOUND 1.
    try {
      final androidImpl = plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await androidImpl?.createNotificationChannel(
        const AndroidNotificationChannel(
          'suggestions_channel',
          'اقتراحات',
          description: 'إشعارات الاقتراحات والردود',
          importance: Importance.high,
          sound: RawResourceAndroidNotificationSound('sound_1'),
        ),
      );
    } catch (_) {}
    try {
      await plugin.show(
        id: key.hashCode & 0x7fffffff,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'suggestions_channel',
            'اقتراحات',
            channelDescription: 'إشعارات الاقتراحات والردود',
            importance: Importance.high,
            priority: Priority.high,
            autoCancel: true,
            icon: 'ic_launcher',
            color: Color(0xFF000000),
            sound: RawResourceAndroidNotificationSound('sound_1'),
            visibility: NotificationVisibility.public,
            category: AndroidNotificationCategory.message,
            playSound: true,
            enableVibration: true,
          ),
        ),
        payload: actionPayload,
      );
      NotificationService.noteBridged(actionPayload);
    } catch (_) {
      try {
        await NotificationService.releaseTrayKey(key);
      } catch (_) {}
    }
  } catch (_) {}
}

String _savedLocale = 'ar';

Future<void> main() async {
  StartupLogger.log('STARTUP_BEGIN');
  WidgetsFlutterBinding.ensureInitialized();
  final imagePickerPlatform = ImagePickerPlatform.instance;
  if (imagePickerPlatform is ImagePickerAndroid) {
    imagePickerPlatform.useAndroidPhotoPicker = true;
  }
  StartupLogger.log('FLUTTER_STARTED');

  FlutterError.onError = (details) {
    final msg = details.exceptionAsString().toLowerCase();
    if (msg.contains('overflow') ||
        msg.contains('socket') || msg.contains('connection') || msg.contains('network') || msg.contains('offline')) {
      StartupLogger.log('FLUTTER_ERROR_SUPPRESSED', details.exception.toString());
      return;
    }
    FlutterError.presentError(details);
  };

  // A build failure must never leave a BLIND black screen. Show a calm, on-brand
  // fallback with a short code so the user can report the exact issue instead of
  // staring at a black page; the full detail is logged for support.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    StartupLogger.error('ERROR_WIDGET', details.exception, details.stack);
    // Guarded to never itself throw (no Directionality/MediaQuery/Theme
    // dependency): a fallback that crashes would just be black again.
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Material(
        color: const Color(0xFFF2F3F6),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline,
                    size: 42, color: Color(0xFFAB0B27)),
                const SizedBox(height: 12),
                const Text('تعذّر عرض هذه الشاشة، حاول مرة أخرى',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF142430))),
                const SizedBox(height: 6),
                Text('الرمز: ${details.exception.runtimeType}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 11,
                        color: Color(0xFF6B7280))),
              ],
            ),
          ),
        ),
      ),
    );
  };

  // Locale: fast, bounded — never block startup.
  StartupLogger.log('APP_INITIALIZATION_STARTED', 'locale');
  try {
    final storage = const FlutterSecureStorage();
    final saved = await storage.read(key: 'locale').timeout(const Duration(milliseconds: 800), onTimeout: () => null);
    if (saved == 'en' || saved == 'ar') _savedLocale = saved!;
    AppLocalizations.setStaticLanguage(_savedLocale);
    await AppLocalizations.preload(_savedLocale).timeout(const Duration(milliseconds: 800), onTimeout: () {});
    setInitialLocale(_savedLocale);
    StartupLogger.log('APP_INITIALIZATION_COMPLETED', 'locale=$_savedLocale');
  } catch (e, st) {
    StartupLogger.error('LOCALE_INIT_FAILED', e, st);
  }

  // Register the background handler SYNCHRONOUSLY before any async work so
  // terminated-state FCM always has a entry-point (registration race used
  // to drop the first background push after a cold kill).
  if (!DirectoryPilotBuild.enabled) {
    try {
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    } catch (_) {}
  }
  // Non-critical: Firebase init MUST NEVER block runApp.
  // The intro video is NOT initialized here — it is created and initialized
  // by the SplashScreen AFTER the first frame so the video platform is ready.
  // Calling VideoPlayerController.initialize() before runApp fails silently
  // (the platform is not registered yet) leaving _ready=false → no intro.
  if (!DirectoryPilotBuild.enabled) unawaited(_initFirebaseBackground());

  // Non-critical: warm the real device identity for session recognition
  // (model/OS headers). Cached on first read; requests never wait for it.
  DeviceIdentity.warm();

  // Server address override (any LAN device can point the app at the
  // backend): applied before runApp so the first Dio uses it. Fast,
  // bounded — never blocks startup.
  try {
    final sp = await SharedPreferences.getInstance()
        .timeout(const Duration(milliseconds: 800), onTimeout: () => throw TimeoutException('prefs'));
    final saved = sp.getString('server_base_url');
    if (saved != null && saved.isNotEmpty) {
      AppConfig.overrideBaseUrl = saved;
    }
    // Per-section languages (personal / business are separate).
    setInitialSectionLocales(
      personal: sp.getString('locale_personal'),
      business: sp.getString('locale_business'),
    );
  } catch (_) {}

  // Lock orientation — fast, synchronous.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // Restore the signed branch context BEFORE the first frame so the
  // «all branches» read-only banner and the correct scope are never stale.
  try {
    await BranchScope.load();
  } catch (_) {}
  await DeviceLedgerOrganizations.load();

  StartupLogger.log('NATIVE_SPLASH_READY');
  runApp(
    ProviderScope(
      child: _AppWithSync(initialLocale: _savedLocale),
    ),
  );
  unawaited(removeRetiredBusinessStorage().catchError((Object error, StackTrace stack) {
    StartupLogger.error('RETIRED_STORAGE_CLEANUP_FAILED', error, stack);
  }));
}

/// Best-effort Firebase init in background — never stalls startup.
/// Background handler is already registered synchronously in main().
Future<void> _initFirebaseBackground() async {
  try {
    await Firebase.initializeApp().timeout(const Duration(seconds: 4));
    StartupLogger.log('FIREBASE_READY');
  } catch (e) {
    StartupLogger.log('FIREBASE_DEFERRED', e.toString());
  }
}

class _AppWithSync extends ConsumerStatefulWidget {
  final String initialLocale;
  const _AppWithSync({this.initialLocale = 'ar'});
  @override
  ConsumerState<_AppWithSync> createState() => _AppWithSyncState();
}

class _AppWithSyncState extends ConsumerState<_AppWithSync>
    with WidgetsBindingObserver {
  Timer? _controlsTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Never blocks first frame; corrects a dead saved address before the
    // user gets a chance to tap Login.
    if (!DirectoryPilotBuild.enabled) _healServerAddress();
    // Keep admin marketing/controls changes (maintenance, urgency countdown,
    // fake subscriber counter, discounts) live in the app without any
    // restart: refresh the public /controls snapshot every 12s.
    _controlsTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      if (!mounted) return;
      try {
        ref.read(platformControlsProvider.notifier).refresh();
      } catch (_) {}
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Live navigator (rootNavigatorKey drives MaterialApp.router).
      DebtReminderService.setContextProvider(() {
        return rootNavigatorKey.currentContext;
      });
      final notifService = ref.read(notificationServiceProvider);
      notifService.init().then((_) async {
        if (!mounted) return;
        try {
          await notifService.handleColdStartTap();
        } catch (_) {}
      });
      notifService.startPolling();
      // Prefs-only reschedules (no user/session needed) for both types.
      try {
        RecurringReminderService.rescheduleAll();
      } catch (_) {}
      DebtReminderService.init().then((_) async {
        await DebtReminderService.rescheduleAll();
        // Native alarm tap (new bridge) wins; the legacy debt-id flow is
        // the fallback when no generic payload is pending.
        var bridged = false;
        try {
          bridged = await AlarmTapBridge.consumeAndRoute();
        } catch (_) {}
        if (bridged) return;
        final initialId = await DebtReminderService.getInitialAlarmDebtId();
        if (initialId != null && initialId.isNotEmpty && mounted) {
          await Future.delayed(const Duration(milliseconds: 800));
          if (mounted && rootNavigatorKey.currentContext != null) {
            await DebtReminderService.showAlarmForDebtId(initialId, rootNavigatorKey.currentContext!);
          }
        } else {
          Future.delayed(const Duration(seconds: 1), () {
            if (mounted) DebtReminderService.checkAndShowAlarms(() => rootNavigatorKey.currentContext);
          });
        }
      });
      try { ref.read(syncEngineProvider).init(); } catch (_) {}
      try { ref.read(fcmServiceProvider).init(); } catch (_) {}
    });
  }

  /// Probe the configured server and fall back to another candidate when it
  /// is unreachable.
  ///
  /// A phone usually keeps `server_base_url` from a previous install, and that
  /// stale value silently overrides the URL baked into this build — so login
  /// dies with a timeout before any request leaves the device. Probing here
  /// (3s, background) either confirms the address or switches the app onto a
  /// live one before the user can hit Login.
  Future<void> _healServerAddress() async {
    const probeTimeout = Duration(seconds: 3);
    Future<bool> reachable(String base) async {
      final root = base.replaceAll(RegExp(r'/api/v1/?$'), '');
      final probe = Dio(BaseOptions(
        connectTimeout: probeTimeout,
        receiveTimeout: probeTimeout,
      ));
      try {
        final resp = await probe.get('$root/version');
        return resp.statusCode == 200;
      } catch (_) {
        return false;
      } finally {
        probe.close(force: true);
      }
    }

    try {
      final current = ref.read(serverBaseUrlProvider);
      // Fast path: the configured address answers, so leave it alone.
      if (await reachable(current)) return;

      final baked = AppConfig.apiBaseUrl;
      final uri = Uri.tryParse(baked);
      final candidates = <String>[baked];
      if (uri != null && uri.host.isNotEmpty) {
        // Same host on both HTTP ports — one is normally filtered on mobile
        // networks/hotels while the other goes through.
        for (final port in const [80, 8001]) {
          candidates.add('${uri.scheme}://${uri.host}:$port${uri.path}');
        }
      }
      candidates.remove(current);

      for (final candidate in candidates) {
        if (!await reachable(candidate)) continue;
        AppConfig.overrideBaseUrl = candidate;
        if (mounted) {
          ref.read(serverBaseUrlProvider.notifier).state = candidate;
        }
        // Only persist a switch that actually works; a dead override stays
        // unset so auto-discovery gets a chance on the next launch.
        final prefs = await SharedPreferences.getInstance();
        if (candidate != baked) {
          await prefs.setString('server_base_url', candidate);
        } else {
          await prefs.remove('server_base_url');
        }
        debugPrint('[ServerHeal] $current unreachable -> using $candidate');
        return;
      }
      debugPrint('[ServerHeal] no server reachable (tried $current, $candidates)');
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      DebtReminderService.rescheduleAll();
      try {
        RecurringReminderService.rescheduleAll();
      } catch (_) {}
      try {
        AlarmTapBridge.consumeAndRoute();
      } catch (_) {}
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) DebtReminderService.checkAndShowAlarms(() => rootNavigatorKey.currentContext);
      });
      // Coming back from background (e.g. after an admin approval): drop
      // every cached subscription snapshot so plans / invoice / profile
      // card can never show a stale state.
      try {
        ref.invalidate(subscriptionStatusProvider);
        ref.invalidate(subscriptionPlansProvider);
        ref.invalidate(subscriptionInvoicesProvider);
      } catch (_) {}
      try {
        ref.read(platformControlsProvider.notifier).refresh();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const FYONAApp();
  }
}
