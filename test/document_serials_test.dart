// Short, sequential document numbers (owner, 28-11): OPEN-1, OPEN-2… in
// the order they were made, instead of a long unique code; a short number
// typed in a search finds its document.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/utils/document_number.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_party.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

void main() {
  if (!DirectoryPilotBuild.signupEnabled) {
    test('document serials', () {}, skip: 'needs the QA directory defines');
    return;
  }
  sqfliteFfiInit();

  test('opening balances get OPEN-1, OPEN-2, OPEN-3 in creation order', () async {
    final tmp = await Directory.systemTemp.createTemp('fyona-serials-');
    addTearDown(() => tmp.delete(recursive: true));
    final w = DirectoryWorkspace(server: DirectoryPilotBuild.baseUrl, accountId: _id(), organizationId: _id());
    final scope = DirectoryAccess(workspace: w, branchId: _id(), readable: DirectoryPartyKind.values.toSet(),
        writable: DirectoryPartyKind.values.toSet(), financialCutover: true);
    final grant = BusinessLedgerAccess(scope, BusinessLedgerAction.values.toSet());
    final db = await DirectoryDatabase.open(root: tmp, workspace: w, keys: FixtureDirectoryKeys(tmp));
    final numbers = <String>[];
    for (final name in ['أ', 'ب', 'ج']) {
      final r = await db.ledger.addPartyWithOpeningDebt(grant, DirectoryPartyKind.customer,
          commandId: _id(), name: 'عميل $name', amountMinor: 100, currency: 'SAR');
      final party = DirectoryPartyReference(scope: scope, kind: DirectoryPartyKind.customer, id: '${r['party_id']}');
      numbers.add('${(await db.ledger.debts(grant, party)).single['number']}');
    }
    expect(numbers.every((n) => n.startsWith('OPEN-') && n.length > 40), isTrue, reason: 'stored: long and unique');
    DocumentSerials.put(await db.ledger.documentSerials(grant));
    expect([for (final n in numbers) shortDocumentNumber(n)], ['OPEN-1', 'OPEN-2', 'OPEN-3']);
    expect(DocumentSerials.full('open-2'), numbers[1].toUpperCase());
    expect(DocumentSerials.missing(numbers[0]), isFalse);
    // Not read yet (a new document): the short code until the next read.
    DocumentSerials.put(const {});
    expect(shortDocumentNumber(numbers[0]), startsWith('OPEN-'));
    expect(shortDocumentNumber(numbers[0]).length, lessThan(16));
    await db.close();
  });
}
