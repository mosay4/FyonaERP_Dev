import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/account_type_bar.dart';
import '../recon_report_pdf_layout.dart';

/// Result palette (per the business request):
///   system  → ORANGE, actual → GREEN, difference → RED.
const Color kReconSystem = Color(0xFFE8820C);
const Color kReconActual = Color(0xFF1B7A43);
const Color kReconDiff = Color(0xFFD32F2F);

/// One line of a reconciliation result (a currency or a product).
class ReconResultRow {
  final String name;
  final String? mark;
  final String? markColorKey;
  final num system;
  final num actual;
  final num diff;
  final String? unit;
  /// Per-unit breakdown for multi-unit products (from `parts`).
  final List<ReconUnitRow> unitRows;
  const ReconResultRow({
    required this.name,
    this.mark,
    this.markColorKey,
    required this.system,
    required this.actual,
    required this.diff,
    this.unit,
    this.unitRows = const [],
  });
}

/// Warm animated header: neon-glow verdict ring + animated count of the
/// biggest movement. Paint-only, cheap, reduced-motion aware.
class ReconResultHeader extends StatefulWidget {
  final int matched;
  final int shortCount;
  final int surplusCount;
  final String currencyOrUnit;
  const ReconResultHeader({
    super.key,
    required this.matched,
    required this.shortCount,
    required this.surplusCount,
    this.currencyOrUnit = '',
  });

  @override
  State<ReconResultHeader> createState() => _ReconResultHeaderState();
}

class _ReconResultHeaderState extends State<ReconResultHeader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final clean = widget.shortCount == 0 && widget.surplusCount == 0;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          final t = Curves.easeOutCubic.transform(_ctrl.value);
          return Container(
            padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [
                  AppColors.primary.withAlpha(26),
                  AppColors.primary.withAlpha(6),
                ],
              ),
              border: Border.all(color: AppColors.primary.withAlpha(60)),
              boxShadow: [
                BoxShadow(
                  color: (clean ? kReconActual : AppColors.primary)
                      .withAlpha(40),
                  blurRadius: 26,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Column(children: [
              // Verdict ring (3D-ish tilt on reveal)
              Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.0016)
                  ..rotateX((1 - t) * 0.5),
                child: Container(
                  width: 92,
                  height: 92,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (clean ? kReconActual : AppColors.primary)
                        .withAlpha(30),
                    border: Border.all(
                        color: clean ? kReconActual : AppColors.primary,
                        width: 2.4),
                  ),
                  child: Icon(
                    clean
                        ? Icons.verified_rounded
                        : Icons.tune_rounded,
                    size: 42,
                    color: clean ? kReconActual : AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                clean ? l10n.translate('reconNoDiffHint')
                    : l10n.translate('reconResultTitle'),
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 15),
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary),
              ),
              const SizedBox(height: 12),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _chip(l10n.translate('reconMatch'), widget.matched,
                    kReconActual),
                const SizedBox(width: 8),
                _chip(l10n.translate('reconShort'), widget.shortCount,
                    kReconDiff),
                const SizedBox(width: 8),
                _chip(l10n.translate('reconSurplus'), widget.surplusCount,
                    kReconSystem),
              ]),
            ]),
          );
        },
      ),
    );
  }

  Widget _chip(String label, int n, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withAlpha(24),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withAlpha(120)),
      ),
      child: Text('$label $n',
          style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: color)),
    );
  }
}

/// «بالنظام (برتقالي) / بالحقيقة (أخضر) / الفرق (أحمر)» table with animated
/// number reveal. RTL-safe.
class ReconDiffTable extends StatefulWidget {
  final List<ReconResultRow> rows;
  final bool showUnitColumn;

  /// Label of the FIRST column: «العملة» (banks) / «المنتج» (inventory).
  final String firstColumnLabel;
  final bool money;
  const ReconDiffTable(
      {super.key,
      required this.rows,
      this.showUnitColumn = false,
      this.firstColumnLabel = '',
      this.money = false});

  @override
  State<ReconDiffTable> createState() => _ReconDiffTableState();
}

class _ReconDiffTableState extends State<ReconDiffTable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.primary.withAlpha(50)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withAlpha(28),
              blurRadius: 18,
              offset: const Offset(0, 8)),
        ],
      ),
      child: Column(children: [
        // Header row
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.primary.withAlpha(14),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Row(children: [
            Expanded(
                flex: 5,
                child: Text(widget.firstColumnLabel,
                    textAlign: TextAlign.start,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11),
                        fontWeight: FontWeight.w800,
                        color: AppColors.textSecondary))),
            for (final (label, color) in [
              (l10n.translate('reconColSystem'), kReconSystem),
              (l10n.translate('reconColActual'), kReconActual),
              (l10n.translate('reconColDiff'), kReconDiff),
            ])
              Expanded(
                flex: 3,
                child: Text(label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11),
                        fontWeight: FontWeight.w800,
                        color: color)),
              ),
          ]),
        ),
        for (var i = 0; i < widget.rows.length; i++)
          _row(context, widget.rows[i], i),
        const SizedBox(height: 6),
      ]),
    );
  }

  Widget _row(BuildContext context, ReconResultRow r, int index) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final start = (index * 0.08).clamp(0.0, 0.6);
        final t = ((_ctrl.value - start) / (1 - start)).clamp(0.0, 1.0);
        final eased = Curves.easeOutCubic.transform(t);
        return Opacity(
          opacity: 0.25 + 0.75 * eased,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - eased)),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                border: Border(
                    top: BorderSide(
                        color: AppColors.border.withAlpha(70), width: .5)),
              ),
              child: Row(children: [
                Expanded(
                  flex: 5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Flexible(
                          child: Text(r.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: R.fontSize(context, 13),
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textPrimary)),
                        ),
                        if (r.markColorKey != null &&
                            r.markColorKey!.isNotEmpty) ...[
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 0.5),
                            decoration: BoxDecoration(
                              color: accountTypeBarColor(r.markColorKey)
                                  .withAlpha(22),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                                ReconPdfLayout.accountTypeLabelStr(
                                    r.markColorKey,
                                    isAr: AppLocalizations.of(context)
                                            .locale
                                            .languageCode ==
                                        'ar',
                                    short: true),
                                style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: R.fontSize(context, 8),
                                    fontWeight: FontWeight.w700,
                                    color:
                                        accountTypeBarColor(r.markColorKey))),
                          ),
                        ],
                      ]),
                      if (r.mark != null)
                        Text(r.mark!,
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: R.fontSize(context, 10),
                                color: AppColors.textSecondary)),
                      // Per-unit breakdown INSIDE the same product cell
                      for (final ur in r.unitRows)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Row(children: [
                            Text(ur.unit,
                                style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: R.fontSize(context, 10),
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textSecondary)),
                            const SizedBox(width: 6),
                            Text(
                                '${ur.before} ← ${ur.after}'
                                ' (${AppLocalizations.of(context).translate('reconColDiff')}: ${ur.diff})',
                                style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: R.fontSize(context, 10),
                                    color: AppColors.textSecondary)),
                          ]),
                        ),
                    ],
                  ),
                ),
                // The REAL values are always shown — the animation only
                // fades/slides the row (it must never scale the numbers,
                // otherwise a stalled ticker would leave everything at 0).
                _numCell(r.system, kReconSystem, r.unit),
                _numCell(r.actual, kReconActual, r.unit),
                _numCell(r.diff, kReconDiff, r.unit, signed: true),
              ]),
            ),
          ),
        );
      },
    );
  }

  Widget _numCell(num v, Color color, String? unit,
      {bool signed = false}) {
    final txt = widget.money
        ? fmtNum(v)
        : (v.roundToDouble() == v
            ? v.toInt().toString().replaceAllMapped(
                RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},')
            : v.toStringAsFixed(2));
    return Expanded(
      flex: 3,
      child: Column(children: [
        Text('${signed && v > 0 ? '+' : ''}$txt',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 13),
                fontWeight: FontWeight.w900,
                color: color)),
        if (unit != null && unit.isNotEmpty)
          Text(unit,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 9),
                  color: AppColors.textSecondary)),
      ]),
    );
  }
}

/// Slim colored bar used inside the results table.
class AccountTypeBarMini extends StatelessWidget {
  final String? type;
  const AccountTypeBarMini({super.key, this.type});
  @override
  Widget build(BuildContext context) {
    final savings = (type ?? '') == 'savings';
    return Container(
      width: 4,
      height: 30,
      decoration: BoxDecoration(
        color: savings ? kReconActual : kReconSystem.withAlpha(200),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

/// «مساواة النظام» summary sheet: bank/cash name + a FAST compact table of
/// every currency BEFORE → AFTER, then تأكيد. Multi-unit products show EVERY
/// unit in its own row INSIDE the product's rectangle — never only the base
/// unit. Returns true when confirmed.
Future<bool> showEqualizeSummary(
  BuildContext context, {
  required String title,
  required List<EqualizeEntry> entries,
}) async {
  final l10n = AppLocalizations.of(context);
  final isAr = Localizations.localeOf(context).languageCode != 'en';
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      return Container(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 12),
            Row(children: [
              const SizedBox(width: 16),
              const Icon(Icons.compare_arrows_rounded,
                  color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    '${l10n.translate('reconEqualizeTitle')} — $title',
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(ctx, 15),
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary)),
              ),
              const SizedBox(width: 16),
            ]),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(l10n.translate('reconEqualizeHint'),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(ctx, 11),
                      height: 1.5,
                      color: AppColors.textSecondary)),
            ),
            const SizedBox(height: 10),
            // Column headers (before → after).
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Expanded(
                    flex: 4,
                    child: Text('',
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(ctx, 11)))),
                Expanded(
                    flex: 3,
                    child: Text(l10n.translate('reconBeforeLabel'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(ctx, 11),
                            fontWeight: FontWeight.w800,
                            color: kReconSystem))),
                Expanded(
                    flex: 3,
                    child: Text(l10n.translate('reconAfterLabel'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(ctx, 11),
                            fontWeight: FontWeight.w800,
                            color: kReconActual))),
              ]),
            ),
            const SizedBox(height: 6),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final e in entries)
                    if (e.rows.length == 1 && e.rows.first.label.isEmpty)
                      _equalizeSimpleRow(ctx, isAr, e, e.rows.first)
                    else
                      _equalizeGroupCard(ctx, isAr, e),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  onPressed: () => Navigator.pop(ctx, true),
                  icon: const Icon(Icons.check_circle_outline_rounded),
                  label: Text(l10n.translate('reconConfirmBtn'),
                      style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontWeight: FontWeight.w800,
                          fontSize: 15)),
                ),
              ),
            ),
          ]),
        ),
      );
    },
  );
  return ok == true;
}

/// A single bank/cash currency row: name (+ optional type badge) before/after.
Widget _equalizeSimpleRow(
    BuildContext ctx, bool isAr, EqualizeEntry e, EqualizeUnitRow r) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(children: [
      if (e.type != null && e.type!.isNotEmpty) ...[
        AccountTypeBar(type: e.type, height: 26),
        const SizedBox(width: 8),
      ],
      Expanded(
        flex: 4,
        child: Row(children: [
          Flexible(
            child: Text(e.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(ctx, 12.5),
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
          ),
          if (e.type != null && e.type!.isNotEmpty) ...[
            const SizedBox(width: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
              decoration: BoxDecoration(
                color: accountTypeBarColor(e.type).withAlpha(24),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                  ReconPdfLayout.accountTypeLabelStr(e.type,
                      isAr: isAr, short: true),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(ctx, 8),
                      fontWeight: FontWeight.w700,
                      color: accountTypeBarColor(e.type))),
            ),
          ],
        ]),
      ),
      Expanded(
          flex: 3,
          child: Text(r.before,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(ctx, 12.5),
                  fontWeight: FontWeight.w800,
                  color: kReconSystem))),
      Expanded(
          flex: 3,
          child: Text(r.after,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(ctx, 12.5),
                  fontWeight: FontWeight.w800,
                  color: kReconActual))),
    ]),
  );
}

/// A product group: ONE rectangle with the product name header and a row for
/// every unit (name + before → after), same columns and colors as the table.
Widget _equalizeGroupCard(BuildContext ctx, bool isAr, EqualizeEntry e) {
  return Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: AppColors.surfaceVariant.withAlpha(90),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppColors.primary.withAlpha(45)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.inventory_2_outlined,
            size: 14, color: AppColors.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(e.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(ctx, 12.5),
                  fontWeight: FontWeight.w900,
                  color: AppColors.textPrimary)),
        ),
      ]),
      const SizedBox(height: 4),
      for (final r in e.rows)
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Row(children: [
            Expanded(
              flex: 4,
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text('${e.name} (${r.label})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(ctx, 11),
                        fontWeight: FontWeight.w700,
                        color: AppColors.textSecondary)),
              ),
            ),
            Expanded(
                flex: 3,
                child: Text(r.before,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(ctx, 11.5),
                        fontWeight: FontWeight.w800,
                        color: kReconSystem))),
            Expanded(
                flex: 3,
                child: Text(r.after,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(ctx, 11.5),
                        fontWeight: FontWeight.w800,
                        color: kReconActual))),
          ]),
        ),
    ]),
  );
}

/// Celebratory success animation after a confirmed equalization: a ring of
/// soft neon sparks + a scale-in check. Runs ONCE (no fake waiting).
class ReconSuccessBurst extends StatefulWidget {
  final String message;
  const ReconSuccessBurst({super.key, required this.message});

  @override
  State<ReconSuccessBurst> createState() => _ReconSuccessBurstState();
}

class _ReconSuccessBurstState extends State<ReconSuccessBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          final t = Curves.easeOutCubic.transform(_ctrl.value);
          return Column(mainAxisSize: MainAxisSize.min, children: [
            CustomPaint(
              size: const Size(120, 120),
              painter: _BurstPainter(t: t),
            ),
            const SizedBox(height: 12),
            Text(widget.message,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 16),
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary)),
          ]);
        },
      ),
    );
  }
}

class _BurstPainter extends CustomPainter {
  final double t;
  _BurstPainter({required this.t});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    // Neon sparks orbiting outward.
    for (var i = 0; i < 12; i++) {
      final a = (i / 12) * math.pi * 2;
      final r = 18 + t * 40;
      final p = Offset(c.dx + math.cos(a) * r, c.dy + math.sin(a) * r);
      canvas.drawCircle(
          p,
          3.2 * (1 - t * 0.6),
          Paint()
            ..color = (i.isEven ? AppColors.primary : kReconActual)
                .withAlpha((220 * (1 - t)).round()));
    }
    // Glow ring.
    canvas.drawCircle(
        c,
        34 * (0.6 + 0.4 * t),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4
          ..shader = ui.Gradient.sweep(
            c,
            [AppColors.primary, kReconActual, AppColors.primary],
          )
          ..color = AppColors.primary.withAlpha(160));
    // Center check (scale-in).
    final s = Curves.easeOutBack.transform(t);
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.scale(s);
    final check = Path()
      ..moveTo(-14, 2)
      ..lineTo(-4, 12)
      ..lineTo(16, -10);
    canvas.drawPath(
        check,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = kReconActual);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BurstPainter old) => old.t != t;
}
