import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/printing/data/escpos.dart';

void main() {
  test('ESC/POS raster encodes GS v 0 with correct header and rows', () {
    // 10x2 pixels, all black (RGBA 0,0,0,255).
    const w = 10, h = 2;
    final rgba = Uint8List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      rgba[i * 4] = 0;
      rgba[i * 4 + 1] = 0;
      rgba[i * 4 + 2] = 0;
      rgba[i * 4 + 3] = 255;
    }
    final out = EscPos.rasterFromRgba(rgba, w, h);
    final bytesPerRow = (w + 7) ~/ 8; // 2
    expect(bytesPerRow, 2);
    // header 8 bytes + 2 rows * 2 bytes
    expect(out.length, 8 + bytesPerRow * h);
    // GS v 0 m=0
    expect(out.sublist(0, 4), [0x1D, 0x76, 0x30, 0x00]);
    expect(out[4], bytesPerRow); // xL
    expect(out[5], 0); // xH
    expect(out[6], h); // yL
    expect(out[7], 0); // yH
    // first row: first 10 bits set => 0xFF, 0xC0
    expect(out[8], 0xFF);
    expect(out[9], 0xC0);
  });

  test('ESC/POS job includes init and cut', () {
    final rgba = Uint8List(8 * 8 * 4); // all transparent => white
    final job = EscPos.job(rgba, 8, 8, autoCut: true, feedAfter: 2);
    // init ESC @
    expect(job.sublist(0, 2), [0x1B, 0x40]);
    // ends with cut GS V 66 0
    expect(job.sublist(job.length - 4), [0x1D, 0x56, 0x42, 0x00]);
  });
}
