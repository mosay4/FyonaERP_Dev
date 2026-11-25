import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/all_branches_ledger.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/presentation/providers/business_all_branches_provider.dart';
import 'package:fyona_flutter/features/reports/data/business_report_rates.dart';
import 'package:fyona_flutter/features/reports/data/reports_api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

void main() {
  test('«جميع الفروع»: the report-currency picker offers the union of every '
      'branch\'s enabled currencies (an unused YER_OLD cash included)', () async {
    SharedPreferences.setMockInitialValues({});
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
    );
    final root = await Directory.systemTemp.createTemp('fyona-all-currencies-');
    final keys = FixtureDirectoryKeys();
    final store = DirectoryPilotStore(root: () async => root, keys: keys);
    addTearDown(() async {
      await store.close();
      await root.delete(recursive: true);
      BranchScope.allMode = false;
    });
    final a = _id(), b = _id();
    await store.remember(scope(a), {
      'status': 'active',
      'business_setup_completed': true,
      'sections': {
        'business': {
          'active': true,
          'end_date': DateTime.now().add(const Duration(days: 1)).toIso8601String(),
        },
      },
    });
    final db = await DirectoryDatabase.open(root: root, workspace: workspace, keys: keys);
    final write = BusinessLedgerAction.values.toSet();
    // Branch A works in SAR; branch B customized SAR + USD + the old rial,
    // with no movement in the old rial yet.
    await db.ledger.customizeCashCurrencies(
      BusinessLedgerAccess(scope(a), write),
      commandId: _id(),
      currencies: {'SAR'},
      expected: {},
    );
    await db.ledger.customizeCashCurrencies(
      BusinessLedgerAccess(scope(b), write),
      commandId: _id(),
      currencies: {'SAR', 'USD', 'YER_OLD'},
      expected: {},
    );
    await db.close();

    BranchScope.allMode = true;
    final view = BusinessAllBranches(
      workspace: workspace,
      store: store,
      branches: () async => {a: 'الرياض', b: 'عدن'},
      isCurrent: () => true,
    );
    final container = ProviderContainer(overrides: [
      businessAllBranchesProvider.overrideWithValue(view),
      businessReportRatesProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    final api = container.read(businessReportsApiProvider);
    expect(api.isAllBranches, isTrue);
    expect(await api.deviceCurrencies(), containsAll({'SAR', 'USD', 'YER_OLD'}));
  });
}
