import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/route_names.dart';
import '../../auth2/auth2_flow.dart';
import '../../auth2/auth2_service.dart';
import '../../auth2/auth2_strings.dart';
import '../../auth2/widgets/auth2_widgets.dart';
import '../../auth2/widgets/phone_field.dart';

/// First Google/Apple sign-in: the account is not usable until a phone
/// number is added and verified by OTP.
class SocialPhonePage extends ConsumerStatefulWidget {
  const SocialPhonePage({super.key});

  @override
  ConsumerState<SocialPhonePage> createState() => _SocialPhonePageState();
}

class _SocialPhonePageState extends ConsumerState<SocialPhonePage> {
  final _formKey = GlobalKey<FormState>();
  final _phone = PhoneFieldController();
  bool _busy = false;
  String? _error;
  String? _idemPhone;
  String _idemKey = Auth2Service.newIdempotencyKey();

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final flow = ref.read(auth2FlowProvider);
    final session = flow.socialSession;
    if (_busy || session == null || !_formKey.currentState!.validate()) return;
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
      final challenge = await ref
          .read(auth2ServiceProvider)
          .socialPhoneStart(session, phone, _idemKey);
      if (!mounted) return;
      ref.read(auth2FlowProvider.notifier).state = flow.copyWith(
        purpose: OtpPurpose.socialPhone,
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
    if (ref.watch(auth2FlowProvider).socialSession == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go(RouteNames.login);
      });
      return const Auth2Shell(child: SizedBox.shrink());
    }
    return Auth2Shell(
      onBack: () {
        ref.read(auth2FlowProvider.notifier).state = const Auth2Flow();
        context.go(RouteNames.login);
      },
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Auth2Title(
              a2(context, 'socialPhoneTitle'),
              subtitle: a2(context, 'socialPhoneSubtitle'),
            ),
            PhoneField(
              controller: _phone,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: _submit,
            ),
            if (_error != null) Auth2ErrorBox(_error!),
            const SizedBox(height: 20),
            Auth2PrimaryButton(
              key: const Key('social_phone_submit'),
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
