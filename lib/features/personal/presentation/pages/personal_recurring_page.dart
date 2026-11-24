import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/date_formatter.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

String _recurringFreqKey(String frequency) {
  switch (frequency) {
    case 'daily':
      return 'frequencyDaily';
    case 'weekly':
      return 'frequencyWeekly';
    case 'yearly':
      return 'frequencyYearly';
    case 'monthly':
    default:
      return 'frequencyMonthly';
  }
}

class PersonalRecurringPage extends ConsumerStatefulWidget {
  const PersonalRecurringPage({super.key});
  @override
  ConsumerState<PersonalRecurringPage> createState() => _PersonalRecurringPageState();
}

class _PersonalRecurringPageState extends ConsumerState<PersonalRecurringPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(recurringProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(recurringProvider);

    ref.listen<RecurringState>(recurringProvider, (prev, next) {
      if (next.sweepFailures.isEmpty) return;
      final message = AppLocalizations.t('recurringInsufficientBalance');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message, style: const TextStyle(fontFamily: 'Cairo')),
            backgroundColor: const Color(0xFFE53935),
          ),
        );
        ref.read(recurringProvider.notifier).consumeSweepWarnings();
      });
    });

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.translate('personalRecurringTransactions'), style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.surface,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          labelColor: const Color(0xFFD32F2F),
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: const Color(0xFFD32F2F),
          labelStyle: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, fontSize: 13),
          tabs: [
            Tab(text: l10n.translate('all')),
            Tab(text: l10n.translate('recurringActiveLabel')),
            Tab(text: l10n.translate('recurringPausedLabel')),
          ],
        ),
      ),
      body: state.isLoading
          ? const Center(child: DotsLoader())
          : state.recurring.isEmpty
              ? _buildEmptyState()
              : _buildContent(state),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push(RouteNames.personalRecurringAdd),
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded, size: 22),
        label: Text(l10n.translate('recurringAddOperation'), style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildEmptyState() {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                color: const Color(0xFFD32F2F).withAlpha(15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.replay_rounded, size: 40, color: Color(0xFFD32F2F)),
            ),
            const SizedBox(height: 20),
            Text(l10n.translate('personalRecurringTransactions'), style: TextStyle(fontFamily: 'Cairo', fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
            const SizedBox(height: 8),
            Text(
              l10n.translate('recurringEmptyDesc'),
              style: TextStyle(fontFamily: 'Cairo', fontSize: 14, color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => context.push(RouteNames.personalRecurringAdd),
              icon: const Icon(Icons.add_rounded, size: 20),
              label: Text(l10n.translate('recurringFormTitle'), style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD32F2F),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(RecurringState state) {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        _buildSummaryCard(state),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => context.push(RouteNames.personalRecurringAdd),
              icon: const Icon(Icons.add_rounded, size: 20),
              label: Text(l10n.translate('recurringCreateNew'), style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD32F2F),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildList(state.recurring),
              _buildList(state.activeTransactions),
              _buildList(state.pausedTransactions),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryCard(RecurringState state) {
    final l10n = AppLocalizations.of(context);
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [const Color(0xFF212121), const Color(0xFF424242)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          _SummaryItem(label: l10n.translate('recurringActiveLabel'), value: '${state.activeCount}', color: const Color(0xFF66BB6A)),
          _SummaryDivider(),
          _SummaryItem(label: l10n.translate('recurringPausedLabel'), value: '${state.pausedCount}', color: const Color(0xFFFFA726)),
          _SummaryDivider(),
          _SummaryItem(label: l10n.translate('all'), value: '${state.totalCount}', color: Colors.white),
        ],
      ),
    );
  }

  Widget _buildList(List<RecurringTransaction> items) {
    if (items.isEmpty) {
      return Center(
        child: Text(AppLocalizations.of(context).translate('noTransactions'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
      );
    }
    return FyonaRefresh(
      onRefresh: () => ref.read(recurringProvider.notifier).load(),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
        itemCount: items.length,
        itemBuilder: (ctx, i) => _RecurringCard(
          transaction: items[i],
          onTap: () => context.push(RouteNames.personalRecurringDetail, extra: items[i]),
        ),
      ),
    );
  }

  void _showActions(RecurringTransaction rt) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ActionSheet(
        transaction: rt,
        onExecute: () async {
          Navigator.pop(ctx);
          final outcome = await ref.read(recurringProvider.notifier).executeNow(rt);
          if (!mounted) return;
          final l10n = AppLocalizations.of(context);
          ScaffoldMessenger.of(context).showSnackBar(
            outcome.success
                ? SnackBar(
                    content: Text(l10n.translate('recurringExecutedOk'), style: const TextStyle(fontFamily: 'Cairo')),
                    backgroundColor: const Color(0xFF66BB6A))
                : SnackBar(
                    content: Text(outcome.message ?? l10n.translate('personalErrExecRecurring'), style: const TextStyle(fontFamily: 'Cairo')),
                    backgroundColor: const Color(0xFFE53935)),
          );
        },
        onSkip: () {
          Navigator.pop(ctx);
          ref.read(recurringProvider.notifier).skipOccurrence(rt);
        },
        onPostpone: () {
          Navigator.pop(ctx);
          _showPostponeDialog(rt);
        },
        onEdit: () {
          Navigator.pop(ctx);
          context.push(RouteNames.personalRecurringAdd, extra: {'recurring': rt});
        },
        onToggleActive: () {
          Navigator.pop(ctx);
          ref.read(recurringProvider.notifier).toggleActive(rt.id, !rt.isActive);
        },
        onDelete: () {
          Navigator.pop(ctx);
          _confirmDelete(rt);
        },
      ),
    );
  }

  void _showPostponeDialog(RecurringTransaction rt) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(24),
        decoration:  BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 20),
            Text(AppLocalizations.of(context).translate('recurringPostponeTitle'), style: TextStyle(fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            _PostponeOption(label: AppLocalizations.of(context).translate('recurringTomorrow'), onTap: () {
              Navigator.pop(ctx);
              ref.read(recurringProvider.notifier).postpone(rt, DateTime.now().add(const Duration(days: 1)));
            }),
            _PostponeOption(label: AppLocalizations.of(context).translate('recurringAfter3Days'), onTap: () {
              Navigator.pop(ctx);
              ref.read(recurringProvider.notifier).postpone(rt, DateTime.now().add(const Duration(days: 3)));
            }),
            _PostponeOption(label: AppLocalizations.of(context).translate('recurringAfterWeek'), onTap: () {
              Navigator.pop(ctx);
              ref.read(recurringProvider.notifier).postpone(rt, DateTime.now().add(const Duration(days: 7)));
            }),
            _PostponeOption(label: AppLocalizations.of(context).translate('recurringCustomDate'), onTap: () async {
              Navigator.pop(ctx);
              final picked = await showDatePicker(
                context: context,
                initialDate: DateTime.now(),
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (picked != null) {
                ref.read(recurringProvider.notifier).postpone(rt, picked);
              }
            }),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(RecurringTransaction rt) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context).translate('deleteRecurringTitle'), style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
        content: Text(AppLocalizations.of(context).translate('recurringDeleteHint'), style: TextStyle(fontFamily: 'Cairo')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(AppLocalizations.of(context).translate('cancel'), style: TextStyle(fontFamily: 'Cairo'))),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(recurringProvider.notifier).delete(rt.id);
            },
            child: Text(AppLocalizations.of(context).translate('delete'), style: TextStyle(fontFamily: 'Cairo', color: Color(0xFFD32F2F))),
          ),
        ],
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _SummaryItem({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(value, style: TextStyle(fontFamily: 'Cairo', fontSize: 18, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: color.withAlpha(180))),
        ],
      ),
    );
  }
}

class _SummaryDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 30, color: Colors.white.withAlpha(30));
  }
}

class _RecurringCard extends StatelessWidget {
  final RecurringTransaction transaction;
  final VoidCallback onTap;
  const _RecurringCard({required this.transaction, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final rt = transaction;
    final isIncome = rt.type == 'income';
    final typeColor = isIncome ? const Color(0xFF66BB6A) : const Color(0xFFD32F2F);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: rt.isActive ? AppColors.border : AppColors.border.withAlpha(100),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: typeColor.withAlpha(15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                isIncome ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
                color: typeColor, size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          rt.name.isNotEmpty ? rt.name : rt.category,
                          style: TextStyle(
                            fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.bold,
                            color: rt.isActive ? AppColors.textPrimary : AppColors.textSecondary,
                          ),
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (!rt.isActive)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFA726).withAlpha(15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(AppLocalizations.of(context).translate('recurringPausedOne'), style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: Color(0xFFFFA726))),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _InfoChip(label: AppLocalizations.of(context).translate(_recurringFreqKey(rt.frequency))),
                      const SizedBox(width: 6),
                      _InfoChip(label: rt.category),
                      if (rt.executionType == 'reminder') ...[
                        const SizedBox(width: 6),
                        _InfoChip(label: AppLocalizations.of(context).translate('recurringReminderChip')),
                      ],
                    ],
                  ),
                  if (rt.nextDate != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      AppLocalizations.of(context).translate('recurringNextDate', params: {'date': DateFormat('dd/MM/yyyy').format(rt.nextDate!)}),
                      style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary),
                    ),
                  ],
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${isIncome ? '+' : '-'}${fmtNum(rt.amount)}',
                  style: TextStyle(
                    fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.bold,
                    color: typeColor,
                  ),
                ),
                Text(rt.currency, style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  const _InfoChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: AppColors.textSecondary)),
    );
  }
}

class _ActionSheet extends StatelessWidget {
  final RecurringTransaction transaction;
  final VoidCallback onExecute;
  final VoidCallback onSkip;
  final VoidCallback onPostpone;
  final VoidCallback onEdit;
  final VoidCallback onToggleActive;
  final VoidCallback onDelete;

  const _ActionSheet({
    required this.transaction,
    required this.onExecute,
    required this.onSkip,
    required this.onPostpone,
    required this.onEdit,
    required this.onToggleActive,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final rt = transaction;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration:  BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 16),
          Text(rt.name.isNotEmpty ? rt.name : rt.category,
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          if (rt.isActive) ...[
            _ActionTile(icon: Icons.play_arrow_rounded, label: AppLocalizations.of(context).translate('recurringExecuteNow'), color: const Color(0xFF66BB6A), onTap: onExecute),
            _ActionTile(icon: Icons.schedule_rounded, label: AppLocalizations.of(context).translate('snooze'), color: const Color(0xFF1565C0), onTap: onPostpone),
            _ActionTile(icon: Icons.skip_next_rounded, label: AppLocalizations.of(context).translate('recurringSkipOnce'), color: const Color(0xFFFFA726), onTap: onSkip),
          ],
          _ActionTile(icon: Icons.edit_outlined, label: AppLocalizations.of(context).translate('edit'), color: AppColors.textSecondary, onTap: onEdit),
          _ActionTile(
            icon: rt.isActive ? Icons.pause_rounded : Icons.play_arrow_rounded,
            label: rt.isActive ? AppLocalizations.of(context).translate('recurringPause') : AppLocalizations.of(context).translate('enable'),
            color: rt.isActive ? const Color(0xFFFFA726) : const Color(0xFF66BB6A),
            onTap: onToggleActive,
          ),
          _ActionTile(icon: Icons.delete_outline_rounded, label: AppLocalizations.of(context).translate('delete'), color: const Color(0xFFD32F2F), onTap: onDelete),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionTile({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: color, size: 22),
      title: Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 14, color: color, fontWeight: FontWeight.w600)),
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );
  }
}

class _PostponeOption extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _PostponeOption({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label, style: const TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600)),
      trailing:  Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.textSecondary),
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );
  }
}
