import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:csv/csv.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/backup/backup_worker.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/export/accounting_export_service.dart';
import 'package:fyona_flutter/core/media/media_store.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/core_business/data/local_commerce/local_commerce_api.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_party.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';

import '../support/directory_test_keys.dart';

String _id() => const Uuid().v4();

Map<String, dynamic> _entitlement() => {
      'status': 'active', 'business_setup_completed': true,
      'sections': {'business': {'active': true, 'end_date': DateTime.now().add(const Duration(days: 2)).toIso8601String()}},
    };

String _day(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Reads an export ZIP: manifest, CSV tables (as maps by header key order),
/// XLSX parts, other files.
class _Export {
  _Export(File zip) {
    final archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
    for (final f in archive.files) {
      if (f.isFile) files[f.name] = Uint8List.fromList(f.content as List<int>);
    }
    manifest = jsonDecode(utf8.decode(files['manifest.json']!)) as Map<String, dynamic>;
  }
  final files = <String, Uint8List>{};
  late final Map<String, dynamic> manifest;

  List<List<dynamic>> csv(String sheet) {
    final b = files['csv/$sheet.csv']!;
    expect(b.sublist(0, 3), [0xEF, 0xBB, 0xBF], reason: 'UTF-8 BOM');
    return const CsvDecoder(skipEmptyLines: true).convert(utf8.decode(b.sublist(3)));
  }

  /// Rows of [sheet] as {column key: value}.
  List<Map<String, String>> rows(String sheet) {
    final t = csv(sheet);
    final keys = businessExportSheets[sheet]!;
    return [for (final r in t.skip(1)) {for (var i = 0; i < keys.length; i++) keys[i]: '${r[i]}'}];
  }
}

void main() {
  if (!DirectoryPilotBuild.signupEnabled) return;
  sqfliteFfiInit();
  late Directory root;
  late FixtureDirectoryKeys keys;
  late DirectoryPilotStore store;
  late MediaStore media;
  final client = ApiClient(dio: Dio());
  final workspace = DirectoryWorkspace(server: DirectoryPilotBuild.baseUrl, accountId: _id(), organizationId: _id());
  DirectoryAccess branch(String id, {bool member = false}) => DirectoryAccess(workspace: workspace, branchId: id,
      readable: DirectoryPartyKind.values.toSet(), writable: DirectoryPartyKind.values.toSet(),
      financialCutover: true, member: member);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fyona-export-');
    keys = FixtureDirectoryKeys();
    store = DirectoryPilotStore(root: () async => root, keys: keys);
    media = MediaStore(Directory('${root.path}/media'));
    MediaStore.rootProvider = () async => media.root;
    MediaStore.reset();
    await MediaStore.instance();
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  /// Moves every record written in [from, to) of a branch to [day]: dates
  /// and timestamps together (as if done on that day).
  Future<void> travel(String branchId, int from, int to, DateTime day) async {
    await store.close();
    final db = await openLedgerFile(DirectoryDatabase.filePath(root, workspace), keys.memory[workspace.storageId]!);
    try {
      final shift = DateTime.now().microsecondsSinceEpoch - DateTime(day.year, day.month, day.day, 12).microsecondsSinceEpoch;
      for (final t in await db.rawQuery("SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'")) {
        final n = '${t['name']}';
        final cols = {for (final c in await db.rawQuery('PRAGMA table_info("$n")')) '${c['name']}'};
        if (!cols.contains('created_us') || !cols.contains('branch_id')) continue;
        final dates = [for (final c in ['date', 'invoice_date']) if (cols.contains(c)) c];
        await db.rawUpdate(
            'UPDATE "$n" SET ${[...dates.map((c) => '"$c" = ?'), 'created_us = created_us - ?'].join(', ')} '
            'WHERE branch_id = ? AND created_us >= ? AND created_us < ?',
            [for (final _ in dates) _day(day), shift, branchId, from, to]);
      }
    } finally {
      await db.close();
    }
  }

  test('opening balances at a cut-off day: exact against the app today, and history taken back for a past day',
      () async {
    final a = branch(_id()), other = branch(_id());
    for (final b in [a, other]) {
      await store.remember(b, _entitlement());
    }
    final g = BusinessLedgerAccess(a, BusinessLedgerAction.values.toSet());
    final inv = LocalInventoryApi(client, LocalCommerceBridge(store, () => a, (_) => true));
    final sales = LocalSalesApi(client, LocalCommerceBridge(store, () => a, (_) => true));
    final buy = LocalPurchaseApi(client, LocalCommerceBridge(store, () => a, (_) => true));
    final returns = LocalReturnsApi(client, LocalCommerceBridge(store, () => a, (_) => true));
    final now = DateTime.now();
    final d1 = now.subtract(const Duration(days: 10)), d2 = now.subtract(const Duration(days: 5)),
        d3 = now.subtract(const Duration(days: 2));

    // ---- Day 1 (before the cut-off).
    final t0 = DateTime.now().microsecondsSinceEpoch;
    final acct = await store.withLedger(g, () => a, (l) => l.createAccount(g, commandId: _id(),
        bankName: 'الصندوق', accountName: 'نقدي', accountNumber: '1', currency: 'SAR', openingMinor: 100000));
    final custA = (await store.withLedger(g, () => a, (l) => l.addPartyWithOpeningDebt(g, DirectoryPartyKind.customer,
        commandId: _id(), name: '=HYPERLINK("http://x")', amountMinor: 10000, currency: 'SAR')))['party_id'] as String;
    final custB = (await store.withLedger(g, () => a, (l) => l.addPartyWithOpeningDebt(g, DirectoryPartyKind.customer,
        commandId: _id(), name: 'عميل، "ب"', amountMinor: 0, currency: 'SAR')))['party_id'] as String;
    final supp = (await store.withLedger(g, () => a, (l) => l.addPartyWithOpeningDebt(g, DirectoryPartyKind.supplier,
        commandId: _id(), name: 'مورد', amountMinor: 0, currency: 'SAR')))['party_id'] as String;
    final photo = await media.put(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, ...List.generate(5000, (i) => i % 251)]),
        mime: 'image/jpeg');
    final x = await inv.createProduct({'name': 'منتج س', 'unit': 'قطعة', 'price': 50.0, 'cost': 30.0, 'stock': 100, 'image': photo});
    final y = await inv.createProduct({'name': 'منتج ص', 'unit': 'قطعة', 'price': 10.0, 'cost': 8.0, 'stock': 10});
    final z = await inv.createProduct({'name': 'منتج ع', 'unit': 'قطعة', 'price': 60.0, 'cost': 40.0, 'stock': 20});
    final s1 = await sales.issueSale({
      'currency': 'SAR', 'customer_id': custA, 'idempotency_key': _id(),
      'items': [{'product_id': x['id'], 'description': 'س', 'quantity': 2, 'unit_price': 50.0, 'discount': 0}],
      'payments': [{'bank_account_id': '${acct['id']}', 'amount': 20.0, 'payment_method': 'cash'}],
    });
    await buy.issuePurchase({
      'currency': 'SAR', 'supplier_id': supp, 'idempotency_key': _id(),
      'items': [{'product_id': y['id'], 'description': 'ص', 'quantity': 5, 'unit_price': 10.0, 'discount': 0}],
    });
    final t1 = DateTime.now().microsecondsSinceEpoch;
    await Future<void>.delayed(const Duration(milliseconds: 5));

    // ---- Day 3 (after the cut-off).
    final s1Id = '${s1['id'] ?? s1['invoice_id'] ?? (s1['invoice'] as Map?)?['id']}';
    await store.withLedger(g, () => a, (l) => l.settle(g,
        DirectoryPartyReference(scope: a, kind: DirectoryPartyKind.customer, id: custA),
        commandId: _id(), accountId: '${acct['id']}', amountMinor: 3000, currency: 'SAR', invoiceId: s1Id));
    final peek = await openLedgerFile(DirectoryDatabase.filePath(root, workspace), keys.memory[workspace.storageId]!);
    final line = await peek.rawQuery('SELECT id FROM business_commerce_invoice_lines WHERE invoice_id = ?', [s1Id]);
    await peek.close();
    await returns.create(s1Id, {'lines': [{'invoice_item_id': line.single['id'], 'quantity': 1, 'restock': true}]});
    await sales.issueSale({
      'currency': 'SAR', 'customer_id': custB, 'idempotency_key': _id(),
      'items': [{'product_id': z['id'], 'description': 'ع', 'quantity': 1, 'unit_price': 60.0, 'discount': 0}],
    });
    final t2 = DateTime.now().microsecondsSinceEpoch;
    // The other branch: must never appear in branch a's export.
    final gb = BusinessLedgerAccess(other, BusinessLedgerAction.values.toSet());
    await store.withLedger(gb, () => other, (l) => l.createAccount(gb, commandId: _id(),
        bankName: 'فرع آخر', accountName: 'x', accountNumber: '2', currency: 'SAR', openingMinor: 777700));

    await travel(a.branchId, t0, t1, d1);
    await travel(a.branchId, t1, t2, d3);

    Future<_Export> export(DateTime cutoff, {bool arabic = true}) async {
      final r = await exportBusinessAccounting(store: store, access: a, cutoff: cutoff, arabic: arabic,
          work: Directory('${root.path}/work'), into: File('${root.path}/out-${_day(cutoff)}.zip'), media: media,
          appVersion: 'test');
      return _Export(r.zip);
    }

    // ---- Today: identical to what the app itself reports.
    final today = await export(now);
    Map<String, String> balancesOf(_Export e) => {
          for (final r in e.rows('opening_parties')) '${r['party_id']}|${r['currency']}': r['balance_cutoff']!,
        };
    final appBalances = <String, String>{};
    for (final kind in ['customer', 'supplier']) {
      final ref = DirectoryPartyKind.values.byName(kind);
      for (final id in kind == 'customer' ? [custA, custB] : [supp]) {
        final rows = await store.withLedger(g, () => a, (l) => l.debts(g, DirectoryPartyReference(scope: a, kind: ref, id: id)));
        for (final row in rows) {
          final k = '$id|${row['currency']}';
          final cur = BigInt.parse((appBalances[k] ?? '0.00').replaceAll('.', ''));
          appBalances[k] = _minor(cur + BigInt.from(row['remaining_minor'] as int));
        }
      }
    }
    appBalances.removeWhere((_, v) => v == '0.00');
    expect(balancesOf(today), appBalances, reason: 'today = the app\'s own party balances');
    expect(balancesOf(today), {'$custA|SAR': '100.00', '$custB|SAR': '60.00', '$supp|SAR': '50.00'});
    final accToday = today.rows('opening_accounts').single;
    final appAcc = (await store.withLedger(g, () => a, (l) => l.accounts(g))).single;
    expect(accToday['balance_cutoff'], _minor(BigInt.from(appAcc['balance_minor'] as int)));
    expect(accToday['balance_cutoff'], '1050.00');
    final stockToday = {for (final r in today.rows('opening_stock')) r['name']: r['quantity_cutoff']};
    expect(stockToday, {'منتج س': '99', 'منتج ص': '15', 'منتج ع': '19'});
    expect(today.manifest['warnings'], isEmpty);

    // ---- Cut-off day 2: later payment, return and sale taken back.
    final past = await export(d2);
    expect(balancesOf(past), {'$custA|SAR': '180.00', '$supp|SAR': '50.00'});
    expect(past.rows('opening_accounts').single['balance_cutoff'], '1020.00');
    expect({for (final r in past.rows('opening_stock')) r['name']: r['quantity_cutoff']},
        {'منتج س': '98', 'منتج ص': '15', 'منتج ع': '20'});
    final docs = {for (final r in past.rows('documents')) r['document_id']: r};
    expect(docs[s1Id]!['remaining_cutoff'], '80.00');
    expect(docs[s1Id]!['remaining_now'], '0.00');
    expect(past.rows('returns'), isEmpty, reason: 'the return is after the cut-off');
    expect(past.rows('payments').where((p) => p['document_id'] == s1Id).length, 1);
    expect(past.manifest['controls']['receivable'], {'SAR': '180.00'});
    expect(past.manifest['controls']['bank'], {'SAR': '1020.00'});

    // ---- Branch isolation, file integrity, safe cells, photo, both formats.
    for (final f in past.files.keys) {
      expect(utf8.decode(past.files[f]!, allowMalformed: true).contains('فرع آخر'), isFalse, reason: f);
    }
    for (final f in (past.manifest['files'] as List).cast<Map>()) {
      expect(sha256.convert(past.files[f['path']]!).toString(), f['sha256'], reason: '${f['path']}');
    }
    final names = today.rows('opening_parties').map((r) => r['name']).toList();
    expect(names, contains('\'=HYPERLINK("http://x")'), reason: 'formula neutralised in CSV');
    expect(names, contains('عميل، "ب"'));
    final img = past.rows('opening_stock').firstWhere((r) => r['name'] == 'منتج س')['image_file']!;
    expect(img, endsWith('.jpg'));
    expect(sha256.convert(past.files[img]!).toString(), MediaStore.shaOf(photo));
    final xlsx = ZipDecoder().decodeBytes(past.files['accounting.xlsx']!);
    final sheetXml = utf8.decode(xlsx.findFile('xl/worksheets/sheet2.xml')!.content as List<int>);
    expect(sheetXml, contains('<t xml:space="preserve">=HYPERLINK(&quot;http://x&quot;)</t>'),
        reason: 'stored as TEXT (inline string), never as a formula');
    expect(sheetXml, isNot(contains('<f>')));
    expect(utf8.decode(xlsx.findFile('xl/workbook.xml')!.content as List<int>), contains('أرصدة العملاء والموردين'));
    final en = await export(d2, arabic: false);
    expect(en.csv('opening_accounts').first.first, 'Account ID');

    // An employee cannot export the whole branch.
    await expectLater(exportBusinessAccounting(store: store, access: branch(a.branchId, member: true), cutoff: now,
        arabic: true, work: Directory('${root.path}/w2'), into: File('${root.path}/no.zip')), throwsA(isA<DirectoryAccessDenied>()));
    // Every part of the workbook is well-formed XML; every sheet has the
    // header + exactly the rows of its CSV twin.
    final sheetNames = {for (final f in xlsx.files) f.name};
    for (final part in sheetNames.where((n) => n.endsWith('.xml') || n.endsWith('.rels'))) {
      XmlDocument.parse(utf8.decode(xlsx.findFile(part)!.content as List<int>));
    }
    final order = businessExportSheets.keys.toList();
    for (var i = 0; i < order.length; i++) {
      final doc = XmlDocument.parse(utf8.decode(xlsx.findFile('xl/worksheets/sheet${i + 1}.xml')!.content as List<int>));
      expect(doc.findAllElements('row').length, past.csv(order[i]).length, reason: order[i]);
    }
  });

  test('100 000 invoices: streamed export, bounded memory (measured)', () async {
    final a = branch(_id());
    await store.remember(a, _entitlement());
    final g = BusinessLedgerAccess(a, BusinessLedgerAction.values.toSet());
    final acct = await store.withLedger(g, () => a, (l) => l.createAccount(g, commandId: _id(),
        bankName: 'Cash', accountName: 'Till', accountNumber: '1', currency: 'SAR', openingMinor: 100000));
    final cust = (await store.withLedger(g, () => a, (l) => l.addPartyWithOpeningDebt(g, DirectoryPartyKind.customer,
        commandId: _id(), name: 'عميل', amountMinor: 0, currency: 'SAR')))['party_id'];
    final inv = LocalInventoryApi(client, LocalCommerceBridge(store, () => a, (_) => true));
    final sales = LocalSalesApi(client, LocalCommerceBridge(store, () => a, (_) => true));
    final p = await inv.createProduct({'name': 'منتج', 'unit': 'قطعة', 'price': 10.0, 'stock': 1000000});
    for (var i = 0; i < 20; i++) {
      await sales.issueSale({
        'currency': 'SAR', 'customer_id': cust, 'idempotency_key': _id(),
        'items': [{'product_id': p['id'], 'description': 'x', 'quantity': 1, 'unit_price': 10.0, 'discount': 0}],
        if (i.isEven) 'payments': [{'bank_account_id': '${acct['id']}', 'amount': 4.0, 'payment_method': 'cash'}],
      });
    }
    await store.close();
    final db = await openLedgerFile(DirectoryDatabase.filePath(root, workspace), keys.memory[workspace.storageId]!);
    const n = 100000;
    Future<int> invoices() async => (await db.rawQuery('SELECT COUNT(*) AS c FROM business_commerce_invoices')).first['c'] as int;
    for (var round = 1; await invoices() < n; round++) {
      final sfx = "'~$round'";
      final want = n - await invoices();
      await db.transaction((tx) async {
        await tx.execute('CREATE TEMP TABLE IF NOT EXISTS pick (id TEXT PRIMARY KEY)');
        await tx.execute('DELETE FROM pick');
        await tx.execute('INSERT INTO pick SELECT id FROM business_commerce_invoices ORDER BY rowid LIMIT $want');
        Future<void> clone(String t, Map<String, String> map, String key) async {
          final cols = [for (final c in await tx.rawQuery('PRAGMA table_info($t)')) '${c['name']}'];
          await tx.execute('INSERT INTO $t (${cols.map((c) => '"$c"').join(',')}) SELECT '
              '${cols.map((c) => map[c] ?? '"$c"').join(',')} FROM $t WHERE $key IN (SELECT id FROM pick)');
        }

        await clone('business_commerce_invoices', {'id': 'id || $sfx', 'number': 'number || $sfx',
          'idempotency_key': 'CASE WHEN idempotency_key IS NULL THEN NULL ELSE idempotency_key || $sfx END'}, 'id');
        await clone('business_commerce_invoice_lines', {'id': 'id || $sfx', 'invoice_id': 'invoice_id || $sfx'}, 'invoice_id');
        await clone('business_commerce_invoice_payments', {'id': 'id || $sfx', 'invoice_id': 'invoice_id || $sfx'}, 'invoice_id');
      });
    }
    final count = (await db.rawQuery('SELECT COUNT(*) AS c FROM business_commerce_invoices')).first['c'] as int;
    final expected = (await db.rawQuery(
            "SELECT SUM(balance_minor) AS s FROM business_commerce_invoices WHERE branch_id = ? AND status <> 'draft'",
            [a.branchId]))
        .first['s'] as int;
    await db.close();
    final base = ProcessInfo.currentRss;
    var peak = base;
    final sw = Stopwatch()..start();
    final timer = Stream.periodic(const Duration(milliseconds: 20)).listen((_) {
      if (ProcessInfo.currentRss > peak) peak = ProcessInfo.currentRss;
    });
    final r = await exportBusinessAccounting(store: store, access: a, cutoff: DateTime.now(), arabic: true,
        work: Directory('${root.path}/work'), into: File('${root.path}/big.zip'), media: media);
    await timer.cancel();
    final ms = sw.elapsedMilliseconds;
    expect(r.result.rows['documents'], count);
    expect(r.result.controls['receivable']!['SAR'], BigInt.from(expected));
    final e = _Export(r.zip);
    expect(e.manifest['sheets']['documents'], count);
    // ignore: avoid_print
    print('EXPORT_BENCH invoices=$count lines=${r.result.rows['document_lines']} payments=${r.result.rows['payments']} '
        'ms=$ms zip=${(r.zip.lengthSync() / 1048576).toStringAsFixed(1)}MB rssPeak=+${((peak - base) / 1048576).toStringAsFixed(1)}MB');
  }, timeout: const Timeout(Duration(minutes: 20)));
}

String _minor(BigInt m) {
  final a = m.abs();
  return '${m.isNegative ? '-' : ''}${a ~/ BigInt.from(100)}.${(a % BigInt.from(100)).toString().padLeft(2, '0')}';
}
