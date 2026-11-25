import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';
import '../../../core/router/route_names.dart';
import '../../../core/startup/startup_logger.dart';
import '../../../shared/providers/auth_provider.dart';
import '../../../shared/services/notification_router.dart';
import '../../auth/presentation/providers/biometric_provider.dart';
import '../../../core/network/session_timeout_provider.dart';
import 'brand_entry_view.dart';
import 'brand_handoff_page.dart';
import 'intro_video.dart';
import '../domain/intro_replay_policy.dart';

/// Production-ready startup flow:
/// PURE BLACK NATIVE LAUNCH (<1s) → VideoPlayer widget mounted immediately
/// → controller initialized AFTER first frame (platform ready) → fade in
/// local asset video (fullscreen, with sound) → VIDEO_COMPLETED → crossfade.
/// NO logo, NO poster, NO grey screen, NO hanging future, NO network needed.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late VideoPlayerController _controller;
  bool _isVideoReady = false;
  bool _isVideoCompleted = false;
  bool _hasNavigated = false;
  bool _hasFaded = false;
  bool _isPausedByLifecycle = false;
  bool _initStarted = false;
  /// True when the intro motion was skipped (played < 72h ago): the splash
  /// then shows the calm branded entry (logo reveal, no spinner) and hands
  /// over with a crossfade into the first screen.
  bool _introSkipped = false;

  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  late AnimationController _overallController;
  late Animation<double> _overallAnimation;

  Timer? _safetyTimer;
  Timer? _authPollTimer;

  static const _fadeDuration = Duration(milliseconds: 450);
  static const _overallFadeDuration = Duration(milliseconds: 350);
  static const _initTimeout = Duration(seconds: 8);
  static const _maxVideoDuration = Duration(seconds: 25);
  /// Hard cap: if the session restore ever hangs, force navigation so the
  /// user is NEVER stuck on a black screen. The router then routes them to
  /// whatever state auth finally reaches (login / re-entry / home).
  static const _authResolveHardCap = Duration(seconds: 15);

  @override
  void initState() {
    super.initState();
    StartupLogger.log('FLUTTER_STARTED');
    WidgetsBinding.instance.addObserver(this);

    _fadeController = AnimationController(vsync: this, duration: _fadeDuration);
    _fadeAnimation = CurvedAnimation(parent: _fadeController, curve: Curves.easeInOut);
    _overallController = AnimationController(vsync: this, duration: _overallFadeDuration, value: 1.0);
    _overallAnimation = CurvedAnimation(parent: _overallController, curve: Curves.easeInOut);

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // Create the controller synchronously (no platform call yet). The
    // VideoPlayer widget below mounts immediately and follows the playerId.
    _controller = VideoPlayerController.asset('assets/video/intro.mp4');

    // Initialize AFTER the first frame so the video platform is registered
    // (calling initialize in main() before runApp causes the whole pipeline
    // to fail silently — the root cause of the missing intro video).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _hasNavigated) return;
      // Play the intro motion only on first launch or once 72h have passed
      // since it last played; otherwise go straight to the next step.
      final play = await IntroReplayPolicy.shouldPlayNow();
      if (!mounted || _hasNavigated) return;
      if (!play) {
        StartupLogger.log('VIDEO_SKIPPED', 'played < 72h ago');
        setState(() => _introSkipped = true);
        _navigateToApp();
        return;
      }
      _startVideoInit();
    });

    // Absolute safety: never trap the user on a black screen.
    _safetyTimer = Timer(const Duration(seconds: 12), () {
      StartupLogger.log('SAFETY_TIMEOUT');
      _navigateToApp();
    });
  }

  Future<void> _startVideoInit() async {
    if (_initStarted) return;
    _initStarted = true;
    _controller.addListener(_onVideoTick);
    final ok = await IntroVideo.prepareForPlayback(_controller, timeout: _initTimeout);
    if (!mounted || _hasNavigated) return;
    if (ok) {
      setState(() => _isVideoReady = true);
      _fadeController.forward();
      // Play on the next frame for clean first paint.
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted || _hasNavigated) return;
        try {
          await _controller.play();
          StartupLogger.log('VIDEO_STARTED');
          unawaited(IntroReplayPolicy.markPlayed());
        } catch (e, st) {
          StartupLogger.error('VIDEO_START_FAILED', e, st);
          _navigateToApp();
        }
      });
      // Hard cap for video duration.
      Future.delayed(_maxVideoDuration, () {
        if (mounted && !_hasNavigated) {
          StartupLogger.log('VIDEO_MAX_DURATION_REACHED');
          _navigateToApp();
        }
      });
    } else {
      // Video failed — keep pure black briefly then proceed to app.
      StartupLogger.log('VIDEO_READY_FAILED', 'skipping video');
      setState(() => _introSkipped = true);
      await Future.delayed(const Duration(milliseconds: 300));
      if (mounted) _navigateToApp();
    }
  }

  void _onVideoTick() {
    final c = _controller;
    if (!mounted || _hasNavigated || _isVideoCompleted) return;
    if (!c.value.isInitialized || c.value.duration.inMilliseconds <= 0) return;
    final pos = c.value.position;
    final dur = c.value.duration;
    final remaining = dur - pos;

    if (remaining <= const Duration(milliseconds: 80) || pos >= dur) {
      if (_isVideoCompleted) return;
      _isVideoCompleted = true;
      StartupLogger.log('VIDEO_COMPLETED', '${dur.inMilliseconds}ms');
      try { c.removeListener(_onVideoTick); } catch (_) {}
      _navigateToApp();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_controller.value.isInitialized) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      if (_controller.value.isPlaying) {
        _controller.pause();
        _isPausedByLifecycle = true;
        StartupLogger.log('VIDEO_PAUSED_LIFECYCLE');
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_isPausedByLifecycle && !_hasNavigated && !_isVideoCompleted) {
        _isPausedByLifecycle = false;
        _controller.play();
        StartupLogger.log('VIDEO_RESUMED_LIFECYCLE');
      }
    }
  }

  void _navigateToApp() {
    if (_hasNavigated) return;
    _hasNavigated = true;
    _safetyTimer?.cancel();
    _authPollTimer?.cancel();

    StartupLogger.log('NAVIGATING_TO_APP', 'status=${ref.read(authProvider).status}');
    _resolveDestination();
  }

  /// Wait for the auth restore (`_checkSession`) to resolve, THEN fade out
  /// and navigate. Navigating while the status is still `initial` causes the
  /// router's restore guard to bounce us straight back to the splash — an
  /// endless black/video loop. The hard cap below guarantees we never wait
  /// forever even if the session check hangs.
  void _resolveDestination() {
    final authState = ref.read(authProvider);
    if (authState.status == AuthStatus.initial) {
      int attempts = 0;
      _authPollTimer = Timer.periodic(const Duration(milliseconds: 100), (t) {
        if (!mounted) { t.cancel(); return; }
        final s = ref.read(authProvider).status;
        attempts++;
        if (s != AuthStatus.initial) {
          t.cancel();
          _authPollTimer = null;
          _fadeAndNavigate();
        } else if (attempts * 100 >= _authResolveHardCap.inMilliseconds) {
          t.cancel();
          _authPollTimer = null;
          StartupLogger.log('AUTH_RESTORE_CAP', 'forcing navigation');
          // Absolute failsafe (very slow network): open the account saved on
          // this device — a slow restore must never sign the user out. Only
          // when no account is saved here does the login screen show.
          unawaited(() async {
            String? err = 'none';
            try {
              err = await ref.read(authProvider.notifier).restoreCachedSession();
            } catch (_) {}
            if (!mounted) return;
            if (err != null && ref.read(authProvider).status == AuthStatus.initial) {
              try {
                final notifier = ref.read(authStateProvider.notifier);
                notifier.state = notifier.state.copyWith(status: AuthStatus.unauthenticated);
              } catch (_) {}
            }
            _fadeAndNavigate();
          }());
        }
      });
      return;
    }
    _fadeAndNavigate();
  }

  void _fadeAndNavigate() {
    if (!mounted || _hasFaded) return;
    _hasFaded = true;
    if (_introSkipped) {
      // The branded entry stays on screen; the next page crossfades over it.
      _finalizeNavigation();
      return;
    }
    _overallController
        .animateTo(0.0, duration: _overallFadeDuration, curve: Curves.easeInOut)
        .whenComplete(() {
      if (!mounted) return;
      _finalizeNavigation();
    });
  }

  Future<void> _finalizeNavigation() async {
    if (!mounted) return;
    final authState = ref.read(authProvider);
    StartupLogger.log('APP_INITIALIZATION_COMPLETED', 'isAuth=${authState.isAuthenticated} status=${authState.status}');

    if (authState.status == AuthStatus.sessionExpired) {
      StartupLogger.log('NAVIGATING_TO_APP', '-> reentry');
      _go(RouteNames.reentry);
      return;
    }

    if (!authState.isAuthenticated) {
      StartupLogger.log('NAVIGATING_TO_APP', '-> login');
      _go(RouteNames.login);
      return;
    }

    // A protected app opens behind the in-app lock (fingerprint first, then
    // the app PIN). Failing or cancelling the fingerprint never signs the
    // user out: only a manual logout or removal from the sessions page does.
    final bioState = ref.read(biometricProvider);
    try {
      await ref
          .read(sessionTimeoutProvider.notifier)
          .lockForStartup(biometric: bioState.shouldPrompt)
          .timeout(const Duration(seconds: 3), onTimeout: () => false);
    } catch (e, st) {
      StartupLogger.error('APP_LOCK_ERROR', e, st);
    }
    if (!mounted) return;
    _goHome(authState);
  }

  void _goHome(dynamic authState) {
    if (!mounted) return;
    // Resolve entitlements and the account's saved section BEFORE mounting a
    // dashboard: mounting Business first overwrites the Personal history.
    const target = '/account-entry';
    StartupLogger.log('NAVIGATING_TO_APP', '-> $target');
    _go(target);
  }

  void _go(String route) {
    if (!mounted) return;
    // The first screen fades/scales in over the branded entry (no jump).
    BrandEntryHandoff.arm();
    context.go(route);
    // A notification tapped while the app was terminated waited for this
    // exact moment — deliver it right after the intro finishes.
    if (route != RouteNames.login && route != RouteNames.reentry) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          NotificationRouter.flushPending();
        } catch (_) {}
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    try { _controller.removeListener(_onVideoTick); } catch (_) {}
    _safetyTimer?.cancel();
    _authPollTimer?.cancel();
    _fadeController.dispose();
    _overallController.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // Disposing the controller stops the native player — correct when splash
    // is replaced by the app. It is NOT shared globally anymore.
    try { _controller.dispose(); } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Mount VideoPlayer immediately — it follows playerId once initialized.
    // Until then it renders transparent (kept black by our base layer).
    final Widget videoLayer = SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: _controller.value.size.width > 0 ? _controller.value.size.width : 1080,
          height: _controller.value.size.height > 0 ? _controller.value.size.height : 1920,
          child: VideoPlayer(_controller),
        ),
      ),
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: FadeTransition(
        opacity: _overallAnimation,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Pure black base — NO logo, NO poster, no placeholder.
            const ColoredBox(color: Colors.black),
            // Intro skipped (or unavailable): calm branded entry instead of
            // a bare black screen / loading spinner while the app prepares.
            if (_introSkipped) const BrandEntryView(),
            // Video fullscreen over black, fades in after init success.
            if (_isVideoReady)
              FadeTransition(opacity: _fadeAnimation, child: videoLayer),
          ],
        ),
      ),
    );
  }
}
