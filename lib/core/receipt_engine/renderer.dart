import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../responsive/r_api.dart';
import 'models.dart';
import 'cards.dart';
import 'templates.dart';
import 'watermark.dart';
import 'config.dart';

class PdfFonts {
  static pw.Font? regular;
  static pw.Font? bold;
  static Future<void> ensure() async {
    if (regular != null) return;
    regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-400.ttf'));
    bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-700.ttf'));
  }
}

class ReceiptRenderer {
  final ReceiptData data;
  final DocumentConfig config;

  ReceiptRenderer({required this.data, required this.config});
}

class WidgetReceiptRenderer extends StatelessWidget {
  final ReceiptData data;
  final DocumentConfig config;

  const WidgetReceiptRenderer({super.key, required this.data, required this.config});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: config.canvas.width,
      decoration: BoxDecoration(
        color: config.colors.cardBackground,
        borderRadius: BorderRadius.circular(config.canvas.borderRadius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(config.canvas.borderRadius),
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.all(R.spacing(context, config.canvas.padding)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: _buildCards(context),
              ),
            ),
            if (config.visibility.showWatermark)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: WatermarkPainter(config: config.watermark),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildCards(BuildContext context) {
    final cardOrder = TemplateRegistry.cardOrderFor(data.type);
    final cards = <Widget>[];
    for (final name in cardOrder) {
      final builder = CardRegistry.getWidget(name);
      if (builder != null) {
        cards.add(builder(context, data, config));
      }
    }
    return cards;
  }

  static WidgetReceiptRenderer fromData(ReceiptData data, {DocumentConfig? config}) {
    return WidgetReceiptRenderer(
      data: data,
      config: config ?? ReceiptConfigDefaults.defaultFor(data.type),
    );
  }
}

class PdfReceiptRenderer {
  final ReceiptData data;
  final DocumentConfig config;

  PdfReceiptRenderer({required this.data, required this.config});

  pw.Document buildPdf() {
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat(
          config.canvas.width + config.canvas.padding * 2,
          PdfPageFormat.a4.height,
        ),
        margin: pw.EdgeInsets.all(config.canvas.padding),
        build: (pw.Context context) {
          return [
            pw.Stack(
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                  children: _buildCards(),
                ),
                if (config.visibility.showWatermark)
                  pw.Positioned.fill(
                    child: buildPdfWatermark(config.watermark),
                  ),
              ],
            ),
          ];
        },
      ),
    );
    return doc;
  }

  List<pw.Widget> _buildCards() {
    final cardOrder = TemplateRegistry.cardOrderFor(data.type);
    final cards = <pw.Widget>[];
    for (final name in cardOrder) {
      final builder = CardRegistry.getPdf(name);
      if (builder != null) {
        cards.add(builder(data, config));
      }
    }
    return cards;
  }

  Future<List<int>> save() async {
    await PdfFonts.ensure();
    return buildPdf().save();
  }
}


