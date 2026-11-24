import 'dart:io';
import 'package:flutter/material.dart';
import 'secure_image.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import '../../core/utils/server_image_url.dart';
import '../../core/router/route_names.dart';
import '../providers/current_user_provider.dart';
import '../../shared/models/user_model.dart';
import '../../features/auth/presentation/providers/auth_provider.dart';
import '../../features/subscription/domain/section_access.dart';
import '../../features/subscription/domain/personal_offline_access.dart';
import '../../core/services/connectivity_service.dart';
import '../../features/subscription/presentation/providers/subscription_providers.dart';
import '../../features/profile/presentation/providers/avatar_provider.dart';
import '../../features/profile/presentation/providers/section_profile_provider.dart';
import '../../features/branches/data/branch_api.dart';
import '../../features/branches/data/branch_scope.dart';
import '../../features/suggestions/di/suggestions_providers.dart';
import '../widgets/app_icon.dart';
import '../widgets/two_tone_icon.dart';
import '../widgets/two_tone_icons.dart';
import 'plan_verification_badge.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import '../../core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';
import 'premium_switch_transition.dart';
import '../../features/dashboard/presentation/providers/business_dashboard_providers.dart';
import '../../features/personal/presentation/providers/personal_providers.dart';
import '../../features/employees/presentation/providers/employee_providers.dart';
import '../../features/employees/presentation/widgets/employee_avatar.dart';
import '../../core/services/section_scope.dart';

class AppDrawer extends ConsumerStatefulWidget {
  final UserModel? user;
  final String currentRoute;

  const AppDrawer({super.key, this.user, required this.currentRoute});

  @override
  ConsumerState<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends ConsumerState<AppDrawer> {
  bool _contactExpanded = false;
  final GlobalKey _branchSwitchKey = GlobalKey();
  final Set<String> _precachedBranches = <String>{};
  final Map<String, String> _branchLabels = {};

  /// Branch pictures from the owner's branch list (the same source as the
  /// branches page, including a picture saved on this device offline).
  Map<String, String> _branchPictures = const {};

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    if (user != null &&
        BranchScope.organizationId != null &&
        BranchScope.organizationId == user.organizationId) {
      final rows = ref.watch(savedBranchListProvider).valueOrNull;
      if (rows != null) {
        _branchPictures = {
          for (final row in rows)
            if ('${row['image'] ?? ''}'.trim().isNotEmpty)
              '${row['id']}': '${row['image']}'.trim(),
        };
      }
    }
    return Drawer(
      backgroundColor: AppColors.background,
      width: 300,
      child: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            SizedBox(height: 8),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Divider(color: AppColors.border, height: 1),
            ),
            SizedBox(height: 8),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  // First action in BOTH sections: switch account/section.
                  _buildModeToggle(),

                  if (_shouldShowEmployment()) _buildJobRequestsItem(),
                  if (!_isEmployeeWorkspace()) _buildBranchManagementItem(),
                  if (!_isEmployeeWorkspace()) _buildSubscriptionItem(),
                  if (!_isEmployeeWorkspace()) _buildSuggestionsItem(),
                  _buildContactSupportItem(),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Divider(color: AppColors.border, height: 1),
            ),
            SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  bool _isEmployeeWorkspace() {
    return !widget.currentRoute.startsWith('/personal') &&
        ref.watch(employeeWorkspaceCompanyProvider) != null;
  }

  bool _shouldShowEmployment() {
    final user = widget.user ?? ref.watch(currentUserProvider);
    if (user != null &&
        user.role.toLowerCase() != 'owner' &&
        !user.isPlatformAdmin)
      return true;
    if (_isEmployeeWorkspace()) return true;
    final rows = ref.watch(myInvitationsProvider).valueOrNull ?? const [];
    return rows.any(
      (e) => e['status'] == 'pending' || e['status'] == 'accepted',
    );
  }

  Widget _buildEmployeeProfileItem() {
    final org = BranchScope.organizationId;
    final info =
        (org == null
                ? ref.watch(myEmployeeProfileProvider)
                : ref.watch(myEmployeeProfileForProvider(org)))
            .valueOrNull ??
        const {};
    final emp = (info['employee'] as Map?) ?? const {};
    if (emp.isEmpty) return const SizedBox.shrink();
    return ListTile(
      leading: EmployeeAvatar(photo: emp['photo_url'] as String?, size: 40),
      title: Text(
        '${emp['full_name'] ?? ''}',
        style: TextStyle(
          fontFamily: 'Cairo',
          fontWeight: FontWeight.w800,
          color: AppColors.textPrimary,
        ),
      ),
      subtitle: Text(
        '${emp['employee_code'] ?? ''}',
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 10,
          color: AppColors.textSecondary,
        ),
      ),
      trailing: Icon(
        Icons.chevron_left_rounded,
        color: AppColors.textSecondary,
      ),
      onTap: () {
        Navigator.pop(context);
        GoRouter.of(context).push('/employee-profile');
      },
    );
  }

  Widget _buildJobRequestsItem() {
    return ListTile(
      leading: Icon(Icons.work_outline_rounded, color: AppColors.primary),
      title: Text(
        'التوظيف',
        style: TextStyle(
          fontFamily: 'Cairo',
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
      ),
      trailing: Icon(
        Icons.chevron_left_rounded,
        color: AppColors.textSecondary,
      ),
      onTap: () {
        Navigator.pop(context);
        GoRouter.of(context).push('/job-requests');
      },
    );
  }

  // ── Header ──
  Widget _buildHeader() {
    ref.watch(branchEpochProvider);
    final l10n = AppLocalizations.of(context);
    final user = ref.watch(currentUserProvider) ?? widget.user;
    final personal = widget.currentRoute.startsWith('/personal');
    final personalIdentity = ref.watch(sectionProfileProvider);
    final ownAvatarBytes = personal
        ? personalIdentity.avatar ?? ref.watch(avatarProvider)
        : null;
    final Widget? ownAvatar = !personal
        ? null
        : ClipOval(
            child: ownAvatarBytes != null
                ? Image.memory(
                    ownAvatarBytes,
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                  )
                : EmployeeAvatar(photo: user?.avatar, size: 40),
          );
    final companies = List<Map<String, dynamic>>.of(
      ref.watch(branchMenuAccessProvider).asData?.value ?? const [],
    );
    final ownOrganizationId = user?.organizationId ?? '__self__';
    // /branches/access includes an owned organization even before Business has
    // any branches. Treat that empty entry as the synthetic personal main
    // branch, not as an empty company that suppresses the return destination.
    companies.removeWhere(
      (company) =>
          '${company['organization_id']}' == ownOrganizationId &&
          (company['branches'] as List? ?? const []).isEmpty,
    );
    if (!personal &&
        !companies.any((c) => '${c['organization_id']}' == ownOrganizationId)) {
      companies.insert(0, {
        'organization_id': ownOrganizationId,
        'organization_name': user?.fullName,
        'role': 'self',
        'all_branches': false,
        'branches': [
          {
            'id': '__main__',
            'name': l10n.translate('branchMain'),
            'image': user?.organizationAvatar,
          },
        ],
      });
    }
    if (personal) {
      companies.removeWhere(
        (company) =>
            company['role'] != 'member' ||
            '${company['organization_id']}' == ownOrganizationId,
      );
    }
    final branches = [
      for (final company in companies)
        for (final branch
            in (company['branches'] as List? ?? const []).whereType<Map>())
          <String, dynamic>{
            ...Map<String, dynamic>.from(branch),
            'organization_id': company['organization_id'],
          },
    ];
    _precacheBranchImages(branches);
    final current = branches
        .where(
          (b) =>
              '${b['id']}' == BranchScope.branchId &&
              '${b['organization_id']}' == BranchScope.organizationId,
        )
        .firstOrNull;
    final fallback = branches
        .where((b) => '${b['organization_id']}' == ownOrganizationId)
        .firstOrNull;
    final selected = personal
        ? <String, dynamic>{'name': user?.fullName, 'image': user?.avatar}
        : current ?? (BranchScope.branchId == null ? fallback : null);
    final hasMerchants = companies.any(
      (c) => '${c['organization_id']}' != ownOrganizationId,
    );
    final switchable = hasMerchants || branches.length > 1;
    final name = personal
        ? (personalIdentity.name ??
              user?.fullName ??
              l10n.translate('defaultUser'))
        : BranchScope.allMode
        ? l10n.translate('branchAllShort')
        : '${selected?['name'] ?? BranchScope.branchName ?? l10n.translate('branchMain')}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
      child: Column(
        children: [
          Image.asset(
            Theme.of(context).brightness == Brightness.dark
                ? 'assets/images/fyona_logo_light.png'
                : 'assets/images/fyona_logo_dark.png',
            key: const ValueKey('drawer-app-logo'),
            width: 80,
            height: 80,
            fit: BoxFit.contain,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Row(
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 15),
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    if ((user?.verificationLevel ?? 0) > 0) ...[
                      const SizedBox(width: 4),
                      PlanVerificationBadge(
                        level: user!.verificationLevel,
                        size: 18,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (switchable)
                _branchSwitchButton(
                  selected,
                  companies,
                  identityAvatar: ownAvatar,
                )
              else if (ownAvatar != null)
                ownAvatar
              else
                _branchCircleImage(selected, size: 40),
            ],
          ),
        ],
      ),
    );
  }

  Widget _legacyHeader() {
    ref.watch(branchEpochProvider);
    final l10n = AppLocalizations.of(context);
    final user = widget.user;
    final isBusiness = !widget.currentRoute.startsWith('/personal');
    final employeeWorkspaceCompany = isBusiness
        ? ref.watch(employeeWorkspaceCompanyProvider)
        : null;
    final section = ref.watch(sectionProfileProvider);
    final isOwner =
        (user?.role ?? '').toLowerCase() == 'owner' ||
        (user?.isPlatformAdmin ?? false);
    final canEditProfile = !isBusiness || isOwner;

    // BUSINESS uses the business identity ONLY. Personal avatar/name are
    // never used as a fallback inside the Business drawer.
    final name = isBusiness
        ? (section.name?.trim().isNotEmpty == true
              ? section.name!.trim()
              : (user?.organizationName?.trim().isNotEmpty == true
                    ? user!.organizationName!.trim()
                    : (user?.fullName ?? l10n.translate('defaultUser'))))
        : (section.name?.trim().isNotEmpty == true
              ? section.name!.trim()
              : (user?.fullName ?? l10n.translate('defaultUser')));
    final personalAvatar = section.avatar ?? ref.watch(avatarProvider);
    final orgAvatar = _absoluteUrl(user?.organizationAvatar);
    final branchCompanies =
        ref.watch(branchAccessProvider).valueOrNull ??
        const <Map<String, dynamic>>[];
    final allAccessibleBranches = branchCompanies
        .expand(
          (c) => (c['branches'] as List? ?? const []).whereType<Map>().map(
            (b) => <String, dynamic>{
              ...Map<String, dynamic>.from(b),
              'organization_id': c['organization_id'],
            },
          ),
        )
        .toList();
    final showBranchSwitch =
        isBusiness &&
        (branchCompanies.length > 1 ||
            allAccessibleBranches.length > 1 ||
            employeeWorkspaceCompany != null);
    if (isBusiness) _precacheBranchImages(allAccessibleBranches);
    final currentBranch = allAccessibleBranches
        .where((b) => '${b['id']}' == BranchScope.branchId)
        .firstOrNull;

    if (isBusiness) {
      final org = BranchScope.organizationId;
      final profile = employeeWorkspaceCompany != null && org != null
          ? ref.watch(myEmployeeProfileForProvider(org)).valueOrNull
          : null;
      final employee = profile?['employee'] as Map?;
      return _buildBusinessHeader(
        l10n: l10n,
        currentBranch: currentBranch,
        companies: branchCompanies,
        showSwitch: showBranchSwitch,
        employee: employee?['full_name']?.toString().trim().isNotEmpty == true
            ? Map<String, dynamic>.from(employee!)
            : null,
        employeeCompany: employeeWorkspaceCompany,
      );
    }

    void openProfile() {
      if (!canEditProfile) return;
      Navigator.pop(context);
      GoRouter.of(
        context,
      ).push(RouteNames.profileForMode(ref.read(currentBusinessTypeProvider)));
    }

    Widget profileTap({required Widget child}) => canEditProfile
        ? GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: openProfile,
            child: child,
          )
        : child;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
      child: Column(
        children: [
          profileTap(
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.primary, width: 3),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withAlpha(60),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: ClipOval(
                child: isBusiness
                    ? (section.avatar != null
                          ? Image.memory(
                              section.avatar!,
                              fit: BoxFit.cover,
                              width: 80,
                              height: 80,
                            )
                          : orgAvatar != null
                          ? SecureImage(
                              url: orgAvatar,
                              fit: BoxFit.cover,
                              width: 80,
                              height: 80,
                              errorBuilder: (_, __, ___) => _businessFallback(),
                            )
                          : _businessFallback())
                    : Image.asset(
                        Theme.of(context).brightness == Brightness.dark
                            ? 'assets/images/fyona_logo_light.png'
                            : 'assets/images/fyona_logo_dark.png',
                        fit: BoxFit.contain,
                        width: 80,
                        height: 80,
                        errorBuilder: (_, __, ___) => Icon(
                          Icons.person,
                          size: 34,
                          color: AppColors.textTertiary,
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              profileTap(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.primary, width: 2),
                  ),
                  child: ClipOval(
                    child: isBusiness
                        ? (section.avatar != null
                              ? Image.memory(
                                  section.avatar!,
                                  fit: BoxFit.cover,
                                  width: 44,
                                  height: 44,
                                )
                              : orgAvatar != null
                              ? SecureImage(
                                  url: orgAvatar,
                                  fit: BoxFit.cover,
                                  width: 44,
                                  height: 44,
                                  errorBuilder: (_, __, ___) =>
                                      _businessFallback(small: true),
                                )
                              : _businessFallback(small: true))
                        : (personalAvatar != null
                              ? Image.memory(
                                  personalAvatar,
                                  gaplessPlayback: true,
                                  fit: BoxFit.cover,
                                  width: 44,
                                  height: 44,
                                )
                              : Icon(
                                  Icons.person,
                                  size: 22,
                                  color: Colors.white60,
                                )),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: profileTap(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: AlignmentDirectional.centerEnd,
                          child: Text(
                            name,
                            maxLines: 1,
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 14),
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if ((user?.verificationLevel ?? 0) > 0) ...[
                      const SizedBox(width: 4),
                      profileTap(
                        child: PlanVerificationBadge(
                          level: user?.verificationLevel ?? 0,
                          size: 18,
                        ),
                      ),
                    ],
                    if (showBranchSwitch) ...[
                      const Spacer(),
                      _branchSwitchButton(currentBranch, branchCompanies),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBusinessHeader({
    required AppLocalizations l10n,
    required Map<String, dynamic>? currentBranch,
    required List<Map<String, dynamic>> companies,
    required bool showSwitch,
    Map<String, dynamic>? employee,
    Map<String, dynamic>? employeeCompany,
  }) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final branchName = BranchScope.allMode
        ? l10n.translate('branchAllShort')
        : '${currentBranch?['name'] ?? BranchScope.branchName ?? l10n.translate('branchMain')}';
    void openEmployeeProfile() {
      final router = GoRouter.of(context);
      Navigator.pop(context);
      router.push('/employee-profile');
    }

    if (employee != null) {
      final photo = _absoluteUrl(employee['photo_url'] as String?);
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 26, 20, 12),
        child: Column(
          children: [
            GestureDetector(
              onTap: openEmployeeProfile,
              child: Container(
                width: 80,
                height: 80,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.primary, width: 2),
                ),
                child: photo == null
                    ? _businessFallback()
                    : SecureImage(
                        url: photo,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _businessFallback(),
                      ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: GestureDetector(
                    onTap: openEmployeeProfile,
                    child: Text(
                      '${employee['full_name'] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ),
                if ((widget.user?.verificationLevel ?? 0) > 0) ...[
                  const SizedBox(width: 4),
                  PlanVerificationBadge(
                    level: widget.user!.verificationLevel,
                    size: 18,
                  ),
                ],
                const SizedBox(width: 8),
                if (showSwitch)
                  _branchSwitchButton(currentBranch, companies)
                else
                  _branchCircleImage(
                    currentBranch,
                    size: 36,
                    allMode: BranchScope.allMode,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${employeeCompany?['organization_name'] ?? ''} • $branchName',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 11,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 12),
      child: Column(
        children: [
          Image.asset(
            dark
                ? 'assets/images/fyona_logo_light.png'
                : 'assets/images/fyona_logo_dark.png',
            width: 80,
            height: 80,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => Icon(
              Icons.storefront_rounded,
              size: 44,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 14),
          // ONE line: the branch name is pinned to the RIGHT edge, its logo
          // sits on the left, and the switch arrow is beside the logo (left),
          // never above it and never duplicated.
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      branchName,
                      maxLines: 1,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (showSwitch)
                _branchSwitchButton(currentBranch, companies)
              else
                SizedBox(
                  width: 40,
                  height: 40,
                  child: ClipOval(
                    child: _branchCircleImage(
                      currentBranch,
                      size: 40,
                      allMode: BranchScope.allMode,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _businessFallback({bool small = false}) => Container(
    color: AppColors.primary.withAlpha(18),
    alignment: Alignment.center,
    child: Icon(
      Icons.storefront_rounded,
      size: small ? 22 : 34,
      color: AppColors.primary,
    ),
  );

  String? _absoluteUrl(String? raw) {
    return serverImageUrl(raw);
  }

  Widget _buildBranchManagementItem() {
    final l10n = AppLocalizations.of(context);
    if (widget.currentRoute.startsWith('/personal')) {
      return const SizedBox.shrink();
    }
    final user = widget.user;
    final isOwner =
        (user?.role ?? '').toLowerCase() == 'owner' ||
        (user?.isPlatformAdmin ?? false);
    if (!isOwner) return const SizedBox.shrink();
    return _drawerItem(
      icon: TwoToneIcons.building,
      label: l10n.translate('branchManagement'),
      subtitle: l10n.translate('branchManagementHint'),
      accentColor: AppColors.primary,
      active: widget.currentRoute.startsWith('/branches'),
      trailing: Icon(
        Icons.chevron_left_rounded,
        size: 18,
        color: AppColors.textSecondary,
      ),
      onTap: () {
        Navigator.pop(context);
        GoRouter.of(context).push('/branches');
      },
    );
  }

  void _precacheBranchImages(List<Map<String, dynamic>> branches) {
    final urls = <String>[];
    for (final b in branches) {
      final u = _branchImage(b);
      if (u != null && _precachedBranches.add(u)) urls.add(u);
    }
    if (urls.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final u in urls) {
        precacheImage(CachedNetworkImageProvider(u), context);
      }
    });
  }

  String? _branchImage(Map<String, dynamic>? branch) => versionedServerImageUrl(
    '${branch?['image'] ?? ''}'.trim().isNotEmpty
        ? '${branch?['image']}'
        : _branchPictures['${branch?['id']}'] != null
        ? _branchPictures['${branch?['id']}']!
        : (branch?['is_default'] == true &&
                  '${branch?['organization_id']}' == widget.user?.organizationId
              ? '${widget.user?.organizationAvatar ?? ''}'
              : ''),
    branch?['image_version']?.toString(),
  );

  Widget _branchCircleImage(
    Map<String, dynamic>? branch, {
    double size = 36,
    bool allMode = false,
  }) {
    final saved = _branchPictures['${branch?['id']}'] ?? '';
    final onDevice = !allMode &&
        '${branch?['image'] ?? ''}'.trim().isEmpty &&
        saved.startsWith('local://');
    final image = onDevice ? null : _branchImage(branch);
    if (onDevice) {
      return Container(
        width: size,
        height: size,
        clipBehavior: Clip.antiAlias,
        decoration: const BoxDecoration(shape: BoxShape.circle),
        child: Image.file(
          File(saved.substring('local://'.length)),
          fit: BoxFit.cover,
          width: size,
          height: size,
          errorBuilder: (_, _, _) => Container(
            color: AppColors.primary.withAlpha(18),
            alignment: Alignment.center,
            child: Icon(
              Icons.storefront_rounded,
              size: size * .5,
              color: AppColors.primary,
            ),
          ),
        ),
      );
    }
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: const BoxDecoration(shape: BoxShape.circle),
      child: allMode
          ? Container(
              color: AppColors.primary.withAlpha(18),
              alignment: Alignment.center,
              child: Icon(
                Icons.hub_rounded,
                size: size * .5,
                color: AppColors.primary,
              ),
            )
          : image != null || branch?['id'] != null
          ? SecureImage(
              // Keeps the last copy on the device: the picture stays offline
              // (even when this device saved no address for it).
              url: image,
              deviceKey: 'branch_${branch?['id']}',
              fit: BoxFit.cover,
              width: size,
              height: size,
              placeholder: Container(
                color: AppColors.primary.withAlpha(18),
                alignment: Alignment.center,
                child: Icon(
                  Icons.storefront_rounded,
                  size: size * .5,
                  color: AppColors.primary,
                ),
              ),
              errorBuilder: (_, __, ___) => Container(
                color: AppColors.primary.withAlpha(18),
                alignment: Alignment.center,
                child: Icon(
                  Icons.storefront_rounded,
                  size: size * .5,
                  color: AppColors.primary,
                ),
              ),
            )
          : Container(
              color: AppColors.primary.withAlpha(18),
              alignment: Alignment.center,
              child: Icon(
                Icons.storefront_rounded,
                size: size * .5,
                color: AppColors.primary,
              ),
            ),
    );
  }

  Widget _branchSwitchButton(
    Map<String, dynamic>? current,
    List<Map<String, dynamic>> companies, {
    Widget? identityAvatar,
  }) {
    return GestureDetector(
      key: _branchSwitchKey,
      onTap: () => _openBranchMenu(companies),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: ClipOval(
              child:
                  identityAvatar ??
                  _branchCircleImage(
                    current,
                    size: 36,
                    allMode: BranchScope.allMode,
                  ),
            ),
          ),
          const SizedBox(width: 1),
          const Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 18,
            color: AppColors.primary,
          ),
        ],
      ),
    );
  }

  Future<void> _openBranchMenu(List<Map<String, dynamic>> companies) async {
    final l10n = AppLocalizations.of(context);
    final items = <PopupMenuEntry<String>>[];
    final user = ref.read(currentUserProvider) ?? widget.user;
    final ownOrganizationId = user?.organizationId ?? '__self__';
    for (final memberSection in [false, true]) {
      final sectionCompanies = companies.where(
        (c) => (c['organization_id'] != ownOrganizationId) == memberSection,
      );
      if (sectionCompanies.isEmpty) continue;
      if (items.isNotEmpty) items.add(const PopupMenuDivider());
      items.add(
        PopupMenuItem<String>(
          enabled: false,
          child: Text(
            l10n.locale.languageCode == 'ar'
                ? (memberSection ? 'الفروع حق التجار' : 'الفروع حقك')
                : (memberSection ? 'Merchant branches' : 'Your branches'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontWeight: FontWeight.w800,
              color: AppColors.primary,
            ),
          ),
        ),
      );
      for (final c in sectionCompanies) {
        final orgId = '${c['organization_id'] ?? ''}';
        final orgName = '${c['organization_name'] ?? ''}';
        final branches = (c['branches'] as List? ?? const []).whereType<Map>();
        if (branches.length > 1) {
          items.add(
            _branchMenuItem(
              value: '$orgId|__all__',
              label: l10n.translate('branchAllShort'),
              subtitle: '',
              selected:
                  BranchScope.organizationId == orgId && BranchScope.allMode,
              allMode: true,
            ),
          );
        }
        for (final b in branches) {
          final branch = Map<String, dynamic>.from(b);
          branch['organization_id'] = orgId;
          items.add(
            _branchMenuItem(
              value: '$orgId|${branch['id']}',
              label: '${branch['name'] ?? ''}',
              subtitle: '',
              selected:
                  BranchScope.organizationId == orgId &&
                  !BranchScope.allMode &&
                  BranchScope.branchId == '${branch['id']}',
              branch: branch,
            ),
          );
        }
      }
    }
    if (items.isEmpty) return;

    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final box =
        _branchSwitchKey.currentContext?.findRenderObject() as RenderBox?;
    RelativeRect position = const RelativeRect.fromLTRB(40, 120, 40, 120);
    if (overlay != null && box != null) {
      final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
      final top = topLeft.dy + box.size.height + 6;
      final left = topLeft.dx.clamp(
        8.0,
        (overlay.size.width - 290).clamp(8.0, double.infinity),
      );
      // Anchor BELOW the circle: large available bottom, zero forced bottom
      // inset, so the popup never covers the circle above it.
      position = RelativeRect.fromLTRB(
        left,
        top,
        overlay.size.width - left - 282,
        0,
      );
    }
    final picked = await showMenu<String>(
      context: context,
      position: position,
      color: AppColors.surface,
      elevation: 18,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      constraints: const BoxConstraints(minWidth: 250, maxWidth: 290),
      items: items,
    );
    if (picked == null || !mounted) return;
    await _applyBranchSelection(picked);
  }

  PopupMenuItem<String> _branchMenuItem({
    required String value,
    required String label,
    required String subtitle,
    required bool selected,
    Map<String, dynamic>? branch,
    bool allMode = false,
    bool personal = false,
  }) {
    _branchLabels[value] = label;
    return PopupMenuItem<String>(
      value: value,
      height: subtitle.isEmpty ? 54 : 64,
      child: Row(
        children: [
          personal
              ? Icon(Icons.person_rounded, size: 34, color: AppColors.primary)
              : _branchCircleImage(branch, size: 34, allMode: allMode),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 9.5,
                      color: AppColors.textTertiary,
                    ),
                  ),
              ],
            ),
          ),
          if (selected)
            const Icon(
              Icons.check_circle_rounded,
              size: 18,
              color: AppColors.primary,
            ),
        ],
      ),
    );
  }

  Future<void> _applyBranchSelection(String picked) async {
    final l10n = AppLocalizations.of(context);
    final container = ProviderScope.containerOf(context, listen: false);
    final router = GoRouter.of(context);
    final scaffold = Scaffold.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final from = BranchScope.allMode
        ? l10n.translate('branchAllShort')
        : BranchScope.branchName ?? l10n.translate('business');
    try {
      if (picked.endsWith('|__main__')) {
        final company = ref.read(employeeWorkspaceCompanyProvider);
        await PremiumSwitch.run(
          kind: PremiumSwitchKind.branch,
          from: company?['organization_name']?.toString() ?? from,
          to: l10n.translate('branchMain'),
          arabic: l10n.locale.languageCode == 'ar',
          action: () async {
            // Keep the branch selection: returning from Personal must land on
            // the same branch the user left, never on the main one.
            container.read(activeSectionProvider.notifier).state =
                AppSection.personal;
            container.read(branchEpochProvider.notifier).state++;
            container.invalidate(branchAccessProvider);
            container.invalidate(branchesProvider);
            container.invalidate(businessAccountsProvider);
            container.invalidate(businessRecentProvider);
            scaffold.closeDrawer();
            router.go('/personal');
          },
        );
        return;
      }
      final parts = picked.split('|');
      final orgId = parts.first;
      final branchId = parts.length > 1 ? parts[1] : '';
      final alreadySelected =
          orgId == BranchScope.organizationId &&
          ((branchId == '__all__' && BranchScope.allMode) ||
              (!BranchScope.allMode && branchId == BranchScope.branchId));
      if (alreadySelected && !widget.currentRoute.startsWith('/personal')) {
        return;
      }
      await PremiumSwitch.run(
        kind: PremiumSwitchKind.branch,
        from: from,
        to: _branchLabels[picked] ?? l10n.translate('branchAllShort'),
        arabic: l10n.locale.languageCode == 'ar',
        action: () async {
          container.read(branchSwitchingProvider.notifier).state = true;
          try {
            final api = container.read(branchApiProvider);
            if (!alreadySelected || !api.ownsSavedSelection) {
              await api.selectFromDrawer(
                organizationId: orgId,
                branchId: branchId == '__all__' ? null : branchId,
                all: branchId == '__all__',
                connected: container.read(connectivityServiceProvider).isOnline,
              );
            }
            final user = container.read(currentUserProvider) ?? widget.user;
            if (orgId != user?.organizationId) {
              await BranchScope.setHasMembership(true);
            }
            container.read(activeSectionProvider.notifier).state =
                AppSection.business;
            container.read(branchEpochProvider.notifier).state++;
            container.invalidate(branchesProvider);
            container.invalidate(branchAccessProvider);
            scaffold.closeDrawer();
            router.go(RouteNames.dashboard);
          } finally {
            container.read(branchSwitchingProvider.notifier).state = false;
          }
        },
      );
    } catch (e) {
      if (messenger.mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              isConnectionError(e)
                  ? l10n.translate('noInternet')
                  : l10n.translate('networkError'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
        );
      }
    }
  }

  // ── Subscription Item ──
  Widget _buildSubscriptionItem() {
    final l10n = AppLocalizations.of(context);
    return _drawerItem(
      icon: TwoToneIcons.crown,
      label: l10n.translate('activateSubscription'),
      active: widget.currentRoute.startsWith(RouteNames.subscription),
      onTap: () {
        Navigator.pop(context);
        GoRouter.of(context).push(RouteNames.subscription);
      },
    );
  }

  // ── Suggestions Item ──
  Widget _buildSuggestionsItem() {
    final l10n = AppLocalizations.of(context);
    final unread = ref.watch(suggestionUnreadCountProvider).valueOrNull ?? 0;
    return _drawerItem(
      icon: TwoToneIcons.suggestions,
      label: l10n.translate('appFeedbackSuggestions'),
      subtitle: l10n.translate('appFeedbackSuggestionsHint'),
      active: widget.currentRoute == RouteNames.suggestions,
      trailing: unread > 0 ? _UnreadBadge(count: unread) : null,
      onTap: () {
        Navigator.pop(context);
        GoRouter.of(context).push(RouteNames.suggestions);
      },
    );
  }

  // ── Mode Toggle ──
  Iterable<Map<String, dynamic>> _merchantDestinations(
    List<Map<String, dynamic>>? companies,
    String? ownOrganization,
  ) => (companies ?? const <Map<String, dynamic>>[]).where(
    (company) =>
        company['role'] == 'member' &&
        company['organization_id'] != ownOrganization &&
        BranchApi.companyIsOpen(company) &&
        BranchApi.selectableBranches(company).isNotEmpty,
  );

  Widget _buildModeToggle() {
    final l10n = AppLocalizations.of(context);
    final isPersonal = widget.currentRoute.startsWith('/personal');
    final user = ref.watch(currentUserProvider) ?? widget.user;
    final status = ref.watch(subscriptionStatusProvider).asData?.value;
    final businessStatus = isPersonal
        ? ref.watch(businessNavigationStatusProvider).asData?.value
        : null;
    final companies = ref.watch(branchMenuAccessProvider).asData?.value;
    final hasMerchant = _merchantDestinations(
      companies,
      user?.organizationId,
    ).isNotEmpty;
    final isAdmin = user?.isPlatformAdmin ?? false;
    final canSwitch =
        isAdmin ||
        (isPersonal
            ? hasMerchant || hasSectionAccess(businessStatus, 'business')
            // Offline — or the server can't be reached right now — the
            // switch stays: each section opens from what the device saved.
            : (user != null &&
                      (!ref.read(connectivityServiceProvider).isOnline ||
                          ref.watch(subscriptionStatusProvider).hasError)) ||
                  (companies?.any((c) => c['role'] == 'member') ?? false) ||
                  (hasSectionAccess(status, 'personal') &&
                      hasSectionAccess(status, 'business')));
    if (!canSwitch) return const SizedBox.shrink();
    return _drawerItem(
      icon: isPersonal ? TwoToneIcons.building : TwoToneIcons.userCircle,
      label: isPersonal
          ? l10n.translate('switchToBusiness')
          : l10n.translate('switchToPersonal'),
      accentColor: AppColors.primary,
      active: false,
      onTap: () async {
        final newMode = isPersonal ? 'business' : 'personal';
        final container = ProviderScope.containerOf(context, listen: false);
        final router = GoRouter.of(context);
        final scaffold = Scaffold.of(context);
        try {
          final memberships = _merchantDestinations(
            ref.read(branchMenuAccessProvider).asData?.value,
            user?.organizationId,
          ).toList();
          final status = isPersonal
              ? ref.read(businessNavigationStatusProvider).asData?.value
              : user != null
              ? await resolvePersonalEntry(
                  connected: ref.read(connectivityServiceProvider).isOnline,
                  live: () => ref.refresh(subscriptionStatusProvider.future),
                  local: () =>
                      ref.read(personalOfflineAccessProvider).read(user),
                )
              : await ref.refresh(subscriptionStatusProvider.future);
          if (!mounted) return;
          if (!hasSectionAccess(status, newMode) &&
              !(isPersonal && memberships.isNotEmpty) &&
              !isAdmin) {
            final subscribe = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(
                  l10n.translate(
                    newMode == 'business' ? 'business' : 'personal',
                  ),
                ),
                content: Text(l10n.translate('sectionSubscriptionRequired')),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(l10n.translate('cancel')),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(l10n.translate('activateSubscription')),
                  ),
                ],
              ),
            );
            if (subscribe == true && mounted) {
              Navigator.pop(context);
              context.push(RouteNames.subscription);
            }
            return;
          }
          final api = isPersonal ? container.read(branchApiProvider) : null;
          final existing = api?.ownsSavedSelection == true;
          final savedMerchant =
              existing && BranchScope.organizationId != user?.organizationId;
          if (savedMerchant &&
              !memberships.any(
                (company) =>
                    company['organization_id'] == BranchScope.organizationId &&
                    (BranchScope.allMode
                        ? BranchApi.selectableBranches(company).length > 1
                        : BranchApi.selectableBranches(
                            company,
                          ).any((row) => row['id'] == BranchScope.branchId)),
              )) {
            throw StateError('Saved branch is no longer available');
          }
          await PremiumSwitch.run(
            kind: isPersonal
                ? PremiumSwitchKind.business
                : PremiumSwitchKind.personal,
            from: l10n.translate(isPersonal ? 'personal' : 'business'),
            to: l10n.translate(newMode),
            arabic: l10n.locale.languageCode == 'ar',
            action: () async {
              // Returning does not select (or reselect) a saved branch over
              // the network. A first-time merchant entry has no branch yet.
              if (api != null && !existing && memberships.isNotEmpty) {
                final company = memberships.first;
                await api.selectFromDrawer(
                  organizationId: '${company['organization_id']}',
                  branchId:
                      '${BranchApi.selectableBranches(company).first['id']}',
                  all: false,
                  connected: container
                      .read(connectivityServiceProvider)
                      .isOnline,
                );
                await BranchScope.setHasMembership(true);
              } else if (savedMerchant) {
                await BranchScope.setHasMembership(true);
              }
              scaffold.closeDrawer();
              container.read(branchEpochProvider.notifier).state++;
              container
                  .read(activeSectionProvider.notifier)
                  .state = newMode == 'business'
                  ? AppSection.business
                  : AppSection.personal;
              await container.read(authProvider.notifier).setUsageMode(newMode);
              router.go(
                isPersonal
                    ? RouteNames.dashboard
                    : RouteNames.personalDashboard,
              );
              await WidgetsBinding.instance.endOfFrame;
              if (!isPersonal) {
                try {
                  await container
                      .read(personalFinanceProvider.notifier)
                      .load()
                      .timeout(const Duration(seconds: 8));
                } catch (_) {}
              }
            },
          );
        } catch (_) {
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.translate('coreNetworkError'))),
            );
          return;
        }
      },
    );
  }

  // ── Contact Support (expandable: WhatsApp + Phone) ──
  Widget _buildContactSupportItem() {
    final l10n = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _drawerItem(
          icon: TwoToneIcons.headphones,
          label: l10n.translate('contactSupportTitle'),
          accentColor: AppColors.primary,
          active: false,
          trailing: AnimatedRotation(
            turns: _contactExpanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 200),
            child: Icon(
              Icons.keyboard_arrow_down,
              size: 18,
              color: AppColors.textSecondary,
            ),
          ),
          onTap: () => setState(() => _contactExpanded = !_contactExpanded),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: _contactExpanded
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      // WhatsApp
                      _contactOption(
                        iconPath: 'assets/images/connect/WhatsApp.png',
                        label: l10n.translate('contactSupportWhatsApp'),
                        number: '+967775977597',
                        bgColor: const Color(0xFF25D366).withAlpha(15),
                        borderColor: const Color(0xFF25D366).withAlpha(50),
                        onTap: () async {
                          Navigator.pop(context);
                          final uri = Uri.parse('https://wa.me/967775977597');
                          try {
                            await launchUrl(
                              uri,
                              mode: LaunchMode.externalApplication,
                            );
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.translate('whatsappNotInstalled'),
                                    style: TextStyle(fontFamily: 'Cairo'),
                                  ),
                                  backgroundColor: AppColors.warning,
                                ),
                              );
                            }
                          }
                        },
                      ),
                      const SizedBox(width: 10),
                      // Phone call
                      _contactOption(
                        iconPath: 'assets/images/connect/Call.png',
                        label: l10n.translate('contactSupportCall'),
                        number: '+967775977597',
                        bgColor: AppColors.primary.withAlpha(15),
                        borderColor: AppColors.primary.withAlpha(50),
                        onTap: () async {
                          Navigator.pop(context);
                          final uri = Uri.parse('tel:+967775977597');
                          try {
                            await launchUrl(
                              uri,
                              mode: LaunchMode.externalApplication,
                            );
                          } catch (_) {}
                        },
                      ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  // ── Contact Option (professional card style) ──
  Widget _contactOption({
    required String iconPath,
    required String label,
    required String number,
    required VoidCallback onTap,
    required Color bgColor,
    required Color borderColor,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor, width: 1.2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset(
                  iconPath,
                  width: 32,
                  height: 32,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 11),
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 2),
              Text(
                number,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 9),
                  color: AppColors.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Reusable Drawer Item ──
  Widget _drawerItem({
    required TwoToneIconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
    String? subtitle,
    Widget? trailing,
    Color? accentColor,
  }) {
    final ac = accentColor ?? AppColors.textSecondary;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: ListTile(
        leading: AppIcon(
          twoToneIcon: icon,
          style: AppIconStyle.badge,
          size: 40,
          iconSize: 20,
          backgroundColor: active
              ? AppColors.primary.withAlpha(25)
              : AppColors.surfaceVariant,
          borderColor: active
              ? AppColors.primary.withAlpha(50)
              : AppColors.border,
          accentColor: active ? AppColors.primary : ac,
          color: active ? AppColors.primary : ac,
        ),
        title: Text(
          label,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 15),
            fontWeight: active ? FontWeight.w700 : FontWeight.w600,
            color: active ? AppColors.primary : AppColors.textPrimary,
          ),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 11),
                  color: AppColors.textDisabled,
                ),
              ),
        trailing: trailing,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        selected: active,
        selectedTileColor: AppColors.primary.withAlpha(15),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.smBorder),
        onTap: onTap,
      ),
    );
  }
}

/// Small circular unread-count badge shown on the suggestions drawer item.
class _UnreadBadge extends StatelessWidget {
  final int count;
  const _UnreadBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.danger,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontFamily: 'Cairo',
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}
