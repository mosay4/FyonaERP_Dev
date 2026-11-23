import 'package:flutter/material.dart';

/// Paper size for printing.
enum PrintPaper { thermal58, thermal80, a4 }

extension PrintPaperX on PrintPaper {
  bool get isThermal => this != PrintPaper.a4;
  double get widthMm =>
      this == PrintPaper.thermal58 ? 58 : (this == PrintPaper.thermal80 ? 80 : 210);
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
enum PrinterKind { bluetooth, network, system }

extension PrinterKindX on PrinterKind {
  String get labelKey => switch (this) {
        PrinterKind.bluetooth => 'printKindBluetooth',
        PrinterKind.network => 'printKindNetwork',
        PrinterKind.system => 'printKindSystem',
      };
  IconData get icon => switch (this) {
        PrinterKind.bluetooth => Icons.bluetooth,
        PrinterKind.network => Icons.wifi,
        PrinterKind.system => Icons.print_outlined,
      };
}

class PrinterDevice {
  final String id; // mac | ip:port | 'system'
  final String name;
  final PrinterKind kind;
  final String address;
  final int port;
  const PrinterDevice({
    required this.id,
    required this.name,
    required this.kind,
    this.address = '',
    this.port = 9100,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'address': address,
        'port': port,
      };

  factory PrinterDevice.fromJson(Map<String, dynamic> j) => PrinterDevice(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        kind: PrinterKind.values.firstWhere(
            (k) => k.name == j['kind'],
            orElse: () => PrinterKind.system),
        address: (j['address'] ?? '').toString(),
        port: (j['port'] as num?)?.toInt() ?? 9100,
      );
}

/// Persisted print preferences (Business scope).
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

/// Outcome of a print attempt. [sentOnly] = the bytes were handed to the
/// transport successfully but the printer does not confirm completion.
class PrintOutcome {
  final bool ok;
  final bool sentOnly;
  final String message;
  const PrintOutcome({
    required this.ok,
    required this.message,
    this.sentOnly = false,
  });
}
