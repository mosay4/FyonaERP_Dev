import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/auth/data/datasources/auth_local_data_source.dart';
import '../../features/auth/di/auth_providers.dart';

/// Default idle timeout applied until the user picks a preference.
const defaultSessionTimeout = Duration(minutes: 15);

class SessionTimeoutState {
  final Duration? duration;
  final DateTime lastActivity;
  final bool locked;
  final bool loaded;

  const SessionTimeoutState({
    this.duration,
    required this.lastActivity,
    this.locked = false,
    this.loaded = false,
  });

  SessionTimeoutState copyWith({
    Duration? duration,
    DateTime? lastActivity,
    bool? locked,
    bool? loaded,
    bool clearDuration = false,
  }) {
    return SessionTimeoutState(
      duration: clearDuration ? null : (duration ?? this.duration),
      lastActivity: lastActivity ?? this.lastActivity,
      locked: locked ?? this.locked,
      loaded: loaded ?? this.loaded,
    );
  }
}

class SessionTimeoutNotifier extends StateNotifier<SessionTimeoutState> {
  final AuthLocalDataSource _localDataSource;
  Timer? _checkTimer;
  AppLifecycleListener? _lifecycleListener;
  bool _authenticated = false;

  SessionTimeoutNotifier(this._localDataSource)
      : super(SessionTimeoutState(lastActivity: DateTime.now())) {
    _load();
    _lifecycleListener = AppLifecycleListener(onResume: _onResume);
    FocusManager.instance.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (FocusManager.instance.primaryFocus != null) {
      recordActivity();
    }
  }

  /// Only an active session can be locked. Called by the router overlay
  /// whenever authentication changes.
  void setAuthenticated(bool value) {
    if (_authenticated == value) return;
    _authenticated = value;
    if (!value) {
      if (state.locked) unlock();
    } else {
      state = state.copyWith(lastActivity: DateTime.now());
    }
  }

  Future<void> _load() async {
    try {
      final duration = await _localDataSource.getSessionTimeoutDuration();
      if (!mounted) return;
      state = state.copyWith(
        clearDuration: duration == null,
        duration: duration,
        lastActivity: DateTime.now(),
        loaded: true,
      );
      _startChecker();
    } catch (_) {
      if (!mounted) return;
      state = state.copyWith(loaded: true);
      _startChecker();
    }
  }

  void _startChecker() {
    _checkTimer?.cancel();
    _checkTimer = Timer.periodic(const Duration(seconds: 10), (_) => _check());
  }

  void _check() {
    final duration = state.duration;
    if (!_authenticated || !state.loaded || state.locked || duration == null) {
      return;
    }
    final idle = DateTime.now().difference(state.lastActivity);
    if (idle >= duration) {
      lock();
    }
  }

  void _onResume() {
    recordActivity();
    _check();
  }

  void recordActivity() {
    if (!_authenticated || !state.loaded || state.locked) return;
    state = state.copyWith(lastActivity: DateTime.now());
  }

  Future<void> setDuration(Duration? duration) async {
    await _localDataSource.saveSessionTimeoutMinutes(duration);
    if (!mounted) return;
    state = state.copyWith(
      clearDuration: duration == null,
      duration: duration,
      lastActivity: DateTime.now(),
      locked: false,
    );
  }

  /// Locks immediately when session-timeout protection is ON (a duration is
  /// set and an app PIN exists) and the session is authenticated. Used on
  /// cold start so killing + reopening the app shows the same lock screen
  /// as an idle timeout — fully offline (local PIN check only).
  Future<void> lockIfProtected() async {
    for (var i = 0; i < 40 && !state.loaded; i++) {
      await Future.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;
    }
    if (!mounted || !state.loaded || state.locked) return;
    if (state.duration == null) return;
    if (!_authenticated) return;
    try {
      final pin = await _localDataSource.getAppPin();
      if (pin == null || pin.isEmpty) return;
      lock();
    } catch (_) {}
  }

  /// Cold start of a signed-in account whose app is protected: fingerprint
  /// login is on ([biometric]) or the idle timeout + app PIN are set. Shows
  /// the in-app lock (fingerprint, then PIN) — never the login screen.
  Future<bool> lockForStartup({required bool biometric}) async {
    for (var i = 0; i < 40 && !state.loaded; i++) {
      await Future.delayed(const Duration(milliseconds: 50));
      if (!mounted) return false;
    }
    if (!mounted) return false;
    if (!state.loaded) state = state.copyWith(loaded: true);
    _authenticated = true;
    var protect = biometric;
    if (!protect && state.duration != null) {
      try {
        final pin = await _localDataSource.getAppPin();
        protect = pin != null && pin.isNotEmpty;
      } catch (_) {}
    }
    if (!mounted || !protect) return false;
    lock();
    return true;
  }

  void lock() {
    if (!state.loaded || state.locked) return;
    state = state.copyWith(locked: true, lastActivity: DateTime.now());
  }

  void unlock() {
    if (!state.locked) return;
    state = state.copyWith(locked: false, lastActivity: DateTime.now());
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    _lifecycleListener?.dispose();
    FocusManager.instance.removeListener(_onFocusChanged);
    super.dispose();
  }
}

final sessionTimeoutProvider =
    StateNotifierProvider<SessionTimeoutNotifier, SessionTimeoutState>((ref) {
  return SessionTimeoutNotifier(ref.watch(authLocalDataSourceProvider));
});
