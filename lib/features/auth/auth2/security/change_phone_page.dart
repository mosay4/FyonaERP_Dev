import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../shared/models/user_model.dart';
import '../../presentation/providers/auth_provider.dart';
import '../auth2_api.dart';
import '../auth2_models.dart';
import '../auth2_service.dart';
import '../auth2_strings.dart';
import '../widgets/auth2_widgets.dart';
import '../widgets/otp_view.dart';
import '../widgets/phone_field.dart';

/// Settings → change phone: re-auth (password + this device's key proof) →
/// new number (must be free) → OTP to the NEW number (WhatsApp first, SMS
/// fallback when the server allows) → swapped only after success.
class ChangePhonePage extends ConsumerStatefulWidget {
  const ChangePhonePage({super.key});

  @override
  ConsumerState<ChangePhonePage> createState() => _ChangePhonePageState();
}

class _ChangePhonePageState extends ConsumerState<ChangePhonePage> {
  int _step = 0; // 0 password · 1 new number · 2 code · 3 done
  final _passwordKey = GlobalKey<FormState>();
  final _phoneKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _phone = PhoneFieldController();
  OtpChallenge? _challenge;
  bool _busy = false;
  String? _error;
  String? _idemPhone;
  String _idemKey = Auth2Service.newIdempotencyKey();

  @override
  void dispose() {
    _password.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_busy || !_phoneKey.currentState!.validate()) return;
    final phone = _phone.e164;
    if (_idemPhone != phone) {
      _idemPhone = phone;
      _idemKey = Auth2Service.newIdempotencyKey();
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final c = await ref.read(auth2ServiceProvider).phoneChangeStart(
            newPhoneE164: phone,
            password: _password.text,
            idempotencyKey: _idemKey,
          );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _challenge = c;
        _step = 2;
      });
    } on Auth2Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = auth2ErrorTextOf(context, e);
        // Wrong password → back to the re-auth step.
        if (e.code == 'invalid_credentials' || e.code == 'invalid_password') {
          _step = 0;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = auth2ErrorTextOf(context, e);
      });
    }
  }

  Future<void> _verify(String code) async {
    final c = _challenge!;
    final userJson = await ref
        .read(auth2ApiProvider)
        .phoneChangeVerify(challengeId: c.challengeId, code: code);
    final newPhone = _phone.e164;
    ref.read(authProvider.notifier).applyUserUpdate((u) {
      if (userJson['id'] != null) {
        try {
          final fresh = UserModel.fromJson(userJson);
          return fresh.copyWith(preferredUsageMode: u.preferredUsageMode);
        } catch (_) {}
      }
      return u.copyWith(phone: newPhone, phoneMasked: newPhone, phoneComplete: true);
    });
    if (!mounted) return;
    setState(() => _step = 3);
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider).user;
    final current = (user?.phone?.isNotEmpty ?? false) ? user!.phone! : (user?.phoneMasked ?? '');
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(a2(context, 'changePhoneTitle'),
            style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
        leading: BackButton(onPressed: () {
          if (_step == 1 || _step == 2) {
            setState(() {
              _step -= 1;
              _error = null;
            });
          } else if (context.canPop()) {
            context.pop();
          }
        }),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: switch (_step) {
                0 => _reauth(context, current),
                1 => _newNumber(context),
                2 => _code(context),
                _ => _done(context),
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _reauth(BuildContext context, String current) => Form(
        key: _passwordKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (current.isNotEmpty)
              Text(
                a2(context, 'currentPhone', {'phone': '\u2066$current\u2069'}),
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
              ),
            const SizedBox(height: 8),
            Text(
              a2(context, 'changePhoneReauth'),
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontFamily: 'Cairo', fontWeight: FontWeight.w700, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 16),
            Auth2PasswordField(
              fieldKey: const Key('reauth_password'),
              controller: _password,
              hint: a2(context, 'password'),
              textInputAction: TextInputAction.done,
              validator: (v) => (v ?? '').isEmpty ? a2(context, 'errPassword') : null,
            ),
            if (_error != null) Auth2ErrorBox(_error!),
            const SizedBox(height: 18),
            Auth2PrimaryButton(
              key: const Key('reauth_continue'),
              label: a2(context, 'continue'),
              onPressed: () {
                if (!_passwordKey.currentState!.validate()) return;
                setState(() {
                  _error = null;
                  _step = 1;
                });
              },
            ),
          ],
        ),
      );

  Widget _newNumber(BuildContext context) => Form(
        key: _phoneKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              a2(context, 'changePhoneNew'),
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontFamily: 'Cairo', fontWeight: FontWeight.w700, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 16),
            PhoneField(controller: _phone, autofocus: true, onSubmitted: _start),
            if (_error != null) Auth2ErrorBox(_error!),
            const SizedBox(height: 18),
            Auth2PrimaryButton(
              key: const Key('change_phone_send'),
              label: a2(context, 'sendCode'),
              loading: _busy,
              onPressed: _start,
            ),
          ],
        ),
      );

  Widget _code(BuildContext context) {
    final api = ref.read(auth2ApiProvider);
    return OtpView(
      key: ValueKey(_challenge!.challengeId),
      challenge: _challenge!,
      destination: _phone.e164,
      onVerify: _verify,
      loadStatus: api.otpStatus,
      resend: (id, channel) => api.otpResend(id, channel: channel),
    );
  }

  Widget _done(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.check_circle_rounded, color: AppColors.success, size: 64),
          const SizedBox(height: 12),
          Text(
            a2(context, 'changePhoneDone'),
            key: const Key('change_phone_done'),
            textAlign: TextAlign.center,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary),
          ),
          const SizedBox(height: 20),
          Auth2PrimaryButton(
            label: a2(context, 'done'),
            onPressed: () {
              if (context.canPop()) context.pop();
            },
          ),
        ],
      );
}
