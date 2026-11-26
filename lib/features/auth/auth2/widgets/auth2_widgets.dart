import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../auth2_strings.dart';

/// Always-dark shell of the public sign-in screens (same identity as the
/// login page: dark theme, light status bar, FYONA logo, centered column).
class Auth2Shell extends StatelessWidget {
  const Auth2Shell({
    super.key,
    required this.child,
    this.onBack,
    this.showLogo = true,
    this.topRight,
  });

  final Widget child;
  final VoidCallback? onBack;
  final bool showLogo;
  final Widget? topRight;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Theme(
        data: AppTheme.darkTheme,
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: SafeArea(
            child: Stack(
              children: [
                Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(28, 48, 28, 24),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (showLogo) ...[
                            Center(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(22),
                                child: Image.asset(
                                  'assets/images/fyona_logo_light.png',
                                  width: 84,
                                  height: 84,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => const Text(
                                    'FYONA',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 28,
                                      fontWeight: FontWeight.w900,
                                      color: AppColors.primary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 18),
                          ],
                          child,
                        ],
                      ),
                    ),
                  ),
                ),
                if (onBack != null)
                  PositionedDirectional(
                    top: 4,
                    start: 4,
                    child: IconButton(
                      key: const Key('auth2_back'),
                      icon: Icon(Icons.arrow_back_rounded,
                          color: AppColors.textPrimary),
                      onPressed: onBack,
                    ),
                  ),
                if (topRight != null)
                  PositionedDirectional(top: 8, end: 12, child: topRight!),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class Auth2Title extends StatelessWidget {
  const Auth2Title(this.title, {super.key, this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(
            subtitle!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 13.5,
              height: 1.5,
              fontWeight: FontWeight.w500,
              color: AppColors.textSecondary,
            ),
          ),
        ],
        const SizedBox(height: 22),
      ],
    );
  }
}

class Auth2PrimaryButton extends StatelessWidget {
  const Auth2PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 50,
      child: ElevatedButton(
        onPressed: loading ? null : onPressed,
        child: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              )
            : Text(
                label,
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
      ),
    );
  }
}

class Auth2ErrorBox extends StatelessWidget {
  const Auth2ErrorBox(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('auth2_error'),
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.danger.withAlpha(22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.danger.withAlpha(70), width: 0.6),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: AppColors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppColors.danger,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class Auth2PasswordField extends StatefulWidget {
  const Auth2PasswordField({
    super.key,
    required this.controller,
    required this.hint,
    this.validator,
    this.onChanged,
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
    this.fieldKey,
  });

  final TextEditingController controller;
  final String hint;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;
  final TextInputAction textInputAction;
  final VoidCallback? onSubmitted;
  final Key? fieldKey;

  @override
  State<Auth2PasswordField> createState() => _Auth2PasswordFieldState();
}

class _Auth2PasswordFieldState extends State<Auth2PasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      key: widget.fieldKey,
      controller: widget.controller,
      obscureText: _obscure,
      textInputAction: widget.textInputAction,
      autofillHints: const [AutofillHints.password],
      onChanged: widget.onChanged,
      onFieldSubmitted: (_) => widget.onSubmitted?.call(),
      validator: widget.validator,
      style: TextStyle(
        fontFamily: 'Cairo',
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: AppColors.textPrimary,
      ),
      decoration: InputDecoration(
        hintText: widget.hint,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        prefixIcon: Icon(Icons.lock_outline, size: 21, color: AppColors.textSecondary),
        suffixIcon: IconButton(
          icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility,
              size: 20, color: AppColors.textSecondary),
          onPressed: () => setState(() => _obscure = !_obscure),
        ),
      ),
    );
  }
}

/// 0..4 — length, letters, digits, symbols, mixed case.
int passwordStrength(String p) {
  if (p.isEmpty) return 0;
  var score = 0;
  if (p.length >= 8) score++;
  if (p.length >= 12) score++;
  if (RegExp(r'[A-Za-z؀-ۿ]').hasMatch(p) && RegExp(r'\d').hasMatch(p)) score++;
  if (RegExp(r'[^A-Za-z0-9؀-ۿ]').hasMatch(p)) score++;
  if (p.length < 8) score = score.clamp(0, 1);
  return score.clamp(0, 4);
}

class PasswordStrengthBar extends StatelessWidget {
  const PasswordStrengthBar({super.key, required this.password});
  final String password;

  @override
  Widget build(BuildContext context) {
    final s = passwordStrength(password);
    final colors = [
      AppColors.danger,
      AppColors.danger,
      AppColors.warning,
      const Color(0xFF7CB342),
      AppColors.success,
    ];
    final labels = ['strengthWeak', 'strengthWeak', 'strengthFair', 'strengthGood', 'strengthStrong'];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (var i = 0; i < 4; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                Expanded(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    height: 4,
                    decoration: BoxDecoration(
                      color: password.isNotEmpty && i < (s == 0 ? 1 : s)
                          ? colors[s]
                          : AppColors.surfaceVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            password.isEmpty
                ? a2(context, 'strengthHint')
                : '${a2(context, labels[s])} · ${a2(context, 'strengthHint')}',
            key: const Key('password_strength'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 11,
              color: password.isEmpty ? AppColors.textTertiary : colors[s],
            ),
          ),
        ],
      ),
    );
  }
}
