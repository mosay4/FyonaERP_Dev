import '../../network/api_client.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../interfaces/all_services.dart';

class TrashServiceImpl implements TrashService {
  final ApiClient? apiClient;

  TrashServiceImpl({this.apiClient});

  String _entityLabel(String type) {
    switch (type) {
      case 'customer':
        return AppLocalizations.t('customers');
      case 'supplier':
        return AppLocalizations.t('suppliers');
      case 'invoice':
        return AppLocalizations.t('invoices');
      case 'product':
        return AppLocalizations.t('products');
      default:
        return AppLocalizations.t('trashItem');
    }
  }

  @override
  Future<List<Map<String, dynamic>>> getTrashedItems({String? entityType, int page = 1}) async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get(
          '/api/trash',
          queryParameters: {
            'page': page,
            'entity_type': ?entityType,
          },
        );
        final data = response.data as List<dynamic>;
        return data.whereType<Map<String, dynamic>>().toList();
      } catch (e) {
        throw Exception(AppLocalizations.t('trashLoadFailed', {'error': e.toString()}));
      }
    }
    final types = entityType != null ? {entityType} : const ['customer', 'supplier', 'invoice', 'product'];
    final result = <Map<String, dynamic>>[];
    for (final type in types) {
      for (int i = 1; i <= 3; i++) {
        result.add({
          'id': i,
          'entity_type': type,
          'entity_label': _entityLabel(type),
          'name': '${_entityLabel(type)} ${AppLocalizations.t('trashDeleted', {'count': i.toString()})}',
          'deleted_at': DateTime.now().subtract(Duration(days: i)).toIso8601String(),
          'deleted_by': AppLocalizations.t('manager'),
        });
      }
    }
    return result;
  }

  @override
  Future<bool> restoreItem(String entityType, int id) async {
    if (apiClient != null) {
      try {
        await apiClient!.post('/api/trash/restore', data: {
          'entity_type': entityType,
          'id': id,
        });
        return true;
      } catch (e) {
        throw Exception(AppLocalizations.t('trashRestoreFailed', {'error': e.toString()}));
      }
    }
    throw Exception(AppLocalizations.t('permNoServer'));
  }

  @override
  Future<bool> permanentlyDelete(String entityType, int id) async {
    if (apiClient != null) {
      try {
        await apiClient!.delete('/api/trash', data: {
          'entity_type': entityType,
          'id': id,
        });
        return true;
      } catch (e) {
        throw Exception(AppLocalizations.t('trashDeleteFailed', {'error': e.toString()}));
      }
    }
    throw Exception(AppLocalizations.t('permNoServer'));
  }

  @override
  Future<bool> emptyTrash() async {
    if (apiClient != null) {
      try {
        await apiClient!.post('/api/trash/empty');
        return true;
      } catch (e) {
        throw Exception(AppLocalizations.t('trashEmptyFailed', {'error': e.toString()}));
      }
    }
    throw Exception(AppLocalizations.t('permNoServer'));
  }

  @override
  Future<Map<String, int>> getTrashStats() async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get('/api/trash/stats');
        final data = response.data as Map<String, dynamic>;
        return data.map((k, v) => MapEntry(k, v as int));
      } catch (e) {
        throw Exception(AppLocalizations.t('trashStatsFailed', {'error': e.toString()}));
      }
    }
    return {
      'customer': 3,
      'supplier': 2,
      'invoice': 5,
      'product': 4,
    };
  }
}
