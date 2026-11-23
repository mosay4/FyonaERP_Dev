import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../core/localization/app_localizations.dart';

class CustomizationPage extends ConsumerWidget {
  const CustomizationPage({super.key});

  static final _sections = [
    (Icons.receipt_long, AppLocalizations.t('settingsInvoices'), AppLocalizations.t('settingsColorsFontsLogoFields'), '/design/invoice'),
    (Icons.assessment, AppLocalizations.t('reports'), AppLocalizations.t('settingsFinancialAndSalesReport'), '/design/report'),
    (Icons.settings, AppLocalizations.t('settingsVisualIdentity'), AppLocalizations.t('settingsLogoPrimaryColorsDefault'), '/design/brand'),
    (Icons.print, AppLocalizations.t('settingsPrintingAndExporting'), AppLocalizations.t('settingsPDFPNGPaperSize'), '/design/print'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(AppLocalizations.of(context).translate('settingsDesignCenter'))),
      body: ListView(
        padding: EdgeInsets.all(R.spacing(context, AppSpacing.lg)),
        children: _sections.map((s) => GestureDetector(
          onTap: () => context.push(s.$4),
          child: Container(
            margin: EdgeInsets.only(bottom: R.spacing(context, AppSpacing.sm)),
            padding: EdgeInsets.all(R.spacing(context, AppSpacing.md)),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: AppRadius.mdBorder,
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                Container(
                  width: 38, height: 38,
                  decoration: BoxDecoration(color: AppColors.primary.withAlpha(30), borderRadius: AppRadius.smBorder),
                  child: Icon(s.$1, size: 20, color: Colors.white),
                ),
                SizedBox(width: R.spacing(context, AppSpacing.md)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.$2, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                      Text(s.$3, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'caption'), color: AppColors.textSecondary)),
                    ],
                  ),
                ),
                TwoToneIcon(data: TwoToneIcons.arrowRight, size: 16, outlineColor: AppColors.textDisabled),
              ],
            ),
          ),
        )).toList(),
      ),
    );
  }
}
