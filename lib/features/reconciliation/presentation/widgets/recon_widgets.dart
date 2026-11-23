import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import 'package:flutter/services.dart';
import 'package:hugeicons/hugeicons.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../core_business/data/local_directory/directory_database.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../data/reconciliation_api.dart';

/// Reconciliation status: match (green) / shortage (red) / surplus (amber).
enum ReconStatus { match, short, surplus, none }

ReconStatus statusFromDiff(double diff) {
  if (diff.abs() < 1e-9) return ReconStatus.match;
  return diff < 0 ? ReconStatus.short : ReconStatus.surplus;
}

class ReconStatusChip extends StatelessWidget {
  final ReconStatus status;
  final String label;
  final double fontSize;
  const ReconStatusChip({
    super.key,
    required this.status,
    required this.label,
    this.fontSize = 11,
  });

  (Color, IconData) _style(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    switch (status) {
      case ReconStatus.match:
        return (
          dark ? Color(0xFF66BB6A) : AppColors.success,
          Icons.check_circle_rounded,
        );
      case ReconStatus.short:
        return (
          dark ? Color(0xFFEF5350) : AppColors.danger,
          Icons.trending_down_rounded,
        );
      case ReconStatus.surplus:
        return (
          dark ? Color(0xFFFFB74D) : AppColors.warning,
          Icons.trending_up_rounded,
        );
      case ReconStatus.none:
        return (
          dark ? Colors.white54 : AppColors.textSecondary,
          Icons.circle_outlined,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final (color, icon) = _style(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(24),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withAlpha(120)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: fontSize + 4, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Count-up money/number text (replays only when [end] changes).
class ReconCountUp extends StatefulWidget {
  final num end;
  final String suffix;
  final TextStyle style;
  final Duration duration;
  const ReconCountUp({
    super.key,
    required this.end,
    required this.style,
    this.suffix = '',
    this.duration = const Duration(milliseconds: 800),
  });

  @override
  State<ReconCountUp> createState() => _ReconCountUpState();
}

class _ReconCountUpState extends State<ReconCountUp>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late num _from;
  num? _lastEnd;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.duration);
    _from = 0;
    _lastEnd = widget.end;
    _ctrl.forward();
  }

  @override
  void didUpdateWidget(covariant ReconCountUp old) {
    super.didUpdateWidget(old);
    if (widget.end != _lastEnd) {
      _from = _valueAt(_ctrl.value);
      _lastEnd = widget.end;
      _ctrl.forward(from: 0);
    }
  }

  double _valueAt(double t) {
    final eased = Curves.easeOutCubic.transform(t);
    return _from + (widget.end - _from) * eased;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  static String _fmt(num v) {
    if (v == v.roundToDouble()) {
      return v.round().toString().replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+$)'),
        (m) => '${m[1]},',
      );
    }
    return v.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) => Text(
        '${_fmt(_valueAt(_ctrl.value))}${widget.suffix}',
        style: widget.style,
      ),
    );
  }
}

/// Luxury 3D-lite tilt card: pointer-driven perspective with a springy
/// return, specular sheen that follows the tilt, and a subtle burgundy rim.
class ReconTiltCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double elevation;
  const ReconTiltCard({
    super.key,
    required this.child,
    this.onTap,
    this.elevation = 8,
  });

  @override
  State<ReconTiltCard> createState() => _ReconTiltCardState();
}

class _ReconTiltCardState extends State<ReconTiltCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onTap?.call();
      },
      child: AnimatedScale(
        scale: _pressed ? 0.975 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(dark ? 90 : 22),
                blurRadius: 9,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Stack(
              children: [
                widget.child,
                // Static specular sheen — Positioned.fill so it NEVER stretches
                // the card beyond its content (that extra 132px box was the root
                // cause of the huge empty space under every archive row).
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _SheenPainter(angle: 0, dark: dark),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SheenPainter extends CustomPainter {
  final double angle;
  final bool dark;
  _SheenPainter({required this.angle, required this.dark});

  @override
  void paint(Canvas canvas, Size size) {
    final shift = size.width * (0.5 + angle * 0.9);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(shift - size.width * 0.4, 0),
          Offset(shift + size.width * 0.4, size.height),
          [Colors.white.withAlpha(dark ? 14 : 20), Colors.white.withAlpha(0)],
        ),
    );
  }

  @override
  bool shouldRepaint(covariant _SheenPainter old) => old.angle != angle;
}

/// Elegant confirm dialog for the irreversible settlement actions.
Future<bool> confirmSettlement(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
}) async {
  final res = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Row(
        children: [
          const Icon(Icons.gpp_maybe_rounded, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
      content: Text(
        body,
        style: const TextStyle(fontFamily: 'Cairo', fontSize: 14, height: 1.5),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(
            MaterialLocalizations.of(ctx).cancelButtonLabel,
            style: const TextStyle(fontFamily: 'Cairo'),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
          onPressed: () {
            HapticFeedback.mediumImpact();
            Navigator.pop(ctx, true);
          },
          child: Text(
            confirmLabel,
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
  return res == true;
}

/// Friendly failure used by the scan overlay (honest errors only).
void showReconError(BuildContext context, Object error) {
  final msg = reconErrorMessage(AppLocalizations.of(context), error);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: Colors.white,
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              msg,
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 13),
            ),
          ),
        ],
      ),
      backgroundColor: AppColors.danger,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 4),
    ),
  );
}

String reconErrorMessage(AppLocalizations l10n, Object error) {
  if (error is DioException) {
    final detail = error.response?.data;
    if (detail is Map) {
      final fields = detail['detail'];
      if (fields is String) return fields;
      if (fields is Map && fields['message'] is String) return fields['message'] as String;
    }
  }
  return l10n.translate(switch (error) {
    DirectoryAccessDenied() => 'reconDeviceDenied',
    ReconciliationNotOnDevice() => 'reconDeviceUnavailable',
    BusinessReconciliationChanged() => 'reconDeviceChanged',
    BusinessInventoryCategoryEmpty() => 'reconDeviceNoCountableCategory',
    BusinessInventoryCategoryChanged() => 'reconDeviceCategoryChanged',
    BusinessCashEqualizationPending() => 'reconDeviceCashFinishPending',
    BusinessCashEqualizationMixed() => 'reconDeviceCashSeparateChecks',
    BusinessLedgerError(
      problem: BusinessLedgerProblem.sharedCashRequiresArbitration,
    ) =>
      'reconDeviceSharedCash',
    _ => 'reconCheckFailed',
  });
}

String? reconCashDecisionLabel(Map<String, dynamic>? record) =>
    switch (record?['authority_state']) {
      'queued' => 'reconDeviceCashQueued',
      'suspended' => 'reconDeviceCashSuspended',
      'rejected' => record?['authority_reason'] == 'permissionChanged'
          ? 'reconDeviceCashPermissionChanged' : 'reconDeviceCashChanged',
      _ => null,
    };

/// Real icon-library glyphs for the reconciliation kinds (replacing the old
/// hand-painted drawings): bank · cash · warehouse, in the FYONA burgundy
/// identity. Used in the home cards, bank cards, scope squares and the
/// cinematic overlay.
class ReconGlyph extends StatelessWidget {
  final ReconGlyphKind kind;
  final double size;
  final Color? color;
  const ReconGlyph(this.kind, {super.key, this.size = 40, this.color});

  List<List<dynamic>> get _icon => switch (kind) {
    ReconGlyphKind.bank => HugeIcons.strokeRoundedBank,
    ReconGlyphKind.cash => HugeIcons.strokeRoundedCash01,
    ReconGlyphKind.inventory => HugeIcons.strokeRoundedWarehouse,
  };

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: HugeIcon(
        icon: _icon,
        size: size,
        color: color ?? AppColors.primary,
        strokeWidth: 1.8,
      ),
    );
  }
}

enum ReconGlyphKind { bank, cash, inventory }

/// The reconciliation back-arrow: ALWAYS behaves.
/// - If there is anything to pop → pop (normal flow).
/// - If the navigation stack was reset (e.g. after «مطابقة أخرى» used go) →
///   land on the Business dashboard instead of a dead button.
void reconBack(BuildContext context) {
  if (Navigator.of(context).canPop()) {
    Navigator.of(context).pop();
  } else {
    context.go('/dashboard');
  }
}
