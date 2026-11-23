import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';

/// Banking-grade biometric authentication service.
///
/// Uses the native System Biometric Prompt on Android/iOS via `local_auth`.
/// - Android: BiometricPrompt / KeyguardManager
/// - iOS: LAContext.evaluatePolicy
///
/// Supports: Fingerprint, Face ID, Face Recognition, Iris, and device
/// PIN / Password / Pattern as fallback (`biometricOnly: false`).
///
/// The native prompt always shows "Use Password" / "استخدام كلمة المرور"
/// when the device supports it — this is controlled by the OS, not by this app.
class BiometricService {
  final LocalAuthentication _localAuth;

  BiometricService({LocalAuthentication? localAuth})
      : _localAuth = localAuth ?? LocalAuthentication();

  Future<bool> isDeviceSupported() async {
    try {
      return await _localAuth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  Future<bool> canCheckBiometrics() async {
    try {
      return await _localAuth.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _localAuth.getAvailableBiometrics();
    } catch (_) {
      return [];
    }
  }

  Future<AuthResult> authenticate({String? reason}) async {
    final auth = LocalAuthentication();
    try {
      final didAuthenticate = await auth.authenticate(
        localizedReason: reason ?? AppLocalizations.t('bioDefaultReason'),
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
          useErrorDialogs: false,
        ),
      );
      return didAuthenticate ? AuthResult.success : AuthResult.cancelled;
    } on PlatformException catch (e) {
      return _mapPlatformError(e.code);
    } catch (_) {
      try {
        final didAuthenticate = await LocalAuthentication().authenticate(
          localizedReason: reason ?? AppLocalizations.t('bioDefaultReason'),
          options: const AuthenticationOptions(
            stickyAuth: false,
            biometricOnly: false,
            useErrorDialogs: false,
          ),
        );
        return didAuthenticate ? AuthResult.success : AuthResult.cancelled;
      } on PlatformException catch (e) {
        return _mapPlatformError(e.code);
      } catch (_) {
        return AuthResult.error;
      }
    }
  }

  AuthResult _mapPlatformError(String code) {
    switch (code) {
      case 'LockedOut':
        return AuthResult.lockedOut;
      case 'PermanentlyLockedOut':
        return AuthResult.permanentlyLockedOut;
      case 'NotAvailable':
        return AuthResult.notAvailable;
      case 'NotEnrolled':
        return AuthResult.notEnrolled;
      case 'OtherOperatingSystem':
        return AuthResult.notSupported;
      case 'InvalidAuthOperation':
        return AuthResult.error;
      default:
        return AuthResult.error;
    }
  }
}

/// Represents the result of a biometric authentication attempt.
enum AuthResult {
  /// Authentication succeeded (biometric or device credential).
  success,

  /// User cancelled the prompt (swipe away, back button, "cancel" button).
  cancelled,

  /// Too many failed attempts. Device is temporarily locked.
  lockedOut,

  /// Too many failed attempts. Device is permanently locked
  /// until biometrics are re-enrolled or device is restarted.
  permanentlyLockedOut,

  /// Device hardware does not support biometrics.
  notAvailable,

  /// No biometrics enrolled on the device.
  notEnrolled,

  /// Platform does not support biometrics (e.g., web, desktop).
  notSupported,

  /// An unexpected error occurred.
  error,
}
