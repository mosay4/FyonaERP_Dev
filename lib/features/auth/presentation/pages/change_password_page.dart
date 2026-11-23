import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/responsive/breakpoints.dart';
import '../../../../core/router/route_names.dart';
import '../providers/auth_provider.dart';
import '../widgets/password_field.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../core/localization/app_localizations.dart';

class ChangePasswordPage extends ConsumerStatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  ConsumerState<ChangePasswordPage> createState() =>
      _ChangePasswordPageState();
}

class _ChangePasswordPageState extends ConsumerState<ChangePasswordPage> {
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  String? _error;
  bool _success = false;

  @override
  void dispose() {
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async {
    setState(() => _error = null);

    final result = await ref.read(authProvider.notifier).changePassword(
          currentPassword: _currentPasswordController.text,
          newPassword: _newPasswordController.text,
          confirmNewPassword: _confirmPasswordController.text,
        );

    if (result != null) {
      setState(() => _error = result);
    } else {
      setState(() => _success = true);
      _currentPasswordController.clear();
      _newPasswordController.clear();
      _confirmPasswordController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isPhone = Breakpoints.isPhone(width);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.translate('changePasswordTitle')),
        leading: IconButton(
          icon: TwoToneIcon(data: TwoToneIcons.arrowRight),
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: isPhone ? 24 : 40,
              vertical: 24,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    _success ? Icons.check_circle : Icons.lock,
                    size: 64,
                    color: _success ? AppColors.success : AppColors.primary,
                  ),
                  SizedBox(height: 24),
Text(
                    _success ? l10n.translate('changePasswordSuccess') : l10n.translate('changePasswordTitle'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: isPhone ? 22 : 26,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
),
                  SizedBox(height: isPhone ? AppSpacing.xl : AppSpacing.xxl),

                  if (!_success) ...[
                    if (_error != null) ...[
                      Container(
                        padding: EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.danger.withAlpha(25),
                          borderRadius: AppRadius.mdBorder,
                          border: Border.all(
                              color: AppColors.danger.withAlpha(80)),
                        ),
                        child: Row(
                          children: [
                            TwoToneIcon(data: TwoToneIcons.warning, size: 20, outlineColor: AppColors.danger),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(_error!,
                                  style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: R.fontSize(context, 13),
                                      color: AppColors.danger)),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: 16),
                    ],

                    PasswordField(
                      label: l10n.translate('currentPasswordLabel'),
                      controller: _currentPasswordController,
                      textInputAction: TextInputAction.next,
                    ),
                    SizedBox(height: 14),

                    PasswordField(
                      label: l10n.translate('newPasswordLabel'),
                      controller: _newPasswordController,
                      showStrengthIndicator: true,
                    ),
                    SizedBox(height: 14),

                    PasswordField(
                      label: l10n.translate('confirmNewPasswordLabel'),
                      controller: _confirmPasswordController,
                      textInputAction: TextInputAction.done,
                    ),
                     SizedBox(height: 24),

                    SizedBox(
                      height: isPhone ? 48 : 52,
                      child: ElevatedButton(
                        onPressed: _onSubmit,
                        child: Text(l10n.translate('changePasswordBtn'),
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: R.fontSize(context, 16),
                                fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ] else ...[
                     SizedBox(height: 16),
                    SizedBox(
                      height: isPhone ? 48 : 52,
                      child: ElevatedButton(
          onPressed: () => context.pop(),
                        child: Text(l10n.translate('backBtn'),
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: R.fontSize(context, 16),
                                fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

