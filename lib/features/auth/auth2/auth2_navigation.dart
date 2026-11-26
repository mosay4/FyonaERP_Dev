import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/route_names.dart';
import 'auth2_flow.dart';
import 'auth2_models.dart';

/// Continues after /auth2/login or /auth2/social: authenticated results are
/// already applied (the router leaves the sign-in screens by itself); a new
/// device goes to «Verify this device»; a new social identity must add and
/// verify a phone number first.
void continueAfterLogin(
  BuildContext context,
  WidgetRef ref,
  Auth2LoginResult result, {
  String? phoneE164,
  String? password,
  String? socialProvider,
}) {
  switch (result) {
    case Auth2Authenticated():
      ref.read(auth2FlowProvider.notifier).state = const Auth2Flow();
    case Auth2NeedsVerification(:final verification):
      ref.read(auth2FlowProvider.notifier).state = Auth2Flow(
        purpose: OtpPurpose.loginVerify,
        verification: verification,
        phoneE164: phoneE164,
        password: password,
        socialProvider: socialProvider,
      );
      context.go(RouteNames.verifyDevice);
    case Auth2NeedsPhone(:final socialSession):
      ref.read(auth2FlowProvider.notifier).state = Auth2Flow(
        purpose: OtpPurpose.socialPhone,
        socialSession: socialSession,
        socialProvider: socialProvider,
      );
      context.go(RouteNames.socialPhone);
  }
}
