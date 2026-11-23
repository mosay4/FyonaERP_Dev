import '../../network/api_client.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../interfaces/all_services.dart';

class UserPreferencesServiceImpl implements UserPreferencesService {
  final ApiClient? apiClient;

  UserPreferencesServiceImpl({this.apiClient});

  static const Map<String, dynamic> _defaults = {
    'language': 'ar',
    'theme': 'dark',
    'notifications': true,
    'currency': 'SAR',
    'date_format': 'YYYY-MM-DD',
    'items_per_page': 20,
    'dashboard_layout': 'grid',
    'receipt_printer': 'default',
  };

  @override
  Future<dynamic> getPreference(String key, {dynamic defaultValue}) async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get('/api/preferences/$key');
        return response.data['value'];
      } catch (e) {
        throw Exception(AppLocalizations.t('prefLoadFailed', {'error': e.toString()}));
      }
    }
    return _defaults[key] ?? defaultValue;
  }

  @override
  Future<bool> setPreference(String key, dynamic value) async {
    if (apiClient != null) {
      try {
        await apiClient!.put('/api/preferences/$key', data: {'value': value});
        return true;
      } catch (e) {
        throw Exception(AppLocalizations.t('prefSaveFailed', {'error': e.toString()}));
      }
    }
    throw Exception(AppLocalizations.t('permNoServer'));
  }

  @override
  Future<Map<String, dynamic>> getAllPreferences() async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get('/api/preferences');
        return response.data as Map<String, dynamic>;
      } catch (e) {
        throw Exception(AppLocalizations.t('prefLoadAllFailed', {'error': e.toString()}));
      }
    }
    return Map<String, dynamic>.from(_defaults);
  }

  @override
  Future<bool> resetPreference(String key) async {
    if (apiClient != null) {
      try {
        await apiClient!.delete('/api/preferences/$key');
        return true;
      } catch (e) {
        throw Exception(AppLocalizations.t('prefResetFailed', {'error': e.toString()}));
      }
    }
    throw Exception(AppLocalizations.t('permNoServer'));
  }

  @override
  Future<Map<String, dynamic>> getPreferencesByGroup(String group) async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get('/api/preferences', queryParameters: {'group': group});
        return response.data as Map<String, dynamic>;
      } catch (e) {
        throw Exception(AppLocalizations.t('prefGroupFailed', {'error': e.toString()}));
      }
    }
    switch (group) {
      case 'display':
        return {'theme': _defaults['theme'], 'dashboard_layout': _defaults['dashboard_layout'], 'items_per_page': _defaults['items_per_page']};
      case 'language':
        return {'language': _defaults['language'], 'date_format': _defaults['date_format'], 'currency': _defaults['currency']};
      case 'notifications':
        return {'notifications': _defaults['notifications']};
      case 'printing':
        return {'receipt_printer': _defaults['receipt_printer']};
      default:
        return {};
    }
  }
}
