import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/providers/database_providers.dart';
import '../../../../core/network/dio_provider.dart';
import '../../auth/di/auth_providers.dart';
import '../domain/services/notification_service.dart';

final notificationServiceProvider = Provider<NotificationServiceImpl>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final repo = ref.watch(settingsRepositoryProvider);
  final userId = ref.watch(authProvider).user?.id;
  final service = NotificationServiceImpl(apiClient: apiClient, localRepo: repo);
  if (userId != null) {
    final parsed = int.tryParse(userId);
    service.userId = parsed ?? _intFromUserId(userId);
  }
  return service;
});

/// Deterministic small-integer mapping for the local notifications cache.
int _intFromUserId(String s) {
  var h = 0x811C9DC5;
  for (var i = 0; i < s.length; i++) {
    h ^= s.codeUnitAt(i);
    h = (h * 0x01000193) & 0x7FFFFFFF;
  }
  return h;
}