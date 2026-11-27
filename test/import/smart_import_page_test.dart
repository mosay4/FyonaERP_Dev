// The smart import screen: owner only, the three choices, columns step.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/import/presentation/smart_import_page.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_party.dart';

DirectoryAccess _scope({bool member = false}) => DirectoryAccess(
      workspace: DirectoryWorkspace(
          server: 'https://x.test/api/v1',
          accountId: '11111111-1111-4111-8111-111111111111',
          organizationId: '22222222-2222-4222-8222-222222222222'),
      branchId: '33333333-3333-4333-8333-333333333333',
      readable: DirectoryPartyKind.values.toSet(),
      writable: DirectoryPartyKind.values.toSet(),
      financialCutover: true,
      member: member,
    );

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('owner sees the entry; an employee does not', (tester) async {
    for (final member in [false, true]) {
      await tester.pumpWidget(ProviderScope(
        overrides: [businessLocalLedgerScopeProvider.overrideWithValue(_scope(member: member))],
        child: const MaterialApp(home: Scaffold(body: SmartImportEntry())),
      ));
      expect(find.byKey(const Key('si-entry')), member ? findsNothing : findsOneWidget);
    }
  });

  testWidgets('the page offers the three kinds of import and the file button', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [businessLocalLedgerScopeProvider.overrideWithValue(_scope())],
      child: const MaterialApp(home: SmartImportPage()),
    ));
    await tester.pump();
    for (final t in ['parties', 'products', 'archive']) {
      expect(find.byKey(Key('si-target-$t')), findsOneWidget);
    }
    expect(find.byKey(const Key('si-pick')), findsOneWidget);
    expect(find.byKey(const Key('si-preview')), findsNothing); // no file yet
  });
}
