import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../../../../core/network/dio_provider.dart';

class CustomFieldService {
  final ApiClient apiClient;

  CustomFieldService({required this.apiClient});

  Future<List<Map<String, dynamic>>> getFields(String entityType) async {
    final resp = await apiClient.getSafe<List<dynamic>>('/custom-fields', queryParameters: {'entity_type': entityType});
    if (resp.data == null) return [];
    return (resp.data as List).whereType<Map<String, dynamic>>().toList();
  }

  Future<Map<String, dynamic>> createField(Map data) async {
    final resp = await apiClient.postSafe<Map<String, dynamic>>('/custom-fields', data: data);
    if (resp.data == null) throw Exception(AppLocalizations.t('settingsFieldCreationFailed'));
    return resp.data!;
  }

  Future<bool> updateField(int id, Map data) async {
    await apiClient.putSafe('/custom-fields/$id', data: data);
    return true;
  }

  Future<bool> deleteField(int id) async {
    await apiClient.deleteSafe('/custom-fields/$id');
    return true;
  }

  Future<dynamic> getFieldValue(int entityId, String fieldName) async {
    final resp = await apiClient.getSafe<Map<String, dynamic>>('/custom-fields/value', queryParameters: {'entity_id': entityId, 'field_name': fieldName});
    return resp.data?['value'];
  }

  Future<bool> setFieldValue(int entityId, String fieldName, dynamic value) async {
    await apiClient.postSafe('/custom-fields/value', data: {'entity_id': entityId, 'field_name': fieldName, 'value': value});
    return true;
  }
}
