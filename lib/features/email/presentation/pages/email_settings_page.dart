import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/utils/extensions/context_extensions.dart';
import '../../../../core/utils/validators/app_validators.dart';
import '../../data/models/email_models.dart';
import '../providers/email_providers.dart';
import '../../di/email_providers.dart';
import '../../../../core/localization/app_localizations.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class EmailSettingsPage extends ConsumerStatefulWidget {
  const EmailSettingsPage({super.key});
  @override
  ConsumerState<EmailSettingsPage> createState() => _EmailSettingsPageState();
}

class _EmailSettingsPageState extends ConsumerState<EmailSettingsPage> {
  final _formKey = GlobalKey<FormState>();
  bool _loading = false;
  bool _testing = false;

  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '587');
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _fromAddressCtrl = TextEditingController();
  final _fromNameCtrl = TextEditingController();
  String _encryption = 'tls';

  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final settings = await ref.read(emailServiceProvider).getSettings();
    if (!mounted) return;
    _hostCtrl.text = settings.host;
    _portCtrl.text = settings.port.toString();
    _usernameCtrl.text = settings.username;
    _passwordCtrl.text = settings.password;
    _fromAddressCtrl.text = settings.fromAddress;
    _fromNameCtrl.text = settings.fromName;
    _encryption = settings.encryption;
    setState(() {});
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _fromAddressCtrl.dispose();
    _fromNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      final settings = EmailSettings(
        host: _hostCtrl.text.trim(),
        port: int.tryParse(_portCtrl.text.trim()) ?? 587,
        username: _usernameCtrl.text.trim(),
        password: _passwordCtrl.text.trim(),
        encryption: _encryption,
        fromAddress: _fromAddressCtrl.text.trim(),
        fromName: _fromNameCtrl.text.trim(),
      );
      await ref.read(emailServiceProvider).updateSettings(settings);
      ref.invalidate(emailSettingsProvider);
      if (mounted) context.showSuccessSnackBar(AppLocalizations.of(context).translate('emailMailSettingsHaveBeen'));
    } catch (e) {
      if (mounted) context.showErrorSnackBar('$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _test() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _testing = true);
    try {
      final settings = EmailSettings(
        host: _hostCtrl.text.trim(),
        port: int.tryParse(_portCtrl.text.trim()) ?? 587,
        username: _usernameCtrl.text.trim(),
        password: _passwordCtrl.text.trim(),
        encryption: _encryption,
        fromAddress: _fromAddressCtrl.text.trim(),
        fromName: _fromNameCtrl.text.trim(),
      );
      await ref.read(emailServiceProvider).testConnection(settings);
      if (mounted) context.showSuccessSnackBar(AppLocalizations.of(context).translate('emailConnectingToTheServer'));
    } catch (e) {
      if (mounted) context.showErrorSnackBar(AppLocalizations.of(context).translate('emailCommunicationFailed', params: {'e': e}));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  InputDecoration _inputDec(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary),
      filled: true,
      fillColor: AppColors.surfaceVariant,
      border: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.border)),
      enabledBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.border)),
      focusedBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: Text(AppLocalizations.of(context).translate('emailMailSettings'))),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: EdgeInsets.all(R.spacing(context)),
            children: [
              Container(
                padding: EdgeInsets.all(R.spacing(context)),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: AppRadius.mdBorder,
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(AppLocalizations.of(context).translate('emailOutgoingMailServerSMTP'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'title_small'), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                    SizedBox(height: R.spacing(context)),
                    FyonaTextFormField(
                      controller: _hostCtrl,
                      validator: (v) => AppValidators.validateRequired(v, AppLocalizations.of(context).translate('emailServer')),
                      style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary),
                      decoration: _inputDec(AppLocalizations.of(context).translate('emailServer2')),
                    ),
                    SizedBox(height: R.spacing(context)),
                    FyonaTextFormField(
                      controller: _portCtrl,
                      keyboardType: TextInputType.number,
                      validator: (v) => AppValidators.validatePositiveNumber(v, AppLocalizations.of(context).translate('emailPort')),
                      style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary),
                      decoration: _inputDec(AppLocalizations.of(context).translate('emailPort2')),
                    ),
                    SizedBox(height: R.spacing(context)),
                    DropdownButtonFormField<String>(
                      initialValue: _encryption,
                      decoration: _inputDec(AppLocalizations.of(context).translate('emailEncryption')),
                      dropdownColor: AppColors.surface,
                      style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary),
                      items: [
                        DropdownMenuItem(value: 'ssl', child: Text('SSL', style: TextStyle(fontFamily: 'Cairo'))),
                        DropdownMenuItem(value: 'tls', child: Text('TLS', style: TextStyle(fontFamily: 'Cairo'))),
                        DropdownMenuItem(value: 'none', child: Text(AppLocalizations.of(context).translate('emailWithoutEncryption'), style: TextStyle(fontFamily: 'Cairo'))),
                      ],
                      onChanged: (v) => setState(() => _encryption = v ?? 'tls'),
                    ),
                    SizedBox(height: R.spacing(context)),
                    FyonaTextFormField(
                      controller: _usernameCtrl,
                      validator: (v) => AppValidators.validateRequired(v, AppLocalizations.of(context).translate('username')),
                      style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary),
                      decoration: _inputDec(AppLocalizations.of(context).translate('emailUsername')),
                    ),
                    SizedBox(height: R.spacing(context)),
                    FyonaTextFormField(
                      controller: _passwordCtrl,
                      obscureText: !_showPassword,
                      style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary),
                      decoration: _inputDec(AppLocalizations.of(context).translate('password')).copyWith(
                        suffixIcon: IconButton(
                          icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility, color: AppColors.textSecondary),
                          onPressed: () => setState(() => _showPassword = !_showPassword),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: R.spacing(context)),
              Container(
                padding: EdgeInsets.all(R.spacing(context)),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: AppRadius.mdBorder,
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(AppLocalizations.of(context).translate('emailSentMail'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'title_small'), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                    SizedBox(height: R.spacing(context)),
                    FyonaTextFormField(
                      controller: _fromAddressCtrl,
                      validator: (v) => AppValidators.validateEmail(v),
                      style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary),
                      decoration: _inputDec(AppLocalizations.of(context).translate('emailFromMail')),
                    ),
                    SizedBox(height: R.spacing(context)),
                    FyonaTextFormField(
                      controller: _fromNameCtrl,
                      style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary),
                      decoration: _inputDec(AppLocalizations.of(context).translate('emailFromName')),
                    ),
                  ],
                ),
              ),
              SizedBox(height: R.spacing(context, 24)),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: R.buttonHeight(context),
                      child: ElevatedButton(
                        onPressed: _loading ? null : _save,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder),
                        ),
                        child: Text(_loading ? '...' : AppLocalizations.of(context).translate('adminSaveSettings'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14))),
                      ),
                    ),
                  ),
                  SizedBox(width: R.spacing(context)),
                  Expanded(
                    child: SizedBox(
                      height: R.buttonHeight(context),
                      child: OutlinedButton(
                        onPressed: _testing ? null : _test,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.textPrimary,
                          side:  BorderSide(color: AppColors.border),
                          shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder),
                        ),
                        child: Text(_testing ? AppLocalizations.of(context).translate('emailTestingInProgress') : AppLocalizations.of(context).translate('emailConnectionTest'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14))),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
