import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import '../../../../core/theme/app_theme.dart';
import '../../../../core/config/directory_pilot_build.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/network/server_discovery.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/services/connectivity_service.dart';
import '../../../../shared/widgets/connectivity_widgets.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../shared/providers/locale_provider.dart';
import '../../../../shared/widgets/language_transition_overlay.dart';
import '../../di/auth_providers.dart' show authLocalDataSourceProvider;
import '../providers/auth_provider.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../../../../core/responsive/r_api.dart';
import '../widgets/google_logo.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSavedEmail());
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _maybeAutoDiscoverServer());
  }

  /// Zero-config LAN: if the user never typed a server address manually and
  /// the current base is unreachable, browse mDNS for the backend and adopt
  /// it (persisted like a manual choice). Best-effort, never blocks UI.
  Future<void> _maybeAutoDiscoverServer() async {
    if (DirectoryPilotBuild.enabled) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getString('server_base_url') ?? '').isNotEmpty) return;
      final current = ref.read(serverBaseUrlProvider);
      final root = current.replaceAll(RegExp(r'/api/v1/?$'), '');
      try {
        final probe = Dio(
          BaseOptions(
              connectTimeout: const Duration(seconds: 2),
              receiveTimeout: const Duration(seconds: 2)),
        );
        final resp = await probe.get('$root/version');
        if (resp.statusCode == 200) return;
      } catch (_) {}
      final found = await ServerDiscovery.discover();
      if (found == null || !mounted) return;
      await persistServerBaseUrl(ref, found);
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_l10n.translate('serverAddressFound'),
            style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: AppColors.success,
      ));
    } catch (_) {}
  }

  AppLocalizations get _l10n => AppLocalizations.of(context);

  Future<void> _loadSavedEmail() async {
    final saved = await ref.read(authLocalDataSourceProvider).getSavedUsername();
    if (!mounted) return;
    if (saved != null && saved.isNotEmpty && _emailController.text.isEmpty) {
      _emailController.text = saved;
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _login() {
    if (!_formKey.currentState!.validate()) return;
    ref.read(authProvider.notifier).login(
      email: _emailController.text.trim(),
      password: _passwordController.text,
    );
  }

  void _googleLogin() async {
    // Google sign-in needs the network (OAuth + profile fetch).
    final connectivity = ref.read(connectivityServiceProvider);
    if (!connectivity.isOnline) {
      final retryOk = await showOfflineDialog(context, connectivity: connectivity);
      if (!retryOk) return;
    }
    // Google sign-in never forces a mode: new users are asked on the
    // choose-usage screen, existing users keep their saved mode.
    ref.read(authProvider.notifier).loginWithGoogle();
  }

  void _createAccount() async {
    // Creating an account needs the network (OTP + server write).
    final connectivity = ref.read(connectivityServiceProvider);
    if (!connectivity.isOnline) {
      final retryOk = await showOfflineDialog(context, connectivity: connectivity);
      if (!retryOk) return;
    }
    context.go(RouteNames.register);
  }

  /// Server address editor: normalize → probe `/version` → persist + switch.
  /// Only switches on a successful probe so a typo can never brick login.
  Future<void> _showServerDialog() async {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController(
        text: Uri.tryParse(ref.read(serverBaseUrlProvider))?.host ?? '');
    var testing = false;
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(l10n.translate('serverAddressTitle'),
              style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
          content: FyonaTextField(
            controller: ctrl,
            keyboardType: TextInputType.url,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(
              hintText: l10n.translate('serverAddressHint'),
              prefixIcon: const Icon(Icons.dns_outlined),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.translate('cancel'),
                  style: const TextStyle(fontFamily: 'Cairo')),
            ),
            FilledButton(
              onPressed: testing
                  ? null
                  : () async {
                      final raw = ctrl.text.trim();
                      if (raw.isEmpty) {
                        Navigator.pop(ctx);
                        return;
                      }
                      setDState(() => testing = true);
                       try {
                         final normalized = normalizeServerBaseUrl(raw);
                         if (DirectoryPilotBuild.enabled &&
                             normalized != DirectoryPilotBuild.baseUrl) {
                           throw const FormatException();
                         }
                        final root = normalized.replaceAll(
                            RegExp(r'/api/v1/?$'), '');
                        final probe = Dio(BaseOptions(
                          connectTimeout: const Duration(seconds: 5),
                          receiveTimeout: const Duration(seconds: 5),
                        ));
                        final resp = await probe.get('$root/version');
                        if (resp.statusCode == 200) {
                          Navigator.pop(ctx, normalized);
                          return;
                        }
                      } catch (_) {}
                      if (ctx.mounted) setDState(() => testing = false);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(
                              l10n.translate('serverAddressFail'),
                              style: const TextStyle(fontFamily: 'Cairo')),
                          backgroundColor: AppColors.danger,
                        ));
                      }
                    },
              child: testing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(l10n.translate('save'),
                      style: const TextStyle(fontFamily: 'Cairo')),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (saved != null && saved.isNotEmpty && mounted) {
      await persistServerBaseUrl(ref, saved);
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(l10n.translate('serverAddressSaved'),
            style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: AppColors.success,
      ));
    }
  }

  Widget _logoFallback(BuildContext context) {
    return Image.asset(
      'assets/images/logo.png',
      width: 100,
      height: 100,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => Text(
        'FYONA',
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: R.fontSize(context, 32),
          fontWeight: FontWeight.w900,
          color: AppColors.primary,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final error = authState.error;
    final isLoading = authState.isLoading;

    ref.listen<AuthState>(authProvider, (prev, next) {
      if (next.status == AuthStatus.verificationPending) {
        context.go(RouteNames.verifyEmail);
        return;
      }
      if (next.forceUsageChoice) {
        context.go(RouteNames.chooseUsage);
        return;
      }
      if (next.isAuthenticated && !(prev?.isAuthenticated ?? false)) {
        final loginEmail = _emailController.text.trim();
        if (loginEmail.isNotEmpty) {
          ref.read(authLocalDataSourceProvider).saveUsername(loginEmail);
        }
        context.go('/account-entry');
      }
    });

    final l10n = AppLocalizations.of(context);
    // The login page is ALWAYS dark (see AuthForcedDark): the app root swaps
    // the effective theme + palette for this route, and the page also pins a
    // local dark Theme and light status-bar icons. The saved preference is
    // never changed.
    const logoAsset = 'assets/images/fyona_logo_light.png';

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Theme(
      data: AppTheme.darkTheme,
      child: Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                      // Hidden fallback: long-press the logo opens the server
                      // address editor (auto-discovery handles LAN silently).
                      GestureDetector(
                        onLongPress: _showServerDialog,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(28),
                          child: Image.asset(
                            logoAsset,
                            width: 120,
                            height: 120,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                _logoFallback(context),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        l10n.welcomeBack,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 24),
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        l10n.loginSubtitle,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 14),
                          fontWeight: FontWeight.w500,
                          color: AppColors.textSecondary.withAlpha(200),
                        ),
                      ),
                      const SizedBox(height: 28),
                      FyonaTextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        textDirection: TextDirection.ltr,
                        textAlign: TextAlign.left,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 14),
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                        decoration: InputDecoration(
                          hintText: l10n.email,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          prefixIcon:  Icon(Icons.email_outlined, size: 22, color: AppColors.textSecondary),
                        ),
                        validator: (v) {
                          final value = v?.trim() ?? '';
                          if (value.isEmpty) return l10n.invalidEmail;
                          final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
                          return emailRegex.hasMatch(value) ? null : l10n.invalidEmail;
                        },
                      ),
                      const SizedBox(height: 14),
                      FyonaTextFormField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        textDirection: TextDirection.rtl,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 14),
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                        decoration: InputDecoration(
                          hintText: l10n.password,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          prefixIcon:  Icon(Icons.lock, size: 22, color: AppColors.textSecondary),
                          suffixIcon: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(
                                  _obscurePassword ? Icons.visibility_off : Icons.visibility,
                                  size: 20, color: AppColors.textSecondary,
                                ),
                                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                              ),
                            ],
                          ),
                        ),
                        validator: (v) => v == null || v.isEmpty ? l10n.requiredPassword : null,
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: AppColors.danger.withAlpha(20),
                            borderRadius: AppRadius.smBorder,
                            border: Border.all(color: AppColors.danger.withAlpha(60), width: 0.5),
                          ),
                          child: Row(
                            children: [
                              TwoToneIcon(data: TwoToneIcons.warning, size: 16, outlineColor: AppColors.danger),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(error, style: TextStyle(
                                  fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.w500, color: AppColors.danger)),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          onPressed: isLoading ? null : _login,
                          child: isLoading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: DotsLoader.button(),
                                  ),
                                )
                              : Text(l10n.loginButton, style: TextStyle(
                                  fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700)),
                        ),
                      ),
                      const SizedBox(height: 14),
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
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          icon: const GoogleLogo(size: 20),
                          label: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(l10n.translate('continueWithGoogle'), style: TextStyle(
                                fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: OutlinedButton(
                          onPressed: () => _createAccount(),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.primary,
                            side: BorderSide(color: AppColors.primary, width: 1.5),
                          ),
                          child: Text(l10n.createAccount, style: TextStyle(
                              fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700)),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: () => context.go(RouteNames.forgotPassword),
                        child: Text(
                          l10n.forgotPasswordLink,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 13),
                            fontWeight: FontWeight.w600,
                            color: AppColors.textSecondary,
                            decoration: TextDecoration.underline,
                            decorationColor: AppColors.textDisabled,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
              ),
            ),
          Positioned(
            top: 8,
            left: 16,
            child: _LanguageToggleButton(),
          ),
        ],
      ),
    ),
    ),
    ),
    );
  }
}

class _LanguageToggleButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeProvider);
    final isArabic = locale.languageCode == 'ar';
    return Material(
      color: AppColors.surface,
      borderRadius: AppRadius.smBorder,
      child: InkWell(
        onTap: () {
          final current = ref.read(localeProvider);
          final target = current.languageCode == 'ar'
              ? const Locale('en')
              : const Locale('ar');
          requestLanguageChange(ref, target);
        },
        borderRadius: AppRadius.smBorder,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.language,
                size: R.icon(context, 16),
                color: AppColors.primary,
              ),
              const SizedBox(width: 6),
              Text(
                isArabic ? 'English' : AppLocalizations.of(context).translate('arabic'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 12),
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
