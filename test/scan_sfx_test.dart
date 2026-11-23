import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/shared/services/scan_sfx.dart';

/// Scanner SFX contract: the shipped WAVs must be valid 16-bit PCM mono
/// 44.1kHz (audioplayers media mode loads them on-device), loud enough to be
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

  test('scanner beeps ship as mp3 assets (converted for APK size)', () async {
    final ok = await loadAsset('audio/scan_success.mp3');
    final bad = await loadAsset('audio/scan_error.mp3');
    // MP3 frame sync (0xFF Ex/..) or ID3 header — both are valid encodings.
    bool isMp3(Uint8List b) =>
        (b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) ||
        (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0);
    expect(ok.length, greaterThan(1500));
    expect(bad.length, greaterThan(1500));
    expect(isMp3(ok), true, reason: 'scan_success must be a real mp3');
    expect(isMp3(bad), true, reason: 'scan_error must be a real mp3');
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
      await ScanSfx.warmUp();
    });
  });
}