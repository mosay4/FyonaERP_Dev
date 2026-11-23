import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/di/providers.dart' show apiClientProvider;
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/branches/data/branch_api.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/branches/data/branch_revocation.dart';
import 'package:fyona_flutter/features/business_banks/presentation/providers/local_business_banking.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/project_settings_api.dart';
import 'package:fyona_flutter/features/core_business/presentation/providers/biz_payment_pref.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_device_finance_provider.dart';
import 'package:fyona_flutter/shared/widgets/merchant_workspace_gate.dart';
import 'package:fyona_flutter/shared/providers/current_user_provider.dart';
import 'package:fyona_flutter/shared/models/user_model.dart';

class _Accounts implements HttpClientAdapter {
  RequestOptions? request;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    return ResponseBody.fromString(
      jsonEncode([
        {
          'id': 'bank-2',
          'bank_name': 'Second Bank',
          'balance': '11.25',
          'currency': 'USD',
          'branch_id': 'second',
          'account_type': 'checking',
        },
      ]),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _SharedSettings extends ProjectSettingsApi {
  _SharedSettings() : super(ApiClient(dio: Dio()));
  Map<String, dynamic> values = {'allow_negative': false};
  @override
  Future<Map<String, dynamic>> load() async => Map.of(values);
  @override
  Future<void> save(Map<String, dynamic> patch) async {
    values.addAll(patch);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await BranchScope.clear();
  });

  test(
    'payment account provider parses server Decimal strings and preserves selected branch',
    () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
      final adapter = _Accounts();
      dio.httpClientAdapter = adapter;
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          // This fixture exercises the connected response, not device payroll.
          employeeDeviceSelectionProvider.overrideWithValue(null),
          businessLocalLedgerScopeProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      final accounts = await container.read(
        employeePaymentAccountsProvider('second').future,
      );
      expect(accounts.single.balance, 11.25);
      expect(accounts.single.id, 'bank-2');
      expect(adapter.request!.queryParameters['branch_id'], 'second');
    },
  );

  test(
    'company allow-negative propagates between employee and merchant preferences',
    () async {
      BranchScope.organizationId = 'merchant';
      final server = _SharedSettings();
      ProviderContainer connectedCompany() => ProviderContainer(
        overrides: [
          projectSettingsApiProvider.overrideWithValue(server),
          localBusinessBankingProvider.overrideWithValue(null),
        ],
      );
      final employee = connectedCompany();
      final merchant = connectedCompany();
      addTearDown(employee.dispose);
      addTearDown(merchant.dispose);
      final a = employee.read(bizPaymentPrefProvider.notifier);
      final b = merchant.read(bizPaymentPrefProvider.notifier);
      await a.load();
      await b.load();
      expect(merchant.read(bizPaymentPrefProvider).allowNegative, isFalse);
      await a.setAllowNegative(true);
      merchant.invalidate(projectSettingsProvider);
      await b.load();
      expect(merchant.read(bizPaymentPrefProvider).allowNegative, isTrue);
      await b.setAllowNegative(false);
      employee.invalidate(projectSettingsProvider);
      await a.load();
      expect(employee.read(bizPaymentPrefProvider).allowNegative, isFalse);
    },
  );

  testWidgets(
    'expired merchant is blocked with logo and employee can return to private account',
    (tester) async {
      await BranchScope.save(
        token: 'scope-token',
        branchId: 'branch',
        branchName: 'Store',
        allMode: false,
        organizationId: 'merchant',
      );
      final router = GoRouter(
        initialLocation: '/dashboard',
        routes: [
          GoRoute(
            path: '/dashboard',
            builder: (_, _) => const Scaffold(
              body: MerchantWorkspaceGate(
                route: '/dashboard',
                child: Text('Secret bank data'),
              ),
            ),
          ),
          GoRoute(
            path: '/personal',
            builder: (_, _) => const Scaffold(body: Text('Private account')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserProvider.overrideWithValue(
              const UserModel(id: 'user', organizationId: 'own', role: 'owner'),
            ),
            branchAccessProvider.overrideWith(
              (ref) async => [
                {
                  'organization_id': 'merchant',
                  'role': 'member',
                  'owner_expired': true,
                },
              ],
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Secret bank data'), findsNothing);
      expect(find.text('The store subscription has expired'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      await tester.tap(find.text('Return to my account'));
      await tester.pumpAndSettle();
      expect(find.text('Private account'), findsOneWidget);
      expect(BranchScope.token, isNull);
    },
  );

  testWidgets('renewal removes workspace block without relinking', (
    tester,
  ) async {
    BranchScope.organizationId = 'merchant';
    BranchScope.token = 'scope';
    var expired = true;
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWithValue(
          const UserModel(id: 'user', organizationId: 'own'),
        ),
        branchAccessProvider.overrideWith(
          (ref) async => [
            {
              'organization_id': 'merchant',
              'role': 'member',
              'owner_expired': expired,
            },
          ],
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: MerchantWorkspaceGate(
              route: '/dashboard',
              child: Text('Store workspace'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Store workspace'), findsNothing);
    container.read(merchantSubscriptionBlockedScopeProvider.notifier).state =
        'scope';
    expired = false;
    container.invalidate(branchAccessProvider);
    await tester.pumpAndSettle();
    expect(find.text('Store workspace'), findsOneWidget);
    expect(container.read(merchantSubscriptionBlockedScopeProvider), isNull);
  });
}
