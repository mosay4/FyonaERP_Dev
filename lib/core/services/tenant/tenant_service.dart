import '../../network/api_client.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../interfaces/all_services.dart';

class TenantServiceImpl implements TenantService {
  final ApiClient? apiClient;
  int? _currentOrgId;

  TenantServiceImpl({this.apiClient});

  @override
  Future<Map<String, dynamic>> getCurrentTenant() async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get('/api/tenant/current');
        return response.data as Map<String, dynamic>;
      } catch (e) {
        throw Exception(AppLocalizations.t('tenantCurrentFailed', {'error': e.toString()}));
      }
    }
    return {
      'id': 1,
      'name': 'FYONA HQ',
      'name_ar': 'مقر فيونا الرئيسي',
      'plan': 'premium',
      'status': 'active',
      'created_at': '2024-01-01T00:00:00Z',
    };
  }

  @override
  Future<bool> switchTenant(int orgId) async {
    if (apiClient != null) {
      try {
        await apiClient!.post('/api/tenant/switch', data: {'org_id': orgId});
        _currentOrgId = orgId;
        return true;
      } catch (e) {
        throw Exception(AppLocalizations.t('tenantSwitchFailed', {'error': e.toString()}));
      }
    }
    _currentOrgId = orgId;
    return true;
  }

  @override
  Future<bool> validateTenantAccess(int orgId) async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get(
          '/api/tenant/validate',
          queryParameters: {'org_id': orgId},
        );
        final data = response.data as Map<String, dynamic>;
        return data['valid'] as bool? ?? false;
      } catch (e) {
        throw Exception(AppLocalizations.t('tenantValidateFailed', {'error': e.toString()}));
      }
    }
    return orgId == 1 || orgId == _currentOrgId;
  }

  @override
  String getTenantIsolationKey() {
    if (_currentOrgId != null) return 'org:$_currentOrgId';
    return 'org:default';
  }

  @override
  Future<List<Map<String, dynamic>>> getAvailableTenants() async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get('/api/tenants');
        final data = response.data as List;
        return data.whereType<Map<String, dynamic>>().toList();
      } catch (e) {
        throw Exception(AppLocalizations.t('tenantListFailed', {'error': e.toString()}));
      }
    }
    return [
      {
        'id': 1,
        'name': 'FYONA HQ',
        'name_ar': 'مقر فيونا الرئيسي',
        'plan': 'premium',
        'role': 'owner',
      },
      {
        'id': 2,
        'name': 'Branch Alpha',
        'name_ar': 'فرع ألفا',
        'plan': 'business',
        'role': 'admin',
      },
    ];
  }
}
