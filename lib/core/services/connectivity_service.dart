import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'network_quality_monitor.dart';

export 'network_quality_monitor.dart' show NetworkQuality;

class ConnectivityService {
  final Connectivity _connectivity = Connectivity();
  final StreamController<bool> _controller = StreamController<bool>.broadcast();
  StreamSubscription? _subscription;
  StreamSubscription<NetworkQuality>? _qualitySub;

  /// What the platform reports (Wi-Fi / data present).
  bool _platformOnline;
  bool _lastReported;
  Future<void>? _initializing;
  String? _probeBaseUrl;
  String? _lastLinks;

  /// When true the platform plugin is never touched — used by integration
  /// tests to simulate devices flipping between online and offline.
  final bool _debugMode;

  /// Network-quality classifier. A connected but practically unusable link
  /// (very poor) is reported as OFFLINE by [isOnline], so every screen of
  /// both sections behaves exactly as with no network at all.
  final NetworkQualityMonitor quality;

  ConnectivityService({bool? debugOnline, NetworkQualityMonitor? quality})
    : _platformOnline = debugOnline ?? true,
      _lastReported = debugOnline ?? true,
      _debugMode = debugOnline != null,
      quality = quality ?? NetworkQualityMonitor() {
    // An injected monitor (tests) is live right away; the default one starts
    // once the platform listener is up.
    if (quality != null) this.quality.enabled = _platformOnline;
    _qualitySub = this.quality.changes.listen((_) => _report());
  }

  Stream<bool> get onConnectivityChanged => _controller.stream;

  /// Online = the platform has a network AND it is not very poor.
  bool get isOnline => _platformOnline && !quality.isPoor;

  /// True while the device is connected but the link is unusable.
  bool get isNetworkPoor => _platformOnline && quality.isPoor;

  Future<void> init() async {
    if (_debugMode) return;
    if (_subscription != null) return;
    final existing = _initializing;
    if (existing != null) return existing;
    final future = _initialize();
    _initializing = future;
    try {
      await future;
    } finally {
      if (identical(_initializing, future)) _initializing = null;
    }
  }

  Future<void> _initialize() async {
    final result = await _connectivity.checkConnectivity();
    _lastLinks = (result.map((r) => r.name).toList()..sort()).join(',');
    _setPlatform(!result.contains(ConnectivityResult.none));
    _subscription = _connectivity.onConnectivityChanged.listen((result) {
      final links = (result.map((r) => r.name).toList()..sort()).join(',');
      // A new/lost link (Wi-Fi <-> data): what was measured on the previous
      // one is void.
      if (links != _lastLinks) quality.reset();
      _lastLinks = links;
      _setPlatform(!result.contains(ConnectivityResult.none));
    });
  }

  void _setPlatform(bool online) {
    _platformOnline = online;
    quality.enabled = online;
    _report();
  }

  void _report() {
    final online = isOnline;
    if (online == _lastReported) return;
    _lastReported = online;
    if (!_controller.isClosed) _controller.add(online);
  }

  /// Points the active probe at the FYONA server (called by the Dio
  /// provider, so it follows server-address changes).
  void attachServer(String baseUrl) {
    _probeBaseUrl = baseUrl;
    if (!quality.hasProbe) quality.probe = _probeServer;
  }

  /// Tiny GET to the server's `/version` (no auth, no DB, not rate limited)
  /// on a dedicated client with short timeouts.
  Future<Duration?> _probeServer() async {
    final base = _probeBaseUrl;
    if (base == null || base.isEmpty) return null;
    final root = base.replaceAll(RegExp(r'/api/v1/?$'), '');
    final timeout = quality.config.probeTimeout;
    final dio = Dio(BaseOptions(
      connectTimeout: timeout,
      receiveTimeout: timeout,
      sendTimeout: timeout,
    ));
    final watch = Stopwatch()..start();
    try {
      await dio.get<dynamic>('$root/version');
      return watch.elapsed;
    } on DioException catch (e) {
      // Any HTTP answer means the server is reachable over this link.
      return e.type == DioExceptionType.badResponse ? watch.elapsed : null;
    } catch (_) {
      return null;
    } finally {
      dio.close(force: true);
    }
  }

  /// «Retry» from the offline dialog: when the link was judged very poor,
  /// probe once now (bounded by the probe timeout) instead of waiting for
  /// the next back-off step.
  Future<bool> recheck() async {
    if (!_platformOnline) return false;
    if (quality.isPoor) await quality.recheck();
    return isOnline;
  }

  /// Test/dev hook: flips the connectivity state and notifies listeners
  /// exactly like a real network transition.
  void debugSetOnline(bool online) {
    _platformOnline = online;
    quality.reset();
    quality.enabled = online;
    _lastReported = isOnline;
    if (!_controller.isClosed) _controller.add(_lastReported);
  }

  void dispose() {
    _subscription?.cancel();
    _qualitySub?.cancel();
    quality.dispose();
    _controller.close();
  }
}

final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  return ConnectivityService();
});
