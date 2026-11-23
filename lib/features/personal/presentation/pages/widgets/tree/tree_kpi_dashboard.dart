import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../../../../core/localization/app_localizations.dart';
import '../../../../../../core/theme/app_colors.dart';
import '../../../../../../core/utils/currency_formatter.dart';
import '../../../../../../features/personal/data/models/financial_tree_models.dart';
import 'app_tree_theme.dart';

class _KpiData {
  final String label;
  final double value;
  final Color color;
  final IconData icon;
  const _KpiData(this.label, this.value, this.color, this.icon);
}

/// Premium horizontal KPI strip for the tree canvas.
class TreeKpiDashboard extends StatelessWidget {
  final TreeComputation computation;
  final String currency;
  const TreeKpiDashboard({super.key, required this.computation, required this.currency});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cards = <_KpiData>[
      _KpiData(l10n.translate('netWorth'), computation.netWorth, AppColors.primary, Icons.account_balance_wallet),
      _KpiData(l10n.translate('freeCash'), computation.available, AppColors.success, Icons.payments),
      _KpiData(l10n.translate('totalIncome'), computation.totalIncome, AppColors.success, Icons.trending_up),
      _KpiData(l10n.translate('totalExpenses'), computation.totalExpenses, AppColors.danger, Icons.trending_down),
      _KpiData(l10n.translate('totalPayable'), computation.totalPayable, AppColors.warning, Icons.money_off),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(30), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 60,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: TreeTheme.space12),
              itemCount: cards.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (ctx, i) => _kpiCard(cards[i]),
            ),
          ),
          if (computation.warnings.isNotEmpty) ...[
            const SizedBox(height: 4),
            ..._warnings(computation.warnings, l10n),
          ],
        ],
      ),
    );
  }

  Widget _kpiCard(_KpiData card) {
    final negative = card.value < 0;
    return Container(
      width: 120,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: card.color.withAlpha(15),
        borderRadius: BorderRadius.circular(TreeTheme.radiusMd),
        border: Border.all(color: card.color.withAlpha(60), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(card.icon, size: 12, color: card.color),
              const SizedBox(width: 4),
              Expanded(
                child: Text(card.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: 'Cairo', fontSize: 9, fontWeight: FontWeight.w600, color: card.color.withAlpha(200))),
              ),
            ],
          ),
          const Spacer(),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '${_fmtShort(card.value)} $currency',
              maxLines: 1,
              style: TextStyle(
                fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w800,
                color: negative ? AppColors.danger : AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _warnings(List<String> warnings, AppLocalizations l10n) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, size: 14, color: AppColors.warning),
            const SizedBox(width: 4),
            Text(l10n.translate('treeWarningsCount', params: {'count': warnings.length}), style: const TextStyle(fontFamily: 'Cairo', fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.warning)),
          ],
        ),
      ),
    ];
  }

  String _fmtShort(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}K';
    return fmtNum(v);
  }
}
