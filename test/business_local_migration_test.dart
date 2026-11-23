import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_party.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

void main() {
  test('the one-time move of legacy data is owner-only and integrity-checked', () async {
    final workspace = DirectoryWorkspace(
      server: 'https://qa.fyonacompany.com:18443/api/v1',
      accountId: _id(),
      organizationId: _id(),
    );
    final root = await Directory.systemTemp.createTemp('fyona-migration-');
    addTearDown(() => root.delete(recursive: true));
    final db = await DirectoryDatabase.open(root: root, workspace: workspace, keys: FixtureDirectoryKeys());
    addTearDown(db.close);
    DirectoryAccess access({bool member = false}) => DirectoryAccess(
      workspace: workspace,
      branchId: '11111111-1111-4111-8111-111111111111',
      readable: DirectoryPartyKind.values.toSet(),
      writable: DirectoryPartyKind.values.toSet(),
      member: member,
    );
    // The rehearsal path still accepts only its synthetic server.
    await expectLater(
      db.importCutoverFixture(access(), payload: [1], expectedDigest: 'x'),
      throwsA(isA<DirectoryAccessDenied>()),
    );
    // Live: an altered payload never imports.
    await expectLater(
      db.importCutoverFixture(access(), payload: [1, 2, 3], expectedDigest: '0' * 64, live: true),
      throwsA(isA<BusinessCutoverImportRejected>()),
    );
    // An employee's device never imports the owner's legacy data.
    await expectLater(
      db.importCutoverFixture(access(member: true), payload: [1], expectedDigest: 'x', live: true),
      throwsA(isA<DirectoryAccessDenied>()),
    );
    expect(await db.cutoverFixtureReceipt(access(), live: true), isNull);
  });
}
