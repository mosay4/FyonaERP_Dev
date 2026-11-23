import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/storage/secure_storage.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/branches/data/branch_revocation.dart';
import 'package:fyona_flutter/features/employees/data/employee_api.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/employees/presentation/widgets/employee_unlink_action.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_detail_page.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/job_requests_page.dart';

class _Storage extends SecureStorageService {
  @override
  Future<String?> getToken() async => 'own-session';
  @override
  Future<String?> getRefreshToken() async => 'own-refresh';
}

class _RevokedAdapter implements HttpClientAdapter {
  int calls = 0;
  Future<void> Function()? beforeReply;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    if (beforeReply != null) await beforeReply!();
    return ResponseBody.fromString(
      '{"success":false,"message":{"code":"employee_workspace_revoked","message":"Unlinked"}}',
      403,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _EmployeeApi extends EmployeeApi {
  _EmployeeApi() : super(ApiClient(dio: Dio()));
  int unlinks = 0;
  @override
  Future<Map<String, dynamic>> unlink(String id) async {
    unlinks++;
    return {'organization_id': 'merchant-org', 'already_unlinked': false};
  }
}

Future<void> _scope(String token, String org) => BranchScope.save(
  token: token,
  branchId: 'branch',
  branchName: 'Store',
  allMode: false,
  organizationId: org,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await BranchScope.clear();
  });

  test(
    'revoked write is rejected once, cleared, and never retried in own company',
    () async {
      await _scope('revoked-token', 'merchant-org');
      final container = ProviderContainer(
        overrides: [secureStorageProvider.overrideWithValue(_Storage())],
      );
      addTearDown(container.dispose);
      final dio = container.read(dioProvider);
      final adapter = _RevokedAdapter();
      dio.httpClientAdapter = adapter;
      await expectLater(
        dio.post('/banking/accounts/bank/withdraw', data: {'amount': 10}),
        throwsA(isA<DioException>()),
      );
      expect(adapter.calls, 1);
      expect(BranchScope.token, isNull);
      expect(BranchScope.organizationId, isNull);
      expect(container.read(branchRevocationProvider), 1);
      await BranchScope.load();
      expect(BranchScope.token, isNull);
    },
  );

  test(
    'a late error from old company does not clear the newly selected company',
    () async {
      await _scope('old-token', 'old-org');
      final container = ProviderContainer(
        overrides: [secureStorageProvider.overrideWithValue(_Storage())],
      );
      addTearDown(container.dispose);
      final dio = container.read(dioProvider);
      final adapter = _RevokedAdapter()
        ..beforeReply = () => _scope('new-token', 'new-org');
      dio.httpClientAdapter = adapter;
      await expectLater(
        dio.get('/banking/accounts'),
        throwsA(isA<DioException>()),
      );
      expect(adapter.calls, 1);
      expect(BranchScope.token, 'new-token');
      expect(container.read(branchRevocationProvider), 0);
    },
  );

  for (final (merchant, verified) in [
    (false, false),
    (false, true),
    (true, false),
    (true, true),
  ]) {
    testWidgets('unlink gate merchant=$merchant verified=$verified', (
      tester,
    ) async {
      final api = _EmployeeApi();
      var verifierCalls = 0;
      bool? completed;
      await _scope('merchant-token', 'merchant-org');
      final container = ProviderContainer(
        overrides: [
          employeeApiProvider.overrideWithValue(api),
          employeeUnlinkVerifierProvider.overrideWithValue((
            context,
            ref,
            reason,
          ) async {
            verifierCalls++;
            return verified;
          }),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () async {
                    completed = await confirmEmployeeUnlink(
                      context,
                      ref,
                      employeeId: 'employee-id',
                      name: 'Store',
                      merchant: merchant,
                    );
                  },
                  child: const Text('Start'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      expect(api.unlinks, 0);
      expect(verifierCalls, 0);
      await tester.tap(find.widgetWithText(FilledButton, 'Unlink'));
      await tester.pumpAndSettle();
      expect(verifierCalls, 1);
      expect(api.unlinks, verified ? 1 : 0);
      expect(completed, verified);
      expect(
        BranchScope.token,
        verified && !merchant ? null : 'merchant-token',
      );
      expect(
        container.read(branchRevocationProvider),
        verified && !merchant ? 1 : 0,
      );
    });
  }

  testWidgets(
    'cancel confirmation never opens security verification or calls unlink',
    (tester) async {
      final api = _EmployeeApi();
      var verifierCalls = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            employeeApiProvider.overrideWithValue(api),
            employeeUnlinkVerifierProvider.overrideWithValue((
              context,
              ref,
              reason,
            ) async {
              verifierCalls++;
              return true;
            }),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () => confirmEmployeeUnlink(
                    context,
                    ref,
                    employeeId: 'employee-id',
                    name: 'Employee',
                    merchant: true,
                  ),
                  child: const Text('Start'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(verifierCalls, 0);
      expect(api.unlinks, 0);
    },
  );

  for (final linked in [false, true]) {
    testWidgets('merchant top unlink action appears only when linked=$linked', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            employeesProvider.overrideWith(
              (ref) async => [
                {
                  'id': 'e1',
                  'full_name': 'Staff HR',
                  'status': linked ? 'linked' : 'unlinked',
                  'salary': 0,
                  'permissions': <String, bool>{},
                },
              ],
            ),
          ],
          child: const MaterialApp(home: EmployeeDetailPage(id: 'e1')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Unlink'), linked ? findsOneWidget : findsNothing);
    });

    testWidgets(
      'employee invitation unlink action appears only when accepted=$linked',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              myInvitationsProvider.overrideWith(
                (ref) async => [
                  {
                    'id': 'i1',
                    'status': linked ? 'accepted' : 'pending',
                    'salary': 100,
                    'employee': {'id': 'e1', 'full_name': 'Staff HR'},
                    'organization': {'id': 'merchant-org', 'name': 'Store'},
                  },
                ],
              ),
              myEmployeeProfileProvider.overrideWith((ref) async => {}),
              employeeInvitationProvider('i1').overrideWith(
                (ref) async => {
                  'id': 'i1',
                  'status': linked ? 'accepted' : 'pending',
                  'salary': 100,
                  'employee': {'id': 'e1', 'full_name': 'Staff HR'},
                  'organization': {'id': 'merchant-org', 'name': 'Store'},
                },
              ),
            ],
            child: const MaterialApp(home: JobRequestsPage()),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Store'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          find.text('إلغاء الربط'),
          linked ? findsOneWidget : findsNothing,
        );
      },
    );
  }
}
