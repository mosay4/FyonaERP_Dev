import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart' show dioProvider;
import '../../../core/security/device_identity.dart';
import '../data/models/auth_response.dart';
import 'auth2_models.dart';

/// Raw HTTP surface of `/api/v1/auth2` (contract v2 in docs/AUTH_PLAN.md).
/// Proofs (nonce + signature) are computed by [Auth2Service]; this layer only
/// moves JSON. Every failure is an [Auth2Exception].
abstract class Auth2Api {
  Future<String> nonce(String deviceId);

  Future<OtpChallenge> registerStart({
    required String fullName,
    required String phoneE164,
    required String password,
    required DeviceDescriptor device,
    required String idempotencyKey,
  });

  Future<OtpStatus> otpStatus(String challengeId);

  Future<OtpChallenge> otpResend(String challengeId, {String? channel});

  Future<Auth2Authenticated> registerVerify({
    required String challengeId,
    required String code,
    required String nonce,
    required String signature,
  });

  Future<Auth2LoginResult> login({
    required String phoneE164,
    required String password,
    required DeviceDescriptor device,
    String? nonce,
    String? signature,
  });

  Future<OtpChallenge> loginVerifyStart({
    required String verificationId,
    required String channel,
  });

  Future<Auth2Authenticated> loginVerify({
    required String challengeId,
    required String code,
    required String nonce,
    required String signature,
  });

  Future<Auth2LoginResult> social({
    required String provider,
    required String idToken,
    String? authorizationCode,
    String? rawNonce,
    String? fullName,
    required DeviceDescriptor device,
    String? nonce,
    String? signature,
  });

  Future<OtpChallenge> socialPhoneStart({
    required String socialSession,
    required String phoneE164,
    required String idempotencyKey,
  });

  Future<Auth2Authenticated> socialPhoneVerify({
    required String challengeId,
    required String code,
    required String nonce,
    required String signature,
  });

  Future<List<PendingApproval>> pendingApprovals();

  Future<ApprovalCode> approvalCode(
    String approvalId, {
    required String nonce,
    required String signature,
  });

  Future<void> denyApproval(String approvalId);

  Future<List<TrustedDevice>> devices();
  Future<void> revokeDevice(String deviceId);
  Future<void> renameDevice(String deviceId, String name);
  Future<void> makePrimary(
    String deviceId, {
    required String nonce,
    required String signature,
  });
  Future<DateTime?> claimPrimary();
  Future<void> cancelClaimPrimary();

  Future<OtpChallenge> phoneChangeStart({
    required String newPhoneE164,
    String? password,
    required String nonce,
    required String signature,
    required String idempotencyKey,
  });

  /// Returns the updated user JSON.
  Future<Map<String, dynamic>> phoneChangeVerify({
    required String challengeId,
    required String code,
  });

  Future<OtpChallenge> passwordForgot({
    required String phoneE164,
    required DeviceDescriptor device,
  });

  /// Confirms the account password from this trusted device (app-lock PIN
  /// reset). Throws [Auth2Exception] on a wrong password.
  Future<void> reauth(String password);

  /// AuthResponse when the server signs the user in, null for a plain "ok".
  Future<Auth2Authenticated?> passwordReset({
    required String challengeId,
    required String code,
    required String newPassword,
  });
}

/// Parses an AuthResponse (+ `device:{device_id,is_primary,trusted}`).
Auth2Authenticated parseAuthenticated(Map<String, dynamic> json) {
  final device = json['device'] is Map
      ? Map<String, dynamic>.from(json['device'] as Map)
      : const <String, dynamic>{};
  return Auth2Authenticated(
    AuthResponse.fromJson(json),
    isPrimary: device['is_primary'] == true,
    trusted: device['trusted'] != false,
  );
}

/// Shared by login + social: tokens / needs_verification / needs_phone.
Auth2LoginResult parseLoginResult(Map<String, dynamic> json) {
  if (json['needs_verification'] == true) {
    return Auth2NeedsVerification(DeviceVerification.fromJson(json));
  }
  if (json['needs_phone'] == true) {
    return Auth2NeedsPhone((json['social_session'] ?? '').toString());
  }
  return parseAuthenticated(json);
}

class DioAuth2Api implements Auth2Api {
  DioAuth2Api(this._dio);

  final Dio _dio;
  static const _p = '/auth2';

  Future<Map<String, dynamic>> _post(String path, [Map<String, dynamic>? body]) =>
      _send(() => _dio.post(path, data: body ?? const <String, dynamic>{}));

  Future<dynamic> _getRaw(String path) async {
    try {
      final r = await _dio.get(path);
      return _unwrap(r.data);
    } on DioException catch (e) {
      throw _toError(e);
    }
  }

  Future<Map<String, dynamic>> _send(Future<Response> Function() call) async {
    try {
      final r = await call();
      final data = _unwrap(r.data);
      if (data is Map) return Map<String, dynamic>.from(data);
      return <String, dynamic>{};
    } on DioException catch (e) {
      throw _toError(e);
    }
  }

  /// Some deployments wrap payloads in `{success, data}`.
  static dynamic _unwrap(dynamic data) {
    if (data is Map && data.containsKey('success') && data['data'] != null) {
      return data['data'];
    }
    return data;
  }

  static Auth2Exception _toError(DioException e) {
    final resp = e.response;
    if (resp == null) {
      return const Auth2Exception(code: 'network');
    }
    return Auth2Exception.fromBody(resp.data, resp.statusCode);
  }

  @override
  Future<String> nonce(String deviceId) async {
    final j = await _post('$_p/device/nonce', {'device_id': deviceId});
    final n = (j['nonce'] ?? '').toString();
    if (n.isEmpty) throw const Auth2Exception(code: 'nonce_missing');
    return n;
  }

  @override
  Future<OtpChallenge> registerStart({
    required String fullName,
    required String phoneE164,
    required String password,
    required DeviceDescriptor device,
    required String idempotencyKey,
  }) async =>
      OtpChallenge.fromJson(await _post('$_p/register/start', {
        'full_name': fullName,
        'phone_e164': phoneE164,
        'password': password,
        'device': device.toJson(),
        'idempotency_key': idempotencyKey,
      }));

  @override
  Future<OtpStatus> otpStatus(String challengeId) async => OtpStatus.fromJson(
      await _post('$_p/otp/status', {'challenge_id': challengeId}));

  @override
  Future<OtpChallenge> otpResend(String challengeId, {String? channel}) async =>
      OtpChallenge.fromJson(await _post('$_p/otp/resend', {
        'challenge_id': challengeId,
        if (channel != null) 'channel': channel,
      }));

  @override
  Future<Auth2Authenticated> registerVerify({
    required String challengeId,
    required String code,
    required String nonce,
    required String signature,
  }) async =>
      parseAuthenticated(await _post('$_p/register/verify', {
        'challenge_id': challengeId,
        'code': code,
        'nonce': nonce,
        'signature': signature,
      }));

  @override
  Future<Auth2LoginResult> login({
    required String phoneE164,
    required String password,
    required DeviceDescriptor device,
    String? nonce,
    String? signature,
  }) async =>
      parseLoginResult(await _post('$_p/login', {
        'phone_e164': phoneE164,
        'password': password,
        'device': device.toJson(),
        if (nonce != null) 'nonce': nonce,
        if (signature != null) 'signature': signature,
      }));

  @override
  Future<OtpChallenge> loginVerifyStart({
    required String verificationId,
    required String channel,
  }) async =>
      OtpChallenge.fromJson(await _post('$_p/login/verify/start', {
        'verification_id': verificationId,
        'channel': channel,
      }));

  @override
  Future<Auth2Authenticated> loginVerify({
    required String challengeId,
    required String code,
    required String nonce,
    required String signature,
  }) async =>
      parseAuthenticated(await _post('$_p/login/verify', {
        'challenge_id': challengeId,
        'code': code,
        'nonce': nonce,
        'signature': signature,
      }));

  @override
  Future<Auth2LoginResult> social({
    required String provider,
    required String idToken,
    String? authorizationCode,
    String? rawNonce,
    String? fullName,
    required DeviceDescriptor device,
    String? nonce,
    String? signature,
  }) async =>
      parseLoginResult(await _post('$_p/social', {
        'provider': provider,
        'id_token': idToken,
        if (authorizationCode != null) 'authorization_code': authorizationCode,
        if (rawNonce != null) 'raw_nonce': rawNonce,
        if (fullName != null && fullName.isNotEmpty) 'full_name': fullName,
        'device': device.toJson(),
        if (nonce != null) 'nonce': nonce,
        if (signature != null) 'signature': signature,
      }));

  @override
  Future<OtpChallenge> socialPhoneStart({
    required String socialSession,
    required String phoneE164,
    required String idempotencyKey,
  }) async =>
      OtpChallenge.fromJson(await _post('$_p/social/phone/start', {
        'social_session': socialSession,
        'phone_e164': phoneE164,
        'idempotency_key': idempotencyKey,
      }));

  @override
  Future<Auth2Authenticated> socialPhoneVerify({
    required String challengeId,
    required String code,
    required String nonce,
    required String signature,
  }) async =>
      parseAuthenticated(await _post('$_p/social/phone/verify', {
        'challenge_id': challengeId,
        'code': code,
        'nonce': nonce,
        'signature': signature,
      }));

  @override
  Future<List<PendingApproval>> pendingApprovals() async {
    final data = await _getRaw('$_p/approvals/pending');
    final list = data is List
        ? data
        : (data is Map && data['items'] is List ? data['items'] as List : const []);
    return list
        .whereType<Map>()
        .map((m) => PendingApproval.fromJson(Map<String, dynamic>.from(m)))
        .where((a) => a.approvalId.isNotEmpty)
        .toList();
  }

  @override
  Future<ApprovalCode> approvalCode(
    String approvalId, {
    required String nonce,
    required String signature,
  }) async =>
      ApprovalCode.fromJson(await _post(
          '$_p/approvals/${Uri.encodeComponent(approvalId)}/code',
          {'nonce': nonce, 'signature': signature}));

  @override
  Future<void> denyApproval(String approvalId) async {
    await _post('$_p/approvals/${Uri.encodeComponent(approvalId)}/deny');
  }

  @override
  Future<List<TrustedDevice>> devices() async {
    final data = await _getRaw('$_p/devices');
    final list = data is List
        ? data
        : (data is Map && data['items'] is List ? data['items'] as List : const []);
    return list
        .whereType<Map>()
        .map((m) => TrustedDevice.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  @override
  Future<void> revokeDevice(String deviceId) async {
    await _post('$_p/devices/${Uri.encodeComponent(deviceId)}/revoke');
  }

  @override
  Future<void> renameDevice(String deviceId, String name) async {
    await _post('$_p/devices/${Uri.encodeComponent(deviceId)}/rename', {'name': name});
  }

  @override
  Future<void> makePrimary(
    String deviceId, {
    required String nonce,
    required String signature,
  }) async {
    await _post('$_p/devices/${Uri.encodeComponent(deviceId)}/make-primary',
        {'nonce': nonce, 'signature': signature});
  }

  @override
  Future<DateTime?> claimPrimary() async {
    final j = await _post('$_p/devices/claim-primary');
    return DateTime.tryParse(
            (j['applies_at'] ?? j['primary_claim_until'] ?? '').toString())
        ?.toLocal();
  }

  @override
  Future<void> cancelClaimPrimary() async {
    await _post('$_p/devices/claim-primary/cancel');
  }

  @override
  Future<OtpChallenge> phoneChangeStart({
    required String newPhoneE164,
    String? password,
    required String nonce,
    required String signature,
    required String idempotencyKey,
  }) async =>
      OtpChallenge.fromJson(await _post('$_p/phone/change/start', {
        'new_phone_e164': newPhoneE164,
        if (password != null && password.isNotEmpty) 'password': password,
        'nonce': nonce,
        'signature': signature,
        'idempotency_key': idempotencyKey,
      }));

  @override
  Future<Map<String, dynamic>> phoneChangeVerify({
    required String challengeId,
    required String code,
  }) async {
    final j = await _post('$_p/phone/change/verify',
        {'challenge_id': challengeId, 'code': code});
    final user = j['user'];
    return user is Map ? Map<String, dynamic>.from(user) : j;
  }

  @override
  Future<void> reauth(String password) async {
    await _post('$_p/reauth', {'password': password});
  }

  @override
  Future<OtpChallenge> passwordForgot({
    required String phoneE164,
    required DeviceDescriptor device,
  }) async =>
      OtpChallenge.fromJson(await _post('$_p/password/forgot', {
        'phone_e164': phoneE164,
        'device': device.toJson(),
      }));

  @override
  Future<Auth2Authenticated?> passwordReset({
    required String challengeId,
    required String code,
    required String newPassword,
  }) async {
    final j = await _post('$_p/password/reset', {
      'challenge_id': challengeId,
      'code': code,
      'new_password': newPassword,
    });
    final hasToken = (j['access_token'] ?? '').toString().isNotEmpty ||
        (j['data'] is Map && (j['data'] as Map)['access_token'] != null);
    return hasToken ? parseAuthenticated(j) : null;
  }
}

final auth2ApiProvider = Provider<Auth2Api>((ref) => DioAuth2Api(ref.watch(dioProvider)));
