import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:printing/printing.dart';
import 'models.dart';
import 'renderer.dart';

Future<Uint8List> exportToPdf(ReceiptData data, DocumentConfig config) async {
  final renderer = PdfReceiptRenderer(data: data, config: config);
  final pdfBytes = await renderer.save();
  return Uint8List.fromList(pdfBytes);
}

Future<Uint8List> exportToImage(ReceiptData data, DocumentConfig config, BuildContext context) async {
  final boundaryKey = GlobalKey();
  final receiptWidget = RepaintBoundary(
    key: boundaryKey,
    child: WidgetReceiptRenderer(data: data, config: config),
  );
  final overlay = OverlayEntry(
    builder: (ctx) => Positioned(
      top: -5000,
      left: -5000,
      child: SizedBox(
        width: config.canvas.width,
        child: Material(child: receiptWidget),
      ),
    ),
  );
  Overlay.of(context).insert(overlay);
  await Future.delayed(const Duration(milliseconds: 300));
  try {
    final boundary = boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return Uint8List(0);
    final image = await boundary.toImage(pixelRatio: 3.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    overlay.remove();
    return byteData?.buffer.asUint8List() ?? Uint8List(0);
  } catch (e) {
    overlay.remove();
    rethrow;
  }
}

Future<void> printReceipt(ReceiptData data, DocumentConfig config) async {
  final pdfBytes = await exportToPdf(data, config);
  await Printing.layoutPdf(
    onLayout: (format) async => pdfBytes,
    name: 'receipt_${data.documentNumber}.pdf',
  );
}

Future<void> shareReceipt(Uint8List pdfBytes, {String? filename}) async {
  await Printing.sharePdf(
    bytes: pdfBytes,
    filename: filename ?? 'receipt.pdf',
  );
}
