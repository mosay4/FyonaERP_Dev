import 'dart:convert';

import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../../../../core/services/audit_service.dart';
import '../../../../shared/models/user_model.dart';
import '../repositories/auth_repository.dart';
import '../../data/models/auth_response.dart';
import '../../data/models/otp_response.dart';
import '../../data/models/session_model.dart';

class AuthService {
  final AuthRepository _repository;
  final AuditService _auditService;

  AuthService({
    required AuthRepository repository,
    required AuditService auditService,
  })  : _repository = repository,
        _auditService = auditService;

  Future<AuthResponse> loginWithFirebase({
    required String idToken,
    String? googleIdToken,
  }) async {
    final response = await _repository.loginWithFirebase(idToken, googleIdToken: googleIdToken);
    _auditService.logEvent(AuditEvent(action: 'login', resource: 'user',
        resourceId: response.user.id.toString(), details: AppLocalizations.t('svcAuthLoginOk'),
        userId: response.user.id, orgId: response.user.organizationId));
    return response;
  }

  Future<AuthResponse> loginWithEmailPassword({
    required String email,
    required String password,
  }) async {
    final response = await _repository.loginWithEmailPassword(
      email: email,
      password: password,
    );
    _auditService.logEvent(AuditEvent(action: 'login', resource: 'user',
        resourceId: response.user.id.toString(), details: AppLocalizations.t('svcAuthLoginOk'),
        userId: response.user.id, orgId: response.user.organizationId));
    return response;
  }

  Future<OtpSentResponse> register({
    required String fullName,
    required String email,
    required String password,
    String? phone,
    String? organizationName,
    String? preferredUsageMode,
  }) {
    return _repository.register(
      fullName: fullName,
      email: email,
      password: password,
      phone: phone,
      organizationName: organizationName,
      preferredUsageMode: preferredUsageMode,
    );
  }

  Future<AuthResponse> verifyRegistration({
    required String email,
    required String otp,
  }) async {
    final response = await _repository.verifyRegistration(email: email, otp: otp);
    _auditService.logEvent(AuditEvent(action: 'register_verify', resource: 'user',
        resourceId: response.user.id.toString(),
        details: AppLocalizations.t('svcAuthRegisterVerifyOk'),
        userId: response.user.id, orgId: response.user.organizationId));
    return response;
  }

  Future<OtpSentResponse> resendRegistrationOtp(String email) {
    return _repository.resendRegistrationOtp(email);
  }

  Future<OtpSentResponse> forgotPassword(String email, {String purpose = 'reset'}) {
    return _repository.forgotPassword(email, purpose: purpose);
  }

  Future<ResetTokenResponse> verifyOtp({
    required String email,
    required String otp,
    String purpose = 'reset',
  }) {
    return _repository.verifyOtp(email: email, otp: otp, purpose: purpose);
  }

  Future<AuthResponse> resetPassword({
    required String resetToken,
    required String newPassword,
  }) async {
    final response = await _repository.resetPassword(
      resetToken: resetToken,
      newPassword: newPassword,
    );
    _auditService.logEvent(AuditEvent(action: 'password_reset', resource: 'user',
        resourceId: response.user.id.toString(),
        details: AppLocalizations.t('svcAuthPasswordResetOk'),
        userId: response.user.id, orgId: response.user.organizationId));
    return response;
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await _repository.changePassword(
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
  }

  Future<OtpSentResponse> requestEmailChange() {
    return _repository.requestEmailChange();
  }

  Future<AuthResponse> verifyEmailChange({
    required String code,
    required String newEmail,
  }) async {
    final response = await _repository.verifyEmailChange(
      code: code,
      newEmail: newEmail,
    );
    _auditService.logEvent(AuditEvent(action: 'email_change', resource: 'user',
        resourceId: response.user.id.toString(),
        details: AppLocalizations.t('svcAuthEmailChanged', {'email': response.user.email}),
        userId: response.user.id, orgId: response.user.organizationId));
    return response;
  }

  Future<void> logout({String? sessionId, String? userId}) async {
    try { await _repository.logout(); } catch (_) {}
    _auditService.logEvent(AuditEvent(action: 'logout', resource: 'session',
        resourceId: sessionId, userId: userId));
  }

  Future<void> logoutSession(String sessionId, String userId) async {
    await _repository.logoutSession(sessionId, userId);
  }

  Future<void> forceLogoutAll({String? userId, String? excludeSessionId}) async {
    await _repository.forceLogoutAll(userId: userId, excludeSessionId: excludeSessionId);
  }

  Future<List<SessionModel>> getActiveSessions(String userId) async {
    // Errors MUST propagate (never collapse to []): the sessions page must
    // distinguish "fetch failed — keep the old list" from "zero sessions".
    return await _repository.getActiveSessions(userId);
  }

  Future<UserModel?> getProfile() async {
    try {
      return await _repository.getProfile();
    } catch (_) { return null; }
  }

  Future<UserModel> updateProfile({String? fullName, String? email, String? phone, String? userId}) async {
    final user = await _repository.updateProfile(fullName: fullName, email: email, phone: phone);
    _auditService.logEvent(AuditEvent(action: 'profile_update', resource: 'user',
        resourceId: userId, details: AppLocalizations.t('svcAuthProfileUpdated'), userId: userId));
    return user;
  }

  Future<UserModel> updatePhone({
    required String phone,
    String? country,
    String? userId,
  }) async {
    final user = await _repository.updatePhone(phone: phone, country: country);
    _auditService.logEvent(AuditEvent(action: 'phone_update', resource: 'user',
        resourceId: userId, details: AppLocalizations.t('svcAuthPhoneAdded'), userId: userId));
    return user;
  }

  Future<bool> hasSession() async => _repository.hasSession();
  Future<void> clearSession() async => _repository.clearSession();

  Future<void> updateSessionName(String sessionId, String customName) async {
    await _repository.updateSessionName(sessionId, customName);
  }

  bool isTokenExpired(String token) {
    final payload = decodeToken(token);
    if (payload == null) return true;
    final exp = payload['exp'] as int?;
    if (exp == null) return false;
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 >= exp;
  }

  Map<String, dynamic>? decodeToken(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = parts[1];
      final normalized = payload.replaceAll('-', '+').replaceAll('_', '/');
      final padded = normalized.padRight(normalized.length + (4 - normalized.length % 4) % 4, '=');
      final decoded = utf8.decode(base64.decode(padded));
      return jsonDecode(decoded) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}
