import 'package:equatable/equatable.dart';

/// Plan keys map to the backend's numeric plan ids (see `/subscription/subscribe`).
/// The keys are strings ("personal"/"business"/"premium") used in navigation and
/// the API status; they must never be parsed as numbers directly.
enum PlanKey {
  personal(1),
  business(2),
  premium(3);

  const PlanKey(this.backendId);

  final int backendId;

  static PlanKey? fromKey(String? key) {
    if (key == null) return null;
    for (final k in PlanKey.values) {
      if (k.name == key) return k;
    }
    return null;
  }
}

class SubscriptionPlan extends Equatable {
  final String id;
  final String name;
  final String? description;
  /// Canonical package identity from the backend (free|personal|business|premium).
  final String packageType;
  final int durationDays;
  final double priceMonthly;
  final double priceYearly;
  final String currency;
  final List<String> features;
  final String? color;
  final String? icon;
  final bool isActive;

  const SubscriptionPlan({
    this.id = '',
    required this.name,
    this.description,
    this.packageType = 'personal',
    this.durationDays = 365,
    this.priceMonthly = 0,
    this.priceYearly = 0,
    this.currency = 'USD',
    this.features = const [],
    this.color,
    this.icon,
    this.isActive = true,
  });

  factory SubscriptionPlan.fromJson(Map<String, dynamic> json) => SubscriptionPlan(
        id: json['id']?.toString() ?? '',
        name: json['name'] as String? ?? '',
        description: json['description'] as String?,
        packageType: (json['package_type'] as String?)?.toLowerCase() ?? 'personal',
        durationDays: (json['duration_days'] as num?)?.toInt() ?? 365,
        priceMonthly: (json['price_monthly'] as num?)?.toDouble() ?? 0,
        priceYearly: (json['price_yearly'] as num?)?.toDouble() ?? 0,
        currency: (json['currency'] as String?)?.toUpperCase() ?? 'USD',
        features: (json['features'] as List<dynamic>?)?.whereType<String>().toList() ?? [],
        color: json['color'] as String?,
        icon: json['icon'] as String?,
        isActive: json['is_active'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (description != null) 'description': description,
        'package_type': packageType,
        'duration_days': durationDays,
        'price_monthly': priceMonthly,
        'price_yearly': priceYearly,
        'currency': currency,
        'features': features,
        if (color != null) 'color': color,
        if (icon != null) 'icon': icon,
        'is_active': isActive,
      };

  @override
  List<Object?> get props => [id, name, packageType, priceMonthly, priceYearly, currency];
}

class StripePlan extends Equatable {
  final String? id;
  final String name;
  final String? nameEn;
  final String? description;
  final double priceMonthly;
  final double priceYearly;
  final String currency;
  final List<String> features;
  final String? color;
  final String? icon;
  final bool isActive;
  final String? stripeProductId;
  final String? stripePriceIdMonthly;
  final String? stripePriceIdYearly;
  final double? stripeAmountMonthly;
  final double? stripeAmountYearly;
  final String? stripeCurrency;
  // Server-quoted prices in the requested currency (quotes come from backend FX).
  final double? quoteAmountMonthly;
  final double? quoteAmountYearly;
  final String? quoteCurrency;
  final String? quoteChargeCurrency;
  final double? quoteFxRate;
  final String? quoteFxSource;
  final bool quoteFallbackUsd;

  const StripePlan({
    this.id,
    required this.name,
    this.nameEn,
    this.description,
    this.priceMonthly = 0,
    this.priceYearly = 0,
    this.currency = 'SAR',
    this.features = const [],
    this.color,
    this.icon,
    this.isActive = true,
    this.stripeProductId,
    this.stripePriceIdMonthly,
    this.stripePriceIdYearly,
    this.stripeAmountMonthly,
    this.stripeAmountYearly,
    this.stripeCurrency,
    this.quoteAmountMonthly,
    this.quoteAmountYearly,
    this.quoteCurrency,
    this.quoteChargeCurrency,
    this.quoteFxRate,
    this.quoteFxSource,
    this.quoteFallbackUsd = false,
  });

  factory StripePlan.fromJson(Map<String, dynamic> json) => StripePlan(
        id: json['id'] as String?,
        name: json['name'] as String? ?? '',
        nameEn: json['name_en'] as String?,
        description: json['description'] as String?,
        priceMonthly: (json['price_monthly'] as num?)?.toDouble() ?? 0,
        priceYearly: (json['price_yearly'] as num?)?.toDouble() ?? 0,
        currency: json['currency'] as String? ?? 'SAR',
        features: (json['features'] as List<dynamic>?)?.whereType<String>().toList() ?? [],
        color: json['color'] as String?,
        icon: json['icon'] as String?,
        isActive: json['is_active'] as bool? ?? true,
        stripeProductId: json['stripe_product_id'] as String?,
        stripePriceIdMonthly: json['stripe_price_id_monthly'] as String?,
        stripePriceIdYearly: json['stripe_price_id_yearly'] as String?,
        stripeAmountMonthly: (json['stripe_price_amount_monthly'] as num?)?.toDouble(),
        stripeAmountYearly: (json['stripe_price_amount_yearly'] as num?)?.toDouble(),
        stripeCurrency: json['stripe_currency'] as String?,
        quoteAmountMonthly: (json['quote_amount_monthly'] as num?)?.toDouble(),
        quoteAmountYearly: (json['quote_amount_yearly'] as num?)?.toDouble(),
        quoteCurrency: json['quote_currency'] as String?,
        quoteChargeCurrency: json['quote_charge_currency'] as String?,
        quoteFxRate: (json['quote_fx_rate'] as num?)?.toDouble(),
        quoteFxSource: json['quote_fx_source'] as String?,
        quoteFallbackUsd: json['quote_fallback_usd'] as bool? ?? false,
      );

  bool get supportsMonthly => stripePriceIdMonthly != null && stripePriceIdMonthly!.isNotEmpty;
  bool get supportsYearly => stripePriceIdYearly != null && stripePriceIdYearly!.isNotEmpty;

  bool supportsPeriod(String period) =>
      period == 'monthly' ? supportsMonthly : supportsYearly;

  /// Price displayed for [period] — prefers the server quote, falls back to
  /// the plan's own Stripe price, then to the raw stored price.
  double quotedPrice(String period) {
    final q = period == 'yearly' ? quoteAmountYearly : quoteAmountMonthly;
    if (q != null && q > 0) return q;
    final s = period == 'yearly' ? stripeAmountYearly : stripeAmountMonthly;
    if (s != null && s > 0) return s;
    return period == 'yearly' ? priceYearly : priceMonthly;
  }

  @override
  List<Object?> get props => [id, name, priceMonthly, priceYearly];
}

class StripePaymentIntent extends Equatable {
  final String clientSecret;
  final String? publishableKey;
  final String paymentId;
  final String? stripePaymentIntentId;
  final String planId;
  final String planName;
  final double amount;
  final String currency;
  final String period;
  final String displayCurrency;
  final double displayAmount;
  final bool fallbackToUsd;
  final double? exchangeRate;
  final String? baseCurrency;
  final String? fxSource;
  final bool reused;

  const StripePaymentIntent({
    required this.clientSecret,
    this.publishableKey,
    required this.paymentId,
    this.stripePaymentIntentId,
    required this.planId,
    required this.planName,
    required this.amount,
    this.currency = 'SAR',
    this.period = 'yearly',
    this.displayCurrency = 'SAR',
    this.displayAmount = 0,
    this.fallbackToUsd = false,
    this.exchangeRate,
    this.baseCurrency,
    this.fxSource,
    this.reused = false,
  });

  factory StripePaymentIntent.fromJson(Map<String, dynamic> json) => StripePaymentIntent(
        clientSecret: json['client_secret'] as String? ?? '',
        publishableKey: json['publishable_key'] as String?,
        paymentId: json['payment_id'] as String? ?? '',
        planId: json['plan_id'] as String? ?? '',
        planName: json['plan_name'] as String? ?? '',
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        currency: json['currency'] as String? ?? 'SAR',
        period: json['period'] as String? ?? 'yearly',
        displayCurrency: json['display_currency'] as String? ?? (json['currency'] as String? ?? 'SAR'),
        displayAmount: (json['display_amount'] as num?)?.toDouble() ?? (json['amount'] as num?)?.toDouble() ?? 0,
        fallbackToUsd: json['fallback_to_usd'] as bool? ?? false,
        exchangeRate: (json['exchange_rate'] as num?)?.toDouble(),
        baseCurrency: json['base_currency'] as String?,
        fxSource: json['fx_source'] as String?,
        reused: json['reused'] as bool? ?? false,
        stripePaymentIntentId: json['stripe_payment_intent_id'] as String?,
      );

  bool get isValid => clientSecret.isNotEmpty;

  @override
  List<Object?> get props => [clientSecret, paymentId, planId];
}

class StripePaymentRecord extends Equatable {
  final String? id;
  final String? planId;
  final String? planName;
  final String? provider;
  final double? amount;
  final String? currency;
  final String? status;
  final String? period;
  final String? checkoutSessionId;
  final String? paymentIntentId;
  final double? exchangeRate;
  final String? baseCurrency;
  final String? mode;
  final DateTime? createdAt;

  const StripePaymentRecord({
    this.id,
    this.planId,
    this.planName,
    this.provider,
    this.amount,
    this.currency,
    this.status,
    this.period,
    this.checkoutSessionId,
    this.paymentIntentId,
    this.exchangeRate,
    this.baseCurrency,
    this.mode,
    this.createdAt,
  });

  factory StripePaymentRecord.fromJson(Map<String, dynamic> json) => StripePaymentRecord(
        id: json['id'] as String?,
        planId: json['plan_id'] as String?,
        planName: json['plan_name'] as String?,
        provider: json['provider'] as String?,
        amount: (json['amount'] as num?)?.toDouble(),
        currency: json['currency'] as String?,
        status: json['status'] as String?,
        period: json['period'] as String?,
        checkoutSessionId: json['stripe_checkout_session_id'] as String?,
        paymentIntentId: json['stripe_payment_intent_id'] as String?,
        exchangeRate: (json['exchange_rate'] as num?)?.toDouble(),
        baseCurrency: json['base_currency'] as String?,
        mode: json['mode'] as String?,
        createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ?? null,
      );

  @override
  List<Object?> get props => [id, planName, amount, status];
}

class StripeSubscriptionRecord extends Equatable {
  final String? id;
  final String? planId;
  final String? planName;
  final String? status;
  final String? stripeSubscriptionId;
  final DateTime? currentPeriodStart;
  final DateTime? currentPeriodEnd;
  final bool? cancelAtPeriodEnd;
  final DateTime? createdAt;

  const StripeSubscriptionRecord({
    this.id,
    this.planId,
    this.planName,
    this.status,
    this.stripeSubscriptionId,
    this.currentPeriodStart,
    this.currentPeriodEnd,
    this.cancelAtPeriodEnd,
    this.createdAt,
  });

  factory StripeSubscriptionRecord.fromJson(Map<String, dynamic> json) =>
      StripeSubscriptionRecord(
        id: json['id'] as String?,
        planId: json['plan_id'] as String?,
        planName: json['plan_name'] as String?,
        status: json['status'] as String?,
        stripeSubscriptionId: json['stripe_subscription_id'] as String?,
        currentPeriodStart: DateTime.tryParse(json['current_period_start']?.toString() ?? '') ?? null,
        currentPeriodEnd: DateTime.tryParse(json['current_period_end']?.toString() ?? '') ?? null,
        cancelAtPeriodEnd: json['cancel_at_period_end'] as bool?,
        createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ?? null,
      );

  @override
  List<Object?> get props => [id, planName, status];
}

class BillingRecord extends Equatable {
  final int? id;
  final int? planId;
  final String? planName;
  final double amount;
  final String period;
  final String? status;
  final String? paymentMethod;
  final DateTime? billingDate;
  final DateTime? dueDate;

  const BillingRecord({
    this.id,
    this.planId,
    this.planName,
    this.amount = 0,
    this.period = 'yearly',
    this.status,
    this.paymentMethod,
    this.billingDate,
    this.dueDate,
  });

  factory BillingRecord.fromJson(Map<String, dynamic> json) => BillingRecord(
        id: json['id'] as int?,
        planId: json['plan_id'] as int?,
        planName: json['plan_name'] as String?,
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        period: json['period'] as String? ?? 'yearly',
        status: json['status'] as String?,
        paymentMethod: json['payment_method'] as String?,
        billingDate: DateTime.tryParse(json['billing_date'].toString()) ?? null,
        dueDate: DateTime.tryParse(json['due_date'].toString()) ?? null,
      );

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    if (planId != null) 'plan_id': planId,
    'amount': amount,
    'period': period,
    if (status != null) 'status': status,
    if (paymentMethod != null) 'payment_method': paymentMethod,
    if (billingDate != null) 'billing_date': billingDate!.toIso8601String(),
    if (dueDate != null) 'due_date': dueDate!.toIso8601String(),
  };

  BillingRecord copyWith({
    int? id, int? planId, String? planName, double? amount,
    String? period, String? status, String? paymentMethod,
    DateTime? billingDate, DateTime? dueDate,
  }) => BillingRecord(
    id: id ?? this.id, planId: planId ?? this.planId, planName: planName ?? this.planName,
    amount: amount ?? this.amount, period: period ?? this.period, status: status ?? this.status,
    paymentMethod: paymentMethod ?? this.paymentMethod, billingDate: billingDate ?? this.billingDate,
    dueDate: dueDate ?? this.dueDate,
  );

  @override
  List<Object?> get props => [id, planId, amount, status, billingDate];
}

class SubscriptionRequest extends Equatable {
  final int? id;
  final int? planId;
  final String? planName;
  final String? userName;
  final String? userEmail;
  final String? period;
  final double amount;
  final String? status;
  final String? note;
  final DateTime? createdAt;

  const SubscriptionRequest({
    this.id,
    this.planId,
    this.planName,
    this.userName,
    this.userEmail,
    this.period,
    this.amount = 0,
    this.status,
    this.note,
    this.createdAt,
  });

  factory SubscriptionRequest.fromJson(Map<String, dynamic> json) => SubscriptionRequest(
        id: json['id'] as int?,
        planId: json['plan_id'] as int?,
        planName: json['plan_name'] as String?,
        userName: json['user_name'] as String?,
        userEmail: json['user_email'] as String?,
        period: json['period'] as String?,
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        status: json['status'] as String?,
        note: json['note'] as String?,
        createdAt: DateTime.tryParse(json['created_at'].toString()) ?? null,
      );

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    if (planId != null) 'plan_id': planId,
    if (period != null) 'period': period,
    'amount': amount,
    if (status != null) 'status': status,
    if (note != null) 'note': note,
    if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
  };

  SubscriptionRequest copyWith({
    int? id, int? planId, String? planName, String? userName,
    String? userEmail, String? period, double? amount,
    String? status, String? note, DateTime? createdAt,
  }) => SubscriptionRequest(
    id: id ?? this.id, planId: planId ?? this.planId, planName: planName ?? this.planName,
    userName: userName ?? this.userName, userEmail: userEmail ?? this.userEmail,
    period: period ?? this.period, amount: amount ?? this.amount, status: status ?? this.status,
    note: note ?? this.note, createdAt: createdAt ?? this.createdAt,
  );

  @override
  List<Object?> get props => [id, planId, status, createdAt];
}
