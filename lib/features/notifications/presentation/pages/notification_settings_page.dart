import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import '../../../../shared/widgets/data_components.dart';
import '../../data/models/notification_models.dart';
import '../providers/notifications_providers.dart';
import '../../di/notifications_providers.dart';
import '../../../../core/localization/app_localizations.dart';

class NotificationSettingsPage extends ConsumerStatefulWidget {
  const NotificationSettingsPage({super.key});
  @override
  ConsumerState<NotificationSettingsPage> createState() => _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends ConsumerState<NotificationSettingsPage> {
  NotificationPreferences _prefs = const NotificationPreferences();
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await ref.read(notificationServiceProvider).getPreferences();
      if (mounted) {
        setState(() {
          _prefs = prefs;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: Text(AppLocalizations.of(context).translate('notificationsNotificationSettings')),
          actions: [
            TextButton(
              onPressed: _saving || _loading ? null : _save,
              child: Text(_saving ? '...' : AppLocalizations.of(context).translate('save'),
                style: TextStyle(fontFamily: 'Cairo', color: AppColors.primary, fontSize: R.fontSize(context, 15))),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  FormCard(title: AppLocalizations.of(context).translate('notificationsGeneralAlerts'), children: [
                    _buildSwitch(
                      icon: Icons.email,
                      title: AppLocalizations.of(context).translate('notificationsEmailAlerts'),
                      subtitle: AppLocalizations.of(context).translate('notificationsReceiveNotificationsViaEmail'),
                      value: _prefs.emailAlerts,
                      onChanged: (v) => setState(() => _prefs = _prefs.copyWith(emailAlerts: v)),
                    ),
                    Divider(height: 1, color: AppColors.border),
                    _buildSwitch(
                      icon: Icons.receipt_long,
                      title: AppLocalizations.of(context).translate('notificationsBillingAlerts'),
                      subtitle: AppLocalizations.of(context).translate('notificationsNotificationsWhenInvoicesAre'),
                      value: _prefs.invoiceAlerts,
                      onChanged: (v) => setState(() => _prefs = _prefs.copyWith(invoiceAlerts: v)),
                    ),
                    Divider(height: 1, color: AppColors.border),
                    _buildSwitch(
                      icon: Icons.attach_money,
                      title: AppLocalizations.of(context).translate('notificationsPaymentAlerts'),
                      subtitle: AppLocalizations.of(context).translate('notificationsNotificationsWhenPaymentsAre'),
                      value: _prefs.paymentAlerts,
                      onChanged: (v) => setState(() => _prefs = _prefs.copyWith(paymentAlerts: v)),
                    ),
                    Divider(height: 1, color: AppColors.border),
                    _buildSwitch(
                      icon: Icons.settings,
                      title: AppLocalizations.of(context).translate('notificationsSystemUpdates'),
                      subtitle: AppLocalizations.of(context).translate('notificationsNotificationsAboutNewSystem'),
                      value: _prefs.systemUpdates,
                      onChanged: (v) => setState(() => _prefs = _prefs.copyWith(systemUpdates: v)),
                    ),
                  ]),
                  FormCard(title: AppLocalizations.of(context).translate('notificationsSmartAlerts'), children: [
                    _buildSwitch(
                      icon: Icons.savings,
                      title: AppLocalizations.of(context).translate('notificationsBudgetAlerts'),
                      subtitle: AppLocalizations.of(context).translate('notificationsNotificationWhenACategory'),
                      value: _prefs.budgetAlerts,
                      onChanged: (v) => setState(() => _prefs = _prefs.copyWith(budgetAlerts: v)),
                    ),
                    Divider(height: 1, color: AppColors.border),
                    _buildSwitch(
                      icon: Icons.account_balance_wallet,
                      title: AppLocalizations.of(context).translate('notificationsLowBalanceAlert'),
                      subtitle: AppLocalizations.of(context).translate('notificationsNotificationWhenTheAccount'),
                      value: _prefs.lowBalanceAlerts,
                      onChanged: (v) => setState(() => _prefs = _prefs.copyWith(lowBalanceAlerts: v)),
                    ),
                  ]),
                  FormCard(title: AppLocalizations.of(context).translate('notificationsPeriodicFinancialReport'), children: [
                    _buildSwitch(
                      icon: Icons.calendar_view_day,
                      title: AppLocalizations.of(context).translate('notificationsDailyReport'),
                      subtitle: AppLocalizations.of(context).translate('notificationsDailyFinancialSummaryAt'),
                      value: _prefs.dailyReport,
                      onChanged: (v) => setState(() => _prefs = _prefs.copyWith(dailyReport: v)),
                    ),
                    Divider(height: 1, color: AppColors.border),
                    _buildSwitch(
                      icon: Icons.calendar_view_week,
                      title: AppLocalizations.of(context).translate('weeklyReport'),
                      subtitle: AppLocalizations.of(context).translate('notificationsWeeklyFinancialSummaryEvery'),
                      value: _prefs.weeklyReport,
                      onChanged: (v) => setState(() => _prefs = _prefs.copyWith(weeklyReport: v)),
                    ),
                    Divider(height: 1, color: AppColors.border),
                    _buildSwitch(
                      icon: Icons.calendar_month,
                      title: AppLocalizations.of(context).translate('monthlyReport'),
                      subtitle: AppLocalizations.of(context).translate('notificationsMonthlyFinancialSummaryFirst'),
                      value: _prefs.monthlyReport,
                      onChanged: (v) => setState(() => _prefs = _prefs.copyWith(monthlyReport: v)),
                    ),
                  ]),
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SizedBox(
                      width: double.infinity,
                      height: R.buttonHeight(context),
                      child: ElevatedButton(
                        onPressed: _saving ? null : _save,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder),
                        ),
                        child: Text(_saving ? '...' : AppLocalizations.of(context).translate('adminSaveSettings'),
                          style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14))),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildSwitch({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      secondary: Icon(icon, color: AppColors.primary, size: 22),
      title: Text(title,
        style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary)),
      subtitle: Text(subtitle,
        style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.textSecondary)),
      value: value,
      activeTrackColor: AppColors.primary,
      onChanged: onChanged,
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(notificationServiceProvider).updatePreferences(_prefs);
      ref.invalidate(notificationPreferencesProvider);
      if (mounted) {
        showSnackbar(context, message: AppLocalizations.of(context).translate('notificationsSettingsHaveBeenSaved'));
        setState(() => _saving = false);
      }
    } catch (e) {
      if (mounted) {
        showSnackbar(context, message: '$e', color: AppColors.danger);
        setState(() => _saving = false);
      }
    }
  }
}
