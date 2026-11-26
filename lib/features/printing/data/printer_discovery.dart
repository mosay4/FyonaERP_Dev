import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:multicast_dns/multicast_dns.dart';

import '../domain/printer_models.dart';
import 'printer_link.dart';
import 'windows_spooler.dart';

/// Finds printers on every path the platform offers, in parallel, and
/// streams each one as soon as it is found (no waiting for the slowest):
///
/// * Bluetooth classic: paired + nearby discovery (Android);
/// * BLE: nearby receipt printers (Android, iOS);
/// * USB: attached printers (Android);
/// * network: mDNS / Bonjour (IPP, raw, LPD) and a fast sweep of the local
///   /24 for ports 9100 (raw) and 631 (IPP) — every platform;
/// * Windows: printers installed in the spooler.
class PrinterDiscovery {
  PrinterDiscovery({
    MethodChannel? channel,
    this.sweep = true,
    this.sweepHosts,
    this.sweepPorts = const {9100: PrinterKind.network, 631: PrinterKind.ipp},
    this.timeout = const Duration(seconds: 6),
  }) : _ch = channel ?? const MethodChannel(NativePrinterLink.channelName);

  final MethodChannel _ch;
  final bool sweep;

  /// Test seam: hosts to probe instead of the local /24.
  final List<String>? sweepHosts;

  /// Ports probed on each host: raw (JetDirect) and IPP.
  final Map<int, PrinterKind> sweepPorts;
  final Duration timeout;

  Stream<PrinterDevice> discover() {
    final out = StreamController<PrinterDevice>();
    final seen = <String>{};
    void emit(PrinterDevice d) {
      if (out.isClosed || !seen.add(d.id)) return;
      out.add(d);
    }

    final jobs = <Future<void>>[
      _native('bt', PrinterKind.bluetooth, emit),
      _native('ble', PrinterKind.ble, emit),
      _native('usb', PrinterKind.usb, emit),
      _mdns(emit),
      if (sweep) _sweep(emit),
      _windows(emit),
    ];
    Future.wait(jobs.map((j) => j.catchError((_) {})))
        .whenComplete(() => out.close());
    return out.stream;
  }

  // ── Native (Bluetooth classic, BLE, USB) ──
  Future<void> _native(
      String transport, PrinterKind kind, void Function(PrinterDevice) emit) async {
    if (!(Platform.isAndroid || (Platform.isIOS && transport == 'ble'))) return;
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('scan', {
        'transport': transport,
        'timeoutMs': timeout.inMilliseconds,
      });
      for (final d in (raw ?? const []).whereType<Map>()) {
        final address = '${d['address'] ?? ''}';
        if (address.isEmpty) continue;
        final name = '${d['name'] ?? ''}'.trim();
        emit(PrinterDevice(
          id: '${transport == 'bt' ? 'bt' : transport}:$address',
          name: name.isEmpty ? _fallbackName(kind) : name,
          kind: kind,
          address: address,
        ));
      }
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  static String _fallbackName(PrinterKind k) => switch (k) {
        PrinterKind.bluetooth => 'Bluetooth printer',
        PrinterKind.ble => 'BLE printer',
        PrinterKind.usb => 'USB printer',
        _ => 'Printer',
      };

  // ── mDNS / Bonjour ──
  /// mDNS runs in its own guarded zone: the multicast socket reports send
  /// failures (no multicast route, e.g. some Wi-Fi / VPN setups) as
  /// asynchronous errors outside any try/catch — they must end this one
  /// search quietly, never surface as app errors.
  Future<void> _mdns(void Function(PrinterDevice) emit) {
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    runZonedGuarded(() {
      _mdnsSearch(emit).whenComplete(finish);
    }, (error, stack) => finish());
    // Hard stop: whatever the socket does, the search ends.
    return done.future.timeout(timeout + const Duration(seconds: 6), onTimeout: () {});
  }

  Future<void> _mdnsSearch(void Function(PrinterDevice) emit) async {
    final client = MDnsClient();
    try {
      await client.start();
    } catch (_) {
      return;
    }
    try {
      const services = {
        '_ipp._tcp.local': PrinterKind.ipp,
        '_ipps._tcp.local': PrinterKind.ipp,
        '_pdl-datastream._tcp.local': PrinterKind.network,
        '_printer._tcp.local': PrinterKind.network,
      };
      await Future.wait(services.entries.map((svc) async {
        try {
          await for (final ptr in client.lookup<PtrResourceRecord>(
              ResourceRecordQuery.serverPointer(svc.key),
              timeout: timeout)) {
            String path = '/ipp/print';
            await for (final txt in client.lookup<TxtResourceRecord>(
                ResourceRecordQuery.text(ptr.domainName),
                timeout: const Duration(seconds: 2))) {
              final rp = RegExp(r'rp=([^\n]+)').firstMatch(txt.text)?.group(1);
              if (rp != null && rp.isNotEmpty) path = '/${rp.trim()}';
              break;
            }
            await for (final srv in client.lookup<SrvResourceRecord>(
                ResourceRecordQuery.service(ptr.domainName),
                timeout: timeout)) {
              final host = srv.target.replaceAll(RegExp(r'\.$'), '');
              await for (final a in client.lookup<IPAddressResourceRecord>(
                  ResourceRecordQuery.addressIPv4(host),
                  timeout: const Duration(seconds: 2))) {
                final ip = a.address.address;
                final name = ptr.domainName
                    .replaceAll(svc.key, '')
                    .replaceAll(RegExp(r'\.$'), '')
                    .replaceAll(r'\032', ' ');
                emit(svc.value == PrinterKind.ipp
                    ? PrinterDevice(
                        id: 'ipp:$ip:${srv.port}$path',
                        name: name.isEmpty ? ip : name,
                        kind: PrinterKind.ipp,
                        address: ip,
                        port: srv.port,
                        path: path,
                        thermal: false)
                    : PrinterDevice(
                        id: 'net:$ip:${srv.port}',
                        name: name.isEmpty ? ip : name,
                        kind: PrinterKind.network,
                        address: ip,
                        port: srv.port));
                break;
              }
            }
          }
        } catch (_) {}
      }));
    } finally {
      try {
        client.stop();
      } catch (_) {}
    }
  }

  // ── Local subnet sweep (9100 raw, 631 IPP) ──
  Future<void> _sweep(void Function(PrinterDevice) emit) async {
    final hosts = sweepHosts ?? await localSubnetHosts();
    if (hosts.isEmpty) return;
    final ports = sweepPorts;
    final targets = [
      for (final h in hosts)
        for (final p in ports.keys) (h, p),
    ];
    var next = 0;
    Future<void> worker() async {
      while (next < targets.length) {
        final (host, port) = targets[next++];
        Socket? s;
        try {
          s = await Socket.connect(host, port,
              timeout: const Duration(milliseconds: 350));
          emit(ports[port] == PrinterKind.ipp
              ? PrinterDevice(
                  id: 'ipp:$host:$port/ipp/print',
                  name: host,
                  kind: PrinterKind.ipp,
                  address: host,
                  port: port,
                  thermal: false)
              : PrinterDevice(
                  id: 'net:$host:$port',
                  name: host,
                  kind: PrinterKind.network,
                  address: host,
                  port: port));
        } catch (_) {
        } finally {
          s?.destroy();
        }
      }
    }

    await Future.wait(List.generate(48, (_) => worker()));
  }

  /// Every other address of this device's private /24 networks.
  static Future<List<String>> localSubnetHosts() async {
    try {
      final out = <String>[];
      for (final nic in await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false)) {
        for (final a in nic.addresses) {
          final p = a.address.split('.');
          if (p.length != 4) continue;
          final first = int.tryParse(p[0]) ?? 0;
          final second = int.tryParse(p[1]) ?? 0;
          final private = first == 10 ||
              (first == 192 && second == 168) ||
              (first == 172 && second >= 16 && second <= 31);
          if (!private) continue;
          for (var i = 1; i < 255; i++) {
            final ip = '${p[0]}.${p[1]}.${p[2]}.$i';
            if (ip != a.address && !out.contains(ip)) out.add(ip);
          }
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  // ── Windows spooler ──
  Future<void> _windows(void Function(PrinterDevice) emit) async {
    if (!WindowsSpooler.available) return;
    for (final name in WindowsSpooler.printers()) {
      final lower = name.toLowerCase();
      // Virtual "printers" that write files are not real printers.
      if (lower.contains('pdf') || lower.contains('xps') ||
          lower.contains('onenote') || lower.contains('fax')) {
        continue;
      }
      emit(PrinterDevice(
        id: 'win:$name',
        name: name,
        kind: PrinterKind.windows,
        address: name,
        thermal: _looksThermal(lower),
      ));
    }
  }

  static bool _looksThermal(String lower) => const [
        'pos', 'receipt', 'thermal', 'tm-', 'xp-', 'rongta', 'xprinter',
        'gprinter', 'bixolon', 'citizen', 'star', 'sewoo', 'hprt', '58', '80',
      ].any(lower.contains);
}
