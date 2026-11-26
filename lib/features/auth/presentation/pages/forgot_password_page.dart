import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/route_names.dart';
import '../../auth2/auth2_flow.dart';
import '../../auth2/auth2_service.dart';
import '../../auth2/auth2_strings.dart';
import '../../auth2/widgets/auth2_widgets.dart';
import '../../auth2/widgets/phone_field.dart';

/// Forgot password: account phone → OTP (WhatsApp, SMS fallback when the
/// server allows) → new password ([ResetPasswordPage]).
class ForgotPasswordPage extends ConsumerStatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  ConsumerState<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends ConsumerState<ForgotPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _phone = PhoneFieldController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final known = ref.read(auth2FlowProvider).phoneE164;
    if (known != null && known.startsWith('+')) _phone.setE164(known);
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    final phone = _phone.e164;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final challenge = await ref.read(auth2ServiceProvider).passwordForgot(phone);
      if (!mounted) return;
      ref.read(auth2FlowProvider.notifier).state = Auth2Flow(
        purpose: OtpPurpose.passwordReset,
        challenge: challenge,
        phoneE164: phone,
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
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Auth2Title(
              a2(context, 'forgotTitle'),
              subtitle: a2(context, 'forgotSubtitle'),
            ),
            PhoneField(
              controller: _phone,
              textInputAction: TextInputAction.done,
              onSubmitted: _submit,
            ),
            if (_error != null) Auth2ErrorBox(_error!),
            const SizedBox(height: 20),
            Auth2PrimaryButton(
              key: const Key('forgot_submit'),
              label: a2(context, 'sendCode'),
              loading: _busy,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
