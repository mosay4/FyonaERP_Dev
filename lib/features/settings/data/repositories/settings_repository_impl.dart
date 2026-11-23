import '../../../../core/network/dio_provider.dart';
import '../../../../core/network/api_client.dart';
import '../models/settings_model.dart';
import '../../domain/repositories/settings_repository.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';

class SettingsRepositoryImpl implements SettingsRepository {
  final ApiClient _apiClient;
  SettingsRepositoryImpl({required this._apiClient});

  @override
  Future<CompanySettings> getCompanySettings() async {
    final resp = await _apiClient.getSafe<Map<String, dynamic>>('/admin/settings');
    if (resp.success && resp.data != null) return CompanySettings.fromJson(resp.data!);
    return const CompanySettings();
  }

  @override
  Future<void> updateCompanySettings(CompanySettings settings) async {
    await _apiClient.putSafe('/admin/settings', data: settings.toJson());
  }

  @override
  Future<List<TaxSetting>> getTaxSettings() async {
    throw UnsupportedError(AppLocalizations.t('settingsTaxSettingsAreNot'));
  }

  @override
  Future<void> updateTaxSettings(List<TaxSetting> taxes) async {
    throw UnsupportedError(AppLocalizations.t('settingsTaxSettingsAreNot2'));
  }

  @override
  Future<List<CurrencySetting>> getCurrencySettings() async {
    final resp = await _apiClient.getSafe<Map<String, dynamic>>('/admin/currencies');
    final data = resp.data;
    final map = data?['currencies'];
    if (map is Map) {
      return map.entries.map((e) {
        final cfg = (e.value as Map?) ?? const <String, dynamic>{};
        return CurrencySetting(
          currency: e.key as String,
          name: cfg['name'] as String?,
          symbol: cfg['symbol'] as String?,
          rate: (cfg['rate'] as num?)?.toDouble() ?? 1.0,
        );
      }).toList();
    }
    return [];
  }

  @override
  Future<void> updateCurrencySettings(List<CurrencySetting> currencies) async {
    final resp = await _apiClient.getSafe<Map<String, dynamic>>('/admin/currencies');
    final data = resp.data;
    final existing = (data?['currencies'] is Map)
        ? (data!['currencies'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    for (final c in currencies) {
      final code = c.currency.toUpperCase();
      final current = existing[code] as Map?;
      if (current == null) {
        await _apiClient.postSafe<Map<String, dynamic>>('/admin/currencies', data: {
          'code': code,
          'name': c.name ?? code,
          'symbol': c.symbol ?? '',
          'enabled': true,
          'rate': c.rate,
        });
      } else {
        final oldRate = (current['rate'] as num?)?.toDouble() ?? 1.0;
        final oldName = current['name'] as String?;
        final oldSymbol = current['symbol'] as String?;
        if ((c.rate - oldRate).abs() > 0.0001) {
          await _apiClient.putSafe<Map<String, dynamic>>('/admin/currencies/$code/rate', data: {'rate': c.rate});
        }
        if (c.name != oldName || c.symbol != oldSymbol) {
          await _apiClient.putSafe<Map<String, dynamic>>('/admin/currencies/$code', data: {
            if (c.name != null) 'name': c.name,
            if (c.symbol != null) 'symbol': c.symbol,
          });
        }
      }
    }
  }
}
