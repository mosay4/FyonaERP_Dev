import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../core/theme/app_colors.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Five-digit app-PIN entry: five independent digit boxes, each rendering its
/// own state (caret, filled dot, focus ring). A single numeric field still
/// drives them so keyboard, delete and paste behave natively, but it is laid
/// out *behind* the boxes so no system overlay (autofill popup, selection
/// toolbar) can ever be painted on top of them.
class AppPinPad extends StatefulWidget {
  final ValueChanged<String> onCompleted;
  final bool enabled;
  final bool autofocus;

  const AppPinPad({
    super.key,
    required this.onCompleted,
    this.enabled = true,
    this.autofocus = true,
  });

  @override
  State<AppPinPad> createState() => AppPinPadState();
}

class AppPinPadState extends State<AppPinPad> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onChanged);
    _focus.addListener(_onFocusChanged);
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.enabled && !_focus.hasFocus) {
          _focus.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onChanged);
    _focus.removeListener(_onFocusChanged);
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    setState(() => _focused = _focus.hasFocus);
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    if (widget.enabled && _ctrl.text.length >= 5) {
      final pin = _ctrl.text.substring(0, 5);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onCompleted(pin);
      });
    }
  }

  void clear() {
    _ctrl.clear();
    if (mounted) setState(() {});
    if (widget.enabled) _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final text = _ctrl.text;
    final caretIndex = _focused && text.length < 5 ? text.length : -1;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (widget.enabled) _focus.requestFocus();
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: FyonaTextField(
              controller: _ctrl,
              focusNode: _focus,
              enabled: widget.enabled,
              autofocus: false,
              keyboardType: TextInputType.number,
              autofillHints: const <String>[],
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(5),
              ],
              showCursor: false,
              enableInteractiveSelection: false,
              style: const TextStyle(color: Colors.transparent, fontSize: 1),
              cursorColor: Colors.transparent,
              decoration: const InputDecoration(
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                counterText: '',
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            textDirection: TextDirection.ltr,
            children: List.generate(5, (i) {
              final filled = i < text.length;
              final active = i == caretIndex;
              return Container(
                width: 50,
                height: 60,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: active
                      ? AppColors.primary.withAlpha(16)
                      : AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: filled || active
                        ? AppColors.primary
                        : AppColors.border,
                    width: filled || active ? 2 : 1,
                  ),
                  boxShadow: active
                      ? [
                          BoxShadow(
                            color: AppColors.primary.withAlpha(60),
                            blurRadius: 10,
                            spreadRadius: 1,
                          )
                        ]
                      : null,
                ),
                alignment: Alignment.center,
                child: filled
                    ? Container(
                        width: 14,
                        height: 14,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.primary,
                        ),
                      )
                    : active
                        ? Container(
                            width: 2,
                            height: 26,
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          )
                        : null,
              );
            }),
          ),
        ],
      ),
    );
  }
}
