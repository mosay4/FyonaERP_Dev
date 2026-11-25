import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/network/dio_provider.dart';
import 'package:fyona_flutter/core/services/sync_engine.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_local_cutover.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_relay_config.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../support/personal_ledger_test_support.dart';

/// Every call is recorded; writes are refused by the device-only guard
/// (or accepted), reads would be server data.
class _GuardedApi extends ApiClient {
  _GuardedApi({this.refuse = true}) : super(dio: Dio());
  final bool refuse;
  final calls = <String>[];

  Future<Response<T>> _answer<T>(String method, String path) {
    calls.add('$method $path');
    if (method == 'GET' || path.contains('/sync/pull')) {
      return Future.value(Response<T>(
        requestOptions: RequestOptions(path: path),
        data: {'success': true, 'data': <dynamic>[]} as T,
        statusCode: 200,
      ));
    }
    if (refuse) {
      throw DioException(
        requestOptions: RequestOptions(path: path),
        response: Response(
          requestOptions: RequestOptions(path: path),
          statusCode: 409,
          data: {'success': false, 'code': 'personal_local', 'message': 'x'},
        ),
        type: DioExceptionType.badResponse,
      );
    }
    return Future.value(Response<T>(
      requestOptions: RequestOptions(path: path),
      data: {'success': true, 'data': {'id': 'acct-9'}} as T,
      statusCode: 201,
    ));
  }

  @override
  Future<Response<T>> get<T>(String path,
          {Map<String, dynamic>? queryParameters, Options? options, CancelToken? cancelToken}) =>
      _answer('GET', path);

  @override
  Future<Response<T>> post<T>(String path,
          {dynamic data, Map<String, dynamic>? queryParameters, Options? options, CancelToken? cancelToken}) =>
      _answer('POST', path);

  @override
  Future<Response<T>> put<T>(String path,
          {dynamic data, Map<String, dynamic>? queryParameters, Options? options, CancelToken? cancelToken}) =>
      _answer('PUT', path);

  @override
  Future<Response<T>> patch<T>(String path,
          {dynamic data, Map<String, dynamic>? queryParameters, Options? options, CancelToken? cancelToken}) =>
      _answer('PATCH', path);

  @override
  Future<Response<T>> delete<T>(String path,
          {dynamic data, Map<String, dynamic>? queryParameters, Options? options, CancelToken? cancelToken}) =>
      _answer('DELETE', path);
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    try {
      await DatabaseHelper.close();
    } catch (_) {}
    await resetPersonalLedger();
    PersonalRelayConfig.enabled = true;
    PersonalLocalMode.debugReset();
  });
  tearDown(() {
    PersonalRelayConfig.enabled = PersonalRelayConfig.build;
    PersonalLocalMode.debugReset();
  });

  Future<void> queueOldWrite() async {
    final db = await testLedger();
    // A row saved by an older build (before the relay existed), not sent.
    await db.rawInsert(
      'INSERT INTO personal_rows (user_id, entity_type, id, data_json, updated_us, deleted, version) '
      "VALUES (1, 'personal_bank_account', 'acct-9', ?, 0, 0, 0)",
      [jsonEncode({'id': 'acct-9', 'bank_name': 'بنك', 'currency': 'SAR', 'balance': 10.0})],
    );
    await db.rawInsert(
      'INSERT INTO personal_outbox (operation_id, operation_type, table_name, entity_type, entity_id, operation, data, status, user_id, occurred_at, created_at) '
      "VALUES ('op-old-1', 'ENTITY_CREATE', 'personal_bank_account', 'personal_bank_account', 'acct-9', 'INSERT', ?, 'pending', 1, ?, ?)",
      [
        jsonEncode({'id': 'acct-9', 'bank_name': 'بنك', 'currency': 'SAR', 'balance': 10.0}),
        DateTime.utc(2026, 10, 1).toIso8601String(),
        DateTime.utc(2026, 10, 1).toIso8601String(),
      ],
    );
  }

  Future<SyncEngine> engineWith(ApiClient api, List<ProviderContainer> keep) async {
    final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(api)]);
    keep.add(container);
    final engine = container.read(syncEngineProvider);
    await engine.init();
    return engine;
  }

  test('the guard refusal turns old outbox rows into relay operations and stops the old sync',
      () async {
    await queueOldWrite();
    final api = _GuardedApi();
    final keep = <ProviderContainer>[];
    final engine = await engineWith(api, keep);
    try {
      await engine.processQueue();
      expect(PersonalLocalMode.oldSyncRetired, isTrue);
      final db = await testLedger();
      expect((await db.rawQuery('SELECT * FROM personal_outbox')), isEmpty);
      final ops = await db.rawQuery('SELECT payload FROM personal_relay_outbox');
      expect(ops, hasLength(1));
      final change = ((jsonDecode(ops.single['payload'] as String) as Map)['c'] as List).single as Map;
      expect(change['t'], 'personal_bank_account');
      expect(change['id'], 'acct-9');
      expect(change['data']['balance'], 10.0);
      // Never a server pull for a local user.
      expect(api.calls.where((c) => c.contains('/sync/pull')), isEmpty);

      // Retired: the next cycles call nothing at all.
      api.calls.clear();
      await engine.processQueue();
      expect(api.calls, isEmpty);
    } finally {
      engine.dispose();
      for (final c in keep) {
        c.dispose();
      }
    }
  });

  test('before the cutover the old sync only drains (pushes), it never pulls', () async {
    await queueOldWrite();
    final api = _GuardedApi(refuse: false);
    final keep = <ProviderContainer>[];
    final engine = await engineWith(api, keep);
    try {
      await engine.processQueue();
      expect(api.calls, isNotEmpty);
      expect(api.calls.every((c) => !c.contains('/sync/pull') && !c.startsWith('GET')), isTrue,
          reason: '${api.calls}');
    } finally {
      engine.dispose();
      for (final c in keep) {
        c.dispose();
      }
    }
  });

  test('after the cutover a save is a relay operation only: nothing for the old outbox',
      () async {
    final cache = PersonalCacheRepository();
    Future<int> count(String table) async =>
        ((await (await testLedger()).rawQuery('SELECT COUNT(*) AS c FROM $table')).first['c']
            as int);
    Future<void> save(String id) => cache.commitOfflineWrite(
          userId: 7,
          entityType: 'personal_bank_account',
          remoteId: id,
          primaryRow: {'id': id, 'bank_name': 'بنك', 'currency': 'SAR', 'balance': 1.0},
          operation: 'INSERT',
          data: {'id': id, 'bank_name': 'بنك', 'currency': 'SAR', 'balance': 1.0},
        );
    // Before the cutover: both (the old outbox still drains to the server).
    await save('b-before');
    expect(await count('personal_outbox'), 1);
    expect(await count('personal_relay_outbox'), 1);

    PersonalLocalMode.oldSyncRetired = true;
    await save('b-after');
    expect(await count('personal_outbox'), 1);
    expect(await count('personal_relay_outbox'), 2);
    // Reads never overlay a stale old-outbox copy of the new row.
    expect((await cache.getCollection(7, 'personal_bank_account')).map((r) => r['id']),
        containsAll(['b-before', 'b-after']));
  });

  test('lists read the device ledger only: no first-run server fetch', () async {
    final api = _GuardedApi();
    final cache = PersonalCacheRepository();
    final svc = PersonalFinanceService(apiClient: api, cache: cache)..setUserId(7);
    expect(await svc.getBankAccounts(), isEmpty);
    await cache.upsertItem(7, 'personal_bank_account', 'b1',
        {'id': 'b1', 'bank_name': 'بنك', 'currency': 'SAR', 'balance': 5.0});
    expect((await svc.getBankAccounts()).single.balance, 5.0);
    await Future<void>.delayed(const Duration(milliseconds: 50)); // no background refresh
    expect(api.calls.where((c) => c.startsWith('GET')), isEmpty, reason: '${api.calls}');
    // No server reset for a local user.
    await svc.resetAccount();
    expect(api.calls.where((c) => c.startsWith('DELETE')), isEmpty);
  });
}
