import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/shared/services/scan_sfx.dart';

/// Scanner SFX contract: the shipped WAVs must be valid 16-bit PCM mono
/// 22.05kHz (audioplayers media mode loads them on-device), loud enough to be
/// heard, and the service must fire without ever throwing.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  Future<Uint8List> loadAsset(String asset) async {
    late Uint8List bytes;
    await binding.runAsync(() async {
      bytes = (await rootBundle.load('assets/$asset')).buffer.asUint8List();
    });
    return bytes;
  }

  test('product / barcode / invoice cues ship as short 22.05 kHz WAVs',
      () async {
    for (final name in const [
      'barcode_capture',
      'product_alert',
      'product_select',
      'invoice_done',
    ]) {
      final b = await loadAsset('audio/$name.wav');
      final h = ByteData.sublistView(b);
      expect(String.fromCharCodes(b.sublist(0, 4)), 'RIFF', reason: name);
      expect(String.fromCharCodes(b.sublist(8, 12)), 'WAVE', reason: name);
      expect(h.getUint16(22, Endian.little), 1, reason: '$name mono');
      expect(h.getUint32(24, Endian.little), 22050, reason: '$name rate');
      expect(h.getUint16(34, Endian.little), 16, reason: '$name 16-bit');
      expect(b.length, inInclusiveRange(2000, 25 * 1024), reason: name);
    }
  });

  test('recon motion sounds ship as mp3 assets', () async {
    final scan = await loadAsset('audio/recon_scan.mp3');
    final crystal = await loadAsset('audio/recon_crystal.mp3');
    expect(scan.length, greaterThan(8000)); // 4s composition
    expect(crystal.length, greaterThan(3000)); // 1.3s chime
  });

  test('ScanSfx fire paths never throw (platform channels mocked)', () async {
    await binding.runAsync(() async {
      await ScanSfx.success();
      await ScanSfx.error();
      await ScanSfx.select();
      await ScanSfx.invoiceDone();
      await ScanSfx.warmUp();
    });
  });
}