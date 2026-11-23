import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';

/// A dedicated signature box: the merchant signs with a finger. Undo (last
/// stroke) and clear are at the TOP-LEFT; cancel and save at the BOTTOM.
///
/// The drawing canvas inverts with the theme for visibility (dark app → white
/// box & black ink, light app → black box & white ink), but the SAVED image is
/// always the signature in BLACK on a TRANSPARENT background so it composites
/// cleanly on the white invoice.
class SignaturePadDialog extends StatefulWidget {
  const SignaturePadDialog({super.key});
  static Future<Uint8List?> show(BuildContext context) {
    return showDialog<Uint8List>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const SignaturePadDialog(),
    );
  }

  @override
  State<SignaturePadDialog> createState() => _SignaturePadDialogState();
}

class _SignaturePadDialogState extends State<SignaturePadDialog> {
  final _boxKey = GlobalKey();
  final List<List<Offset>> _strokes = [];
  bool _drawing = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final boxColor = dark ? Colors.white : Colors.black;
    final inkColor = dark ? Colors.black : Colors.white;

    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(l10n.translate('sigDirect'),
              style: const TextStyle(
                  fontFamily: 'Cairo', fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          // The drawing layer is BELOW; the tool buttons are ON TOP so taps on
          // undo/clear are never swallowed by the pan gesture.
          Container(
            key: _boxKey,
            width: double.infinity,
            height: 220,
            decoration: BoxDecoration(
              color: boxColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.primary, width: 1.5),
            ),
            child: Stack(children: [
              Positioned.fill(
                child: GestureDetector(
                  onPanStart: (d) => setState(() {
                    _strokes.add([d.localPosition]);
                    _drawing = true;
                  }),
                  onPanUpdate: (d) => setState(() {
                    if (_strokes.isNotEmpty) _strokes.last.add(d.localPosition);
                  }),
                  onPanEnd: (_) => setState(() => _drawing = false),
                  child: CustomPaint(
                    painter: _PadPainter(strokes: _strokes, color: inkColor),
                  ),
                ),
              ),
              Positioned(
                left: 2,
                top: 2,
                child: Row(children: [
                  _toolBtn(
                    icon: Icons.undo_rounded,
                    tooltip: l10n.translate('sigUndo'),
                    enabled: _strokes.isNotEmpty,
                    onTap: () => setState(() {
                      if (_strokes.isNotEmpty) _strokes.removeLast();
                    }),
                  ),
                  _toolBtn(
                    icon: Icons.delete_outline_rounded,
                    tooltip: l10n.translate('sigClear'),
                    enabled: _strokes.isNotEmpty,
                    onTap: () => setState(() => _strokes.clear()),
                  ),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12)),
                child: Text(l10n.translate('cancel'),
                    style: const TextStyle(fontFamily: 'Cairo')),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: _strokes.isEmpty ? null : _save,
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 12)),
                child: Text(l10n.translate('save'),
                    style: const TextStyle(
                        fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _toolBtn({
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: tooltip,
        onPressed: enabled ? onTap : null,
        icon: Icon(icon, size: 18),
        color: AppColors.primary,
        disabledColor: AppColors.textDisabled,
      ),
    );
  }

  Future<void> _save() async {
    if (_strokes.isEmpty) return;
    try {
      final box =
          _boxKey.currentContext?.findRenderObject() as RenderBox?;
      final size = box?.size ?? const Size(320, 220);
      const scale = 3.0;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.scale(scale);
      final paint = Paint()
        ..color = Colors.black
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      for (final stroke in _strokes) {
        if (stroke.length == 1) {
          canvas.drawCircle(
              stroke.first,
              1.6,
              Paint()
                ..color = Colors.black
                ..style = PaintingStyle.fill);
          continue;
        }
        final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
        for (var i = 1; i < stroke.length; i++) {
          path.lineTo(stroke[i].dx, stroke[i].dy);
        }
        canvas.drawPath(path, paint);
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(
          (size.width * scale).round(), (size.height * scale).round());
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (!mounted) return;
      Navigator.pop(context, data?.buffer.asUint8List());
    } catch (_) {
      if (mounted) Navigator.pop(context);
    }
  }
}

class _PadPainter extends CustomPainter {
  final List<List<Offset>> strokes;
  final Color color;
  _PadPainter({required this.strokes, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final stroke in strokes) {
      if (stroke.length == 1) {
        canvas.drawCircle(
            stroke.first,
            1.6,
            Paint()
              ..color = color
              ..style = PaintingStyle.fill);
        continue;
      }
      final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
      for (var i = 1; i < stroke.length; i++) {
        path.lineTo(stroke[i].dx, stroke[i].dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PadPainter old) => true;
}
