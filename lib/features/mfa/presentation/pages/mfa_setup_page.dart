import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import '../../../../shared/widgets/business_widgets.dart';
import '../../data/models/mfa_models.dart';
import '../providers/mfa_providers.dart';
import '../../di/mfa_providers.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class MfaSetupPage extends ConsumerStatefulWidget {
  MfaSetupPage({super.key});
  @override
  ConsumerState<MfaSetupPage> createState() => _MfaSetupPageState();
}

class _MfaSetupPageState extends ConsumerState<MfaSetupPage> {
  final _verifyCodeCtrl = TextEditingController();
  bool _showCodes = false;
  bool _verifying = false;

  @override
  void dispose() {
    _verifyCodeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final statusAsync = ref.watch(mfaStatusProvider);

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: Text(l10n.translate('mfaEnableTitle'))),
        body: statusAsync.when(
          loading: () => LoadingShimmer(itemCount: 2),
          error: (e, _) => EmptyStateWidget(
            title: l10n.translate('errorOccurred'),
            subtitle: e.toString(),
            icon: Icons.error_outline,
          ),
          data: (status) => ListView(
            padding: EdgeInsets.all(16),
            children: [
              Icon(Icons.security, size: 64, color: AppColors.primary),
              SizedBox(height: 16),
               Text(
                l10n.translate('mfaTitleMfa'),
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 20), fontWeight: FontWeight.w700, color: AppColors.textPrimary),
              ),
              SizedBox(height: 8),
               Text(
                l10n.translate('mfaEnableSubtitle'),
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary),
              ),
              const SizedBox(height: 32),

              if (status.enabled) ...[
                _buildEnabledState(status),
              ] else ...[
                _buildDisabledState(status),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDisabledState(MfaStatusModel status) {
    final l10n = AppLocalizations.of(context);
    return Column(children: [
      if (status.qrCodeUrl != null) ...[
        Container(
          width: 200, height: 200,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Center(
            child: QrImageView(
              data: status.qrCodeUrl!,
              version: QrVersions.auto,
              size: 180,
            ),
          ),
        ),
         SizedBox(height: 24),
      ],

      if (status.secretKey != null) ...[
        Container(
          padding: EdgeInsets.all(16),
          decoration: BoxDecoration(color: AppColors.surface, borderRadius: AppRadius.mdBorder, border: Border.all(color: AppColors.border)),
          child: Column(children: [
            Text(l10n.translate('mfaSecretKey'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary)),
             SizedBox(height: 8),
            Text(status.secretKey!,
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          ]),
        ),
         SizedBox(height: 16),
        FyonaTextFormField(
          controller: _verifyCodeCtrl,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          maxLength: 6,
          style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 20), fontWeight: FontWeight.w700, color: AppColors.textPrimary),
          decoration: InputDecoration(
            counterText: '',
            labelText: l10n.translate('otpTitle'),
            labelStyle: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary),
            filled: true, fillColor: AppColors.surfaceVariant,
            border: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.border)),
            focusedBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
          ),
        ),
         SizedBox(height: 16),
      ],

      SizedBox(
        width: double.infinity, height: 48,
        child: ElevatedButton(
          onPressed: _verifying ? null : _enableMfa,
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white),
          child: Text(_verifying ? '...' : l10n.translate('mfaEnableTitle'),
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w600)),
        ),
      ),
      SizedBox(height: 24),

      if (_showCodes) ...[
        Consumer(
          builder: (context, ref, _) {
            final codesAsync = ref.watch(mfaBackupCodesProvider);
            return codesAsync.when(
              loading: () => SizedBox(height: 100, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
              error: (e, _) => SizedBox.shrink(),
              data: (codes) => Container(
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.warning.withAlpha(15),
                  borderRadius: AppRadius.mdBorder,
                  border: Border.all(color: AppColors.warning.withAlpha(60)),
                ),
                child: Column(children: [
                   Row(children: [
                    Icon(Icons.warning, color: AppColors.warning, size: 20),
                    SizedBox(width: 8),
                    Expanded(child: Text(l10n.translate('mfaSaveBackupWarning'),
                        style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.warning))),
                  ]),
                  SizedBox(height: 16),
                  ...codes.map((code) => Padding(
                    padding: EdgeInsets.symmetric(vertical: 2),
                    child: Row(children: [
                      Icon(Icons.fiber_manual_record, size: 8, color: AppColors.warning),
                       SizedBox(width: 8),
                      Text(code, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w500, color: AppColors.textPrimary)),
                      const Spacer(),
                      GestureDetector(
                        onTap: () {
                          // copy to clipboard would go here
                          showSnackbar(context, message: l10n.translate('mfaCodeCopied'));
                        },
                        child:  Icon(Icons.copy, size: 16, color: AppColors.textSecondary),
                      ),
                    ]),
                  )),
                ]),
              ),
            );
          },
        ),
      ],
    ]);
  }

  Widget _buildEnabledState(MfaStatusModel status) {
    final l10n = AppLocalizations.of(context);
    return Column(children: [
      Container(
        width: 80, height: 80,
        decoration: BoxDecoration(
          color: AppColors.success.withAlpha(25),
          borderRadius: BorderRadius.circular(40),
        ),
        child: Icon(Icons.check_circle, size: 48, color: AppColors.success),
      ),
       SizedBox(height: 16),
       Text(l10n.translate('mfaEnabledTitle'),
          style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 18), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
      SizedBox(height: 8),
       Text(l10n.translate('mfaEnabledSubtitle'),
          textAlign: TextAlign.center,
          style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary)),
       SizedBox(height: 32),
      SizedBox(
        width: double.infinity, height: 48,
        child: OutlinedButton(
          onPressed: _showCodes ? null : () => setState(() => _showCodes = true),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.primary,
            side: BorderSide(color: AppColors.primary),
            shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder),
          ),
          child: Text(l10n.translate('mfaShowBackupCodes'),
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14))),
        ),
      ),
      if (_showCodes) ...[
        SizedBox(height: 12),
        Consumer(
          builder: (context, ref, _) {
            final codesAsync = ref.watch(mfaBackupCodesProvider);
            return codesAsync.when(
              loading: () => SizedBox(height: 100, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
              error: (e, _) => SizedBox.shrink(),
              data: (codes) => Container(
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface, borderRadius: AppRadius.mdBorder, border: Border.all(color: AppColors.border)),
                child: Column(children: codes.map((code) => Padding(
                  padding: EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Icon(Icons.fiber_manual_record, size: 8, color: AppColors.textSecondary),
                     SizedBox(width: 8),
                    Text(code, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w500, color: AppColors.textPrimary)),
                  ]),
                )).toList()),
              ),
            );
          },
        ),
      ],
       SizedBox(height: 24),
      SizedBox(
        width: double.infinity, height: 48,
        child: ElevatedButton(
          onPressed: () => _disableMfa(),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.danger,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder),
          ),
          child: Text(l10n.translate('mfaDisableBtn'),
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14))),
        ),
      ),
    ]);
  }

  Future<void> _enableMfa() async {
    final l10n = AppLocalizations.of(context);
    final code = _verifyCodeCtrl.text.trim();
    if (code.isEmpty) {
      showSnackbar(context, message: l10n.translate('mfaEnterCodePrompt'), color: AppColors.warning);
      return;
    }
    setState(() => _verifying = true);
    try {
      final isValid = await ref.read(mfaServiceProvider).verifyCode(code);
      if (isValid && mounted) {
        final service = ref.read(mfaServiceProvider);
        await service.enableMfa();
        if (mounted) {
          setState(() {
            _showCodes = true;
            _verifying = false;
          });
          ref.invalidate(mfaStatusProvider);
          showSnackbar(context, message: l10n.translate('mfaEnabledSuccess'));
        }
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

  Future<void> _disableMfa() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showConfirmDialog(context,
      title: l10n.translate('mfaDisableTitle'),
      message: l10n.translate('mfaDisableMessage'),
      danger: true,
    );
    if (confirmed == true && mounted) {
      try {
        await ref.read(mfaServiceProvider).disableMfa();
        ref.invalidate(mfaStatusProvider);
        setState(() => _showCodes = false);
        showSnackbar(context, message: l10n.translate('mfaDisabledSuccess'));
      } catch (e) {
        showSnackbar(context, message: '$e', color: AppColors.danger);
      }
    }
  }
}

