import '../../core/utils/subscription_identity.dart' show subscriptionIdentityLevel;
import 'package:equatable/equatable.dart';

class UserModel extends Equatable {
  final String id;
  final String? username;
  final String? email;
  final String? fullName;
  final String? phone;
  final String? phoneMasked;
  final bool phoneComplete;
  final String role;
  final bool isActive;
  final String? organizationId;
  final bool isPlatformAdmin;
  final List<String> adminPermissions;
  final String? preferredUsageMode;
  final String? subscriptionPlan;
  final String? status;
  final bool mfaEnabled;
  final String? subscriptionStartDate;
  final String? subscriptionEndDate;
  final String? trialStartDate;
  final String? trialEndDate;
  final bool personalTrialActivated;
  final bool businessTrialActivated;
  final bool emailVerified;
  /// Relative server path of the profile picture (e.g.
  /// `uploads/avatars/<id>.jpg`), or null when none is set.
  final String? avatar;
  final String? organizationName;
  final String? organizationAvatar;

  const UserModel({
    required this.id,
    this.username,
    this.email,
    this.fullName,
    this.phone,
    this.phoneMasked,
    this.phoneComplete = false,
    this.role = 'employee',
    this.isActive = true,
    this.organizationId,
    this.isPlatformAdmin = false,
    this.adminPermissions = const [],
    this.preferredUsageMode,
    this.subscriptionPlan,
    this.status,
    this.mfaEnabled = false,
    this.subscriptionStartDate,
    this.subscriptionEndDate,
    this.trialStartDate,
    this.trialEndDate,
    this.personalTrialActivated = false,
    this.businessTrialActivated = false,
    this.emailVerified = false,
    this.avatar,
    this.organizationName,
    this.organizationAvatar,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: json['id'].toString(),
      username: json['username'] as String?,
      email: json['email'] as String?,
      fullName: json['full_name'] as String?,
      phone: json['phone'] as String?,
      phoneMasked: (json['phone_masked'] as String?) ?? (json['phone'] as String?),
      phoneComplete: (json['phone_complete'] as bool?) ??
          ((json['phone'] as String?)?.isNotEmpty ?? false),
      role: (json['role'] as String?) ?? 'employee',
      isActive: (json['is_active'] as bool?) ?? true,
      organizationId: json['organization_id'].toString(),
      isPlatformAdmin: (json['is_platform_admin'] as bool?) ?? false,
      adminPermissions: _parseAdminPermissions(json['admin_permissions']),
      preferredUsageMode: json['preferred_usage_mode'] as String?,
      subscriptionPlan: json['subscription_plan'] as String?,
      status: (json['subscription_status'] as String?) ?? (json['status'] as String?),
      mfaEnabled: (json['mfa_enabled'] as bool?) ?? false,
      subscriptionStartDate: json['subscription_start_date'] as String?,
      subscriptionEndDate: json['subscription_end_date'] as String?,
      trialStartDate: json['trial_start_date'] as String?,
      trialEndDate: json['trial_end_date'] as String?,
      personalTrialActivated: (json['personal_trial_activated'] == true || json['personal_trial_activated'] == 1),
      businessTrialActivated: (json['business_trial_activated'] == true || json['business_trial_activated'] == 1),
      emailVerified: (json['email_verified'] as bool?) ?? false,
      avatar: json['avatar'] as String?,
      organizationName: json['organization_name'] as String?,
      organizationAvatar: json['organization_avatar'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      if (username != null) 'username': username,
      'email': email,
      'full_name': fullName,
      'phone': phone,
      'phone_masked': phoneMasked,
      'phone_complete': phoneComplete,
      'role': role,
      'is_active': isActive,
      'organization_id': organizationId,
      'is_platform_admin': isPlatformAdmin,
      'admin_permissions': adminPermissions,
      'preferred_usage_mode': preferredUsageMode,
      'subscription_plan': subscriptionPlan,
      'status': status,
      'mfa_enabled': mfaEnabled,
      'subscription_start_date': subscriptionStartDate,
      'subscription_end_date': subscriptionEndDate,
      'trial_start_date': trialStartDate,
      'trial_end_date': trialEndDate,
      'personal_trial_activated': personalTrialActivated,
      'business_trial_activated': businessTrialActivated,
      'email_verified': emailVerified,
      if (avatar != null) 'avatar': avatar,
    };
  }

  UserModel copyWith({
    String? id,
    String? username,
    String? email,
    String? fullName,
    String? phone,
    String? phoneMasked,
    bool? phoneComplete,
    String? role,
    bool? isActive,
    String? organizationId,
    bool? isPlatformAdmin,
    List<String>? adminPermissions,
    String? preferredUsageMode,
    String? subscriptionPlan,
    String? status,
    bool? mfaEnabled,
    String? subscriptionStartDate,
    String? subscriptionEndDate,
    String? trialStartDate,
    String? trialEndDate,
    bool? personalTrialActivated,
    bool? businessTrialActivated,
    bool? emailVerified,
    String? avatar,
    String? organizationName,
    String? organizationAvatar,
  }) {
    return UserModel(
      id: id ?? this.id,
      username: username ?? this.username,
      email: email ?? this.email,
      fullName: fullName ?? this.fullName,
      phone: phone ?? this.phone,
      phoneMasked: phoneMasked ?? this.phoneMasked,
      phoneComplete: phoneComplete ?? this.phoneComplete,
      role: role ?? this.role,
      isActive: isActive ?? this.isActive,
      organizationId: organizationId ?? this.organizationId,
      isPlatformAdmin: isPlatformAdmin ?? this.isPlatformAdmin,
      adminPermissions: adminPermissions ?? this.adminPermissions,
      preferredUsageMode: preferredUsageMode ?? this.preferredUsageMode,
      subscriptionPlan: subscriptionPlan ?? this.subscriptionPlan,
      status: status ?? this.status,
      mfaEnabled: mfaEnabled ?? this.mfaEnabled,
      subscriptionStartDate: subscriptionStartDate ?? this.subscriptionStartDate,
      subscriptionEndDate: subscriptionEndDate ?? this.subscriptionEndDate,
      trialStartDate: trialStartDate ?? this.trialStartDate,
      trialEndDate: trialEndDate ?? this.trialEndDate,
      personalTrialActivated: personalTrialActivated ?? this.personalTrialActivated,
      businessTrialActivated: businessTrialActivated ?? this.businessTrialActivated,
      emailVerified: emailVerified ?? this.emailVerified,
      avatar: avatar ?? this.avatar,
      organizationName: organizationName ?? this.organizationName,
      organizationAvatar: organizationAvatar ?? this.organizationAvatar,
    );
  }

  /// Effective subscription status based on dates
  String get effectiveStatus {
    // A cancelled subscription (admin revoked) is frozen immediately:
    // the app must treat it exactly like an expired one — force the user
    // back to the paywall/subscription gate.
    if (status == 'cancelled') return 'expired';
    if (status == 'active') {
      if (subscriptionEndDate != null) {
        final end = DateTime.tryParse(subscriptionEndDate!);
        if (end != null && end.isBefore(DateTime.now())) return 'expired';
      }
      return 'active';
    }
    if (status == 'expired') return 'expired';
    if (status == 'trial' && trialEndDate != null) {
      final end = DateTime.tryParse(trialEndDate!);
      if (end != null && end.isBefore(DateTime.now())) return 'expired';
      return 'trial';
    }
    if (status == 'pending' || status == null || status == 'trial') return 'pending';
    // `none` = brand-new account that has never subscribed (no request pending).
    // Keep it distinct from `pending` so the app shows the plans/trial CTA
    // instead of a phantom "your request is under review" waiting screen.
    if (status == 'none') return 'none';
    return status!;
  }

  /// Whether subscription is valid (active or trial not expired)
  bool get hasValidSubscription {
    final s = effectiveStatus;
    return s == 'active' || s == 'trial';
  }

  /// Whether user is admin (bypasses subscription checks)
  bool get isAdmin => isPlatformAdmin;

  /// Whether the account holds a completed phone number.
  bool get hasPhone => phoneComplete && phoneMasked != null;

  /// Plan-based verification level — follows the plan identity:
  /// 0 = none, 1 = personal (blue check), 2 = business (red check),
  /// 3 = premium/أعمال + شخصي (gold check).
  int get verificationLevel => subscriptionIdentityLevel(subscriptionPlan);

  /// Whether the user is entitled to a plan-based verification badge.
  bool get isPlanVerified => verificationLevel > 0;

  /// Whether the user holds a given platform-admin permission (`resource:action`).
  bool hasAdminPermission(String resource, [String? action]) {
    if (!isPlatformAdmin) return false;
    if (adminPermissions.isEmpty) return true; // legacy full-access admin
    final code = action == null ? resource : '$resource:$action';
    for (final p in adminPermissions) {
      if (p == '*') return true;
      if (action == null && p.startsWith('$resource:')) return true;
      if (p == code) return true;
    }
    return false;
  }

  /// Whether the user holds the `read` permission for a resource.
  bool canAdminRead(String resource) => hasAdminPermission(resource, 'read');

  /// Whether the user holds the `update` permission for a resource.
  bool canAdminUpdate(String resource) => hasAdminPermission(resource, 'update');

  /// Whether the user holds the `create` permission for a resource.
  bool canAdminCreate(String resource) => hasAdminPermission(resource, 'create');

  /// Whether the user holds the `delete` permission for a resource.
  bool canAdminDelete(String resource) => hasAdminPermission(resource, 'delete');

  static List<String> _parseAdminPermissions(Object? raw) {
    if (raw == null) return const [];
    if (raw is List) {
      return raw.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
    }
    return const [];
  }

  @override
  List<Object?> get props => [
        id, username, email, fullName, phone, phoneMasked, phoneComplete,
        role, isActive,
        organizationId, isPlatformAdmin, adminPermissions, preferredUsageMode,
        subscriptionPlan, status, mfaEnabled,
        subscriptionStartDate, subscriptionEndDate,
        trialStartDate, trialEndDate,
        personalTrialActivated, businessTrialActivated, emailVerified,
        avatar, organizationName, organizationAvatar,
      ];
}
