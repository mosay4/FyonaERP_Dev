import 'dart:async';
import 'dart:typed_data';

import 'package:permission_handler/permission_handler.dart';
import 'dart:io';

import '../../invoices/data/invoice_design_models.dart';
import '../../invoices/presentation/pdf/invoice_pdf.dart';
import '../domain/printer_models.dart';
import 'print_engine.dart';
import 'printer_discovery.dart';
import 'printer_store.dart';

/// The Print Center's single entry point: printers of this device and
/// branch ([PrinterStore]), discovery ([PrinterDiscovery]) and printing
/// ([PrintEngine]). Everything runs on the device — no server, no internet.
class PrintService {
  PrintService({PrinterStore? store, PrintEngine? engine, PrinterDiscovery Function()? discovery})
      : store = store ?? PrinterStore(),
        engine = engine ?? PrintEngine(),
        _discovery = discovery ?? PrinterDiscovery.new;

  final PrinterStore store;
  final PrintEngine engine;
  final PrinterDiscovery Function() _discovery;

  Future<PrintPrefs> loadPrefs() => store.load();
  Future<void> savePrefs(PrintPrefs prefs) => store.save(prefs);
  Future<List<PrinterDevice>> savedPrinters() => store.saved();
  Future<void> forget(String id) => store.forget(id);

  /// Bluetooth (Android 12+) needs the nearby-devices grant to scan.
  Future<void> ensurePermissions() async {
    if (!Platform.isAndroid) return;
    try {
      await [Permission.bluetoothScan, Permission.bluetoothConnect].request();
    } catch (_) {}
  }

  Stream<PrinterDevice> discover() => _discovery().discover();

  PrinterDevice manualNetwork(String host,
      {int port = 9100, String? name, bool ipp = false, String path = '/ipp/print',
      String? username, String? password, bool thermal = true}) {
    final h = host.trim();
    return ipp
        ? PrinterDevice(
            id: 'ipp:$h:$port$path',
            name: (name == null || name.isEmpty) ? h : name,
            kind: PrinterKind.ipp,
            address: h,
            port: port,
            path: path,
            username: username,
            password: password,
            thermal: false)
        : PrinterDevice(
            id: 'net:$h:$port',
            name: (name == null || name.isEmpty) ? h : name,
            kind: PrinterKind.network,
            address: h,
            port: port,
            thermal: thermal);
  }

  Future<Uint8List> buildPdf(Map<String, dynamic> invoice,
          InvoiceDesignPreset design, String templateId, bool isPurchase) =>
      buildInvoicePdf(invoice, design, templateId: templateId, isPurchase: isPurchase);

  /// Prints [invoice] on [printer]; see [PrintEngine.run] for the events.
  Stream<PrintProgress> print({
    required Map<String, dynamic> invoice,
    required InvoiceDesignPreset design,
    required bool isPurchase,
    required PrinterDevice printer,
    required PrintPaper paper,
    required String templateId,
    int copies = 1,
    bool autoCut = true,
    bool force = false,
  }) {
    final id = '${invoice['id'] ?? invoice['invoice_number'] ?? invoice.hashCode}';
    return engine.run(PrintRequest(
      printer: printer,
      paper: paper,
      pdf: () => buildPdf(invoice, design, templateId, isPurchase),
      copies: copies,
      autoCut: autoCut,
      force: force,
      fingerprint: '$id|$templateId|$copies|${printer.id}',
      jobName: 'FYONA ${invoice['invoice_number'] ?? ''}'.trim(),
    ));
  }

  /// A short sample receipt (never counted as a duplicate).
  Stream<PrintProgress> testPrint({
    required PrinterDevice printer,
    required PrintPaper paper,
    required String templateId,
    required InvoiceDesignPreset design,
  }) {
    final sample = sampleInvoice();
    return engine.run(PrintRequest(
      printer: printer,
      paper: paper,
      pdf: () => buildPdf(sample, design, templateId, false),
      fingerprint: 'test|${DateTime.now().microsecondsSinceEpoch}',
      jobName: 'FYONA test',
    ));
  }

  static Map<String, dynamic> sampleInvoice() => <String, dynamic>{
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
}
