import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../shared/widgets/business_widgets.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import '../providers/notifications_providers.dart';
import '../../di/notifications_providers.dart';
import '../../data/models/notification_models.dart';
import '../../../../core/localization/app_localizations.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class ReminderListPage extends ConsumerStatefulWidget {
  ReminderListPage({super.key});
  @override
  ConsumerState<ReminderListPage> createState() => _ReminderListPageState();
}

class _ReminderListPageState extends ConsumerState<ReminderListPage> {
  @override
  Widget build(BuildContext context) {
    final remindersAsync = ref.watch(remindersProvider);

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: Text(AppLocalizations.of(context).translate('notificationsReminders')),
        ),
        floatingActionButton: FloatingActionButton(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          onPressed: () => _showReminderDialog(),
          child: Icon(Icons.add),
        ),
        body: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(remindersProvider);
          },
          child: remindersAsync.when(
            loading: () => LoadingShimmer(),
            error: (e, _) => EmptyStateWidget(
              title: AppLocalizations.of(context).translate('errorOccurred'),
              subtitle: e.toString(),
              icon: Icons.error_outline,
            ),
            data: (reminders) {
              if (reminders.isEmpty) {
                return EmptyStateWidget(
                  title: AppLocalizations.of(context).translate('notificationsNoReminders'),
                  subtitle: AppLocalizations.of(context).translate('notificationsPressTheButtonTo'),
                  icon: Icons.alarm,
                );
              }
              return ListView.builder(
                padding: EdgeInsets.all(16),
                itemCount: reminders.length,
                itemBuilder: (context, index) => _buildReminderItem(reminders[index]),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildReminderItem(Reminder reminder) {
    final overdue = reminder.isActive && reminder.remindAt.isBefore(DateTime.now());
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.mdBorder,
        border: Border.all(
          color: reminder.isActive
              ? (overdue ? AppColors.warning : AppColors.primary.withAlpha(40))
              : AppColors.border,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: (reminder.isActive ? AppColors.primary : AppColors.border).withAlpha(25),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              reminder.isActive ? Icons.alarm : Icons.alarm_off,
              color: reminder.isActive ? AppColors.primary : AppColors.textDisabled,
              size: 22,
            ),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reminder.title,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    fontWeight: FontWeight.w600,
                    color: reminder.isActive ? AppColors.textPrimary : AppColors.textDisabled,
                  ),
                ),
                if (reminder.message != null && reminder.message!.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Text(
                      reminder.message!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11),
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  children: [
                    _tag(Icons.schedule, _formatDate(reminder.remindAt)),
                    if (reminder.repeat != 'none')
                      _tag(Icons.repeat, _repeatLabel(reminder.repeat)),
                    if (overdue)
                      _tag(Icons.priority_high, AppLocalizations.of(context).translate('notificationsDueNow'), color: AppColors.danger),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.edit_outlined, size: 18),
            color: AppColors.textSecondary,
            onPressed: () => _showReminderDialog(reminder: reminder),
          ),
          IconButton(
            icon: Icon(Icons.delete_outline, size: 18),
            color: AppColors.danger,
            onPressed: () => _deleteReminder(reminder),
          ),
        ],
      ),
    );
  }

  Widget _tag(IconData icon, String text, {Color color = AppColors.primary}) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: color),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    String dayLabel;
    if (day == today) {
      dayLabel = AppLocalizations.of(context).translate('today');
    } else if (day == today.subtract(Duration(days: 1))) {
      dayLabel = AppLocalizations.of(context).translate('yesterday');
    } else {
      dayLabel = '${local.day}/${local.month}/${local.year}';
    }
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$dayLabel $hh:$mm';
  }

  String _repeatLabel(String repeat) {
    switch (repeat) {
      case 'daily':
        return AppLocalizations.of(context).translate('frequencyDaily');
      case 'weekly':
        return AppLocalizations.of(context).translate('frequencyWeekly');
      case 'monthly':
        return AppLocalizations.of(context).translate('frequencyMonthly');
      default:
        return AppLocalizations.of(context).translate('notificationsOnce');
    }
  }

  Future<void> _deleteReminder(Reminder reminder) async {
    final ok = await showConfirmDialog(
      context,
      title: AppLocalizations.of(context).translate('notificationsDeleteTheReminder'),
      message: AppLocalizations.of(context).translate('notificationsAreYouSureYou'),
    );
    if (ok == true) {
      try {
        await ref.read(notificationServiceProvider).deleteReminder(reminder.id);
        ref.invalidate(remindersProvider);
        if (mounted) showSnackbar(context, message: AppLocalizations.of(context).translate('notificationsTheReminderHasBeen'));
      } catch (e) {
        if (mounted) showSnackbar(context, message: '$e', color: AppColors.danger);
      }
    }
  }

  Future<void> _showReminderDialog({Reminder? reminder}) async {
    final titleCtrl = TextEditingController(text: reminder?.title ?? '');
    final messageCtrl = TextEditingController(text: reminder?.message ?? '');
    DateTime? remindAt = reminder?.remindAt.toLocal() ?? DateTime.now().add(Duration(hours: 1));
    String repeat = reminder?.repeat ?? 'none';

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(borderRadius: AppRadius.lgBorder),
          title: Text(
            reminder == null ? AppLocalizations.of(context).translate('notificationsNewReminder') : AppLocalizations.of(context).translate('notificationsEditReminder'),
            style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w700),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FyonaTextField(
                  controller: titleCtrl,
                  textAlign: TextAlign.right,
                  decoration: InputDecoration(
                    labelText: AppLocalizations.of(context).translate('notificationsReminderAddress'),
                    hintText: AppLocalizations.of(context).translate('notificationsExampleCarPayment'),
                  ),
                ),
                SizedBox(height: 12),
                FyonaTextField(
                  controller: messageCtrl,
                  textAlign: TextAlign.right,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: AppLocalizations.of(context).translate('notificationsNoteOptional'),
                  ),
                ),
                SizedBox(height: 12),
                InkWell(
                  onTap: () async {
                    final pickedDate = await showDatePicker(
                      context: dialogContext,
                      initialDate: remindAt,
                      firstDate: DateTime.now().subtract(Duration(days: 1)),
                      lastDate: DateTime.now().add(Duration(days: 365 * 3)),
                    );
                    if (pickedDate == null) return;
                    final pickedTime = await showTimePicker(
                      context: dialogContext,
                      initialTime: TimeOfDay.fromDateTime(remindAt!),
                    );
                    if (pickedTime == null) return;
                    setDialogState(() {
                      remindAt = DateTime(
                        pickedDate.year, pickedDate.month, pickedDate.day,
                        pickedTime.hour, pickedTime.minute,
                      );
                    });
                  },
                  child: Container(
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withAlpha(10),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.primary.withAlpha(40)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.event, color: AppColors.primary, size: 20),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _formatDate(remindAt!),
                            style: TextStyle(fontFamily: 'Cairo', fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: repeat,
                  decoration: InputDecoration(labelText: AppLocalizations.of(context).translate('frequency')),
                  items: [
                    DropdownMenuItem(value: 'none', child: Text(AppLocalizations.of(context).translate('notificationsOnce'))),
                    DropdownMenuItem(value: 'daily', child: Text(AppLocalizations.of(context).translate('frequencyDaily'))),
                    DropdownMenuItem(value: 'weekly', child: Text(AppLocalizations.of(context).translate('frequencyWeekly'))),
                    DropdownMenuItem(value: 'monthly', child: Text(AppLocalizations.of(context).translate('frequencyMonthly'))),
                  ],
                  onChanged: (v) => setDialogState(() => repeat = v ?? 'none'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(AppLocalizations.of(context).translate('cancel'), style: TextStyle(fontFamily: 'Cairo')),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                if (titleCtrl.text.trim().length < 2) return;
                Navigator.pop(dialogContext);
                try {
                  final service = ref.read(notificationServiceProvider);
                  if (reminder == null) {
                    await service.createReminder(
                      title: titleCtrl.text.trim(),
                      message: messageCtrl.text.trim().isEmpty ? null : messageCtrl.text.trim(),
                      remindAt: remindAt!,
                      repeat: repeat,
                    );
                  } else {
                    await service.updateReminder(
                      reminder.copyWith(
                        title: titleCtrl.text.trim(),
                        message: messageCtrl.text.trim().isEmpty ? null : messageCtrl.text.trim(),
                        remindAt: remindAt,
                        repeat: repeat,
                      ),
                    );
                  }
                  ref.invalidate(remindersProvider);
                  if (mounted) {
                    showSnackbar(context, message: reminder == null ? AppLocalizations.of(context).translate('notificationsTheReminderHasBeen2') : AppLocalizations.of(context).translate('notificationsTheReminderHasBeen3'));
                  }
                } catch (e) {
                  if (mounted) showSnackbar(context, message: '$e', color: AppColors.danger);
                }
              },
              child: Text(reminder == null ? AppLocalizations.of(context).translate('actionCreate') : AppLocalizations.of(context).translate('save'), style: TextStyle(fontFamily: 'Cairo')),
            ),
          ],
        ),
      ),
    );
  }
}
