/// Merchant membership authorizes non-setup Business routes independently of
/// the invited user's own section plan. Own-company access is never exempted.
bool shouldUseInvitedWorkspaceAccess({
  required String? section,
  required bool isSetupRoute,
  required String? workspaceOrganizationId,
  required String? userOrganizationId,
  required bool hasMembership,
}) =>
    section == 'business' &&
    !isSetupRoute &&
    workspaceOrganizationId != null &&
    workspaceOrganizationId != userOrganizationId &&
    hasMembership;

/// Server-owned section access. A cached active flag never outlives its date.
bool hasSectionAccess(Map<String, dynamic>? status, String section, {DateTime? now}) {
  final sections = status?['sections'];
  if (sections is! Map) return false;
  final entry = sections[section];
  if (entry is! Map || entry['active'] != true) return false;
  final end = DateTime.tryParse(entry['end_date']?.toString() ?? '');
  return end != null && end.isAfter(now ?? DateTime.now());
}

bool hasPaidPlan(Map<String, dynamic>? status, String plan, {DateTime? now}) {
  final entries = status?['subscriptions'];
  if (entries is! Map) return false;
  final entry = entries[plan];
  if (entry is! Map || entry['status'] != 'active') return false;
  final end = DateTime.tryParse(entry['end_date']?.toString() ?? '');
  return end != null && end.isAfter(now ?? DateTime.now());
}
