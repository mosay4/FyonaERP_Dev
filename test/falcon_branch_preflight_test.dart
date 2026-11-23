import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/storage/secure_storage.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/inventory/data/inventory_api.dart';

class _Storage extends SecureStorageService {
  @override
  Future<String?> getToken() async => null;
}

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      '{"data":{}}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Falcon API keeps signed all-mode token without branch override',
    () async {
      final original = (BranchScope.token, BranchScope.allMode);
      addTearDown(() {
        BranchScope.token = original.$1;
        BranchScope.allMode = original.$2;
      });
      BranchScope.allMode = true;
      // Same shape as a server-signed permitted write scope. No JWT validation
      // is bypassed in production: this test exercises only client preflight.
      BranchScope.token =
          'header.${base64Url.encode(utf8.encode(jsonEncode({
            'write_scope': 'branch',
            'branch_ids': ['b1', 'b2'],
          })))}.signature';
      final container = ProviderContainer(
        overrides: [secureStorageProvider.overrideWithValue(_Storage())],
      );
      addTearDown(container.dispose);
      final dio = container.read(dioProvider);
      final adapter = _Adapter();
      dio.httpClientAdapter = adapter;
      final api = InventoryApi(ApiClient(dio: dio));
      await api.falconAnalyze('inventory', null);
      await api.falconChat('inventory', null, 'قارن الفروع', []);
      expect(adapter.requests, hasLength(2));
      for (final request in adapter.requests) {
        expect(request.headers['X-Branch-Token'], BranchScope.token);
        expect(request.headers.containsKey('X-Branch-Id'), isFalse);
        expect((request.data as Map).containsKey('branch_id'), isFalse);
      }
    },
  );
  test('Falcon read-only POSTs never require a create branch', () {
    for (final path in [
      '/inventory/falcon/analyze',
      '/inventory/falcon/chat',
    ]) {
      expect(requiresScopedCreateBranch(path, businessPath: true), isFalse);
      expect(isFalconReadOnlyPath(path), isTrue);
    }
  });
  test('real inventory and business creates still require a branch', () {
    for (final path in [
      '/inventory/adjust',
      '/inventory/falcon/write',
      '/invoices',
      '/products',
    ]) {
      expect(requiresScopedCreateBranch(path, businessPath: true), isTrue);
      expect(isFalconReadOnlyPath(path), isFalse);
    }
  });
}
