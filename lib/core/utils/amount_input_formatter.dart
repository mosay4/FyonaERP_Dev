import 'package:flutter/services.dart';
import '../services/currency/money_format_service.dart';

/// Formats numeric input while typing with a thousands separator
/// (1,000,000.50) and up to two decimal places, honouring the app-wide
/// [currentMoneyFormat] preferences (whether the thousands separator and the
/// decimal places are shown).
///
/// When `useThousandsSeparator` is disabled the value is still normalised but
/// no grouping separators are inserted. The underlying value stays parseable
/// by `double.parse` (after removing the separators), so form code can keep
/// reading plain numbers from the field.
class AmountInputFormatter extends TextInputFormatter {
  AmountInputFormatter({this.maxIntDigits = 12});

  /// Maximum number of integer digits allowed.
  final int maxIntDigits;

  static final _validInput = RegExp(r'^\d*\.?\d*$');

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final useSep = currentMoneyFormat.useThousandsSeparator;
    final sep = ',';
    final dot = '.';

    final ungrouped = newValue.text.replaceAll(sep, '');
    if (ungrouped.isEmpty) {
      return const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
    }
    // Strip any accidental non-digit separators but keep the decimal point.
    if (!_validInput.hasMatch(ungrouped)) return oldValue;

    final dotIndex = ungrouped.indexOf(dot);
    final hasDot = dotIndex >= 0;
    final intPart = hasDot ? ungrouped.substring(0, dotIndex) : ungrouped;
    final decPart = hasDot ? ungrouped.substring(dotIndex + 1) : '';
    if (decPart.length > 2) return oldValue;
    if (intPart.length > maxIntDigits) return oldValue;

    final groupedInt = useSep ? _groupDigits(intPart, sep) : intPart;
    final formatted = hasDot ? '$groupedInt$dot$decPart' : groupedInt;

    final selection = newValue.selection;
    if (selection.isValid && selection.isCollapsed) {
      final caretOffset = selection.baseOffset;
      if (caretOffset >= 0) {
        final beforeCursor = newValue.text.substring(0, caretOffset).replaceAll(sep, '');
        final mapped = _mapCursor(formatted, beforeCursor.length, sep);
        return TextEditingValue(text: formatted, selection: TextSelection.collapsed(offset: mapped));
      }
    }
    // Non-collapsed selection or unknown cursor: place caret at the end.
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }

  static String _groupDigits(String digits, String sep) {
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(sep);
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }

  /// Finds the position in [formatted] that corresponds to having consumed
  /// [count] digits/dot characters of the ungrouped value.
  static int _mapCursor(String formatted, int count, String sep) {
    if (count <= 0) return 0;
    var seen = 0;
    for (var i = 0; i < formatted.length; i++) {
      final ch = formatted[i];
      if (ch == sep) continue;
      seen++;
      if (seen == count) return i + 1;
    }
    return formatted.length;
  }
}
