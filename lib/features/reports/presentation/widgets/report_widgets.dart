import 'dart:ui' as ui;

import 'package:fl_chart/fl_chart.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/services/currency/money_format_service.dart';

/// Custom FYONA-identity report illustrations (paint-only, theme-aware).
enum ReportArtKind { sales, money, inventory, debts, profit, overview }

class ReportArt extends StatelessWidget {
  final ReportArtKind kind;
  final double size;
  const ReportArt(this.kind, {super.key, this.size = 56});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(size),
        painter: _ReportArtPainter(kind: kind, dark: dark),
      ),
    );
  }
}

class _ReportArtPainter extends CustomPainter {
  final ReportArtKind kind;
  final bool dark;
  _ReportArtPainter({required this.kind, required this.dark});

  Color get _stroke => dark ? Colors.white70 : const Color(0xFF565656);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.045
      ..strokeCap = StrokeCap.round
      ..color = _stroke;
    final accent = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.05
      ..strokeCap = StrokeCap.round
      ..color = AppColors.primary;
    switch (kind) {
      case ReportArtKind.sales:
        // Rising bars
        final hs = [0.30, 0.48, 0.40, 0.62];
        final bw = s * 0.13;
        final gap = s * 0.07;
        var x = s * 0.12;
        for (var i = 0; i < hs.length; i++) {
          final h = s * 0.5 * hs[i];
          final r = RRect.fromRectAndRadius(
            Rect.fromLTWH(x, s * 0.78 - h, bw, h),
            Radius.circular(s * 0.03),
          );
          canvas.drawRRect(r, stroke);
          x += bw + gap;
        }
        canvas.drawLine(
          Offset(s * 0.10, s * 0.86),
          Offset(s * 0.90, s * 0.86),
          accent,
        );
      case ReportArtKind.money:
        // Banknote with coin
        final r = RRect.fromRectAndRadius(
          Rect.fromLTWH(s * 0.12, s * 0.30, s * 0.76, s * 0.40),
          Radius.circular(s * 0.06),
        );
        canvas.drawRRect(r, stroke);
        canvas.drawCircle(Offset(s * 0.5, s * 0.50), s * 0.11, accent);
        canvas.drawLine(
          Offset(s * 0.5, s * 0.42),
          Offset(s * 0.5, s * 0.58),
          stroke..strokeWidth = s * 0.04,
        );
      case ReportArtKind.inventory:
        // Stacked crates
        final big = RRect.fromRectAndRadius(
          Rect.fromLTWH(s * 0.10, s * 0.34, s * 0.52, s * 0.46),
          Radius.circular(s * 0.05),
        );
        canvas.drawRRect(big, stroke);
        canvas.drawLine(
          Offset(s * 0.36, s * 0.34),
          Offset(s * 0.36, s * 0.80),
          stroke..strokeWidth = s * 0.03,
        );
        final small = RRect.fromRectAndRadius(
          Rect.fromLTWH(s * 0.60, s * 0.52, s * 0.30, s * 0.28),
          Radius.circular(s * 0.04),
        );
        canvas.drawRRect(small, accent);
      case ReportArtKind.debts:
        // Two parties + handshake line
        canvas.drawCircle(Offset(s * 0.28, s * 0.30), s * 0.11, stroke);
        canvas.drawCircle(Offset(s * 0.72, s * 0.30), s * 0.11, stroke);
        canvas.drawLine(
          Offset(s * 0.34, s * 0.52),
          Offset(s * 0.66, s * 0.52),
          accent,
        );
        canvas.drawLine(
          Offset(s * 0.42, s * 0.70),
          Offset(s * 0.58, s * 0.70),
          stroke,
        );
      case ReportArtKind.profit:
        // Up arrow inside a circle
        canvas.drawCircle(Offset(s * 0.5, s * 0.5), s * 0.38, stroke);
        canvas.drawLine(
          Offset(s * 0.36, s * 0.62),
          Offset(s * 0.64, s * 0.36),
          accent,
        );
        final head = Path()
          ..moveTo(s * 0.50, s * 0.35)
          ..lineTo(s * 0.66, s * 0.35)
          ..lineTo(s * 0.64, s * 0.51)
          ..close();
        canvas.drawPath(head, Paint()..color = AppColors.primary);
      case ReportArtKind.overview:
        // Merging panels
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(s * 0.10, s * 0.14, s * 0.36, s * 0.32),
            Radius.circular(s * 0.04),
          ),
          stroke,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(s * 0.54, s * 0.14, s * 0.36, s * 0.32),
            Radius.circular(s * 0.04),
          ),
          accent,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(s * 0.10, s * 0.56, s * 0.36, s * 0.30),
            Radius.circular(s * 0.04),
          ),
          accent,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(s * 0.54, s * 0.56, s * 0.36, s * 0.30),
            Radius.circular(s * 0.04),
          ),
          stroke,
        );
    }
  }

  @override
  bool shouldRepaint(covariant _ReportArtPainter old) =>
      old.dark != dark || old.kind != kind;
}

/// 3D-tilt data card carrying a KPI question + its animated number.
/// Ledger totals are decimal strings. Keep their cents even above the
/// precision of a double, and still follow the user's display preferences.
String formatRecordedReportNumber(Object? value) {
  final match = value is String
      ? RegExp(r'^(-?)(\d+)\.(\d{2})$').firstMatch(value)
      : null;
  if (match == null) return fmtNum(value);
  var whole = match[2]!;
  var decimals = match[3]!;
  final prefs = currentMoneyFormat;
  if (!prefs.showDecimals) {
    if (int.parse(decimals) >= 50) {
      whole = (BigInt.parse(whole) + BigInt.one).toString();
    }
    decimals = '';
  } else {
    decimals = decimals.replaceFirst(RegExp(r'0+$'), '');
  }
  final sign = whole == '0' && decimals.isEmpty ? '' : match[1]!;
  if (prefs.useThousandsSeparator) {
    whole = whole.replaceAllMapped(
      RegExp(r'\d(?=(\d{3})+$)'), (m) => '${m[0]},',
    );
  }
  return '$sign$whole${decimals.isEmpty ? '' : '.$decimals'}';
}

class ReportKpiCard extends StatefulWidget {
  final String question;
  final String value;
  final Widget? valueOverride;
  final String currency;
  final String? count;
  final String? hint;
  final ReportArtKind art;
  final Color color;
  final VoidCallback? onTap;
  const ReportKpiCard({
    super.key,
    required this.question,
    required this.value,
    this.valueOverride,
    required this.currency,
    this.count,
    this.hint,
    required this.art,
    required this.color,
    this.onTap,
  });

  @override
  State<ReportKpiCard> createState() => _ReportKpiCardState();
}

class _ReportKpiCardState extends State<ReportKpiCard>
    with SingleTickerProviderStateMixin {
  double _tilt = 0;
  late final AnimationController _spring;

  @override
  void initState() {
    super.initState();
    _spring = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _spring.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Display-only cards (no onTap): zero press response — no gesture layer,
    // no haptics, no tilt, no tap hint icon.
    if (widget.onTap == null) {
      return Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0018)
          ..rotateY(_tilt * 0.2),
        child: ReportCard(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [ReportArt(widget.art, size: 30), const Spacer()],
                ),
                const SizedBox(height: 10),
                Text(
                  widget.question,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 11.5),
                    color: AppColors.textSecondary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                 widget.valueOverride ?? ReportCountUp(
                  end: _parse(widget.value),
                  currency: currencyLabel(
                    widget.currency,
                    locale: AppLocalizations.of(context).locale.languageCode,
                  ),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 17),
                    fontWeight: FontWeight.w900,
                    color: widget.color,
                  ),
                ),
                if (widget.count != null && widget.count!.isNotEmpty)
                  Text(
                    widget.count!,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 10),
                      color: AppColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onTap?.call();
      },
      onHorizontalDragUpdate: (d) {
        _tilt = ((d.localPosition.dy / 120) - 0.5).clamp(-.4, .4);
        _spring.forward(from: 0.6);
      },
      onHorizontalDragEnd: (_) {
        _tilt = 0;
        _spring.forward(from: 0);
      },
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0018)
          ..rotateY(_tilt * 0.2),
        child: ReportCard(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ReportArt(widget.art, size: 30),
                    const Spacer(),
                    Icon(
                      Icons.touch_app_rounded,
                      size: 13,
                      color: AppColors.textSecondary.withAlpha(140),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  widget.question,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 11.5),
                    color: AppColors.textSecondary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                 widget.valueOverride ?? ReportCountUp(
                  end: _parse(widget.value),
                  currency: currencyLabel(
                    widget.currency,
                    locale: AppLocalizations.of(context).locale.languageCode,
                  ),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 17),
                    fontWeight: FontWeight.w900,
                    color: widget.color,
                  ),
                ),
                if (widget.count != null && widget.count!.isNotEmpty)
                  Text(
                    widget.count!,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 10),
                      color: AppColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static num _parse(String v) => num.tryParse(v.replaceAll(',', '')) ?? 0;
}

/// Elevated rounded card with FYONA depth (soft shadow + burgundy rim).
class ReportCard extends StatelessWidget {
  final Widget child;
  const ReportCard({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(dark ? 120 : 28),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Container(
        padding: EdgeInsets.zero,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.primary.withAlpha(55)),
        ),
        child: child,
      ),
    );
  }
}

/// Report entry tile: custom art + title + hint, full-width tap.
class ReportTileCard extends StatelessWidget {
  final String title;
  final String hint;
  final ReportArtKind kind;
  final VoidCallback onTap;
  const ReportTileCard({
    super.key,
    required this.title,
    required this.hint,
    required this.kind,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: ReportCard(
        child: Container(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(16),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: ReportArt(kind, size: 38),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 13.5),
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      hint,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11),
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.primary,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Chart data point.
class ChartPoint {
  final String label;
  final double value;
  const ChartPoint({required this.label, required this.value});
}

/// Animated bar chart: bars rise smoothly to their real values on first
/// appearance and re-animate when the data changes. Touch shows the value.
class AnimatedReportChart extends StatefulWidget {
  final List<ChartPoint> points;
  final Color color;
  const AnimatedReportChart({
    super.key,
    required this.points,
    required this.color,
  });

  @override
  State<AnimatedReportChart> createState() => _AnimatedReportChartState();
}

class _AnimatedReportChartState extends State<AnimatedReportChart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  List<ChartPoint>? _last;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _ctrl.forward();
  }

  @override
  void didUpdateWidget(covariant AnimatedReportChart old) {
    super.didUpdateWidget(old);
    if (_last != null &&
        (_last!.length != widget.points.length ||
            (_last!.isNotEmpty &&
                widget.points.isNotEmpty &&
                _last!.first.value != widget.points.first.value))) {
      _ctrl.forward(from: 0);
    }
    _last = widget.points;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final grow = Curves.easeOutCubic.transform(_ctrl.value);
        return BarChart(
          BarChartData(
            alignment: BarChartAlignment.spaceAround,
            maxY: _maxY * 1.15,
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              getDrawingHorizontalLine: (v) => FlLine(
                color: AppColors.border.withAlpha(90),
                strokeWidth: 0.6,
                dashArray: [3, 4],
              ),
            ),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              leftTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 22,
                  getTitlesWidget: (v, meta) {
                    final i = v.toInt();
                    if (i < 0 || i >= widget.points.length) {
                      return const SizedBox.shrink();
                    }
                    // Thin labels: never overlap (RTL-safe — chart widgets
                    // handle their own layout).
                    final label = widget.points[i].label;
                    return Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 9,
                          color: dark
                              ? Colors.white54
                              : AppColors.textSecondary,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            barTouchData: BarTouchData(
              touchTooltipData: BarTouchTooltipData(
                getTooltipItem: (group, gi, rod, ri) => BarTooltipItem(
                  _fmt(rod.toY),
                  TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            barGroups: [
              for (var i = 0; i < widget.points.length; i++)
                BarChartGroupData(
                  x: i,
                  barRods: [
                    BarChartRodData(
                      toY: widget.points[i].value * grow,
                      width: 12,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(5),
                      ),
                      color: widget.color.withAlpha(210),
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  double get _maxY {
    var m = 0.0;
    for (final p in widget.points) {
      if (p.value > m) m = p.value;
    }
    return m <= 0 ? 1.0 : m;
  }

  static String _fmt(double v) => fmtNum(v);
}

/// Animated number (count-up) that replays on value change.
/// Amount plus a compact currency badge. The whole unit scales down to fit;
/// the currency stays visually secondary and never disappears.
class ReportAmount extends StatelessWidget {
  final String number;
  final String currency;
  final TextStyle style;
  final AlignmentDirectional alignment;
  const ReportAmount({
    super.key,
    required this.number,
    required this.currency,
    required this.style,
    this.alignment = AlignmentDirectional.centerStart,
  });

  @override
  Widget build(BuildContext context) {
    final compact = style.copyWith(
      fontSize: (style.fontSize ?? 14) * .62,
      fontWeight: FontWeight.w700,
    );
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: alignment,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            number,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
            style: style,
          ),
          if (currency.trim().isNotEmpty) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: (style.color ?? AppColors.primary).withAlpha(16),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                currency,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                style: compact,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One-line financial value that scales down instead of clipping, wrapping or
/// ellipsizing. Long currency names and 12+ digit amounts stay fully visible.
class ReportFitText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final AlignmentDirectional alignment;
  const ReportFitText({
    super.key,
    required this.text,
    required this.style,
    this.alignment = AlignmentDirectional.centerStart,
  });

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: alignment,
      child: Text(
        text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        style: style,
      ),
    );
  }
}

class ReportCountUp extends StatefulWidget {
  final num end;
  final String suffix;
  final String currency;
  final TextStyle style;
  /// Exact recorded value shown once the count-up lands (keeps every cent of
  /// ledger decimals that a double cannot hold).
  final String? exact;
  final AlignmentDirectional alignment;
  const ReportCountUp({
    super.key,
    required this.end,
    required this.style,
    this.suffix = '',
    this.currency = '',
    this.exact,
    this.alignment = AlignmentDirectional.centerStart,
  });

  @override
  State<ReportCountUp> createState() => _ReportCountUpState();
}

class _ReportCountUpState extends State<ReportCountUp>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  num _from = 0;
  num? _lastEnd;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    );
    _lastEnd = widget.end;
    _ctrl.forward();
  }

  @override
  void didUpdateWidget(covariant ReportCountUp old) {
    super.didUpdateWidget(old);
    if (widget.end != _lastEnd) {
      _from = _valueAt(_ctrl.value);
      _lastEnd = widget.end;
      _ctrl.forward(from: 0);
    }
  }

  double _valueAt(double t) =>
      _from + (widget.end - _from) * Curves.easeOutCubic.transform(t);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) => widget.currency.trim().isNotEmpty
          ? ReportAmount(
              number: _number,
              currency: widget.currency,
              style: widget.style,
              alignment: widget.alignment,
            )
          : ReportFitText(
              text: '$_number${widget.suffix}',
              style: widget.style,
              alignment: widget.alignment,
            ),
    );
  }

  String get _number => _ctrl.value >= 1 && widget.exact != null
      ? widget.exact!
      : _fmt(_valueAt(_ctrl.value));

  static String _fmt(num v) => fmtNum(v);
}

/// Report-currency picker sheet (enabled currencies of the business).
Future<String?> showReportCurrencyPicker(
  BuildContext context,
  List<String> currencies,
  String current,
) async {
  final l10n = AppLocalizations.of(context);
  final dark = Theme.of(context).brightness == Brightness.dark;
  final list = currencies.isEmpty ? const ['SAR'] : currencies;
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 14),
          Text(
            l10n.translate('repReportCurrency'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          for (final c in list)
            ListTile(
              leading: Icon(
                c == current
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: AppColors.primary,
                size: 20,
              ),
              title: Text(
                currencyLabel(c, locale: l10n.locale.languageCode),
                maxLines: 1,
                overflow: TextOverflow.visible,
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.w700,
                ),
              ),
              onTap: () => Navigator.pop(ctx, c),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Small value/stat row helper reused across report pages.
class ReportStatRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  final IconData? icon;
  const ReportStatRow({
    super.key,
    required this.label,
    required this.value,
    this.color,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: color ?? AppColors.textSecondary),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Flexible(
            child: ReportFitText(
              text: value,
              alignment: AlignmentDirectional.centerEnd,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: color ?? AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Ambient burgundy glow behind hero sections (repaint-bounded, cheap).
class ReportGlow extends StatelessWidget {
  final double height;
  const ReportGlow({super.key, this.height = 120});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(painter: _GlowPainter()),
      ),
    );
  }
}

class _GlowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(size.width / 2, size.height),
          size.width * 0.7,
          [AppColors.primary.withAlpha(38), AppColors.primary.withAlpha(0)],
        ),
    );
  }

  @override
  bool shouldRepaint(covariant _GlowPainter old) => false;
}

/// ONE concise FX warning for the whole report: merges every gap
/// ({currency,count} from all sections) into a single line naming what was
/// excluded — never a stack of repetitive messages.
String? singleFxNotice(
  AppLocalizations l10n,
  List<dynamic> sections,
  String target,
) {
  // The owner's rule: reports never show warnings. Every amount is valued
  // with the saved rates (see BusinessReportFx), so there is nothing to warn.
  return null;
}

// ignore: unused_element
String? _legacySingleFxNotice(
  AppLocalizations l10n,
  List<dynamic> sections,
  String target,
) {
  final merged = <String, int>{};
  for (final m in sections.whereType<Map>()) {
    final gaps = m['gaps'];
    if (gaps is! List) continue;
    for (final g in gaps.whereType<Map>()) {
      final cur = '${g['currency']}';
      if (cur.isEmpty) continue;
      merged[cur] = (merged[cur] ?? 0) + ((g['count'] as num?)?.toInt() ?? 0);
    }
  }
  if (merged.isEmpty) return null;
  final total = merged.values.fold(0, (a, b) => a + b);
  final detail = merged.entries.map((e) => '${e.key}×${e.value}').join('، ');
  return l10n.translate(
    'repFxSingle',
    params: {'n': '$total', 't': target, 'd': detail},
  );
}

/// The single FX notice card (or nothing when everything converted).
Widget singleFxCard(String? text) {
  if (text == null || text.isEmpty) return const SizedBox.shrink();
  return Container(
    margin: const EdgeInsets.only(top: 4),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.warning.withAlpha(16),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppColors.warning.withAlpha(60)),
    ),
    child: Row(
      children: [
        Icon(Icons.currency_pound_outlined, size: 14, color: AppColors.warning),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 10.5,
              color: AppColors.warning,
              height: 1.4,
            ),
          ),
        ),
      ],
    ),
  );
}

// ══════════════════════════════════════════════════════════════
//  Reference-identity widgets (Report Identity PDFs) — RTL/LTR aware.
// ══════════════════════════════════════════════════════════════

/// White card with the reference look: radius 18, hairline border, soft shadow.
class RefCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final Color? background;
  final Color? borderColor;
  const RefCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.background,
    this.borderColor,
  });
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: background ?? AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: borderColor ?? AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// Tinted rounded-square icon chip used across every reference card.
class RefIconChip extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  const RefIconChip(
    this.icon, {
    super.key,
    this.color = AppColors.primary,
    this.size = 34,
  });
  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withAlpha(22),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: size * 0.52, color: color),
    );
  }
}

/// Period chips row: اليوم/هذا الأسبوع/هذا الشهر/هذه السنة (+ custom only
/// when active). Selected = burgundy fill, white text.
class RefPeriodChips extends StatelessWidget {
  final String period;
  final ValueChanged<String> onSelect;
  final VoidCallback onCustom;
  const RefPeriodChips({
    super.key,
    required this.period,
    required this.onSelect,
    required this.onCustom,
  });
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    Widget chip(String label, String value, {bool custom = false}) {
      final selected = custom ? period == 'custom' : period == value;
      return GestureDetector(
        onTap: () => custom ? onCustom() : onSelect(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? AppColors.primary : AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : AppColors.textPrimary,
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        children: [
          chip(l10n.translate('reconPeriodToday'), 'today'),
          const SizedBox(width: 8),
          chip(l10n.translate('reconPeriodWeek'), 'week'),
          const SizedBox(width: 8),
          chip(l10n.translate('reconPeriodMonth'), 'month'),
          const SizedBox(width: 8),
          chip(l10n.translate('reconPeriodYear'), 'year'),
          if (period == 'custom') ...[
            const SizedBox(width: 8),
            chip(l10n.translate('repCustomRange'), 'custom', custom: true),
          ],
        ],
      ),
    );
  }
}

/// Section header: icon chip + bold title (+ optional trailing action).
class RefSectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color color;
  final String? actionLabel;
  final VoidCallback? onAction;
  const RefSectionHeader(
    this.icon,
    this.title, {
    super.key,
    this.color = AppColors.primary,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        RefIconChip(icon, color: color, size: 30),
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
        if (actionLabel != null)
          Flexible(
            child: GestureDetector(
              onTap: onAction,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerEnd,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      actionLabel!,
                      maxLines: 1,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(width: 3),
                    const Icon(
                      Icons.chevron_left_rounded,
                      size: 18,
                      color: AppColors.primary,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One reference stat row: icon chip + label (start) | value (end, colored).
class RefStatRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? color;
  final String? subtitle;
  const RefStatRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.color,
    this.subtitle,
  });
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          RefIconChip(icon, color: color ?? AppColors.textPrimary, size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
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
          Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Burgundy-tinted full-width pill button («عرض جميع ...»).
class RefPill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  const RefPill({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
  });
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 10),
        decoration: BoxDecoration(
          color: AppColors.primary.withAlpha(14),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.primary.withAlpha(45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: AppColors.primary),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Thin progress bar (burgundy fill on light track).
class RefProgress extends StatelessWidget {
  final double value; // 0..1
  const RefProgress({super.key, required this.value});
  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, c) {
        return Container(
          height: 6,
          width: double.infinity,
          decoration: BoxDecoration(
            color: AppColors.border.withAlpha(120),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: FractionallySizedBox(
              widthFactor: v,
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Why a profit figure shows «—», in plain words the merchant understands.
String profitUnavailableReason(AppLocalizations l10n, Map? data, Map? section) {
  final gaps = section?['gaps'];
  if (data?['profit_cost_unknown'] == true) {
    return l10n.translate('repProfitWhyCost');
  }
  if (gaps is List && gaps.isNotEmpty) {
    return l10n.translate('repProfitWhyRate');
  }
  if (data?['legacy_flow_unclassified'] == true) {
    return l10n.translate('repProfitWhyLegacy');
  }
  return l10n.translate('repProfitWhyGeneric');
}

Future<void> showProfitUnavailableInfo(
  BuildContext context,
  Map? data, {
  Map? section,
}) {
  final l10n = AppLocalizations.of(context);
  HapticFeedback.selectionClick();
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Row(
        children: [
          const Icon(Icons.info_outline_rounded, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.translate('repProfitWhyTitle'),
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
      content: Text(
        profitUnavailableReason(l10n, data, section),
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 13.5,
          height: 1.6,
          color: AppColors.textPrimary,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(
            l10n.translate('repProfitWhyOk'),
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontWeight: FontWeight.w800,
              color: AppColors.primary,
            ),
          ),
        ),
      ],
    ),
  );
}

/// «—» for an unavailable profit: tap it to learn why.
class ReportProfitUnavailable extends StatelessWidget {
  const ReportProfitUnavailable({
    super.key,
    required this.data,
    this.section,
    required this.style,
  });
  final Map? data;
  final Map? section;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showProfitUnavailableInfo(context, data, section: section),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('—', style: style),
            const SizedBox(width: 6),
            Icon(
              Icons.info_outline_rounded,
              size: (style.fontSize ?? 14) * .9,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
