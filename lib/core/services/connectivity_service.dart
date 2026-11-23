import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ConnectivityService {
  final Connectivity _connectivity = Connectivity();
  final StreamController<bool> _controller = StreamController<bool>.broadcast();
  StreamSubscription? _subscription;
  bool _isOnline;
  Future<void>? _initializing;

  /// When true the platform plugin is never touched — used by integration
  /// tests to simulate devices flipping between online and offline.
  final bool _debugMode;

  ConnectivityService({bool? debugOnline})
    : _isOnline = debugOnline ?? true,
      _debugMode = debugOnline != null;

  Stream<bool> get onConnectivityChanged => _controller.stream;
  bool get isOnline => _isOnline;

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
    _isOnline = !result.contains(ConnectivityResult.none);
    _subscription = _connectivity.onConnectivityChanged.listen((result) {
      final online = !result.contains(ConnectivityResult.none);
      if (_isOnline != online) {
        _isOnline = online;
        _controller.add(_isOnline);
      }
    });
  }

  /// Test/dev hook: flips the connectivity state and notifies listeners
  /// exactly like a real network transition.
  void debugSetOnline(bool online) {
    _isOnline = online;
    _controller.add(online);
  }

  void dispose() {
    _subscription?.cancel();
    _controller.close();
  }
}

final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  return ConnectivityService();
});
