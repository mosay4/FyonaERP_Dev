import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Central identity helpers for the four FYONA plans:
/// free → green · personal → blue · business → red · premium (أعمال + شخصي) → gold.
/// Used everywhere a plan's "identity" must be styled consistently:
/// plan cards, invoices, profile subscription cards, verification badges.

const String subIdentityFree = 'free';
const String subIdentityPersonal = 'personal';
const String subIdentityBusiness = 'business';
const String subIdentityPremium = 'premium';

/// Map any plan value (engine key or Arabic/English display name) to a
/// canonical identity key: 'personal' | 'business' | 'premium' | ''.
///
/// 'trial' (and 'تجريبي') is the free plan's trial face — it always shares
/// the free identity (green), online and offline alike.
String subscriptionIdentityKey(String? plan) {
  switch ((plan ?? '').trim().toLowerCase()) {
    case 'free':
    case 'free_plan':
    case 'مجاني':
    case 'trial':
    case 'تجريبي':
      return subIdentityFree;
    case 'personal':
    case 'personal_plan':
    case 'باقة شخصية':
    case 'شخصي':
      return subIdentityPersonal;
    case 'business':
    case 'business_plan':
    case 'باقة أعمال':
    case 'أعمال':
      return subIdentityBusiness;
    case 'premium':
    case 'premium_plan':
    case 'باقة أعمال + شخصي':
    case 'أعمال + شخصي':
      return subIdentityPremium;
    default:
      return '';
  }
}

/// The identity color of a plan: blue (personal), red (business),
/// gold (أعمال + شخصي).
Color subscriptionIdentityColor(String? plan) {
  return switch (subscriptionIdentityKey(plan)) {
    subIdentityFree => AppColors.success,
    subIdentityBusiness => AppColors.danger,
    subIdentityPremium => AppColors.gold,
    _ => AppColors.info,
  };
}

/// Verification level used for badges:
/// 0 none · 1 personal (blue) · 2 business (red) · 3 premium (gold).
int subscriptionIdentityLevel(String? plan) {
  return switch (subscriptionIdentityKey(plan)) {
    subIdentityBusiness => 2,
    subIdentityPremium => 3,
    subIdentityPersonal => 1,
    _ => 0,
  };
}