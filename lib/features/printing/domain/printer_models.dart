import 'package:flutter/material.dart';

/// Paper size for printing.
enum PrintPaper { thermal58, thermal80, a4 }

extension PrintPaperX on PrintPaper {
  bool get isThermal => this != PrintPaper.a4;
  double get widthMm =>
      this == PrintPaper.thermal58 ? 58 : (this == PrintPaper.thermal80 ? 80 : 210);

  /// Printable dots across the head at 203 dpi (thermal only).
  int get dots => this == PrintPaper.thermal58 ? 384 : 576;
  String get templateId => switch (this) {
        PrintPaper.thermal58 => 'thermal58',
        PrintPaper.thermal80 => 'thermal',
        PrintPaper.a4 => 'paper',
      };
  String get labelKey => switch (this) {
        PrintPaper.thermal58 => 'printPaper58',
        PrintPaper.thermal80 => 'printPaper80',
        PrintPaper.a4 => 'printPaperA4',
      };
  IconData get icon => switch (this) {
        PrintPaper.thermal58 => Icons.receipt_outlined,
        PrintPaper.thermal80 => Icons.receipt_long_outlined,
        PrintPaper.a4 => Icons.description_outlined,
      };
}

/// How a printer is reached.
///
/// * [bluetooth] — classic Bluetooth SPP (Android).
/// * [ble] — Bluetooth Low Energy GATT write (Android, iOS).
/// * [network] — raw TCP socket, usually port 9100 (every platform).
/// * [ipp] — Internet Printing Protocol over HTTP :631 (every platform).
/// * [usb] — USB host bulk transfer (Android).
/// * [windows] — a printer installed in Windows (spooler, RAW data).
/// * [system] — the operating system print service (last resort only).
enum PrinterKind { bluetooth, ble, network, ipp, usb, windows, system }

extension PrinterKindX on PrinterKind {
  String get labelKey => switch (this) {
        PrinterKind.bluetooth => 'printKindBluetooth',
        PrinterKind.ble => 'printKindBle',
        PrinterKind.network => 'printKindNetwork',
        PrinterKind.ipp => 'printKindIpp',
        PrinterKind.usb => 'printKindUsb',
        PrinterKind.windows => 'printKindWindows',
        PrinterKind.system => 'printKindSystem',
      };
  IconData get icon => switch (this) {
        PrinterKind.bluetooth => Icons.bluetooth,
        PrinterKind.ble => Icons.bluetooth_searching,
        PrinterKind.network => Icons.lan_outlined,
        PrinterKind.ipp => Icons.wifi,
        PrinterKind.usb => Icons.usb,
        PrinterKind.windows => Icons.desktop_windows_outlined,
        PrinterKind.system => Icons.print_outlined,
      };

  /// Printed straight from FYONA (no system dialog, no other app).
  bool get direct => this != PrinterKind.system;
}

/// The language spoken to the printer — chosen automatically per printer
/// and paper (see [PrintProtocolX.choose]).
enum PrintProtocol {
  /// ESC/POS raster (thermal receipt printers, 58 / 80 mm).
  escpos,

  /// IPP Print-Job with a PDF document (office / A4 printers).
  ippPdf,

  /// IPP Print-Job with PWG raster (IPP Everywhere printers without PDF).
  ippPwg,

  /// PDF straight to a raw port (printers with a PDF interpreter on 9100).
  rawPdf,

  /// Windows spooler, RAW bytes (ESC/POS for receipt printers).
  windowsRaw,

  /// Windows / macOS / iOS direct PDF to an installed printer, no dialog.
  osDirectPdf,

  /// Operating-system print dialog (only when nothing direct is possible).
  systemDialog,
}

class PrinterDevice {
  /// Stable identity: `bt:<mac>`, `ble:<id>`, `net:<ip>:<port>`,
  /// `ipp:<ip>:<port><path>`, `usb:<vid>:<pid>`, `win:<name>`, `system`.
  final String id;
  final String name;
  final PrinterKind kind;
  final String address;
  final int port;

  /// IPP resource path (e.g. `/ipp/print`).
  final String path;

  /// Optional IPP credentials (HTTP Basic), kept on this device only.
  final String? username;
  final String? password;

  /// What the printer is for (decides the protocol when both fit).
  final bool thermal;

  const PrinterDevice({
    required this.id,
    required this.name,
    required this.kind,
    this.address = '',
    this.port = 9100,
    this.path = '/ipp/print',
    this.username,
    this.password,
    this.thermal = true,
  });

  PrinterDevice copyWith({String? name, String? username, String? password}) =>
      PrinterDevice(
        id: id,
        name: name ?? this.name,
        kind: kind,
        address: address,
        port: port,
        path: path,
        username: username ?? this.username,
        password: password ?? this.password,
        thermal: thermal,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'address': address,
        'port': port,
        'path': path,
        if (username != null) 'username': username,
        if (password != null) 'password': password,
        'thermal': thermal,
      };

  factory PrinterDevice.fromJson(Map<String, dynamic> j) => PrinterDevice(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        kind: PrinterKind.values.firstWhere((k) => k.name == j['kind'],
            orElse: () => PrinterKind.system),
        address: (j['address'] ?? '').toString(),
        port: j['port'] is num
            ? (j['port'] as num).toInt()
            : int.tryParse('${j['port'] ?? ''}') ?? 9100,
        path: (j['path'] ?? '/ipp/print').toString(),
        username: j['username']?.toString(),
        password: j['password']?.toString(),
        thermal: j['thermal'] is bool ? j['thermal'] as bool : '${j['thermal']}' != 'false',
      );

  @override
  bool operator ==(Object other) => other is PrinterDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

extension PrintProtocolX on PrintProtocol {
  /// Picks the protocol for [printer] and [paper]. [ippFormats] are the
  /// document formats the printer announced (IPP), when known.
  static PrintProtocol choose(PrinterDevice printer, PrintPaper paper,
      {Set<String>? ippFormats}) {
    switch (printer.kind) {
      case PrinterKind.bluetooth:
      case PrinterKind.ble:
      case PrinterKind.usb:
        return PrintProtocol.escpos;
      case PrinterKind.network:
        return paper.isThermal || printer.thermal
            ? PrintProtocol.escpos
            : PrintProtocol.rawPdf;
      case PrinterKind.ipp:
        final f = ippFormats;
        if (f == null || f.contains('application/pdf')) return PrintProtocol.ippPdf;
        if (f.contains('image/pwg-raster')) return PrintProtocol.ippPwg;
        return PrintProtocol.ippPdf;
      case PrinterKind.windows:
        return paper.isThermal ? PrintProtocol.windowsRaw : PrintProtocol.osDirectPdf;
      case PrinterKind.system:
        return PrintProtocol.systemDialog;
    }
  }
}

/// Persisted print preferences (per device and branch).
class PrintPrefs {
  final PrinterDevice? printer;
  final PrintPaper paper;
  final int copies;
  final bool autoCut;
  const PrintPrefs({
    this.printer,
    this.paper = PrintPaper.thermal80,
    this.copies = 1,
    this.autoCut = true,
  });
  PrintPrefs copyWith({
    PrinterDevice? printer,
    bool clearPrinter = false,
    PrintPaper? paper,
    int? copies,
    bool? autoCut,
  }) =>
      PrintPrefs(
        printer: clearPrinter ? null : (printer ?? this.printer),
        paper: paper ?? this.paper,
        copies: copies ?? this.copies,
        autoCut: autoCut ?? this.autoCut,
      );
}

/// Stage of a print job, in order.
enum PrintStage { preparing, connecting, sending, finishing, done, failed }

/// Live progress of a job.
///
/// [fraction] is real: bytes handed to the printer (ESC/POS / raw), or the
/// job state reported by the printer (IPP). [confirmed] is true only when
/// the printer itself reported the job finished — never assumed.
class PrintProgress {
  final PrintStage stage;
  final double fraction;
  final bool confirmed;
  final String? error;
  const PrintProgress(this.stage,
      {this.fraction = 0, this.confirmed = false, this.error});

  bool get finished => stage == PrintStage.done || stage == PrintStage.failed;
}

/// Outcome of a print attempt. [sentOnly] = the data reached the printer
/// but it does not report completion (no false "printed").
class PrintOutcome {
  final bool ok;
  final bool sentOnly;
  final bool duplicate;
  final String message;
  const PrintOutcome({
    required this.ok,
    required this.message,
    this.sentOnly = false,
    this.duplicate = false,
  });
}
