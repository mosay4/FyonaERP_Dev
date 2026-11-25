import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/features/ai/domain/agent/business_device_loop.dart';
import 'package:fyona_flutter/features/ai/domain/agent/business_device_router.dart';
import 'package:fyona_flutter/features/ai/domain/services/ai_service.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/all_branches_ledger.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/presentation/providers/business_all_branches_provider.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/shared/providers/current_user_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

void main() {
  final workspace = DirectoryWorkspace(
    server: DirectoryPilotBuild.baseUrl,
    accountId: _id(),
    organizationId: _id(),
  );
  late String a, b, c;
  late Directory root;
  late FixtureDirectoryKeys keys;
  late DirectoryPilotStore store;
  DirectoryAccess scope(String branch) => DirectoryAccess(
    workspace: workspace, branchId: branch, readable: {}, writable: {}, financialCutover: true);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('fyona-probe-');
    keys = FixtureDirectoryKeys();
    store = DirectoryPilotStore(root: () async => root, keys: keys);
    a = _id(); b = _id(); c = _id();
    await store.remember(scope(a), {
      'status': 'active', 'business_setup_completed': true,
      'sections': {'business': {'active': true, 'end_date': DateTime.now().add(const Duration(days: 1)).toIso8601String()}},
    });
    final db = await DirectoryDatabase.open(root: root, workspace: workspace, keys: keys);
    final write = BusinessLedgerAction.values.toSet();
    await db.ledger.createAccount(BusinessLedgerAccess(scope(a), write), commandId: _id(), bankName: 'كاش',
        accountName: 'كاش', accountNumber: '1', currency: 'SAR', openingMinor: 1000, managed: true);
    await db.close();
  });

  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
    BranchScope.allMode = false;
  });

  test('every Sara read answers in «جميع الفروع», none waits forever', () async {
    BranchScope.allMode = true;
    final all = BusinessAllBranches(workspace: workspace, store: store,
        branches: () async => {a: 'الرياض', b: 'جدة', c: 'فرع تجربة الدليل'}, isCurrent: () => true);
    final container = ProviderContainer(overrides: [
      businessAllBranchesProvider.overrideWithValue(all),
      directoryPilotStoreProvider.overrideWithValue(store),
      currentUserProvider.overrideWithValue(null),
      employeeWorkspaceCompanyProvider.overrideWithValue(null),
      employeePermissionsProvider.overrideWithValue(const {}),
    ]);
    addTearDown(container.dispose);
    for (final route in BusinessDeviceRouter.readRoutes) {
      final path = route.substring(4).replaceAll(RegExp(r'\{[^}]+\}'), 'x');
      final r = await BusinessDeviceRouter.handle(container.read, method: 'GET', path: path,
          params: {'from': 'SAR', 'to': 'USD', 'code': '1'}).timeout(const Duration(seconds: 8));
      expect(r.containsKey('success'), isTrue, reason: route);
    }
    final banks = await BusinessDeviceRouter.handle(container.read, method: 'GET', path: '/banking/accounts');
    expect(banks['success'], isTrue);
  });

  group('device loop always ends with a reply', () {
    AiAgentResponse paused(int n) => AiAgentResponse(text: '',
        deviceCalls: [{'id': 'c$n', 'method': 'GET', 'path': '/invoices'}], state: {'steps': n});

    test('a read that never finishes is answered as a timeout, Sara still replies', () async {
      final sent = <List<Map<String, dynamic>>>[];
      final reply = await BusinessDeviceLoop.run(paused(1),
          perCall: const Duration(milliseconds: 50),
          handle: (_) => Completer<Map<String, dynamic>>().future,
          resume: (state, results) async {
            sent.add(results);
            return const AiAgentResponse(text: 'هذه أرقام الفروع التي قرأتها.');
          });
      expect(reply!.text, 'هذه أرقام الفروع التي قرأتها.');
      final result = sent.single.single['result'] as Map;
      expect(result['success'], isFalse);
      expect(result['coverage'], 'timeout');
    });

    test('a model that keeps asking ends with a clear message, never an empty bubble', () async {
      var rounds = 0;
      final reply = await BusinessDeviceLoop.run(paused(0),
          handle: (_) async => {'success': true, 'data': []},
          resume: (state, results) async => paused(++rounds));
      expect(rounds, BusinessDeviceLoop.maxRounds);
      expect(reply!.text, contains('سؤالًا أضيق'));
      expect(reply.deviceCalls, isEmpty);
    });

    test('the time budget stops a slow conversation with a clear message', () async {
      final reply = await BusinessDeviceLoop.run(paused(0),
          total: const Duration(milliseconds: 120),
          handle: (_) async {
            await Future<void>.delayed(const Duration(milliseconds: 80));
            return {'success': true, 'data': []};
          },
          resume: (state, results) async => paused(1));
      expect(reply!.text, contains('سؤالًا أضيق'));
    });

    test('closing the page or switching branch drops the reply', () async {
      var alive = true;
      final reply = await BusinessDeviceLoop.run(paused(0), alive: () => alive,
          handle: (_) async { alive = false; return {'success': true}; },
          resume: (state, results) async => const AiAgentResponse(text: 'x'));
      expect(reply, isNull);
    });

    test('merged lists of every branch are trimmed under the server limit with honest coverage', () {
      final rows = [
        for (var i = 0; i < 900; i++)
          {'id': '$i', 'number': 'INV-$i', 'total': '120.00', 'currency': 'SAR',
           'branch_name': i.isEven ? 'الرياض' : 'فرع تجربة الدليل', 'party': 'عميل رقم $i',
           'image': 'x' * 2000},
      ];
      final out = BusinessDeviceLoop.compact({'success': true, 'data': rows});
      expect(jsonEncode(out).length, lessThanOrEqualTo(BusinessDeviceLoop.resultLimit));
      final kept = out['data'] as List;
      expect(kept, isNotEmpty);
      expect((kept.first as Map)['image'], startsWith('[omitted'));
      expect(out['data_coverage'], containsPair('total', 900));
      expect((out['data_coverage'] as Map)['shown'], kept.length);
      final small = {'success': true, 'data': [1, 2, 3]};
      expect(identical(BusinessDeviceLoop.compact(small), small), isTrue);
    });
  });
}
