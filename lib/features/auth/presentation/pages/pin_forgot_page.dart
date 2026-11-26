import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/security/app_pin_crypto.dart';
import '../../../../core/theme/app_colors.dart';
import '../../di/auth_providers.dart' hide authProvider;
import '../providers/auth_provider.dart';
import '../../auth2/auth2_models.dart';
import '../../auth2/auth2_service.dart';
import '../widgets/app_pin_pad.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Forgot-PIN flow: account password (server-confirmed from this trusted
/// device, no message sent) → new 5-digit PIN (create+confirm).
///
/// Uses the `pin` purpose of the email-code channel: it only proves the
/// address is yours and never touches the account password, so accounts
/// signed in with Google (no password) work too. Pops `true` when a new PIN
/// was saved.
class PinForgotPage extends ConsumerStatefulWidget {
  const PinForgotPage({super.key});

  @override
  ConsumerState<PinForgotPage> createState() => _PinForgotPageState();
}

class _PinForgotPageState extends ConsumerState<PinForgotPage> {
  int _step = 0;
  bool _sending = false;
  bool _verifying = false;
  int _pinSubStep = 0;
  String _first = '';
  final _emailCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _padKey = GlobalKey<AppPinPadState>();

  @override
  void initState() {
    super.initState();
    _emailCtrl.text = '';
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  void _snack(String message, {Color? bg}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: bg ?? AppColors.danger,
      ),
    );
  }

  Future<void> _sendCode() async {
    final l10n = AppLocalizations.of(context);
    final password = _emailCtrl.text;
    if (password.isEmpty) {
      _snack(l10n.translate('pinPasswordLabel'));
      return;
    }
    setState(() => _sending = true);
    // Ownership check for the APP LOCK only: the account password, confirmed
    // by the server from this trusted device. No message is sent (free).
    String? err;
    try {
      await ref.read(auth2ServiceProvider).reauth(password);
    } on Auth2Exception catch (e) {
      err = e.code == 'password_not_set'
          ? l10n.translate('pinPasswordNotSet')
          : e.isNetwork
              ? l10n.translate('noInternet')
              : l10n.translate('pinPasswordWrong');
    } catch (_) {
      err = l10n.translate('pinPasswordWrong');
    }
    if (!mounted) return;
    setState(() => _sending = false);
    if (err != null) {
      _snack(err);
      return;
    }
    setState(() {
      _step = 2;
      _pinSubStep = 0;
      _first = '';
    });
  }

  Future<void> _verifyCode() async {
    final code = _codeCtrl.text.trim();
    if (code.isEmpty) {
      _snack(AppLocalizations.of(context).translate('pinCodeEmpty'));
      return;
    }
    setState(() => _verifying = true);
    final err = await ref.read(authProvider.notifier).verifyResetOtp(
          email: _emailCtrl.text.trim(),
          otp: code,
          purpose: 'pin',
        );
    if (!mounted) return;
    setState(() => _verifying = false);
    if (err != null) {
      _snack(err);
      return;
    }
    setState(() {
      _step = 2;
      _pinSubStep = 0;
      _first = '';
    });
  }

  void _onNewPinCompleted(String pin) {
    if (_pinSubStep == 0) {
      setState(() => _pinSubStep = 1);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _padKey.currentState?.clear();
      });
      return;
    }
    if (pin == _first && _first.isNotEmpty) {
      _save(pin);
      return;
    }
    _snack(AppLocalizations.of(context).translate('pinMismatch'));
    setState(() {
      _pinSubStep = 0;
      _first = '';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _padKey.currentState?.clear();
    });
  }

  Future<void> _save(String pin) async {
    try {
      final ds = ref.read(authLocalDataSourceProvider);
      await ds.saveAppPin(packAppPin(pin));
    } catch (_) {}
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          color: AppColors.textPrimary,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        title: Text(l10n.translate('pinForgotTitle'),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: _step == 0
              ? _buildEmail(l10n)
              : _step == 1
                  ? _buildCode(l10n)
                  : _buildNewPin(l10n),
        ),
      ),
    );
  }

  Widget _fieldLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 13),
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary)),
      );

  InputDecoration _decoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
            fontFamily: 'Cairo', color: AppColors.textPlaceholder),
        filled: true,
        fillColor: AppColors.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.border),
        ),
      );

  Widget _primaryButton(String label, VoidCallback? onTap,
      {bool busy = false}) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: busy ? null : onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 0,
        ),
        child: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: Colors.white))
            : Text(label,
                style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: Colors.white)),
      ),
    );
  }

  Widget _buildEmail(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.translate('pinPasswordBody'),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 14),
                color: AppColors.textSecondary,
                height: 1.7)),
        const SizedBox(height: 20),
        _fieldLabel(l10n.translate('pinPasswordLabel')),
        FyonaTextField(
          controller: _emailCtrl,
          obscureText: true,
          keyboardType: TextInputType.visiblePassword,
          style: TextStyle(
              fontFamily: 'Cairo', color: AppColors.textPrimary),
          decoration: _decoration(l10n.translate('pinPasswordLabel')),
        ),
        const SizedBox(height: 20),
        _primaryButton(
          l10n.translate('pinPasswordContinue'),
          _sending ? null : _sendCode,
          busy: _sending,
        ),
      ],
    );
  }

  Widget _buildCode(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.translate('pinCodeBody'),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 14),
                color: AppColors.textSecondary,
                height: 1.7)),
        const SizedBox(height: 20),
        _fieldLabel(l10n.translate('pinCodeLabel')),
        FyonaTextField(
          controller: _codeCtrl,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(8),
          ],
          textAlign: TextAlign.center,
          style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 20,
              letterSpacing: 4,
              color: AppColors.textPrimary),
          decoration: _decoration(l10n.translate('pinCodeHint')),
        ),
        const SizedBox(height: 20),
        _primaryButton(
          l10n.translate('pinVerifyCode'),
          _verifying ? null : _verifyCode,
          busy: _verifying,
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: _sending ? null : _sendCode,
          child: Text(l10n.translate('pinResendCode'),
              style: TextStyle(
                  fontFamily: 'Cairo', color: AppColors.primary)),
        ),
      ],
    );
  }

  Widget _buildNewPin(AppLocalizations l10n) {
    return Column(
      children: [
        const SizedBox(height: 12),
        Text(
          _pinSubStep == 0
              ? l10n.translate('pinCreateTitle')
              : l10n.translate('pinConfirmTitle'),
          textAlign: TextAlign.center,
          style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 18),
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary),
        ),
        const SizedBox(height: 24),
        AppPinPad(
          key: _padKey,
          onCompleted: (pin) {
            if (_pinSubStep == 0) {
              _first = pin;
              _onNewPinCompleted(pin);
            } else {
              _onNewPinCompleted(pin);
            }
          },
        ),
      ],
    );
  }
}
