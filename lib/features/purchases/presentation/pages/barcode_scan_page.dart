import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../../../../core/localization/app_localizations.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../shared/services/scan_sfx.dart';

/// Minimal camera barcode scanner used by the purchase item lookup.
///
/// It only reads a code and pops it back (or null when cancelled). Permission
/// is requested by the plugin on first frame; if the merchant denies it the
/// error builder shows a friendly message and the caller keeps manual entry
/// working — the app never crashes.
class BarcodeScanPage extends StatefulWidget {
  const BarcodeScanPage({super.key});

  @override
  State<BarcodeScanPage> createState() => _BarcodeScanPageState();
}

class _BarcodeScanPageState extends State<BarcodeScanPage> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    // Preload the scanner beeps while the camera warms up, so the decode
    // beep is instantaneous (in sync with the frame the code is read).
    unawaited(ScanSfx.warmUp());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    String? code;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v != null && v.trim().isNotEmpty) {
        code = v.trim();
        break;
      }
    }
    if (code == null) return;
    _handled = true;
    // Real handheld-scanner beep on a successful decode. The shared player
    // keeps playing after the pop.
    unawaited(ScanSfx.success());
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(l10n.translate('purScanBarcode'),
            style: const TextStyle(
                fontFamily: 'Cairo',
                fontWeight: FontWeight.w700,
                // Theme titleTextStyle (black in light mode) overrides
                // foregroundColor — force white on the black scanner bar.
                color: Colors.white)),
        actions: [
          IconButton(
            tooltip: l10n.translate('purCameraTorch'),
            onPressed: () => _controller.toggleTorch(),
            icon: const Icon(Icons.flash_on_rounded),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.no_photography_outlined,
                          color: Colors.white70, size: 48),
                      const SizedBox(height: 12),
                      Text(
                        l10n.translate('purCameraDenied'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontFamily: 'Cairo',
                            color: Colors.white,
                            fontSize: 15),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.tonal(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(l10n.translate('purManualEntry'),
                            style: const TextStyle(fontFamily: 'Cairo')),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          // Simple framing guide that matches the current design language.
          IgnorePointer(
            child: Center(
              child: Container(
                width: 240,
                height: 140,
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.primary, width: 3),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
