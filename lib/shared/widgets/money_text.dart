import 'package:flutter/material.dart';

import '../../core/utils/currency_formatter.dart';

/// One amount with its currency, always shown in FULL.
///
/// * The number keeps the given [style]; the currency name is a quieter,
///   smaller tag beside it (never as loud as the amount).
/// * The pair is one unit inside a [FittedBox] (scaleDown): when space is
///   tight — long Arabic currency names («ريال يمني قديم») or 20+ digit
///   amounts — both shrink together instead of being ellipsized, clipped,
///   wrapped or overlapping their neighbours.
/// * RTL-correct: the number is laid out LTR (sign and grouping stay intact)
///   and the currency follows it in the ambient reading direction, so Arabic
///   reads «13,500 ريال يمني» and English reads «13,500 USD».
class MoneyText extends StatelessWidget {
  /// The already formatted number (e.g. `fmtNum(x)`, may carry a sign).
  final String amount;

  /// The currency label shown beside the number (may be empty).
  final String currency;

  /// Style of the number. The currency derives its style from it.
  final TextStyle? style;

  /// Optional explicit style for the currency label.
  final TextStyle? currencyStyle;

  /// Currency font size relative to the number's.
  final double currencyScale;

  /// Draw the currency as a subtle rounded tag.
  final bool tagged;

  final AlignmentGeometry alignment;

  const MoneyText({
    super.key,
    required this.amount,
    required this.currency,
    this.style,
    this.currencyStyle,
    this.currencyScale = .7,
    this.tagged = false,
    this.alignment = AlignmentDirectional.centerStart,
  });

  /// Formats [value] with [fmtNum] and labels it with the app's localized
  /// currency label for [code] (full Arabic name / ISO code in English).
  factory MoneyText.value(
    num value,
    String code, {
    Key? key,
    TextStyle? style,
    TextStyle? currencyStyle,
    double currencyScale = .7,
    bool tagged = false,
    String prefix = '',
    AlignmentGeometry alignment = AlignmentDirectional.centerStart,
  }) =>
      MoneyText(
        key: key,
        amount: '$prefix${fmtNum(value)}',
        currency: code.trim().isEmpty ? '' : currencySymbol(code),
        style: style,
        currencyStyle: currencyStyle,
        currencyScale: currencyScale,
        tagged: tagged,
        alignment: alignment,
      );

  /// Splits an already combined «number currency» (or «currency number»)
  /// string so legacy call sites that pass one string still get the small
  /// currency tag and the no-ellipsis behaviour.
  factory MoneyText.parse(
    String text, {
    Key? key,
    TextStyle? style,
    TextStyle? currencyStyle,
    double currencyScale = .7,
    bool tagged = false,
    AlignmentGeometry alignment = AlignmentDirectional.centerStart,
  }) {
    final (n, cur) = splitMoney(text);
    return MoneyText(
      key: key,
      amount: n,
      currency: cur,
      style: style,
      currencyStyle: currencyStyle,
      currencyScale: currencyScale,
      tagged: tagged,
      alignment: alignment,
    );
  }

  static final RegExp _lead = RegExp(r'^\s*([+\-−]?\s*[\d٠-٩][\d٠-٩,٬.\s]*%?)(.*)$');
  static final RegExp _trail = RegExp(r'^(.*?)([+\-−]?\s*[\d٠-٩][\d٠-٩,٬.]*%?)\s*$');

  /// (number, currency) of a combined money string. When no number is found
  /// the whole text is returned as the "number" with an empty currency.
  static (String, String) splitMoney(String text) {
    final t = text.trim();
    final lead = _lead.firstMatch(t);
    if (lead != null) {
      return (lead.group(1)!.trim(), lead.group(2)!.trim());
    }
    final trail = _trail.firstMatch(t);
    if (trail != null) {
      return (trail.group(2)!.trim(), trail.group(1)!.trim());
    }
    return (t, '');
  }

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style.merge(style);
    final fs = base.fontSize ?? 14;
    final curFs = (fs * currencyScale).clamp(8.0, 14.0).toDouble();
    final curStyle = base
        .copyWith(
          fontSize: curFs < fs ? curFs : fs * .8,
          fontWeight: FontWeight.w600,
          color: (base.color ?? Theme.of(context).colorScheme.onSurface)
              .withAlpha(200),
          height: 1.2,
          letterSpacing: 0,
        )
        .merge(currencyStyle);
    final hasCur = currency.trim().isNotEmpty;
    Widget cur = Text(
      currency.trim(),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.visible,
      style: curStyle,
    );
    if (tagged) {
      cur = Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: (base.color ?? Theme.of(context).colorScheme.primary)
              .withAlpha(12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: cur,
      );
    }
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: alignment,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            amount,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
            textDirection: TextDirection.ltr,
            style: base,
          ),
          if (hasCur) ...[
            SizedBox(width: fs * .25 < 3 ? 3 : fs * .25),
            cur,
          ],
        ],
      ),
    );
  }
}
