import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/router/route_names.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import '../../../../core/localization/app_localizations.dart';

final _settingsSections = [
  (AppLocalizations.t('onboardingCompanyData'), Icons.business, AppColors.info, AppLocalizations.t('settingsNameRegisterTaxLogo'), '/settings/company'),
  (AppLocalizations.t('settingsInvoices'), Icons.receipt_long, AppColors.primary, AppLocalizations.t('settingsColorFooterTemplatesPrefix'), '/personal/receipt-design'),
  (AppLocalizations.t('settingsTaxes'), Icons.attach_money, AppColors.warning, AppLocalizations.t('settingsTypesOfTaxesAnd'), '/settings/taxes'),
  (AppLocalizations.t('adminCurrencies'), Icons.compare_arrows, AppColors.success, AppLocalizations.t('settingsExchangeRatesAndCurrencies'), '/settings/currencies'),
  (AppLocalizations.t('settingsCustomFields'), Icons.description, AppColors.info, AppLocalizations.t('settingsAdditionalFieldsForCustomers'), '/settings/custom-fields'),
  (AppLocalizations.t('designStudioDesignStudio'), Icons.settings, AppColors.gold, AppLocalizations.t('settingsDesignInvoicesAndReports'), '/design/invoice'),
  (AppLocalizations.t('settingsFiles'), Icons.folder, AppColors.primary, AppLocalizations.t('settingsManageFilesAndAttachments'), '/settings/files'),
  (AppLocalizations.t('designStudioMail'), Icons.email, AppColors.gold, AppLocalizations.t('settingsSMTPTemplatesPreferences'), '/email/settings'),
  (AppLocalizations.t('settingsMailTemplates'), Icons.email, AppColors.warning, AppLocalizations.t('settingsEmailMessageTemplates'), '/settings/email-templates'),
  (AppLocalizations.t('emailMailLog'), Icons.email, AppColors.success, AppLocalizations.t('settingsRecordSendingMail'), '/settings/email-logs'),
  (AppLocalizations.t('notifications'), Icons.notifications, AppColors.danger, AppLocalizations.t('notificationsNotificationSettings'), RouteNames.notifications),
  (AppLocalizations.t('homeServiceBackup'), Icons.backup, AppColors.info, AppLocalizations.t('settingsCopyAndRestore'), RouteNames.personalBackup),
  (AppLocalizations.t('settingsCustomization'), Icons.settings, AppColors.gold, AppLocalizations.t('settingsCustomizeInterfaceAndColors'), '/settings/customization'),
  (AppLocalizations.t('profile'), Icons.person, AppColors.primary, AppLocalizations.t('settingsUserPersonalData'), RouteNames.profile),
  (AppLocalizations.t('settingsSecurity'), Icons.security, AppColors.danger, AppLocalizations.t('settingsPasswordSessions'), '/change-password'),
];

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final user = ref.watch(authProvider).user;
    final business = ref.read(currentBusinessTypeProvider) == 'business';
    final sections = <(String, IconData, Color, String, String)>[
      ..._settingsSections,
      if (business && (user?.role == 'owner' || user?.isPlatformAdmin == true))
        (l10n.translate('branchesTitle'), Icons.account_tree_outlined,
            AppColors.primary, l10n.translate('branchesSubtitle'), '/branches'),
    ];
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(AppLocalizations.of(context).translate('settings'))),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: sections.length,
        itemBuilder: (context, index) {
          final s = sections[index];
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(color: AppColors.surface, borderRadius: AppRadius.mdBorder, border: Border.all(color: AppColors.border)),
            child: ListTile(
              contentPadding: const EdgeInsets.all(14),
              leading: Container(
                width: 48, height: 48,
                decoration: BoxDecoration(color: s.$3.withAlpha(25), borderRadius: BorderRadius.circular(12)),
                child: Icon(s.$2, color: s.$3, size: 24),
              ),
              title: Text(s.$1, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
              subtitle: Text(s.$4, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textSecondary)),
              trailing: const Icon(Icons.arrow_back_ios_new, color: AppColors.textDisabled),
              onTap: () {
                final route = s.$5 == RouteNames.profile
                    ? RouteNames.profileForMode(
                        ref.read(currentBusinessTypeProvider))
                    : s.$5;
                context.push(route);
              },
            ),
          );
        },
      ),
    );
  }
}
