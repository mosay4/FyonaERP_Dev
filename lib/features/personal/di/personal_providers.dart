import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/database/providers/database_providers.dart';
import '../../../core/database/repositories/personal_cache_repository.dart';
import '../../../core/network/dio_provider.dart';
import '../../../core/services/sync_engine.dart';
import '../../auth/di/auth_providers.dart';
import '../domain/services/personal_finance_service.dart';
import '../domain/services/backup_service.dart';

final personalFinanceServiceProvider = Provider<PersonalFinanceService>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final repo = ref.watch(personalRepositoryProvider);
  final cache = ref.watch(personalCacheRepositoryProvider);
  final service = PersonalFinanceService(apiClient: apiClient, repo: repo, cache: cache);
  // Local-First wiring: every local commit schedules a background
  // SyncEngine push. Fire-and-forget — the UI never waits for it.
  service.requestSync = () {
    try {
      return ref.read(syncEngineProvider).processQueue();
    } catch (_) {
      return Future.value();
    }
  };
  final userId = ref.watch(authProvider).user?.id;
  if (userId != null && userId.isNotEmpty) {
    // Canonical namespace, resolved synchronously (warmed stable id or
    // deterministic FNV fallback). The backstop warm below only fills the
    // in-memory mapping and migrates gap rows, then re-points the service —
    // the namespace can only move toward canonical, never flip-flop.
    service.setUserId(PersonalCacheRepository.stableIdSync(userId));
    try {
      cache.warmStableId(userId).then((uid) {
        if (uid > 0) {
          service.setUserId(PersonalCacheRepository.stableIdSync(userId));
        }
      });
    } catch (_) {}
  }
  return service;
});

final backupServiceProvider = Provider<BackupService>((ref) {
  final repo = ref.watch(personalRepositoryProvider);
  final financeService = ref.watch(personalFinanceServiceProvider);
  final apiClient = ref.watch(apiClientProvider);
  final svc = BackupService(repo: repo, financeService: financeService, apiClient: apiClient);
  // Bind the real session identity so auto paths never snapshot as a
  // fallback user. Rebuilt automatically when auth state changes.
  final userId = ref.watch(authProvider).user?.id ?? '';
  if (userId.isNotEmpty) {
    try {
      svc.bindIdentity(
        localUserId: financeService.currentUserId,
        serverUserUuid: userId,
      );
    } catch (_) {}
  }
  return svc;
});