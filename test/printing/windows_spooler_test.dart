import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/printing/data/print_engine.dart';
import 'package:fyona_flutter/features/printing/data/printer_discovery.dart';
import 'package:fyona_flutter/features/printing/data/windows_spooler.dart';
import 'package:fyona_flutter/features/printing/domain/printer_models.dart';

import 'support/fake_printers.dart';

/// REAL Windows spooler integration (GitHub Actions, windows-2022): the CI
/// installs a printer named $FYONA_SPOOLER_PRINTER ("Generic / Text Only"
/// driver) on a Standard TCP/IP port pointing at 127.0.0.1:9100, where
/// this test listens. FYONA finds it through EnumPrinters and prints RAW
/// ESC/POS through OpenPrinter / WritePrinter — the bytes must arrive.
void main() {
  final name = Platform.environment['FYONA_SPOOLER_PRINTER'];
  final skip = !Platform.isWindows || name == null || name.isEmpty
      ? 'needs Windows with a test printer (CI)'
      : null;

  test('Windows: discovered through the spooler and printed RAW, no dialog', () async {
    final printer = await FakeEscPosPrinter.start(mode: FakeMode.silent, port: 9100);
    addTearDown(printer.close);

    expect(WindowsSpooler.printers(), contains(name));
    final found = await PrinterDiscovery(sweep: false).discover().toList();
    final device = found.firstWhere((d) => d.kind == PrinterKind.windows && d.name == name);

    final engine = PrintEngine(raster: (pdf, dpi) async {
      const w = 576, h = 200;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i + 3] = 255; // black: every dot printed
      }
      return [(rgba: rgba, width: w, height: h)];
    });
    final events = await engine
        .run(PrintRequest(
          printer: device,
          paper: PrintPaper.thermal80,
          pdf: () async => Uint8List(0),
          fingerprint: 'win-${DateTime.now().microsecondsSinceEpoch}',
        ))
        .toList();
    expect(events.last.stage, PrintStage.done, reason: '${events.last.error}');
    // The spooler cannot read the printer back: delivered, not claimed printed.
    expect(events.last.confirmed, isFalse);

    // The spooler forwards the job to the port a moment later.
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (printer.count([0x1D, 0x76, 0x30, 0x00]) == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    expect(printer.count([0x1B, 0x40]), greaterThanOrEqualTo(1));
    expect(printer.count([0x1D, 0x76, 0x30, 0x00]), greaterThan(0));
    expect(printer.count([0x1D, 0x56, 0x42, 0x00]), 1);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
