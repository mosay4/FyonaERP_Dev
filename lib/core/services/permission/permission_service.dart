import '../../network/api_client.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../interfaces/all_services.dart';

class PermissionServiceImpl implements PermissionService {
  final ApiClient? apiClient;

  PermissionServiceImpl({this.apiClient});

  Map<String, List<Map<String, dynamic>>> get _allPermissions => {
        'sales': [
          {'code': 'sales.view', 'name': AppLocalizations.t('permSalesView'), 'group': AppLocalizations.t('permGroupSales'), 'description': AppLocalizations.t('permSalesViewDesc')},
          {'code': 'sales.create', 'name': AppLocalizations.t('permSalesCreate'), 'group': AppLocalizations.t('permGroupSales'), 'description': AppLocalizations.t('permSalesCreateDesc')},
          {'code': 'sales.edit', 'name': AppLocalizations.t('permSalesEdit'), 'group': AppLocalizations.t('permGroupSales'), 'description': AppLocalizations.t('permSalesEditDesc')},
        ],
        'purchases': [
          {'code': 'purchases.view', 'name': AppLocalizations.t('permPurchaseView'), 'group': AppLocalizations.t('permGroupPurchases'), 'description': AppLocalizations.t('permPurchaseViewDesc')},
        ],
        'employees': [
          {'code': 'employees.manage', 'name': AppLocalizations.t('permEmployeesManage'), 'group': AppLocalizations.t('permGroupEmployees'), 'description': AppLocalizations.t('permEmployeesManageDesc')},
        ],
        'reports': [
          {'code': 'reports.export', 'name': AppLocalizations.t('permReportsExport'), 'group': AppLocalizations.t('permGroupReports'), 'description': AppLocalizations.t('permReportsExportDesc')},
        ],
        'settings': [
          {'code': 'settings.edit', 'name': AppLocalizations.t('permSettingsEdit'), 'group': AppLocalizations.t('permGroupSettings'), 'description': AppLocalizations.t('permSettingsEditDesc')},
        ],
        'admin': [
          {'code': 'admin.access', 'name': AppLocalizations.t('permAdminAccess'), 'group': AppLocalizations.t('permGroupAdmin'), 'description': AppLocalizations.t('permAdminAccessDesc')},
        ],
      };

  @override
  Future<List<String>> getUserPermissions(int userId) async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get('/api/permissions/user/$userId');
        return (response.data as List).whereType<String>().toList();
      } catch (e) {
        throw Exception(AppLocalizations.t('permLoadUserFailed', {'error': e.toString()}));
      }
    }
    return ['sales.view', 'sales.create', 'purchases.view', 'reports.export'];
  }

  @override
  Future<bool> hasPermission(int userId, String permission) async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get('/api/permissions/user/$userId/check', queryParameters: {'permission': permission});
        return response.data as bool;
      } catch (e) {
        throw Exception(AppLocalizations.t('permCheckFailed', {'error': e.toString()}));
      }
    }
    final perms = await getUserPermissions(userId);
    return perms.contains(permission);
  }

  @override
  Future<List<String>> getRolePermissions(String role) async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get('/api/permissions/role/$role');
        return (response.data as List).whereType<String>().toList();
      } catch (e) {
        throw Exception(AppLocalizations.t('permLoadRoleFailed', {'error': e.toString()}));
      }
    }
    switch (role) {
      case 'admin':
        return ['sales.view', 'sales.create', 'sales.edit', 'purchases.view', 'employees.manage', 'reports.export', 'settings.edit', 'admin.access'];
      case 'manager':
        return ['sales.view', 'sales.create', 'purchases.view', 'employees.manage', 'reports.export'];
      case 'accountant':
        return ['sales.view', 'purchases.view', 'reports.export'];
      default:
        return ['sales.view'];
    }
  }

  @override
  Future<bool> assignPermission(int userId, String permission) async {
    if (apiClient != null) {
      try {
        await apiClient!.post('/api/permissions/user/$userId/assign', data: {'permission': permission});
        return true;
      } catch (e) {
        throw Exception(AppLocalizations.t('permAssignFailed', {'error': e.toString()}));
      }
    }
    throw Exception(AppLocalizations.t('permNoServer'));
  }

  @override
  Future<bool> revokePermission(int userId, String permission) async {
    if (apiClient != null) {
      try {
        await apiClient!.post('/api/permissions/user/$userId/revoke', data: {'permission': permission});
        return true;
      } catch (e) {
        throw Exception(AppLocalizations.t('permRevokeFailed', {'error': e.toString()}));
      }
    }
    throw Exception(AppLocalizations.t('permNoServer'));
  }

  @override
  Future<List<Map<String, dynamic>>> getAllPermissions() async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get('/api/permissions');
        return (response.data as List).whereType<Map<String, dynamic>>().toList();
      } catch (e) {
        throw Exception(AppLocalizations.t('permLoadAllFailed', {'error': e.toString()}));
      }
    }
    return _allPermissions.values.expand((p) => p).toList();
  }
}
