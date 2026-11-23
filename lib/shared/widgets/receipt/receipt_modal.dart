import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:gal/gal.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../../../core/theme/app_colors.dart';
import '../../../features/personal/presentation/providers/receipt_design_models.dart';
import 'receipt_card.dart';
import 'receipt_data.dart';

class ReceiptModal extends StatefulWidget {
  final ReceiptData data;
  final ReceiptDesignPreset? preset;

  const ReceiptModal({super.key, required this.data, this.preset});

  static void show(BuildContext context, ReceiptData data, {
    ReceiptDesignPreset? preset,
    Widget Function(Widget receipt)? protect,
  }) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '',
      barrierColor: Colors.black.withAlpha(200),
      transitionDuration: const Duration(milliseconds: 400),
      pageBuilder: (ctx, anim1, anim2) {
        final receipt = ReceiptModal(data: data, preset: preset);
        return protect?.call(receipt) ?? receipt;
      },
      transitionBuilder: (ctx, anim, secondaryAnim, child) {
        return FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.88, end: 1.0).animate(
              CurvedAnimation(parent: anim, curve: Curves.easeOutBack),
            ),
            child: child,
          ),
        );
      },
    );
  }

  @override
  State<ReceiptModal> createState() => _ReceiptModalState();
}

class _ReceiptModalState extends State<ReceiptModal> {
  final GlobalKey _boundaryKey = GlobalKey();
  bool _isSaving = false;
  bool _isSharing = false;
  bool _isExportingPdf = false;

  Future<Uint8List?> _capture() async {
    final boundary = _boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;
    final image = await boundary.toImage(pixelRatio: 3.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return byteData?.buffer.asUint8List();
  }

  Future<void> _exportPdf() async {
    setState(() => _isExportingPdf = true);
    try {
      final bytes = await _capture();
      if (bytes == null || !mounted) return;
      final doc = pw.Document();
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (_) => pw.Center(
            child: pw.Image(pw.MemoryImage(bytes), fit: pw.BoxFit.contain),
          ),
        ),
      );
      final pdfBytes = await doc.save();
      if (!mounted) return;
      await Printing.sharePdf(
        bytes: Uint8List.fromList(pdfBytes),
        filename: 'receipt.pdf',
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).translate('sharedPdfCreateFailed'), style: TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppColors.danger,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 2),
        ),
      );
    }
    if (mounted) setState(() => _isExportingPdf = false);
  }

  Future<void> _share() async {
    setState(() => _isSharing = true);
    try {
      final bytes = await _capture();
      if (bytes == null || !mounted) return;
      await Share.shareXFiles([XFile.fromData(bytes, mimeType: 'image/png', name: 'receipt.png')]);
    } catch (_) {}
    if (mounted) setState(() => _isSharing = false);
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    try {
      final bytes = await _capture();
      if (bytes == null || !mounted) return;
      await Gal.putImageBytes(bytes, name: 'receipt', album: 'FYONA');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).translate('sharedImageSavedOk'), style: TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).translate('sharedImageSaveFailed'), style: TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppColors.danger,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 2),
        ),
      );
    }
    if (mounted) setState(() => _isSaving = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(25),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white.withAlpha(30), width: 1),
                    ),
                    child: const Icon(Icons.close, color: Colors.white, size: 18),
                  ),
                ),
                const SizedBox(height: 20),
                RepaintBoundary(
                  key: _boundaryKey,
                  child: ReceiptCard(data: widget.data, preset: widget.preset),
                ),
                const SizedBox(height: 28),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _ActionBtn(
                      icon: Icons.picture_as_pdf,
                      label: 'PDF',
                      color: AppColors.danger,
                      isLoading: _isExportingPdf,
                      onTap: _exportPdf,
                    ),
                    _ActionBtn(
                      icon: Icons.save_alt,
                      label: AppLocalizations.of(context).translate('save'),
                      color: AppColors.success,
                      isLoading: _isSaving,
                      onTap: _save,
                    ),
                    _ActionBtn(
                      icon: Icons.share,
                      label: AppLocalizations.of(context).translate('share'),
                      color: AppColors.primary,
                      isLoading: _isSharing,
                      onTap: _share,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool isLoading;
  final VoidCallback onTap;

  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isLoading ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        decoration: BoxDecoration(
          color: color.withAlpha(isLoading ? 40 : 255),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(color: color.withAlpha(isLoading ? 0 : 60), blurRadius: 20, offset: const Offset(0, 8)),
          ],
        ),
        child: isLoading
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: Colors.white, size: 18),
                  const SizedBox(width: 10),
                  Text(label, style: const TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
                ],
              ),
      ),
    );
  }
}
