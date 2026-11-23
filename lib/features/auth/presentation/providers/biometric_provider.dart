import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/services/biometric_service.dart';
import '../../di/auth_providers.dart';
import '../../data/datasources/auth_local_data_source.dart';

final biometricServiceProvider = Provider<BiometricService>((ref) {
  return BiometricService();
});

class BiometricState {
  final bool isEnabled;
  final bool isDeviceSupported;
  final bool canCheckBiometrics;

  const BiometricState({
    this.isEnabled = false,
    this.isDeviceSupported = false,
    this.canCheckBiometrics = false,
  });

  BiometricState copyWith({
    bool? isEnabled,
    bool? isDeviceSupported,
    bool? canCheckBiometrics,
  }) {
    return BiometricState(
      isEnabled: isEnabled ?? this.isEnabled,
      isDeviceSupported: isDeviceSupported ?? this.isDeviceSupported,
      canCheckBiometrics: canCheckBiometrics ?? this.canCheckBiometrics,
    );
  }

  bool get shouldPrompt =>
      isEnabled && isDeviceSupported && canCheckBiometrics;
}

class BiometricNotifier extends StateNotifier<BiometricState> {
  final BiometricService _biometricService;
  final AuthLocalDataSource _localDataSource;
  late final Future<void> ready;

  BiometricNotifier(this._biometricService, this._localDataSource)
      : super(const BiometricState()) {
    ready = _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    try {
      final enabled = await _localDataSource.getBiometricEnabled();
      final supported = await _biometricService.isDeviceSupported();
      final canCheck = await _biometricService.canCheckBiometrics();
      if (!mounted) return;
      state = state.copyWith(
        isEnabled: enabled,
        isDeviceSupported: supported,
        canCheckBiometrics: canCheck,
      );
    } catch (_) {}
  }

  Future<AuthResult> authenticate({String? reason}) async {
    return await _biometricService.authenticate(reason: reason);
  }

  Future<void> setEnabled(bool value) async {
    await _localDataSource.saveBiometricEnabled(value);
    if (!value) {
      // Fingerprint turned off: the gated snapshot must die with it.
      try {
        await _localDataSource.clearBiometricSnapshot();
      } catch (_) {}
    }
    state = state.copyWith(isEnabled: value);
  }

  Future<void> saveCredentials({required String email, required String password}) async {
    await _localDataSource.saveBiometricCredentials(email: email, password: password);
  }

  /// Snapshot the CURRENT session (tokens + user + usage mode) into the
  /// fingerprint-gated store. Called when biometric is enabled and on
  /// logout/refresh so a later fingerprint restores the account directly.
  Future<void> snapshotCurrentSession() async {
    try {
      final access = await _localDataSource.getAccessToken();
      final user = await _localDataSource.getUser();
      if (access == null || access.isEmpty || user == null) return;
      final refresh = await _localDataSource.getRefreshToken();
      final mode = await _localDataSource.getUsageMode();
      await _localDataSource.saveBiometricSnapshot(
        accessToken: access,
        refreshToken: refresh,
        userJson: jsonEncode(user.toJson()),
        usageMode: mode,
      );
    } catch (_) {}
  }

  Future<String?> getBiometricEmail() => _localDataSource.getBiometricEmail();
  Future<String?> getBiometricPassword() => _localDataSource.getBiometricPassword();

}

final biometricProvider =
    StateNotifierProvider<BiometricNotifier, BiometricState>((ref) {
  return BiometricNotifier(
    ref.watch(biometricServiceProvider),
    ref.watch(authLocalDataSourceProvider),
  );
});
