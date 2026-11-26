import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth2_models.dart';

/// What the OTP screen is verifying.
enum OtpPurpose { signup, loginVerify, socialPhone, passwordReset, phoneChange }

/// In-memory context shared by the sign-in screens (never persisted: a
/// killed app simply starts over at the login page).
class Auth2Flow {
  final OtpPurpose? purpose;
  final OtpChallenge? challenge;
  final String? phoneE164;
  final String? password;
  final String? fullName;
  final DeviceVerification? verification;
  final String? socialSession;
  final String? socialProvider;

  /// Code typed on the OTP screen for the password-reset step.
  final String? resetCode;

  const Auth2Flow({
    this.purpose,
    this.challenge,
    this.phoneE164,
    this.password,
    this.fullName,
    this.verification,
    this.socialSession,
    this.socialProvider,
    this.resetCode,
  });

  Auth2Flow copyWith({
    OtpPurpose? purpose,
    OtpChallenge? challenge,
    String? phoneE164,
    String? password,
    String? fullName,
    DeviceVerification? verification,
    String? socialSession,
    String? socialProvider,
    String? resetCode,
  }) =>
      Auth2Flow(
        purpose: purpose ?? this.purpose,
        challenge: challenge ?? this.challenge,
        phoneE164: phoneE164 ?? this.phoneE164,
        password: password ?? this.password,
        fullName: fullName ?? this.fullName,
        verification: verification ?? this.verification,
        socialSession: socialSession ?? this.socialSession,
        socialProvider: socialProvider ?? this.socialProvider,
        resetCode: resetCode ?? this.resetCode,
      );
}

final auth2FlowProvider = StateProvider<Auth2Flow>((ref) => const Auth2Flow());
