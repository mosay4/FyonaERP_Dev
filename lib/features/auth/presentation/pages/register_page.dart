import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../auth2/auth2_flow.dart';
import '../../auth2/auth2_service.dart';
import '../../auth2/auth2_strings.dart';
import '../../auth2/widgets/auth2_widgets.dart';
import '../../auth2/widgets/phone_field.dart';

/// Create account: full name, phone, password + confirm → OTP (WhatsApp first).
class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key});

  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends ConsumerState<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = PhoneFieldController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  // Same key for retries of the same number (a double tap never starts two
  // challenges); a different number gets a new key.
  String? _idemPhone;
  String _idemKey = Auth2Service.newIdempotencyKey();

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;
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
      final challenge = await ref.read(auth2ServiceProvider).registerStart(
            fullName: _name.text.trim(),
            phoneE164: phone,
            password: _password.text,
            idempotencyKey: _idemKey,
          );
      if (!mounted) return;
      ref.read(auth2FlowProvider.notifier).state = Auth2Flow(
        purpose: OtpPurpose.signup,
        challenge: challenge,
        phoneE164: phone,
        password: _password.text,
        fullName: _name.text.trim(),
      );
      setState(() => _busy = false);
      context.go(RouteNames.authOtp);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = auth2ErrorTextOf(context, e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Auth2Shell(
      onBack: () => context.go(RouteNames.login),
      child: AutofillGroup(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Auth2Title(
                a2(context, 'registerTitle'),
                subtitle: a2(context, 'registerSubtitle'),
              ),
              TextFormField(
                key: const Key('name_input'),
                controller: _name,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.name],
                textCapitalization: TextCapitalization.words,
                style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary),
                validator: (v) =>
                    (v ?? '').trim().length < 2 ? a2(context, 'errName') : null,
                decoration: InputDecoration(
                  hintText: a2(context, 'fullName'),
                  prefixIcon: Icon(Icons.person_outline,
                      size: 21, color: AppColors.textSecondary),
                ),
              ),
              const SizedBox(height: 14),
              PhoneField(controller: _phone),
              const SizedBox(height: 14),
              Auth2PasswordField(
                fieldKey: const Key('password_input'),
                controller: _password,
                hint: a2(context, 'password'),
                onChanged: (_) => setState(() {}),
                validator: (v) => (v ?? '').length < 8
                    ? a2(context, 'errPasswordShort')
                    : null,
              ),
              PasswordStrengthBar(password: _password.text),
              const SizedBox(height: 14),
              Auth2PasswordField(
                fieldKey: const Key('confirm_input'),
                controller: _confirm,
                hint: a2(context, 'confirmPassword'),
                textInputAction: TextInputAction.done,
                onSubmitted: _submit,
                validator: (v) =>
                    v != _password.text ? a2(context, 'errMismatch') : null,
              ),
              if (_error != null) Auth2ErrorBox(_error!),
              const SizedBox(height: 20),
              Auth2PrimaryButton(
                key: const Key('register_submit'),
                label: a2(context, 'continue'),
                loading: _busy,
                onPressed: _submit,
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => context.go(RouteNames.login),
                child: Text(
                  a2(context, 'haveAccount'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
