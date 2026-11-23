import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

mixin _FyonaSelectionBehavior<T extends StatefulWidget> on State<T> {
  TextEditingController get _controller;
  FocusNode get _focusNode;
  TextDirection? get _explicitDirection;
  bool _rtl = false;
  bool _syncing = false;

  void _initSelectionBehavior(TextEditingController controller,
      FocusNode focus) {
    _rtl = (widget as dynamic).textDirection == TextDirection.rtl;
    _controller.addListener(_normalizeSelection);
    focus.addListener(_normalizeSelection);
  }

  void _updateDirection() {
    final next = (_explicitDirection ?? Directionality.of(context)) ==
        TextDirection.rtl;
    if (_rtl != next) {
      _rtl = next;
      _normalizeSelection();
    }
  }

  void _normalizeSelection() {
    if (_syncing || !mounted) return;
    final value = _controller.value;
    if (!_rtl || value.text.isEmpty) return;
    final selection = value.selection;
    if (!selection.isCollapsed) return;
    if (selection.baseOffset != value.text.length) return;
    if (selection.affinity == TextAffinity.downstream) return;
    _syncing = true;
    _controller.selection = TextSelection.collapsed(
        offset: value.text.length, affinity: TextAffinity.downstream);
    _syncing = false;
  }

  void _handleTap() {
    if (!_rtl) return;
    Future.microtask(() {
      if (!mounted || !_focusNode.hasFocus || _controller.text.isEmpty) return;
      final selection = _controller.selection;
      if (selection.isCollapsed && selection.extentOffset == 0) {
        _syncing = true;
        _controller.selection = TextSelection.collapsed(
            offset: _controller.text.length,
            affinity: TextAffinity.downstream);
        _syncing = false;
      }
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_normalizeSelection);
    _focusNode.removeListener(_normalizeSelection);
    super.dispose();
  }
}

class FyonaTextField extends StatefulWidget {
  const FyonaTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.keyboardType,
    this.textInputAction,
    this.style,
    this.decoration = const InputDecoration(),
    this.textAlign = TextAlign.start,
    this.textDirection,
    this.textAlignVertical,
    this.autofocus = false,
    this.enabled,
    this.readOnly = false,
    this.obscureText = false,
    this.showCursor,
    this.enableInteractiveSelection,
    this.maxLines = 1,
    this.minLines,
    this.maxLength,
    this.cursorColor,
    this.autofillHints,
    this.inputFormatters,
    this.onChanged,
    this.onSubmitted,
    this.onEditingComplete,
    this.onTap,
    this.onTapOutside,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextStyle? style;
  final InputDecoration decoration;
  final TextAlign textAlign;
  final TextDirection? textDirection;
  final TextAlignVertical? textAlignVertical;
  final bool autofocus;
  final bool? enabled;
  final bool readOnly;
  final bool obscureText;
  final bool? showCursor;
  final bool? enableInteractiveSelection;
  final int? maxLines;
  final int? minLines;
  final int? maxLength;
  final Color? cursorColor;
  final Iterable<String>? autofillHints;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onEditingComplete;
  final GestureTapCallback? onTap;
  final TapRegionCallback? onTapOutside;

  @override
  State<FyonaTextField> createState() => _FyonaTextFieldState();
}

class _FyonaTextFieldState extends State<FyonaTextField>
    with _FyonaSelectionBehavior<FyonaTextField> {
  late TextEditingController _public;
  late FocusNode _focus;
  bool _ownsController = false;
  bool _ownsFocus = false;

  @override
  TextEditingController get _controller => _public;
  @override
  FocusNode get _focusNode => _focus;
  @override
  TextDirection? get _explicitDirection => widget.textDirection;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _ownsFocus = widget.focusNode == null;
    _public = widget.controller ?? TextEditingController();
    _focus = widget.focusNode ?? FocusNode();
    if (_public.text.isNotEmpty && !_public.selection.isValid) {
      _public.selection = TextSelection.collapsed(
          offset: _public.text.length, affinity: TextAffinity.downstream);
    }
    _initSelectionBehavior(_public, _focus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateDirection();
  }

  @override
  void didUpdateWidget(covariant FyonaTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      _public.removeListener(_normalizeSelection);
      _focusNode.removeListener(_normalizeSelection);
      if (_ownsController) _public.dispose();
      _ownsController = widget.controller == null;
      _public = widget.controller ?? TextEditingController();
      _public.addListener(_normalizeSelection);
      _focusNode.addListener(_normalizeSelection);
      _normalizeSelection();
    }
    if (widget.focusNode != oldWidget.focusNode) {
      _focusNode.removeListener(_normalizeSelection);
      if (_ownsFocus) _focus.dispose();
      _ownsFocus = widget.focusNode == null;
      _focus = widget.focusNode ?? FocusNode();
      _focusNode.addListener(_normalizeSelection);
      _normalizeSelection();
    }
  }

  @override
  void dispose() {
    super.dispose();
    if (_ownsController) _public.dispose();
    if (_ownsFocus) _focus.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _public,
      focusNode: _focus,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      style: widget.style,
      decoration: widget.decoration,
      textAlign: widget.textAlign,
      textDirection: widget.textDirection ??
          (_rtl ? TextDirection.rtl : TextDirection.ltr),
      textAlignVertical: widget.textAlignVertical,
      autofocus: widget.autofocus,
      enabled: widget.enabled,
      readOnly: widget.readOnly,
      obscureText: widget.obscureText,
      showCursor: widget.showCursor,
      enableInteractiveSelection: widget.enableInteractiveSelection,
      maxLines: widget.maxLines,
      minLines: widget.minLines,
      maxLength: widget.maxLength,
      cursorColor: widget.cursorColor,
      autofillHints: widget.autofillHints,
      inputFormatters: widget.inputFormatters,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      onEditingComplete: widget.onEditingComplete,
      onTap: () {
        widget.onTap?.call();
        _handleTap();
      },
      onTapOutside: widget.onTapOutside,
    );
  }
}

class FyonaTextFormField extends StatefulWidget {
  const FyonaTextFormField({
    super.key,
    this.controller,
    this.focusNode,
    this.initialValue,
    this.keyboardType,
    this.textInputAction,
    this.style,
    this.decoration = const InputDecoration(),
    this.textAlign = TextAlign.start,
    this.textDirection,
    this.textAlignVertical,
    this.autofocus = false,
    this.enabled,
    this.readOnly = false,
    this.obscureText = false,
    this.maxLines = 1,
    this.minLines,
    this.maxLength,
    this.cursorColor,
    this.inputFormatters,
    this.onChanged,
    this.onFieldSubmitted,
    this.onEditingComplete,
    this.onTap,
    this.onTapOutside,
    this.validator,
    this.onSaved,
    this.autovalidateMode,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? initialValue;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextStyle? style;
  final InputDecoration decoration;
  final TextAlign textAlign;
  final TextDirection? textDirection;
  final TextAlignVertical? textAlignVertical;
  final bool autofocus;
  final bool? enabled;
  final bool readOnly;
  final bool obscureText;
  final int? maxLines;
  final int? minLines;
  final int? maxLength;
  final Color? cursorColor;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onFieldSubmitted;
  final VoidCallback? onEditingComplete;
  final GestureTapCallback? onTap;
  final TapRegionCallback? onTapOutside;
  final FormFieldValidator<String>? validator;
  final FormFieldSetter<String>? onSaved;
  final AutovalidateMode? autovalidateMode;

  @override
  State<FyonaTextFormField> createState() => _FyonaTextFormFieldState();
}

class _FyonaTextFormFieldState extends State<FyonaTextFormField>
    with _FyonaSelectionBehavior<FyonaTextFormField> {
  late TextEditingController _public;
  late FocusNode _focus;
  bool _ownsController = false;
  bool _ownsFocus = false;

  @override
  TextEditingController get _controller => _public;
  @override
  FocusNode get _focusNode => _focus;
  @override
  TextDirection? get _explicitDirection => widget.textDirection;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _ownsFocus = widget.focusNode == null;
    _public = widget.controller ??
        TextEditingController(text: widget.initialValue ?? '');
    _focus = widget.focusNode ?? FocusNode();
    if (_public.text.isNotEmpty && !_public.selection.isValid) {
      _public.selection = TextSelection.collapsed(
          offset: _public.text.length, affinity: TextAffinity.downstream);
    }
    _initSelectionBehavior(_public, _focus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateDirection();
  }

  @override
  void didUpdateWidget(covariant FyonaTextFormField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      _public.removeListener(_normalizeSelection);
      _focusNode.removeListener(_normalizeSelection);
      if (_ownsController) _public.dispose();
      _ownsController = widget.controller == null;
      _public = widget.controller ??
          TextEditingController(text: widget.initialValue ?? '');
      _public.addListener(_normalizeSelection);
      _focusNode.addListener(_normalizeSelection);
      _normalizeSelection();
    }
    if (widget.focusNode != oldWidget.focusNode) {
      _focusNode.removeListener(_normalizeSelection);
      if (_ownsFocus) _focus.dispose();
      _ownsFocus = widget.focusNode == null;
      _focus = widget.focusNode ?? FocusNode();
      _focusNode.addListener(_normalizeSelection);
      _normalizeSelection();
    }
  }

  @override
  void dispose() {
    super.dispose();
    if (_ownsController) _public.dispose();
    if (_ownsFocus) _focus.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: _public,
      focusNode: _focus,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      style: widget.style,
      decoration: widget.decoration,
      textAlign: widget.textAlign,
      textDirection: widget.textDirection ??
          (_rtl ? TextDirection.rtl : TextDirection.ltr),
      textAlignVertical: widget.textAlignVertical,
      autofocus: widget.autofocus,
      enabled: widget.enabled,
      readOnly: widget.readOnly,
      obscureText: widget.obscureText,
      maxLines: widget.maxLines,
      minLines: widget.minLines,
      maxLength: widget.maxLength,
      cursorColor: widget.cursorColor,
      inputFormatters: widget.inputFormatters,
      onChanged: widget.onChanged,
      onFieldSubmitted: widget.onFieldSubmitted,
      onEditingComplete: widget.onEditingComplete,
      onTap: () {
        widget.onTap?.call();
        _handleTap();
      },
      onTapOutside: widget.onTapOutside,
      validator: widget.validator,
      onSaved: widget.onSaved,
      autovalidateMode: widget.autovalidateMode,
    );
  }
}
