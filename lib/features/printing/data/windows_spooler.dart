import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'printer_link.dart';

/// Printers installed in Windows, through the spooler (winspool.drv) — USB,
/// Bluetooth, network or any port Windows knows. Bytes go RAW (ESC/POS for
/// receipt printers), so nothing opens: no dialog, no other app.
abstract final class WindowsSpooler {
  static bool get available => Platform.isWindows;

  /// Names of the local and connected printers.
  static List<String> printers() {
    if (!available) return const [];
    final needed = calloc<Uint32>();
    final returned = calloc<Uint32>();
    const flags = PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS;
    try {
      EnumPrinters(flags, nullptr, 4, nullptr, 0, needed, returned);
      if (needed.value == 0) return const [];
      final buffer = calloc<Uint8>(needed.value);
      try {
        if (EnumPrinters(flags, nullptr, 4, buffer, needed.value, needed, returned) == 0) {
          return const [];
        }
        final infos = buffer.cast<PRINTER_INFO_4>();
        return [
          for (var i = 0; i < returned.value; i++)
            infos[i].pPrinterName.toDartString(),
        ];
      } finally {
        calloc.free(buffer);
      }
    } finally {
      calloc.free(needed);
      calloc.free(returned);
    }
  }

  /// The Windows default printer, when there is one.
  static String? defaultPrinter() {
    if (!available) return null;
    final size = calloc<Uint32>()..value = 512;
    final name = wsalloc(512);
    try {
      return GetDefaultPrinter(name, size) != 0 ? name.toDartString() : null;
    } finally {
      free(name);
      calloc.free(size);
    }
  }
}

/// One RAW document on a Windows printer. The bytes are spooled as they are
/// written; [close] ends the document (the spooler then prints it).
class WindowsSpoolerLink implements PrinterLink {
  WindowsSpoolerLink(this.printerName, {this.documentName = 'FYONA'});

  final String printerName;
  final String documentName;
  int _handle = 0;
  bool _docOpen = false;

  @override
  bool get isOpen => _handle != 0;

  @override
  bool get canRead => false;

  @override
  Future<void> open() async {
    if (!WindowsSpooler.available) {
      throw const PrinterLinkException('unsupported', 'not Windows');
    }
    final name = printerName.toNativeUtf16();
    final handle = calloc<IntPtr>();
    final doc = calloc<DOC_INFO_1>();
    final docName = documentName.toNativeUtf16();
    final raw = 'RAW'.toNativeUtf16();
    try {
      if (OpenPrinter(name, handle, nullptr) == 0) {
        throw PrinterLinkException('connect', 'OpenPrinter failed (${GetLastError()})');
      }
      _handle = handle.value;
      doc.ref
        ..pDocName = docName
        ..pOutputFile = nullptr
        ..pDatatype = raw;
      if (StartDocPrinter(_handle, 1, doc) == 0) {
        final err = GetLastError();
        ClosePrinter(_handle);
        _handle = 0;
        throw PrinterLinkException('connect', 'StartDocPrinter failed ($err)');
      }
      _docOpen = true;
      StartPagePrinter(_handle);
    } finally {
      free(name);
      free(docName);
      free(raw);
      calloc.free(handle);
      calloc.free(doc);
    }
  }

  @override
  Future<void> write(Uint8List bytes, {void Function(int sent)? onSent}) async {
    if (_handle == 0) throw const PrinterLinkException('lost', 'closed');
    const chunk = 16384;
    final buf = calloc<Uint8>(chunk);
    final written = calloc<Uint32>();
    try {
      for (var i = 0; i < bytes.length; i += chunk) {
        final end = i + chunk > bytes.length ? bytes.length : i + chunk;
        final n = end - i;
        buf.asTypedList(n).setRange(0, n, bytes, i);
        if (WritePrinter(_handle, buf, n, written) == 0 || written.value != n) {
          throw PrinterLinkException('write', 'WritePrinter failed (${GetLastError()})');
        }
        onSent?.call(end);
        // Let the UI breathe between large slices.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      calloc.free(buf);
      calloc.free(written);
    }
  }

  @override
  Future<Uint8List?> read({Duration timeout = const Duration(milliseconds: 600)}) async =>
      null;

  @override
  Future<void> close() async {
    if (_handle == 0) return;
    if (_docOpen) {
      EndPagePrinter(_handle);
      EndDocPrinter(_handle);
      _docOpen = false;
    }
    ClosePrinter(_handle);
    _handle = 0;
  }
}
