import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/network/dio_provider.dart';
import 'package:fyona_flutter/core/services/sync_engine.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../support/personal_ledger_test_support.dart';

DioException _offlineErr(String path) => DioException(
      requestOptions: RequestOptions(path: path),
      type: DioExceptionType.connectionError,
      message: 'SocketException: Failed host lookup (no internet)',
    );

/// ApiClient double that behaves like a fully-offline device.
class _OfflineApiClient extends ApiClient {
  _OfflineApiClient() : super(dio: Dio());

  @override
  Future<Response<T>> get<T>(String path,
      {Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken}) {
    throw _offlineErr(path);
  }

  @override
  Future<Response<T>> post<T>(String path,
      {dynamic data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken}) {
    throw _offlineErr(path);
  }

  @override
  Future<Response<T>> put<T>(String path,
      {dynamic data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken}) {
    throw _offlineErr(path);
  }

  @override
  Future<Response<T>> patch<T>(String path,
      {dynamic data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken}) {
    throw _offlineErr(path);
  }

  @override
  Future<Response<T>> delete<T>(String path,
      {dynamic data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken}) {
    throw _offlineErr(path);
  }
}

/// Online double: the debt-payment endpoint succeeds (atomic server-side),
/// everything else behaves offline (so fragment pushes fail safe).
class _OnlineApiClient extends ApiClient {
  final List<Map<String, dynamic>> paymentPosts = [];
  _OnlineApiClient() : super(dio: Dio());

  @override
  Future<Response<T>> post<T>(String path,
      {dynamic data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken}) {
    if (path.contains('/debts/') && path.endsWith('/payments')) {
      paymentPosts.add({
        'path': path,
        'data': Map<String, dynamic>.from(data as Map),
      });
      final body = {
        'success': true,
        'message': 'ok',
        'data': {'id': 'pay-server-1'},
      };
      return Future.value(Response<T>(
        requestOptions: RequestOptions(path: path),
        data: body as T,
        statusCode: 201,
      ));
    }
    throw _offlineErr(path);
  }

  @override
  Future<Response<T>> get<T>(String path,
      {Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken}) {
    throw _offlineErr(path);
  }

  @override
  Future<Response<T>> put<T>(String path,
      {dynamic data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken}) {
    throw _offlineErr(path);
  }

  @override
  Future<Response<T>> patch<T>(String path,
      {dynamic data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken}) {
    throw _offlineErr(path);
  }

  @override
  Future<Response<T>> delete<T>(String path,
      {dynamic data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken}) {
    throw _offlineErr(path);
  }
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
    final path = '${await getDatabasesPath()}/fyona_erp.db';
    final db = await databaseFactory.openDatabase(path);
    await resetPersonalLedger();
    await db.close();
  });

  tearDown(() async {
    try {
      await DatabaseHelper.close();
    } catch (_) {}
  });

  const uid = 7;

  Future<PersonalFinanceService> seededService() async {
    final cache = PersonalCacheRepository();
    await cache.upsertItem(uid, 'personal_bank_account', 'bank-1', {
      'id': 'bank-1',
      'bank_name': 'Test Bank',
      'balance': 1000.0,
      'currency': 'SAR',
      'account_type': 'checking',
    });
    await cache.upsertItem(uid, 'personal_debt', 'debt-1', {
      'id': 'debt-1',
      'debt_type': 'payable',
      'person_name': 'Ali',
      'amount': 500.0,
      'paid': 0.0,
      'currency': 'SAR',
    });
    final svc = PersonalFinanceService(
      apiClient: _OfflineApiClient(),
      cache: cache,
    );
    svc.setUserId(uid);
    return svc;
  }

  group('offline bank debt payment', () {
    test('deducts bank, updates debt and creates a dated transaction', () async {
      final svc = await seededService();

      final res = await svc.payDebt(
        'debt-1',
        200,
        DateTime(2026, 9, 8, 20, 0),
        method: 'bank',
        bankAccountId: 'bank-1',
      );
      expect(res['offline'], isTrue);

      final accounts = await svc.getBankAccounts();
      expect(
        accounts.firstWhere((a) => a.id == 'bank-1').balance,
        800.0,
        reason: 'bank balance must be deducted',
      );

      final debts = await svc.getDebts();
      final debt = debts.firstWhere((d) => d.id == 'debt-1');
      expect(debt.paid, 200.0, reason: 'debt paid must increase');
      expect(debt.remaining, 300.0, reason: 'debt remaining must decrease');

      final txs = await svc.getTransactions();
      final payTxs = txs.where((t) => t.debtId == 'debt-1').toList();
      expect(payTxs, isNotEmpty, reason: 'payment tx must exist');
      expect(payTxs.first.amount, 200.0);
      expect(payTxs.first.date, isNotNull,
          reason: 'payment tx must carry a date or it sinks in newest-first lists');
      expect(payTxs.first.accountId, 'bank-1');
    });

    test('offline cash debt payment behaves identically', () async {
      final cache = PersonalCacheRepository();
      await cache.upsertItem(uid, 'personal_bank_account', 'cash-1', {
        'id': 'cash-1',
        'bank_name': 'كاش',
        'balance': 1000.0,
        'currency': 'SAR',
        'account_type': 'cash',
      });
      await cache.upsertItem(uid, 'personal_debt', 'debt-2', {
        'id': 'debt-2',
        'debt_type': 'payable',
        'person_name': 'Sara',
        'amount': 400.0,
        'paid': 0.0,
        'currency': 'SAR',
      });
      final svc = PersonalFinanceService(
        apiClient: _OfflineApiClient(),
        cache: cache,
      );
      svc.setUserId(uid);

      await svc.payDebt(
        'debt-2',
        150,
        DateTime(2026, 9, 8, 19, 0),
        method: 'cash',
        bankAccountId: 'cash-1',
      );

      final debts = await svc.getDebts();
      final debt = debts.firstWhere((d) => d.id == 'debt-2');
      expect(debt.paid, 150.0);
      expect(debt.remaining, 250.0);

      final txs = await svc.getTransactions();
      final payTxs = txs.where((t) => t.debtId == 'debt-2').toList();
      expect(payTxs, isNotEmpty);
      expect(payTxs.first.date, isNotNull);
    });
  });

  group('reconnect replays staged bank payment exactly once (CRUD)', () {
    test('offline pay -> online sync -> one atomic replay, no revert, no dup',
        () async {
      // uid 1 = SyncEngine default with no logged-in user.
      const syncUid = 1;
      final cache = PersonalCacheRepository();
      await cache.upsertItem(syncUid, 'personal_bank_account', 'bank-9', {
        'id': 'bank-9',
        'bank_name': 'Test Bank',
        'balance': 1000.0,
        'currency': 'SAR',
        'account_type': 'checking',
      });
      await cache.upsertItem(syncUid, 'personal_debt', 'debt-9', {
        'id': 'debt-9',
        'debt_type': 'payable',
        'person_name': 'Omar',
        'amount': 500.0,
        'paid': 0.0,
        'currency': 'SAR',
      });
      final staging = PersonalFinanceService(
        apiClient: _OfflineApiClient(),
        cache: cache,
      );
      staging.setUserId(syncUid);

      // 1. Pay offline: mirror reflects everything immediately.
      await staging.payDebt(
        'debt-9',
        200,
        DateTime(2026, 9, 8, 20, 0),
        method: 'bank',
        bankAccountId: 'bank-9',
      );
      expect(
        (await staging.getBankAccounts())
            .firstWhere((a) => a.id == 'bank-9')
            .balance,
        800.0,
      );
      expect(
        (await staging.getDebts()).firstWhere((d) => d.id == 'debt-9').paid,
        200.0,
      );

      // 2. Reconnect: run the real sync engine with an online client whose
      // ONLY working endpoint is the atomic debt-payment one.
      final fake = _OnlineApiClient();
      final container = ProviderContainer(
        overrides: [apiClientProvider.overrideWithValue(fake)],
      );
      final engine = container.read(syncEngineProvider);
      try {
        await engine.init();
        await engine.processQueue();

        // 3. Exactly ONE atomic CRUD replay with the right payload.
        expect(fake.paymentPosts.length, 1,
            reason: 'payment must replay exactly once through CRUD');
        final post = fake.paymentPosts.single;
        expect((post['path'] as String).contains('/debts/debt-9/payments'),
            isTrue);
        final body = post['data'] as Map<String, dynamic>;
        expect(body['amount'], 200);
        expect(body['bank_account_id'], 'bank-9');
        expect(body['tx_id'], isNotEmpty,
            reason: 'the client UUID must materialise the same row server-side');

        // 4. Staged op consumed: no INSERT left in the outbox.
        final leftoverTxOps = await (await testLedger()).rawQuery(
          "SELECT * FROM sync_queue WHERE entity_type = 'personal_transaction' "
          "AND operation = 'INSERT'",
        );
        expect(leftoverTxOps, isEmpty);
        // The locally-created transaction KEEPS its client UUID (the server
        // materialises the same identity through tx_id) — exactly one row, no
        // duplicate and no disappearance.
        final txs = await staging.getTransactions();
        expect(txs.where((t) => t.debtId == 'debt-9').length, 1);

        // 5. Local figures intact (no revert): bank deducted, debt paid.
        expect(
          (await staging.getBankAccounts())
              .firstWhere((a) => a.id == 'bank-9')
              .balance,
          800.0,
        );
        final debt =
            (await staging.getDebts()).firstWhere((d) => d.id == 'debt-9');
        expect(debt.paid, 200.0);
        expect(debt.remaining, 300.0);

        // 6. Second cycle: still exactly one POST (exactly-once, no dup).
        await engine.processQueue();
        expect(fake.paymentPosts.length, 1,
            reason: 'replay must not duplicate on later cycles');
      } finally {
        try {
          engine.dispose();
        } catch (_) {}
        container.dispose();
      }
    });
  });
}
