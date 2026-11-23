import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/network/api_client.dart'
    show normalizeServerBaseUrl;
import 'package:fyona_flutter/core/network/server_discovery.dart'
    show ServerDiscovery;
import 'package:fyona_flutter/core/config/app_config.dart';

/// Server address normalization: any LAN device can point the app at the
/// backend by typing just the IP — no rebuilds, no exceptions.
void main() {
  group('normalizeServerBaseUrl', () {
    test('bare LAN IP defaults to backend port + /api/v1', () {
      expect(normalizeServerBaseUrl('192.168.8.139'),
          'http://192.168.8.139:8001/api/v1');
    });

    test('IP with explicit port is respected', () {
      expect(normalizeServerBaseUrl('192.168.8.139:9000'),
          'http://192.168.8.139:9000/api/v1');
    });

    test('full URL passes through untouched', () {
      expect(normalizeServerBaseUrl('http://192.168.8.139:8001/api/v1'),
          'http://192.168.8.139:8001/api/v1');
      expect(normalizeServerBaseUrl('https://api.example.com/api/v1'),
          'https://api.example.com/api/v1');
    });

    test('trailing slashes are trimmed, suffix not doubled', () {
      expect(normalizeServerBaseUrl('192.168.8.139/'),
          'http://192.168.8.139:8001/api/v1');
      expect(normalizeServerBaseUrl('http://h:8001/api/v1/'),
          'http://h:8001/api/v1');
    });

    test('empty/garbage falls back to build default', () {
      expect(normalizeServerBaseUrl(''), AppConfig.apiBaseUrl);
      expect(normalizeServerBaseUrl('   '), AppConfig.apiBaseUrl);
    });

    test('whitespace is trimmed', () {
      expect(normalizeServerBaseUrl('  192.168.8.139  '),
          'http://192.168.8.139:8001/api/v1');
    });
  });

  group('ServerDiscovery.baseUrlFromHost', () {
    test('builds LAN base URL from host+port', () {
      expect(ServerDiscovery.baseUrlFromHost('192.168.8.139', 8001),
          'http://192.168.8.139:8001/api/v1');
    });

    test('non-positive port falls back to 8001', () {
      expect(ServerDiscovery.baseUrlFromHost('192.168.8.139', 0),
          'http://192.168.8.139:8001/api/v1');
    });
  });
}
