import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../../core/receipt_engine/models.dart';
import '../../core/receipt_engine/renderer.dart';
import '../../core/receipt_engine/export.dart';
import '../../core/receipt_engine/config.dart';
import '../../core/theme/app_colors.dart';
import '../../core/responsive/r_api.dart';

class ReceiptPreviewScreen extends ConsumerStatefulWidget {
  final ReceiptData data;
  final DocumentConfig? config;

  const ReceiptPreviewScreen({super.key, required this.data, this.config});

  @override
  ConsumerState<ReceiptPreviewScreen> createState() => _ReceiptPreviewScreenState();
}

class _ReceiptPreviewScreenState extends ConsumerState<ReceiptPreviewScreen> {
  double _zoom = 1.0;
  Uint8List? _pdfBytes;
  bool _loadingPdf = false;

  @override
  Widget build(BuildContext context) {
    final config = widget.config ?? ReceiptConfigDefaults.defaultFor(widget.data.type);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).translate('sharedDocPreview'), style: TextStyle(fontFamily: 'Cairo')),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            onPressed: _exportPdf,
            tooltip: AppLocalizations.of(context).translate('exportPdf'),
          ),
          IconButton(
            icon: const Icon(Icons.image),
            onPressed: _exportImage,
            tooltip: AppLocalizations.of(context).translate('exportImage'),
          ),
          IconButton(
            icon: const Icon(Icons.print),
            onPressed: _printDoc,
            tooltip: AppLocalizations.of(context).translate('print'),
          ),
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: _shareDoc,
            tooltip: AppLocalizations.of(context).translate('share'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.all(R.spacing(context, 8)),
            child: Row(
              children: [
                Text(AppLocalizations.of(context).translate('sharedZoom'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), color: AppColors.textPrimary)),
                Expanded(
                  child: Slider(
                    value: _zoom,
                    min: 0.5,
                    max: 2.0,
                    divisions: 30,
                    activeColor: AppColors.primary,
                    inactiveColor: AppColors.border,
                    label: '${(_zoom * 100).toInt()}%',
                    onChanged: (v) => setState(() => _zoom = v),
                  ),
                ),
                Text('${(_zoom * 100).toInt()}%', style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), color: AppColors.textSecondary)),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 3.0,
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
  }

  Future<void> _exportPdf() async {
    if (_loadingPdf) return;
    setState(() => _loadingPdf = true);
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
          SnackBar(content: Text(AppLocalizations.of(context).translate('sharedPdfCreateFailedWithError', params: {'error': e}))),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingPdf = false);
    }
  }

  Future<void> _exportImage() async {
    try {
      final config = widget.config ?? ReceiptConfigDefaults.defaultFor(widget.data.type);
      await exportToImage(widget.data, config, context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).translate('sharedImageExportOk'))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).translate('sharedImageExportFailed', params: {'error': e}))),
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

