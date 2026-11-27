// Branch backup file (.fyonabiz) kept on the phone: restored from the
// picked file, any size once its first page opens with the recovery code;
// unknown files stay under the 64 MB cap and are refused early.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/storage/free_space.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_local_backups.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../support/directory_test_keys.dart';

String _id() => const Uuid().v4();

Map<String, dynamic> _entitlement() => {
      'status': 'active', 'business_setup_completed': true,
      'sections': {'business': {'active': true, 'end_date': DateTime.now().add(const Duration(days: 2)).toIso8601String()}},
    };

void main() {
  if (!DirectoryPilotBuild.signupEnabled) {
    test('branch file restore', () {}, skip: 'needs the QA directory defines');
    return;
  }
  sqfliteFfiInit();
  late Directory dir;
  late DirectoryAccess scope;
  late DirectoryPilotStore phone1, phone2;
  late BusinessLedgerAccess grant;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fyona-bizfile-');
    final w = DirectoryWorkspace(server: DirectoryPilotBuild.baseUrl, accountId: _id(), organizationId: _id());
    scope = DirectoryAccess(workspace: w, branchId: _id(), readable: DirectoryPartyKind.values.toSet(),
        writable: DirectoryPartyKind.values.toSet(), financialCutover: true);
    grant = BusinessLedgerAccess(scope, BusinessLedgerAction.values.toSet());
    phone1 = DirectoryPilotStore(root: () async => Directory('${dir.path}/p1'), keys: FixtureDirectoryKeys());
    phone2 = DirectoryPilotStore(root: () async => Directory('${dir.path}/p2'), keys: FixtureDirectoryKeys());
    for (final s in [phone1, phone2]) {
      await s.remember(scope, _entitlement());
    }
    await phone1.withLedger(grant, () => scope, (l) => l.createAccount(grant, commandId: _id(),
        bankName: 'Cash', accountName: 'Till', accountNumber: '1', currency: 'SAR', openingMinor: 125000));
  });
  tearDown(() async {
    FreeSpace.probe = null;
    await phone1.close();
    await phone2.close();
    await dir.delete(recursive: true);
  });

  LocalBusinessBackups files(DirectoryPilotStore s, String name) =>
      LocalBusinessBackups(scope, s, () async => Directory('${dir.path}/$name-backups'), () => scope);

  (Stream<List<int>>, int Function()) counted(Stream<List<int>> s) {
    var n = 0;
    return (s.map((b) {
      n += b.length;
      return b;
    }), () => n);
  }

  test('a genuine file restores on a new phone, with progress; a second restore is not doubled', () async {
    final code = BusinessBackupCode.generate();
    final made = await files(phone1, 'p1').create(code);
    final stages = <BusinessBackupStage, double>{};
    final r = await files(phone2, 'p2').restoreStream(made.file.openRead(), code,
        size: made.bytes, onProgress: (s, d) => stages[s] = d);
    expect(r.alreadyRestored, isFalse);
    expect(stages[BusinessBackupStage.reading], 1.0);
    expect(stages[BusinessBackupStage.applying], 1.0);
    final a = await phone1.withLedger(grant, () => scope, (l) => l.accounts(grant));
    final b = await phone2.withLedger(grant, () => scope, (l) => l.accounts(grant));
    expect(b.toString(), a.toString());
    final again = await files(phone2, 'p2').restoreStream(made.file.openRead(), code, size: made.bytes);
    expect(again.alreadyRestored, isTrue);
    expect((await phone2.withLedger(grant, () => scope, (l) => l.accounts(grant))).length, a.length);
  });

  test('an unknown file is refused after its first 1 MB, whatever its size', () async {
    final rnd = Random(7);
    // 80 MB of noise named like a backup: over the 64 MB cap for unknown files.
    Stream<List<int>> noise() async* {
      for (var i = 0; i < 80; i++) {
        yield Uint8List.fromList(List.generate(1 << 20, (_) => rnd.nextInt(256)));
      }
    }

    final (input, read) = counted(noise());
    await expectLater(files(phone2, 'p2').restoreStream(input, BusinessBackupCode.generate(), size: 80 << 20),
        throwsA(isA<BusinessBackupRejected>()));
    expect(read(), lessThanOrEqualTo(businessBackupHeadProbe + (1 << 20)));
    expect(await phone2.withLedger(grant, () => scope, (l) => l.accounts(grant)), isEmpty);
  });

  test('a genuine file with the wrong code is refused; nothing restored', () async {
    final made = await files(phone1, 'p1').create(BusinessBackupCode.generate());
    await expectLater(files(phone2, 'p2').restoreStream(made.file.openRead(), BusinessBackupCode.generate()),
        throwsA(isA<BusinessBackupRejected>()));
    expect(await phone2.withLedger(grant, () => scope, (l) => l.accounts(grant)), isEmpty);
  });

  test('not enough free space: refused before reading the file', () async {
    final code = BusinessBackupCode.generate();
    final made = await files(phone1, 'p1').create(code);
    FreeSpace.probe = (_) async => 1024;
    final (input, read) = counted(made.file.openRead());
    await expectLater(files(phone2, 'p2').restoreStream(input, code, size: made.bytes), throwsA(isA<NotEnoughSpace>()));
    expect(read(), 0);
  });

  test('a large genuine file (announced over 64 MB) proves itself on its first page; a wrong code stops at 1 MB', () async {
    // Enough rows for a file past the 1 MB probe.
    for (var i = 0; i < 2600; i++) {
      await phone1.withLedger(grant, () => scope, (l) => l.addPartyWithOpeningDebt(grant, DirectoryPartyKind.customer,
          commandId: _id(), name: 'عميل ${'س' * 90} $i', amountMinor: 100 + i, currency: 'SAR'));
    }
    final code = BusinessBackupCode.generate();
    final made = await files(phone1, 'p1').create(code);
    expect(made.bytes, greaterThan(businessBackupHeadProbe + (256 << 10)));
    // The picker announces a size over the 64 MB cap for unknown files.
    const announced = businessBackupMaxBytes + 4096; // whole pages, as a real file
    final (wrongIn, wrongRead) = counted(made.file.openRead());
    await expectLater(files(phone2, 'p2').restoreStream(wrongIn, BusinessBackupCode.generate(), size: announced),
        throwsA(isA<BusinessBackupRejected>()));
    expect(wrongRead(), lessThan(made.bytes));
    expect(await phone2.withLedger(grant, () => scope, (l) => l.accounts(grant)), isEmpty);
    final r = await files(phone2, 'p2').restoreStream(made.file.openRead(), code, size: announced);
    expect(r.alreadyRestored, isFalse);
    final a = await phone1.withLedger(grant, () => scope, (l) => l.debtReport(grant, currency: 'SAR'));
    final b = await phone2.withLedger(grant, () => scope, (l) => l.debtReport(grant, currency: 'SAR'));
    expect((b['customers'] as Map)['total'], (a['customers'] as Map)['total']);
    expect((b['customers'] as Map)['count'], 2600);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
