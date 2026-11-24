import 'package:flutter/material.dart';

import '../../../../core/utils/currency_formatter.dart' as cf;
import 'package:fyona_flutter/core/utils/document_number.dart';

/// Friendly, localized message for a failed request — NEVER the raw
/// DioException/stack text in the UI. The technical detail stays in logs.
String debtFriendlyError(Object e, String Function(String) tr) {
  final s = e.toString().toLowerCase();
  if (s.contains('timeout') || s.contains('timed out')) {
    return tr('debtErrTimeout');
  }
  if (s.contains('socketexception') ||
      s.contains('connection') ||
      s.contains('network') ||
      s.contains('failed host')) {
    return tr('debtErrNetwork');
  }
  if (s.contains('500') ||
      s.contains('502') ||
      s.contains('503') ||
      s.contains('server error')) {
    return tr('debtErrServer');
  }
  return tr('debtErrGeneric');
}

/// Localized, non-technical currency token for amounts: the full Arabic name
/// in AR (ريال يمني قديم) and the ISO code in EN. Never the raw YER_OLD in AR.
String debtCurrencyLabel(String code) => cf.currencyLabel(code);

/// Circular avatar showing the first letter of a party/merchant name.
class DebtAvatar extends StatelessWidget {
  final String name;
  final double size;
  const DebtAvatar(this.name, {super.key, this.size = 46});
  @override
  Widget build(BuildContext context) {
    final t = name.trim();
    final letter = t.isEmpty ? '?' : t.characters.first;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: DebtStyle.red.withAlpha(28),
        shape: BoxShape.circle,
      ),
      child: Text(letter,
          style: DebtStyle.text(context,
              size: size * 0.42, bold: true, color: DebtStyle.red)),
    );
  }
}

/// Visual tokens measured from Debt References (not the global app palette).
class DebtStyle {
  static const red = Color(0xFFAB0B27);
  static const wine = Color(0xFF8E1029);
  static const pink = Color(0xFFF8E7EB);
  static bool dark(BuildContext c) => Theme.of(c).brightness == Brightness.dark;
  static Color background(BuildContext c) => dark(c) ? const Color(0xFF17171B) : const Color(0xFFF2F3F6);
  static Color surface(BuildContext c) => dark(c) ? const Color(0xFF242128) : const Color(0xFFFCFAFC);
  static Color border(BuildContext c) => dark(c) ? const Color(0xFF53323C) : const Color(0xFFEAD4DA);
  static Color ink(BuildContext c) => dark(c) ? Colors.white : const Color(0xFF142430);
  static TextStyle text(BuildContext c, {double size = 14, bool bold = false, Color? color}) =>
      TextStyle(fontFamily: 'Cairo', fontSize: size, fontWeight: bold ? FontWeight.w800 : FontWeight.w500, color: color ?? ink(c));
}

String debtAmount(dynamic value) {
  final n = value is num ? value : num.tryParse('$value');
  if (n == null || !n.isFinite) return '—';
  return cf.fmtNum(n);
}

/// Quantities: whole numbers never show `.0` (1, 2, 3) unless the merchant
/// actually typed a fraction (1.5 stays 1.5). No thousands separators so the
/// value can be edited in a text field and parsed back safely.
/// Short, plain currency name for tight UI (debt cards): Arabic names where
/// everyone understands them; the code itself in English builds.
String debtCurrencyShort(String code, bool arabic) {
  final c = code.trim().toUpperCase();
  if (!arabic) return c;
  switch (c) {
    case 'USD':
      return 'دولار';
    case 'SAR':
      return 'سعودي';
    case 'YER':
      return 'يمني';
    case 'YER_NEW':
      return 'يمني جديد';
    case 'YER_OLD':
      return 'يمني قديم';
    case 'EUR':
      return 'يورو';
    case 'GBP':
      return 'جنيه';
    case 'AED':
      return 'درهم';
    case 'KWD':
      return 'كويتي';
    case 'QAR':
      return 'قطري';
    case 'BHD':
      return 'بحريني';
    case 'OMR':
      return 'عماني';
    case 'JOD':
      return 'أردني';
    case 'EGP':
      return 'مصري';
    case 'IQD':
      return 'عراقي';
    case 'SYP':
      return 'سوري';
    case 'TRY':
      return 'تركي';
    case 'CNY':
      return 'صيني';
    case 'INR':
      return 'هندي';
    default:
      return debtCurrencyLabel(c);
  }
}

String debtPlainNum(dynamic value) {
  final n = value is num ? value : num.tryParse('$value');
  if (n == null || !n.isFinite) return '';
  final d = n.toDouble();
  if ((d - d.roundToDouble()).abs() < 1e-9) return d.round().toString();
  var s = d.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  return s;
}

class DebtPanel extends StatelessWidget {
  final Widget child;
  final bool red;
  final bool pink;
  final bool decorated;
  final EdgeInsetsGeometry padding;
  const DebtPanel({super.key, required this.child, this.red = false,
    this.pink = false, this.decorated = false, this.padding = const EdgeInsets.all(16)});
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(borderRadius: BorderRadius.circular(16),
      border: Border.all(color: red ? DebtStyle.red : (pink ? DebtStyle.red.withAlpha(50) : DebtStyle.border(context))),
      boxShadow: decorated ? [BoxShadow(color: DebtStyle.red.withAlpha(12), blurRadius: 12, offset: const Offset(0, 4))] : null,
      gradient: red
          ? const LinearGradient(colors: [DebtStyle.red, DebtStyle.wine])
          : (pink ? const LinearGradient(colors: [DebtStyle.pink, Color(0xFFFDF3F6)]) : null),
      color: (red || pink) ? null : DebtStyle.surface(context)),
    child: ClipRRect(borderRadius: BorderRadius.circular(15),
      child: CustomPaint(painter: decorated ? _DebtDecoration(red) : null,
        child: Padding(padding: padding, child: child))));
}

class _DebtDecoration extends CustomPainter {
  final bool red;
  _DebtDecoration(this.red);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = (red ? Colors.white : DebtStyle.red).withAlpha(red ? 16 : 9);
    canvas.drawOval(Rect.fromLTWH(-size.width * .35, -size.height * 1.1, size.width * .8, size.height * 2), paint);
    canvas.drawCircle(Offset(size.width * .85, size.height * 1.7), size.height, paint);
  }
  @override
  bool shouldRepaint(_DebtDecoration old) => red != old.red;
}

class DebtIcon extends StatelessWidget {
  final IconData icon;
  final double size;
  final bool inverse;
  const DebtIcon(this.icon, {super.key, this.size = 42, this.inverse = false});
  @override
  Widget build(BuildContext context) => Container(width: size, height: size,
    decoration: BoxDecoration(color: inverse ? Colors.white.withAlpha(30) : DebtStyle.red.withAlpha(20), borderRadius: BorderRadius.circular(size * .28)),
    child: Icon(icon, size: size * .55, color: inverse ? Colors.white : DebtStyle.red));
}

/// Disclosure chevron on the leading (left-in-RTL) edge, pointing toward the
/// content start — exactly as the references show. Forced LTR so it is never
/// auto-mirrored into the opposite direction.
class DebtArrow extends StatelessWidget {
  final Color? color;
  const DebtArrow({super.key, this.color});
  @override
  Widget build(BuildContext c) => Icon(Icons.chevron_right,
    textDirection: TextDirection.ltr, size: 24, color: color ?? DebtStyle.ink(c));
}

class DebtPersonTile extends StatelessWidget {
  final String name;
  final VoidCallback onTap;
  final bool merchant;
  const DebtPersonTile({super.key, required this.name, required this.onTap, this.merchant = false});
  @override
  Widget build(BuildContext c) => Padding(padding: const EdgeInsets.only(bottom: 10), child: Material(color: Colors.transparent,
    child: InkWell(borderRadius: BorderRadius.circular(16), onTap: onTap,
      child: DebtPanel(decorated: merchant, padding: EdgeInsets.symmetric(horizontal: 14, vertical: merchant ? 15 : 12),
        child: Row(children: [DebtIcon(merchant ? Icons.storefront_outlined : Icons.person_outline, size: merchant ? 48 : 42),
          const SizedBox(width: 14), Expanded(child: Text(name, style: DebtStyle.text(c, size: 16, bold: true))),
          const SizedBox(width: 8), const DebtArrow()])))));
}

class DebtOperationTile extends StatelessWidget {
  final Map operation;
  final VoidCallback onTap;

  /// Localized word shown before the number (e.g. "فاتورة"). When null only
  /// the raw number is shown.
  final String? titlePrefix;
  const DebtOperationTile(
      {super.key,
      required this.operation,
      required this.onTap,
      this.titlePrefix});
  @override
  Widget build(BuildContext c) {
    final number = shortDocumentNumber(operation['number']);
    final title = (titlePrefix == null || titlePrefix!.isEmpty)
        ? number
        : '$titlePrefix $number';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: DebtPanel(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            const DebtIcon(Icons.receipt_long_outlined, size: 36),
            const SizedBox(width: 10),
            Expanded(
              flex: 3,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textDirection: TextDirection.ltr,
                        textAlign: TextAlign.start,
                        style: DebtStyle.text(c, size: 13, bold: true)),
                    Text('${operation['date'] ?? ''}'.split('T').first,
                        style:
                            DebtStyle.text(c, size: 11, color: Colors.grey)),
                  ]),
            ),
            const SizedBox(width: 8),
            Flexible(
              flex: 2,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      if ((num.tryParse('${operation['remaining'] ?? 0}') ?? 0) <=
                          0.004)
                        const Padding(
                          padding: EdgeInsetsDirectional.only(end: 4),
                          child: Icon(Icons.check_circle,
                              size: 14, color: Color(0xFF1F9D55)),
                        ),
                      Text(debtAmount(operation['remaining']),
                          textDirection: TextDirection.ltr,
                          style: DebtStyle.text(c,
                              size: 17, bold: true, color: DebtStyle.red)),
                    ]),
                    Text(debtCurrencyLabel('${operation['currency'] ?? ''}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            DebtStyle.text(c, size: 11, color: Colors.grey)),
                  ]),
            ),
            const SizedBox(width: 6),
            const DebtArrow(),
          ]),
        ),
      ),
    );
  }
}

class DebtGroupTile extends StatelessWidget {
  final Map group;
  final String countLabel;
  final VoidCallback onTap;
  final VoidCallback? onEdit;
  const DebtGroupTile({super.key, required this.group, required this.countLabel,
      required this.onTap, this.onEdit});
  @override
  Widget build(BuildContext c) => InkWell(onTap: onTap, borderRadius: BorderRadius.circular(16),
    child: DebtPanel(decorated: true, padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start,
      children: [Row(children: [const DebtIcon(Icons.folder_outlined, size: 36), const SizedBox(width: 8),
        Expanded(child: Text('${group['name'] ?? ''}', style: DebtStyle.text(c, size: 13, bold: true))),
        if (onEdit != null)
          InkWell(
            onTap: onEdit,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.edit_outlined, size: 17,
                  color: DebtStyle.red),
            ),
          ),
      ]),
        const SizedBox(height: 8), Text(countLabel, style: DebtStyle.text(c, size: 11, color: Colors.grey)),
        const Align(alignment: AlignmentDirectional.centerEnd, child: DebtArrow(color: DebtStyle.red)),
      ])));
}

class DebtRetry extends StatelessWidget {
  final String message;
  final VoidCallback retry;
  const DebtRetry({super.key, required this.message, required this.retry});
  @override
  Widget build(BuildContext c) => Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min,
    children: [Text(message, textAlign: TextAlign.center, style: DebtStyle.text(c)), IconButton(onPressed: retry, icon: const Icon(Icons.refresh))])));
}

/// Shared report-period filter (الكل / اليوم / هذا الشهر / بين فترتين) used by
/// BOTH the individual-debts tab and a debt section so the design is identical.
class DebtPeriodFilter extends StatelessWidget {
  final String period;
  final DateTime? from;
  final DateTime? to;
  final Map<String, String> labels;
  final void Function(String period, DateTime? from, DateTime? to) onChanged;
  const DebtPeriodFilter({
    super.key,
    required this.period,
    required this.from,
    required this.to,
    required this.labels,
    required this.onChanged,
  });

  Future<void> _select(BuildContext context, String key) async {
    if (key == 'range') {
      final now = DateTime.now();
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(now.year - 5),
        lastDate: DateTime(now.year + 1, 12, 31),
        initialDateRange: (from != null && to != null)
            ? DateTimeRange(start: from!, end: to!)
            : DateTimeRange(start: DateTime(now.year, now.month, 1), end: now),
      );
      if (picked == null) return;
      onChanged('range', picked.start, picked.end);
      return;
    }
    onChanged(key, null, null);
  }

  @override
  Widget build(BuildContext context) {
    final dark = DebtStyle.dark(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final e in labels.entries) ...[
            _chip(context, dark, e.value, period == e.key,
                () => _select(context, e.key)),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, bool dark, String label, bool active,
      VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: active
                ? DebtStyle.red
                : (dark ? const Color(0xFF2A2026) : Colors.white),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: active
                    ? DebtStyle.red
                    : DebtStyle.red.withAlpha(dark ? 70 : 45)),
            boxShadow: active
                ? [
                    BoxShadow(
                        color: DebtStyle.red.withAlpha(50),
                        blurRadius: 10,
                        offset: const Offset(0, 4))
                  ]
                : null,
          ),
          child: Text(label,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: active
                      ? Colors.white
                      : (dark ? Colors.white70 : DebtStyle.red))),
        ),
      ),
    );
  }
}

/// Shared total-debts hero card (same size/style as the banks «إجمالي الأرصدة»
/// card) with an inline paid (green) / remaining (red) breakdown.
class DebtTotalHeroCard extends StatelessWidget {
  final String? currency;
  final dynamic grand;
  final dynamic paid;
  final dynamic remaining;
  final int fxGaps;
  final String title;
  final String subtitle;
  final String paidLabel;
  final String remainingLabel;
  final String fxGapText;
  final String emptyText;
  final VoidCallback onPickCurrency;
  const DebtTotalHeroCard({
    super.key,
    required this.currency,
    required this.grand,
    required this.paid,
    required this.remaining,
    required this.fxGaps,
    required this.title,
    required this.subtitle,
    required this.paidLabel,
    required this.remainingLabel,
    required this.fxGapText,
    required this.emptyText,
    required this.onPickCurrency,
  });

  @override
  Widget build(BuildContext context) {
    final shown = grand ?? remaining;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            begin: Alignment(-1.0, -1.0),
            end: Alignment(1.5, 1.5),
            colors: [Color(0xFFC01838), DebtStyle.red, Color(0xFF7A1020)]),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: DebtStyle.red.withAlpha(100),
              blurRadius: 32,
              offset: const Offset(0, 12)),
        ],
      ),
      child: Stack(children: [
        Positioned(
            top: -30,
            right: -20,
            child: Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                    shape: BoxShape.circle, color: Colors.white.withAlpha(15)))),
        Positioned(
            bottom: -40,
            left: -10,
            child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                    shape: BoxShape.circle, color: Colors.white.withAlpha(10)))),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                  color: Colors.white.withAlpha(20),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: Colors.white.withAlpha(30))),
              child: const Icon(Icons.account_balance_wallet_outlined,
                  size: 22, color: Colors.white),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Colors.white70)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 11,
                            color: Colors.white.withAlpha(120))),
                  ]),
            ),
            GestureDetector(
              onTap: onPickCurrency,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                    color: Colors.white.withAlpha(25),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withAlpha(40))),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 175),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(debtCurrencyLabel(currency ?? ''),
                          maxLines: 1,
                          style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: Colors.white)),
                    ),
                  ),
                  const Icon(Icons.expand_more, size: 16, color: Colors.white),
                ]),
              ),
            ),
          ]),
          const SizedBox(height: 20),
          if (shown == null)
            Text(fxGaps > 0 ? fxGapText : emptyText,
                style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.white))
          else ...[
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(debtAmount(shown),
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                  const SizedBox(width: 6),
                  Text(debtCurrencyLabel(currency ?? ''),
                      maxLines: 1,
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Colors.white.withAlpha(180))),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: _breakdown(paidLabel, paid,
                    debtCurrencyLabel(currency ?? ''),
                    const Color(0xFF7BF1A8)),
              ),
              Container(width: 1, height: 30, color: Colors.white24),
              const SizedBox(width: 12),
              Expanded(
                child: _breakdown(remainingLabel, remaining,
                    debtCurrencyLabel(currency ?? ''),
                    const Color(0xFFFFC1C1)),
              ),
            ]),
          ],
        ]),
      ]),
    );
  }

  Widget _breakdown(
          String label, dynamic amount, String currency, Color color) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontFamily: 'Cairo', fontSize: 11, color: Colors.white70)),
          const SizedBox(height: 3),
          // Never clip: the amount grows digits and the currency label can be
          // long («ريال يمني قديم»); scale the whole row down to the width.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(debtAmount(amount),
                    textDirection: TextDirection.ltr,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: color)),
                const SizedBox(width: 4),
                Text(currency,
                    maxLines: 1,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withAlpha(200))),
              ],
            ),
          ),
        ],
      );
}
