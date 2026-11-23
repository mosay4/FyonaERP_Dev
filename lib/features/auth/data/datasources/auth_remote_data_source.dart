import '../models/auth_response.dart';
import '../models/otp_response.dart';
import '../models/session_model.dart';
import '../../../../shared/models/user_model.dart';

abstract class AuthRemoteDataSource {
  Future<AuthResponse> loginWithFirebase(String idToken, {String? googleIdToken});
  Future<AuthResponse> loginWithEmailPassword({
    required String email,
    required String password,
  });
  Future<OtpSentResponse> register({
    required String fullName,
    required String email,
    required String password,
    String? phone,
    String? organizationName,
    String? preferredUsageMode,
  });
  Future<AuthResponse> verifyRegistration({
    required String email,
    required String otp,
  });
  Future<OtpSentResponse> resendRegistrationOtp(String email);
  Future<OtpSentResponse> forgotPassword(String email, {String purpose = 'reset'});
  Future<ResetTokenResponse> verifyOtp({
    required String email,
    required String otp,
    String purpose = 'reset',
  });
  Future<AuthResponse> resetPassword({
    required String resetToken,
    required String newPassword,
  });
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  });
  Future<OtpSentResponse> requestEmailChange();
  Future<AuthResponse> verifyEmailChange({
    required String code,
    required String newEmail,
  });
  Future<AuthResponse> refreshToken(String refreshToken);
  Future<void> logout();
  Future<void> logoutSession(String sessionId, String userId);
  Future<void> forceLogoutAll({String? userId, String? excludeSessionId});
  Future<UserModel> getProfile();
  Future<UserModel> updateProfile({String? fullName, String? email, String? phone});
  Future<UserModel> updatePhone({required String phone, String? country});
  Future<List<SessionModel>> getActiveSessions(String userId);
  Future<void> updateSessionName(String sessionId, String customName);
}
