import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../interfaces/all_services.dart';
import 'user_preferences_service.dart';

final userPreferencesServiceProvider = Provider<UserPreferencesService>((ref) {
  return UserPreferencesServiceImpl(apiClient: null);
});
