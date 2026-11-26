import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:printing/printing.dart';

import '../domain/printer_models.dart';
import 'escpos.dart';
import 'ipp_client.dart';
import 'printer_link.dart';
import 'windows_spooler.dart';

/// Why a job did not print (an l10n key + an optional technical detail).
class PrintFailure {
  final String key;
  final String? detail;
  const PrintFailure(this.key, [this.detail]);
}

/// One job for [PrintEngine.run].
class PrintRequest {
  final PrinterDevice printer;
  final PrintPaper paper;

  /// The document as PDF (the same one the preview shows).
  final Future<Uint8List> Function() pdf;
  final int copies;
  final bool autoCut;

  /// Identity of WHAT is printed (e.g. invoice id + template + copies):
  /// the same fingerprint again within [PrintEngine.duplicateWindow] needs
  /// an explicit confirmation ([force]).
  final String fingerprint;
  final bool force;
  final String jobName;

  const PrintRequest({
    required this.printer,
    required this.paper,
    required this.pdf,
    required this.fingerprint,
    this.copies = 1,
    this.autoCut = true,
    this.force = false,
    this.jobName = 'FYONA',
  });
}

/// Rasterized page for the printer.
typedef RasterPage = ({Uint8List rgba, int width, int height});

/// FYONA's print engine — 100% on the device (no server, no internet).
///
/// Picks the protocol for each printer ([PrintProtocolX.choose]), prepares
/// the document at the paper's real resolution, sends it with real progress,
/// asks the printer whether it really finished (ESC/POS process id, IPP job
/// state) and only then reports "printed". It never prints the same job
/// twice by accident: one job per printer at a time, a repeat of the same
/// document within a few seconds needs a confirmation, and a connection lost
/// mid-job is never silently re-sent.
class PrintEngine {
  PrintEngine({
    PrinterLink Function(PrinterDevice)? linkFor,
    Future<List<RasterPage>> Function(Uint8List pdf, double dpi)? raster,
    IppClient Function(PrinterDevice)? ippFor,
    this.duplicateWindow = const Duration(seconds: 8),
    this.confirmTimeout,
  })  : _linkFor = linkFor ?? defaultLink,
        _raster = raster ?? rasterizePdf,
        _ippFor = ippFor ?? defaultIpp;

  final PrinterLink Function(PrinterDevice) _linkFor;
  final Future<List<RasterPage>> Function(Uint8List pdf, double dpi) _raster;
  final IppClient Function(PrinterDevice) _ippFor;
  final Duration duplicateWindow;

  /// Test seam: how long to wait for the printer's "finished" answer.
  final Duration? confirmTimeout;

  final Set<String> _busy = {};
  final Map<String, DateTime> _recent = {};

  /// Bluetooth / USB links stay open between jobs (reconnecting costs
  /// seconds); a stale one is reopened automatically.
  final Map<String, PrinterLink> _kept = {};

  static PrinterLink defaultLink(PrinterDevice d) => switch (d.kind) {
        PrinterKind.network => TcpPrinterLink(d.address, d.port),
        PrinterKind.windows => WindowsSpoolerLink(d.address),
        _ => NativePrinterLink(d),
      };

  static IppClient defaultIpp(PrinterDevice d) => IppClient(d.address,
      port: d.port, path: d.path, username: d.username, password: d.password);

  static Future<List<RasterPage>> rasterizePdf(Uint8List pdf, double dpi) async {
    final out = <RasterPage>[];
    await for (final page in Printing.raster(pdf, dpi: dpi)) {
      out.add((rgba: page.pixels, width: page.width, height: page.height));
    }
    return out;
  }

  /// True while [printer] has a job running.
  bool isBusy(PrinterDevice printer) => _busy.contains(printer.id);

  /// Was the same document printed moments ago?
  bool isRecentDuplicate(String fingerprint) {
    final at = _recent[fingerprint];
    return at != null && DateTime.now().difference(at) < duplicateWindow;
  }

  Future<void> dispose() async {
    for (final l in _kept.values) {
      await l.close();
    }
    _kept.clear();
  }

  /// Runs one job. The last event is `done` (with [PrintProgress.confirmed]
  /// true only when the printer said so) or `failed` (with an l10n key in
  /// [PrintProgress.error]).
  Stream<PrintProgress> run(PrintRequest r) {
    final out = StreamController<PrintProgress>();
    () async {
      void emit(PrintProgress p) {
        if (!out.isClosed) out.add(p);
      }

      if (!r.force && isRecentDuplicate(r.fingerprint)) {
        emit(const PrintProgress(PrintStage.failed, error: 'printErrDuplicate'));
        await out.close();
        return;
      }
      if (!_busy.add(r.printer.id)) {
        emit(const PrintProgress(PrintStage.failed, error: 'printErrBusy'));
        await out.close();
        return;
      }
      try {
        emit(const PrintProgress(PrintStage.preparing));
        final protocol = r.printer.kind == PrinterKind.ipp
            ? await _ippProtocol(r.printer)
            : PrintProtocolX.choose(r.printer, r.paper);
        final result = await _dispatch(protocol, r, emit);
        _recent[r.fingerprint] = DateTime.now();
        emit(PrintProgress(PrintStage.done, fraction: 1, confirmed: result));
      } on PrintFailure catch (f) {
        emit(PrintProgress(PrintStage.failed, error: f.key));
      } on PrinterLinkException catch (e) {
        emit(PrintProgress(PrintStage.failed, error: _linkKey(e)));
      } on IppException catch (e) {
        emit(PrintProgress(PrintStage.failed,
            error: e.status == 0x0403 ? 'printErrAuth' : 'printErrRefused'));
      } on SocketException {
        emit(const PrintProgress(PrintStage.failed, error: 'printErrConnect'));
      } on TimeoutException {
        emit(const PrintProgress(PrintStage.failed, error: 'printErrConnect'));
      } catch (_) {
        emit(const PrintProgress(PrintStage.failed, error: 'printErrPrepare'));
      } finally {
        _busy.remove(r.printer.id);
        await out.close();
      }
    }();
    return out.stream;
  }

  static String _linkKey(PrinterLinkException e) => switch (e.code) {
        'permission' => 'printErrPermission',
        'unsupported' => 'printErrUnsupported',
        'lost' || 'write' => 'printErrLost',
        _ => 'printErrConnect',
      };

  Future<PrintProtocol> _ippProtocol(PrinterDevice p) async {
    try {
      final attrs = await _ippFor(p).printerAttributes();
      final formats = {
        for (final f in attrs.printer['document-format-supported'] ?? const [])
          '$f'.toLowerCase(),
      };
      return PrintProtocolX.choose(p, PrintPaper.a4, ippFormats: formats);
    } on IppException catch (e) {
      if (e.status == 0x0403) rethrow;
      return PrintProtocol.ippPdf;
    }
  }

  /// Returns whether the printer confirmed the job is finished.
  Future<bool> _dispatch(PrintProtocol protocol, PrintRequest r,
      void Function(PrintProgress) emit) async {
    switch (protocol) {
      case PrintProtocol.escpos:
      case PrintProtocol.windowsRaw:
        return _escpos(r, emit);
      case PrintProtocol.ippPdf:
        return _ipp(r, emit, pwg: false);
      case PrintProtocol.ippPwg:
        return _ipp(r, emit, pwg: true);
      case PrintProtocol.rawPdf:
        return _raw(await r.pdf(), r, emit);
      case PrintProtocol.osDirectPdf:
        final pdf = await r.pdf();
        emit(const PrintProgress(PrintStage.sending, fraction: .3));
        final ok = await Printing.directPrintPdf(
          printer: Printer(url: r.printer.address, name: r.printer.name),
          onLayout: (_) async => pdf,
          name: r.jobName,
        );
        if (!ok) throw const PrintFailure('printErrRefused');
        return false; // handed to the OS spooler; it does not report back
      case PrintProtocol.systemDialog:
        final pdf = await r.pdf();
        final ok = await Printing.layoutPdf(onLayout: (_) async => pdf, name: r.jobName);
        if (!ok) throw const PrintFailure('printErrCancelled');
        return false;
    }
  }

  // ── ESC/POS ──

  /// The receipt as ESC/POS bands at the printer's exact width.
  Future<List<Uint8List>> escposBands(PrintRequest r) async {
    final pdf = await r.pdf();
    final paper = r.paper.isThermal ? r.paper : PrintPaper.thermal80;
    // PDF width (mm) → dots across the head.
    final dpi = paper.dots / (paper.widthMm / 25.4);
    final pages = await _raster(pdf, dpi);
    if (pages.isEmpty) throw const PrintFailure('printErrPrepare');
    final bands = <Uint8List>[];
    for (final p in pages) {
      bands.addAll(EscPos.rasterBands(_fit(p, paper.dots).rgba,
          math.min(p.width, paper.dots), p.height));
    }
    return bands;
  }

  /// Crops a page wider than the head (centered) — never wraps lines.
  static RasterPage _fit(RasterPage p, int dots) {
    if (p.width <= dots) return p;
    final left = (p.width - dots) ~/ 2;
    final out = Uint8List(dots * p.height * 4);
    for (var y = 0; y < p.height; y++) {
      out.setRange(y * dots * 4, (y + 1) * dots * 4, p.rgba, (y * p.width + left) * 4);
    }
    return (rgba: out, width: dots, height: p.height);
  }

  Future<bool> _escpos(PrintRequest r, void Function(PrintProgress) emit) async {
    final bands = await escposBands(r);
    final copies = r.copies.clamp(1, 999);
    final total = bands.fold<int>(0, (s, b) => s + b.length) * copies;

    emit(const PrintProgress(PrintStage.connecting));
    final link = await _open(r.printer);
    var sent = 0;
    try {
      // Before printing: no paper / cover open → say so, print nothing.
      final before = await _status(link);
      if (before != null && !before.ready) throw PrintFailure(_statusKey(before));

      for (var c = 0; c < copies; c++) {
        await link.write(EscPos.init());
        for (final band in bands) {
          final base = sent;
          await link.write(band, onSent: (n) {
            emit(PrintProgress(PrintStage.sending,
                fraction: total == 0 ? 1 : ((base + n) / total).clamp(0, .97)));
          });
          sent += band.length;
        }
        await link.write(EscPos.feed(4));
        // Cut only at the very end of the whole job.
        if (r.autoCut && c == copies - 1) await link.write(EscPos.cut());
      }
      emit(const PrintProgress(PrintStage.finishing, fraction: .98));
      return await _confirm(link, total);
    } on PrinterLinkException catch (e) {
      _kept.remove(r.printer.id);
      await link.close();
      // Lost mid-job: never re-send by itself (that could print twice).
      if (sent > 0 && e.code != 'permission') throw const PrintFailure('printErrLost');
      rethrow;
    } finally {
      if (!_keepOpen(r.printer)) await link.close();
    }
  }

  bool _keepOpen(PrinterDevice p) =>
      p.kind == PrinterKind.bluetooth || p.kind == PrinterKind.usb;

  /// Opens (or reuses) the link; one automatic reconnect when the first
  /// attempt fails — nothing was printed yet, so it is safe.
  Future<PrinterLink> _open(PrinterDevice p) async {
    final kept = _kept[p.id];
    if (kept != null && kept.isOpen) return kept;
    _kept.remove(p.id);
    var link = _linkFor(p);
    try {
      await link.open();
    } on PrinterLinkException catch (e) {
      if (e.code == 'permission' || e.code == 'unsupported') rethrow;
      await link.close();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      link = _linkFor(p);
      await link.open();
    }
    if (_keepOpen(p)) _kept[p.id] = link;
    return link;
  }

  Future<EscPosStatus?> _status(PrinterLink link) async {
    if (!link.canRead) return null;
    await link.read(timeout: const Duration(milliseconds: 1)); // drain
    await link.write(Uint8List.fromList([
      ...EscPos.statusRequest(1),
      ...EscPos.statusRequest(2),
      ...EscPos.statusRequest(4),
    ]));
    final reply = await link.read(timeout: const Duration(milliseconds: 700));
    if (reply == null || reply.length < 3) return null;
    return EscPos.parseStatus(Uint8List.sublistView(reply, reply.length - 3));
  }

  static String _statusKey(EscPosStatus s) => s.paperOut
      ? 'printErrPaper'
      : s.coverOpen
          ? 'printErrCover'
          : s.online
              ? 'printErrPrinter'
              : 'printErrOffline';

  /// Waits for the printer's own "finished" (GS ( H process id). Printers
  /// that do not support it answer the real-time status instead: data
  /// delivered and printer fine → `false` (sent, not claimed printed).
  Future<bool> _confirm(PrinterLink link, int bytes) async {
    if (!link.canRead) return false;
    final id = [1 + DateTime.now().millisecond % 9, 2, 3, 4];
    await link.write(EscPos.processIdRequest(id));
    // ~ 8 KB/s of raster on slow heads, plus mechanics.
    final wait = confirmTimeout ??
        Duration(milliseconds: (4000 + bytes / 8).clamp(4000, 30000).round());
    final deadline = DateTime.now().add(wait);
    final got = BytesBuilder();
    while (DateTime.now().isBefore(deadline)) {
      final r = await link.read(timeout: const Duration(milliseconds: 500));
      if (r == null) {
        // Silence: printers without process ids never answer.
        if (got.isEmpty &&
            DateTime.now().isAfter(deadline.subtract(wait ~/ 2))) {
          break;
        }
        continue;
      }
      got.add(r);
      if (EscPos.hasProcessIdReply(got.toBytes(), id)) return true;
    }
    final after = await _status(link);
    if (after != null && !after.ready) throw PrintFailure(_statusKey(after));
    return false;
  }

  // ── Raw PDF (port 9100) ──
  Future<bool> _raw(Uint8List data, PrintRequest r, void Function(PrintProgress) emit) async {
    emit(const PrintProgress(PrintStage.connecting));
    final link = await _open(r.printer);
    try {
      final copies = r.copies.clamp(1, 999);
      final total = data.length * copies;
      for (var c = 0; c < copies; c++) {
        await link.write(data, onSent: (n) {
          emit(PrintProgress(PrintStage.sending,
              fraction: ((c * data.length + n) / total).clamp(0, .97)));
        });
      }
      return false;
    } finally {
      if (!_keepOpen(r.printer)) await link.close();
    }
  }

  // ── IPP ──
  Future<bool> _ipp(PrintRequest r, void Function(PrintProgress) emit,
      {required bool pwg}) async {
    final pdf = await r.pdf();
    Uint8List doc = pdf;
    if (pwg) {
      final pages = await _raster(pdf, 300);
      doc = PwgRaster.encode([
        for (final p in pages)
          (gray: PwgRaster.grayFromRgba(p.rgba, p.width, p.height),
            width: p.width, height: p.height),
      ]);
    }
    emit(const PrintProgress(PrintStage.connecting));
    final ipp = _ippFor(r.printer);
    emit(const PrintProgress(PrintStage.sending, fraction: .2));
    final jobId = await ipp.printJob(doc,
        format: pwg ? 'image/pwg-raster' : 'application/pdf',
        jobName: r.jobName,
        copies: r.copies.clamp(1, 999));
    emit(const PrintProgress(PrintStage.sending, fraction: .45));
    if (jobId == 0) return false;
    // Follow the printer's own job state.
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final s = await ipp.jobState(jobId);
      switch (s.state) {
        case IppJobState.completed:
          return true;
        case IppJobState.canceled:
          throw const PrintFailure('printErrCancelled');
        case IppJobState.aborted:
          throw const PrintFailure('printErrPrinter');
        case IppJobState.stopped:
        case IppJobState.held:
          throw const PrintFailure('printErrPrinter');
        case IppJobState.processing:
          emit(PrintProgress(PrintStage.sending,
              fraction: (.55 + .1 * s.impressions).clamp(.55, .95)));
        default:
          emit(const PrintProgress(PrintStage.sending, fraction: .5));
      }
    }
    return false;
  }
}
