import 'dart:async';

import 'package:flutter/material.dart';
import '../../../../core/config/directory_pilot_build.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/responsive/breakpoints.dart';
import '../../../../core/router/route_names.dart';
import '../providers/auth_provider.dart';
import '../widgets/auth_text_field.dart';
import '../widgets/google_logo.dart';
import '../widgets/password_field.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../core/localization/app_localizations.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class ForgotPasswordPage extends ConsumerStatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  ConsumerState<ForgotPasswordPage> createState() =>
      _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends ConsumerState<ForgotPasswordPage> {
  static const _stepEmail = 0;
  static const _stepOtp = 1;
  static const _stepPassword = 2;

  int _step = _stepEmail;
  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _error;
  bool _submitting = false;
  bool _resending = false;

  /// True when the typed email belongs to a Google-registered account (no
  /// password): the page then offers direct Google sign-in instead of OTP.
  bool _isGoogleAccount = false;
  bool _googleLoading = false;

  /// Remaining seconds before a new code may be requested (mirrors the
  /// server-side 60s OTP cooldown). While > 0 the resend button is disabled
  /// and shows the live countdown.
  Timer? _resendTimer;
  int _resendSeconds = 0;

  AppLocalizations get l10n => AppLocalizations.of(context);

  @override
  void dispose() {
    _resendTimer?.cancel();
    _emailController.dispose();
    _otpController.dispose();
    _newPasswordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _setError(String? message) => setState(() => _error = message);

  /// Starts (or restarts) the 60s resend gate with a visible countdown.
  void _startResendCooldown([int seconds = 60]) {
    _resendTimer?.cancel();
    setState(() => _resendSeconds = seconds);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_resendSeconds <= 1) {
        t.cancel();
        setState(() => _resendSeconds = 0);
      } else {
        setState(() => _resendSeconds--);
      }
    });
  }

  Future<void> _onSubmitEmail() async {
    if (_submitting) return;
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      _setError(l10n.translate('emailRequired'));
      return;
    }
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    if (!emailRegex.hasMatch(email)) {
      _setError(l10n.translate('invalidEmail'));
      return;
    }

    setState(() {
      _error = null;
      _isGoogleAccount = false;
      _submitting = true;
    });
    final result = await ref.read(authProvider.notifier).forgotPassword(email);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      if (result != null) {
        _error = result;
        // Brand name survives localization in both languages.
        _isGoogleAccount = result.contains('Google');
      } else {
        _step = _stepOtp;
        // First code sent → arm the 60s resend gate immediately.
        _startResendCooldown();
      }
    });
  }

  Future<void> _onSubmitOtp() async {
    if (_submitting) return;
    final otp = _otpController.text.trim();
    if (otp.isEmpty) {
      _setError(l10n.translate('otpEmpty'));
      return;
    }

    setState(() {
      _error = null;
      _submitting = true;
    });
    final result = await ref
        .read(authProvider.notifier)
        .verifyResetOtp(email: _emailController.text.trim(), otp: otp);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      if (result != null) {
        _error = result;
      } else {
        _step = _stepPassword;
      }
    });
  }

  Future<void> _onSubmitPassword() async {
    if (_submitting) return;
    setState(() {
      _error = null;
      _submitting = true;
    });
    final result = await ref.read(authProvider.notifier).resetPassword(
          newPassword: _newPasswordController.text,
          confirmNewPassword: _confirmController.text,
        );
    if (!mounted) return;
    setState(() {
      _submitting = false;
      if (result != null) {
        _error = result;
      } else {
        context.go(RouteNames.login);
      }
    });
  }

  void _resendOtp() async {
    if (_submitting || _resending || _resendSeconds > 0) return;    setState(() {
      _error = null;
      _resending = true;
    });
    final result =
        await ref.read(authProvider.notifier).forgotPassword(_emailController.text.trim());
    if (!mounted) return;
    setState(() => _resending = false);
    if (result != null) {
      setState(() => _error = result);
      return;
    }
    // Success feedback + re-arm the 60s gate.
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        l10n.translate('otpResentOk'),
        style: const TextStyle(fontFamily: 'Cairo'),
      ),
      backgroundColor: AppColors.success,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ));
    _startResendCooldown();
  }

  /// Direct Google sign-in for Google-registered accounts (no password).
  /// Success navigates automatically via the router auth guard.
  Future<void> _googleSignIn() async {
    if (_googleLoading) return;
    setState(() {
      _googleLoading = true;
      _error = null;
    });
    await ref.read(authProvider.notifier).loginWithGoogle();
    if (!mounted) return;
    setState(() => _googleLoading = false);
    final authState = ref.read(authProvider);
    if (authState.status != AuthStatus.authenticated) {
      setState(() {
        _error = authState.error ??
            AppLocalizations.of(context).translate('fbErrAuth');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isPhone = Breakpoints.isPhone(width);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          _step == _stepEmail
              ? l10n.translate('forgotPasswordTitle')
              : _step == _stepOtp
                  ? l10n.translate('otpTitle')
                  : l10n.translate('newPasswordTitle'),
        ),
        leading: IconButton(
          icon: TwoToneIcon(data: TwoToneIcons.arrowRight),
          onPressed: () {
            if (_step > _stepEmail) {
              setState(() {
                _step -= 1;
                _error = null;
              });
            } else {
              context.go(RouteNames.login);
            }
          },
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: isPhone ? 24 : 40,
              vertical: 24,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(15),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    _step == _stepEmail
                        ? Icons.lock
                        : _step == _stepOtp
                            ? Icons.verified_user_outlined
                            : Icons.password,
                    size: 34,
                    color: AppColors.primary,
                  ),
                ),
                SizedBox(height: 24),
                  Text(
                    _step == _stepEmail
                        ? l10n.translate('forgotPasswordTitle')
                        : _step == _stepOtp
                            ? l10n.translate('otpTitle')
                            : l10n.translate('newPasswordTitle'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: isPhone ? 22 : 26,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    _step == _stepEmail
                        ? l10n.translate('forgotPasswordSubtitle')
                        : _step == _stepOtp
                            ? '${l10n.translate('otpSubtitle')} ${_emailController.text.trim()}'
                            : l10n.translate('newPasswordSubtitle'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 14),
                      color: AppColors.textSecondary,
                    ),
                  ),
                  SizedBox(height: isPhone ? AppSpacing.xl : AppSpacing.xxl),

                  if (_error != null) ...[
                    Container(
                      padding: EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.danger.withAlpha(25),
                        borderRadius: AppRadius.mdBorder,
                        border: Border.all(
                            color: AppColors.danger.withAlpha(80)),
                      ),
                      child: Row(
                        children: [
                          TwoToneIcon(data: TwoToneIcons.share, size: 20, outlineColor: AppColors.textSecondary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(_error!,
                                style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: R.fontSize(context, 13),
                                    color: AppColors.danger)),
                          ),
                          GestureDetector(
                            onTap: () => _setError(null),
                            child: TwoToneIcon(data: TwoToneIcons.close, size: 16, outlineColor: AppColors.danger),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 16),
                  ],

                  // Google-registered account: offer direct sign-in (no OTP,
                  // no password) right under the explanatory message.
                  if (_isGoogleAccount && _step == _stepEmail) ...[
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: OutlinedButton.icon(
                         onPressed: _googleLoading || DirectoryPilotBuild.enabled
                             ? null : _googleSignIn,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.textPrimary,
                          side: BorderSide(color: AppColors.border, width: 1.2),
                          backgroundColor: AppColors.surface,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        icon: _googleLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const GoogleLogo(size: 20),
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                              l10n.translate('continueWithGoogle'),
                              style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: R.fontSize(context, 14),
                                  fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ),
                    SizedBox(height: 12),
                  ],

                  if (_step == _stepEmail) ...[
                    AuthTextField(
                      label: l10n.translate('email'),
                      hintText: 'example@email.com',
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.done,
                      prefixIcon: TwoToneIcon(data: TwoToneIcons.share, size: 20, outlineColor: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      height: 52,
                      child: ElevatedButton(
                        onPressed: _submitting ? null : _onSubmitEmail,
                        child: _submitting
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.5, color: Colors.white),
                              )
                            : Text(l10n.translate('sendOtpBtn'),
                                style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: R.fontSize(context, 16),
                                    height: 1.2,
                                    fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ] else if (_step == _stepOtp) ...[
                    FyonaTextField(
                      controller: _otpController,
                      textAlign: TextAlign.center,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(8),
                      ],
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 20),
                        fontWeight: FontWeight.w700,
                        letterSpacing: 8,
                        color: AppColors.textPrimary,
                      ),
                      decoration: InputDecoration(
                        hintText: l10n.translate('otpHint'),
                        hintStyle: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 20),
                          fontWeight: FontWeight.w700,
                          letterSpacing: 8,
                          color: AppColors.textDisabled,
                        ),
                        filled: true,
                        fillColor: AppColors.surfaceVariant,
                        border: OutlineInputBorder(
                          borderRadius: AppRadius.inputBorder,
                          borderSide:
                               BorderSide(color: AppColors.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: AppRadius.inputBorder,
                          borderSide:
                               BorderSide(color: AppColors.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: AppRadius.inputBorder,
                          borderSide: const BorderSide(
                              color: AppColors.primary, width: 1.5),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                      ),
                      onSubmitted: (_) => _onSubmitOtp(),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      height: 52,
                      child: ElevatedButton(
                        onPressed: _submitting ? null : _onSubmitOtp,
                        child: _submitting
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.5, color: Colors.white),
                              )
                            : Text(l10n.translate('verifyOtpBtn'),
                                style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: R.fontSize(context, 16),
                                    height: 1.2,
                                    fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: (_submitting || _resending || _resendSeconds > 0)
                          ? null
                          : _resendOtp,
                      child: Text(
                        _resendSeconds > 0
                            ? l10n.translate('resendOtpIn',
                                params: {'seconds': '$_resendSeconds'})
                            : (_resending
                                ? l10n.translate('resendingBtn')
                                : l10n.translate('resendOtpBtn')),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 13),
                          fontWeight: FontWeight.w600,
                          color: (_submitting || _resending || _resendSeconds > 0)
                              ? AppColors.textDisabled
                              : AppColors.primary,
                        ),
                      ),
                    ),
                  ] else ...[
                    PasswordField(
                      label: l10n.translate('newPasswordLabel'),
                      controller: _newPasswordController,
                      showStrengthIndicator: true,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 14),
                    PasswordField(
                      label: l10n.translate('confirmNewPasswordLabel'),
                      controller: _confirmController,
                      textInputAction: TextInputAction.done,
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      height: 52,
                      child: ElevatedButton(
                        onPressed: _submitting ? null : _onSubmitPassword,
                        child: _submitting
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.5, color: Colors.white),
                              )
                            : Text(l10n.translate('savePasswordBtn'),
                                style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: R.fontSize(context, 16),
                                    height: 1.2,
                                    fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
