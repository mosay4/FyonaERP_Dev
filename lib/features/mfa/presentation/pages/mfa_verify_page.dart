import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import '../../di/mfa_providers.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class MfaVerifyPage extends ConsumerStatefulWidget {
  final String? mfaToken;
  const MfaVerifyPage({super.key, this.mfaToken});
  @override
  ConsumerState<MfaVerifyPage> createState() => _MfaVerifyPageState();
}

class _MfaVerifyPageState extends ConsumerState<MfaVerifyPage> {
  final _pinFields = List.generate(6, (_) => TextEditingController());
  final _focusNodes = List.generate(6, (_) => FocusNode());
  final _backupCodeCtrl = TextEditingController();
  bool _useBackupCode = false;
  bool _verifying = false;

  @override
  void dispose() {
    for (final c in _pinFields) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    _backupCodeCtrl.dispose();
    super.dispose();
  }

  void _onPinChanged(int index, String value) {
    if (value.isNotEmpty && index < 5) {
      _focusNodes[index + 1].requestFocus();
    }
    if (index == 5 && value.isNotEmpty) {
      _verifyPin();
    }
  }

  Future<void> _verifyPin() async {
    final l10n = AppLocalizations.of(context);
    final code = _pinFields.map((c) => c.text).join();
    if (code.length < 6) {
      showSnackbar(context, message: l10n.translate('mfaEnterFullCode'), color: AppColors.warning);
      return;
    }
    setState(() => _verifying = true);
    try {
      final valid = await ref.read(mfaServiceProvider).verifyCode(code);
      if (valid && mounted) {
        context.go(RouteNames.dashboard);
      } else if (mounted) {
        showSnackbar(context, message: l10n.translate('mfaInvalidCode'), color: AppColors.danger);
        setState(() => _verifying = false);
      }
    } catch (e) {
      if (mounted) {
        showSnackbar(context, message: '$e', color: AppColors.danger);
        setState(() => _verifying = false);
      }
    }
  }

  Future<void> _verifyBackupCode() async {
    final l10n = AppLocalizations.of(context);
    final code = _backupCodeCtrl.text.trim();
    if (code.isEmpty) {
      showSnackbar(context, message: l10n.translate('mfaEnterBackupCode'), color: AppColors.warning);
      return;
    }
    setState(() => _verifying = true);
    try {
      final valid = await ref.read(mfaServiceProvider).verifyCode(code);
      if (valid && mounted) {
        context.go(RouteNames.dashboard);
      } else if (mounted) {
        showSnackbar(context, message: l10n.translate('mfaBackupCodeInvalid'), color: AppColors.danger);
        setState(() => _verifying = false);
      }
    } catch (e) {
      if (mounted) {
        showSnackbar(context, message: '$e', color: AppColors.danger);
        setState(() => _verifying = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: Text(l10n.translate('mfaTitleVerify'))),
        body: ListView(
          padding: EdgeInsets.all(16),
          children: [
            SizedBox(height: 40),
            Icon(Icons.lock_outline, size: 64, color: AppColors.primary),
            SizedBox(height: 24),
             Text(
              l10n.translate('otpError'),
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 20), fontWeight: FontWeight.w700, color: AppColors.textPrimary),
            ),
            SizedBox(height: 8),
             Text(
              l10n.translate('mfaEnterCodeSubtitle'),
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary),
            ),
             SizedBox(height: 40),

            if (!_useBackupCode) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(6, (i) {
                  return Container(
                    width: 48, height: 56,
                    margin: EdgeInsets.symmetric(horizontal: 4),
                    child: FyonaTextField(
                      controller: _pinFields[i],
                      focusNode: _focusNodes[i],
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      maxLength: 1,
                      style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 22), fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                      decoration: InputDecoration(
                        counterText: '',
                        filled: true, fillColor: AppColors.surfaceVariant,
                        border: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide:  BorderSide(color: AppColors.border)),
                        focusedBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: const BorderSide(color: AppColors.primary, width: 1.5)),
                      ),
                      onChanged: (v) => _onPinChanged(i, v),
                    ),
                  );
                }),
              ),
               SizedBox(height: 32),
              SizedBox(
                width: double.infinity, height: 48,
                child: ElevatedButton(
                  onPressed: _verifying ? null : _verifyPin,
                  style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white),
                  child: Text(_verifying ? '...' : l10n.translate('mfaVerifyBtn'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w600)),
                ),
              ),
               SizedBox(height: 16),
              Center(
                child: TextButton(
                  onPressed: () => setState(() => _useBackupCode = true),
                  child: Text(l10n.translate('mfaUseBackupCode'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.primary)),
                ),
              ),
            ] else ...[
              FyonaTextFormField(
                controller: _backupCodeCtrl,
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), color: AppColors.textPrimary),
                decoration: InputDecoration(
                  labelText: l10n.translate('mfaBackupCodeLabel'),
                  labelStyle: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary),
                  filled: true, fillColor: AppColors.surfaceVariant,
                  border: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.border)),
                  focusedBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
                ),
              ),
               SizedBox(height: 16),
              SizedBox(
                width: double.infinity, height: 48,
                child: ElevatedButton(
                  onPressed: _verifying ? null : _verifyBackupCode,
                  style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white),
                  child: Text(_verifying ? '...' : l10n.translate('mfaVerifyBtn'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: TextButton(
                  onPressed: () => setState(() => _useBackupCode = false),
                  child: Text(l10n.translate('mfaBackToCode'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

