import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/di/providers.dart' show apiClientProvider;
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_commerce/all_branches_commerce.dart';
import 'package:fyona_flutter/features/core_business/data/local_commerce/local_commerce_api.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/inventory/presentation/providers/inventory_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

DirectoryAccess _scope(DirectoryWorkspace workspace, String branch, {DateTime? expiry}) =>
    DirectoryAccess(
      workspace: workspace,
      branchId: branch,
      readable: DirectoryPartyKind.values.toSet(),
      writable: DirectoryPartyKind.values.toSet(),
      financialCutover: true,
      transferExpiry: expiry,
    );

void main() {
  test('a background refresh of the same branch keeps the same device API '
      '(the product form is not replaced by «غير مصرح بالوصول»)', () async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(BranchScope.clear);
    final root = await Directory.systemTemp.createTemp('fyona-bridge-refresh-');
    addTearDown(() => root.delete(recursive: true));
    final store = DirectoryPilotStore(root: () async => root, keys: FixtureDirectoryKeys());
    addTearDown(store.close);
    final workspace = DirectoryWorkspace(
      server: DirectoryPilotBuild.baseUrl,
      accountId: _id(),
      organizationId: _id(),
    );
    final branch = _id();
    await BranchScope.save(
      token: 'fixture',
      branchId: branch,
      branchName: 'Device',
      allMode: false,
      organizationId: workspace.organizationId,
    );
    await store.remember(_scope(workspace, branch), {
      'status': 'active',
      'business_setup_completed': true,
      'sections': {
        'business': {
          'active': true,
          'end_date': DateTime.now().add(const Duration(days: 1)).toIso8601String(),
        },
      },
    });
    final current = StateProvider<DirectoryAccess?>((_) => _scope(workspace, branch));
    final container = ProviderContainer(overrides: [
      directoryPilotStoreProvider.overrideWithValue(store),
      businessLocalLedgerScopeProvider.overrideWith((ref) => ref.watch(current)),
      employeeCanProvider.overrideWith((ref, key) => true),
      allBranchesCommerceProvider.overrideWith((ref) => null),
      apiClientProvider.overrideWithValue(ApiClient(dio: Dio())),
    ]);
    addTearDown(container.dispose);
    final watched = <Object>[];
    container.listen(inventoryApiProvider, (_, next) => watched.add(next), fireImmediately: true);
    final bridge = container.read(localCommerceBridgeProvider);
    final api = container.read(inventoryApiProvider);
    expect(api, isA<LocalInventoryApi>());
    expect(bridge.active, isTrue);

    // Auth reload / branch-token refresh: a new but equivalent scope object
    // (fresh transfer expiry), then an epoch bump from access polling.
    final refreshed = _scope(workspace, branch, expiry: DateTime.utc(2030));
    container.read(current.notifier).state = refreshed;
    container.read(branchEpochProvider.notifier).state++;
    await Future<void>.delayed(Duration.zero);
    expect(identical(container.read(localCommerceBridgeProvider), bridge), isTrue);
    expect(identical(container.read(inventoryApiProvider), api), isTrue);
    expect(watched, hasLength(1));
    // Still usable after the refresh (the bridge was not retired).
    expect(bridge.active, isTrue);
    expect(await api.categories(), isA<List>());

    // A real change of branch still yields a new source.
    final other = _id();
    await BranchScope.save(
      token: 'fixture',
      branchId: other,
      branchName: 'Other',
      allMode: false,
      organizationId: workspace.organizationId,
    );
    container.read(current.notifier).state = _scope(workspace, other);
    container.read(branchEpochProvider.notifier).state++;
    await Future<void>.delayed(Duration.zero);
    expect(identical(container.read(localCommerceBridgeProvider), bridge), isFalse);
    expect(identical(container.read(inventoryApiProvider), api), isFalse);
    // The old branch's API no longer reads.
    await expectLater(api.categories(), throwsA(isA<DirectoryAccessDenied>()));
  });
}
