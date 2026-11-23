import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/di/providers.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/core/storage/secure_storage.dart'
    show SecureStorageService;
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_relay_identity.dart';
import 'package:fyona_flutter/features/core_business/presentation/providers/business_cash_relay_provider.dart';
import 'package:fyona_flutter/features/core_business/presentation/providers/business_relay_http_provider.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'support/business_cash_test_checkpoint.dart';
import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

class _ReadOnlyVault extends Fake implements SecureStorageService {
  _ReadOnlyVault(this.account, this.sid);
  final String account, sid;
  @override
  Future<String?> getToken() async {
    final encoded = base64Url.encode(
      utf8.encode(jsonEncode({'type': 'access', 'sub': account, 'sid': sid})),
    );
    return 'fixture.$encoded.signature';
  }
}

void main() {
  testWidgets(
    'a rejected background relay never changes the login, selection or local outbox',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final scope = DirectoryAccess(
        workspace: DirectoryWorkspace(
          server: DirectoryPilotBuild.baseUrl,
          organizationId: _id(),
          accountId: _id(),
        ),
        branchId: _id(),
        readable: {},
        writable: {},
        financialCutover: true,
      );
      final account = _id(), sid = _id(), command = _id();
      final grant = BusinessLedgerAccess(scope, {
        BusinessLedgerAction.syncCash,
        BusinessLedgerAction.createBank,
        BusinessLedgerAction.moveMoney,
      }, cashSessionId: sid);
      final checkpoint = cashTestCheckpoint(scope, account, balance: 1000);
      final connectivity = ConnectivityService(debugOnline: false);
      addTearDown(connectivity.dispose);
      final requests = <RequestOptions>[];
      final relay = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              requests.add(request);
              handler.reject(
                DioException.badResponse(
                  statusCode: 401,
                  requestOptions: request,
                  response: Response(
                    requestOptions: request,
                    statusCode: 401,
                    data: {
                      'detail': {'code': 'branch_scope_expired'},
                    },
                  ),
                ),
              );
            },
          ),
        );
      addTearDown(() => relay.close(force: true));
      late DirectoryPilotStore store;
      const token = 'selected-fixture-token';
      await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'fyona-cash-runtime-',
        );
        store = DirectoryPilotStore(
          root: () async => root,
          keys: FixtureDirectoryKeys(),
        );
        addTearDown(() async {
          await store.close();
          await root.delete(recursive: true);
        });
        addTearDown(BranchScope.clear);
        await BranchScope.save(
          token: token,
          branchId: scope.branchId,
          branchName: 'QA',
          organizationId: scope.workspace.organizationId,
          allMode: false,
        );
        await store.remember(scope, {
          'status': 'active',
          'business_setup_completed': true,
          'sections': {
            'business': {
              'active': true,
              'end_date': DateTime.now()
                  .add(const Duration(days: 1))
                  .toIso8601String(),
            },
          },
        });
        await store.withLedger(grant, () => scope, (ledger) async {
          await ledger.createAccount(
            grant,
            commandId: account,
            bankName: 'Cash',
            accountName: 'QA',
            accountNumber: '1',
            currency: 'SAR',
            openingMinor: 1000,
          );
          await ledger.cashSync.provision(
            grant,
            account,
            grantVersion: 1,
            allowNegative: false,
          );
          await ledger.cashSync.bindReplica(
            grant,
            sessionId: sid,
            checkpoint: checkpoint,
          );
          await ledger.move(
            grant,
            commandId: command,
            accountId: account,
            amountMinor: 250,
            withdraw: true,
          );
        });
      });

      final secure = _ReadOnlyVault(scope.workspace.accountId, sid);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            businessLocalLedgerScopeProvider.overrideWithValue(scope),
            directoryPilotStoreProvider.overrideWithValue(store),
            connectivityServiceProvider.overrideWithValue(connectivity),
            employeeCanProvider.overrideWith((_, __) => true),
            secureStorageProvider.overrideWithValue(secure),
            businessRelayHttpProvider.overrideWithValue(relay),
            apiClientProvider.overrideWith(
              (_) => fail('Relay must not use app-wide auth retries'),
            ),
          ],
          child: const BusinessCashRelayRuntime(child: SizedBox.shrink()),
        ),
      );
      await tester.pump();
      expect(requests, isEmpty);
      connectivity.debugSetOnline(true);
      for (var i = 0; i < 60 && requests.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 8)),
        );
      }
      expect(
        requests.single.uri.path,
        '/api/v1/business/cash-relay/v2/withdraw',
      );
      expect(requests.single.headers['X-Business-Replica-Session'], sid);
      expect(requests.single.headers['X-Branch-Token'], token);
      expect(requests.single.headers['X-Refresh-Token'], isNull);
      expect(requests.single.followRedirects, isFalse);
      expect(requests.single.data['checkpoint'], {
        'sequence': checkpoint.sequence,
        'digest': checkpoint.digest,
      });
      expect(BranchScope.token, token);
      expect(BranchScope.branchId, scope.branchId);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await store.close();
        final queued = await store.withLedger(
          grant,
          () => scope,
          (ledger) => ledger.cashSync.pending(grant),
        );
        expect(queued.single['command_id'], command);
      });
      expect(tester.takeException(), isNull);
    },
    skip: !DirectoryPilotBuild.signupEnabled || !businessCashRelayEnabled,
  );
}
