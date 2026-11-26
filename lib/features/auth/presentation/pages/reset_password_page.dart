import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../auth2/auth2_api.dart';
import '../../auth2/auth2_flow.dart';
import '../../auth2/auth2_models.dart';
import '../../auth2/auth2_strings.dart';
import '../../auth2/widgets/auth2_widgets.dart';
import '../providers/auth_provider.dart';

/// Last step of «forgot password»: the new password, sent with the OTP.
class ResetPasswordPage extends ConsumerStatefulWidget {
  const ResetPasswordPage({super.key});

  @override
  ConsumerState<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends ConsumerState<ResetPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _finished = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final flow = ref.read(auth2FlowProvider);
    final challenge = flow.challenge;
    final code = flow.resetCode;
    if (_busy || challenge == null || code == null) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref.read(auth2ApiProvider).passwordReset(
            challengeId: challenge.challengeId,
            code: code,
            newPassword: _password.text,
          );
      if (!mounted) return;
      _finished = true;
      if (result != null) {
        await ref
            .read(authProvider.notifier)
            .completeAuth2(result, password: _password.text);
        ref.read(auth2FlowProvider.notifier).state = const Auth2Flow();
        return;
      }
      final messenger = ScaffoldMessenger.of(context);
      final text = a2(context, 'passwordChanged');
      ref.read(auth2FlowProvider.notifier).state =
          Auth2Flow(phoneE164: flow.phoneE164);
      context.go(RouteNames.login);
      messenger.showSnackBar(SnackBar(
        content: Text(text, style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: AppColors.success,
      ));
    } on Auth2Exception catch (e) {
      if (!mounted) return;
      final wrongCode = e.code == 'invalid_code' || e.code == 'wrong_code';
      setState(() {
        _busy = false;
        _error = auth2ErrorTextOf(context, e);
      });
      if (wrongCode) {
        // Back to the code screen to type it again.
        context.go(RouteNames.authOtp);
      }
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
    final flow = ref.watch(auth2FlowProvider);
    if (flow.challenge == null || flow.resetCode == null) {
      if (_finished) return const Auth2Shell(child: SizedBox.shrink());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go(RouteNames.forgotPassword);
      });
      return const Auth2Shell(child: SizedBox.shrink());
    }
    return Auth2Shell(
      onBack: () => context.go(RouteNames.authOtp),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Auth2Title(a2(context, 'newPasswordTitle')),
            Auth2PasswordField(
              fieldKey: const Key('new_password_input'),
              controller: _password,
              hint: a2(context, 'newPassword'),
              onChanged: (_) => setState(() {}),
              validator: (v) =>
                  (v ?? '').length < 8 ? a2(context, 'errPasswordShort') : null,
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
              key: const Key('reset_submit'),
              label: a2(context, 'savePassword'),
              loading: _busy,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
