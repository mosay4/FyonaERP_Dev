import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/router/route_names.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

class PersonalBudgetPage extends ConsumerStatefulWidget {
  const PersonalBudgetPage({super.key});
  @override
  ConsumerState<PersonalBudgetPage> createState() => _PersonalBudgetPageState();
}

class _PersonalBudgetPageState extends ConsumerState<PersonalBudgetPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _load() {
    ref.read(budgetProvider.notifier).load();
  }

  void _confirmDelete(PersonalBudget b) {
    HapticFeedback.lightImpact();
    final l10n = AppLocalizations.of(context);
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(l10n.translate('deleteBudgetTitle'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary, fontWeight: FontWeight.w700)),
      content: Text(l10n.translate('budgetDeleteConfirm', params: {'name': b.name}), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.translate('cancel'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary))),
        TextButton(onPressed: () {
          Navigator.pop(ctx);
          ref.read(budgetProvider.notifier).deleteBudget(b.id);
        }, child: Text(l10n.translate('delete'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.danger, fontWeight: FontWeight.w700))),
      ],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(budgetProvider);

    return FyonaRefresh(
      onRefresh: () async => _load(),
      color: AppColors.primary,
      backgroundColor: AppColors.surface,
      child: st.isLoading
          ? Center(child: DotsLoader())
          : st.error != null
              ? _buildErrorState(st)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                  children: [
                    // Header
                    _buildHeader(st),
                    const SizedBox(height: 16),

                    if (st.budgets.isEmpty)
                      _buildEmptyState()
                    else
                      ...st.sortedBudgets.map((b) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _BudgetCard(
                          budget: b,
                          onTap: () => context.push('/personal/budget/detail', extra: b),
                          onEdit: () => context.push(RouteNames.personalBudgetEdit, extra: {'budget': b}),
                          onDelete: () => _confirmDelete(b),
                        ),
                      )),
                  ],
                ),
    );
  }

  Widget _buildHeader(BudgetState st) {
    final l10n = AppLocalizations.of(context);
    final activeCount = st.budgets.where((b) => b.isActive).length;
    final expiredCount = st.budgets.where((b) => b.isExpired).length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.primary, AppColors.primary.withAlpha(180)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(25),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.account_balance_wallet_rounded, color: Colors.white, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.translate('budgetTitle'),
                      style: TextStyle(fontFamily: 'Cairo', fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.translate('budgetCount', params: {'count': st.budgets.length}),
                      style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _HeaderStat(label: l10n.translate('activeStatus'), value: '$activeCount', color: Color(0xFF66BB6A)),
              const SizedBox(width: 16),
              _HeaderStat(label: l10n.translate('budgetExpired'), value: '$expiredCount', color: Color(0xFFEF5350)),
            ],
          ),
          const SizedBox(height: 14),
          // Add budget button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => context.push(RouteNames.personalBudgetAdd),
              icon: Icon(Icons.add_rounded, size: 20),
              label: Text(l10n.translate('budgetCreateNew'), style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(15),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.account_balance_wallet_rounded, size: 48, color: AppColors.primary),
          ),
          const SizedBox(height: 20),
          Text(
            l10n.translate('budgetEmptyTitle'),
            style: TextStyle(fontFamily: 'Cairo', fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.translate('budgetEmptySubtitle'),
            textAlign: TextAlign.center,
            style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => context.push(RouteNames.personalBudgetAdd),
            icon: Icon(Icons.add_rounded, size: 20),
            label: Text(l10n.translate('budgetCreate'), style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(BudgetState st) {
    final l10n = AppLocalizations.of(context);
    final isOffline = st.isOfflineError;
    return SingleChildScrollView(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(isOffline ? Icons.wifi_off_rounded : Icons.error_outline_rounded,
                  size: 48, color: isOffline ? AppColors.warning : AppColors.danger),
              const SizedBox(height: 12),
              Text(isOffline ? l10n.translate('noInternet') : l10n.translate('errorOccurred'),
                  style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                isOffline ? l10n.translate('offlineSectionRequiresInternet') : _shortError(st.error ?? l10n.translate('errorOccurred')),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppColors.textTertiary),
              ),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _load, child: Text(l10n.translate('retry'), style: TextStyle(fontFamily: 'Cairo'))),
            ],
          ),
        ),
      ),
    );
  }

  String _shortError(String raw) {
    final clean = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.length > 180) return clean.substring(0, 180) + '…';
    return clean;
  }
}

// ════════════════════════════════════════════════════════════
//  BUDGET CARD
// ════════════════════════════════════════════════════════════
class _BudgetCard extends StatelessWidget {
  final PersonalBudget budget;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _BudgetCard({
    required this.budget,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  Color get _statusColor {
    if (budget.isOverBudget) return Color(0xFFEF5350);
    if (budget.usagePercent >= 80) return Color(0xFFFFA726);
    if (budget.isExpired) return AppColors.textSecondary;
    return AppColors.primary;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isOver = budget.isOverBudget;
    final isWarning = budget.usagePercent >= 80 && !isOver;
    final isExpired = budget.isExpired;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isOver ? Color(0xFFEF5350).withAlpha(80) : isWarning ? Color(0xFFFFA726).withAlpha(60) : AppColors.border,
            width: isOver || isWarning ? 1.5 : 1,
          ),
          boxShadow: isOver ? [
            BoxShadow(color: Color(0xFFEF5350).withAlpha(20), blurRadius: 8, offset: Offset(0, 2)),
          ] : [],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title row
            Row(
              children: [
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    color: _statusColor.withAlpha(20),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    isExpired ? Icons.schedule_rounded : isOver ? Icons.warning_rounded : Icons.account_balance_wallet_rounded,
                    color: _statusColor, size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        budget.name,
                        style: TextStyle(fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        budget.periodLabel,
                        style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'edit') onEdit();
                    if (v == 'delete') onDelete();
                  },
                  itemBuilder: (ctx) => [
                    PopupMenuItem(value: 'edit', child: Row(
                      children: [
                        Icon(Icons.edit_outlined, size: 18, color: AppColors.primary),
                        const SizedBox(width: 8),
                        Text(l10n.translate('edit'), style: TextStyle(fontFamily: 'Cairo')),
                      ],
                    )),
                    PopupMenuItem(value: 'delete', child: Row(
                      children: [
                        Icon(Icons.delete_outline_rounded, size: 18, color: AppColors.danger),
                        const SizedBox(width: 8),
                        Text(l10n.translate('delete'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.danger)),
                      ],
                    )),
                  ],
                  icon: Icon(Icons.more_vert_rounded, size: 18, color: AppColors.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Amount info
            Row(
              children: [
                _AmountInfo(label: l10n.translate('budgetTotal'), amount: budget.totalAmount, color: AppColors.textPrimary),
                const SizedBox(width: 12),
                _AmountInfo(label: l10n.translate('expense'), amount: budget.totalSpent, color: Color(0xFFEF5350)),
                const SizedBox(width: 12),
                _AmountInfo(
                  label: isOver ? l10n.translate('budgetOverrun') : l10n.translate('remainingLabel'),
                  amount: isOver ? budget.overAmount : budget.remaining,
                  color: isOver ? Color(0xFFEF5350) : Color(0xFF66BB6A),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: budget.progress.clamp(0.0, 1.0),
                backgroundColor: _statusColor.withAlpha(30),
                valueColor: AlwaysStoppedAnimation<Color>(_statusColor),
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 8),

            // Bottom row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Status badges
                Row(
                  children: [
                    if (isOver)
                      _Badge(text: l10n.translate('budgetOverBadge', params: {'amount': fmtNum(budget.overAmount)}), color: Color(0xFFEF5350)),
                    if (isWarning && !isOver)
                      _Badge(text: l10n.translate('budgetNearLimit'), color: Color(0xFFFFA726)),
                    if (isExpired)
                      _Badge(text: l10n.translate('budgetExpiredLabel'), color: AppColors.textSecondary),
                    if (!isOver && !isWarning && !isExpired)
                      _Badge(text: '${budget.usagePercent.toStringAsFixed(0)}%', color: AppColors.primary),
                  ],
                ),
                // Days remaining
                if (budget.endDate != null && !isExpired)
                  Text(
                    l10n.translate('budgetDaysLeft', params: {'count': budget.daysRemaining}),
                    style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary),
                  ),
                // Categories count
                Text(
                  '${budget.categories.length} ${budget.categories.length == 1 ? l10n.translate('budgetCategorySingle') : l10n.translate('budgetCategoryPlural')}',
                  style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _HeaderStat({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(value, style: TextStyle(fontFamily: 'Ciro', fontSize: 16, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: Colors.white70)),
      ],
    );
  }
}

class _AmountInfo extends StatelessWidget {
  final String label;
  final double amount;
  final Color color;
  const _AmountInfo({required this.label, required this.amount, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: AppColors.textSecondary)),
          const SizedBox(height: 2),
          Text(
            fmtNum(amount),
            style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.bold, color: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(fontFamily: 'Cairo', fontSize: 10, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }
}
