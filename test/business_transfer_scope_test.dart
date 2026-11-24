import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/di/providers.dart' show apiClientProvider;
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/branches/data/branch_api.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/branches/presentation/pages/branch_transfers_page.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

void main() {
  late String a, b, productId;
  final workspace = DirectoryWorkspace(
    server: DirectoryPilotBuild.baseUrl,
    accountId: _id(),
    organizationId: _id(),
  );
  DirectoryAccess scope(String branch) => DirectoryAccess(
    workspace: workspace,
    branchId: branch,
    readable: {},
    writable: {},
    financialCutover: true,
    transferBranches: {a: 'الفرع الأول', b: 'الفرع الثاني'},
  );
  final all = BusinessLedgerAction.values.toSet();
  late Directory root;
  late FixtureDirectoryKeys keys;
  late DirectoryPilotStore store;
  late DirectoryDatabase db;
  late int requests;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    requests = 0;
    root = await Directory.systemTemp.createTemp('fyona-transfer-scope-');
    keys = FixtureDirectoryKeys();
    store = DirectoryPilotStore(root: () async => root, keys: keys);
    a = _id();
    b = _id();
    await store.remember(scope(a), {
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
    await store.remember(scope(b), {
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
    db = await DirectoryDatabase.open(
      root: root,
      workspace: workspace,
      keys: keys,
    );
    final seed = _id();
    final created = await db.ledger.createCommerceProduct(
      BusinessLedgerAccess(scope(a), all),
      commandId: seed,
      name: 'مياه',
      unit: 'قطعة',
      price: 1000,
      costPrice: 5,
      costCurrency: 'SAR',
      stock: 5,
    );
    productId = created['id'] as String;
    await db.ledger.createCommerceProduct(
      BusinessLedgerAccess(scope(b), all),
      commandId: seed,
      name: 'مياه',
      unit: 'قطعة',
      price: 1000,
      stock: 0,
    );
  });

  tearDown(() async {
    await db.close();
    await store.close();
    await root.delete(recursive: true);
    await BranchScope.clear();
  });

  testWidgets('the transfers screen works from the device store with no REST', (
    tester,
  ) async {
    await BranchScope.save(
      token: 'fixture',
      branchId: a,
      branchName: 'الفرع الأول',
      allMode: false,
      organizationId: workspace.organizationId,
    );
    final dio = Dio(BaseOptions(baseUrl: workspace.server));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests++;
          handler.reject(
            DioException.connectionError(
              requestOptions: request,
              reason: 'التحويل محلي على هذا الجهاز',
            ),
          );
        },
      ),
    );
    addTearDown(() => dio.close(force: true));
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        businessLocalLedgerScopeProvider.overrideWithValue(scope(a)),
        directoryPilotStoreProvider.overrideWithValue(store),
        employeeCanProvider.overrideWith((_, _) => true),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      await AppLocalizations.preload('ar');
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const BranchTransfersPage(),
        ),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
    }

    await settle();
    // The list reads the device store: no legacy request, no blocked screen.
    expect(
      find.text(AppLocalizations.t('branchTransferDeviceScope')),
      findsNothing,
    );
    expect(requests, 0);

    // The same methods the form submits through answer locally.
    final api = container.read(branchApiProvider);
    final options = await tester.runAsync(
      () => api.transferOptions(a, includeZero: true),
    );
    expect((options!['products'] as List), hasLength(1));
    final match = await tester.runAsync(
      () => api.productMatch(fromProductId: productId, toBranchId: b),
    );
    expect(match!['exists'], isTrue);
    final branches = await tester.runAsync(() => api.transferBranches());
    expect(branches, hasLength(1));
    final rows = await tester.runAsync(() => api.transfers());
    expect(rows, isEmpty);

    // The form opens with its own fields instead of a refusal.
    await tester.tap(find.byKey(const ValueKey('transfer_create')));
    await settle();
    await tester.tap(find.byKey(const ValueKey('transfer_inventory')));
    await settle();
    expect(
      find.text(AppLocalizations.t('branchTransferDeviceScope')),
      findsNothing,
    );
    Future<void> tapKey(String key) async {
      final target = find.byKey(ValueKey(key));
      await tester.ensureVisible(target);
      await tester.tap(target);
      await settle();
    }

    await tapKey('transfer_source_branch');
    await tester.tap(find.text('الفرع الأول').last);
    await settle();
    await tapKey('transfer_target_branch');
    await tester.tap(find.text('الفرع الثاني').last);
    await settle();
    await tapKey('transfer_inventory_picker');
    await tapKey('inventory-select-$productId');
    await tester.enterText(
      find.byKey(ValueKey('inventory-quantity-$productId')),
      '2',
    );
    await tapKey('inventory-confirm');
    // The form is a lazy list: bring the submit button into view first.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('transfer_submit')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await settle();
    expect(find.byKey(const ValueKey('transfer_submit')), findsOneWidget);

    // Use the real confirmation button twice in the same frame.
    await tester.tap(find.byKey(const ValueKey('transfer_submit')));
    await tester.tap(
      find.byKey(const ValueKey('transfer_submit')),
      warnIfMissed: false,
    );
    await settle();
    final confirm = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(
        FilledButton,
        AppLocalizations.t('branchConfirmTransfer'),
      ),
    );
    await tester.tap(confirm);
    await settle();
    expect(requests, 0);
    final listed = await tester.runAsync(() => api.transfers());
    final detail = await tester.runAsync(
      () => api.transfer(listed!.single['id'] as String),
    );
    expect(detail!['status'], 'done');
    expect((detail['items'] as List), hasLength(1));
    expect((options['products'] as List).single['available'], 5);
    final after = await tester.runAsync(
      () => api.transferOptions(a, includeZero: true),
    );
    expect((after!['products'] as List).single['available'], 3);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle();
  }, skip: !DirectoryPilotBuild.signupEnabled);

  testWidgets('the owner moves stock between two other branches', (
    tester,
  ) async {
    final c = _id();
    final third = DirectoryAccess(
      workspace: workspace,
      branchId: c,
      readable: {},
      writable: {},
      financialCutover: true,
      transferBranches: {a: 'الفرع الأول', b: 'الفرع الثاني'},
    );
    await BranchScope.save(
      token: 'fixture',
      branchId: c,
      branchName: 'الفرع الثالث',
      allMode: false,
      organizationId: workspace.organizationId,
    );
    final dio = Dio(BaseOptions(baseUrl: workspace.server));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests++;
          handler.reject(
            DioException.connectionError(
              requestOptions: request,
              reason: 'offline',
            ),
          );
        },
      ),
    );
    addTearDown(() => dio.close(force: true));
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        businessLocalLedgerScopeProvider.overrideWithValue(third),
        directoryPilotStoreProvider.overrideWithValue(store),
        employeeCanProvider.overrideWith((_, _) => true),
      ],
    );
    addTearDown(container.dispose);
    final api = container.read(branchApiProvider);
    final moved = await tester.runAsync(
      () => api.inventoryTransfer(
        fromBranchId: a,
        toBranchId: b,
        items: [
          {'from_product_id': productId, 'quantity': '2'},
        ],
      ),
    );
    expect(moved, isNotNull);
    expect(requests, 0);
    final after = await tester.runAsync(
      () => api.transferOptions(a, includeZero: true),
    );
    expect((after!['products'] as List).single['available'], 3);
    container.dispose();
    await tester.pump(const Duration(seconds: 30));
  }, skip: !DirectoryPilotBuild.signupEnabled);
}
