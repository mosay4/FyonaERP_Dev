import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../core/network/api_client.dart' show serverBaseUrlProvider;
import '../../../../core/offline/offline_guard.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../data/models/subscription_models.dart';
import '../../domain/subscription_errors.dart';
import '../../di/subscription_providers.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../domain/business_offline_access.dart';
import '../../domain/personal_offline_access.dart';

const _plansCacheKey = 'subscription_plans_cache';

Future<List<SubscriptionPlan>> _plansFromCache() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_plansCacheKey);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List;
    return list
        .whereType<Map>()
        .map((j) => SubscriptionPlan.fromJson(Map<String, dynamic>.from(j)))
        .toList();
  } catch (_) {
    return [];
  }
}

Future<void> _plansToCache(List<SubscriptionPlan> plans) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(plans.map((p) => p.toJson()).toList());
    await prefs.setString(_plansCacheKey, raw);
  } catch (_) {}
}

/// Live plans from the backend; on ANY failure (offline) it returns the last
/// successfully-synced prices cached locally — so disabling the internet never
/// flashes the hard-coded fallback prices that differ from the admin's real
/// prices. Only when NO cache has ever been saved does it fall back to the
/// server's own default list (guaranteeing the plans screen always renders).
final subscriptionPlansProvider = FutureProvider<List<SubscriptionPlan>>((ref) async {
  final service = ref.watch(subscriptionServiceProvider);
  try {
    final plans = await service.getPlans();
    if (plans.isNotEmpty) unawaited(_plansToCache(plans));
    return plans;
  } catch (_) {
    final cached = await _plansFromCache();
    if (cached.isNotEmpty) return cached;
    rethrow;
  }
});

final subscriptionPlanDetailProvider = FutureProvider.family<SubscriptionPlan?, int>((ref, id) async {
  final service = ref.watch(subscriptionServiceProvider);
  return service.getPlan(id);
});

final personalOfflineAccessProvider = Provider<PersonalOfflineAccess>((ref) {
  final service = ref.watch(subscriptionServiceProvider);
  return PersonalOfflineAccess(service.apiClient.dio.options.baseUrl);
});

final businessOfflineAccessProvider = Provider<BusinessOfflineAccess>((ref) {
  return BusinessOfflineAccess(ref.watch(serverBaseUrlProvider));
});

final savedBusinessStatusProvider =
    FutureProvider<Map<String, dynamic>?>((ref) async {
      final user = ref.watch(currentUserProvider);
      if (user == null || !user.isActive) return null;
      final access = ref.watch(businessOfflineAccessProvider);
      final branch = ref.watch(directoryPilotAccessProvider);
      final store = branch == null ? null : ref.watch(directoryPilotStoreProvider);
      final saved = await access.read(user);
      if (saved != null || branch == null) return saved;
      // In-place upgrades may already have the existing per-branch grant.
      return store!.entry(branch);
    });

final businessNavigationStatusProvider =
    FutureProvider<Map<String, dynamic>?>((ref) {
      final live = ref.watch(subscriptionStatusProvider);
      final status = live.asData?.value;
      if (status != null) return status;
      if (live.hasError && !isConnectivityError(live.error!)) return null;
      return ref.watch(savedBusinessStatusProvider.future);
    });

final subscriptionStatusProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final service = ref.watch(subscriptionServiceProvider);
  final local = ref.watch(personalOfflineAccessProvider);
  final businessLocal = ref.watch(businessOfflineAccessProvider);
  final account = ref.watch(authProvider.select((auth) => auth.isAuthenticated
      ? (auth.user?.id, auth.user?.organizationId)
      : (null, null)));
  final pilot = ref.read(directoryPilotAccessProvider);
  final pilotStore = pilot == null ? null : ref.read(directoryPilotStoreProvider);
  final status = await service.getStatus();
  if (pilot != null &&
      sameDirectoryScope(pilot, ref.read(directoryPilotAccessProvider))) {
    await pilotStore!.remember(pilot, status);
  }
  final userId = account.$1;
  if (userId != null && userId.isNotEmpty) {
    try {
      await businessLocal.remember(userId, account.$2, status);
      ref.invalidate(savedBusinessStatusProvider);
    } catch (_) {}
    try {
      await local.remember(userId, account.$2, status);
    } catch (_) {
      // Local storage problems must not interfere with an online response.
    }
  }
  return status;
});

final billingHistoryProvider = FutureProvider<List<BillingRecord>>((ref) async {
  final service = ref.watch(subscriptionServiceProvider);
  return service.getBillingHistory();
});

final pendingRequestsProvider = FutureProvider<List<SubscriptionRequest>>((ref) async {
  final service = ref.watch(subscriptionServiceProvider);
  return service.getPendingRequests();
});

final subscriptionInvoicesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final service = ref.watch(subscriptionServiceProvider);
  return service.getInvoices();
});

/// A bank-transfer subscription the user is about to send. Stored BEFORE
/// navigating to the waiting screen so that screen can upload the receipt in
/// the background — the user reaches the waiting list in the SAME second they
/// tap "Send".
class PendingReceiptSubmission {
  final int planId;
  final String period;
  final String currency;
  final double? amount;
  final List<Map<String, dynamic>> proofFiles;
  const PendingReceiptSubmission({
    required this.planId,
    required this.period,
    required this.currency,
    this.amount,
    required this.proofFiles,
  });
}

class ReceiptUploadState {
  final bool uploading;
  final String? error;
  final bool succeeded;
  const ReceiptUploadState({
    this.uploading = false,
    this.error,
    this.succeeded = false,
  });
  const ReceiptUploadState.idle() : this();
  const ReceiptUploadState.running() : this(uploading: true);
  const ReceiptUploadState.failed(String message)
      : this(error: message);
  const ReceiptUploadState.done() : this(succeeded: true);
}

class PendingReceiptNotifier extends StateNotifier<PendingReceiptSubmission?> {
  PendingReceiptNotifier() : super(null);

  void submit(PendingReceiptSubmission s) => state = s;

  void clear() => state = null;
}

final pendingReceiptProvider = StateNotifierProvider<PendingReceiptNotifier, PendingReceiptSubmission?>(
    (ref) => PendingReceiptNotifier());

class ReceiptUploadNotifier extends StateNotifier<ReceiptUploadState> {
  ReceiptUploadNotifier(this._ref) : super(const ReceiptUploadState.idle());
  final Ref _ref;

  Future<bool> run(PendingReceiptSubmission submission) async {
    if (state.uploading) return false;
    state = const ReceiptUploadState.running();
    try {
      final service = _ref.read(subscriptionServiceProvider);
      await service.subscribe(
        submission.planId,
        period: submission.period,
        currency: submission.currency,
        amount: submission.amount,
        proofFiles: submission.proofFiles,
      );
      state = const ReceiptUploadState.done();
      return true;
    } catch (e) {
      state = ReceiptUploadState.failed(localizeSubscriptionError(e));
      return false;
    }
  }

  void reset() => state = const ReceiptUploadState.idle();
}

/// Background upload of the bank-transfer receipt. Runs on the WAITING screen
/// so the user feels an instant transition; failures surface there with a
/// retry instead of leaving the user stranded.
final receiptUploadProvider =
    StateNotifierProvider<ReceiptUploadNotifier, ReceiptUploadState>(
        (ref) => ReceiptUploadNotifier(ref));
