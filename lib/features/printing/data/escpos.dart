import 'dart:typed_data';

/// Minimal ESC/POS command set + a raster (GS v 0) builder.
///
/// We print receipts as a bitmap rasterized from the SAME thermal PDF used for
/// on-screen preview, so Arabic, RTL, QR and barcodes are pixel-perfect on
/// every ESC/POS printer (text code-pages are unreliable for Arabic).
class EscPos {
  static Uint8List init() => Uint8List.fromList([0x1B, 0x40]);

  /// Feed [n] lines.
  static Uint8List feed([int n = 1]) =>
      Uint8List.fromList(List.filled(n, 0x0A));

  /// Full cut (GS V 66 0).
  static Uint8List cut() => Uint8List.fromList([0x1D, 0x56, 0x42, 0x00]);

  /// Partial cut (GS V 1).
  static Uint8List cutPartial() => Uint8List.fromList([0x1D, 0x56, 0x01]);

  /// GS v 0 raster: `rgba` must be RGBA8888, length == width*height*4.
  /// Dark pixels become printed dots.
  static Uint8List rasterFromRgba(
    Uint8List rgba,
    int width,
    int height, {
    int threshold = 170,
  }) {
    final bytesPerRow = (width + 7) >> 3;
    final out = BytesBuilder(copy: false);
    // Header: GS v 0 m xL xH yL yH
    out.add([
      0x1D, 0x76, 0x30, 0x00,
      bytesPerRow & 0xFF, (bytesPerRow >> 8) & 0xFF,
      height & 0xFF, (height >> 8) & 0xFF,
    ]);
    final row = Uint8List(bytesPerRow);
    for (var y = 0; y < height; y++) {
      row.fillRange(0, bytesPerRow, 0);
      final rowStart = y * width * 4;
      for (var x = 0; x < width; x++) {
        final i = rowStart + x * 4;
        if (i + 3 >= rgba.length) break;
        final a = rgba[i + 3];
        if (a < 100) continue; // transparent => white
        final r = rgba[i];
        final g = rgba[i + 1];
        final b = rgba[i + 2];
        final lum = (r * 299 + g * 587 + b * 114) ~/ 1000;
        if (lum < threshold) {
          row[x >> 3] |= 0x80 >> (x & 7);
        }
      }
      out.add(row);
    }
    return out.toBytes();
  }

  /// Build a full job: init, feed, raster, feed, cut.
  static Uint8List job(Uint8List rgba, int width, int height,
      {bool autoCut = true, int feedAfter = 4}) {
    final b = BytesBuilder(copy: false);
    b.add(init());
    b.add(rasterFromRgba(rgba, width, height));
    b.add(feed(feedAfter));
    if (autoCut) b.add(cut());
    return b.toBytes();
  }
}
