import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import '../providers/receipt_design_provider.dart';
import '../providers/receipt_design_models.dart';

class ReceiptDesignHubPage extends ConsumerWidget {
  const ReceiptDesignHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final presets = ref.watch(personalReceiptDesignProvider);
    final unified =
        ref.watch(personalReceiptDesignProvider.notifier).unified;
    final sections = unified
        // Unified mode: the Default customization drives every receipt, so
        // it is the ONLY card shown.
        ? const [PersonalReceiptSection.default_]
        // Per-section mode: the six customizable sections. Default is
        // hidden here because no receipt reads it directly in this mode.
        : personalReceiptSections
            .where((s) => s != PersonalReceiptSection.default_)
            .toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new,
              color: AppColors.textPrimary, size: 20),
          // Back to the profile preferences that opened this hub.
          onPressed: () => context.pop(),
        ),
        title: Text(l10n.translate('receiptCustomize'),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 16),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
        centerTitle: true,
      ),
      body: ListView(
        padding: EdgeInsets.all(R.spacing(context, 12)),
        children: [
          // ── Unified receipt switch ──
          Container(
            margin: EdgeInsets.only(bottom: R.spacing(context, 10)),
            decoration: BoxDecoration(
              color: unified
                  ? AppColors.primary.withAlpha(18)
                  : AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: unified ? AppColors.primary : AppColors.border),
            ),
            child: SwitchListTile(
              value: unified,
              activeThumbColor: AppColors.primary,
              onChanged: (v) async {
                await ref
                    .read(personalReceiptDesignProvider.notifier)
                    .setUnified(v);
              },
              title: Text(l10n.translate('receiptUnifiedTitle'),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.font(context),
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary)),
              subtitle: Text(l10n.translate('receiptUnifiedHint'),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.font(context, 'caption'),
                      color: AppColors.textSecondary)),
            ),
          ),
          ...sections.map((section) {
            final preset =
                presets[section.id] ?? ReceiptDesignPreset.defaults(section.id);
            return _SectionCard(section: section, preset: preset);
          }),
        ],
      ),
    );
  }
}

class _SectionCard extends ConsumerWidget {
  final PersonalReceiptSection section;
  final ReceiptDesignPreset preset;

  const _SectionCard({required this.section, required this.preset});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final isDefault = section == PersonalReceiptSection.default_;

    return Container(
      margin: EdgeInsets.only(bottom: R.spacing(context, 10)),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => context.push('/personal/receipt-design/edit', extra: section),
          child: Padding(
            padding: EdgeInsets.all(R.spacing(context, 12)),
            child: Row(
              children: [
                _buildPreview(),
                SizedBox(width: R.spacing(context, 12)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.translate(section.nameKey),
                        style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                      ),
                      SizedBox(height: 4),
                      Text('${l10n.translate('deposit')} ${l10n.translate(section.iconLabelKey)}',
                        style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'caption'), color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                if (!isDefault)
                  IconButton(
                    icon: Icon(Icons.restart_alt, size: 18, color: AppColors.textSecondary),
                    tooltip: l10n.translate('clear'),
                    onPressed: () => ref.read(personalReceiptDesignProvider.notifier).resetToDefaults(section.id),
                  ),
                Icon(Icons.arrow_back_ios_new, size: 18, color: AppColors.textDisabled),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final isCustom = preset.primaryColor != const Color(0xFFA01530) ||
        preset.backgroundColor != const Color(0xFFFFFFFF) ||
        preset.brandName != 'FYONA' ||
        preset.footerText != 'FYONA ERP' ||
        preset.fontSizeScale != 1.0 ||
        !preset.showAccentBar ||
        !preset.showFooter ||
        preset.logoBytes != null;

    return Container(
      width: 72,
      height: 96,
      decoration: BoxDecoration(
        color: preset.backgroundColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isCustom ? preset.primaryColor.withAlpha(100) : preset.dividerColor,
          width: isCustom ? 1.5 : 0.5,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (preset.showAccentBar)
            Container(
              height: 4,
              width: 40,
              margin: const EdgeInsets.only(top: 8),
              decoration: BoxDecoration(
                color: preset.accentBarColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          if (preset.showAccentBar) const SizedBox(height: 2),
          const Spacer(),
          if (preset.showBrandLogo)
            Container(
              width: 26, height: 26,
              decoration: BoxDecoration(
                color: preset.primaryColor.withAlpha(200),
                borderRadius: BorderRadius.circular(7),
              ),
              child: preset.logoBytes != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(7),
                      child: Image.memory(preset.logoBytes!, width: 26, height: 26, fit: BoxFit.cover),
                    )
                  : Center(
                      child: Text('F',
                        style: TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.w800, color: Colors.white),
                      ),
                    ),
            ),
          if (preset.showBrandLogo) const SizedBox(height: 2),
          Text(preset.brandName.length > 6 ? preset.brandName.substring(0, 6) : preset.brandName,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontFamily: 'Cairo', fontSize: 7, fontWeight: FontWeight.w800, color: preset.primaryColor, letterSpacing: 1),
          ),
          const SizedBox(height: 2),
          Text('SAR',
            style: TextStyle(fontFamily: 'Cairo', fontSize: 7, fontWeight: FontWeight.w700, color: preset.amountColor),
          ),
          const Spacer(),
          Container(height: 2, margin: EdgeInsets.symmetric(horizontal: 8), color: preset.dividerColor),
          const SizedBox(height: 3),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isCustom)
                Icon(Icons.check_circle, size: 8, color: preset.primaryColor),
              if (isCustom) const SizedBox(width: 2),
              Text(preset.footerText.length > 10 ? '${preset.footerText.substring(0, 10)}..' : preset.footerText,
                style: TextStyle(fontFamily: 'Cairo', fontSize: 5, color: preset.secondaryTextColor.withAlpha(180)),
              ),
            ],
          ),
          const SizedBox(height: 3),
        ],
      ),
    );
  }
}
