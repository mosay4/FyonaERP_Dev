import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../../core/receipt_engine/models.dart';
import '../../core/receipt_engine/renderer.dart';
import '../../core/receipt_engine/export.dart';
import '../../core/receipt_engine/config.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import '../../core/responsive/r_api.dart';

class ReceiptOverlay extends ConsumerStatefulWidget {
  final ReceiptData data;
  final DocumentConfig? config;

  const ReceiptOverlay({super.key, required this.data, this.config});

  static Future<void> show(BuildContext context, ReceiptData data, {DocumentConfig? config}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ReceiptOverlay(data: data, config: config),
    );
  }

  @override
  ConsumerState<ReceiptOverlay> createState() => _ReceiptOverlayState();
}

class _ReceiptOverlayState extends ConsumerState<ReceiptOverlay> {
  double _zoom = 1.0;
  Uint8List? _pdfBytes;

  @override
  Widget build(BuildContext context) {
    final config = widget.config ?? ReceiptConfigDefaults.defaultFor(widget.data.type);
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (ctx, scrollController) {
        return Container(
          decoration:  BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
          ),
          child: Column(
            children: [
              _buildHandle(),
              _buildToolbar(config),
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 3.0,
                    child: Padding(
                      padding: EdgeInsets.all(R.spacing(context, 12)),
                      child: Transform.scale(
                        scale: _zoom,
                        child: WidgetReceiptRenderer(data: widget.data, config: config),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHandle() {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 8, bottom: 4),
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: AppColors.textDisabled,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildToolbar(DocumentConfig config) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: R.spacing(context, 12),
        vertical: R.spacing(context, 4),
      ),
      decoration:  BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          _toolButton(Icons.zoom_in, AppLocalizations.of(context).translate('zoomIn'), () {
            setState(() => _zoom = (_zoom + 0.1).clamp(0.5, 3.0));
          }),
          SizedBox(width: R.gap(context)),
          _toolButton(Icons.zoom_out, AppLocalizations.of(context).translate('zoomOut'), () {
            setState(() => _zoom = (_zoom - 0.1).clamp(0.5, 3.0));
          }),
          SizedBox(width: R.gap(context)),
          Text('${(_zoom * 100).toInt()}%', style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), color: AppColors.textSecondary)),
          const Spacer(),
          _toolButton(Icons.open_in_full, AppLocalizations.of(context).translate('coreOpen'), () {
            context.push('/receipt-preview', extra: {'data': widget.data, 'config': config});
          }),
          SizedBox(width: R.gap(context)),
          _toolButton(Icons.picture_as_pdf, 'PDF', _exportPdf),
          SizedBox(width: R.gap(context)),
          _toolButton(Icons.print, AppLocalizations.of(context).translate('print'), _printDoc),
          SizedBox(width: R.gap(context)),
          _toolButton(Icons.share, AppLocalizations.of(context).translate('share'), _shareDoc),
        ],
      ),
    );
  }

  Widget _toolButton(IconData icon, String tooltip, VoidCallback onPressed) {
    return IconButton(
      icon: Icon(icon, size: R.icon(context, 20)),
      onPressed: onPressed,
      tooltip: tooltip,
      color: AppColors.textPrimary,
      style: IconButton.styleFrom(
        backgroundColor: AppColors.surfaceVariant,
        padding: EdgeInsets.all(R.spacing(context, 6)),
      ),
    );
  }

  Future<void> _exportPdf() async {
    try {
      final config = widget.config ?? ReceiptConfigDefaults.defaultFor(widget.data.type);
      _pdfBytes = await exportToPdf(widget.data, config);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).translate('sharedPdfCreatedOk'))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).translate('sharedFailedWithError', params: {'error': e}))),
        );
      }
    }
  }

  Future<void> _printDoc() async {
    try {
      final config = widget.config ?? ReceiptConfigDefaults.defaultFor(widget.data.type);
      await printReceipt(widget.data, config);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).translate('sharedPrintFailed', params: {'error': e}))),
        );
      }
    }
  }

  Future<void> _shareDoc() async {
    try {
      if (_pdfBytes == null) await _exportPdf();
      if (_pdfBytes != null) {
        await shareReceipt(_pdfBytes!, filename: 'receipt_${widget.data.documentNumber}.pdf');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).translate('sharedShareFailed', params: {'error': e}))),
        );
      }
    }
  }
}

