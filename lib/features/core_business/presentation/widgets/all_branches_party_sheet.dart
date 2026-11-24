import 'package:flutter/material.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import 'debt_widgets.dart';

/// «جميع الفروع» party: read-only summary of its open debts, the total over
/// every branch and each branch's own share. No action can be started here.
Future<void> showAllBranchesPartySheet(
  BuildContext context,
  Map<String, dynamic> party,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  backgroundColor: AppColors.surface,
  builder: (context) => SafeArea(child: AllBranchesPartySummary(party: party)),
);

/// The open debts of a merged party (per currency) and, per branch, the
/// same figures — what the merchant needs to see his whole position.
class AllBranchesPartySummary extends StatelessWidget {
  const AllBranchesPartySummary({super.key, required this.party});
  final Map<String, dynamic> party;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final members = (party['members'] as List? ?? const []).whereType<Map>();
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      children: [
        Text(
          '${party['name'] ?? ''}',
          style: DebtStyle.text(context, size: 18, bold: true),
        ),
        const SizedBox(height: 12),
        Text(
          l10n.translate('allBranchesTotal'),
          style: DebtStyle.text(context, size: 13, color: AppColors.textSecondary),
        ),
        _Debts(debts: party['debts'] as List? ?? const []),
        const SizedBox(height: 16),
        Text(
          l10n.translate('allBranchesPerBranch'),
          style: DebtStyle.text(context, size: 13, color: AppColors.textSecondary),
        ),
        for (final member in members)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: DebtStyle.surface(context),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: DebtStyle.border(context)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${member['branch_name'] ?? ''}'.trim().isEmpty
                      ? l10n.translate('allBranchesUnnamed')
                      : '${member['branch_name']}',
                  style: DebtStyle.text(context, size: 14, bold: true),
                ),
                _Debts(debts: member['debts'] as List? ?? const []),
              ],
            ),
          ),
      ],
    );
  }
}

class _Debts extends StatelessWidget {
  const _Debts({required this.debts});
  final List debts;

  @override
  Widget build(BuildContext context) {
    final rows = [
      for (final debt in debts.whereType<Map>())
        if (num.tryParse('${debt['total']}') != 0) debt,
    ];
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          AppLocalizations.of(context).translate('allBranchesNoDebt'),
          style: DebtStyle.text(context, size: 13, color: AppColors.textSecondary),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final debt in rows)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${debtAmount(debt['total'])} ${debt['currency']}',
              textDirection: TextDirection.ltr,
              style: DebtStyle.text(context, size: 15, bold: true, color: DebtStyle.red),
            ),
          ),
      ],
    );
  }
}

/// One line under a merged party's name: the branches it deals with.
String allBranchesPartyLine(BuildContext context, Map party) {
  final names = [
    for (final name in (party['branch_names'] as List? ?? const []))
      '$name'.trim().isEmpty
          ? AppLocalizations.of(context).translate('allBranchesUnnamed')
          : '$name',
  ];
  return AppLocalizations.of(
    context,
  ).translate('allBranchesPartyBranches', params: {'names': names.join('، ')});
}
