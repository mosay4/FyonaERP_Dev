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
import '../../../../core/responsive/r_api.dart';
import '../widgets/google_logo.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';
import '../../auth2/auth2_navigation.dart';
import '../../auth2/auth2_strings.dart';
import '../../auth2/social_sign_in.dart';
import '../../auth2/widgets/auth2_widgets.dart';
import '../../auth2/widgets/phone_field.dart';

/// Phone-first sign-in (docs/AUTH_PLAN.md). Always dark (AuthForcedDark).
/// Phone + password; «Continue with Google» on Android only, «Continue with
/// Apple» on iOS only. A new device continues to «Verify this device».
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _phone = PhoneFieldController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _socialBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSavedPhone());
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

  Future<void> _loadSavedPhone() async {
    try {
      final saved =
          await ref.read(authLocalDataSourceProvider).getSavedUsername();
      if (!mounted) return;
      if (saved != null && saved.startsWith('+') && _phone.text.text.isEmpty) {
        _phone.setE164(saved);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _phone.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<bool> _ensureOnline() async {
    final connectivity = ref.read(connectivityServiceProvider);
    if (connectivity.isOnline) return true;
    return showOfflineDialog(context, connectivity: connectivity);
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    final phone = _phone.e164;
    final password = _passwordController.text;
    final result = await ref
        .read(authProvider.notifier)
        .login(phone: phone, password: password);
    if (!mounted || result == null) return;
    try {
      await ref.read(authLocalDataSourceProvider).saveUsername(phone);
    } catch (_) {}
    if (!mounted) return;
    continueAfterLogin(context, ref, result,
        phoneE164: phone, password: password);
  }

  Future<void> _social({required bool apple}) async {
    if (!await _ensureOnline() || !mounted) return;
    setState(() => _socialBusy = true);
    final notifier = ref.read(authProvider.notifier);
    try {
      final social = ref.read(socialSignInProvider);
      final cred = apple ? await social.apple() : await social.google();
      final result = await notifier.loginWithSocial(
        provider: cred.provider,
        idToken: cred.idToken,
        authorizationCode: cred.authorizationCode,
        rawNonce: cred.rawNonce,
        fullName: cred.fullName,
      );
      if (!mounted || result == null) return;
      continueAfterLogin(context, ref, result, socialProvider: cred.provider);
    } on SocialSignInCancelled {
      // The user closed the sheet: nothing to report.
    } catch (_) {
      if (mounted) notifier.setError(a2(context, 'socialFailed'));
    } finally {
      if (mounted) setState(() => _socialBusy = false);
    }
  }

  Future<void> _createAccount() async {
    // Creating an account needs the network (OTP + server write).
    if (!await _ensureOnline() || !mounted) return;
    ref.read(authProvider.notifier).clearError();
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

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final error = authState.error;
    final isLoading = authState.isLoading || _socialBusy;

    ref.listen<AuthState>(authProvider, (prev, next) {
      if (next.isAuthenticated && !(prev?.isAuthenticated ?? false)) {
        context.go('/account-entry');
      }
    });

    final showGoogle = googleSignInAvailable;
    final showApple = appleSignInAvailable;

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
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: AutofillGroup(
                        child: Form(
                          key: _formKey,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SizedBox(height: 24),
                              // Hidden fallback: long-press the logo opens the
                              // server address editor.
                              Center(
                                child: GestureDetector(
                                  onLongPress: _showServerDialog,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(28),
                                    child: Image.asset(
                                      logoAsset,
                                      width: 110,
                                      height: 110,
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
                                ),
                              ),
                              const SizedBox(height: 22),
                              Auth2Title(
                                a2(context, 'welcome'),
                                subtitle: a2(context, 'loginSubtitle'),
                              ),
                              PhoneField(controller: _phone),
                              const SizedBox(height: 14),
                              Auth2PasswordField(
                                fieldKey: const Key('password_input'),
                                controller: _passwordController,
                                hint: a2(context, 'password'),
                                textInputAction: TextInputAction.done,
                                onSubmitted: isLoading ? null : _login,
                                validator: (v) => v == null || v.isEmpty
                                    ? a2(context, 'errPassword')
                                    : null,
                              ),
                              Align(
                                alignment: AlignmentDirectional.centerEnd,
                                child: TextButton(
                                  key: const Key('forgot_button'),
                                  onPressed: () {
                                    ref.read(authProvider.notifier).clearError();
                                    context.go(RouteNames.forgotPassword);
                                  },
                                  child: Text(
                                    a2(context, 'forgot'),
                                    style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: R.fontSize(context, 12.5),
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                ),
                              ),
                              if (error != null) Auth2ErrorBox(error),
                              const SizedBox(height: 14),
                              Auth2PrimaryButton(
                                key: const Key('login_button'),
                                label: a2(context, 'login'),
                                loading: authState.isLoading,
                                onPressed: isLoading ? null : _login,
                              ),
                              if (showGoogle || showApple) ...[
                                const SizedBox(height: 14),
                                Row(
                                  children: [
                                    Expanded(child: Divider(color: AppColors.border, thickness: 1)),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                      child: Text(
                                        a2(context, 'or'),
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
                              ],
                              if (showGoogle)
                                SizedBox(
                                  height: 50,
                                  child: OutlinedButton.icon(
                                    key: const Key('google_button'),
                                    onPressed: isLoading ? null : () => _social(apple: false),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: AppColors.textPrimary,
                                      side: BorderSide(color: AppColors.border, width: 1.2),
                                      backgroundColor: AppColors.surface,
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12)),
                                    ),
                                    icon: const GoogleLogo(size: 20),
                                    label: Text(
                                      a2(context, 'google'),
                                      style: TextStyle(
                                        fontFamily: 'Cairo',
                                        fontSize: R.fontSize(context, 14),
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              if (showApple)
                                SizedBox(
                                  height: 50,
                                  child: ElevatedButton.icon(
                                    key: const Key('apple_button'),
                                    onPressed: isLoading ? null : () => _social(apple: true),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.white,
                                      foregroundColor: Colors.black,
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12)),
                                    ),
                                    icon: const Icon(Icons.apple, size: 22),
                                    label: Text(
                                      a2(context, 'apple'),
                                      style: TextStyle(
                                        fontFamily: 'Cairo',
                                        fontSize: R.fontSize(context, 14),
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 14),
                              SizedBox(
                                height: 50,
                                child: OutlinedButton(
                                  key: const Key('register_button'),
                                  onPressed: isLoading ? null : _createAccount,
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: AppColors.primary,
                                    side: const BorderSide(color: AppColors.primary, width: 1.5),
                                  ),
                                  child: Text(
                                    a2(context, 'createAccount'),
                                    style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: R.fontSize(context, 14),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 24),
                            ],
                          ),
                        ),
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
