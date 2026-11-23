import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../network/api_client.dart';
import '../storage/secure_storage.dart';
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';

// ── Storage ──
final secureStorageProvider = Provider<SecureStorageService>((ref) {
  return SecureStorageService();
});

// ── Network ──
// dioProvider is defined in ../network/api_client.dart with AppConfig.apiBaseUrl + AuthInterceptor.
// We re-export it from there. apiClientProvider wraps it.
final apiClientProvider = Provider<ApiClient>((ref) {
  ref.watch(branchEpochProvider);
  return ApiClient(dio: ref.watch(dioProvider));
});
