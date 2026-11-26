import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/route_names.dart';
import '../../auth2/auth2_api.dart';
import '../../auth2/auth2_flow.dart';
import '../../auth2/auth2_models.dart';
import '../../auth2/auth2_service.dart';
import '../../auth2/auth2_strings.dart';
import '../../auth2/widgets/auth2_widgets.dart';
import '../../auth2/widgets/otp_view.dart';
import '../providers/auth_provider.dart';

/// The one OTP screen of the public flows: sign-up, new-device login,
/// social phone completion and password reset (see [OtpPurpose]).
class OtpPage extends ConsumerWidget {
  const OtpPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flow = ref.watch(auth2FlowProvider);
    final challenge = flow.challenge;
    if (challenge == null || flow.purpose == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go(RouteNames.login);
      });
      return const Auth2Shell(child: SizedBox.shrink());
    }
    final api = ref.read(auth2ApiProvider);
    final service = ref.read(auth2ServiceProvider);
    final notifier = ref.read(authProvider.notifier);

    Future<void> verify(String code) async {
      switch (flow.purpose!) {
        case OtpPurpose.signup:
          final r = await service.registerVerify(challenge.challengeId, code);
          await notifier.completeAuth2(r,
              password: flow.password, usageMode: 'personal');
        case OtpPurpose.loginVerify:
          final r = await service.loginVerify(challenge.challengeId, code);
          await notifier.completeAuth2(r, password: flow.password);
        case OtpPurpose.socialPhone:
          final r = await service.socialPhoneVerify(challenge.challengeId, code);
          await notifier.completeAuth2(r, usageMode: 'personal');
        case OtpPurpose.passwordReset:
          ref.read(auth2FlowProvider.notifier).state =
              flow.copyWith(resetCode: code);
          if (context.mounted) context.go(RouteNames.resetPassword);
          return;
        case OtpPurpose.phoneChange:
          // Handled inside the settings page (ChangePhonePage).
          return;
      }
      ref.read(auth2FlowProvider.notifier).state = const Auth2Flow();
    }

    Future<OtpChallenge> resend(String id, String? channel) async {
      final next = await api.otpResend(id, channel: channel);
      ref.read(auth2FlowProvider.notifier).state = flow.copyWith(challenge: next);
      return next;
    }

    return Auth2Shell(
      onBack: () {
        final back = switch (flow.purpose!) {
          OtpPurpose.signup => RouteNames.register,
          OtpPurpose.loginVerify => RouteNames.verifyDevice,
          OtpPurpose.socialPhone => RouteNames.socialPhone,
          OtpPurpose.passwordReset => RouteNames.forgotPassword,
          OtpPurpose.phoneChange => RouteNames.login,
        };
        context.go(back);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Auth2Title(a2(context, 'otpTitle')),
          OtpView(
            key: ValueKey(challenge.challengeId),
            challenge: challenge,
            destination: flow.phoneE164 ?? '',
            primaryDeviceName: flow.verification?.primaryDevice?.label,
            onVerify: verify,
            loadStatus: api.otpStatus,
            resend: resend,
          ),
        ],
      ),
    );
  }
}
