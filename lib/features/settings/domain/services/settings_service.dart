import '../../data/models/settings_model.dart';
import '../repositories/settings_repository.dart';

class SettingsService {
  final SettingsRepository repository;

  SettingsService(this.repository);

  Future<CompanySettings> getCompanySettings() async {
    return repository.getCompanySettings();
  }

  Future<void> updateCompanySettings(CompanySettings s) async {
    await repository.updateCompanySettings(s);
  }

  Future<List<TaxSetting>> getTaxSettings() async {
    return repository.getTaxSettings();
  }

  Future<void> updateTaxSettings(List<TaxSetting> taxes) async {
    await repository.updateTaxSettings(taxes);
  }

  Future<List<CurrencySetting>> getCurrencySettings() async {
    return repository.getCurrencySettings();
  }

  Future<void> updateCurrencySettings(List<CurrencySetting> currencies) async {
    await repository.updateCurrencySettings(currencies);
  }
}
