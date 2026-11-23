import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/config/directory_pilot_build.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/router/route_names.dart';
import '../providers/auth_provider.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import '../widgets/google_logo.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../shared/providers/theme_provider.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key});

  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends ConsumerState<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _generalError;

  @override
  void dispose() {
    _fullNameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _register() {
    setState(() => _generalError = null);
    if (!_formKey.currentState!.validate()) return;
    ref.read(authProvider.notifier).register(
      email: _emailCtrl.text.trim(),
      password: _passwordCtrl.text,
      fullName: _fullNameCtrl.text.trim(),
    );
  }

  void _googleLogin() {
    // Google sign-up never forces a mode: new users are asked on the
    // choose-usage screen, existing users keep their saved mode.
    ref.read(authProvider.notifier).loginWithGoogle();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final isLoading = authState.isLoading;
    final l10n = AppLocalizations.of(context);

    ref.listen<AuthState>(authProvider, (prev, next) {
      if (next.isAuthenticated) GoRouter.of(context).go('/account-entry');
      if (next.status == AuthStatus.verificationPending) {
        GoRouter.of(context).go(RouteNames.verifyEmail);
      }
      if (next.error != null && prev?.error != next.error) {
        setState(() => _generalError = next.error);
      }
    });

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new,
            color: AppColors.textPrimary,
            size: 20,
          ),
          onPressed: () => context.go(RouteNames.login),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Logo (theme-aware, rounded — no sharp frame) ──
                  ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: Image.asset(
                      ref.watch(themeModeProvider) == ThemeMode.dark
                          ? 'assets/images/fyona_logo_light.png'
                          : 'assets/images/fyona_logo_dark.png',
                      width: 100,
                      height: 100,
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
                  SizedBox(height: 20),
Text(
                     l10n.translate('createAccount'),
                     style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 24),
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                   SizedBox(height: 6),
Text(
                     l10n.translate('freeTrial'),
                     style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w500,
                      color: AppColors.textSecondary.withAlpha(200),
                    ),
                  ),
                  SizedBox(height: 28),
                  if (_generalError != null) ...[
                    Container(
                      padding: EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.danger.withAlpha(20),
                        borderRadius: AppRadius.smBorder,
                        border: Border.all(
                          color: AppColors.danger.withAlpha(60),
                          width: 0.5,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: AppColors.danger,
                            size: 18,
                          ),
                           SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _generalError!,
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: R.fontSize(context, 12),
                                fontWeight: FontWeight.w500,
                                color: AppColors.danger,
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: () =>
                                setState(() => _generalError = null),
                            child: const Icon(
                              Icons.close,
                              color: AppColors.danger,
                              size: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  _buildField(
                    label: l10n.translate('fullName'),
                    hint: l10n.translate('fullNameHint'),
                    icon: Icons.person,
                    ctrl: _fullNameCtrl,
                    next: true,
                    requiredError: l10n.translate('passwordRequired'),
                  ),
                  const SizedBox(height: 14),
                  _buildField(
                    label: l10n.translate('email'),
                    hint: l10n.translate('emailRequired'),
                    icon: Icons.email_outlined,
                    ctrl: _emailCtrl,
                    next: true,
                    type: TextInputType.emailAddress,
                    ltr: true,
                    requiredError: l10n.translate('emailRequired'),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return l10n.translate('emailRequired');
                      final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
                      return emailRegex.hasMatch(v.trim()) ? null : l10n.translate('invalidEmail');
                    },
                  ),
                  SizedBox(height: 14),
                  _buildPasswordField(
                    label: l10n.translate('password'),
                    ctrl: _passwordCtrl,
                    obscure: _obscurePassword,
                    toggle: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                    requiredError: l10n.translate('passwordRequired'),
                    minLengthError: l10n.translate('passwordTooShort'),
                  ),
                  const SizedBox(height: 14),
                  _buildPasswordField(
                    label: l10n.translate('confirmPassword'),
                    ctrl: _confirmCtrl,
                    obscure: _obscureConfirm,
                    toggle: () =>
                        setState(() => _obscureConfirm = !_obscureConfirm),
                    requiredError: l10n.translate('passwordRequired'),
                    minLengthError: l10n.translate('passwordTooShort'),
                    validator: (v) {
                      if (v == null || v.isEmpty) return l10n.translate('passwordRequired');
                      if (v != _passwordCtrl.text) return l10n.translate('passwordsMismatch');
                      return null;
                    },
                  ),
                   SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: isLoading ? null : _register,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: AppColors.surfaceVariant,
                        disabledForegroundColor: AppColors.textDisabled,
                        shape: RoundedRectangleBorder(
                          borderRadius: AppRadius.mdBorder,
                        ),
                      ),
child: isLoading
                          ? SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                  l10n.translate('createAccountBtn'),
                                  style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                            ),
                    ),
                  ),
                   SizedBox(height: 20),
Row(
                      children: [
                         Expanded(child: Divider(color: AppColors.border, thickness: 1)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            l10n.translate('orDivider'),
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 12),
                              fontWeight: FontWeight.w600,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                         Expanded(child: Divider(color: AppColors.border, thickness: 1)),
                      ],
                    ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: OutlinedButton.icon(
                      onPressed: isLoading || DirectoryPilotBuild.enabled
                          ? null : _googleLogin,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textPrimary,
                        side: BorderSide(color: AppColors.border, width: 1.2),
                        backgroundColor: AppColors.surface,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const GoogleLogo(size: 20),
                      label: Text(l10n.translate('continueWithGoogle'), style: TextStyle(
                              fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700)),
                    ),
                  ),
                   SizedBox(height: 20),
Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          l10n.translate('alreadyHaveAccount'),
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 13),
                            fontWeight: FontWeight.w500,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        GestureDetector(
                          onTap: () => context.go(RouteNames.login),
                          child: Text(
                            l10n.translate('loginLink'),
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 13),
                              fontWeight: FontWeight.w700,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildField({
    required String label,
    required String hint,
    required IconData icon,
    required TextEditingController ctrl,
    required bool next,
    TextInputType type = TextInputType.text,
    bool isOptional = false,
    bool ltr = false,
    String? Function(String?)? validator,
    required String requiredError,
  }) {
    return FyonaTextFormField(
      controller: ctrl,
      textDirection: ltr ? TextDirection.ltr : TextDirection.rtl,
      keyboardType: type,
      textInputAction: next ? TextInputAction.next : TextInputAction.done,
      style: TextStyle(
        fontFamily: 'Cairo',
        fontSize: R.fontSize(context, 14),
        fontWeight: FontWeight.w500,
        color: AppColors.textPrimary,
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, size: 20, color: AppColors.textSecondary),
        contentPadding: EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      ),
      validator: validator ??
          (isOptional
              ? null
              : (v) {
                  if (v == null || v.trim().isEmpty) return requiredError;
                  return null;
                }),
    );
  }

Widget _buildPasswordField({
    required String label,
    required TextEditingController ctrl,
    required bool obscure,
    required VoidCallback toggle,
    String? Function(String?)? validator,
    required String requiredError,
    required String minLengthError,
  }) {
    return FyonaTextFormField(
      controller: ctrl,
      obscureText: obscure,
      textDirection: TextDirection.rtl,
      textInputAction: TextInputAction.done,
      style: TextStyle(
        fontFamily: 'Cairo',
        fontSize: R.fontSize(context, 14),
        fontWeight: FontWeight.w500,
        color: AppColors.textPrimary,
      ),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon:  Icon(
          Icons.lock,
          size: 20,
          color: AppColors.textSecondary,
        ),
        suffixIcon: IconButton(
          icon: Icon(
            obscure ? Icons.visibility_off : Icons.visibility,
            size: 20,
            color: AppColors.textSecondary,
          ),
          onPressed: toggle,
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      ),
      validator: validator ??
          (v) {
            if (v == null || v.isEmpty) return requiredError;
            if (v.length < 8) return minLengthError;
            return null;
          },
    );
  }
}
