import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../../../../core/network/dio_provider.dart';

class EmailTemplateService {
  final ApiClient apiClient;

  EmailTemplateService({required this.apiClient});

  Future<List<Map<String, dynamic>>> getTemplates() async {
    final resp = await apiClient.getSafe<List<dynamic>>('/email-templates');
    if (resp.data == null) return [];
    return (resp.data as List).whereType<Map<String, dynamic>>().toList();
  }

  Future<Map<String, dynamic>?> getTemplate(int id) async {
    final resp = await apiClient.getSafe<Map<String, dynamic>>('/email-templates/$id');
    return resp.data;
  }

  Future<Map<String, dynamic>> createTemplate(Map data) async {
    final resp = await apiClient.postSafe<Map<String, dynamic>>('/email-templates', data: data);
    if (resp.data == null) throw Exception(AppLocalizations.t('settingsTemplateCreationFailed'));
    return resp.data!;
  }

  Future<bool> updateTemplate(int id, Map data) async {
    await apiClient.putSafe('/email-templates/$id', data: data);
    return true;
  }

  Future<bool> deleteTemplate(int id) async {
    await apiClient.deleteSafe('/email-templates/$id');
    return true;
  }

  Future<String> previewTemplate(int id, Map<String, String> variables) async {
    final template = await getTemplate(id);
    if (template == null) return '';
    String body = template['body'] as String? ?? '';
    for (final entry in variables.entries) {
      body = body.replaceAll('{{${entry.key}}}', entry.value);
    }
    return body;
  }

  Future<bool> sendFromTemplate(int id, String to, Map<String, String> variables) async {
    await apiClient.postSafe('/email-templates/$id/send', data: {
      'to': to,
      'variables': variables,
    });
    return true;
  }
}
