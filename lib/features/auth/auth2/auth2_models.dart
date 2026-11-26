import '../data/models/auth_response.dart';

/// Error body of every auth2 endpoint:
/// `{detail:{code, message_ar, message_en, retry_after?}}`.
class Auth2Exception implements Exception {
  final String code;
  final String? messageAr;
  final String? messageEn;
  final int? retryAfter;
  final int? statusCode;

  const Auth2Exception({
    required this.code,
    this.messageAr,
    this.messageEn,
    this.retryAfter,
    this.statusCode,
  });

  bool get isNetwork => code == 'network';

  factory Auth2Exception.fromBody(dynamic body, int? status) {
    if (body is Map) {
      final detail = body['detail'];
      if (detail is Map) {
        return Auth2Exception(
          code: (detail['code'] ?? 'error').toString(),
          messageAr: detail['message_ar']?.toString(),
          messageEn: detail['message_en']?.toString(),
          retryAfter: _int(detail['retry_after']),
          statusCode: status,
        );
      }
      if (detail is String) {
        return Auth2Exception(
            code: 'error', messageAr: detail, messageEn: detail, statusCode: status);
      }
      final msg = body['message']?.toString();
      if (msg != null) {
        return Auth2Exception(
            code: 'error', messageAr: msg, messageEn: msg, statusCode: status);
      }
    }
    return Auth2Exception(code: 'error', statusCode: status);
  }

  @override
  String toString() => 'Auth2Exception($code, $statusCode)';
}

int? _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

/// OTP challenge as returned by every "start" endpoint (and /otp/resend).
class OtpChallenge {
  final String challengeId;
  final String channel; // whatsapp | sms | device
  final String status;
  final int resendAfter;
  final int expiresIn;
  final DateTime receivedAt;

  OtpChallenge({
    required this.challengeId,
    required this.channel,
    required this.status,
    required this.resendAfter,
    required this.expiresIn,
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();

  factory OtpChallenge.fromJson(Map<String, dynamic> j) => OtpChallenge(
        challengeId: (j['challenge_id'] ?? '').toString(),
        channel: (j['channel'] ?? 'whatsapp').toString(),
        status: (j['status'] ?? 'queued').toString(),
        resendAfter: _int(j['resend_after']) ?? 30,
        expiresIn: _int(j['expires_in']) ?? 300,
      );

  DateTime get expiresAt => receivedAt.add(Duration(seconds: expiresIn));
  DateTime get resendAt => receivedAt.add(Duration(seconds: resendAfter));
}

class OtpStatus {
  final String status;
  final String channel;
  final bool canRequestSms;
  final int? resendAfter;

  const OtpStatus({
    required this.status,
    required this.channel,
    required this.canRequestSms,
    this.resendAfter,
  });

  factory OtpStatus.fromJson(Map<String, dynamic> j) => OtpStatus(
        status: (j['status'] ?? 'queued').toString(),
        channel: (j['channel'] ?? 'whatsapp').toString(),
        canRequestSms: j['can_request_sms'] == true,
        resendAfter: _int(j['resend_after']),
      );

  bool get isTerminal =>
      status == 'verified' || status == 'expired' || status == 'locked';
}

class PrimaryDeviceRef {
  final String name;
  final String model;
  const PrimaryDeviceRef({required this.name, required this.model});

  factory PrimaryDeviceRef.fromJson(Map<String, dynamic>? j) => PrimaryDeviceRef(
        name: (j?['name'] ?? '').toString(),
        model: (j?['model'] ?? '').toString(),
      );

  String get label {
    if (name.isEmpty) return model;
    if (model.isEmpty || model == name || name.contains(model)) return name;
    return '$name · $model';
  }
}

class DeviceVerification {
  final String verificationId;
  final List<String> options;
  final PrimaryDeviceRef? primaryDevice;

  const DeviceVerification({
    required this.verificationId,
    required this.options,
    this.primaryDevice,
  });

  factory DeviceVerification.fromJson(Map<String, dynamic> j) =>
      DeviceVerification(
        verificationId: (j['verification_id'] ?? '').toString(),
        options: ((j['options'] as List?) ?? const ['device', 'whatsapp'])
            .map((e) => e.toString())
            // Never SMS for new-device login, whatever the server sends.
            .where((e) => e == 'device' || e == 'whatsapp')
            .toList(),
        primaryDevice: j['primary_device'] is Map
            ? PrimaryDeviceRef.fromJson(
                Map<String, dynamic>.from(j['primary_device'] as Map))
            : null,
      );

  bool get canUseDevice => options.contains('device');
}

/// Result of /auth2/login and /auth2/social.
sealed class Auth2LoginResult {
  const Auth2LoginResult();
}

class Auth2Authenticated extends Auth2LoginResult {
  final AuthResponse response;
  final bool isPrimary;
  final bool trusted;
  const Auth2Authenticated(this.response,
      {this.isPrimary = false, this.trusted = true});
}

class Auth2NeedsVerification extends Auth2LoginResult {
  final DeviceVerification verification;
  const Auth2NeedsVerification(this.verification);
}

class Auth2NeedsPhone extends Auth2LoginResult {
  final String socialSession;
  const Auth2NeedsPhone(this.socialSession);
}

class PendingApproval {
  final String approvalId;
  final String deviceName;
  final String deviceModel;
  final String os;
  final String osVersion;
  final String? locationHint;
  final DateTime createdAt;
  final DateTime expiresAt;

  const PendingApproval({
    required this.approvalId,
    required this.deviceName,
    required this.deviceModel,
    required this.os,
    required this.osVersion,
    required this.locationHint,
    required this.createdAt,
    required this.expiresAt,
  });

  factory PendingApproval.fromJson(Map<String, dynamic> j) {
    final d = j['device'] is Map
        ? Map<String, dynamic>.from(j['device'] as Map)
        : const <String, dynamic>{};
    final created =
        DateTime.tryParse((j['created_at'] ?? '').toString())?.toLocal() ??
            DateTime.now();
    final expires =
        DateTime.tryParse((j['expires_at'] ?? '').toString())?.toLocal() ??
            created.add(const Duration(minutes: 5));
    final loc = j['location_hint']?.toString().trim();
    return PendingApproval(
      approvalId: (j['approval_id'] ?? '').toString(),
      deviceName: (d['name'] ?? '').toString(),
      deviceModel: (d['model'] ?? '').toString(),
      os: (d['os'] ?? '').toString(),
      osVersion: (d['os_version'] ?? '').toString(),
      locationHint: (loc == null || loc.isEmpty) ? null : loc,
      createdAt: created,
      expiresAt: expires,
    );
  }

  bool isExpired([DateTime? now]) => !(now ?? DateTime.now()).isBefore(expiresAt);
}

class ApprovalCode {
  final String code;
  final DateTime expiresAt;
  const ApprovalCode({required this.code, required this.expiresAt});

  factory ApprovalCode.fromJson(Map<String, dynamic> j) => ApprovalCode(
        code: (j['code'] ?? '').toString(),
        expiresAt:
            DateTime.tryParse((j['expires_at'] ?? '').toString())?.toLocal() ??
                DateTime.now().add(const Duration(minutes: 5)),
      );
}

class TrustedDevice {
  final String deviceId;
  final String name;
  final String model;
  final String os;
  final String osVersion;
  final String appVersion;
  final bool isPrimary;
  final bool trusted;
  final DateTime? lastSeen;
  final DateTime? createdAt;
  final bool current;
  final DateTime? primaryClaimUntil;

  const TrustedDevice({
    required this.deviceId,
    required this.name,
    required this.model,
    required this.os,
    required this.osVersion,
    required this.appVersion,
    required this.isPrimary,
    required this.trusted,
    required this.lastSeen,
    required this.createdAt,
    required this.current,
    this.primaryClaimUntil,
  });

  factory TrustedDevice.fromJson(Map<String, dynamic> j) => TrustedDevice(
        deviceId: (j['device_id'] ?? j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        model: (j['model'] ?? '').toString(),
        os: (j['os'] ?? '').toString(),
        osVersion: (j['os_version'] ?? '').toString(),
        appVersion: (j['app_version'] ?? '').toString(),
        isPrimary: j['is_primary'] == true,
        trusted: j['trusted'] != false,
        lastSeen: DateTime.tryParse((j['last_seen'] ?? '').toString())?.toLocal(),
        createdAt:
            DateTime.tryParse((j['created_at'] ?? '').toString())?.toLocal(),
        current: j['current'] == true,
        primaryClaimUntil: DateTime.tryParse(
                (j['primary_claim_until'] ?? j['claim_applies_at'] ?? '')
                    .toString())
            ?.toLocal(),
      );

  TrustedDevice copyWith({String? name}) => TrustedDevice(
        deviceId: deviceId,
        name: name ?? this.name,
        model: model,
        os: os,
        osVersion: osVersion,
        appVersion: appVersion,
        isPrimary: isPrimary,
        trusted: trusted,
        lastSeen: lastSeen,
        createdAt: createdAt,
        current: current,
        primaryClaimUntil: primaryClaimUntil,
      );
}
