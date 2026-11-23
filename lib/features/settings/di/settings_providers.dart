import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/dio_provider.dart';
import '../data/repositories/settings_repository_impl.dart';
import '../domain/services/settings_service.dart';

final settingsServiceProvider = Provider<SettingsService>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return SettingsService(SettingsRepositoryImpl(apiClient: apiClient));
});
