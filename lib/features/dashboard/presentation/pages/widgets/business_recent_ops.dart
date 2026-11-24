import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fyona_flutter/core/utils/document_number.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../../core/localization/app_localizations.dart';
import '../../../../../core/responsive/r_api.dart';
import '../../../../../core/router/route_names.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/utils/currency_formatter.dart';
import '../../../../../shared/widgets/two_tone_icon.dart';
import '../../../../../shared/widgets/two_tone_icons.dart';
import '../../providers/business_dashboard_providers.dart';
import '../../../../branches/data/branch_scope.dart';
import '../../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../../core_business/presentation/providers/local_commerce_navigation.dart';

/// «أحدث العمليات» on the business home — the EXACT visual design of the
/// personal home's «آخر المعاملات» section (same header, same row metrics,
/// same two-tone arrows, same amount/date column), fed by the unified
/// business transactions timeline. Newest 5; refreshes on pull-to-refresh
/// and whenever the user returns from any pushed page.
class BusinessRecentOps extends ConsumerWidget {
  const BusinessRecentOps({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final recent = ref.watch(businessRecentProvider);

    // Show the section ONLY when there are real transactions — the header,
    // the «عرض الكل» button and the list all hide together otherwise.
    final items = recent.isReloading ? null : recent.valueOrNull;
    if (items == null || items.isEmpty) return const SizedBox.shrink();
    final scope = ref.watch(businessLocalLedgerScopeProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                l10n.translate('bizRecentOps'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 16),
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => context.push(RouteNames.businessTransactions),
                child: Text(
                  l10n.translate('viewAll'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Column(children: [
            for (final t in items)
              if (scope == null || t['branch_id'] == scope.branchId)
                _RecentTxTile(tx: t, onTap: () async {
                  if (!sameDirectoryScope(
                      scope, ref.read(businessLocalLedgerScopeProvider))) return;
                  await openCommerceRecord(context, RouteNames.businessTransactionDetails,
                      '${t['source_id']}', kind: '${t['source_type']}', fromLocal: scope);
                  if (context.mounted) ref.invalidate(businessRecentProvider);
                }),
          ]),
        ],
      ),
    );
  }
}

/// One row — metrics/styles copied from the personal home's transaction tile.
class _RecentTxTile extends ConsumerWidget {
  final Map<String, dynamic> tx;
  final VoidCallback onTap;
  const _RecentTxTile({required this.tx, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final isIn = tx['direction'] == 'in';
    final color = isIn ? AppColors.success : AppColors.danger;
    final iconData = isIn ? TwoToneIcons.arrowDown : TwoToneIcons.arrowUp;
    final amount = asDoubleValue(tx['amount']);
    final currency = (tx['currency'] ?? '').toString();
    final amtNum = '${isIn ? '+' : '-'}${fmtNum(amount)}';
    final cur = currency.isEmpty ? '' : currencyLabel(currency);

    String date = '';
    final iso = (tx['date'] ?? '').toString();
    if (iso.isNotEmpty) {
      final d = DateTime.tryParse(iso)?.toLocal();
      if (d != null) date = DateFormat('yyyy-MM-dd').format(d);
    }

    final kind = _kindLabel((tx['kind'] ?? '').toString(), l10n);
    final party = (tx['party'] ?? '').toString();
    final reference = shortDocumentNumber(tx['reference']);
    final branchName = (tx['branch_name'] ?? '').toString();
    final branchLabel = BranchScope.allMode && branchName.isNotEmpty
        ? l10n.translate('branchOfTransaction', params: {'name': branchName})
        : '';
    final baseSub = party.isNotEmpty
        ? party
        : (reference.isNotEmpty ? reference : '');
    final sub = [
      if (branchLabel.isNotEmpty) branchLabel,
      baseSub,
    ].where((e) => e.isNotEmpty).join('  •  ');

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(
            bottom: BorderSide(color: AppColors.divider, width: 1),
          ),
        ),
        child: Row(
          children: [
            TwoToneIcon(
              data: iconData,
              detailColor: AppColors.primary,
              outlineColor: AppColors.textSecondary,
              size: 22,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    kind,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 14),
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  if (sub.isNotEmpty)
                    Text(
                      sub,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11),
                        fontWeight: FontWeight.w400,
                        color: AppColors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text.rich(
                  TextSpan(
                    text: amtNum,
                    children: [
                      if (cur.isNotEmpty)
                        TextSpan(
                          text: '  $cur',
                          style: TextStyle(
                            fontSize: R.fontSize(context, 9),
                            fontWeight: FontWeight.w600,
                            color: AppColors.textSecondary,
                          ),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 14),
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
                Text(
                  date,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 10),
                    fontWeight: FontWeight.w400,
                    color: AppColors.textDisabled,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _kindLabel(String k, AppLocalizations l10n) {
    const keys = {
      'sale': 'txKindSale',
      'purchase': 'txKindPurchase',
      'sale_return': 'txKindSaleReturn',
      'purchase_return': 'txKindPurchaseReturn',
      'collection': 'txKindCollection',
      'supplier_payment': 'txKindSupplierPayment',
      'income': 'txKindIncome',
      'expense': 'txKindExpense',
      'transfer': 'txKindTransfer',
      'transfer_reversal': 'txKindTransferReversal',
      'inventory_transfer': 'txKindInventoryTransfer',
      'bank_withdrawal': 'txKindBankWithdrawal',
      'withdrawal_reversal': 'bizCashWithdrawalReversed',
      'reconciliation': 'reconMovement',
      'opening': 'txKindOpening',
    };
    return l10n.translate(keys[k] ?? 'txKindSale');
  }
}
