import '../../network/api_client.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../interfaces/all_services.dart';

class OrganizationServiceImpl implements OrganizationService {
  final ApiClient? apiClient;

  OrganizationServiceImpl({this.apiClient});

  @override
  Future<Map<String, dynamic>> getOrganization(int orgId) async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get('/api/organizations/$orgId');
        return response.data as Map<String, dynamic>;
      } catch (e) {
        throw Exception(AppLocalizations.t('orgLoadFailed', {'error': e.toString()}));
      }
    }
    return {'id': orgId, 'name': 'شركة التقنية المتطورة', 'email': 'info@techcorp.sa', 'phone': '+966500000000', 'address': 'الرياض، المملكة العربية السعودية', 'tax_number': '310123456700003', 'cr_number': '1010234567', 'logo': null, 'created_at': '2024-01-01'};
  }

  @override
  Future<bool> updateOrganization(int orgId, Map<String, dynamic> data) async {
    if (apiClient != null) {
      try {
        await apiClient!.put('/api/organizations/$orgId', data: data);
        return true;
      } catch (e) {
        throw Exception(AppLocalizations.t('orgUpdateFailed', {'error': e.toString()}));
      }
    }
    throw Exception(AppLocalizations.t('permNoServer'));
  }

  @override
  Future<Map<String, dynamic>> getOrganizationSettings(int orgId) async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get('/api/organizations/$orgId/settings');
        return response.data as Map<String, dynamic>;
      } catch (e) {
        throw Exception(AppLocalizations.t('orgSettingsLoadFailed', {'error': e.toString()}));
      }
    }
    return {'language': 'ar', 'currency': 'SAR', 'timezone': 'Asia/Riyadh', 'date_format': 'YYYY-MM-DD', 'tax_inclusive': true, 'rounding': 2};
  }

  @override
  Future<bool> updateOrganizationSettings(int orgId, Map<String, dynamic> data) async {
    if (apiClient != null) {
      try {
        await apiClient!.put('/api/organizations/$orgId/settings', data: data);
        return true;
      } catch (e) {
        throw Exception(AppLocalizations.t('orgSettingsUpdateFailed', {'error': e.toString()}));
      }
    }
    throw Exception(AppLocalizations.t('permNoServer'));
  }

  @override
  Future<List<Map<String, dynamic>>> getBranches(int orgId) async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get('/api/organizations/$orgId/branches');
        return (response.data as List).whereType<Map<String, dynamic>>().toList();
      } catch (e) {
        throw Exception(AppLocalizations.t('orgBranchesLoadFailed', {'error': e.toString()}));
      }
    }
    return [
      {'id': 1, 'name': 'الفرع الرئيسي', 'location': 'الرياض', 'phone': '+966500000001', 'is_active': true},
      {'id': 2, 'name': 'فرع جدة', 'location': 'جدة', 'phone': '+966500000002', 'is_active': true},
      {'id': 3, 'name': 'فرع الدمام', 'location': 'الدمام', 'phone': '+966500000003', 'is_active': false},
    ];
  }

  @override
  Future<Map<String, dynamic>> createBranch(Map<String, dynamic> data) async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.post('/api/organizations/${data['org_id']}/branches', data: data);
        return response.data as Map<String, dynamic>;
      } catch (e) {
        throw Exception(AppLocalizations.t('orgBranchCreateFailed', {'error': e.toString()}));
      }
    }
    throw Exception(AppLocalizations.t('permNoServer'));
  }

  @override
  Future<Map<String, dynamic>> getSubscriptionInfo(int orgId) async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get('/api/organizations/$orgId/subscription');
        return response.data as Map<String, dynamic>;
      } catch (e) {
        throw Exception(AppLocalizations.t('orgSubInfoFailed', {'error': e.toString()}));
      }
    }
    return {'plan': 'professional', 'status': 'active', 'start_date': '2024-01-01', 'end_date': '2025-12-31', 'days_remaining': 173, 'users_limit': 50, 'storage_limit': 10737418240, 'features': ['sales', 'purchases', 'accounting', 'hr', 'reports']};
  }
}
