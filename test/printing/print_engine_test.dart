import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/printing/data/escpos.dart';
import 'package:fyona_flutter/features/printing/data/ipp_client.dart';
import 'package:fyona_flutter/features/printing/data/print_engine.dart';
import 'package:fyona_flutter/features/printing/data/printer_link.dart';
import 'package:fyona_flutter/features/printing/domain/printer_models.dart';

import 'support/fake_printers.dart';

/// Engine tests over REAL sockets (a fake ESC/POS printer and a fake IPP
/// printer on 127.0.0.1). The PDF → bitmap step is replaced by a fixed
/// page so the tests need no native PDF renderer.
const _width = 576;
const _height = 300;

Future<List<RasterPage>> _fakeRaster(Uint8List pdf, double dpi) async {
  final rgba = Uint8List(_width * _height * 4);
  for (var y = 0; y < _height; y++) {
    for (var x = 0; x < _width; x++) {
      final i = (y * _width + x) * 4;
      final ink = (x ~/ 8 + y ~/ 8).isEven;
      rgba[i] = rgba[i + 1] = rgba[i + 2] = ink ? 0 : 255;
      rgba[i + 3] = 255;
    }
  }
  return [(rgba: rgba, width: _width, height: _height)];
}

PrintEngine _engine({PrinterLink Function(PrinterDevice)? linkFor}) => PrintEngine(
      raster: _fakeRaster,
      linkFor: linkFor,
      confirmTimeout: const Duration(seconds: 2),
    );

PrinterDevice _net(int port) => PrinterDevice(
    id: 'net:127.0.0.1:$port', name: 'fake', kind: PrinterKind.network, address: '127.0.0.1', port: port);

PrintRequest _req(PrinterDevice p,
        {String fp = 'inv-1', int copies = 1, bool force = false, bool cut = true}) =>
    PrintRequest(
      printer: p,
      paper: PrintPaper.thermal80,
      pdf: () async => Uint8List(0),
      fingerprint: fp,
      copies: copies,
      force: force,
      autoCut: cut,
    );

Future<List<PrintProgress>> _run(PrintEngine e, PrintRequest r) => e.run(r).toList();

void main() {
  group('ESC/POS over a real socket', () {
    test('confirmed only when the printer reports the job finished', () async {
      final printer = await FakeEscPosPrinter.start();
      addTearDown(printer.close);
      final events = await _run(_engine(), _req(_net(printer.port)));
      final last = events.last;
      expect(last.stage, PrintStage.done);
      expect(last.confirmed, isTrue);
      // Real progress, monotonic, never 100% before the end.
      final sending = events.where((e) => e.stage == PrintStage.sending).map((e) => e.fraction).toList();
      expect(sending, isNotEmpty);
      for (var i = 1; i < sending.length; i++) {
        expect(sending[i], greaterThanOrEqualTo(sending[i - 1]));
      }
      expect(sending.last, lessThan(1));
      // Init, raster bands, one cut at the very end.
      expect(printer.count([0x1B, 0x40]), greaterThanOrEqualTo(1));
      expect(printer.count([0x1D, 0x76, 0x30, 0x00]), greaterThan(1)); // banded
      expect(printer.count([0x1D, 0x56, 0x42, 0x00]), 1);
    });

    test('several copies are printed in order with a single final cut', () async {
      final printer = await FakeEscPosPrinter.start();
      addTearDown(printer.close);
      final one = EscPos.rasterBands((await _fakeRaster(Uint8List(0), 0)).first.rgba, _width, _height).length;
      final events = await _run(_engine(), _req(_net(printer.port), copies: 3));
      expect(events.last.stage, PrintStage.done);
      expect(printer.count([0x1D, 0x76, 0x30, 0x00]), one * 3);
      expect(printer.count([0x1D, 0x56, 0x42, 0x00]), 1);
    });

    test('no auto-cut → no cut command at all', () async {
      final printer = await FakeEscPosPrinter.start();
      addTearDown(printer.close);
      await _run(_engine(), _req(_net(printer.port), cut: false));
      expect(printer.count([0x1D, 0x56, 0x42, 0x00]), 0);
    });

    test('a printer that never answers: delivered, but not claimed printed', () async {
      final printer = await FakeEscPosPrinter.start(mode: FakeMode.silent);
      addTearDown(printer.close);
      final events = await _run(_engine(), _req(_net(printer.port)));
      expect(events.last.stage, PrintStage.done);
      expect(events.last.confirmed, isFalse);
      expect(printer.count([0x1D, 0x76, 0x30, 0x00]), greaterThan(0));
    });

    test('out of paper: the reason is reported and nothing is printed', () async {
      final printer = await FakeEscPosPrinter.start(mode: FakeMode.paperOut);
      addTearDown(printer.close);
      final events = await _run(_engine(), _req(_net(printer.port)));
      expect(events.last.stage, PrintStage.failed);
      expect(events.last.error, 'printErrPaper');
      expect(printer.count([0x1D, 0x76, 0x30, 0x00]), 0);
    });

    test('connection lost mid-job: error, and the job is NOT re-sent by itself', () async {
      final printer = await FakeEscPosPrinter.start(mode: FakeMode.silent);
      addTearDown(printer.close);
      final drop = await FakeEscPosPrinter.start(mode: FakeMode.drop, dropAfter: 3000);
      addTearDown(drop.close);
      final events = await _run(_engine(), _req(_net(drop.port)));
      expect(events.last.stage, PrintStage.failed);
      expect(events.last.error, 'printErrLost');
      expect(drop.connections, 1);
    });

    test('nobody listening: a clear connection error', () async {
      final printer = await FakeEscPosPrinter.start();
      final port = printer.port;
      await printer.close();
      final events = await _run(_engine(), _req(_net(port)));
      expect(events.last.stage, PrintStage.failed);
      expect(events.last.error, 'printErrConnect');
    });

    test('reconnects once by itself when the first connection fails', () async {
      final printer = await FakeEscPosPrinter.start();
      addTearDown(printer.close);
      var opens = 0;
      final engine = _engine(linkFor: (d) {
        opens++;
        // First attempt: a port nobody listens on; then the real printer.
        return opens == 1 ? TcpPrinterLink('127.0.0.1', 1) : TcpPrinterLink('127.0.0.1', printer.port);
      });
      final events = await _run(engine, _req(_net(printer.port)));
      expect(opens, 2);
      expect(events.last.stage, PrintStage.done);
      expect(events.last.confirmed, isTrue);
    });
  });

  group('no accidental duplicates', () {
    test('the same document again within seconds needs a confirmation', () async {
      final printer = await FakeEscPosPrinter.start();
      addTearDown(printer.close);
      final engine = _engine();
      final p = _net(printer.port);
      expect((await _run(engine, _req(p))).last.stage, PrintStage.done);
      final again = await _run(engine, _req(p));
      expect(again.last.stage, PrintStage.failed);
      expect(again.last.error, 'printErrDuplicate');
      final cuts = printer.count([0x1D, 0x56, 0x42, 0x00]);
      expect(cuts, 1);
      // Confirmed by the user → prints.
      expect((await _run(engine, _req(p, force: true))).last.stage, PrintStage.done);
      expect(printer.count([0x1D, 0x56, 0x42, 0x00]), 2);
    });

    test('a second job on the same printer while one runs is refused', () async {
      final printer = await FakeEscPosPrinter.start();
      addTearDown(printer.close);
      final engine = _engine();
      final p = _net(printer.port);
      final first = _run(engine, _req(p, fp: 'a'));
      final second = await _run(engine, _req(p, fp: 'b'));
      expect(second.last.error, 'printErrBusy');
      expect((await first).last.stage, PrintStage.done);
    });
  });

  group('IPP (office / A4 printers) over real HTTP', () {
    PrinterDevice ipp(int port, {String? user, String? password}) => PrinterDevice(
        id: 'ipp:127.0.0.1:$port/ipp/print',
        name: 'office',
        kind: PrinterKind.ipp,
        address: '127.0.0.1',
        port: port,
        username: user,
        password: password,
        thermal: false);

    PrintRequest a4(PrinterDevice p) => PrintRequest(
          printer: p,
          paper: PrintPaper.a4,
          pdf: () async => Uint8List.fromList('%PDF-1.4 fake'.codeUnits),
          fingerprint: 'a4-${DateTime.now().microsecondsSinceEpoch}',
        );

    test('PDF printers get the PDF; completion follows the printer job state', () async {
      final server = await FakeIppPrinter.start();
      addTearDown(server.close);
      final events = await _run(_engine(), a4(ipp(server.port)));
      expect(events.last.stage, PrintStage.done);
      expect(events.last.confirmed, isTrue);
      expect(server.documentFormats.single, 'application/pdf');
      expect(String.fromCharCodes(server.documents.single), startsWith('%PDF'));
      expect(server.polls, greaterThanOrEqualTo(2));
    });

    test('printers without PDF get PWG raster', () async {
      final server = await FakeIppPrinter.start(formats: ['image/pwg-raster', 'image/urf']);
      addTearDown(server.close);
      final events = await _run(_engine(), a4(ipp(server.port)));
      expect(events.last.stage, PrintStage.done);
      expect(server.documentFormats.single, 'image/pwg-raster');
      expect(String.fromCharCodes(server.documents.single.sublist(0, 4)), 'RaS2');
    });

    test('credentials are sent; wrong ones give a clear message', () async {
      final server = await FakeIppPrinter.start(user: 'office', password: 'secret');
      addTearDown(server.close);
      final ok = await _run(_engine(), a4(ipp(server.port, user: 'office', password: 'secret')));
      expect(ok.last.stage, PrintStage.done);
      final bad = await _run(_engine(), a4(ipp(server.port, user: 'office', password: 'nope')));
      expect(bad.last.stage, PrintStage.failed);
      expect(bad.last.error, 'printErrAuth');
    });
  });

  group('protocol is chosen automatically', () {
    test('per printer kind and paper', () {
      PrinterDevice d(PrinterKind k, {bool thermal = true}) =>
          PrinterDevice(id: k.name, name: k.name, kind: k, thermal: thermal);
      expect(PrintProtocolX.choose(d(PrinterKind.bluetooth), PrintPaper.thermal58), PrintProtocol.escpos);
      expect(PrintProtocolX.choose(d(PrinterKind.ble), PrintPaper.thermal80), PrintProtocol.escpos);
      expect(PrintProtocolX.choose(d(PrinterKind.usb), PrintPaper.thermal80), PrintProtocol.escpos);
      expect(PrintProtocolX.choose(d(PrinterKind.network), PrintPaper.thermal80), PrintProtocol.escpos);
      expect(PrintProtocolX.choose(d(PrinterKind.network, thermal: false), PrintPaper.a4), PrintProtocol.rawPdf);
      expect(PrintProtocolX.choose(d(PrinterKind.ipp), PrintPaper.a4, ippFormats: {'application/pdf'}),
          PrintProtocol.ippPdf);
      expect(PrintProtocolX.choose(d(PrinterKind.ipp), PrintPaper.a4, ippFormats: {'image/pwg-raster'}),
          PrintProtocol.ippPwg);
      expect(PrintProtocolX.choose(d(PrinterKind.windows), PrintPaper.thermal80), PrintProtocol.windowsRaw);
      expect(PrintProtocolX.choose(d(PrinterKind.windows), PrintPaper.a4), PrintProtocol.osDirectPdf);
    });
  });

  group('ESC/POS building blocks', () {
    test('bands carry the whole image and the status replies parse', () {
      final page = Uint8List(_width * 10 * 4);
      final bands = EscPos.rasterBands(page, _width, 250, bandRows: 96);
      expect(bands, hasLength(3));
      final rows = bands.map((b) => b[6] | (b[7] << 8)).toList();
      expect(rows, [96, 96, 58]);
      expect(EscPos.parseStatus(Uint8List.fromList([0x16, 0x12, 0x12]))!.ready, isTrue);
      final out = EscPos.parseStatus(Uint8List.fromList([0x16, 0x32, 0x72]))!;
      expect(out.paperOut, isTrue);
      expect(EscPos.parseStatus(Uint8List.fromList([0x00, 0x12, 0x12])), isNull);
      final id = [1, 2, 3, 4];
      expect(EscPos.hasProcessIdReply(
          Uint8List.fromList([9, 0x37, 0x22, 0x31, 0x32, 0x33, 0x34, 0x00]), id), isTrue);
    });

    test('PWG raster round trip (decoder per PWG 5102.4)', () {
      const w = 37, h = 5;
      final gray = Uint8List(w * h);
      for (var i = 0; i < gray.length; i++) {
        gray[i] = (i % 7 == 0) ? 0 : (i ~/ w == 2 ? 255 : (i * 13) % 256);
      }
      // Two identical rows to exercise line repeat.
      gray.setRange(w * 4, w * 5, gray.sublist(w * 3, w * 4));
      final enc = PwgRaster.encode([(gray: gray, width: w, height: h)]);
      expect(String.fromCharCodes(enc.sublist(0, 4)), 'RaS2');
      final dec = _decodePwg(enc.sublist(4 + 1796), w, h);
      expect(dec, gray);
    });
  });
}

Uint8List _decodePwg(Uint8List d, int w, int h) {
  final out = Uint8List(w * h);
  var i = 0, y = 0;
  while (y < h) {
    final repeat = d[i++];
    final line = Uint8List(w);
    var x = 0;
    while (x < w) {
      final c = d[i++];
      if (c <= 127) {
        final n = c + 1;
        final v = d[i++];
        line.fillRange(x, x + n, v);
        x += n;
      } else {
        final n = 257 - c;
        line.setRange(x, x + n, d.sublist(i, i + n));
        i += n;
        x += n;
      }
    }
    for (var r = 0; r <= repeat; r++) {
      out.setRange((y + r) * w, (y + r + 1) * w, line);
    }
    y += repeat + 1;
  }
  return out;
}
