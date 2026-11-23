import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/di/providers.dart'
    show apiClientProvider, secureStorageProvider;
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/core/services/section_scope.dart';
import 'package:fyona_flutter/core/storage/secure_storage.dart'
    show SecureStorageService;
import 'package:fyona_flutter/features/auth/presentation/providers/auth_provider.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/presentation/providers/business_relay_http_provider.dart';
import 'package:fyona_flutter/features/employees/data/employee_device_finance.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_finance_receipt_page.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/job_requests_page.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_device_finance_provider.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/subscription/presentation/pages/account_entry_page.dart';
import 'package:fyona_flutter/shared/models/user_model.dart';
import 'package:fyona_flutter/shared/widgets/receipt/receipt_modal.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();
String _jwt(Map<String, Object?> body) =>
    'fixture.${base64Url.encode(utf8.encode(jsonEncode(body)))}.fixture';

class _SignedIn extends StateNotifier<AuthState> implements AuthNotifier {
  _SignedIn(UserModel user)
    : super(AuthState(status: AuthStatus.authenticated, user: user));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Vault extends Fake implements SecureStorageService {
  _Vault(this.token);
  String token;
  @override
  Future<String?> getToken() async => token;
}

void main() {
  final account = _id();
  final ownOrganization = _id();
  final org = _id();
  final branch = _id();
  final employee = _id();
  final invitation = _id();
  final session = _id();
  final payment = _id();
  final debt = _id();
  final revision = List.filled(64, 'a').join();
  final server = DirectoryPilotBuild.baseUrl;
  final user = UserModel(
    id: account,
    organizationId: ownOrganization,
    phoneComplete: true,
    phoneMasked: '***0042',
    role: 'personal',
    status: 'active',
    preferredUsageMode: 'personal',
  );
  final workspace = DirectoryWorkspace(
    server: server,
    accountId: account,
    organizationId: org,
  );
  late Directory root;
  late FixtureDirectoryKeys keys;
  late BusinessEmployeeReadCache cache;
  final branchToken = _jwt({
    'typ': 'branch_scope',
    'sub': account,
    'mode': 'branch',
    'org': org,
    'branch': branch,
    'qa_employee_finance': {'employee_id': employee, 'revision': revision},
  });
  String accessToken(String sid) =>
      _jwt({'sub': account, 'sid': sid, 'type': 'access'});

  Map<String, dynamic> frame({DateTime? expires}) {
    final now = DateTime.now();
    final identity = {
      'id': employee,
      'full_name': 'سالم الموظف',
      'linked_user_id': account,
    };
    final company = {'id': org, 'name': 'متجر الاختبار'};
    return {
      'account_id': account,
      'session_id': session,
      'branch_id': branch,
      'organization_id': org,
      'employee_id': employee,
      'grant_revision': revision,
      'expires_at': (expires ?? now.add(const Duration(hours: 1)))
          .toIso8601String(),
      'profile': {'employee': identity, 'organization': company},
      'employment': {
        'id': invitation,
        'status': 'accepted',
        'employee_id': employee,
        'employee': identity,
        'organization': company,
        'branch_ids': [branch],
        'branches': [
          {'id': branch, 'name': 'الفرع'},
        ],
      },
      'finance': {
        'employee_id': employee,
        'organization_id': org,
        'balances': {'SAR': '31.00'},
        'salary': [
          {
            'id': payment,
            'amount': '43.00',
            'currency': 'SAR',
            'paid_at': now.toIso8601String(),
            'invoice_no': payment,
            'branch_name': 'الفرع',
            'notes': 'راتب محفوظ',
          },
        ],
        'debts': [
          {
            'id': debt,
            'kind': 'charge',
            'direction': 'employee_owes',
            'amount': '36.00',
            'outstanding_amount': '31.00',
            'currency': 'SAR',
            'created_at': now.toIso8601String(),
            'invoice_no': debt,
            'notes': 'دين محفوظ',
          },
        ],
      },
    };
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await BranchScope.save(
      token: branchToken,
      branchId: branch,
      branchName: 'الفرع',
      allMode: false,
      organizationId: org,
    );
    await BranchScope.setHasMembership(true);
    root = await Directory.systemTemp.createTemp('fyona-staff-copy-');
    keys = FixtureDirectoryKeys();
    cache = BusinessEmployeeReadCache(() async => root, keys);
  });

  tearDown(() async {
    await cache.close();
    await root.delete(recursive: true);
    await BranchScope.clear();
  });

  test(
    'scope, session, expiry and interrupted cache replacement fail closed',
    () async {
      EmployeeReadSelection? resolve({
        String? selectedAccount,
        String? selectedOrg,
        String? selectedBranch,
        bool all = false,
      }) => resolveEmployeeReadSelection(
        server: server,
        account: selectedAccount ?? account,
        organization: selectedOrg ?? org,
        branch: selectedBranch ?? branch,
        token: branchToken,
        allMode: all,
      );
      final scope = resolve()!;
      expect(resolve(selectedAccount: _id()), isNull);
      expect(resolve(selectedOrg: _id()), isNull);
      expect(resolve(selectedBranch: _id()), isNull);
      expect(resolve(all: true), isNull);
      final data = frame();
      expect(
        await cache.replace(workspace, branch, data, current: () => true),
        isTrue,
      );
      var checks = 0;
      await expectLater(
        cache.replace(workspace, branch, {
          ...data,
          'finance': null,
        }, current: () => ++checks < 3),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      await cache.close();
      final reopened = await cache.read(workspace, branch);
      expect(
        EmployeeReadCopy.parse(reopened, scope, session)?.finance?['salary'],
        hasLength(1),
      );
      expect(EmployeeReadCopy.parse(reopened, scope, _id()), isNull);
      expect(
        EmployeeReadCopy.parse(frame(expires: DateTime.now()), scope, session),
        isNull,
      );
      final encrypted = File(DirectoryDatabase.filePath(root, workspace));
      expect(
        latin1.decode(await encrypted.readAsBytes()),
        isNot(contains('salary')),
      );
    },
    skip: !employeeDeviceFinanceEnabled,
  );

  testWidgets(
    'owner sync publishes only the addressed employee receipts after committing offline',
    (tester) async {
      final ownerId = _id();
      final scope = DirectoryAccess(
        workspace: DirectoryWorkspace(
          server: server,
          accountId: ownerId,
          organizationId: org,
        ),
        branchId: branch,
        financialCutover: true,
        readable: {},
        writable: {},
      );
      final ownerStore = DirectoryPilotStore(
        root: () async => root,
        keys: keys,
      );
      addTearDown(ownerStore.close);
      final grant = BusinessLedgerAccess(scope, {
        BusinessLedgerAction.payEmployeeSalary,
      });
      final anotherEmployee = _id();
      await tester.runAsync(() async {
        await BranchScope.save(
          token: 'owner-fixture',
          branchId: branch,
          branchName: 'الفرع',
          allMode: false,
          organizationId: org,
        );
        await ownerStore.remember(scope, {
          'status': 'active',
          'business_setup_completed': true,
          'sections': {
            'business': {
              'active': true,
              'end_date': DateTime.now()
                  .add(const Duration(hours: 2))
                  .toIso8601String(),
            },
          },
        });
        await ownerStore.withLedger(grant, () => scope, (ledger) async {
          await ledger.payEmployeeSalary(
            grant,
            commandId: payment,
            employeeId: employee,
            amountMinor: 4300,
            currency: 'SAR',
            notes: 'راتب محفوظ',
          );
          await ledger.payEmployeeSalary(
            grant,
            commandId: _id(),
            employeeId: anotherEmployee,
            amountMinor: 8000,
            currency: 'SAR',
            notes: 'خاص بموظف آخر',
          );
        });
      });
      final network = ConnectivityService(debugOnline: false);
      addTearDown(network.dispose);
      final http = Dio();
      addTearDown(() => http.close(force: true));
      final requests = <RequestOptions>[];
      http.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'data': request.method == 'GET'
                      ? {
                          'targets': [
                            {
                              'employee_id': employee,
                              'grant_revision': revision,
                              'version': 0,
                            },
                          ],
                        }
                      : {'version': 1},
                },
              ),
            );
          },
        ),
      );
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            (_) => _SignedIn(user.copyWith(id: ownerId)),
          ),
          serverBaseUrlProvider.overrideWith((_) => server),
          secureStorageProvider.overrideWithValue(
            _Vault(_jwt({'sub': ownerId, 'sid': session, 'type': 'access'})),
          ),
          businessLocalLedgerScopeProvider.overrideWithValue(scope),
          directoryPilotStoreProvider.overrideWithValue(ownerStore),
          connectivityServiceProvider.overrideWithValue(network),
          businessRelayHttpProvider.overrideWithValue(http),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const EmployeeDeviceFinanceRuntime(child: SizedBox()),
        ),
      );
      await tester.pump();
      expect(requests, isEmpty);
      network.debugSetOnline(true);
      for (var i = 0; i < 100 && requests.length < 2; ++i) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
      expect(requests.map((r) => r.method), ['GET', 'PUT']);
      expect(requests.last.uri.path, endsWith('/owner/$employee'));
      expect(requests.last.headers['X-Branch-Token'], 'owner-fixture');
      final rows = (requests.last.data as Map)['receipts'] as List;
      expect(
        rows.single,
        allOf(containsPair('id', payment), containsPair('amount_minor', 4300)),
      );
      expect(rows.single, isNot(contains('account_id')));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      container.dispose();
    },
    skip: !employeeDeviceFinanceEnabled,
  );

  testWidgets(
    'employee reopens the original cards offline; live denial hides even an open receipt',
    (tester) async {
      await tester.runAsync(() async {
        await AppLocalizations.preload('ar');
        await SectionHistory.save(account, 'business');
      });
      final connectivity = ConnectivityService(debugOnline: true);
      addTearDown(connectivity.dispose);
      final requests = <String>[];
      final legacy = Dio(BaseOptions(baseUrl: server));
      final network = Dio();
      var deny = false;
      var loseReply = false;
      final payload = frame();
      network.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add('${options.method} ${options.uri.path}');
            expect(options.headers['X-Branch-Token'], branchToken);
            expect(
              options.headers['Authorization'],
              'Bearer ${accessToken(session)}',
            );
            if (loseReply) {
              handler.reject(
                DioException.connectionError(
                  requestOptions: options,
                  reason: 'fixture',
                ),
              );
            } else if (deny) {
              handler.reject(
                DioException.badResponse(
                  statusCode: 403,
                  requestOptions: options,
                  response: Response(requestOptions: options, statusCode: 403),
                ),
              );
            } else {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {'data': payload},
                ),
              );
            }
          },
        ),
      );
      legacy.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add('legacy ${options.method} ${options.path}');
            handler.reject(
              DioException.connectionError(
                requestOptions: options,
                reason: 'fixture',
              ),
            );
          },
        ),
      );
      addTearDown(() {
        legacy.close(force: true);
        network.close(force: true);
      });
      final vault = _Vault(accessToken(session));
      ProviderContainer device() => ProviderContainer(
        overrides: [
          authProvider.overrideWith((_) => _SignedIn(user)),
          serverBaseUrlProvider.overrideWith((_) => server),
          apiClientProvider.overrideWithValue(ApiClient(dio: legacy)),
          secureStorageProvider.overrideWithValue(vault),
          connectivityServiceProvider.overrideWithValue(connectivity),
          employeeDeviceCacheProvider.overrideWithValue(cache),
          businessRelayHttpProvider.overrideWithValue(network),
        ],
      );
      Widget app(ProviderContainer container, GoRouter router) =>
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              locale: const Locale('ar'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              routerConfig: router,
            ),
          );
      Future<void> until(Finder finder) async {
        for (var i = 0; i < 120; ++i) {
          await tester.pump(const Duration(milliseconds: 20));
          if (finder.evaluate().isNotEmpty) return;
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        expect(
          finder,
          findsOneWidget,
          reason:
              'Requests: $requests; visible: '
              '${tester.widgetList<Text>(find.byType(Text)).map((w) => w.data).toList()}',
        );
      }

      final initial = device();
      final first = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => EmployeeDeviceFinanceRuntime(
              child: EmployeeFinanceReceiptPage(
                employeeId: employee,
                recordId: payment,
                kind: 'salary',
              ),
            ),
          ),
        ],
      );
      await tester.pumpWidget(app(initial, first));
      await until(find.text('راتب محفوظ'));
      expect(requests, ['GET /api/v1/business/employee-finance/me']);
      expect(initial.read(businessLocalLedgerScopeProvider), isNull);
      await tester.runAsync(() async {
        final api = initial.read(employeeApiProvider);
        await expectLater(
          api.paySalary(employee, {'amount': 50}),
          throwsA(isA<DirectoryAccessDenied>()),
        );
        await expectLater(
          initial.read(employeeFinanceForProvider(_id()).future),
          throwsA(isA<DirectoryAccessDenied>()),
        );
      });

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      first.dispose();
      initial.dispose();
      await tester.runAsync(cache.close);
      connectivity.debugSetOnline(false);
      requests.clear();
      final reopened = device();
      final router = GoRouter(
        initialLocation: '/account-entry',
        routes: [
          GoRoute(
            path: '/account-entry',
            builder: (_, _) => const AccountEntryPage(),
          ),
          GoRoute(
            path: '/job-requests',
            builder: (_, _) =>
                const EmployeeDeviceFinanceRuntime(child: JobRequestsPage()),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(app(reopened, router));
      await until(find.text('متجر الاختبار'));
      await tester.tap(find.text('متجر الاختبار'));
      await until(find.text('راتبي'));
      await tester.tap(find.text('راتبي'));
      await until(find.textContaining(payment));
      expect(find.text('صرف راتب'), findsNothing);
      Navigator.of(tester.element(find.text('رواتبي'))).pop();
      await tester.pumpAndSettle();
      await until(find.text('ديوني'));
      await tester.tap(find.text('ديوني'));
      await until(find.textContaining(debt));
      expect(find.text('إنشاء دين جديد'), findsNothing);
      await tester.tap(find.textContaining(debt));
      await until(find.byType(ReceiptModal));
      expect(requests, isEmpty);

      // The failed network request is not a denial, and removes no saved data.
      loseReply = true;
      connectivity.debugSetOnline(true);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(ReceiptModal), findsOneWidget);
      loseReply = false;
      deny = true;
      connectivity.debugSetOnline(true);
      await until(find.text('ما عندك صلاحية لهذي العملية الآن'));
      expect(find.byType(ReceiptModal), findsNothing);
      expect(find.textContaining(debt), findsNothing);
      expect(
        await tester.runAsync(() => cache.read(workspace, branch)),
        isNull,
      );
      expect(
        requests.where((r) => r.endsWith('/business/employee-finance/me')),
        hasLength(2),
      );
      // Once online the original invitation list may refresh; the financial
      // screens never fall back to the connected finance writer or reader.
      expect(
        requests.where((r) => r.startsWith('legacy')),
        everyElement(startsWith('legacy GET /employees/invitations')),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      reopened.dispose();
      await tester.runAsync(cache.close);
    },
    skip: !employeeDeviceFinanceEnabled,
  );
}
