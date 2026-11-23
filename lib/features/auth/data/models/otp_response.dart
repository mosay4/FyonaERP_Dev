class OtpSentResponse {
  final bool success;
  final String message;
  final int expiresInSeconds;
  final int cooldownSeconds;

  const OtpSentResponse({
    this.success = true,
    this.message = '',
    this.expiresInSeconds = 600,
    this.cooldownSeconds = 0,
  });

  factory OtpSentResponse.fromJson(Map<String, dynamic> json) {
    return OtpSentResponse(
      success: (json['success'] as bool?) ?? true,
      message: (json['message'] as String?) ?? '',
      expiresInSeconds: (json['expires_in_seconds'] as num?)?.toInt() ?? 600,
      cooldownSeconds: (json['cooldown_seconds'] as num?)?.toInt() ?? 0,
    );
  }
}

class ResetTokenResponse {
  final bool success;
  final String resetToken;
  final int expiresInSeconds;

  const ResetTokenResponse({
    this.success = true,
    required this.resetToken,
    this.expiresInSeconds = 600,
  });

  factory ResetTokenResponse.fromJson(Map<String, dynamic> json) {
    return ResetTokenResponse(
      success: (json['success'] as bool?) ?? true,
      resetToken: (json['reset_token'] as String?) ?? '',
      expiresInSeconds: (json['expires_in_seconds'] as num?)?.toInt() ?? 600,
    );
  }
}
