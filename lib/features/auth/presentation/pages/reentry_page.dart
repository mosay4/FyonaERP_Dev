import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/security/app_pin_crypto.dart';
import '../../di/auth_providers.dart' hide authProvider;
import '../../../../shared/providers/theme_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/biometric_provider.dart';
import '../../domain/services/biometric_service.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Re-entry gate shown when the session expired but this device still holds
/// recovery material (fingerprint snapshot / saved credentials).
/// The user NEVER types an email here: fingerprint opens the app directly,
/// otherwise the stored password silently re-logs in.
class ReentryPage extends ConsumerStatefulWidget {
  const ReentryPage({super.key});

  @override
  ConsumerState<ReentryPage> createState() => _ReentryPageState();
}

class _ReentryPageState extends ConsumerState<ReentryPage> {
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscure = true;
  bool _attempting = false;
  bool _autoBioTriggered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryAutoBiometric());
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _tryAutoBiometric() async {
    if (_autoBioTriggered || !mounted) return;
    _autoBioTriggered = true;
    await ref.read(biometricProvider.notifier).ready;
    if (!mounted) return;
    final bioState = ref.read(biometricProvider);
    if (!bioState.isEnabled) return;
    if (!bioState.isDeviceSupported || !bioState.canCheckBiometrics) return;
    _biometricEntry();
  }

  Future<void> _biometricEntry() async {
    if (_attempting || !mounted) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _attempting = true);
    final result = await ref.read(biometricProvider.notifier).authenticate(
      reason: l10n.unlockWithBiometric,
    );
    if (!mounted) return;
    if (result == AuthResult.success) {
      // Fingerprint opens the app directly — no email/password is typed.
      var error = await ref.read(authProvider.notifier).loginWithBiometric();
      if (error != null) {
        // Device biometric already proved identity; open the cached account
        // offline instead of failing just because the server is unreachable.
        error = await ref.read(authProvider.notifier).restoreCachedSession();
      }
      if (!mounted) return;
      setState(() => _attempting = false);
      if (error != null) {
        _snack(error, warn: true);
      }
      // On success the router redirect moves to the dashboard automatically.
    } else {
      setState(() => _attempting = false);
      if (result == AuthResult.lockedOut ||
          result == AuthResult.permanentlyLockedOut) {
        _snack(l10n.biometricLocked, warn: true);
      }
    }
  }

  Future<void> _passwordEntry() async {
    if (_attempting || !_formKey.currentState!.validate()) return;
    final l10n = AppLocalizations.of(context);
    final secret = _passwordController.text.trim();
    // The session-expiry gate accepts the 5-digit app security PIN as a fully
    // offline alternative. It was previously compared to the account
    // password, so a correct PIN always reported "wrong".
    if (RegExp(r'^\d{5}$').hasMatch(secret)) {
      setState(() => _attempting = true);
      var pinOk = false;
      try {
        final record =
            await ref.read(authLocalDataSourceProvider).getAppPin();
        pinOk = verifyAppPinRecord(secret, record);
      } catch (_) {}
      if (pinOk) {
        final err =
            await ref.read(authProvider.notifier).restoreCachedSession();
        if (!mounted) return;
        setState(() => _attempting = false);
        if (err != null) _snack(err, warn: true);
        return;
      }
      setState(() => _attempting = false);
      _snack(l10n.translate('pinWrong'));
      return;
    }
    setState(() => _attempting = true);
    final ok = await ref
        .read(authProvider.notifier)
        .verifySessionPassword(secret);
    if (!mounted) return;
    if (!ok) {
      setState(() => _attempting = false);
      _snack(l10n.wrongPassword);
      return;
    }
    final error = await ref
        .read(authProvider.notifier)
        .reloginWithSavedCredentials();
    if (!mounted) return;
    setState(() => _attempting = false);
    if (error != null) {
      _snack(error, warn: true);
    }
  }

  void _snack(String msg, {bool warn = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: warn ? AppColors.warning : AppColors.danger,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final authState = ref.watch(authProvider);
    final bioState = ref.watch(biometricProvider);
    final isDark = ref.watch(themeModeProvider) == ThemeMode.dark;
    final logoAsset = isDark
        ? 'assets/images/fyona_logo_light.png'
        : 'assets/images/fyona_logo_dark.png';
    final showBio =
        bioState.isDeviceSupported && bioState.canCheckBiometrics;
    final user = authState.user;
    final userLabel = user?.fullName ?? user?.email ?? user?.phone ?? '';

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(26),
                    child: Image.asset(
                      logoAsset,
                      width: 96,
                      height: 96,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Text(
                        'FYONA',
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 32),
                          fontWeight: FontWeight.w900,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    l10n.reentryTitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 22),
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (userLabel.isNotEmpty)
                    Text(
                      userLabel,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 14),
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                      ),
                    ),
                  const SizedBox(height: 6),
                  Text(
                    l10n.reentrySubtitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w500,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 28),
                  if (showBio) ...[
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: _attempting ? null : _biometricEntry,
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
                      l10n.unlockPasswordHint,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 12),
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDisabled,
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  FyonaTextFormField(
                    controller: _passwordController,
                    obscureText: _obscure,
                    textDirection: TextDirection.rtl,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 14),
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary,
                    ),
                    decoration: InputDecoration(
                      hintText: l10n.reentryPasswordHint,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      prefixIcon: Icon(Icons.lock,
                          size: 22, color: AppColors.textSecondary),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure ? Icons.visibility_off : Icons.visibility,
                          size: 20,
                          color: AppColors.textSecondary,
                        ),
                        onPressed: () =>
                            setState(() => _obscure = !_obscure),
                      ),
                    ),
                      validator: (v) =>
                          v == null || v.isEmpty ? l10n.requiredPassword : null,
                      onFieldSubmitted: (_) => _passwordEntry(),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.reentryPasswordHelp,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11),
                        fontWeight: FontWeight.w500,
                        color: AppColors.textSecondary,
                        height: 1.6,
                      ),
                    ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: _attempting ? null : _passwordEntry,
                      child: Text(
                        l10n.unlock,
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 14),
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _attempting
                        ? null
                        : () async {
                            await ref
                                .read(authProvider.notifier)
                                .abandonSession();
                            if (context.mounted) {
                              context.go(RouteNames.login);
                            }
                          },
                    child: Text(
                      l10n.useAnotherAccount,
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
