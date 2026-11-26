import 'dart:typed_data';

/// What the printer said about itself (ESC/POS real-time status).
class EscPosStatus {
  final bool online;
  final bool coverOpen;
  final bool paperOut;
  final bool paperNearEnd;
  final bool error;
  const EscPosStatus({
    this.online = true,
    this.coverOpen = false,
    this.paperOut = false,
    this.paperNearEnd = false,
    this.error = false,
  });

  bool get ready => online && !coverOpen && !paperOut && !error;
}

/// ESC/POS command set + a banded raster (GS v 0) builder.
///
/// Receipts are printed as a bitmap rasterized from the SAME thermal PDF used
/// for the on-screen preview, so Arabic, RTL, logos, QR and barcodes are
/// pixel-perfect on every ESC/POS printer (text code pages are unreliable for
/// Arabic). The image is sent in horizontal bands: cheap printers with small
/// buffers never overflow, and every band is real progress.
class EscPos {
  static Uint8List init() => Uint8List.fromList([0x1B, 0x40]);

  /// Feed [n] lines.
  static Uint8List feed([int n = 1]) =>
      Uint8List.fromList(List.filled(n, 0x0A));

  /// Full cut (GS V 66 0) — feeds to the cutter then cuts.
  static Uint8List cut() => Uint8List.fromList([0x1D, 0x56, 0x42, 0x00]);

  /// Partial cut (GS V 1).
  static Uint8List cutPartial() => Uint8List.fromList([0x1D, 0x56, 0x01]);

  /// Real-time status request DLE EOT n (1 printer, 2 offline cause,
  /// 4 paper sensor). Answered immediately, even with a full buffer.
  static Uint8List statusRequest(int n) => Uint8List.fromList([0x10, 0x04, n]);

  /// "Tell me when everything before this is printed": GS ( H fn 48 with a
  /// 4-byte process id. Printers that support it (Epson TM and compatibles)
  /// answer `37 22 d1 d2 d3 d4 00` only after the preceding data is done.
  static Uint8List processIdRequest(List<int> id) {
    assert(id.length == 4);
    return Uint8List.fromList(
        [0x1D, 0x28, 0x48, 0x06, 0x00, 0x30, 0x30, ...id.map((b) => 0x30 + (b % 10))]);
  }

  /// The answer to [processIdRequest] inside [bytes] (any position).
  static bool hasProcessIdReply(Uint8List bytes, List<int> id) {
    final want = [0x37, 0x22, ...id.map((b) => 0x30 + (b % 10)), 0x00];
    outer:
    for (var i = 0; i + want.length <= bytes.length; i++) {
      for (var j = 0; j < want.length; j++) {
        if (bytes[i + j] != want[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  /// Parses the replies to DLE EOT 1, 2 and 4 (one byte each, in order).
  /// Each status byte has bit 4 set and bits 0, 1 and 7 clear (0x12 mask).
  static EscPosStatus? parseStatus(Uint8List? reply) {
    if (reply == null || reply.length < 3) return null;
    bool valid(int b) => (b & 0x93) == 0x12;
    final s1 = reply[0], s2 = reply[1], s4 = reply[2];
    if (!valid(s1) || !valid(s2) || !valid(s4)) return null;
    return EscPosStatus(
      online: (s1 & 0x08) == 0,
      coverOpen: (s2 & 0x04) != 0,
      paperOut: (s2 & 0x20) != 0 || (s4 & 0x60) == 0x60,
      paperNearEnd: (s4 & 0x0C) == 0x0C,
      error: (s2 & 0x40) != 0,
    );
  }

  /// 1-bit rows of an RGBA8888 image (dark pixels print). Width is padded
  /// to whole bytes.
  static Uint8List packRows(Uint8List rgba, int width, int height,
      {int threshold = 170}) {
    final bytesPerRow = (width + 7) >> 3;
    final out = Uint8List(bytesPerRow * height);
    for (var y = 0; y < height; y++) {
      final rowStart = y * width * 4;
      final o = y * bytesPerRow;
      for (var x = 0; x < width; x++) {
        final i = rowStart + x * 4;
        if (i + 3 >= rgba.length) break;
        if (rgba[i + 3] < 100) continue; // transparent => white
        final lum = (rgba[i] * 299 + rgba[i + 1] * 587 + rgba[i + 2] * 114) ~/ 1000;
        if (lum < threshold) out[o + (x >> 3)] |= 0x80 >> (x & 7);
      }
    }
    return out;
  }

  /// GS v 0 for [rows] packed rows of [bytesPerRow] bytes.
  static Uint8List rasterBlock(Uint8List packed, int bytesPerRow, int rows) {
    final b = BytesBuilder(copy: false)
      ..add([
        0x1D, 0x76, 0x30, 0x00,
        bytesPerRow & 0xFF, (bytesPerRow >> 8) & 0xFF,
        rows & 0xFF, (rows >> 8) & 0xFF,
      ])
      ..add(packed);
    return b.toBytes();
  }

  /// Single GS v 0 image (kept for callers of the old API).
  static Uint8List rasterFromRgba(Uint8List rgba, int width, int height,
      {int threshold = 170}) {
    final packed = packRows(rgba, width, height, threshold: threshold);
    return rasterBlock(packed, (width + 7) >> 3, height);
  }

  /// The image as consecutive GS v 0 bands of at most [bandRows] rows.
  static List<Uint8List> rasterBands(Uint8List rgba, int width, int height,
      {int bandRows = 96, int threshold = 170}) {
    final bpr = (width + 7) >> 3;
    final packed = packRows(rgba, width, height, threshold: threshold);
    final out = <Uint8List>[];
    for (var y = 0; y < height; y += bandRows) {
      final rows = (y + bandRows > height) ? height - y : bandRows;
      out.add(rasterBlock(
          Uint8List.sublistView(packed, y * bpr, (y + rows) * bpr), bpr, rows));
    }
    return out;
  }

  /// Build a full job: init, raster, feed, cut.
  static Uint8List job(Uint8List rgba, int width, int height,
      {bool autoCut = true, int feedAfter = 4}) {
    final b = BytesBuilder(copy: false);
    b.add(init());
    for (final band in rasterBands(rgba, width, height)) {
      b.add(band);
    }
    b.add(feed(feedAfter));
    if (autoCut) b.add(cut());
    return b.toBytes();
  }
}
