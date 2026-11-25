import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/date_formatter.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import '../providers/receipt_design_provider.dart';
import '../../../../shared/widgets/receipt/receipt_modal.dart';
import '../../../../shared/widgets/receipt/receipt_data.dart';
import '../widgets/personal_account_choice.dart';

class PersonalRecurringDetailPage extends ConsumerStatefulWidget {
  final RecurringTransaction? transaction;
  final String? transactionId;
  const PersonalRecurringDetailPage({super.key, this.transaction, this.transactionId});
  @override
  ConsumerState<PersonalRecurringDetailPage> createState() => _PersonalRecurringDetailPageState();
}

class _PersonalRecurringDetailPageState extends ConsumerState<PersonalRecurringDetailPage> {
  late RecurringTransaction _rt;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _rt = widget.transaction ?? RecurringTransaction(id: '', name: '', type: 'expense', amount: 0, category: '', frequency: 'monthly', intervalValue: 1, currency: 'USD', accountType: 'fixed', executionType: 'reminder');
    if (widget.transaction == null && widget.transactionId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadById());
    } else {
      _loaded = true;
    }
    // The recurring flow must not depend on another section having loaded
    // banks first (deep links / notification taps land here directly):
    // fill the shared bank list from the local mirror (offline-safe).
    // The account card + execute sheet rebuild via watch() below.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        ref.read(personalFinanceProvider.notifier).load();
      } catch (_) {}
    });
  }

  Future<void> _loadById() async {
    final id = widget.transactionId;
    if (id == null || id.isEmpty) return;
    final state = ref.read(recurringProvider);
    final found = state.recurring.where((r) => r.id == id).firstOrNull;
    if (found != null && mounted) {
      setState(() {
        _rt = found;
        _loaded = true;
      });
    } else if (mounted) {
      await ref.read(recurringProvider.notifier).load();
      final updated = ref.read(recurringProvider).recurring.where((r) => r.id == id).firstOrNull;
      if (updated != null && mounted) {
        setState(() {
          _rt = updated;
          _loaded = true;
        });
      } else if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(recurringProvider);
    final current = state.recurring.where((r) => r.id == _rt.id).firstOrNull;
    if (current != null) _rt = current;

    if (!_loaded) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: Text(l10n.translate('transactionDetails'), style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
          backgroundColor: AppColors.surface,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final isIncome = _rt.type == 'income';
    final typeColor = isIncome ? const Color(0xFF66BB6A) : const Color(0xFFD32F2F);
    final nextDate = _rt.nextDate;
    final now = DateTime.now();
    final daysLeft = nextDate != null ? nextDate.difference(now).inDays : 0;
    final isOverdue = nextDate != null && nextDate.isBefore(now);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.translate('transactionDetails'), style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.surface,
        elevation: 0,
        actions: [
          IconButton(
            onPressed: () => context.push(RouteNames.personalRecurringAdd, extra: {'recurring': _rt}),
            icon:  Icon(Icons.edit_outlined, color: AppColors.textPrimary),
          ),
          IconButton(
            onPressed: _confirmDelete,
            icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFD32F2F)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(typeColor, isIncome),
            const SizedBox(height: 16),
            _buildCountdownBanner(nextDate, daysLeft, isOverdue, typeColor),
            const SizedBox(height: 16),
            _buildDetailsCard(),
            const SizedBox(height: 16),
            _buildScheduleCard(),
            const SizedBox(height: 16),
            _buildAccountCard(),
            const SizedBox(height: 16),
            _buildExecutionCard(),
            const SizedBox(height: 16),
            _buildActionsCard(typeColor, isIncome),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(Color typeColor, bool isIncome) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [typeColor.withAlpha(25), typeColor.withAlpha(10)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: typeColor.withAlpha(30)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 56, height: 56,
                decoration: BoxDecoration(
                  color: typeColor.withAlpha(20),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  isIncome ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
                  color: typeColor, size: 30,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _rt.name.isNotEmpty ? _rt.name : _rt.category,
                      style:  TextStyle(fontFamily: 'Cairo', fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _StatusBadge(isActive: _rt.isActive),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: typeColor.withAlpha(15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(isIncome ? AppLocalizations.of(context).translate('income') : AppLocalizations.of(context).translate('expense'),
                              style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: typeColor, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${isIncome ? '+' : '-'}${fmtNum(_rt.amount)}',
                style: TextStyle(fontFamily: 'Cairo', fontSize: 32, fontWeight: FontWeight.bold, color: typeColor),
              ),
              const SizedBox(width: 8),
              Text(_rt.currency, style: TextStyle(fontFamily: 'Cairo', fontSize: 16, color: typeColor.withAlpha(180))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCountdownBanner(DateTime? nextDate, int daysLeft, bool isOverdue, Color typeColor) {
    if (nextDate == null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.event_busy_rounded, color: AppColors.textSecondary, size: 20),
            const SizedBox(width: 8),
            Text(AppLocalizations.of(context).translate('recurringNoUpcoming'), style: TextStyle(fontFamily: 'Cairo', fontSize: 14, color: AppColors.textSecondary)),
          ],
        ),
      );
    }

    final Color bannerColor = isOverdue ? const Color(0xFFD32F2F) : typeColor;
    final String statusText = isOverdue
        ? AppLocalizations.of(context).translate('recurringOverdue')
        : daysLeft == 0
            ? AppLocalizations.of(context).translate('today')
            : daysLeft == 1
                ? AppLocalizations.of(context).translate('recurringTomorrow')
                : AppLocalizations.of(context).translate('recurringAfterDays', params: {'count': daysLeft});

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bannerColor.withAlpha(15),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: bannerColor.withAlpha(40)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isOverdue ? Icons.warning_amber_rounded : Icons.schedule_rounded,
                color: bannerColor, size: 22,
              ),
              const SizedBox(width: 8),
              Text(
                statusText,
                style: TextStyle(fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.bold, color: bannerColor),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            AppLocalizations.of(context).translate('recurringNextDate', params: {'date': localizedWeekdayDate(context, nextDate)}),
            style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: AppColors.textSecondary),
            textAlign: TextAlign.center,
          ),
          if (!isOverdue) ...[
            const SizedBox(height: 8),
            _CountdownBar(daysLeft: daysLeft, nextDate: nextDate),
          ],
        ],
      ),
    );
  }

  Widget _buildDetailsCard() {
    return _SectionCard(
      title: AppLocalizations.of(context).translate('recurringBasicData'),
      icon: Icons.info_outline_rounded,
      child: Column(
        children: [
          _DetailRow(label: AppLocalizations.of(context).translate('nameLabel'), value: _rt.name.isNotEmpty ? _rt.name : '--'),
          _DetailRow(label: AppLocalizations.of(context).translate('categoryLabel'), value: _rt.category),
          _DetailRow(label: AppLocalizations.of(context).translate('treeTypeLabel'), value: _rt.type == 'income' ? AppLocalizations.of(context).translate('income') : AppLocalizations.of(context).translate('expense'),
              valueColor: _rt.type == 'income' ? const Color(0xFF66BB6A) : const Color(0xFFD32F2F)),
          _DetailRow(label: AppLocalizations.of(context).translate('currencyLabel'), value: _rt.currency),
          if (_rt.description != null && _rt.description!.isNotEmpty)
            _DetailRow(label: AppLocalizations.of(context).translate('notesLabel'), value: _rt.description!),
        ],
      ),
    );
  }

  Widget _buildScheduleCard() {
    final intervalText = _rt.frequency == 'daily'
        ? AppLocalizations.of(context).translate('recurringDaily')
        : _rt.frequency == 'weekly'
            ? AppLocalizations.of(context).translate('recurringEveryXWeeks', params: {'count': _rt.intervalValue}).replaceAll('{count}', '${_rt.intervalValue}')
            : _rt.frequency == 'monthly'
                ? AppLocalizations.of(context).translate('recurringEveryXMonths', params: {'count': _rt.intervalValue})
                : AppLocalizations.of(context).translate('recurringEveryXYears', params: {'count': _rt.intervalValue});

    return _SectionCard(
      title: AppLocalizations.of(context).translate('recurringSchedule'),
      icon: Icons.calendar_today_rounded,
      child: Column(
        children: [
          _DetailRow(label: AppLocalizations.of(context).translate('frequency'), value: intervalText, icon: Icons.repeat_rounded),
          _DetailRow(label: AppLocalizations.of(context).translate('recurringStartLabel'), value: _rt.nextDate != null ? DateFormat('dd/MM/yyyy').format(_rt.nextDate!) : '--',
              icon: Icons.play_circle_outline_rounded),
          if (_rt.lastExecutedAt != null)
            _DetailRow(label: AppLocalizations.of(context).translate('recurringLastExecuted'), value: DateFormat('dd/MM/yyyy HH:mm').format(_rt.lastExecutedAt!),
                icon: Icons.check_circle_outline_rounded, valueColor: const Color(0xFF66BB6A)),
          if (_rt.approximateStartDay != null)
            _DetailRow(label: AppLocalizations.of(context).translate('recurringApproxStartDay'), value: '${_rt.approximateStartDay}'),
          if (_rt.approximateEndDay != null)
            _DetailRow(label: AppLocalizations.of(context).translate('recurringApproxEndDay'), value: '${_rt.approximateEndDay}'),
        ],
      ),
    );
  }

  Widget _buildAccountCard() {
    final accounts = ref.watch(personalFinanceProvider).bankAccounts;
    final account = _rt.bankAccountId != null
        ? accounts.where((a) => a.id == _rt.bankAccountId).firstOrNull
        : null;

    return _SectionCard(
      title: AppLocalizations.of(context).translate('recurringBankAccountTitle'),
      icon: Icons.account_balance_rounded,
      child: Column(
        children: [
          _DetailRow(
            label: AppLocalizations.of(context).translate('recurringLinkType'),
            value: _rt.accountType == 'fixed' ? AppLocalizations.of(context).translate('recurringFixedLabel') : AppLocalizations.of(context).translate('recurringPickAtExecShort'),
            icon: _rt.accountType == 'fixed' ? Icons.link_rounded : Icons.touch_app_rounded,
          ),
          if (account != null) ...[
            _DetailRow(label: AppLocalizations.of(context).translate('recurringBankLabel'), value: account.bankName, icon: Icons.account_balance),
            _DetailRow(label: AppLocalizations.of(context).translate('currencyLabel'), value: account.currency),
            _DetailRow(label: AppLocalizations.of(context).translate('currentBalance'), value: '${fmtNum(account.balance)} ${account.currency}'),
          ] else if (_rt.accountType == 'pick_at_execution') ...[
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1565C0).withAlpha(10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF1565C0).withAlpha(30)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 16, color: Color(0xFF1565C0)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(AppLocalizations.of(context).translate('recurringPickAtExecEachTime'),
                          style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: const Color(0xFF1565C0))),
                    ),
                  ],
                ),
              ),
            ),
          ] else ...[
            _DetailRow(label: AppLocalizations.of(context).translate('recurringStepAccount'), value: AppLocalizations.of(context).translate('recurringNotSpecified')),
          ],
        ],
      ),
    );
  }

  Widget _buildExecutionCard() {
    return _SectionCard(
      title: AppLocalizations.of(context).translate('recurringExecMethodTitle'),
      icon: Icons.settings_rounded,
      child: Column(
        children: [
          _DetailRow(
            label: AppLocalizations.of(context).translate('recurringMethodLabel'),
            value: _rt.executionType == 'auto' ? AppLocalizations.of(context).translate('recurringAutoLong') : AppLocalizations.of(context).translate('recurringReminderConfirm'),
            icon: _rt.executionType == 'auto' ? Icons.flash_on_rounded : Icons.notifications_active_rounded,
          ),
          if (_rt.reminderTime != null)
            _DetailRow(label: AppLocalizations.of(context).translate('recurringReminderTimeLabel'), value: _rt.reminderTime!, icon: Icons.access_time_rounded),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _rt.executionType == 'auto' ? const Color(0xFF66BB6A).withAlpha(10) : const Color(0xFF1565C0).withAlpha(10),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: (_rt.executionType == 'auto' ? const Color(0xFF66BB6A) : const Color(0xFF1565C0)).withAlpha(30)),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: _rt.executionType == 'auto' ? const Color(0xFF66BB6A) : const Color(0xFF1565C0)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _rt.executionType == 'auto'
                          ? AppLocalizations.of(context).translate('recurringAutoHint')
                          : AppLocalizations.of(context).translate('recurringReminderHint'),
                      style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: _rt.executionType == 'auto' ? const Color(0xFF66BB6A) : const Color(0xFF1565C0)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionsCard(Color typeColor, bool isIncome) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppLocalizations.of(context).translate('recurringActions'), style: TextStyle(fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          const SizedBox(height: 16),
          if (_rt.isActive) ...[
            _ActionButton(
              icon: Icons.play_arrow_rounded, label: AppLocalizations.of(context).translate('recurringExecuteNow'), color: const Color(0xFF66BB6A),
              onTap: () => _executeNow(),
            ),
            const SizedBox(height: 8),
            _ActionButton(
              icon: Icons.skip_next_rounded, label: AppLocalizations.of(context).translate('recurringSkipOnce'), color: const Color(0xFFFFA726),
              onTap: () {
                ref.read(recurringProvider.notifier).skipOccurrence(_rt);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(AppLocalizations.of(context).translate('recurringSkipped'), style: TextStyle(fontFamily: 'Cairo')),
                      backgroundColor: const Color(0xFFFFA726)),
                );
              },
            ),
            const SizedBox(height: 8),
            _ActionButton(
              icon: Icons.schedule_rounded, label: AppLocalizations.of(context).translate('snooze'), color: const Color(0xFF1565C0),
              onTap: _showPostponeDialog,
            ),
            const SizedBox(height: 8),
          ],
          _ActionButton(
            icon: _rt.isActive ? Icons.pause_rounded : Icons.play_arrow_rounded,
            label: _rt.isActive ? AppLocalizations.of(context).translate('recurringPause') : AppLocalizations.of(context).translate('enable'),
            color: _rt.isActive ? const Color(0xFFFFA726) : const Color(0xFF66BB6A),
            onTap: () {
              ref.read(recurringProvider.notifier).toggleActive(_rt.id, !_rt.isActive);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(_rt.isActive ? AppLocalizations.of(context).translate('recurringPausedMsg') : AppLocalizations.of(context).translate('recurringActivatedMsg'),
                      style: TextStyle(fontFamily: 'Cairo')),
                  backgroundColor: _rt.isActive ? const Color(0xFFFFA726) : const Color(0xFF66BB6A),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          _ActionButton(
            icon: Icons.edit_outlined, label: AppLocalizations.of(context).translate('edit'), color: AppColors.textSecondary,
            onTap: () => context.push(RouteNames.personalRecurringAdd, extra: {'recurring': _rt}),
          ),
          const SizedBox(height: 8),
          _ActionButton(
            icon: Icons.delete_outline_rounded, label: AppLocalizations.of(context).translate('recurringDeletePermanently'), color: const Color(0xFFD32F2F),
            onTap: _confirmDelete,
          ),
        ],
      ),
    );
  }

  void _showExecResult(RecurringExecOutcome outcome,
      {String? bankAccountId, String? currency}) {
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
    // A completed execution gets its own full-data receipt (recurring
    // customization): every field of the executed operation, same design.
    if (outcome.success) {
      _showCompletionReceipt(
          bankAccountId: bankAccountId, currency: currency);
    }
  }

  /// Completion receipt of the just-executed recurring operation: name,
  /// type, amount, category, frequency, account (+currency), next date and
  /// notes — nothing missing, design untouched.
  void _showCompletionReceipt({String? bankAccountId, String? currency}) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final isIncome = _rt.type == 'income';
    final cur = (currency ?? _rt.currency).toUpperCase();
    PersonalBankAccount? acc;
    final accId = bankAccountId ?? _rt.bankAccountId;
    if (accId != null && accId.isNotEmpty) {
      try {
        final accounts = ref.read(personalFinanceProvider).bankAccounts;
        acc = accounts.where((a) => a.id == accId).firstOrNull;
      } catch (_) {}
    }
    final accDisplay = acc != null
        ? '${acc.bankName} (${acc.currency})'
        : l10n.translate('payMethodCash');
    final preset = ref
        .read(personalReceiptDesignProvider.notifier)
        .getPreset('recurring');
    ReceiptModal.show(
      context,
      ReceiptData(
        title: _rt.name.isNotEmpty ? _rt.name : _rt.category,
        amount: _rt.amount,
        currencySymbol: currencySymbol(cur),
        dateTime: DateFormat('yyyy/MM/dd HH:mm').format(DateTime.now()),
        referenceNumber: '#RC-${_rt.id}',
        senderName: isIncome ? _rt.category : accDisplay,
        receiverName: isIncome ? accDisplay : _rt.category,
        details: [
          ReceiptDetail(
              label: l10n.translate('recurringTypeTitle'),
              value: isIncome
                  ? l10n.translate('deposit')
                  : l10n.translate('withdrawal')),
          ReceiptDetail(
              label: l10n.translate('recurringStepCategory'),
              value: _rt.category),
          ReceiptDetail(
              label: l10n.translate('recurringFreqTitle'),
              value: _rt.frequencyLabel),
          ReceiptDetail(
              label: l10n.translate('recurringStepAccount'),
              value: accDisplay),
          if (_rt.nextDate != null)
            ReceiptDetail(
                label: l10n.translate('nextDateLabel'),
                value:
                    DateFormat('yyyy/MM/dd').format(_rt.nextDate!)),
          if (_rt.description != null && _rt.description!.isNotEmpty)
            ReceiptDetail(
                label: l10n.translate('description'),
                value: _rt.description!),
          ReceiptDetail(
              label: l10n.translate('statusDetail'),
              value: l10n.translate('recurringExecutedOk')),
        ],
      ),
      preset: preset,
    );
  }

  Future<void> _executeNow() async {
    if (_rt.accountType == 'fixed' && _rt.bankAccountId != null) {
      final outcome = await ref.read(recurringProvider.notifier).executeNow(_rt);
      _showExecResult(outcome);
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _ExecuteNowSheet(
        recurring: _rt,
        onExecute: (bankAccountId, currency) async {
          Navigator.pop(ctx);
          final outcome = await ref.read(recurringProvider.notifier).executeNowWithBank(_rt, bankAccountId, currency);
          _showExecResult(outcome,
              bankAccountId: bankAccountId, currency: currency);
        },
      ),
    );
  }

  void _showPostponeDialog() {
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
              ref.read(recurringProvider.notifier).postpone(_rt, DateTime.now().add(const Duration(days: 1)));
            }),
            _PostponeOption(label: AppLocalizations.of(context).translate('recurringAfter3Days'), onTap: () {
              Navigator.pop(ctx);
              ref.read(recurringProvider.notifier).postpone(_rt, DateTime.now().add(const Duration(days: 3)));
            }),
            _PostponeOption(label: AppLocalizations.of(context).translate('recurringAfterWeek'), onTap: () {
              Navigator.pop(ctx);
              ref.read(recurringProvider.notifier).postpone(_rt, DateTime.now().add(const Duration(days: 7)));
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
                ref.read(recurringProvider.notifier).postpone(_rt, picked);
              }
            }),
          ],
        ),
      ),
    );
  }

  void _confirmDelete() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context).translate('deleteRecurringTitle'), style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
        content: Text(
          AppLocalizations.of(context).translate('recurringDeleteBody', params: {'name': _rt.name.isNotEmpty ? _rt.name : _rt.category}),
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(AppLocalizations.of(context).translate('cancel'), style: TextStyle(fontFamily: 'Cairo'))),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(recurringProvider.notifier).delete(_rt.id);
              context.pop();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(AppLocalizations.of(context).translate('recurringDeleted'), style: TextStyle(fontFamily: 'Cairo')),
                    backgroundColor: const Color(0xFFD32F2F)),
              );
            },
            child: Text(AppLocalizations.of(context).translate('delete'), style: TextStyle(fontFamily: 'Cairo', color: Color(0xFFD32F2F), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}

// ── Helper widgets ──

/// Bank accounts offered for manual recurring execution: every account,
/// cash included. Filtering cash out left cash-only users with an empty
/// bank list (online and offline alike).
List<PersonalBankAccount> recurringExecutionBanks(
    List<PersonalBankAccount> all) {
  return all.toList();
}

class _StatusBadge extends StatelessWidget {
  final bool isActive;
  const _StatusBadge({required this.isActive});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: (isActive ? const Color(0xFF66BB6A) : const Color(0xFFFFA726)).withAlpha(15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(isActive ? AppLocalizations.of(context).translate('activeStatus') : AppLocalizations.of(context).translate('recurringPausedOne'),
          style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: isActive ? const Color(0xFF66BB6A) : const Color(0xFFFFA726),
              fontWeight: FontWeight.w600)),
    );
  }
}

class _CountdownBar extends StatelessWidget {
  final int daysLeft;
  final DateTime nextDate;
  const _CountdownBar({required this.daysLeft, required this.nextDate});

  @override
  Widget build(BuildContext context) {
    final totalDays = 30;
    final progress = (1 - (daysLeft / totalDays)).clamp(0.0, 1.0);
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 6,
            backgroundColor: AppColors.border,
            valueColor: AlwaysStoppedAnimation<Color>(
              daysLeft <= 3 ? const Color(0xFFD32F2F) : daysLeft <= 7 ? const Color(0xFFFFA726) : const Color(0xFF66BB6A),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(AppLocalizations.of(context).translate('today'), style: TextStyle(fontFamily: 'Cairo', fontSize: 9, color: AppColors.textSecondary)),
            Text(AppLocalizations.of(context).translate('recurringDaysLeft', params: {'count': daysLeft}), style: TextStyle(fontFamily: 'Cairo', fontSize: 9, color: AppColors.textSecondary)),
          ],
        ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  const _SectionCard({required this.title, required this.icon, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: const Color(0xFFD32F2F)),
              const SizedBox(width: 8),
              Text(title, style:  TextStyle(fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
            ],
          ),
          const Divider(height: 20),
          child,
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData? icon;
  final Color? valueColor;
  const _DetailRow({required this.label, required this.value, this.icon, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: AppColors.textSecondary),
            const SizedBox(width: 8),
          ],
          Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppColors.textSecondary)),
          const Spacer(),
          Flexible(
            child: Text(value,
                style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600, color: valueColor ?? AppColors.textPrimary),
                textAlign: TextAlign.end, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionButton({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withAlpha(10),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 12),
              Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600, color: color)),
            ],
          ),
        ),
      ),
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

class _ExecuteNowSheet extends ConsumerStatefulWidget {
  final RecurringTransaction recurring;
  final void Function(String bankAccountId, String currency) onExecute;
  const _ExecuteNowSheet({required this.recurring, required this.onExecute});
  @override
  ConsumerState<_ExecuteNowSheet> createState() => _ExecuteNowSheetState();
}

class _ExecuteNowSheetState extends ConsumerState<_ExecuteNowSheet> {
  String? _selectedBankName;
  String? _selectedAccountId;
  String? _selectedCurrency;

  @override
  void initState() {
    super.initState();
    // Self-sufficient like the detail page: never show an empty list just
    // because another section hasn't loaded banks yet (offline-safe).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        ref.read(personalFinanceProvider.notifier).load();
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    // Every account is offered, cash included: executing into/out of cash is
    // legitimate, and cash-only users otherwise get an empty sheet.
    final allAccounts = ref.watch(personalFinanceProvider).bankAccounts;
    final accounts = recurringExecutionBanks(allAccounts);

    final grouped = <String, List<PersonalBankAccount>>{};
    for (final acc in accounts) {
      grouped.putIfAbsent(acc.bankName, () => []).add(acc);
    }
    final bankNames = grouped.keys.toList();

    final bankAccounts = _selectedBankName != null ? (grouped[_selectedBankName!] ?? []) : [];

    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration:  BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          Container(width: 40, height: 4, margin: const EdgeInsets.only(top: 12),
              decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 16),
          Padding(padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(AppLocalizations.of(context).translate('selectBankAccount'), style: TextStyle(fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.bold))),
          const SizedBox(height: 4),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(_selectedBankName == null
                  ? AppLocalizations.of(context).translate('recurringPickAccountForExec')
                  : AppLocalizations.of(context).translate('recurringPickCurrencyFrom', params: {'bank': _selectedBankName!}),
                  style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: AppColors.textSecondary))),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              children: [
                if (_selectedBankName == null) ...[
                  ...bankNames.map((name) {
                    final accs = grouped[name]!;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: GestureDetector(
                        onTap: () => setState(() {
                          _selectedBankName = name;
                          _selectedAccountId = null;
                          _selectedCurrency = null;
                        }),
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.background,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Row(children: [
                            Icon(Icons.account_balance_rounded, color: AppColors.textSecondary, size: 22),
                            const SizedBox(width: 12),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(name, style: const TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600)),
                              Text(AppLocalizations.of(context).translate('recurringAccountsCount', params: {'count': accs.length, 'count2': accs.length}),
                                  style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
                            ])),
                            Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.textSecondary),
                          ]),
                        ),
                      ),
                    );
                  }),
                ] else ...[
                  GestureDetector(
                    onTap: () => setState(() { _selectedBankName = null; _selectedAccountId = null; _selectedCurrency = null; }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(children: [
                        Icon(Icons.arrow_back_rounded, size: 18, color: AppColors.textSecondary),
                        const SizedBox(width: 6),
                        Text(AppLocalizations.of(context).translate('recurringBackToBanks'), style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: AppColors.textSecondary)),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...bankAccounts.map((acc) {
                    final selected = _selectedAccountId == acc.id;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: GestureDetector(
                        onTap: () => setState(() {
                          _selectedAccountId = acc.id;
                          _selectedCurrency = acc.currency;
                        }),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: selected ? const Color(0xFFD32F2F).withAlpha(10) : AppColors.background,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: selected ? const Color(0xFFD32F2F) : AppColors.border, width: selected ? 2 : 1),
                          ),
                          child: Row(children: [
                            Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked,
                                color: selected ? const Color(0xFFD32F2F) : AppColors.textSecondary, size: 22),
                            const SizedBox(width: 12),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [
                                Flexible(child: Text(acc.currency, style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600,
                                    color: selected ? AppColors.textPrimary : AppColors.textSecondary))),
                                PersonalAccountTypeTag(accounts: List<PersonalBankAccount>.from(bankAccounts), account: acc),
                              ]),
                              Text(AppLocalizations.of(context).translate('recurringBalanceIs', params: {'balance': fmtNum(acc.balance)}), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
                            ])),
                          ]),
                        ),
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: (_selectedAccountId != null && _selectedCurrency != null)
                    ? () => widget.onExecute(_selectedAccountId!, _selectedCurrency!)
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF66BB6A),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppColors.border,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(AppLocalizations.of(context).translate('recurringExecuteNow'), style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
