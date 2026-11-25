import 'package:equatable/equatable.dart';

class SessionModel extends Equatable {
  final String id;
  final String userId;
  final String? ipAddress;
  final String? deviceInfo;
  final String? deviceModel;
  final String? osVersion;
  final String? appVersion;
  final String? platform;
  final String? fingerprint;
  final String? country;
  final String? region;
  final String? city;
  final bool isActive;
  final bool isCurrent;
  final bool isPrimary;
  final String? customName;
  final DateTime lastActivity;
  final DateTime createdAt;

  /// Server-side cap on devices per account (null on old servers).
  final int? sessionLimit;

  const SessionModel({
    required this.id,
    required this.userId,
    this.ipAddress,
    this.deviceInfo,
    this.deviceModel,
    this.osVersion,
    this.appVersion,
    this.platform,
    this.fingerprint,
    this.country,
    this.region,
    this.city,
    this.isActive = true,
    this.isCurrent = false,
    this.isPrimary = false,
    this.customName,
    required this.lastActivity,
    required this.createdAt,
    this.sessionLimit,
  });

  factory SessionModel.fromJson(Map<String, dynamic> json) {
    return SessionModel(
      id: json['id'].toString(),
      userId: json['user_id'].toString(),
      ipAddress: json['ip_address'] as String?,
      deviceInfo: json['device_info'] as String?,
      deviceModel: json['device_model'] as String?,
      osVersion: json['os_version'] as String?,
      appVersion: json['app_version'] as String?,
      platform: json['platform'] as String?,
      fingerprint: json['fingerprint'] as String?,
      country: json['country'] as String?,
      region: json['region'] as String?,
      city: json['city'] as String?,
      isActive: (json['is_active'] as bool?) ?? true,
      isCurrent: (json['is_current'] as bool?) ?? false,
      isPrimary: (json['is_primary'] as bool?) ?? false,
      customName: json['custom_name'] as String?,
      lastActivity: DateTime.tryParse(json['last_activity'].toString()) ?? DateTime.now(),
      createdAt: DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now(),
      sessionLimit: (json['session_limit'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'user_id': userId,
        if (ipAddress != null) 'ip_address': ipAddress,
        if (deviceInfo != null) 'device_info': deviceInfo,
        if (deviceModel != null) 'device_model': deviceModel,
        if (osVersion != null) 'os_version': osVersion,
        if (appVersion != null) 'app_version': appVersion,
        if (platform != null) 'platform': platform,
        if (fingerprint != null) 'fingerprint': fingerprint,
        if (country != null) 'country': country,
        if (region != null) 'region': region,
        if (city != null) 'city': city,
        'is_active': isActive,
        'is_current': isCurrent,
        'is_primary': isPrimary,
        if (customName != null) 'custom_name': customName,
        'last_activity': lastActivity.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
        if (sessionLimit != null) 'session_limit': sessionLimit,
      };

  /// Human-readable location, e.g. "اليمن، صنعاء" / empty when unknown.
  String get locationLabel {
    final parts = [
      if (country != null && country!.trim().isNotEmpty) country!.trim(),
      if (region != null && region!.trim().isNotEmpty) region!.trim(),
      if (city != null &&
          city!.trim().isNotEmpty &&
          city!.trim() != region?.trim())
        city!.trim(),
    ];
    return parts.join('، ');
  }

  @override
  List<Object?> get props => [id, userId, ipAddress, deviceInfo, deviceModel, osVersion, appVersion, platform, fingerprint, country, region, city, isActive, isCurrent, isPrimary, customName];
}
