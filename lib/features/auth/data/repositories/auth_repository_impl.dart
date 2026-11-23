import '../../data/datasources/auth_remote_data_source.dart';
import '../../data/datasources/auth_local_data_source.dart';
import '../../data/models/auth_response.dart';
import '../../data/models/otp_response.dart';
import '../../data/models/session_model.dart';
import '../../../../shared/models/user_model.dart';
import '../../domain/repositories/auth_repository.dart';

class AuthRepositoryImpl implements AuthRepository {
  final AuthRemoteDataSource _remoteDataSource;
  final AuthLocalDataSource _localDataSource;

  AuthRepositoryImpl({
    required this._remoteDataSource,
    required this._localDataSource,
  });

  @override
  Future<AuthResponse> loginWithFirebase(String idToken, {String? googleIdToken}) async {
    final response = await _remoteDataSource.loginWithFirebase(idToken, googleIdToken: googleIdToken);
    await _localDataSource.saveTokens(response.token);
    await _localDataSource.saveUser(response.user);
    return response;
  }

  @override
  Future<AuthResponse> loginWithEmailPassword({
    required String email,
    required String password,
  }) async {
    final response = await _remoteDataSource.loginWithEmailPassword(
      email: email,
      password: password,
    );
    await _localDataSource.saveTokens(response.token);
    await _localDataSource.saveUser(response.user);
    return response;
  }

  @override
  Future<OtpSentResponse> register({
    required String fullName,
    required String email,
    required String password,
    String? phone,
    String? organizationName,
    String? preferredUsageMode,
  }) {
    return _remoteDataSource.register(
      fullName: fullName,
      email: email,
      password: password,
      phone: phone,
      organizationName: organizationName,
      preferredUsageMode: preferredUsageMode,
    );
  }

  @override
  Future<AuthResponse> verifyRegistration({
    required String email,
    required String otp,
  }) async {
    final response = await _remoteDataSource.verifyRegistration(
      email: email,
      otp: otp,
    );
    await _localDataSource.saveTokens(response.token);
    await _localDataSource.saveUser(response.user);
    return response;
  }

  @override
  Future<OtpSentResponse> resendRegistrationOtp(String email) {
    return _remoteDataSource.resendRegistrationOtp(email);
  }

  @override
  Future<OtpSentResponse> forgotPassword(String email, {String purpose = 'reset'}) {
    return _remoteDataSource.forgotPassword(email, purpose: purpose);
  }

  @override
  Future<ResetTokenResponse> verifyOtp({
    required String email,
    required String otp,
    String purpose = 'reset',
  }) {
    return _remoteDataSource.verifyOtp(
      email: email,
      otp: otp,
      purpose: purpose,
    );
  }

  @override
  Future<AuthResponse> resetPassword({
    required String resetToken,
    required String newPassword,
  }) async {
    final response = await _remoteDataSource.resetPassword(
      resetToken: resetToken,
      newPassword: newPassword,
    );
    await _localDataSource.saveTokens(response.token);
    await _localDataSource.saveUser(response.user);
    return response;
  }

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) {
    return _remoteDataSource.changePassword(
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
  }

  @override
  Future<OtpSentResponse> requestEmailChange() {
    return _remoteDataSource.requestEmailChange();
  }

  @override
  Future<AuthResponse> verifyEmailChange({
    required String code,
    required String newEmail,
  }) async {
    final response = await _remoteDataSource.verifyEmailChange(
      code: code,
      newEmail: newEmail,
    );
    await _localDataSource.saveTokens(response.token);
    await _localDataSource.saveUser(response.user);
    return response;
  }

  @override
  Future<AuthResponse> refreshToken(String refreshToken) async {
    final response = await _remoteDataSource.refreshToken(refreshToken);
    await _localDataSource.saveTokens(response.token);
    await _localDataSource.saveUser(response.user);
    return response;
  }

  @override
  Future<void> logout() async {
    try {
      await _remoteDataSource.logout();
    } catch (_) {
    }
    await _localDataSource.clearAuth();
  }

  @override
  Future<void> logoutSession(String sessionId, String userId) async {
    await _remoteDataSource.logoutSession(sessionId, userId);
  }

  @override
  Future<void> forceLogoutAll({String? userId, String? excludeSessionId}) async {
    await _remoteDataSource.forceLogoutAll(
      userId: userId,
      excludeSessionId: excludeSessionId,
    );
  }

  @override
  Future<void> updateSessionName(String sessionId, String customName) async {
    await _remoteDataSource.updateSessionName(sessionId, customName);
  }

  @override
  Future<UserModel> getProfile() async {
    final user = await _remoteDataSource.getProfile();
    await _localDataSource.saveUser(user);
    return user;
  }

  @override
  Future<UserModel> updateProfile({
    String? fullName,
    String? email,
    String? phone,
  }) async {
    final user = await _remoteDataSource.updateProfile(
      fullName: fullName,
      email: email,
      phone: phone,
    );
    await _localDataSource.saveUser(user);
    return user;
  }

  @override
  Future<UserModel> updatePhone({
    required String phone,
    String? country,
  }) async {
    final user = await _remoteDataSource.updatePhone(
      phone: phone,
      country: country,
    );
    await _localDataSource.saveUser(user);
    return user;
  }

  @override
  Future<List<SessionModel>> getActiveSessions(String userId) async {
    return await _remoteDataSource.getActiveSessions(userId);
  }

  @override
  Future<bool> hasSession() => _localDataSource.hasSession();

  @override
  Future<void> clearSession() => _localDataSource.clearAuth();
}
