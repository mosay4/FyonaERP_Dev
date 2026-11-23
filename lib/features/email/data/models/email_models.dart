class EmailLog {
  final int? id;
  final String to;
  final String subject;
  final String status;
  final DateTime? sentAt;
  final String? error;

  const EmailLog({
    this.id,
    required this.to,
    required this.subject,
    this.status = 'sent',
    this.sentAt,
    this.error,
  });

  factory EmailLog.fromJson(Map<String, dynamic> json) => EmailLog(
    id: json['id'] as int?,
    to: json['to'] as String? ?? '',
    subject: json['subject'] as String? ?? '',
    status: json['status'] as String? ?? 'sent',
    sentAt: DateTime.tryParse(json['sent_at'].toString()) ?? null,
    error: json['error'] as String?,
  );

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'to': to,
    'subject': subject,
    'status': status,
    if (sentAt != null) 'sent_at': sentAt!.toIso8601String(),
    if (error != null) 'error': error,
  };
}

class EmailSettings {
  final String host;
  final int port;
  final String username;
  final String password;
  final String encryption;
  final String fromAddress;
  final String fromName;

  const EmailSettings({
    required this.host,
    this.port = 587,
    required this.username,
    required this.password,
    this.encryption = 'tls',
    required this.fromAddress,
    this.fromName = '',
  });

  factory EmailSettings.fromJson(Map<String, dynamic> json) => EmailSettings(
    host: json['host'] as String? ?? '',
    port: json['port'] as int? ?? 587,
    username: json['username'] as String? ?? '',
    password: json['password'] as String? ?? '',
    encryption: json['encryption'] as String? ?? 'tls',
    fromAddress: json['from_address'] as String? ?? '',
    fromName: json['from_name'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'username': username,
    'password': password,
    'encryption': encryption,
    'from_address': fromAddress,
    'from_name': fromName,
  };
}
