import 'dart:developer' as developer;
import 'package:dio/dio.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/network/error_handler.dart';
import '../../../../shared/models/user_model.dart';
import 'auth_remote_data_source.dart';
import '../models/auth_response.dart';
import '../models/otp_response.dart';
import '../models/session_model.dart';

class AuthRemoteDataSourceImpl implements AuthRemoteDataSource {
  final ApiClient _apiClient;

  AuthRemoteDataSourceImpl({required this._apiClient});

  @override
  Future<OtpSentResponse> register({
    required String fullName,
    required String email,
    required String password,
    String? phone,
    String? organizationName,
    String? preferredUsageMode,
  }) async {
    developer.log('[Auth] Sending POST /auth/register');
    try {
      final response = await _apiClient.post(
        '/auth/register',
        data: {
          'full_name': fullName,
          'email': email,
          'password': password,
          if (phone != null && phone.trim().isNotEmpty) 'phone': phone,
          if (organizationName != null && organizationName.trim().isNotEmpty)
            'organization_name': organizationName,
          if (preferredUsageMode != null &&
              preferredUsageMode.trim().isNotEmpty)
            'preferred_usage_mode': preferredUsageMode,
        },
      );
      return OtpSentResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      developer.log(
        '[Auth] /auth/register failed: type=${e.type} message=${e.message}',
      );
      throw handleDioException(e);
    }
  }

  @override
  Future<AuthResponse> verifyRegistration({
    required String email,
    required String otp,
  }) async {
    developer.log('[Auth] Sending POST /auth/verify-registration');
    try {
      final response = await _apiClient.post(
        '/auth/verify-registration',
        data: {'email': email, 'otp': otp},
      );
      return AuthResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      developer.log(
        '[Auth] /auth/verify-registration failed: type=${e.type} '
        'message=${e.message}',
      );
      throw handleDioException(e);
    }
  }

  @override
  Future<OtpSentResponse> resendRegistrationOtp(String email) async {
    developer.log('[Auth] Sending POST /auth/resend-otp');
    try {
      final response = await _apiClient.post(
        '/auth/resend-otp',
        data: {'email': email},
      );
      return OtpSentResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      developer.log(
        '[Auth] /auth/resend-otp failed: type=${e.type} message=${e.message}',
      );
      throw handleDioException(e);
    }
  }

  @override
  Future<AuthResponse> loginWithEmailPassword({
    required String email,
    required String password,
  }) async {
    developer.log('[Auth] Sending POST /auth/login');
    try {
      final response = await _apiClient.post(
        '/auth/login',
        data: {'email': email, 'password': password},
      );
      developer.log(
        '[Auth] /auth/login responded: status=${response.statusCode}',
      );
      return AuthResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      developer.log(
        '[Auth] /auth/login failed: type=${e.type} message=${e.message}',
      );
      throw handleDioException(e);
    }
  }

  @override
  Future<OtpSentResponse> forgotPassword(
    String email, {
    String purpose = 'reset',
  }) async {
    developer.log('[Auth] Sending POST /auth/forgot-password');
    try {
      final response = await _apiClient.post(
        '/auth/forgot-password',
        data: {'email': email, 'purpose': purpose},
      );
      return OtpSentResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      developer.log(
        '[Auth] /auth/forgot-password failed: type=${e.type} '
        'message=${e.message}',
      );
      throw handleDioException(e);
    }
  }

  @override
  Future<ResetTokenResponse> verifyOtp({
    required String email,
    required String otp,
    String purpose = 'reset',
  }) async {
    developer.log('[Auth] Sending POST /auth/verify-otp');
    try {
      final response = await _apiClient.post(
        '/auth/verify-otp',
        data: {'email': email, 'otp': otp, 'purpose': purpose},
      );
      return ResetTokenResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      developer.log(
        '[Auth] /auth/verify-otp failed: type=${e.type} message=${e.message}',
      );
      throw handleDioException(e);
    }
  }

  @override
  Future<AuthResponse> resetPassword({
    required String resetToken,
    required String newPassword,
  }) async {
    developer.log('[Auth] Sending POST /auth/reset-password');
    try {
      final response = await _apiClient.post(
        '/auth/reset-password',
        data: {'reset_token': resetToken, 'new_password': newPassword},
      );
      return AuthResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      developer.log(
        '[Auth] /auth/reset-password failed: type=${e.type} '
        'message=${e.message}',
      );
      throw handleDioException(e);
    }
  }

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    developer.log('[Auth] Sending POST /auth/change-password');
    try {
      await _apiClient.post(
        '/auth/change-password',
        data: {
          'current_password': currentPassword,
          'new_password': newPassword,
        },
      );
    } on DioException catch (e) {
      developer.log(
        '[Auth] /auth/change-password failed: type=${e.type} '
        'message=${e.message}',
      );
      throw handleDioException(e);
    }
  }

  @override
  Future<OtpSentResponse> requestEmailChange() async {
    developer.log('[Auth] Sending POST /auth/email-change-otp');
    try {
      final response = await _apiClient.post('/auth/email-change-otp');
      return OtpSentResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      developer.log(
        '[Auth] /auth/email-change-otp failed: type=${e.type} message=${e.message}',
      );
      throw handleDioException(e);
    }
  }

  @override
  Future<AuthResponse> verifyEmailChange({
    required String code,
    required String newEmail,
  }) async {
    developer.log('[Auth] Sending POST /auth/email-change-verify');
    try {
      final response = await _apiClient.post(
        '/auth/email-change-verify',
        data: {'otp': code, 'new_email': newEmail},
      );
      return AuthResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      developer.log(
        '[Auth] /auth/email-change-verify failed: type=${e.type} message=${e.message}',
      );
      throw handleDioException(e);
    }
  }

  @override
  Future<AuthResponse> loginWithFirebase(String idToken, {String? googleIdToken}) async {
    developer.log('[Auth] Sending POST /auth/firebase');
    try {
      final payload = <String, dynamic>{'id_token': idToken};
      if (googleIdToken != null) {
        payload['google_id_token'] = googleIdToken;
      }
      final response = await _apiClient.post(
        '/auth/firebase',
        data: payload,
      );
      developer.log(
        '[Auth] /auth/firebase responded: status=${response.statusCode}',
      );
      return AuthResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      developer.log(
        '[Auth] /auth/firebase failed: type=${e.type} message=${e.message}',
      );
      throw handleDioException(e);
    }
  }

  @override
  Future<AuthResponse> refreshToken(String refreshToken) async {
    try {
      final response = await _apiClient.post(
        '/auth/refresh',
        data: {'refresh_token': refreshToken},
      );
      return AuthResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw handleDioException(e);
    }
  }

  @override
  Future<void> logout() async {
    try {
      await _apiClient.post('/auth/logout');
    } on DioException catch (_) {}
  }

  @override
  Future<void> logoutSession(String sessionId, String userId) async {
    try {
      await _apiClient.post(
        '/auth/sessions/logout',
        data: {'session_id': sessionId, 'user_id': userId},
      );
    } on DioException catch (e) {
      throw handleDioException(e);
    }
  }

  @override
  Future<void> forceLogoutAll({String? userId, String? excludeSessionId}) async {
    final data = <String, dynamic>{};
    if (userId != null) data['user_id'] = userId;
    if (excludeSessionId != null) data['exclude_session_id'] = excludeSessionId;
    try {
      await _apiClient.post('/auth/sessions/logout-all', data: data);
    } on DioException catch (e) {
      throw handleDioException(e);
    }
  }

  @override
  Future<UserModel> getProfile() async {
    try {
      final response = await _apiClient.get('/auth/me');
      return UserModel.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      _logRequestFailure(e, method: 'GET', path: '/auth/me');
      throw handleDioException(e);
    }
  }

  @override
  Future<UserModel> updateProfile({
    String? fullName,
    String? email,
    String? phone,
  }) async {
    final body = <String, dynamic>{};
    if (fullName != null) body['full_name'] = fullName;
    if (email != null) body['email'] = email;
    if (phone != null) body['phone'] = phone;

    try {
      final response = await _apiClient.put(
        '/auth/me',
        data: body,
      );
      return UserModel.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      _logRequestFailure(e, method: 'PUT', path: '/auth/me', body: body);
      throw handleDioException(e);
    }
  }

  @override
  Future<UserModel> updatePhone({
    required String phone,
    String? country,
  }) async {
    final body = <String, dynamic>{
      'phone': phone,
      if (country != null && country.trim().isNotEmpty) 'country': country,
    };

    try {
      final response = await _apiClient.post('/auth/me/phone', data: body);
      return UserModel.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      _logRequestFailure(e, method: 'POST', path: '/auth/me/phone', body: body);
      throw handleDioException(e);
    }
  }

  void _logRequestFailure(
    DioException e, {
    required String method,
    required String path,
    Map<String, dynamic>? body,
  }) {
    final response = e.response;
    developer.log(
      '[UpdateProfile] $method $path failed.\n'
      'Request URL: ${response?.requestOptions.uri ?? e.requestOptions.uri}\n'
      'Request Body: ${body ?? e.requestOptions.data}\n'
      'Response Status Code: ${response?.statusCode ?? e.type}\n'
      'Response Body: ${response?.data}',
      name: 'auth_remote_data_source',
      error: e,
    );
  }

  @override
  Future<List<SessionModel>> getActiveSessions(String userId) async {
    // Errors MUST propagate (never collapse to []): the sessions page must
    // distinguish "fetch failed — keep the old list" from "zero sessions".
    final response = await _apiClient.get(
      '/auth/sessions',
      queryParameters: {'user_id': userId},
    );
    final data = response.data;
    if (data is List) {
      return data
          .map((e) => SessionModel.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  @override
  Future<void> updateSessionName(String sessionId, String customName) async {
    await _apiClient.put(
      '/auth/sessions/$sessionId/name',
      data: {'custom_name': customName},
    );
  }
}
