import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/session_timeout_provider.dart';
import '../../../../core/security/app_pin_crypto.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../di/auth_providers.dart' hide authProvider;
import '../providers/auth_provider.dart';
import '../providers/biometric_provider.dart';
import '../../domain/services/biometric_service.dart';
import '../widgets/app_pin_pad.dart';
import 'pin_forgot_page.dart';

/// Full-screen lock shown after an idle timeout. Keeps the underlying
/// navigation stack alive so unlocking resumes exactly where the user left.
class SessionLockScreen extends ConsumerStatefulWidget {
  const SessionLockScreen({super.key});

  @override
  ConsumerState<SessionLockScreen> createState() => _SessionLockScreenState();
}

class _SessionLockScreenState extends ConsumerState<SessionLockScreen> {
  final _padKey = GlobalKey<AppPinPadState>();
  bool _attempting = false;
  bool _autoBioTriggered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryAutoBiometric());
  }

  Future<void> _tryAutoBiometric() async {
    if (_autoBioTriggered || !mounted) return;
    _autoBioTriggered = true;
    await ref.read(biometricProvider.notifier).ready;
    if (!mounted) return;
    final bioState = ref.read(biometricProvider);
    if (!bioState.isDeviceSupported || !bioState.canCheckBiometrics) return;
    if (!mounted) return;
    if (bioState.isEnabled) _unlockWithBiometric();
  }

  Future<void> _unlockWithBiometric() async {
    if (_attempting) return;
    setState(() => _attempting = true);
    final l10n = AppLocalizations.of(context);
    final result = await ref.read(biometricProvider.notifier).authenticate(
      reason: l10n.lockScreenTitle,
    );
    if (!mounted) return;
    setState(() => _attempting = false);
    if (result == AuthResult.success) {
      ref.read(sessionTimeoutProvider.notifier).unlock();
    } else if (result == AuthResult.lockedOut ||
        result == AuthResult.permanentlyLockedOut) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.biometricLocked,
              style: const TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppColors.danger,
        ),
      );
    }
  }

  Future<void> _unlockWithPin(String pin) async {
    if (_attempting) return;
    setState(() => _attempting = true);
    bool ok = false;
    try {
      final record =
          await ref.read(authLocalDataSourceProvider).getAppPin();
      ok = verifyAppPinRecord(pin, record);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    if (ok) {
      ref.read(sessionTimeoutProvider.notifier).unlock();
      return;
    }
    setState(() => _attempting = false);
    _padKey.currentState?.clear();
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.translate('pinWrong'),
            style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: AppColors.danger,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final bioState = ref.watch(biometricProvider);
    final showBio = bioState.isDeviceSupported && bioState.canCheckBiometrics;
    final user = ref.watch(authProvider).user;
    final userLabel = user?.fullName ?? user?.phone ?? '';

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                    Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: AppColors.border, width: 1),
                      ),
                      child: const Icon(
                        Icons.lock_outline,
                        size: 40,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      l10n.lockScreenTitle,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 22),
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.lockScreenSubtitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 13),
                        fontWeight: FontWeight.w500,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    if (userLabel.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        userLabel,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 13),
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 28),
                    if (showBio) ...[
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton.icon(
                          onPressed: _attempting ? null : _unlockWithBiometric,
                          icon: _attempting
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2.5, color: Colors.white))
                              : const Icon(Icons.fingerprint, size: 22),
                          label: Text(
                            l10n.unlockWithBiometric,
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: R.fontSize(context, 14),
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        l10n.translate('lockScreenPinHint'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 12),
                          fontWeight: FontWeight.w600,
                          color: AppColors.textDisabled,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    AppPinPad(
                      key: _padKey,
                      enabled: !_attempting,
                      onCompleted: _unlockWithPin,
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: () {
                        Navigator.of(context).push<bool>(
                          MaterialPageRoute(
                              builder: (_) => const PinForgotPage()),
                        );
                      },
                      child: Text(
                        l10n.translate('pinForgotLink'),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 13),
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: () async {
                        await ref.read(authProvider.notifier).logout();
                      },
                      child: Text(
                        l10n.logout,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 12),
                          fontWeight: FontWeight.w500,
                          color: AppColors.textDisabled,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
  }
