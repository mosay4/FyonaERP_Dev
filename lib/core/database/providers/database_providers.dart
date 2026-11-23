import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../repositories/personal_repository.dart';
import '../repositories/personal_cache_repository.dart';
import '../repositories/settings_repository.dart';

final personalRepositoryProvider = Provider<PersonalRepository>((ref) {
  return PersonalRepository();
});

final personalCacheRepositoryProvider = Provider<PersonalCacheRepository>((ref) {
  return PersonalCacheRepository();
});

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SettingsRepository();
});
