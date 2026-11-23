import 'dart:async';

import 'package:multicast_dns/multicast_dns.dart';

/// Zero-configuration LAN discovery of the backend (mDNS / DNS-SD).
///
/// The backend advertises `_fyona-erp._tcp.local`; any phone on the same
/// Wi-Fi resolves it to `http://<laptop-ip>:<port>/api/v1` with no typed
/// addresses and no per-device builds. Manual server setting (login screen)
/// always wins over discovery; the build default is the last fallback.
class ServerDiscovery {
  static const serviceType = '_fyona-erp';
  static const serviceProto = '_tcp';
  static const defaultPort = 8001;

  /// Pure URL builder (unit-tested).
  static String baseUrlFromHost(String host, int port) {
    final clean = host.trim();
    final p = port > 0 ? port : defaultPort;
    return 'http://$clean:$p/api/v1';
  }

  /// Browse for the backend, returning the first usable base URL or null.
  /// Never throws; bounded by [timeout] in all cases.
  static Future<String?> discover(
      {Duration timeout = const Duration(seconds: 5)}) async {
    MDnsClient? client;
    try {
      client = MDnsClient();
      await client
          .start()
          .timeout(timeout, onTimeout: () => throw TimeoutException('mdns'));
      final stopAt = DateTime.now().add(timeout);
      Duration remaining() => stopAt.difference(DateTime.now());

      final ptr = await client
          .lookup<PtrResourceRecord>(
              ResourceRecordQuery.serverPointer('$serviceType.$serviceProto'))
          .first
          .timeout(remaining().isNegative ? Duration.zero : remaining());
      final srv = await client
          .lookup<SrvResourceRecord>(
              ResourceRecordQuery.service(ptr.domainName))
          .first
          .timeout(remaining().isNegative ? Duration.zero : remaining());
      final ip = await client
          .lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4(srv.target))
          .first
          .timeout(remaining().isNegative ? Duration.zero : remaining());
      return baseUrlFromHost(ip.address.address, srv.port);
    } catch (_) {
      return null;
    } finally {
      try {
        client?.stop();
      } catch (_) {}
    }
  }
}
