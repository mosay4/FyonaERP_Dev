import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Presentation-only RTL boundary. It is never exposed to application
// controllers, callbacks, validation, persistence or API payloads.
const _rtlBoundary = '\u200f';

String _digits(String value) {
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  return value.split('').map((c) {
    final a = arabic.indexOf(c);
    if (a >= 0) return '$a';
    final p = persian.indexOf(c);
    if (p >= 0) return '$p';
    return c == '٫' ? '.' : c;
  }).join();
}

TextEditingValue _plain(TextEditingValue value) {
  final text = value.text.replaceAll(_rtlBoundary, '');
  int offset(int at) => at < 0
      ? -1
      : value.text.substring(0, at.clamp(0, value.text.length))
          .replaceAll(_rtlBoundary, '').length;
  return TextEditingValue(
    text: _digits(text),
    selection: TextSelection(
      baseOffset: offset(value.selection.baseOffset),
      extentOffset: offset(value.selection.extentOffset),
      affinity: value.selection.affinity,
      isDirectional: value.selection.isDirectional,
    ),
    composing: value.composing.isValid
        ? TextRange(start: offset(value.composing.start), end: offset(value.composing.end))
        : TextRange.empty,
  );
}

TextEditingValue _display(TextEditingValue value, bool arabic) {
  final raw = _plain(value);
  final append = arabic && raw.text.isNotEmpty;
  int offset(int at) {
    final valid = at < 0 ? raw.text.length : at.clamp(0, raw.text.length);
    return append && valid == raw.text.length ? valid + 1 : valid;
  }
  return TextEditingValue(
    text: raw.text + (append ? _rtlBoundary : ''),
    selection: TextSelection(
      baseOffset: offset(raw.selection.baseOffset),
      extentOffset: offset(raw.selection.extentOffset),
      affinity: raw.selection.affinity,
      isDirectional: raw.selection.isDirectional,
    ),
    composing: raw.composing,
  );
}

/// Runs existing amount/quantity formatters on clean numeric text. The final
/// presentation boundary places the Arabic logical END caret on the visual
/// LEFT without reversing digits or decimals. Backspacing that boundary
/// deletes the preceding digit, rather than deleting/reinserting the mark.
class BusinessNumberFormatter extends TextInputFormatter {
  BusinessNumberFormatter({required this.arabic, this.formatters = const []});
  final bool arabic;
  final List<TextInputFormatter> formatters;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    // Never fight an IME while composing. Commit will normalize the edit.
    if (newValue.composing.isValid && !newValue.composing.isCollapsed) {
      return newValue;
    }
    final oldPlain = _plain(oldValue);
    var next = _plain(newValue);
    final removedBoundary = arabic &&
        oldValue.text.endsWith(_rtlBoundary) &&
        oldValue.selection.isCollapsed &&
        oldValue.selection.end == oldValue.text.length &&
        newValue.text == oldValue.text.substring(0, oldValue.text.length - 1);
    if (removedBoundary && oldPlain.text.isNotEmpty) {
      final text = oldPlain.text.substring(0, oldPlain.text.length - 1);
      next = TextEditingValue(text: text,
          selection: TextSelection.collapsed(offset: text.length));
    }
    for (final formatter in formatters) {
      next = formatter.formatEditUpdate(oldPlain, next);
    }
    return _display(next, arabic);
  }
}

/// Business-only numeric editing bridge. The caller's controller always holds
/// an ordinary numeric string. Caret/composing offsets are mapped explicitly;
/// rebuilds do not force the selection back to the end. Text keyboard fields
/// can use the same helper and retain their original TextField behaviour.
class BusinessNumberField extends StatefulWidget {
  const BusinessNumberField({
    super.key, this.controller, this.focusNode,
    this.keyboardType = const TextInputType.numberWithOptions(decimal: true),
    this.decoration = const InputDecoration(), this.style,
    this.textAlign = TextAlign.start, this.textDirection,
    this.autofocus = false, this.enabled, this.readOnly = false,
    this.onChanged, this.onSubmitted, this.onEditingComplete,
    this.onTap, this.onTapOutside, this.inputFormatters,
    this.maxLines = 1, this.minLines, this.maxLength,
    this.textInputAction, this.cursorColor, this.textAlignVertical,
    this.formField = false, this.initialValue, this.validator, this.onSaved,
    this.autovalidateMode, this.obscureText = false,
  });
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final TextInputType? keyboardType;
  final InputDecoration? decoration;
  final TextStyle? style;
  final TextAlign textAlign;
  final TextDirection? textDirection;
  final bool autofocus, readOnly, formField, obscureText;
  final bool? enabled;
  final ValueChanged<String>? onChanged, onSubmitted;
  final VoidCallback? onEditingComplete, onTap;
  final TapRegionCallback? onTapOutside;
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLines, minLines, maxLength;
  final TextInputAction? textInputAction;
  final Color? cursorColor;
  final TextAlignVertical? textAlignVertical;
  final String? initialValue;
  final FormFieldValidator<String>? validator;
  final FormFieldSetter<String>? onSaved;
  final AutovalidateMode? autovalidateMode;

  @override
  State<BusinessNumberField> createState() => _BusinessNumberFieldState();
}

class _BusinessNumberFieldState extends State<BusinessNumberField> {
  late TextEditingController _public;
  late final TextEditingController _editing;
  late FocusNode _focus;
  bool _syncing = false;
  bool _arabic = false;
  bool get _numeric => widget.keyboardType?.index == TextInputType.number.index;

  @override
  void initState() {
    super.initState();
    _public = widget.controller ?? TextEditingController(text: widget.initialValue);
    _focus = widget.focusNode ?? FocusNode();
    _editing = TextEditingController.fromValue(_public.value);
    _public.addListener(_fromPublic);
    _editing.addListener(_fromEditing);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final rtl = _numeric && Directionality.of(context) == TextDirection.rtl;
    if (_arabic != rtl) {
      _arabic = rtl;
      _fromPublic();
    }
  }

  @override
  void didUpdateWidget(covariant BusinessNumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      final draft = _plain(_editing.value);
      _public.removeListener(_fromPublic);
      if (oldWidget.controller == null) _public.dispose();
      _public = widget.controller ?? TextEditingController(text: widget.initialValue);
      _public.addListener(_fromPublic);
      // Some invoice rows recreate controllers from a parsed model on every
      // keystroke. Preserve an equivalent focused draft ("12." vs "12.0")
      // and its selection instead of destroying decimal input mid-edit.
      final a = double.tryParse(draft.text);
      final b = double.tryParse(_public.text);
      final incomplete = ['', '.', '-', '-.'].contains(draft.text);
      if (_numeric && _focus.hasFocus && (incomplete || (a != null && a == b))) {
        _syncing = true;
        _public.value = draft;
        _syncing = false;
      } else {
        _fromPublic();
      }
    }
    if (widget.focusNode != oldWidget.focusNode) {
      if (oldWidget.focusNode == null) _focus.dispose();
      _focus = widget.focusNode ?? FocusNode();
    }
    if (widget.keyboardType != oldWidget.keyboardType) {
      _arabic = _numeric && Directionality.of(context) == TextDirection.rtl;
      _fromPublic();
    }
  }

  void _fromPublic() {
    if (_syncing || !_numeric) return;
    _syncing = true;
    final next = _plain(_public.value);
    final current = _plain(_editing.value);
    final source = next.text == current.text && !next.selection.isValid
        ? current : next;
    final encoded = _display(source, _arabic);
    if (_editing.value != encoded) _editing.value = encoded;
    _syncing = false;
  }

  void _fromEditing() {
    if (_syncing || !_numeric) return;
    _syncing = true;
    _public.value = _plain(_editing.value);
    _syncing = false;
  }

  void _tap() {
    widget.onTap?.call();
    if (!_numeric || !_arabic || widget.readOnly) return;
    // In a RTL paragraph the left edge of a digit run has two legal bidi
    // carets: offset 0 (before digits) and the logical end after the boundary.
    // Flutter hit-testing can choose offset 0, where Backspace is a no-op.
    // Resolve ONLY that tapped edge to the end; middle/range selections are
    // left untouched, and typing never rewrites the cursor on rebuild.
    Future.microtask(() {
      if (!mounted || !_focus.hasFocus || _editing.text.isEmpty) return;
      final selection = _editing.selection;
      if (selection.isCollapsed && selection.extentOffset == 0) {
        _editing.selection = TextSelection.collapsed(offset: _editing.text.length);
      }
    });
  }

  @override
  void dispose() {
    _public.removeListener(_fromPublic);
    _editing.removeListener(_fromEditing);
    _editing.dispose();
    if (widget.controller == null) _public.dispose();
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _numeric ? _editing : _public;
    final direction = _numeric
        ? (_arabic ? TextDirection.rtl : TextDirection.ltr)
        : widget.textDirection;
    final formatters = _numeric
        ? <TextInputFormatter>[BusinessNumberFormatter(
            arabic: _arabic, formatters: widget.inputFormatters ?? const [])]
        : widget.inputFormatters;
    void changed(String text) => widget.onChanged?.call(
        _numeric ? _plain(controller.value).text : text);
    String clean(String text) => _numeric
        ? _digits(text.replaceAll(_rtlBoundary, '')) : text;
    if (widget.formField) {
      return TextFormField(
        controller: controller, focusNode: _focus,
        keyboardType: widget.keyboardType, decoration: widget.decoration,
        style: widget.style, textAlign: widget.textAlign, textDirection: direction,
        autofocus: widget.autofocus, enabled: widget.enabled,
        readOnly: widget.readOnly, obscureText: widget.obscureText,
        onChanged: changed,
        onFieldSubmitted: (text) => widget.onSubmitted?.call(clean(text)),
        onEditingComplete: widget.onEditingComplete,
        onTap: _tap, onTapOutside: widget.onTapOutside,
        inputFormatters: formatters, maxLines: widget.maxLines,
        minLines: widget.minLines, maxLength: widget.maxLength,
        textInputAction: widget.textInputAction, cursorColor: widget.cursorColor,
        textAlignVertical: widget.textAlignVertical,
        validator: widget.validator == null ? null : (text) => widget.validator!(clean(text ?? '')),
        onSaved: widget.onSaved == null ? null : (text) => widget.onSaved!(clean(text ?? '')),
        autovalidateMode: widget.autovalidateMode,
      );
    }
    return TextField(
      controller: controller, focusNode: _focus,
      keyboardType: widget.keyboardType, decoration: widget.decoration,
      style: widget.style, textAlign: widget.textAlign, textDirection: direction,
      autofocus: widget.autofocus, enabled: widget.enabled,
      readOnly: widget.readOnly, obscureText: widget.obscureText,
      onChanged: changed,
      onSubmitted: (text) => widget.onSubmitted?.call(clean(text)),
      onEditingComplete: widget.onEditingComplete,
      onTap: _tap, onTapOutside: widget.onTapOutside,
      inputFormatters: formatters, maxLines: widget.maxLines,
      minLines: widget.minLines, maxLength: widget.maxLength,
      textInputAction: widget.textInputAction, cursorColor: widget.cursorColor,
      textAlignVertical: widget.textAlignVertical,
    );
  }
}
