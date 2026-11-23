import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class PasswordField extends StatefulWidget {
  final String label;
  final TextEditingController? controller;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;
  final TextInputAction textInputAction;
  final bool enabled;
  final String? errorText;
  final bool showStrengthIndicator;

  PasswordField({
    super.key,
    required this.label,
    this.controller,
    this.validator,
    this.onChanged,
    this.textInputAction = TextInputAction.next,
    this.enabled = true,
    this.errorText,
    this.showStrengthIndicator = false,
  });

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _obscured = true;
  double _strength = 0;

  void _calculateStrength(String value) {
    double score = 0;
    if (value.length >= 8) score += 0.25;
    if (value.contains(RegExp(r'[A-Z]'))) score += 0.2;
    if (value.contains(RegExp(r'[a-z]'))) score += 0.2;
    if (value.contains(RegExp(r'[0-9]'))) score += 0.2;
    if (value.contains(RegExp(r'[!@#\$%^&*()_+=\-\[\]{};:.,<>/?]'))) score += 0.15;
    setState(() => _strength = score);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.label,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 13),
            fontWeight: FontWeight.w500,
            color: AppColors.textSecondary,
          ),
        ),
         SizedBox(height: 6),
        FyonaTextFormField(
          controller: widget.controller,
          validator: widget.validator,
          onChanged: (value) {
            widget.onChanged?.call(value);
            if (widget.showStrengthIndicator) {
              _calculateStrength(value);
            }
          },
          textInputAction: widget.textInputAction,
          obscureText: _obscured,
          enabled: widget.enabled,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 15),
            color: AppColors.textPrimary,
          ),
          decoration: InputDecoration(
            hintText: '********',
            prefixIcon:  Icon(
              Icons.lock,
              color: AppColors.textSecondary,
              size: 20,
            ),
            suffixIcon: IconButton(
              icon: Icon(
                _obscured ? Icons.visibility : Icons.visibility_off,
                color: AppColors.textSecondary,
                size: 20,
              ),
              onPressed: () => setState(() => _obscured = !_obscured),
            ),
            errorText: widget.errorText,
            filled: true,
            fillColor: AppColors.surfaceVariant,
            border: OutlineInputBorder(
              borderRadius: AppRadius.inputBorder,
              borderSide: BorderSide(
                color: widget.errorText != null ? AppColors.danger : AppColors.border,
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: AppRadius.inputBorder,
              borderSide: BorderSide(
                color: widget.errorText != null ? AppColors.danger : AppColors.border,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: AppRadius.inputBorder,
              borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: AppRadius.inputBorder,
              borderSide: const BorderSide(color: AppColors.danger),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: AppRadius.inputBorder,
              borderSide: const BorderSide(color: AppColors.danger, width: 1.5),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
          ),
        ),
        if (widget.showStrengthIndicator && _strength > 0) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _strength,
              minHeight: 4,
              backgroundColor: AppColors.surfaceVariant,
              color: _strength < 0.4
                  ? AppColors.danger
                  : _strength < 0.7
                      ? AppColors.warning
                      : AppColors.success,
            ),
          ),
        ],
      ],
    );
  }
}

