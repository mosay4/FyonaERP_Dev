import 'package:equatable/equatable.dart';

class NotificationItem extends Equatable {
  final String id;
  final String type;
  final String title;
  final String? message;
  final bool isRead;
  final DateTime createdAt;
  final String? actionPayload;
  final String? route;
  final String? sourceNotifId;
  final bool isSystem;
  final String? imageUrl;

  const NotificationItem({
    required this.id,
    required this.type,
    required this.title,
    this.message,
    this.isRead = false,
    required this.createdAt,
    this.actionPayload,
    this.route,
    this.sourceNotifId,
    this.isSystem = true,
    this.imageUrl,
  });

  /// True ONLY when a human admin wrote the message in the admin panel's
  /// notifications section. Every automatic notification (subscription,
  /// maintenance/controls, payments, ...) is a system notification.
  bool get isAdminWritten => !isSystem;

  factory NotificationItem.fromJson(Map<String, dynamic> json) =>
      NotificationItem(
        id: json['id'].toString(),
        type: json['type'] as String? ?? 'info',
        title: json['title'] as String? ?? '',
        message: json['message'] as String?,
        isRead: json['is_read'] as bool? ?? false,
        createdAt:
            DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now(),
        actionPayload: json['action_payload'] as String?,
        route: json['route'] as String?,
        sourceNotifId: json['source_notif_id']?.toString(),
        isSystem: json['is_system'] as bool? ?? true,
        imageUrl: json['image_url'] as String?,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'title': title,
    if (message != null) 'message': message,
    'is_read': isRead,
    'created_at': createdAt.toIso8601String(),
    if (actionPayload != null) 'action_payload': actionPayload,
    if (route != null) 'route': route,
    if (sourceNotifId != null) 'source_notif_id': sourceNotifId,
    'is_system': isSystem,
    if (imageUrl != null) 'image_url': imageUrl,
  };

  NotificationItem copyWith({
    String? id,
    String? type,
    String? title,
    String? message,
    bool? isRead,
    DateTime? createdAt,
    String? actionPayload,
    String? route,
    String? sourceNotifId,
    bool? isSystem,
    String? imageUrl,
  }) => NotificationItem(
    id: id ?? this.id,
    type: type ?? this.type,
    title: title ?? this.title,
    message: message ?? this.message,
    isRead: isRead ?? this.isRead,
    createdAt: createdAt ?? this.createdAt,
    actionPayload: actionPayload ?? this.actionPayload,
    route: route ?? this.route,
    sourceNotifId: sourceNotifId ?? this.sourceNotifId,
    isSystem: isSystem ?? this.isSystem,
    imageUrl: imageUrl ?? this.imageUrl,
  );

  @override
  List<Object?> get props => [
    id,
    type,
    title,
    isRead,
    createdAt,
    actionPayload,
    sourceNotifId,
    isSystem,
    imageUrl,
  ];
}

class NotificationSettings {
  bool emailAlerts;
  bool invoiceAlerts;
  bool paymentAlerts;
  bool systemUpdates;

  NotificationSettings({
    this.emailAlerts = true,
    this.invoiceAlerts = true,
    this.paymentAlerts = true,
    this.systemUpdates = true,
  });

  factory NotificationSettings.fromJson(Map<String, dynamic> json) =>
      NotificationSettings(
        emailAlerts: json['email_alerts'] as bool? ?? true,
        invoiceAlerts: json['invoice_alerts'] as bool? ?? true,
        paymentAlerts: json['payment_alerts'] as bool? ?? true,
        systemUpdates: json['system_updates'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
    'email_alerts': emailAlerts,
    'invoice_alerts': invoiceAlerts,
    'payment_alerts': paymentAlerts,
    'system_updates': systemUpdates,
  };
}

class NotificationPreferences extends Equatable {
  final bool emailAlerts;
  final bool invoiceAlerts;
  final bool paymentAlerts;
  final bool systemUpdates;
  final bool budgetAlerts;
  final bool lowBalanceAlerts;
  final bool dailyReport;
  final bool weeklyReport;
  final bool monthlyReport;

  const NotificationPreferences({
    this.emailAlerts = true,
    this.invoiceAlerts = true,
    this.paymentAlerts = true,
    this.systemUpdates = true,
    this.budgetAlerts = true,
    this.lowBalanceAlerts = true,
    this.dailyReport = false,
    this.weeklyReport = false,
    this.monthlyReport = false,
  });

  factory NotificationPreferences.fromJson(Map<String, dynamic> json) =>
      NotificationPreferences(
        emailAlerts: json['email_alerts'] as bool? ?? true,
        invoiceAlerts: json['invoice_alerts'] as bool? ?? true,
        paymentAlerts: json['payment_alerts'] as bool? ?? true,
        systemUpdates: json['system_updates'] as bool? ?? true,
        budgetAlerts: json['budget_alerts'] as bool? ?? true,
        lowBalanceAlerts: json['low_balance_alerts'] as bool? ?? true,
        dailyReport: json['daily_report'] as bool? ?? false,
        weeklyReport: json['weekly_report'] as bool? ?? false,
        monthlyReport: json['monthly_report'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
    'email_alerts': emailAlerts,
    'invoice_alerts': invoiceAlerts,
    'payment_alerts': paymentAlerts,
    'system_updates': systemUpdates,
    'budget_alerts': budgetAlerts,
    'low_balance_alerts': lowBalanceAlerts,
    'daily_report': dailyReport,
    'weekly_report': weeklyReport,
    'monthly_report': monthlyReport,
  };

  NotificationPreferences copyWith({
    bool? emailAlerts,
    bool? invoiceAlerts,
    bool? paymentAlerts,
    bool? systemUpdates,
    bool? budgetAlerts,
    bool? lowBalanceAlerts,
    bool? dailyReport,
    bool? weeklyReport,
    bool? monthlyReport,
  }) => NotificationPreferences(
    emailAlerts: emailAlerts ?? this.emailAlerts,
    invoiceAlerts: invoiceAlerts ?? this.invoiceAlerts,
    paymentAlerts: paymentAlerts ?? this.paymentAlerts,
    systemUpdates: systemUpdates ?? this.systemUpdates,
    budgetAlerts: budgetAlerts ?? this.budgetAlerts,
    lowBalanceAlerts: lowBalanceAlerts ?? this.lowBalanceAlerts,
    dailyReport: dailyReport ?? this.dailyReport,
    weeklyReport: weeklyReport ?? this.weeklyReport,
    monthlyReport: monthlyReport ?? this.monthlyReport,
  );

  @override
  List<Object?> get props => [
    emailAlerts,
    invoiceAlerts,
    paymentAlerts,
    systemUpdates,
    budgetAlerts,
    lowBalanceAlerts,
    dailyReport,
    weeklyReport,
    monthlyReport,
  ];
}

class Reminder extends Equatable {
  final String id;
  final String title;
  final String? message;
  final DateTime remindAt;
  final String repeat;
  final bool isActive;
  final DateTime? lastTriggeredAt;

  const Reminder({
    required this.id,
    required this.title,
    this.message,
    required this.remindAt,
    this.repeat = 'none',
    this.isActive = true,
    this.lastTriggeredAt,
  });

  factory Reminder.fromJson(Map<String, dynamic> json) => Reminder(
    id: json['id']?.toString() ?? '',
    title: json['title'] as String? ?? '',
    message: json['message'] as String?,
    remindAt:
        DateTime.tryParse(json['remind_at']?.toString() ?? '') ??
        DateTime.now(),
    repeat: json['repeat'] as String? ?? 'none',
    isActive: json['is_active'] as bool? ?? true,
    lastTriggeredAt: json['last_triggered_at'] != null
        ? DateTime.tryParse(json['last_triggered_at'].toString())
        : null,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (message != null) 'message': message,
    'remind_at': remindAt.toUtc().toIso8601String(),
    'repeat': repeat,
    'is_active': isActive,
    if (lastTriggeredAt != null)
      'last_triggered_at': lastTriggeredAt!.toUtc().toIso8601String(),
  };

  Reminder copyWith({
    String? title,
    String? message,
    DateTime? remindAt,
    String? repeat,
    bool? isActive,
  }) => Reminder(
    id: id,
    title: title ?? this.title,
    message: message ?? this.message,
    remindAt: remindAt ?? this.remindAt,
    repeat: repeat ?? this.repeat,
    isActive: isActive ?? this.isActive,
    lastTriggeredAt: lastTriggeredAt,
  );

  @override
  List<Object?> get props => [id, title, message, remindAt, repeat, isActive];
}
