import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/network/dio_provider.dart';
import '../../data/models/subscription_models.dart';

class SubscriptionServiceImpl {
  final ApiClient apiClient;

  SubscriptionServiceImpl({required this.apiClient});

  Future<List<SubscriptionPlan>> getPlans() async {
    final resp = await apiClient.getSafe<List<dynamic>>('/subscription/plans');
    if (resp.data == null) return [];
    return (resp.data as List).map((j) => SubscriptionPlan.fromJson(j as Map<String, dynamic>)).toList();
  }

  Future<SubscriptionPlan?> getPlan(int id) async {
    final resp = await apiClient.getSafe<Map<String, dynamic>>('/subscription/plans/$id');
    if (resp.data == null) return null;
    return SubscriptionPlan.fromJson(resp.data!);
  }

  Future<Map<String, dynamic>> subscribe(
    int planId, {
    String? period,
    String? currency,
    double? amount,
    Uint8List? proofImage,
    String? proofFileName,
    List<Map<String, dynamic>>? proofFiles,
  }) async {
    final formData = FormData();
    formData.fields.add(MapEntry('plan_id', '$planId'));
    formData.fields.add(MapEntry('period', period ?? 'yearly'));
    // The exact currency (and optional amount) the user chose at checkout —
    // stored on the request so the admin always sees the REAL currency.
    final cur = (currency ?? '').trim().toUpperCase();
    if (cur.isNotEmpty) formData.fields.add(MapEntry('currency', cur));
    if (amount != null && amount > 0) {
      formData.fields.add(MapEntry('amount', amount.toStringAsFixed(2)));
    }
    // Attach ALL proofs (multiple `proof_images` fields).
    final files = (proofFiles?.isNotEmpty ?? false) ? proofFiles! : <Map<String, dynamic>>[];
    if (files.isEmpty && proofImage != null) {
      formData.files.add(MapEntry(
        'proof_images',
        MultipartFile.fromBytes(proofImage, filename: proofFileName ?? 'proof.jpg'),
      ));
    }
    for (final f in files) {
      final bytes = f['bytes'] as Uint8List?;
      final name = f['name'] as String? ?? 'proof.jpg';
      if (bytes != null) {
        formData.files.add(MapEntry('proof_images', MultipartFile.fromBytes(bytes, filename: name)));
      }
    }
    // Force multipart so the global JSON default never conflicts with Dio's
    // boundary handling (guarantees the multiplex files are always received).
    // Give this specific upload a generous send/receive window so a heavy
    // receipt on a slow link NEVER aborts with "انتهت مهلة الطلب" — while the
    // rest of the app keeps its fast 10/30s defaults.
    final resp = await apiClient.postSafe<Map<String, dynamic>>(
      '/subscription/subscribe',
      data: formData,
      options: Options(
        contentType: 'multipart/form-data',
        sendTimeout: const Duration(seconds: 60),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );
    if (!resp.success) throw Exception(resp.message ?? AppLocalizations.t('subSubmitFailed'));
    return {'success': true, 'message': resp.message};
  }

  Future<Map<String, dynamic>> getStatus() async {
    final resp = await apiClient.getSafe<Map<String, dynamic>>('/subscription/status');
    return resp.data ?? {};
  }

  Future<List<BillingRecord>> getBillingHistory({int page = 1, int pageSize = 20}) async {
    throw UnsupportedError(AppLocalizations.t('subBillingUnsupported'));
  }

  Future<List<SubscriptionRequest>> getPendingRequests({int page = 1, int pageSize = 20}) async {
    final resp = await apiClient.getSafe<Map<String, dynamic>>('/admin/subscription-requests');
    final data = resp.data;
    final requests = data?['requests'];
    if (requests is List) {
      return requests.map((j) => SubscriptionRequest.fromJson(j as Map<String, dynamic>)).toList();
    }
    return [];
  }

  /// Latest subscription invoices of the current user (newest first).
  Future<List<Map<String, dynamic>>> getInvoices() async {
    final resp = await apiClient.getSafe<List<dynamic>>('/subscription-invoices');
    if (resp.data == null) return [];
    return (resp.data as List)
        .whereType<Map>()
        .map((j) => Map<String, dynamic>.from(j))
        .toList();
  }

  /// Admin approval with the full required payment record. Request ids are
  /// UUID strings on the backend; the backend validates bank, currency,
  /// amount and package before activating anything.
  Future<void> approveRequest(
    String requestId, {
    required String bankAccountId,
    required String planId,
    required String currency,
    required double amount,
  }) async {
    final resp = await apiClient.putSafe<Map<String, dynamic>>(
      '/admin/subscription-requests/$requestId/approve',
      data: {
        'bank_account_id': bankAccountId,
        'plan_id': planId,
        'currency': currency,
        'amount': amount,
      },
    );
    if (!resp.success) throw Exception(resp.message ?? 'تعذر اعتماد الطلب');
  }

  Future<void> rejectRequest(String requestId, {String? reason}) async {
    final resp = await apiClient.putSafe<Map<String, dynamic>>(
      '/admin/subscription-requests/$requestId/reject',
      data: {if (reason != null && reason.isNotEmpty) 'reason': reason},
    );
    if (!resp.success) throw Exception(resp.message ?? 'تعذر رفض الطلب');
  }

  Future<Map<String, dynamic>> activateTrial({String? mode}) async {
    final resp = await apiClient.postSafe<Map<String, dynamic>>('/subscription/trial', data: {'mode': mode ?? 'personal'});
    if (!resp.success) throw Exception(resp.message ?? 'فشل تفعيل التجربة');
    return resp.data ?? {};
  }

  Future<int> getDaysRemaining() async {
    final status = await getStatus();
    return status['days_remaining'] as int? ?? 0;
  }

  Future<List<StripePlan>> getStripePlans({String? currency}) async {
    final resp = await apiClient.getSafe<Map<String, dynamic>>(
      ApiEndpoints.stripePlans,
      queryParameters: {if (currency != null && currency.isNotEmpty) 'currency': currency},
    );
    final data = resp.data;
    final plans = data?['plans'];
    if (plans is List) {
      return plans
          .whereType<Map>()
          .map((j) => StripePlan.fromJson(Map<String, dynamic>.from(j)))
          .toList();
    }
    return [];
  }

  Future<({List<StripePlan> plans, bool enabled})> getStripePaymentState({String? currency}) async {
    final resp = await apiClient.getSafe<Map<String, dynamic>>(
      ApiEndpoints.stripePlans,
      queryParameters: {if (currency != null && currency.isNotEmpty) 'currency': currency},
    );
    final data = resp.data;
    final plansJson = data?['plans'];
    final plans = plansJson is List
        ? plansJson.whereType<Map>().map((j) => StripePlan.fromJson(Map<String, dynamic>.from(j))).toList()
        : <StripePlan>[];
    return (plans: plans, enabled: data?['stripe_enabled'] as bool? ?? false);
  }

  Future<StripePaymentIntent> createStripePaymentIntent(
    String planId, {
    String period = 'yearly',
    String? currency,
    String? idempotencyKey,
  }) async {
    final resp = await apiClient.postSafe<Map<String, dynamic>>(
      ApiEndpoints.stripePaymentIntent,
      data: {
        'plan_id': planId,
        'period': period,
        if (currency != null && currency.isNotEmpty) 'target_currency': currency,
        if (idempotencyKey != null && idempotencyKey.isNotEmpty) 'idempotency_key': idempotencyKey,
      },
    );
    final data = resp.data ?? <String, dynamic>{};
    final intent = StripePaymentIntent.fromJson(data);
    if (!intent.isValid) {
      throw Exception(resp.message ?? AppLocalizations.t('subIntentFailed'));
    }
    return intent;
  }

  Future<Map<String, dynamic>> confirmStripePayment({String? paymentIntentId, String? paymentId}) async {
    final resp = await apiClient.postSafe<Map<String, dynamic>>(
      '/payments/stripe/confirm',
      data: {
        if (paymentIntentId != null && paymentIntentId.isNotEmpty) 'payment_intent_id': paymentIntentId,
        if (paymentId != null && paymentId.isNotEmpty) 'payment_id': paymentId,
      },
    );
    if (!resp.success) throw Exception(resp.message ?? 'فشل تأكيد الدفع');
    return resp.data ?? {};
  }

  // ── Auto-renew (independent layer — one-time methods above untouched) ──

  /// SetupIntent client secret (+ publishable key) for saving a card
  /// (explicit consent is collected in-app first). Card data never touches
  /// FYONA.
  Future<Map<String, String>> createAutoRenewSetupIntent() async {
    final resp = await apiClient.postSafe<Map<String, dynamic>>(
      ApiEndpoints.stripeSetupIntent,
      data: const {},
    );
    if (!resp.success) throw Exception(resp.message ?? 'تعذر بدء حفظ البطاقة');
    final data = resp.data ?? {};
    final secret = data['client_secret']?.toString() ?? '';
    if (secret.isEmpty) throw Exception(resp.message ?? 'تعذر بدء حفظ البطاقة');
    return {
      'client_secret': secret,
      'publishable_key': data['publishable_key']?.toString() ?? '',
    };
  }

  /// Enable auto-renewal after SetupIntent success + explicit consent.
  Future<Map<String, dynamic>> enableAutoRenew({
    required String planId,
    required String period,
    required String paymentMethodId,
    required bool consent,
  }) async {
    final resp = await apiClient.postSafe<Map<String, dynamic>>(
      ApiEndpoints.stripeAutoRenewEnable,
      data: {
        'plan_id': planId,
        'period': period,
        'payment_method_id': paymentMethodId,
        'consent': consent,
      },
    );
    if (!resp.success) throw Exception(resp.message ?? 'تعذر تفعيل التجديد التلقائي');
    return resp.data ?? {};
  }

  /// Auto-save the card that just paid + arm the renewal (invoice start tap).
  /// The backend resolves the paid charge and reuses the charged method.
  Future<Map<String, dynamic>> activateAutoRenewFromInvoice({
    String? invoiceNo,
    String? paymentIntentId,
  }) async {
    final resp = await apiClient.postSafe<Map<String, dynamic>>(
      ApiEndpoints.stripeAutoRenewActivate,
      data: {
        if (invoiceNo != null && invoiceNo.trim().isNotEmpty)
          'invoice_no': invoiceNo.trim(),
        if (paymentIntentId != null && paymentIntentId.trim().isNotEmpty)
          'payment_intent_id': paymentIntentId.trim(),
      },
    );
    if (!resp.success) throw Exception(resp.message ?? 'تعذر تفعيل التجديد التلقائي');
    return resp.data ?? {};
  }

  /// Stop the next renewal (subscription stays active until period end).
  Future<Map<String, dynamic>> disableAutoRenew() async {
    final resp = await apiClient.postSafe<Map<String, dynamic>>(
      ApiEndpoints.stripeAutoRenewDisable,
      data: const {},
    );
    if (!resp.success) throw Exception(resp.message ?? 'تعذر إيقاف التجديد التلقائي');
    return resp.data ?? {};
  }

  /// Renewal state + safe card display (brand/last4 only).
  Future<Map<String, dynamic>> autoRenewStatus() async {
    final resp = await apiClient.getSafe<Map<String, dynamic>>(
      ApiEndpoints.stripeAutoRenewStatus,
    );
    if (!resp.success) throw Exception(resp.message ?? 'تعذر جلب حالة التجديد');
    return resp.data ?? {};
  }

  Future<bool> hasFeature(String feature) async {
    final status = await getStatus();
    if (status['status'] != 'active') return false;
    final features = status['features'] as List? ?? [];
    return features.contains(feature) || status['is_trial'] == true;
  }
}
