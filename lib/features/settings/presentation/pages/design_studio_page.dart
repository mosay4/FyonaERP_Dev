import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import '../../../../core/localization/app_localizations.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

// ──────────────────────────────────────────────
// InvoiceDesignStudio
// ──────────────────────────────────────────────

class InvoiceDesignStudio extends ConsumerStatefulWidget {
  const InvoiceDesignStudio({super.key});
  @override
  ConsumerState<InvoiceDesignStudio> createState() => _InvoiceDesignStudioState();
}

class _InvoiceDesignStudioState extends ConsumerState<InvoiceDesignStudio> {
  bool _showProductImages = true;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) {
        setState(() =>
            _showProductImages = p.getBool('invoice_show_product_images') ?? true);
      }
    });
  }

  Future<void> _setShowProductImages(bool v) async {
    setState(() => _showProductImages = v);
    final p = await SharedPreferences.getInstance();
    await p.setBool('invoice_show_product_images', v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(AppLocalizations.of(context).translate('settingsInvoiceDesignStudio'))),
      body: ListView(
        padding: EdgeInsets.all(R.spacing(context, AppSpacing.md)),
        children: [
          _buildAccordion(AppLocalizations.of(context).translate('settingsGeneralSettings'), HugeIcons.strokeRoundedSettings02, Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildDropdown(AppLocalizations.of(context).translate('font'), 'Amiri', ['Amiri', 'Cairo']),
              SizedBox(height: R.spacing(context, AppSpacing.sm)),
              _buildDropdown(AppLocalizations.of(context).translate('designStudioPlanning'), 'modern', ['modern', 'classic']),
            ],
          )),
          SizedBox(height: R.spacing(context, AppSpacing.sm)),
          _buildAccordion(AppLocalizations.of(context).translate('settingsCompanyIdentity'), HugeIcons.strokeRoundedBuilding01, Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSecondaryButton(AppLocalizations.of(context).translate('settingsRaiseTheLogo')),
              SizedBox(height: R.spacing(context, AppSpacing.sm)),
              _buildTextField(AppLocalizations.of(context).translate('designStudioCompanyName'), ''),
            ],
          )),
          SizedBox(height: R.spacing(context, AppSpacing.sm)),
          _buildAccordion(AppLocalizations.of(context).translate('settingsContactInformation2'), HugeIcons.strokeRoundedContact, Column(
            children: [
              _buildTextFieldRow([AppLocalizations.of(context).translate('adminPhone'), AppLocalizations.of(context).translate('settingsPhone2')]),
              SizedBox(height: R.spacing(context, AppSpacing.sm)),
              _buildTextFieldRow([AppLocalizations.of(context).translate('settingsMobile'), AppLocalizations.of(context).translate('designStudioMail')]),
              SizedBox(height: R.spacing(context, AppSpacing.sm)),
              _buildTextField(AppLocalizations.of(context).translate('adminTheAddress'), ''),
            ],
          )),
          SizedBox(height: R.spacing(context, AppSpacing.sm)),
          _buildAccordion(AppLocalizations.of(context).translate('settingsShowAndHideItems'), HugeIcons.strokeRoundedView, Column(
            children: [
              _checkboxCard(AppLocalizations.of(context).translate('logo'), true),
              SizedBox(height: R.spacing(context, AppSpacing.xs)),
              _checkboxCard(AppLocalizations.of(context).translate('designStudioCompanyName'), true),
              SizedBox(height: R.spacing(context, AppSpacing.xs)),
              _checkboxCard(AppLocalizations.of(context).translate('settingsBranch'), true),
              SizedBox(height: R.spacing(context, AppSpacing.xs)),
              _checkboxCard(AppLocalizations.of(context).translate('settingsNumber2'), true),
              SizedBox(height: R.spacing(context, AppSpacing.xs)),
              _checkboxCard(AppLocalizations.of(context).translate('date'), true),
              SizedBox(height: R.spacing(context, AppSpacing.xs)),
              _checkboxCard(AppLocalizations.of(context).translate('statusDetail'), true),
              SizedBox(height: R.spacing(context, AppSpacing.xs)),
              _checkboxCard(AppLocalizations.of(context).translate('amountLabel'), true),
              SizedBox(height: R.spacing(context, AppSpacing.xs)),
              _checkboxCard(AppLocalizations.of(context).translate('settingsTheAmountIsWritten'), true),
              SizedBox(height: R.spacing(context, AppSpacing.xs)),
              _checkboxCard(AppLocalizations.of(context).translate('settingsParty'), true),
              SizedBox(height: R.spacing(context, AppSpacing.xs)),
              _checkboxCard(AppLocalizations.of(context).translate('settingsItems'), true),
              SizedBox(height: R.spacing(context, AppSpacing.xs)),
              _checkboxCard(AppLocalizations.of(context).translate('designStudioTotals'), true),
              SizedBox(height: R.spacing(context, AppSpacing.xs)),
              _checkboxCard(AppLocalizations.of(context).translate('settingsCommunication'), true),
              SizedBox(height: R.spacing(context, AppSpacing.xs)),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _showProductImages,
                onChanged: (v) => _setShowProductImages(v),
                title: Text(
                    AppLocalizations.of(context)
                        .translate('settingsShowProductImages'),
                    style: R.textStyle(
                        context, TypographySizes.body, AppColors.textPrimary)),
              ),
            ],
          )),
          SizedBox(height: R.spacing(context, AppSpacing.sm)),
          _buildAccordion(AppLocalizations.of(context).translate('settingsColorsAndDesign'), HugeIcons.strokeRoundedColors, Column(
            children: [
              _buildColorRow([AppLocalizations.of(context).translate('settingsBasic'), AppLocalizations.of(context).translate('settingsSecondary'), AppLocalizations.of(context).translate('designStudioBackground')]),
              SizedBox(height: R.spacing(context, AppSpacing.sm)),
              _buildColorRow([AppLocalizations.of(context).translate('settingsCards'), AppLocalizations.of(context).translate('texts'), AppLocalizations.of(context).translate('settingsSecondaryTexts')]),
              SizedBox(height: R.spacing(context, AppSpacing.sm)),
              _buildColorRow([AppLocalizations.of(context).translate('settingsBorder'), AppLocalizations.of(context).translate('amountLabel'), AppLocalizations.of(context).translate('settingsTableHeader')]),
            ],
          )),
          SizedBox(height: R.spacing(context, AppSpacing.sm)),
          _buildAccordion(AppLocalizations.of(context).translate('settingsPrintingAndExporting'), HugeIcons.strokeRoundedPrinter, Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildDropdown(AppLocalizations.of(context).translate('settingsFormula'), 'png', ['png', 'jpg']),
              SizedBox(height: R.spacing(context, AppSpacing.sm)),
              _buildSlider(AppLocalizations.of(context).translate('settingsQuality'), 95, 50, 100),
            ],
          )),
          SizedBox(height: R.spacing(context, AppSpacing.sm)),
          _buildAccordion(AppLocalizations.of(context).translate('settingsSignatureAndSeal'), HugeIcons.strokeRoundedEdit02, Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _checkboxCard(AppLocalizations.of(context).translate('designStudioTheSignature'), false),
              SizedBox(height: R.spacing(context, AppSpacing.sm)),
              _buildSecondaryButton(AppLocalizations.of(context).translate('settingsUploadSignature')),
              SizedBox(height: R.spacing(context, AppSpacing.sm)),
              _checkboxCard(AppLocalizations.of(context).translate('designStudioSeal'), false),
              SizedBox(height: R.spacing(context, AppSpacing.sm)),
              _buildSecondaryButton(AppLocalizations.of(context).translate('settingsLiftTheSeal')),
            ],
          )),
          SizedBox(height: R.spacing(context, AppSpacing.sm)),
          _buildAccordion(AppLocalizations.of(context).translate('settingsReset'), HugeIcons.strokeRoundedRefresh01, Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(AppLocalizations.of(context).translate('settingsRestoreAllBillingSettings'),
                  style: R.textStyle(context, TypographySizes.caption, AppColors.textSecondary)),
              SizedBox(height: R.spacing(context, AppSpacing.sm)),
              _buildDangerButton(AppLocalizations.of(context).translate('settingsRestoreDefaultSettings')),
            ],
          )),
          SizedBox(height: R.spacing(context, AppSpacing.xl)),
          SizedBox(
            width: double.infinity,
            height: R.buttonHeight(context),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder)),
              onPressed: () => showSnackbar(context, message: AppLocalizations.of(context).translate('settingsBillingSettingsHaveBeen')),
              child: Text(AppLocalizations.of(context).translate('settingsSaveChanges')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccordion(String title, List<List<dynamic>> icon, Widget child) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(R.spacing(context, AppSpacing.md)),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: AppRadius.mdBorder, border: Border.all(color: AppColors.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            HugeIcon(icon: icon, size: 16, color: AppColors.primary),
            SizedBox(width: R.gap(context)),
            Text(title, style: R.textStyle(context, TypographySizes.body, AppColors.textPrimary)),
          ]),
          SizedBox(height: R.spacing(context, AppSpacing.sm)),
          child,
        ],
      ),
    );
  }

  Widget _buildTextField(String label, String value) {
    return FyonaTextField(
      style: R.textStyle(context, null, AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        labelStyle:  TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide:  BorderSide(color: AppColors.border)),
        focusedBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: const BorderSide(color: AppColors.primary)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
    );
  }

  Widget _buildDropdown(String label, String value, List<String> options) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      dropdownColor: AppColors.surface,
      style: R.textStyle(context, null, AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        labelStyle:  TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide:  BorderSide(color: AppColors.border)),
        focusedBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: const BorderSide(color: AppColors.primary)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      items: options.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
      onChanged: (v) => showSnackbar(context, message: AppLocalizations.of(context).translate('settingsHasBeenChanged', params: {'label': label})),
    );
  }

  Widget _checkboxCard(String label, bool value) {
    return InkWell(
      onTap: () => showSnackbar(context, message: value ? AppLocalizations.of(context).translate('settingsCanceled') : AppLocalizations.of(context).translate('settingsActivated')),
      borderRadius: AppRadius.smBorder,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: R.spacing(context, AppSpacing.sm), vertical: R.spacing(context, AppSpacing.xs)),
        decoration: BoxDecoration(
          color: value ? AppColors.primary.withAlpha(15) : AppColors.surface,
          borderRadius: AppRadius.smBorder,
          border: Border.all(color: value ? AppColors.primary.withAlpha(60) : AppColors.border),
        ),
        child: Row(
          children: [
            Icon(
              value ? Icons.check_circle : Icons.close,
              size: 20,
              color: value ? AppColors.primary : AppColors.textDisabled,
            ),
            SizedBox(width: R.spacing(context, AppSpacing.sm)),
            Expanded(
              child: Text(label,
                  style: R.textStyle(context, TypographySizes.bodySmall, value ? AppColors.textPrimary : AppColors.textSecondary)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlider(String label, double value, double min, double max) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: R.textStyle(context, TypographySizes.body, AppColors.textSecondary)),
      Slider(value: value, min: min, max: max, activeColor: AppColors.primary, inactiveColor: AppColors.border, onChanged: (v) => showSnackbar(context, message: AppLocalizations.of(context).translate('settingsTheValueHasBeen'))),
    ]);
  }

  Widget _buildSecondaryButton(String text) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(foregroundColor: AppColors.textPrimary, side:  BorderSide(color: AppColors.border), shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder)),
      onPressed: () => showSnackbar(context, message: AppLocalizations.of(context).translate('settingsTheFileHasBeen')),
      child: Text(text),
    );
  }

  Widget _buildDangerButton(String text) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger, side: const BorderSide(color: AppColors.danger), shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder)),
      onPressed: () => showSnackbar(context, message: AppLocalizations.of(context).translate('settingsDefaultSettingsHaveBeen')),
      child: Text(text),
    );
  }

  Widget _buildColorRow(List<String> keys) {
    return Row(children: keys.map((k) => Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: _buildTextField(k, '#6B0F1A')))).toList());
  }

  Widget _buildTextFieldRow(List<String> labels) {
    return Row(children: labels.map((l) => Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: _buildTextField(l, '')))).toList());
  }
}

// ──────────────────────────────────────────────
// ReportDesignStudio
// ──────────────────────────────────────────────

class ReportDesignStudio extends ConsumerStatefulWidget {
  const ReportDesignStudio({super.key});
  @override
  ConsumerState<ReportDesignStudio> createState() => _ReportDesignStudioState();
}

class _ReportDesignStudioState extends ConsumerState<ReportDesignStudio> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(AppLocalizations.of(context).translate('settingsReportDesignStudio'))),
      body: ListView(
        padding: EdgeInsets.all(R.spacing(context, AppSpacing.lg)),
        children: [
          Row(children: [
            HugeIcon(icon: HugeIcons.strokeRoundedChartLineData01, size: 24, color: AppColors.primary),
            SizedBox(width: R.spacing(context, AppSpacing.md)),
            Text(AppLocalizations.of(context).translate('settingsConsolidatedReportSettings'), style: R.textStyle(context, TypographySizes.titleSmall, AppColors.textPrimary)),
          ]),
          SizedBox(height: R.spacing(context, AppSpacing.xs)),
          Text(AppLocalizations.of(context).translate('settingsThisDesignWillBe'),
              style: R.textStyle(context, TypographySizes.bodySmall, AppColors.textSecondary)),
          SizedBox(height: R.spacing(context, AppSpacing.xl)),
          _buildDesignSection(AppLocalizations.of(context).translate('colors'), [
            _buildTextField(AppLocalizations.of(context).translate('settingsReportHeaderColor'), '#6B0F1A'),
            SizedBox(height: R.spacing(context, AppSpacing.md)),
            _buildTextField(AppLocalizations.of(context).translate('settingsTextColor'), '#1A1A2E'),
          ]),
          SizedBox(height: R.spacing(context, AppSpacing.md)),
          _buildDesignSection(AppLocalizations.of(context).translate('designStudioPlanning'), [
            _checkboxCard(AppLocalizations.of(context).translate('showLogo'), true),
             Divider(height: 1, color: AppColors.border),
            _checkboxCard(AppLocalizations.of(context).translate('settingsShowFooter'), true),
            SizedBox(height: R.spacing(context, AppSpacing.sm)),
            _buildTextField(AppLocalizations.of(context).translate('footerText'), AppLocalizations.of(context).translate('designStudioThankYouForDealing')),
          ]),
          SizedBox(height: R.spacing(context, AppSpacing.xl)),
          SizedBox(
            width: double.infinity,
            height: R.buttonHeight(context),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder)),
              onPressed: () => showSnackbar(context, message: AppLocalizations.of(context).translate('settingsReportSettingsHaveBeen')),
              child: Text(AppLocalizations.of(context).translate('settingsSaveReportSettings')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesignSection(String label, List<Widget> children) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(R.spacing(context, AppSpacing.md)),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: AppRadius.mdBorder, border: Border.all(color: AppColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: R.textStyle(context, TypographySizes.body, AppColors.textPrimary)),
        SizedBox(height: R.spacing(context, AppSpacing.md)),
        ...children,
      ]),
    );
  }

  Widget _buildTextField(String label, String value) {
    return FyonaTextField(
      style: R.textStyle(context, null, AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        labelStyle:  TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide:  BorderSide(color: AppColors.border)),
        focusedBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: const BorderSide(color: AppColors.primary)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
    );
  }

  Widget _checkboxCard(String label, bool value) {
    return InkWell(
      onTap: () => showSnackbar(context, message: value ? AppLocalizations.of(context).translate('settingsCanceled') : AppLocalizations.of(context).translate('settingsActivated')),
      borderRadius: AppRadius.smBorder,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: R.spacing(context, AppSpacing.sm), vertical: R.spacing(context, AppSpacing.xs)),
        decoration: BoxDecoration(
          color: value ? AppColors.primary.withAlpha(15) : AppColors.surface,
          borderRadius: AppRadius.smBorder,
          border: Border.all(color: value ? AppColors.primary.withAlpha(60) : AppColors.border),
        ),
        child: Row(
          children: [
            Icon(
              value ? Icons.check_circle : Icons.close,
              size: 20,
              color: value ? AppColors.primary : AppColors.textDisabled,
            ),
            SizedBox(width: R.spacing(context, AppSpacing.sm)),
            Expanded(
              child: Text(label,
                  style: R.textStyle(context, TypographySizes.bodySmall, value ? AppColors.textPrimary : AppColors.textSecondary)),
            ),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────
// BrandDesignStudio
// ──────────────────────────────────────────────

class BrandDesignStudio extends ConsumerStatefulWidget {
  const BrandDesignStudio({super.key});
  @override
  ConsumerState<BrandDesignStudio> createState() => _BrandDesignStudioState();
}

class _BrandDesignStudioState extends ConsumerState<BrandDesignStudio> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(AppLocalizations.of(context).translate('settingsVisualIdentityStudio'))),
      body: ListView(
        padding: EdgeInsets.all(R.spacing(context, AppSpacing.lg)),
        children: [
          Row(children: [
            HugeIcon(icon: HugeIcons.strokeRoundedColors, size: 24, color: AppColors.primary),
            SizedBox(width: R.spacing(context, AppSpacing.md)),
            Text(AppLocalizations.of(context).translate('settingsVisualIdentity'), style: R.textStyle(context, TypographySizes.titleSmall, AppColors.textPrimary)),
          ]),
          SizedBox(height: R.spacing(context, AppSpacing.xs)),
          Text(AppLocalizations.of(context).translate('settingsCompletelyCustomizeTheOverall'),
              style: R.textStyle(context, TypographySizes.bodySmall, AppColors.textSecondary)),
          SizedBox(height: R.spacing(context, AppSpacing.xl)),
          _buildBrandSection(AppLocalizations.of(context).translate('logo'), [
            Row(children: [
              OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.primary, side: const BorderSide(color: AppColors.primary), shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder)),
                onPressed: () => showSnackbar(context, message: AppLocalizations.of(context).translate('settingsTheLogoHasBeen')),
                child: Text(AppLocalizations.of(context).translate('settingsChangeLogo')),
              ),
            ]),
          ]),
          SizedBox(height: R.spacing(context, AppSpacing.md)),
          _buildBrandSection(AppLocalizations.of(context).translate('settingsCompany'), [
            _buildTextField(AppLocalizations.of(context).translate('designStudioCompanyName'), ''),
          ]),
          SizedBox(height: R.spacing(context, AppSpacing.md)),
          _buildBrandSection(AppLocalizations.of(context).translate('colors'), [
            _buildTextField(AppLocalizations.of(context).translate('designStudioPrimaryColor'), '#6B0F1A'),
            SizedBox(height: R.spacing(context, AppSpacing.md)),
            _buildTextField(AppLocalizations.of(context).translate('designStudioSecondaryColor'), '#C8A03C'),
          ]),
          SizedBox(height: R.spacing(context, AppSpacing.xl)),
          SizedBox(
            width: double.infinity,
            height: R.buttonHeight(context),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder)),
              onPressed: () => showSnackbar(context, message: AppLocalizations.of(context).translate('settingsVisualIdentityPreserved')),
              child: Text(AppLocalizations.of(context).translate('settingsPreservingVisualIdentity')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBrandSection(String label, List<Widget> children) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(R.spacing(context, AppSpacing.md)),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: AppRadius.mdBorder, border: Border.all(color: AppColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: R.textStyle(context, TypographySizes.body, AppColors.textPrimary)),
        SizedBox(height: R.spacing(context, AppSpacing.md)),
        ...children,
      ]),
    );
  }

  Widget _buildTextField(String label, String value) {
    return FyonaTextField(
      style: R.textStyle(context, null, AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        labelStyle:  TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide:  BorderSide(color: AppColors.border)),
        focusedBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: const BorderSide(color: AppColors.primary)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
    );
  }
}

// ──────────────────────────────────────────────
// PrintDesignStudio
// ──────────────────────────────────────────────

class PrintDesignStudio extends ConsumerStatefulWidget {
  const PrintDesignStudio({super.key});
  @override
  ConsumerState<PrintDesignStudio> createState() => _PrintDesignStudioState();
}

class _PrintDesignStudioState extends ConsumerState<PrintDesignStudio> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(AppLocalizations.of(context).translate('settingsPrintingAndExportStudio'))),
      body: ListView(
        padding: EdgeInsets.all(R.spacing(context, AppSpacing.lg)),
        children: [
          Row(children: [
            HugeIcon(icon: HugeIcons.strokeRoundedPrinter, size: 24, color: AppColors.primary),
            SizedBox(width: R.spacing(context, AppSpacing.md)),
            Text(AppLocalizations.of(context).translate('settingsPrintingAndExporting'), style: R.textStyle(context, TypographySizes.titleSmall, AppColors.textPrimary)),
          ]),
          SizedBox(height: R.spacing(context, AppSpacing.xs)),
          Text(AppLocalizations.of(context).translate('settingsInvoiceAndReportExport'),
              style: R.textStyle(context, TypographySizes.bodySmall, AppColors.textSecondary)),
          SizedBox(height: R.spacing(context, AppSpacing.xl)),
          _buildPrintSection(AppLocalizations.of(context).translate('settingsCoordination'), [
            _buildDropdown(AppLocalizations.of(context).translate('settingsExportFormat'), 'PNG', ['PDF', 'PNG', 'JPG', 'Excel', 'CSV']),
          ]),
          SizedBox(height: R.spacing(context, AppSpacing.md)),
          _buildPrintSection(AppLocalizations.of(context).translate('settingsPage'), [
            _buildLabeledDropdown(AppLocalizations.of(context).translate('settingsPaperSize'), 'A4', ['A4', 'Letter', 'A3', 'A5']),
            SizedBox(height: R.spacing(context, AppSpacing.sm)),
            _buildLabeledDropdown(AppLocalizations.of(context).translate('orientation'), 'portrait', ['portrait', 'landscape']),
          ]),
          SizedBox(height: R.spacing(context, AppSpacing.md)),
          _buildPrintSection(AppLocalizations.of(context).translate('settingsQuality'), [
            Text(AppLocalizations.of(context).translate('settingsImageQuality'), style: R.textStyle(context, TypographySizes.body, AppColors.textPrimary)),
            Slider(value: 95, min: 10, max: 100, divisions: 18, activeColor: AppColors.primary, inactiveColor: AppColors.border, onChanged: (v) => showSnackbar(context, message: AppLocalizations.of(context).translate('settingsTheValueHasBeen'))),
          ]),
          SizedBox(height: R.spacing(context, AppSpacing.xl)),
          SizedBox(
            width: double.infinity,
            height: R.buttonHeight(context),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder)),
              onPressed: () => showSnackbar(context, message: AppLocalizations.of(context).translate('settingsPrintSettingsHaveBeen')),
              child: Text(AppLocalizations.of(context).translate('settingsSavePrintSettings')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrintSection(String label, List<Widget> children) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(R.spacing(context, AppSpacing.md)),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: AppRadius.mdBorder, border: Border.all(color: AppColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: R.textStyle(context, TypographySizes.body, AppColors.textPrimary)),
        SizedBox(height: R.spacing(context, AppSpacing.md)),
        ...children,
      ]),
    );
  }

  Widget _buildDropdown(String label, String value, List<String> options) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      dropdownColor: AppColors.surface,
      style: R.textStyle(context, null, AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        labelStyle:  TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide:  BorderSide(color: AppColors.border)),
        focusedBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: const BorderSide(color: AppColors.primary)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      items: options.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
      onChanged: (v) => showSnackbar(context, message: AppLocalizations.of(context).translate('settingsHasBeenChanged', params: {'label': label})),
    );
  }

  Widget _buildLabeledDropdown(String label, String value, List<String> options) {
    return Row(children: [
      Text('$label  ', style: R.textStyle(context, TypographySizes.body, AppColors.textPrimary)),
      SizedBox(width: R.gap(context)),
      Expanded(child: _buildDropdown('', value, options)),
    ]);
  }
}
