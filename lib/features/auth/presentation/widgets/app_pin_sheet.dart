import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/security/app_pin_crypto.dart';
import '../../../../core/theme/app_colors.dart';
import '../../di/auth_providers.dart';
import '../pages/pin_forgot_page.dart';
import '../pages/pin_setup_page.dart';
import '../providers/biometric_provider.dart';
import '../../domain/services/biometric_service.dart';
import 'app_pin_pad.dart';

/// Biometric-first gate for sensitive actions (bank delete, account reset).
/// Uses device biometrics when enabled, otherwise falls back to the app PIN.
/// Fully offline. Returns true only on successful verification.
Future<bool> verifySensitiveAction(
  BuildContext context,
  WidgetRef ref, {
  String? reason,
  bool existingCredentialsOnly = false,
}) async {
  final l10n = AppLocalizations.of(context);
  try {
    await ref.read(biometricProvider.notifier).ready;
  } catch (_) {}
  if (!context.mounted) return false;
  final bio = ref.read(biometricProvider);
  var usable = bio.isDeviceSupported && bio.canCheckBiometrics;
  if (usable && context.mounted) {
    try {
      usable = (await ref
              .read(biometricServiceProvider)
              .getAvailableBiometrics())
          .isNotEmpty;
    } catch (_) {
      usable = false;
    }
  }

  if (usable) {
    AuthResult res;
    try {
      res = await ref.read(biometricProvider.notifier).authenticate(
            reason: reason ?? l10n.translate('bioDefaultReason'),
          );
    } catch (_) {
      res = AuthResult.error;
    }
    if (res == AuthResult.success) {
      if (!context.mounted) return false;
      if (!bio.isEnabled && !existingCredentialsOnly) {
        try {
          await ref.read(biometricProvider.notifier).setEnabled(true);
          await ref.read(biometricProvider.notifier).snapshotCurrentSession();
        } catch (_) {}
      }
      return true;
    }
    if (res == AuthResult.lockedOut ||
        res == AuthResult.permanentlyLockedOut) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.t('biometricLocked'),
                style: const TextStyle(fontFamily: 'Cairo')),
            backgroundColor: AppColors.warning,
          ),
        );
      }
    }
  }

  if (!context.mounted) return false;
  final hasPin = await _hasAppPin(ref);
  if (!context.mounted) return false;
  if (hasPin) {
    return showAppPinVerifySheet(
      context, ref, title: reason, allowRecovery: !existingCredentialsOnly,
    );
  }
  if (existingCredentialsOnly) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.translate('businessBackupVerifyExisting'))),
    );
    return false;
  }
  final created = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => PinSetupPage(
        reason: reason ??
            l10n.translate('pinSensitiveCreateReason'),
      ),
    ),
  );
  return created == true;
}

Future<bool> _hasAppPin(WidgetRef ref) async {
  try {
    final pin = await ref.read(authLocalDataSourceProvider).getAppPin();
    return pin != null && pin.isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// Bottom sheet asking for the 5-digit app PIN (offline check). Also offers
/// biometric when enabled and a forgot-PIN entry. Returns true on success.
Future<bool> showAppPinVerifySheet(
  BuildContext context,
  WidgetRef ref, {
  String? title,
  bool allowRecovery = true,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => _AppPinVerifySheet(title: title, allowRecovery: allowRecovery),
  );
  return result == true;
}

class _AppPinVerifySheet extends ConsumerStatefulWidget {
  final String? title;
  final bool allowRecovery;
  const _AppPinVerifySheet({this.title, required this.allowRecovery});

  @override
  ConsumerState<_AppPinVerifySheet> createState() =>
      _AppPinVerifySheetState();
}

class _AppPinVerifySheetState extends ConsumerState<_AppPinVerifySheet> {
  final _padKey = GlobalKey<AppPinPadState>();
  String? _error;
  bool _busy = false;

  Future<void> _verify(String pin) async {
    if (_busy) return;
    setState(() => _busy = true);
    bool ok = false;
    try {
      final record = await ref.read(authLocalDataSourceProvider).getAppPin();
      ok = verifyAppPinRecord(pin, record);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = AppLocalizations.of(context).translate('pinWrong');
    });
    _padKey.currentState?.clear();
  }

  Future<void> _bio() async {
    if (_busy) return;
    setState(() => _busy = true);
    AuthResult res;
    try {
      res = await ref.read(biometricProvider.notifier).authenticate(
            reason: AppLocalizations.of(context).translate('pinVerifyTitle'),
          );
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    if (res == AuthResult.success) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final bioState = ref.watch(biometricProvider);
    final showBio = bioState.isEnabled && bioState.canCheckBiometrics;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 16),
            Text(
              widget.title ?? l10n.translate('pinVerifyTitle'),
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary),
            ),
            const SizedBox(height: 16),
            if (showBio) ...[
              SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _bio,
                  icon: const Icon(Icons.fingerprint, size: 22),
                  label: Text(l10n.translate('unlockWithBiometric'),
                      style: const TextStyle(
                          fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 12),
            ],
            AppPinPad(
              key: _padKey,
              enabled: !_busy,
              onCompleted: _verify,
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 13,
                      color: AppColors.danger)),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (widget.allowRecovery) TextButton(
                  onPressed: _busy
                      ? null
                      : () {
                          Navigator.of(context).push<bool>(
                            MaterialPageRoute(
                                builder: (_) => const PinForgotPage()),
                          );
                        },
                  child: Text(l10n.translate('pinForgotLink'),
                      style: TextStyle(
                          fontFamily: 'Cairo', color: AppColors.primary)),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(l10n.translate('cancel'),
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          color: AppColors.textSecondary)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
