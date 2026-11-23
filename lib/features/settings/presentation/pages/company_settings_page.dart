import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import '../../data/models/settings_model.dart';
import '../../di/settings_providers.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/secure_image.dart';
import '../../../../core/localization/app_localizations.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class CompanySettingsPage extends ConsumerStatefulWidget {
  const CompanySettingsPage({super.key});
  @override
  ConsumerState<CompanySettingsPage> createState() => _CompanySettingsPageState();
}

class _CompanySettingsPageState extends ConsumerState<CompanySettingsPage> {
  bool _loading = true;
  bool _saving = false;

  final _nameCtrl = TextEditingController();
  final _legalNameCtrl = TextEditingController();
  final _crCtrl = TextEditingController();
  final _taxCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();

  String? _logoPath;
  String? _existingLogo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final s = await ref.read(settingsServiceProvider).getCompanySettings();
      _nameCtrl.text = s.companyName;
      _legalNameCtrl.text = s.legalName ?? '';
      _crCtrl.text = s.crNumber ?? '';
      _taxCtrl.text = s.taxNumber ?? '';
      _phoneCtrl.text = s.phone ?? '';
      _emailCtrl.text = s.email ?? '';
      _addressCtrl.text = s.address ?? '';
      _existingLogo = s.logo;
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _legalNameCtrl.dispose();
    _crCtrl.dispose();
    _taxCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickLogo() async {
    final result = await FilePicker.pickFiles(type: FileType.image);
    if (result != null && result.files.single.path != null) {
      setState(() => _logoPath = result.files.single.path);
    }
  }

  InputDecoration _inputDec(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary),
      filled: true,
      fillColor: AppColors.surfaceVariant,
      border: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide:  BorderSide(color: AppColors.border)),
      enabledBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide:  BorderSide(color: AppColors.border)),
      focusedBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: const BorderSide(color: AppColors.primary, width: 1.5)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    );
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      showSnackbar(context, message: AppLocalizations.of(context).translate('settingsCompanyNameRequired'), color: AppColors.danger);
      return;
    }
    setState(() => _saving = true);
    try {
      final s = CompanySettings(
        companyName: _nameCtrl.text.trim(),
        legalName: _legalNameCtrl.text.trim().isEmpty ? null : _legalNameCtrl.text.trim(),
        crNumber: _crCtrl.text.trim().isEmpty ? null : _crCtrl.text.trim(),
        taxNumber: _taxCtrl.text.trim().isEmpty ? null : _taxCtrl.text.trim(),
        phone: _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
        email: _emailCtrl.text.trim().isEmpty ? null : _emailCtrl.text.trim(),
        address: _addressCtrl.text.trim().isEmpty ? null : _addressCtrl.text.trim(),
        logo: _logoPath ?? _existingLogo,
      );
      await ref.read(settingsServiceProvider).updateCompanySettings(s);
      if (mounted) showSnackbar(context, message: AppLocalizations.of(context).translate('settingsCompanyDataSaved'));
    } catch (e) {
      if (mounted) showSnackbar(context, message: AppLocalizations.of(context).translate('settingsSaveFailed', params: {'e': e}), color: AppColors.danger);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).translate('onboardingCompanyData')),
        actions: [
          TextButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : TwoToneIcon(data: TwoToneIcons.upload, size: 18),
            label: Text(_saving ? '...' : AppLocalizations.of(context).translate('save'), style: TextStyle(fontFamily: 'Cairo')),
          ),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : ListView(
              padding: EdgeInsets.all(16),
              children: [
                Container(
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: AppRadius.mdBorder,
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(AppLocalizations.of(context).translate('designStudioCompanyInformation'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                       SizedBox(height: 12),
                      FyonaTextField(controller: _nameCtrl, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary), decoration: _inputDec(AppLocalizations.of(context).translate('onboardingCompanyName'))),
                       SizedBox(height: 12),
                      FyonaTextField(controller: _legalNameCtrl, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary), decoration: _inputDec(AppLocalizations.of(context).translate('onboardingLegalName'))),
                    ],
                  ),
                ),
                 SizedBox(height: 12),
                Container(
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: AppRadius.mdBorder,
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(AppLocalizations.of(context).translate('settingsLicensesAndNumbers'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                       SizedBox(height: 12),
                      FyonaTextField(controller: _crCtrl, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary), decoration: _inputDec(AppLocalizations.of(context).translate('onboardingCommercialRegistrationNumber'))),
                       SizedBox(height: 12),
                      FyonaTextField(controller: _taxCtrl, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary), decoration: _inputDec(AppLocalizations.of(context).translate('dataImportTaxNumber'))),
                    ],
                  ),
                ),
                 SizedBox(height: 12),
                Container(
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: AppRadius.mdBorder,
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(AppLocalizations.of(context).translate('settingsContactInformation'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                       SizedBox(height: 12),
                      FyonaTextField(controller: _phoneCtrl, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary), decoration: _inputDec(AppLocalizations.of(context).translate('adminPhone'))),
                       SizedBox(height: 12),
                      FyonaTextField(controller: _emailCtrl, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary), decoration: _inputDec(AppLocalizations.of(context).translate('email'))),
                       SizedBox(height: 12),
                      FyonaTextField(controller: _addressCtrl, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary), decoration: _inputDec(AppLocalizations.of(context).translate('adminTheAddress')), maxLines: 3),
                    ],
                  ),
                ),
                 SizedBox(height: 12),
                Container(
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: AppRadius.mdBorder,
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(AppLocalizations.of(context).translate('settingsCompanyLogo'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                      const SizedBox(height: 12),
                      if (_logoPath != null || _existingLogo != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: _logoPath != null
                                ? Image.file(File(_logoPath!), height: 80, fit: BoxFit.contain)
                                : SecureImage(url: _existingLogo!, height: 80, fit: BoxFit.contain, errorBuilder: (_, _, _) => const TwoToneIcon(data: TwoToneIcons.upload, size: 18)),
                          ),
                        ),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _pickLogo,
                          style: OutlinedButton.styleFrom(foregroundColor: AppColors.textPrimary, side:  BorderSide(color: AppColors.border), shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder)),
                          icon: const TwoToneIcon(data: TwoToneIcons.upload, size: 18),
                          label: Text(AppLocalizations.of(context).translate('settingsRaisingASlogan'), style: TextStyle(fontFamily: 'Cairo')),
                        ),
                      ),
                      if (_logoPath != null || _existingLogo != null) ...[
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: () => setState(() { _logoPath = null; _existingLogo = null; }),
                          child: Text(AppLocalizations.of(context).translate('settingsDeleteLogo'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.danger)),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}
