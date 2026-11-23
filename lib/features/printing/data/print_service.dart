import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../invoices/data/invoice_design_models.dart';
import '../../invoices/presentation/pdf/invoice_pdf.dart';
import '../domain/printer_models.dart';
import 'escpos.dart';

/// Discovers printers, sends ESC/POS thermal jobs over Bluetooth (classic SPP,
/// native channel) and WiFi/LAN (raw TCP :9100), and routes A4 / unsupported
/// devices through the Android system print service. Also persists the
/// preferred printer, paper size and copies (Business scope).
class PrintService {
  static const MethodChannel _ch = MethodChannel('fyona/printing');

  // ── Preferences ──
  static const _kPrinter = 'biz_print_printer';
  static const _kPaper = 'biz_print_paper';
  static const _kCopies = 'biz_print_copies';
  static const _kAutoCut = 'biz_print_autocut';

  Future<PrintPrefs> loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kPrinter);
    PrinterDevice? printer;
    if (raw != null && raw.isNotEmpty) {
      try {
        printer = PrinterDevice.fromJson(
            Map<String, dynamic>.from(_decode(raw)));
      } catch (_) {}
    }
    final paper = PrintPaper.values.firstWhere(
        (x) => x.name == p.getString(_kPaper),
        orElse: () => PrintPaper.thermal80);
    return PrintPrefs(
      printer: printer,
      paper: paper,
      copies: p.getInt(_kCopies) ?? 1,
      autoCut: p.getBool(_kAutoCut) ?? true,
    );
  }

  Future<void> savePrefs(PrintPrefs prefs) async {
    final p = await SharedPreferences.getInstance();
    if (prefs.printer != null) {
      await p.setString(_kPrinter, _encode(prefs.printer!.toJson()));
    }
    await p.setString(_kPaper, prefs.paper.name);
    await p.setInt(_kCopies, prefs.copies);
    await p.setBool(_kAutoCut, prefs.autoCut);
  }

  String _encode(Map<String, dynamic> m) =>
      m.entries.map((e) => '${e.key}=${e.value}').join('&');
  Map<String, dynamic> _decode(String s) {
    final out = <String, dynamic>{};
    for (final part in s.split('&')) {
      final i = part.indexOf('=');
      if (i > 0) out[part.substring(0, i)] = part.substring(i + 1);
    }
    return out;
  }

  // ── Discovery ──

  /// Paired Bluetooth thermal printers (requires Android pairing).
  Future<List<PrinterDevice>> discoverBluetooth() async {
    try {
      final ok = await _ch.invokeMethod<bool>('btIsSupported') ?? false;
      if (!ok) return const [];
      final raw = await _ch.invokeMethod<List<dynamic>>('btBondedDevices');
      return [
        for (final d in (raw ?? const []).whereType<Map>())
          PrinterDevice(
            id: 'bt:${d['address']}',
            name: (d['name'] ?? 'طابعة بلوتوث').toString(),
            kind: PrinterKind.bluetooth,
            address: (d['address'] ?? '').toString(),
          )
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Network printers advertised over mDNS (_pdl-datastream/_printer/_ipp).
  Future<List<PrinterDevice>> discoverNetwork(
      {Duration timeout = const Duration(seconds: 4)}) async {
    final found = <String, PrinterDevice>{};
    final client = MDnsClient();
    try {
      await client.start();
      const services = [
        '_pdl-datastream._tcp.local',
        '_printer._tcp.local',
        '_ipp._tcp.local',
      ];
      for (final svc in services) {
        try {
          await for (final ptr
              in client.lookup<PtrResourceRecord>(
                  ResourceRecordQuery.serverPointer(svc),
                  timeout: timeout)) {
            try {
              await for (final srv in client.lookup<SrvResourceRecord>(
                  ResourceRecordQuery.service(ptr.domainName),
                  timeout: timeout)) {
                final host = srv.target.replaceAll(RegExp(r'\.$'), '');
                String? ip;
                await for (final addr in client.lookup<IPAddressResourceRecord>(
                    ResourceRecordQuery.addressIPv4(host),
                    timeout: timeout)) {
                  ip = addr.address.address;
                  break;
                }
                if (ip == null) continue;
                final key = '$ip:${srv.port}';
                found.putIfAbsent(
                  key,
                  () => PrinterDevice(
                    id: 'net:$key',
                    name: ptr.domainName
                        .replaceAll(svc, '')
                        .replaceAll('.local', '')
                        .replaceAll(RegExp(r'\.$'), ''),
                    kind: PrinterKind.network,
                    address: ip!,
                    port: srv.port,
                  ),
                );
              }
            } catch (_) {}
          }
        } catch (_) {}
      }
    } catch (_) {
    } finally {
      try {
        client.stop();
      } catch (_) {}
    }
    return found.values.toList();
  }

  PrinterDevice manualNetwork(String ip, {int port = 9100, String? name}) =>
      PrinterDevice(
        id: 'net:$ip:$port',
        name: (name == null || name.isEmpty) ? ip : name,
        kind: PrinterKind.network,
        address: ip,
        port: port,
      );

  // ── Rasterization ──

  Future<Uint8List> buildThermalPdf(Map<String, dynamic> invoice,
      InvoiceDesignPreset design, String templateId, bool isPurchase) {
    return buildInvoicePdf(invoice, design,
        templateId: templateId, isPurchase: isPurchase);
  }

  Future<({Uint8List rgba, int width, int height})> rasterize(
      Uint8List pdfBytes) async {
    final pages = await rasterizeAll(pdfBytes);
    return pages.first;
  }

  /// Rasterize EVERY page (thermal invoices are a single tall page; if the
  /// estimater ever falls short, the extra pages are returned so nothing is
  /// lost).
  Future<List<({Uint8List rgba, int width, int height})>> rasterizeAll(
      Uint8List pdfBytes) async {
    final out = <({Uint8List rgba, int width, int height})>[];
    await for (final page in Printing.raster(pdfBytes, dpi: 203)) {
      out.add((rgba: page.pixels, width: page.width, height: page.height));
    }
    return out;
  }

  // ── Transport ──

  static const int _chunk = 4096;

  /// Sends [bytes] to the selected printer in ORDER, in small sequential
  /// batches (thermal receipts can be large). One connection per job.
  Future<PrintOutcome> _sendBytes(PrinterDevice printer, Uint8List bytes) async {
    if (printer.kind == PrinterKind.bluetooth) {
      try {
        final ok = await _ch.invokeMethod<bool>(
            'btConnect', {'address': printer.address});
        if (ok != true) {
          return const PrintOutcome(ok: false, message: 'تعذّر الاتصال بالطابعة');
        }
        for (var i = 0; i < bytes.length; i += _chunk) {
          final end = (i + _chunk) > bytes.length ? bytes.length : i + _chunk;
          final part = Uint8List.fromList(bytes.sublist(i, end));
          await _ch.invokeMethod('btWrite', {'bytes': part});
        }
        return const PrintOutcome(
            ok: true, sentOnly: true, message: 'أُرسلت المهمة للطابعة');
      } on PlatformException catch (e) {
        return PrintOutcome(ok: false, message: e.message ?? 'فشل إرسال البيانات');
      } catch (e) {
        return PrintOutcome(ok: false, message: '$e');
      }
    }
    if (printer.kind == PrinterKind.network) {
      Socket? socket;
      try {
        socket = await Socket.connect(printer.address, printer.port,
            timeout: const Duration(seconds: 6));
        for (var i = 0; i < bytes.length; i += _chunk) {
          final end = (i + _chunk) > bytes.length ? bytes.length : i + _chunk;
          socket.add(bytes.sublist(i, end));
          await socket.flush();
        }
        return const PrintOutcome(
            ok: true, sentOnly: true, message: 'أُرسلت المهمة للطابعة');
      } catch (e) {
        return PrintOutcome(
            ok: false, message: 'تعذّر الاتصال بالطابعة (${printer.address})');
      } finally {
        try {
          await socket?.close();
        } catch (_) {}
      }
    }
    return const PrintOutcome(
        ok: false, message: 'الطابعة المحددة لا تدعم الطباعة المباشرة');
  }

  /// Prints a thermal receipt (58/80) directly via ESC/POS. ALL products are
  /// sent as one continuous receipt (multiple raster pages if needed), copies
  /// are sent in order, and the cut happens ONLY at the end of the whole job
  /// and only when the user enabled auto-cut.
  Future<PrintOutcome> printThermal({
    required Map<String, dynamic> invoice,
    required InvoiceDesignPreset design,
    required bool isPurchase,
    required PrinterDevice printer,
    required String templateId,
    int copies = 1,
    bool autoCut = true,
  }) async {
    try {
      final pdf =
          await buildThermalPdf(invoice, design, templateId, isPurchase);
      final pages = await rasterizeAll(pdf);
      if (pages.isEmpty) {
        return const PrintOutcome(ok: false, message: 'تعذّر تجهيز الفاتورة');
      }
      final perCopy = BytesBuilder(copy: false);
      perCopy.add(EscPos.init());
      for (var i = 0; i < pages.length; i++) {
        perCopy.add(EscPos.rasterFromRgba(
            pages[i].rgba, pages[i].width, pages[i].height));
        if (i < pages.length - 1) perCopy.add(EscPos.feed(2));
      }
      perCopy.add(EscPos.feed(4));
      if (autoCut) perCopy.add(EscPos.cut());
      final oneCopy = perCopy.toBytes();

      final totalCopies = copies < 1 ? 1 : (copies > 999 ? 999 : copies);
      final buffer = BytesBuilder(copy: false);
      for (var c = 0; c < totalCopies; c++) {
        buffer.add(oneCopy);
      }
      return await _sendBytes(printer, buffer.toBytes());
    } catch (e) {
      return PrintOutcome(ok: false, message: 'فشل تجهيز الفاتورة: $e');
    }
  }

  /// A4 (or any printer the OS can see) via the Android system print service.
  Future<PrintOutcome> printSystem({
    required Map<String, dynamic> invoice,
    required InvoiceDesignPreset design,
    required bool isPurchase,
    required String templateId,
  }) async {
    try {
      final pdf = await buildInvoicePdf(invoice, design,
          templateId: templateId, isPurchase: isPurchase);
      await Printing.layoutPdf(onLayout: (_) async => pdf);
      return const PrintOutcome(
          ok: true, sentOnly: true, message: 'أُرسلت المهمة للطباعة');
    } catch (e) {
      return PrintOutcome(ok: false, message: '$e');
    }
  }

  /// Small test receipt on a connected thermal printer.
  Future<PrintOutcome> testPrint({
    required PrinterDevice printer,
    required String templateId,
    required InvoiceDesignPreset design,
  }) async {
    final sample = <String, dynamic>{
      'invoice_number': 'TEST-0001',
      'invoice_type': 'sale',
      'customer_name': 'طباعة تجريبية',
      'invoice_date': DateTime.now().toIso8601String(),
      'currency': 'SAR',
      'subtotal': 10,
      'discount_amount': 0,
      'tax_amount': 0,
      'total': 10,
      'paid_amount': 10,
      'balance': 0,
      'items': [
        {
          'description': 'منتج تجريبي',
          'quantity': 1,
          'unit_price': 10,
          'discount': 0,
          'total': 10,
        },
      ],
    };
    return printThermal(
      invoice: sample,
      design: design,
      isPurchase: false,
      printer: printer,
      templateId: templateId.contains('thermal')
          ? templateId
          : (templateId.contains('return') ? 'return_thermal' : 'thermal'),
      copies: 1,
    );
  }
}
