import '../../../../core/network/api_exceptions.dart';

class TokenResponse {
  final String accessToken;
  final String? refreshToken;
  final String? tokenType;
  final int? expiresIn;

  const TokenResponse({
    required this.accessToken,
    this.refreshToken,
    this.tokenType,
    this.expiresIn,
  });

  factory TokenResponse.fromJson(Map<String, dynamic> json) {
    final token = json['access_token'] as String? ??
        json['token'] as String? ??
        json['accessToken'] as String?;
    if (token == null || token.isEmpty) {
      throw const ApiException(message: 'لم يتم استلام رمز الدخول من الخادم');
    }
    return TokenResponse(
      accessToken: token,
      refreshToken: json['refresh_token'] as String? ??
          json['refreshToken'] as String?,
      tokenType: json['token_type'] as String? ?? 'Bearer',
      expiresIn: json['expires_in'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        if (refreshToken != null) 'refresh_token': refreshToken,
        if (tokenType != null) 'token_type': tokenType,
        if (expiresIn != null) 'expires_in': expiresIn,
      };
}
