class MfaStatusModel {
  final bool enabled;
  final String? secretKey;
  final String? qrCodeUrl;
  final List<String>? backupCodes;

  const MfaStatusModel({
    this.enabled = false,
    this.secretKey,
    this.qrCodeUrl,
    this.backupCodes,
  });

  factory MfaStatusModel.fromJson(Map<String, dynamic> json) => MfaStatusModel(
    enabled: json['enabled'] as bool? ?? false,
    secretKey: json['secret_key'] as String?,
    qrCodeUrl: json['qr_code_url'] as String?,
    backupCodes: (json['backup_codes'] as List<dynamic>?)?.whereType<String>().toList(),
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled, if (secretKey != null) 'secret_key': secretKey,
    if (qrCodeUrl != null) 'qr_code_url': qrCodeUrl,
    if (backupCodes != null) 'backup_codes': backupCodes,
  };
}
