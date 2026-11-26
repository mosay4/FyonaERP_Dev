import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../domain/printer_models.dart';

/// Thrown by a link when the printer cannot be reached or stops answering.
class PrinterLinkException implements Exception {
  final String code; // connect | write | permission | unsupported | lost
  final String message;
  const PrinterLinkException(this.code, this.message);
  @override
  String toString() => 'PrinterLinkException($code): $message';
}

/// A byte pipe to one printer. Implementations: [TcpPrinterLink] (raw TCP,
/// every platform), [NativePrinterLink] (Bluetooth classic / BLE / USB via
/// the app's native side) and the Windows spooler link.
abstract class PrinterLink {
  /// Opens the connection. Throws [PrinterLinkException].
  Future<void> open();

  bool get isOpen;

  /// Writes [bytes] in order. [onSent] reports bytes delivered so far.
  Future<void> write(Uint8List bytes, {void Function(int sent)? onSent});

  /// Bytes the printer sent back within [timeout] (null when the transport
  /// cannot read or nothing arrived). Used for status / completion only.
  Future<Uint8List?> read({Duration timeout = const Duration(milliseconds: 600)});

  /// True when this transport can read replies from the printer.
  bool get canRead;

  Future<void> close();
}

/// Raw TCP (JetDirect / AppSocket, usually port 9100).
class TcpPrinterLink implements PrinterLink {
  TcpPrinterLink(this.host, this.port,
      {this.connectTimeout = const Duration(seconds: 5), this.chunk = 4096});

  final String host;
  final int port;
  final Duration connectTimeout;
  final int chunk;

  Socket? _socket;
  StreamSubscription<Uint8List>? _sub;
  final BytesBuilder _inbox = BytesBuilder();
  Completer<void>? _arrived;
  bool _closed = false;

  @override
  bool get isOpen => _socket != null && !_closed;

  @override
  bool get canRead => true;

  @override
  Future<void> open() async {
    try {
      final s = await Socket.connect(host, port, timeout: connectTimeout);
      s.setOption(SocketOption.tcpNoDelay, true);
      _socket = s;
      _closed = false;
      _sub = s.listen((data) {
        _inbox.add(data);
        _arrived?.complete();
        _arrived = null;
      }, onDone: () => _closed = true, onError: (_) => _closed = true);
    } on SocketException catch (e) {
      throw PrinterLinkException('connect', e.message);
    } on TimeoutException {
      throw const PrinterLinkException('connect', 'timeout');
    }
  }

  @override
  Future<void> write(Uint8List bytes, {void Function(int sent)? onSent}) async {
    final s = _socket;
    if (s == null || _closed) throw const PrinterLinkException('lost', 'closed');
    try {
      for (var i = 0; i < bytes.length; i += chunk) {
        final end = i + chunk > bytes.length ? bytes.length : i + chunk;
        s.add(Uint8List.sublistView(bytes, i, end));
        await s.flush();
        if (_closed) throw const PrinterLinkException('lost', 'closed');
        onSent?.call(end);
      }
    } on SocketException catch (e) {
      throw PrinterLinkException('lost', e.message);
    }
  }

  @override
  Future<Uint8List?> read({Duration timeout = const Duration(milliseconds: 600)}) async {
    if (_inbox.isEmpty) {
      _arrived = Completer<void>();
      try {
        await _arrived!.future.timeout(timeout);
        // A reply may come in several packets.
        await Future<void>.delayed(const Duration(milliseconds: 40));
      } on TimeoutException {
        _arrived = null;
        return null;
      }
    }
    return _inbox.takeBytes();
  }

  @override
  Future<void> close() async {
    _closed = true;
    try {
      await _sub?.cancel();
    } catch (_) {}
    try {
      await _socket?.close();
    } catch (_) {}
    try {
      _socket?.destroy();
    } catch (_) {}
    _socket = null;
  }
}

/// Bluetooth classic (SPP), BLE (GATT write) and USB (bulk) through the
/// app's native side — channel `com.fyona.erp/printer`. Every call runs off
/// the UI thread natively.
class NativePrinterLink implements PrinterLink {
  NativePrinterLink(this.device, {MethodChannel? channel})
      : _ch = channel ?? const MethodChannel(channelName);

  static const channelName = 'com.fyona.erp/printer';
  final PrinterDevice device;
  final MethodChannel _ch;
  bool _open = false;

  String get _transport => switch (device.kind) {
        PrinterKind.ble => 'ble',
        PrinterKind.usb => 'usb',
        _ => 'bt',
      };

  @override
  bool get isOpen => _open;

  @override
  bool get canRead => device.kind != PrinterKind.ble;

  Never _fail(PlatformException e, String fallback) =>
      throw PrinterLinkException(e.code, e.message ?? fallback);

  @override
  Future<void> open() async {
    try {
      final ok = await _ch.invokeMethod<bool>('connect', {
        'transport': _transport,
        'address': device.address,
      });
      if (ok != true) throw const PrinterLinkException('connect', 'refused');
      _open = true;
    } on PlatformException catch (e) {
      _fail(e, 'connect');
    } on MissingPluginException {
      throw const PrinterLinkException('unsupported', 'no native printer side');
    }
  }

  @override
  Future<void> write(Uint8List bytes, {void Function(int sent)? onSent}) async {
    // The native side keeps order and paces BLE / USB itself; slices let the
    // UI follow real progress.
    const slice = 8192;
    try {
      for (var i = 0; i < bytes.length; i += slice) {
        final end = i + slice > bytes.length ? bytes.length : i + slice;
        await _ch.invokeMethod('write', {
          'transport': _transport,
          'bytes': Uint8List.sublistView(bytes, i, end),
        });
        onSent?.call(end);
      }
    } on PlatformException catch (e) {
      _open = false;
      _fail(e, 'write');
    }
  }

  @override
  Future<Uint8List?> read({Duration timeout = const Duration(milliseconds: 600)}) async {
    if (!canRead) return null;
    try {
      return await _ch.invokeMethod<Uint8List>('read', {
        'transport': _transport,
        'timeoutMs': timeout.inMilliseconds,
      });
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> close() async {
    _open = false;
    try {
      await _ch.invokeMethod('disconnect', {'transport': _transport});
    } catch (_) {}
  }
}
