import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../data/branch_api.dart';
import '../../data/branch_epoch.dart';
import '../../data/branch_scope.dart';

/// Label for the Business header branch chip, or null when no chip should be
/// shown (the current company has a single branch, or nothing is known yet).
///
/// Pure so it can be tested without a device: [companies] is the
/// `/branches/access` shape (saved on device, so it also works offline).
String? businessBranchChipLabel({
  required List<Map<String, dynamic>> companies,
  required String? scopeOrganizationId,
  required String? ownOrganizationId,
  required String? branchId,
  required String? branchName,
  required bool allMode,
  required String allBranchesLabel,
  required String mainBranchLabel,
}) {
  final org = scopeOrganizationId ?? ownOrganizationId;
  Map<String, dynamic>? company;
  for (final c in companies) {
    if (org != null && '${c['organization_id']}' == org) {
      company = c;
      break;
    }
  }
  if (company == null && org == null && companies.length == 1) {
    company = companies.first;
  }
  if (company == null) return null;
  final rows = BranchApi.selectableBranches(company).toList();
  if (rows.length < 2) return null;
  if (allMode) return allBranchesLabel;
  for (final row in rows) {
    if (branchId != null && '${row['id']}' == branchId) {
      final n = '${row['name'] ?? ''}'.trim();
      if (n.isNotEmpty) return n;
    }
  }
  final saved = branchName?.trim();
  if (saved != null && saved.isNotEmpty) return saved;
  return mainBranchLabel;
}

/// Small chip under the «قسم الأعمال» title naming the branch in use. Hidden
/// entirely when the merchant has only one branch. Rebuilds on every switch.
class BusinessBranchChip extends ConsumerWidget {
  const BusinessBranchChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(branchEpochProvider);
    final companies =
        ref.watch(branchMenuAccessProvider).asData?.value ?? const [];
    final l10n = AppLocalizations.of(context);
    final label = businessBranchChipLabel(
      companies: companies,
      scopeOrganizationId: BranchScope.organizationId,
      ownOrganizationId: ref.watch(currentUserProvider)?.organizationId,
      branchId: BranchScope.branchId,
      branchName: BranchScope.branchName,
      allMode: BranchScope.allMode,
      allBranchesLabel: l10n.translate('branchAllShort'),
      mainBranchLabel: l10n.translate('branchMain'),
    );
    if (label == null) return const SizedBox.shrink();
    return BranchChipView(label: label, allMode: BranchScope.allMode);
  }
}

/// Visual of the chip (theme-aware through the mode-aware [AppColors]).
///
/// Sits on its own line under the section title, so it may use the whole
/// header width: the full branch name shows, with an ellipsis only when the
/// name is truly longer than the available space (capped at [maxWidth]).
class BranchChipView extends StatelessWidget {
  const BranchChipView({super.key, required this.label, this.allMode = false});

  final String label;
  final bool allMode;

  static const double maxWidth = 320;

  @override
  Widget build(BuildContext context) {
    final light = AppColors.isLightMode;
    final accent = light ? AppColors.primary : AppColors.primaryLight;
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: Container(
          key: const ValueKey('business-branch-chip'),
          padding: const EdgeInsetsDirectional.fromSTEB(8, 2, 10, 2),
          decoration: BoxDecoration(
            color: AppColors.primary.withAlpha(light ? 16 : 30),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: AppColors.primary.withAlpha(light ? 60 : 80),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                allMode ? Icons.account_tree_outlined : Icons.storefront_outlined,
                size: 13,
                color: accent,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 11.5),
                    fontWeight: FontWeight.w700,
                    height: 1.4,
                    color: light ? AppColors.textPrimary : AppColors.textPrimary.withAlpha(235),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
