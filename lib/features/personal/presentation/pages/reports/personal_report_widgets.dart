import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../../core/localization/app_localizations.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/utils/currency_formatter.dart';
import '../../../../reports/presentation/widgets/report_widgets.dart';
import 'personal_report_data.dart';

/// Calm accents for category shares: brand crimson first, then neutrals that
/// read in both themes (the same family as the report PDF tones).
const personalReportTones = <Color>[
  AppColors.primary,
  Color(0xFFD9822B),
  Color(0xFF3F7CAC),
  Color(0xFF2E9E6B),
  Color(0xFF8E5BA8),
  Color(0xFF6B7785),
  Color(0xFFB0636F),
];

/// PDF tone names in the same order as [personalReportTones].
const personalReportPdfTones = [
  'brand',
  'amber',
  'info',
  'in',
  'plum',
  'slate',
  'out',
];

const personalIncomeColor = Color(0xFF2E9E6B);
const personalSpendColor = AppColors.primary;

String prMoney(double v, String currency) =>
    '${fmtNum(v)} ${currencyShort(currency)}';

String prPercent(double fraction) {
  final p = fraction * 100;
  final r = p.abs() >= 10 || p == p.roundToDouble()
      ? p.round().toString()
      : p.toStringAsFixed(1);
  return '$r%';
}

// ───────────────────────────────────────────────────────── currency picker

/// Report currency sheet: ONE clean list of exactly the currencies the user
/// enabled for Personal (Profile › preferences), with flags — no section
/// headers, nothing added, nothing dropped. Search appears only for long sets.
Future<String?> showPersonalReportCurrencyPicker(
  BuildContext context, {
  required List<String> currencies,
  required String current,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _CurrencySheet(currencies: currencies, current: current),
  );
}

class _CurrencySheet extends StatefulWidget {
  const _CurrencySheet({required this.currencies, required this.current});
  final List<String> currencies;
  final String current;

  /// Above this many currencies the sheet shows a search field.
  static const searchThreshold = 8;
  @override
  State<_CurrencySheet> createState() => _CurrencySheetState();
}

class _CurrencySheetState extends State<_CurrencySheet> {
  String _q = '';

  bool _match(String code, String lang) {
    if (_q.isEmpty) return true;
    final q = _q.toLowerCase();
    return code.toLowerCase().contains(q) ||
        currencyName(code, locale: lang).toLowerCase().contains(q) ||
        currencyName(
          code,
          locale: lang == 'ar' ? 'en' : 'ar',
        ).toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final lang = l10n.locale.languageCode;
    final seen = <String>{};
    final codes = [
      for (final c in widget.currencies)
        if (seen.add(c.trim().toUpperCase())) c.trim().toUpperCase(),
    ];
    final searchable = codes.length > _CurrencySheet.searchThreshold;
    final shown = searchable
        ? codes.where((c) => _match(c, lang)).toList()
        : codes;
    Widget tile(String c) {
      final selected = c == widget.current;
      final flag = currencyFlagEmoji(c);
      return ListTile(
        dense: true,
        leading: SizedBox(
          width: 30,
          child: Center(
            child: Text(
              flag.isEmpty ? '¤' : flag,
              style: const TextStyle(fontSize: 20),
            ),
          ),
        ),
        title: Text(
          currencyName(c, locale: lang),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 13.5,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            color: selected ? AppColors.primary : AppColors.textPrimary,
          ),
        ),
        subtitle: Text(
          currencyShort(c),
          textDirection: TextDirection.ltr,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 11,
            color: AppColors.textSecondary,
          ),
        ),
        trailing: selected
            ? const Icon(Icons.check_circle_rounded, color: AppColors.primary)
            : null,
        onTap: () {
          HapticFeedback.selectionClick();
          Navigator.pop(context, c);
        },
      );
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .72,
      minChildSize: .4,
      maxChildSize: .94,
      builder: (context, scroll) => Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.translate('repReportCurrency'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
          if (searchable)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: TextField(
                onChanged: (v) => setState(() => _q = v.trim()),
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  hintText: l10n.translate('prepCurrencySearch'),
                  hintStyle: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12.5,
                    color: AppColors.textSecondary,
                  ),
                  filled: true,
                  fillColor: AppColors.background,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 6),
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.only(bottom: 20),
              children: [...shown.map(tile)],
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────── cards

class PrCard extends StatelessWidget {
  const PrCard({super.key, required this.child, this.padding});
  final Widget child;
  final EdgeInsets? padding;
  @override
  Widget build(BuildContext context) =>
      RefCard(padding: padding ?? const EdgeInsets.all(14), child: child);
}

/// Section title with the report's icon chip.
class PrSectionTitle extends StatelessWidget {
  const PrSectionTitle(this.icon, this.title, {super.key, this.trailing});
  final IconData icon;
  final String title;
  final String? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        RefIconChip(icon, size: 30),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        if (trailing != null)
          Text(
            trailing!,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondary,
            ),
          ),
      ],
    ),
  );
}

/// A small KPI: label, animated amount, optional change chip.
/// A KPI tile: the title and the amount (or percentage) — nothing else.
/// Owner rule: no descriptions, captions or side stats on these tiles.
class PrKpi extends StatelessWidget {
  const PrKpi({
    super.key,
    required this.label,
    required this.value,
    required this.currency,
    required this.color,
    this.icon,
    this.percent = false,
  });
  final String label;
  final double value;
  final String currency;
  final Color color;
  final IconData? icon;
  final bool percent;

  @override
  Widget build(BuildContext context) {
    final lang = AppLocalizations.of(context).locale.languageCode;
    final style = TextStyle(
      fontFamily: 'Cairo',
      fontSize: 18,
      fontWeight: FontWeight.w900,
      color: color,
    );
    return PrCard(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: color),
                const SizedBox(width: 5),
              ],
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          percent
              ? ReportCountUp(
                  end: (value * 100).roundToDouble(),
                  currency: '',
                  suffix: '%',
                  style: style,
                )
              : ReportCountUp(
                  end: value,
                  currency: currencyLabel(currency, locale: lang),
                  style: style,
                ),
        ],
      ),
    );
  }
}

class PrChange extends StatelessWidget {
  const PrChange({super.key, required this.change, this.goodWhenUp = true});
  final double change;
  final bool goodWhenUp;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final up = change >= 0;
    final good = up == goodWhenUp;
    final color = change.abs() < .005
        ? AppColors.textSecondary
        : (good ? personalIncomeColor : AppColors.danger);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: color.withAlpha(24),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                size: 11,
                color: color,
              ),
              Text(
                prPercent(change.abs().clamp(0, 99.99).toDouble()),
                textDirection: TextDirection.ltr,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            l10n.translate('prepVsPrev'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 9.5,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

// ───────────────────────────────────────────────────────── charts

/// One animation value (0→1) that replays whenever [trigger] changes.
class PrGrow extends StatelessWidget {
  const PrGrow({
    super.key,
    required this.trigger,
    required this.builder,
    this.duration = const Duration(milliseconds: 900),
  });
  final Object trigger;
  final Widget Function(BuildContext, double) builder;
  final Duration duration;
  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return TweenAnimationBuilder<double>(
      key: ValueKey(trigger),
      tween: Tween(begin: reduced ? 1 : 0, end: 1),
      duration: reduced ? Duration.zero : duration,
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => builder(context, v),
    );
  }
}

/// Donut of shares with the total in the centre and a legend below.
class PrDonut extends StatelessWidget {
  const PrDonut({
    super.key,
    required this.slices,
    required this.currency,
    required this.centerLabel,
    this.maxSlices = 6,
    this.otherLabel = '',
  });
  final List<PersonalReportSlice> slices;
  final String currency;
  final String centerLabel;
  final int maxSlices;
  final String otherLabel;

  static List<PersonalReportSlice> fold(
    List<PersonalReportSlice> slices,
    int max,
    String otherLabel,
  ) {
    if (slices.length <= max) return slices;
    final head = slices.take(max - 1).toList();
    final tail = slices.skip(max - 1);
    return [
      ...head,
      PersonalReportSlice(
        otherLabel,
        tail.fold(0.0, (s, e) => s + e.amount),
        tail.fold(0, (s, e) => s + e.count),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final shown = fold(slices, maxSlices, otherLabel);
    final total = shown.fold(0.0, (s, e) => s + e.amount);
    final lang = AppLocalizations.of(context).locale.languageCode;
    return PrGrow(
      trigger: Object.hash(total, shown.length, currency),
      builder: (context, v) => Column(
        children: [
          SizedBox(
            height: 176,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  size: const Size.square(176),
                  painter: _DonutPainter(
                    values: [for (final s in shown) s.amount],
                    progress: v,
                    track: AppColors.border.withAlpha(110),
                  ),
                ),
                SizedBox(
                  width: 112,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        centerLabel,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 10.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      ReportAmount(
                        number: fmtNum(total * v),
                        currency: currencyShort(currency),
                        alignment: AlignmentDirectional.center,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < shown.length; i++)
            _LegendRow(
              color: personalReportTones[i % personalReportTones.length],
              label: shown[i].label,
              share: total > 0 ? shown[i].amount / total : 0,
              amount: prMoney(shown[i].amount, currency),
              progress: v,
              lang: lang,
            ),
        ],
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.color,
    required this.label,
    required this.share,
    required this.amount,
    required this.progress,
    required this.lang,
  });
  final Color color;
  final String label, amount, lang;
  final double share, progress;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      children: [
        Row(
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            Text(
              prPercent(share),
              textDirection: TextDirection.ltr,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 84),
              child: Text(
                amount,
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        PrBar(value: share * progress, color: color, height: 4),
      ],
    ),
  );
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({
    required this.values,
    required this.progress,
    required this.track,
  });
  final List<double> values;
  final double progress;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2 - 12;
    final c = size.center(Offset.zero);
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 18
        ..color = track,
    );
    final total = values.fold(0.0, (s, v) => s + v);
    if (total <= 0) return;
    const gap = .035;
    var start = -math.pi / 2;
    final sweepAll = 2 * math.pi * progress;
    var drawn = 0.0;
    for (var i = 0; i < values.length; i++) {
      final sweep = 2 * math.pi * values[i] / total;
      final visible = math.min(sweep, sweepAll - drawn);
      if (visible <= 0) break;
      final g = values.length > 1 ? gap : 0.0;
      if (visible - g > 0) {
        canvas.drawArc(
          rect,
          start + g / 2,
          visible - g,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 18
            ..strokeCap = StrokeCap.butt
            ..color = personalReportTones[i % personalReportTones.length],
        );
      }
      start += sweep;
      drawn += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.progress != progress || old.values != values || old.track != track;
}

/// Rounded progress bar; [value] may exceed 1 (over budget shows full red).
class PrBar extends StatelessWidget {
  const PrBar({
    super.key,
    required this.value,
    required this.color,
    this.height = 7,
  });
  final double value;
  final Color color;
  final double height;
  @override
  Widget build(BuildContext context) => Container(
    height: height,
    decoration: BoxDecoration(
      color: AppColors.border.withAlpha(110),
      borderRadius: BorderRadius.circular(height),
    ),
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: FractionallySizedBox(
        widthFactor: value.clamp(0.0, 1.0).toDouble(),
        child: Container(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(height),
          ),
        ),
      ),
    ),
  );
}

/// Paired income/spending bars per bucket, with a legend.
class PrDualBars extends StatelessWidget {
  const PrDualBars({
    super.key,
    required this.buckets,
    required this.labelOf,
    required this.incomeLabel,
    required this.spendLabel,
    this.height = 170,
  });
  final List<PersonalReportBucket> buckets;
  final String Function(DateTime) labelOf;
  final String incomeLabel, spendLabel;
  final double height;

  @override
  Widget build(BuildContext context) {
    final maxV = buckets.fold(
      0.0,
      (m, b) => math.max(m, math.max(b.income, b.spending)),
    );
    // Many buckets (a month by day): show every n-th label only.
    final every = (buckets.length / 7).ceil().clamp(1, 99);
    Widget legend(Color c, String t) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: c,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          t,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
    return Column(
      children: [
        Row(
          children: [
            legend(personalIncomeColor, incomeLabel),
            const SizedBox(width: 14),
            legend(personalSpendColor, spendLabel),
          ],
        ),
        const SizedBox(height: 10),
        PrGrow(
          trigger: Object.hash(maxV, buckets.length),
          builder: (context, v) => SizedBox(
            height: height,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < buckets.length; i++)
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _bar(
                                buckets[i].income,
                                maxV,
                                v,
                                personalIncomeColor,
                                buckets.length,
                              ),
                              SizedBox(width: buckets.length > 14 ? 1 : 3),
                              _bar(
                                buckets[i].spending,
                                maxV,
                                v,
                                personalSpendColor,
                                buckets.length,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 5),
                        SizedBox(
                          height: 14,
                          child: i % every == 0
                              ? FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    labelOf(buckets[i].start),
                                    maxLines: 1,
                                    style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 9.5,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _bar(double value, double maxV, double v, Color color, int n) {
    final f = maxV <= 0 ? 0.0 : (value / maxV) * v;
    final w = n > 20 ? 3.0 : (n > 10 ? 5.0 : (n > 6 ? 9.0 : 14.0));
    return LayoutBuilder(
      builder: (context, c) => Container(
        width: w,
        height: math.max(value > 0 ? 2.0 : 0.0, c.maxHeight * f),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.vertical(top: Radius.circular(w / 2)),
        ),
      ),
    );
  }
}

/// Plain label/value row used in report lists.
class PrRow extends StatelessWidget {
  const PrRow({
    super.key,
    required this.title,
    required this.value,
    this.subtitle,
    this.valueColor,
    this.leading,
    this.bottom,
  });
  final String title, value;
  final String? subtitle;
  final Color? valueColor;
  final Widget? leading;
  final Widget? bottom;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Column(
      children: [
        Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 10)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 10.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: ReportFitText(
                  text: value,
                  alignment: AlignmentDirectional.centerEnd,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: valueColor ?? AppColors.textPrimary,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (bottom != null) ...[const SizedBox(height: 6), bottom!],
      ],
    ),
  );
}

/// The calm note under a report: conversion basis + anything left out.
class PrFxNote extends StatelessWidget {
  const PrFxNote({super.key, required this.data});
  final PersonalReportData data;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final missing = data.unconvertedCount;
    final codes = data.unconverted.keys.map(currencyShort).join('، ');
    return Column(
      children: [
        Row(
          children: [
            Icon(
              Icons.currency_exchange_rounded,
              size: 13,
              color: AppColors.textSecondary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l10n.translate(
                  'prepConverted',
                  params: {
                    'c': currencyLabel(
                      data.currency,
                      locale: l10n.locale.languageCode,
                    ),
                  },
                ),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 10.5,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
        if (missing > 0)
          singleFxCard(
            l10n.translate(
              'prepUnconverted',
              params: {
                'n': '$missing',
                'codes': codes,
                't': currencyShort(data.currency),
              },
            ),
          ),
      ],
    );
  }
}

// ───────────────────────────────────────────────────────── controls

/// Report currency chip (app bar): flag + currency name, opens the picker.
class PrCurrencyChip extends StatelessWidget {
  const PrCurrencyChip({
    super.key,
    required this.currency,
    required this.onTap,
  });
  final String currency;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final lang = AppLocalizations.of(context).locale.languageCode;
    final flag = currencyFlagEmoji(currency);
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 10),
      child: Center(
        child: Semantics(
          button: true,
          label: AppLocalizations.of(context).translate('repReportCurrency'),
          child: GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              onTap();
            },
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: ScaleTransition(scale: a, child: child),
              ),
              child: Container(
                key: ValueKey(currency),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(20),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.primary.withAlpha(90)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (flag.isNotEmpty)
                      Text(flag, style: const TextStyle(fontSize: 13))
                    else
                      const Icon(
                        Icons.currency_exchange_rounded,
                        size: 14,
                        color: AppColors.primary,
                      ),
                    const SizedBox(width: 5),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 130),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          currencyLabel(currency, locale: lang),
                          maxLines: 1,
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    const Icon(
                      Icons.expand_more_rounded,
                      size: 16,
                      color: AppColors.primary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Period chips (same choices as the Business reports).
class PrPeriodBar extends StatelessWidget {
  const PrPeriodBar({
    super.key,
    required this.period,
    required this.onChanged,
    this.from,
    this.to,
  });
  final String period;
  final DateTime? from, to;
  final void Function(String period, DateTime? from, DateTime? to) onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    Widget chip(String label, String value) => Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: ChoiceChip(
        label: Text(
          label,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: period == value ? Colors.white : AppColors.textSecondary,
          ),
        ),
        selected: period == value,
        selectedColor: AppColors.primary,
        backgroundColor: AppColors.surface,
        side: BorderSide(
          color: period == value ? AppColors.primary : AppColors.border,
        ),
        showCheckmark: false,
        onSelected: (_) async {
          HapticFeedback.selectionClick();
          if (value == 'custom') {
            final now = DateTime.now();
            final picked = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2015),
              lastDate: now,
              initialDateRange: DateTimeRange(
                start: from ?? now.subtract(const Duration(days: 29)),
                end: to ?? now,
              ),
            );
            if (picked != null) onChanged('custom', picked.start, picked.end);
            return;
          }
          onChanged(value, null, null);
        },
      ),
    );
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          chip(l10n.translate('reconPeriodToday'), 'today'),
          chip(l10n.translate('reconPeriodWeek'), 'week'),
          chip(l10n.translate('reconPeriodMonth'), 'month'),
          chip(l10n.translate('reconPeriodYear'), 'year'),
          chip(l10n.translate('reconPeriodCustom'), 'custom'),
        ],
      ),
    );
  }
}

/// Staggered entrance (fade + rise) for report blocks.
class PrEntrance extends StatelessWidget {
  const PrEntrance({super.key, required this.index, required this.child});
  final int index;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduced) return child;
    final delay = (index.clamp(0, 10)) * 70;
    final total = 420 + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      builder: (context, t, child) {
        final local = ((t * total - delay) / 420).clamp(0.0, 1.0);
        final e = Curves.easeOutCubic.transform(local);
        return Opacity(
          opacity: e,
          child: Transform.translate(
            offset: Offset(0, 18 * (1 - e)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
