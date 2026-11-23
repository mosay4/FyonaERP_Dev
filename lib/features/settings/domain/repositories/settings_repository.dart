import '../../data/models/settings_model.dart';

abstract class SettingsRepository {
  Future<CompanySettings> getCompanySettings();
  Future<void> updateCompanySettings(CompanySettings settings);
  Future<List<TaxSetting>> getTaxSettings();
  Future<void> updateTaxSettings(List<TaxSetting> taxes);
  Future<List<CurrencySetting>> getCurrencySettings();
  Future<void> updateCurrencySettings(List<CurrencySetting> currencies);
}
