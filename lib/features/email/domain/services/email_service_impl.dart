import '../../../../core/network/api_client.dart';
import '../../../../core/services/interfaces/all_services.dart';
import '../../data/models/email_models.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';

class EmailServiceImpl implements EmailService {
  final ApiClient _apiClient;

  EmailServiceImpl({required this._apiClient});

  @override
  Future<void> send(String to, String subject, String body, {bool isHtml = false}) async {
    throw UnsupportedError(AppLocalizations.t('emailSendingMailIsNot'));
  }

  @override
  Future<List<EmailLog>> getLogs({int page = 1, int pageSize = 50}) async {
    throw UnsupportedError(AppLocalizations.t('emailMailLogIsNot'));
  }

  @override
  Future<void> sendPasswordReset(String to, String token) async {
    throw UnsupportedError(AppLocalizations.t('emailPasswordResetViaMail'));
  }

  Future<EmailSettings> getSettings() async {
    final response = await _apiClient.get('/admin/email/config');
    final json = response.data as Map<String, dynamic>? ?? const {};
    return EmailSettings(
      host: json['smtp_host'] as String? ?? '',
      port: json['smtp_port'] as int? ?? 587,
      username: json['smtp_user'] as String? ?? '',
      password: json['smtp_password'] as String? ?? '',
      fromAddress: json['smtp_from'] as String? ?? '',
    );
  }

  Future<void> updateSettings(EmailSettings settings) async {
    await _apiClient.put('/admin/email/config', data: {
      'smtp_host': settings.host,
      'smtp_port': settings.port,
      'smtp_user': settings.username,
      if (settings.password.isNotEmpty) 'smtp_password': settings.password,
      'smtp_from': settings.fromAddress,
    });
  }

  Future<void> testConnection(EmailSettings settings) async {
    final to = settings.username.contains('@') ? settings.username : settings.fromAddress;
    await _apiClient.post('/admin/email/test', data: {
      'to': to,
      'subject': 'Fyona Test Email',
      'body': 'This is a test email from Fyona admin panel.',
    });
  }
}
