import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/utils/extensions/context_extensions.dart';
import '../../../../core/utils/validators/app_validators.dart';
import '../../di/email_providers.dart';
import '../providers/email_providers.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../core/localization/app_localizations.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class EmailComposePage extends ConsumerStatefulWidget {
  final String? presetTo;
  final String? presetSubject;
  const EmailComposePage({super.key, this.presetTo, this.presetSubject});
  @override
  ConsumerState<EmailComposePage> createState() => _EmailComposePageState();
}

class _EmailComposePageState extends ConsumerState<EmailComposePage> {
  final _formKey = GlobalKey<FormState>();
  bool _sending = false;

  final _toCtrl = TextEditingController();
  final _ccCtrl = TextEditingController();
  final _subjectCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.presetTo != null) _toCtrl.text = widget.presetTo!;
    if (widget.presetSubject != null) _subjectCtrl.text = widget.presetSubject!;
  }

  @override
  void dispose() {
    _toCtrl.dispose();
    _ccCtrl.dispose();
    _subjectCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _sending = true);
    try {
      await ref.read(emailServiceProvider).send(
        _toCtrl.text.trim(),
        _subjectCtrl.text.trim(),
        _bodyCtrl.text.trim(),
        isHtml: false,
      );
      ref.invalidate(emailLogListProvider);
      if (mounted) {
        context.showSuccessSnackBar(AppLocalizations.of(context).translate('emailMailSentSuccessfully'));
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) context.showErrorSnackBar(AppLocalizations.of(context).translate('emailTransmissionFailure', params: {'e': e}));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  InputDecoration _inputDec(String label, {Widget? suffix}) {
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary),
      filled: true,
      fillColor: AppColors.surfaceVariant,
      border: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.border)),
      enabledBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.border)),
      focusedBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      suffixIcon: suffix,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: Text(AppLocalizations.of(context).translate('emailSendMail')),
          actions: [
            TextButton(
              onPressed: _sending ? null : _send,
              child: Text(_sending ? '...' : AppLocalizations.of(context).translate('adminSend'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.primary, fontSize: R.fontSize(context, 15))),
            ),
          ],
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: EdgeInsets.all(R.spacing(context)),
            children: [
              FyonaTextFormField(
                controller: _toCtrl,
                keyboardType: TextInputType.emailAddress,
                validator: (v) => AppValidators.validateEmail(v),
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary),
                decoration: _inputDec(AppLocalizations.of(context).translate('emailTo')),
              ),
              SizedBox(height: R.spacing(context)),
              FyonaTextFormField(
                controller: _ccCtrl,
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary),
                decoration: _inputDec('CC'),
              ),
              SizedBox(height: R.spacing(context)),
              FyonaTextFormField(
                controller: _subjectCtrl,
                validator: (v) => AppValidators.validateRequired(v, AppLocalizations.of(context).translate('emailTheTopic')),
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary),
                decoration: _inputDec(AppLocalizations.of(context).translate('emailTheTopic2')),
              ),
              SizedBox(height: R.spacing(context)),
              FyonaTextFormField(
                controller: _bodyCtrl,
                maxLines: 10,
                validator: (v) => AppValidators.validateRequired(v, AppLocalizations.of(context).translate('colorText')),
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: AppColors.textPrimary),
                decoration: _inputDec(AppLocalizations.of(context).translate('emailText')).copyWith(
                  alignLabelWithHint: true,
                ),
              ),
              SizedBox(height: R.spacing(context, 24)),
              SizedBox(
                height: R.buttonHeight(context),
                child: ElevatedButton.icon(
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : TwoToneIcon(data: TwoToneIcons.share),
                  label: Text(_sending ? AppLocalizations.of(context).translate('emailSending') : AppLocalizations.of(context).translate('adminSend'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14))),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
