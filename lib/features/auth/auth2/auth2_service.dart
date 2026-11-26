import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/security/device_identity.dart';
import 'auth2_api.dart';
import 'auth2_models.dart';

/// Device-proof purposes (docs/AUTH_PLAN.md → "Proof purposes").
abstract final class ProofPurpose {
  static const registerVerify = 'register_verify';
  static const login = 'login';
  static const loginVerify = 'login_verify';
  static const social = 'social';
  static const socialPhoneVerify = 'social_phone_verify';
  static const refresh = 'refresh';
  static const approvalCode = 'approval_code';
  static const makePrimary = 'make_primary';
  static const phoneChange = 'phone_change';
}

class DeviceProof {
  final String nonce;
  final String signature;
  const DeviceProof(this.nonce, this.signature);
}

/// auth2 calls with the device descriptor and fresh device proofs attached.
class Auth2Service {
  Auth2Service(this.api, this.identity);

  final Auth2Api api;
  final DeviceKeyIdentity identity;

  static String newIdempotencyKey() => const Uuid().v4();

  Future<DeviceProof> proof(String purpose) async {
    final id = await identity.deviceId();
    final nonce = await api.nonce(id);
    final sig = await identity.signProof(nonce: nonce, purpose: purpose);
    return DeviceProof(nonce, sig);
  }

  Future<OtpChallenge> registerStart({
    required String fullName,
    required String phoneE164,
    required String password,
    required String idempotencyKey,
  }) async =>
      api.registerStart(
        fullName: fullName,
        phoneE164: phoneE164,
        password: password,
        device: await identity.descriptor(),
        idempotencyKey: idempotencyKey,
      );

  Future<Auth2Authenticated> registerVerify(String challengeId, String code) async {
    final p = await proof(ProofPurpose.registerVerify);
    return api.registerVerify(
        challengeId: challengeId, code: code, nonce: p.nonce, signature: p.signature);
  }

  Future<Auth2LoginResult> login(String phoneE164, String password) async {
    final device = await identity.descriptor();
    DeviceProof? p;
    try {
      p = await proof(ProofPurpose.login);
    } on Auth2Exception catch (e) {
      // A device unknown to the server may get no nonce: log in without a
      // proof (the server then asks for verification).
      if (e.isNetwork) rethrow;
    }
    return api.login(
      phoneE164: phoneE164,
      password: password,
      device: device,
      nonce: p?.nonce,
      signature: p?.signature,
    );
  }

  Future<OtpChallenge> loginVerifyStart(String verificationId, String channel) =>
      api.loginVerifyStart(verificationId: verificationId, channel: channel);

  Future<Auth2Authenticated> loginVerify(String challengeId, String code) async {
    final p = await proof(ProofPurpose.loginVerify);
    return api.loginVerify(
        challengeId: challengeId, code: code, nonce: p.nonce, signature: p.signature);
  }

  Future<Auth2LoginResult> social({
    required String provider,
    required String idToken,
    String? authorizationCode,
    String? rawNonce,
    String? fullName,
  }) async {
    final device = await identity.descriptor();
    DeviceProof? p;
    try {
      p = await proof(ProofPurpose.social);
    } on Auth2Exception catch (e) {
      if (e.isNetwork) rethrow;
    }
    return api.social(
      provider: provider,
      idToken: idToken,
      authorizationCode: authorizationCode,
      rawNonce: rawNonce,
      fullName: fullName,
      device: device,
      nonce: p?.nonce,
      signature: p?.signature,
    );
  }

  Future<OtpChallenge> socialPhoneStart(
          String socialSession, String phoneE164, String idempotencyKey) =>
      api.socialPhoneStart(
          socialSession: socialSession,
          phoneE164: phoneE164,
          idempotencyKey: idempotencyKey);

  Future<Auth2Authenticated> socialPhoneVerify(String challengeId, String code) async {
    final p = await proof(ProofPurpose.socialPhoneVerify);
    return api.socialPhoneVerify(
        challengeId: challengeId, code: code, nonce: p.nonce, signature: p.signature);
  }

  Future<void> reauth(String password) => api.reauth(password);

  Future<ApprovalCode> approvalCode(String approvalId) async {
    final p = await proof(ProofPurpose.approvalCode);
    return api.approvalCode(approvalId, nonce: p.nonce, signature: p.signature);
  }

  Future<void> makePrimary(String deviceId) async {
    final p = await proof(ProofPurpose.makePrimary);
    await api.makePrimary(deviceId, nonce: p.nonce, signature: p.signature);
  }

  Future<OtpChallenge> phoneChangeStart({
    required String newPhoneE164,
    String? password,
    required String idempotencyKey,
  }) async {
    final p = await proof(ProofPurpose.phoneChange);
    return api.phoneChangeStart(
      newPhoneE164: newPhoneE164,
      password: password,
      nonce: p.nonce,
      signature: p.signature,
      idempotencyKey: idempotencyKey,
    );
  }

  Future<OtpChallenge> passwordForgot(String phoneE164) async =>
      api.passwordForgot(phoneE164: phoneE164, device: await identity.descriptor());
}

final auth2ServiceProvider = Provider<Auth2Service>((ref) =>
    Auth2Service(ref.watch(auth2ApiProvider), ref.watch(deviceKeyIdentityProvider)));
