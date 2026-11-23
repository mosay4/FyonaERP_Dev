import '../../../../shared/models/user_model.dart';
import 'token_response.dart';

class AuthResponse {
  final UserModel user;
  final TokenResponse token;

  const AuthResponse({
    required this.user,
    required this.token,
  });

  factory AuthResponse.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    final userData = data['user'] as Map<String, dynamic>? ??
        json['user'] as Map<String, dynamic>? ??
        data;
    return AuthResponse(
      user: UserModel.fromJson(userData),
      token: TokenResponse.fromJson(data),
    );
  }

  Map<String, dynamic> toJson() => {
        'user': user.toJson(),
        ...token.toJson(),
      };
}
