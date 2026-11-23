import '../../network/api_client.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../interfaces/all_services.dart';

class QuotaServiceImpl implements QuotaService {
  final ApiClient? apiClient;
  final Map<String, int> _usage = {};

  static const _planLimits = <String, Map<String, int>>{
    'trial': {
      'employees': 5,
      'invoices': 50,
      'products': 100,
      'customers': 100,
      'suppliers': 50,
      'storage_mb': 100,
    },
    'business': {
      'employees': 50,
      'invoices': 500,
      'products': 1000,
      'customers': 1000,
      'suppliers': 500,
      'storage_mb': 1000,
    },
    'premium': {
      'employees': -1,
      'invoices': -1,
      'products': -1,
      'customers': -1,
      'suppliers': -1,
      'storage_mb': 10000,
    },
  };

  QuotaServiceImpl({this.apiClient});

  int get limitSentinel => -1;

  @override
  Future<Map<String, dynamic>> getQuota(String feature) async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get(
          '/api/quota/$feature',
        );
        return response.data as Map<String, dynamic>;
      } catch (e) {
        throw Exception(AppLocalizations.t('quotaLoadFailed', {'error': e.toString()}));
      }
    }
    final limit = _getLimitForFeature(feature);
    final used = _usage[feature] ?? 0;
    final remaining = limit == -1 ? -1 : (limit - used).clamp(0, limit);
    return {
      'feature': feature,
      'limit': limit,
      'used': used,
      'remaining': remaining,
      'unlimited': limit == -1,
    };
  }

  @override
  Future<bool> checkQuota(String feature) async {
    if (apiClient != null) {
      try {
        final quota = await getQuota(feature);
        final limit = quota['limit'] as int;
        final used = quota['used'] as int;
        return limit == -1 || used < limit;
      } catch (e) {
        throw Exception(AppLocalizations.t('quotaCheckFailed', {'error': e.toString()}));
      }
    }
    final limit = _getLimitForFeature(feature);
    if (limit == -1) return true;
    final used = _usage[feature] ?? 0;
    return used < limit;
  }

  @override
  Future<bool> incrementUsage(String feature) async {
    if (apiClient != null) {
      try {
        await apiClient!.post('/api/quota/$feature/increment');
        return true;
      } catch (e) {
        throw Exception(AppLocalizations.t('quotaIncrementFailed', {'error': e.toString()}));
      }
    }
    _usage[feature] = (_usage[feature] ?? 0) + 1;
    return true;
  }

  @override
  Future<Map<String, Map<String, dynamic>>> getAllQuotas() async {
    if (apiClient != null) {
      try {
        final response = await apiClient!.get('/api/quota');
        final data = response.data as Map<String, dynamic>;
        return data.map(
          (k, v) => MapEntry(k, v as Map<String, dynamic>),
        );
      } catch (e) {
        throw Exception(AppLocalizations.t('quotaLoadAllFailed', {'error': e.toString()}));
      }
    }
    const features = ['employees', 'invoices', 'products', 'customers', 'suppliers', 'storage_mb'];
    final result = <String, Map<String, dynamic>>{};
    for (final f in features) {
      result[f] = await getQuota(f);
    }
    return result;
  }

  @override
  Map<String, int> getPlanLimits(String plan) {
    return Map.from(_planLimits[plan] ?? _planLimits['trial']!);
  }

  int _getLimitForFeature(String feature) {
    for (final limits in _planLimits.values) {
      if (limits.containsKey(feature)) return limits[feature]!;
    }
    return 0;
  }
}
