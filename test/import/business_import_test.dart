// Smart import into a real Business branch ledger: preview, one batch,
// balances through the app's own operations, double import refused, undo
// only while nothing happened since. FYONA_IMPORT_BENCH=100000 adds a
// large-file measurement.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/import/business_import.dart';
import 'package:fyona_flutter/core/import/import_plan.dart';
import 'package:fyona_flutter/core/import/import_source.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/core_business/data/local_commerce/local_commerce_api.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_party.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../support/directory_test_keys.dart';

String _id() => const Uuid().v4();
// ignore: avoid_print
void _log(String s) => print(s);

Map<String, dynamic> _entitlement() => {
      'status': 'active', 'business_setup_completed': true,
      'sections': {'business': {'active': true, 'end_date': DateTime.now().add(const Duration(days: 2)).toIso8601String()}},
    };

void main() {
  if (!DirectoryPilotBuild.signupEnabled) {
    test('business import', () {}, skip: 'needs the QA directory defines');
    return;
  }
  sqfliteFfiInit();
  late Directory dir;
  late DirectoryAccess scope;
  late DirectoryPilotStore store;
  late ImportRegistry registry;
  late LocalInventoryApi inventory;
  late BusinessLedgerAccess grant;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fyona-bizimport-');
    final w = DirectoryWorkspace(server: DirectoryPilotBuild.baseUrl, accountId: _id(), organizationId: _id());
    scope = DirectoryAccess(workspace: w, branchId: _id(), readable: DirectoryPartyKind.values.toSet(),
        writable: DirectoryPartyKind.values.toSet(), financialCutover: true);
    grant = BusinessLedgerAccess(scope, BusinessLedgerAction.values.toSet());
    store = DirectoryPilotStore(root: () async => Directory('${dir.path}/ledger'), keys: FixtureDirectoryKeys());
    await store.remember(scope, _entitlement());
    registry = await ImportRegistry.open('${dir.path}/imports.sqlite', '');
    inventory = LocalInventoryApi(ApiClient(dio: Dio()), LocalCommerceBridge(store, () => scope, (_) => true));
  });
  tearDown(() async {
    await registry.close();
    await store.close();
    await dir.delete(recursive: true);
  });

  BusinessImporter importer([ImportRegistry? r]) => BusinessImporter(
        store: store, access: scope, registry: r ?? registry,
        createProduct: inventory.createProduct, deleteProduct: inventory.deleteProduct);

  Future<(ImportTable, String)> file(String name, String text) async {
    final f = File('${dir.path}/$name')..writeAsStringSync(text);
    return ((await readImportFile(f)).single, '${sha256.convert(f.readAsBytesSync())}');
  }

  Future<List<Map<String, Object?>>> debts(DirectoryPartyKind kind, String name) async {
    final p = (await store.search(scope, kind, name)).single;
    return store.withLedger(grant, () => scope,
        (l) => l.debts(grant, DirectoryPartyReference(scope: scope, kind: kind, id: p.id)));
  }

  const csv = 'الاسم,النوع,الجوال,مدين,دائن,العملة\n'
      'محمد علي,عميل,0500000001,"1,250.50",0,SAR\n'
      'مؤسسة الأمل,مورد,0500000002,0,٧٥٠,ريال سعودي\n'
      'سالم,عميل,,0,0,SAR\n'
      'خالد,عميل,,0,100,SAR\n' // a credit balance: listed, not guessed
      'محمد علي,عميل,,5,0,SAR\n' // same name twice in the file
      ',عميل,,9,0,SAR\n' // no name
      'نوال,شريك,,1,0,SAR\n'; // unknown kind

  test('customers and suppliers with opening balances: preview, one batch, real balances', () async {
    final (t, sha) = await file('customers.csv', csv);
    final mapping = autoMapColumns(ImportTarget.parties, t.columns);
    expect(mapping, {'name': 'الاسم', 'kind': 'النوع', 'phone': 'الجوال', 'debit': 'مدين', 'credit': 'دائن', 'currency': 'العملة'});
    final imp = importer();
    final p = await buildImportPreview(t, ImportTarget.parties, mapping, existing: await imp.existingNames(), defaultCurrency: 'SAR');
    expect(p.rows, 7);
    expect(p.ready, 3);
    expect({for (final i in p.issues) i.row: i.code},
        {4: 'credit_balance', 5: 'duplicate_in_file', 6: 'missing_name', 7: 'bad_kind'});
    expect(p.totals, {'customer': {'SAR': 125050}, 'supplier': {'SAR': 75000}});
    final batch = await imp.apply(p, fileSha: sha, fileName: 'customers.csv');
    final a = await debts(DirectoryPartyKind.customer, 'محمد علي');
    expect(a.single['total_minor'] ?? a.single['amount_minor'] ?? a.single['remaining_minor'], isNotNull);
    expect(jsonEncode(a), contains('125050'));
    expect(jsonEncode(await debts(DirectoryPartyKind.supplier, 'مؤسسة الأمل')), contains('75000'));
    expect(await debts(DirectoryPartyKind.customer, 'سالم'), isEmpty); // zero: card only
    final b = (await registry.batches(scope.branchId)).single;
    expect(b['id'], batch);
    expect(b['status'], 'done');
    expect(b['rows_done'], 3);

    // The same file again: refused. With the registry lost (new phone,
    // restored ledger), the ledger's own command ids still prevent doubles.
    await expectLater(imp.apply(p, fileSha: sha, fileName: 'customers.csv'),
        throwsA(isA<ImportRefused>().having((e) => e.code, 'code', 'already_imported')));
    final fresh = await ImportRegistry.open('${dir.path}/imports-2.sqlite', '');
    await importer(fresh).apply(p, fileSha: sha, fileName: 'customers.csv');
    await fresh.close();
    expect((await store.search(scope, DirectoryPartyKind.customer, '')).length, 2);
    expect((await debts(DirectoryPartyKind.customer, 'محمد علي')).length, 1);

    // Undo the batch: cards and opening debts gone, nothing else touched.
    expect(await imp.undo(batch), 3);
    expect(await store.search(scope, DirectoryPartyKind.customer, ''), isEmpty);
    expect(await store.search(scope, DirectoryPartyKind.supplier, ''), isEmpty);
    await expectLater(imp.undo(batch), throwsA(isA<ImportRefused>().having((e) => e.code, 'code', 'already_undone')));
  });

  test('undo is refused once something happened to what the batch created', () async {
    final (t, sha) = await file('c.csv', 'name,balance\nعميل أ,100\nعميل ب,200\n');
    final imp = importer();
    final p = await buildImportPreview(t, ImportTarget.parties, autoMapColumns(ImportTarget.parties, t.columns), defaultCurrency: 'SAR');
    final batch = await imp.apply(p, fileSha: sha, fileName: 'c.csv');
    final party = (await store.search(scope, DirectoryPartyKind.customer, 'عميل ب')).single;
    await store.withLedger(grant, () => scope, (l) => l.recordOpeningDebt(grant,
        DirectoryPartyReference(scope: scope, kind: DirectoryPartyKind.customer, id: party.id),
        commandId: _id(), amountMinor: 50, currency: 'SAR'));
    await expectLater(imp.undo(batch),
        throwsA(isA<ImportRefused>().having((e) => e.code, 'code', 'busy_after_import').having((e) => e.count, 'count', 1)));
    expect((await store.search(scope, DirectoryPartyKind.customer, '')).length, 2);
    // Another file naming a customer the branch already has: skipped, listed.
    final (t2, _) = await file('c2.csv', 'name,balance\nعميل  أ,5\nعميل ج,7\n');
    final p2 = await buildImportPreview(t2, ImportTarget.parties, autoMapColumns(ImportTarget.parties, t2.columns),
        existing: await imp.existingNames(), defaultCurrency: 'SAR');
    expect(p2.ready, 1);
    expect(p2.issues.single.code, 'exists');
  });

  test('products with prices and stock; undo; refused after a sale', () async {
    final (t, sha) = await file('p.csv', 'الصنف,الباركود,سعر البيع,التكلفة,الكمية\nقلم أزرق,111,2.5,1.25,100\nدفتر,222,"1,000",600,٣\nقلم أزرق,333,1,1,1\n');
    final map = autoMapColumns(ImportTarget.products, t.columns);
    expect(map, {'name': 'الصنف', 'barcode': 'الباركود', 'sale_price': 'سعر البيع', 'cost_price': 'التكلفة', 'stock': 'الكمية'});
    final imp = importer();
    final p = await buildImportPreview(t, ImportTarget.products, map, defaultCurrency: 'SAR');
    // Two products may share a name when their barcodes differ (sizes,
    // colours); the same barcode twice would be refused.
    expect(p.ready, 3);
    expect(p.issues, isEmpty);
    final batch = await imp.apply(p, fileSha: sha, fileName: 'p.csv');
    final list = await inventory.listProducts();
    expect(list.length, 3);
    final pen = list.firstWhere((e) => e['barcode'] == '111');
    expect(pen['barcode'], '111');
    expect(double.parse('${pen['stock']}'), 100);
    expect(double.parse('${pen['price']}'), 2.5);
    expect(await imp.undo(batch), 3);
    expect(await inventory.listProducts(), isEmpty);

    // Again (another file name, same content = same batch: refused).
    await expectLater(imp.apply(p, fileSha: sha, fileName: 'copy.csv'), throwsA(isA<ImportRefused>()));
    final (t2, sha2) = await file('p2.csv', 'الصنف,سعر البيع,الكمية\nممحاة,1,10\n');
    final p2 = await buildImportPreview(t2, ImportTarget.products, autoMapColumns(ImportTarget.products, t2.columns), defaultCurrency: 'SAR');
    final b2 = await imp.apply(p2, fileSha: sha2, fileName: 'p2.csv');
    final eraser = (await inventory.listProducts()).single;
    final buyer = await store.withLedger(grant, () => scope, (l) => l.addPartyWithOpeningDebt(grant,
        DirectoryPartyKind.customer, commandId: _id(), name: 'مشتري', amountMinor: 0, currency: 'SAR'));
    await LocalSalesApi(ApiClient(dio: Dio()), LocalCommerceBridge(store, () => scope, (_) => true)).issueSale({
      'currency': 'SAR', 'idempotency_key': _id(), 'customer_id': buyer['party_id'],
      'items': [{'product_id': eraser['id'], 'description': 'بيع', 'quantity': 1, 'unit_price': 1.0, 'discount': 0}],
    });
    await expectLater(imp.undo(b2), throwsA(isA<ImportRefused>().having((e) => e.code, 'code', 'busy_after_import')));
  });

  test('products with a category and a picture from the same ZIP; rows for another branch refused', () async {
    final png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List.filled(64, 7)];
    final zip = Archive()
      ..addFile(ArchiveFile.bytes('products.csv', utf8.encode('الصنف,التصنيف,الصورة,الكمية,الفرع\n'
          'قلم,قرطاسية,pen.png,5,${scope.branchId}\nدفتر,قرطاسية,missing.png,2,\nممحاة,,,,فرع آخر\n')))
      ..addFile(ArchiveFile('pics/pen.png', png.length, png));
    final f = File('${dir.path}/p.zip')..writeAsBytesSync(ZipEncoder().encode(zip));
    final t = (await readImportFile(f)).single;
    final images = await readImportImages(f);
    expect(images.names, {'pen.png'});
    final review = await ImportReview.load(t, ImportTarget.products, autoMapColumns(ImportTarget.products, t.columns),
        branches: {scope.branchId}, images: images.names, defaultCurrency: 'SAR');
    expect(review.rows[1].warnings, ['image_missing']);
    expect(review.rows[2].reasons, ['other_branch']);
    // Another branch of the file is not an error: its own group.
    expect(review.rows[2].status, RowStatus.elsewhere);
    expect(review.skippedCount, 0);
    final media = <String>[];
    final imp = BusinessImporter(
      store: store, access: scope, registry: registry,
      createProduct: inventory.createProduct, deleteProduct: inventory.deleteProduct,
      categories: inventory.categories, createCategory: inventory.createCategory,
      picture: (name) async {
        final p = images.read(name);
        if (p == null) return null;
        media.add(p.$2);
        return 'media:${sha256.convert(p.$1)}';
      },
    );
    await imp.apply(review.toPreview(), fileSha: '${sha256.convert(f.readAsBytesSync())}', fileName: 'p.zip');
    final list = await inventory.listProducts();
    expect(list.map((e) => e['name']).toSet(), {'قلم', 'دفتر'});
    expect(media, ['image/png']);
    final pen = list.firstWhere((e) => e['name'] == 'قلم');
    expect('${pen['image'] ?? pen['image_url']}', contains('media:'));
    final cats = await inventory.categories();
    expect(cats.where((c) => c['name'] == 'قرطاسية').length, 1); // created once
    expect(pen['category_id'], cats.single['id']);
  });

  final bench = int.tryParse(Platform.environment['FYONA_IMPORT_BENCH'] ?? '');
  // Windows CI disks write each row slowly: there it checks the import
  // works (1 000 rows); 10 000 run on Linux, 100 000 with the bench flag.
  final n = bench ?? (Platform.isWindows ? 1000 : 10000);
  test('large file: $n customers', () async {
    final rnd = Random(9);
    final b = StringBuffer('الاسم,الجوال,الرصيد\n');
    var total = 0;
    for (var i = 0; i < n; i++) {
      final amt = rnd.nextInt(100000);
      total += amt;
      b.write('عميل رقم $i,05${'$i'.padLeft(8, '0')},${amt ~/ 100}.${(amt % 100).toString().padLeft(2, '0')}\n');
    }
    final (t, sha) = await file('big.csv', b.toString());
    final rss = ProcessInfo.currentRss;
    var peak = rss;
    final sw = Stopwatch()..start();
    final imp = importer();
    final p = await buildImportPreview(t, ImportTarget.parties, autoMapColumns(ImportTarget.parties, t.columns), defaultCurrency: 'SAR');
    final previewMs = sw.elapsedMilliseconds;
    expect(p.ready, n);
    expect(p.totals['customer']!['SAR'], total);
    final batch = await imp.apply(p, fileSha: sha, fileName: 'big.csv', onProgress: (_, _) {
      peak = max(peak, ProcessInfo.currentRss);
    });
    final applyMs = sw.elapsedMilliseconds - previewMs;
    final report = await store.withLedger(grant, () => scope, (l) => l.debtReport(grant, currency: 'SAR'));
    // The app's own debt report: the same total to the halala.
    final customers = report['customers'] as Map;
    expect(customers['total'], '${total ~/ 100}.${(total % 100).toString().padLeft(2, '0')}');
    sw.reset();
    expect(await imp.undo(batch), n);
    _log('IMPORT_BENCH $n customers: preview ${previewMs}ms, import ${applyMs}ms '
        '(${(applyMs / n).toStringAsFixed(2)} ms/row), undo ${sw.elapsedMilliseconds}ms, RSS +${((peak - rss) / 1048576).toStringAsFixed(1)} MB');
  }, timeout: const Timeout(Duration(hours: 2)));

  test('bank and cash balances: banks as the banks screen makes them, cash into the one «كاش»', () async {
    final (t, sha) = await file('accounts.csv', 'الحساب,البنك,الرصيد,العملة\n'
        'الصندوق الرئيسي,,1500,SAR\n'
        'صندوق المعرض,,500.25,SAR\n'
        'حساب الراجحي,مصرف الراجحي,85000,SAR\n'
        'حساب ثان,مصرف الراجحي,10,SAR\n' // same bank and currency: FYONA keeps one
        'حساب دولار,مصرف الراجحي,400,USD\n');
    // The branch already has its cash account (created as the app does).
    await store.withLedger(grant, () => scope, (l) => l.createAccount(grant,
        commandId: const Uuid().v5(Uuid.NAMESPACE_URL, 'fyona-cash:${scope.branchId}:SAR'),
        bankName: 'كاش', accountName: 'حساب الكاش', accountNumber: 'CASH', currency: 'SAR', openingMinor: 1000, managed: true));
    final imp = importer();
    final review = await ImportReview.load(t, ImportTarget.accounts, autoMapColumns(ImportTarget.accounts, t.columns),
        existing: await imp.existingNames(), enabledCurrencies: {'SAR', 'USD'});
    expect(review.refusedByReason, {'duplicate_in_file': 1});
    expect(review.rows.where((r) => r.warnings.contains('to_cash')).length, 2);
    final id = await imp.apply(review.toPreview(), fileSha: sha, fileName: 'accounts.csv');
    final rows = await store.withLedger(grant, () => scope, (l) => l.managedBankAccounts(grant, includeBalances: true));
    final cash = rows.where((a) => a['bank_name'] == 'كاش').toList();
    expect(cash.length, 1, reason: 'never a second cash account');
    expect(cash.single['balance_minor'], 1000 + 150000 + 50025);
    final banks = rows.where((a) => a['bank_name'] == 'مصرف الراجحي').toList();
    expect(banks.map((a) => a['currency']).toSet(), {'SAR', 'USD'});
    expect(banks.firstWhere((a) => a['currency'] == 'SAR')['balance_minor'], 8500000);
    // The same bank again is refused by FYONA's own rule (managed account).
    expect(
        () => store.withLedger(grant, () => scope, (l) => l.createAccount(grant,
            commandId: _id(), bankName: 'مصرف الراجحي', accountName: 'x', accountNumber: '1', currency: 'SAR', managed: true)),
        throwsA(isA<BusinessLedgerError>()));
    // Undo: the deposits leave «كاش», the banks are closed.
    await imp.undo(id);
    final after = await store.withLedger(grant, () => scope, (l) => l.managedBankAccounts(grant, includeBalances: true));
    expect(after.where((a) => a['bank_name'] == 'كاش').single['balance_minor'], 1000);
    expect(after.where((a) => a['bank_name'] == 'مصرف الراجحي'), isEmpty);
  });

  test('a customer owing in two currencies; products saved exactly as the product form saves them', () async {
    final imp = BusinessImporter(
        store: store, access: scope, registry: registry,
        createProduct: inventory.createProduct, deleteProduct: inventory.deleteProduct,
        categories: inventory.categories, createCategory: inventory.createCategory);
    final parties = ImportPreview(ImportTarget.parties, const {}, currency: 'SAR')
      ..parties.add(PartyImportRow(1, 'customer', 'عميل بعملتين', '0555000111', 125050, 'SAR', more: [('USD', 4000)]));
    await imp.apply(parties, fileSha: 'two-currencies', fileName: 'c.csv');
    final docs = await debts(DirectoryPartyKind.customer, 'عميل بعملتين');
    expect({for (final d in docs) '${d['currency']}': d['amount_minor'] ?? d['total_minor']}.keys.toSet(), {'SAR', 'USD'});

    // A product priced in USD (and SAR): main currency first, as the form.
    final (t, sha) = await file('p.csv', 'الاسم,سعر البيع,سعر الشراء,الكمية,العملة,التصنيف,الرمز\n'
        'قلم أزرق,2.5,1.5,10,USD,${'ت' * 130},SKU-1\n');
    final review = await ImportReview.load(t, ImportTarget.products, autoMapColumns(ImportTarget.products, t.columns),
        enabledCurrencies: {'SAR', 'USD'});
    expect(review.rows.single.warnings, contains('category_cut'));
    final p = review.toPreview();
    expect(p.products.single.currency, 'USD');
    expect(p.products.single.prices.first, {'currency': 'USD', 'price': '2.5', 'buy_price': '1.5'});
    expect(p.products.single.category!.runes.length, importCategoryMax);
    await imp.apply(p, fileSha: sha, fileName: 'p.csv');
    final id = await registry.batches(scope.branchId).then((b) => b.first['id']);
    final items = await (await databaseFactoryFfi.openDatabase('${dir.path}/imports.sqlite')).query('import_items',
        where: 'batch_id = ? AND kind = ?', whereArgs: [id, 'product']);
    final full = await inventory.getProduct('${items.single['entity_id']}');
    expect(full['cost_currency'], 'USD');
    expect(full['sku'], isNull, reason: 'the form has no SKU field');
    expect(full['description'], isNull);
  });

  test('a backup from before the import was restored: the same file may be imported again', () async {
    final (t, sha) = await file('again.csv', 'الاسم,الرصيد,العملة\nعميل مستعاد,50,SAR\n');
    final p = await buildImportPreview(t, ImportTarget.parties, autoMapColumns(ImportTarget.parties, t.columns), defaultCurrency: 'SAR');
    await importer().apply(p, fileSha: sha, fileName: 'again.csv');
    await expectLater(importer().apply(p, fileSha: sha, fileName: 'again.csv'), throwsA(isA<ImportRefused>()));
    // The ledger goes back to before the import (the registry stays).
    await store.close();
    await Directory('${dir.path}/ledger').delete(recursive: true);
    store = DirectoryPilotStore(root: () async => Directory('${dir.path}/ledger'), keys: FixtureDirectoryKeys());
    await store.remember(scope, _entitlement());
    await importer().apply(p, fileSha: sha, fileName: 'again.csv');
    expect(await store.search(scope, DirectoryPartyKind.customer, 'عميل مستعاد'), hasLength(1));
  });

  test('the same file again: what it added shows as already there (not an error), only new rows are added, cash is not deposited twice',
      () async {
    final (t, sha) = await file('again2.csv', 'الاسم,الجوال,الرصيد,العملة\nعميل 1,0501,10,SAR\nعميل 2,0502,0,\n');
    final (ta, shaA) = await file('cash2.csv', 'الحساب,الرصيد,العملة\nالصندوق,900,SAR\n');
    final imp = importer();
    Future<ImportReview> review(ImportTable table, ImportTarget target, String key) async => ImportReview.load(
        table, target, autoMapColumns(target, table.columns),
        defaultCurrency: 'SAR', enabledCurrencies: {'SAR'},
        existing: await imp.existingNames(), imported: await imp.importedRows(key, target));
    // First time: row 2 left out by the user.
    var r = await review(t, ImportTarget.parties, sha);
    r.setRejected([r.rows[1]], true);
    await imp.apply(r.toPreview(), fileSha: sha, fileName: 'again2.csv');
    await imp.apply((await review(ta, ImportTarget.accounts, shaA)).toPreview(), fileSha: shaA, fileName: 'cash2.csv');
    expect(await imp.importedRows(sha, ImportTarget.parties), {1});
    // Again: row 1 is "already imported", row 2 can now be added.
    r = await review(t, ImportTarget.parties, sha);
    expect(r.rows[0].reasons, ['already_imported']);
    expect(r.rows[0].status, RowStatus.present);
    expect(r.rows[1].status, RowStatus.add);
    expect(r.skippedCount, 0);
    await imp.apply(r.toPreview(), fileSha: sha, fileName: 'again2.csv');
    expect(await store.search(scope, DirectoryPartyKind.customer, 'عميل'), hasLength(2));
    // A third time: everything is already there; nothing is an error.
    r = await review(t, ImportTarget.parties, sha);
    expect(r.acceptedCount, 0);
    expect(r.countOf(RowStatus.present), 2);
    expect(r.skippedCount, 0);
    // The cash box of the same file: already there, never deposited twice.
    final cash = await review(ta, ImportTarget.accounts, shaA);
    expect(cash.rows.single.status, RowStatus.present);
    expect(cash.acceptedCount, 0);
    await expectLater(imp.apply(cash.toPreview(), fileSha: shaA, fileName: 'cash2.csv'),
        throwsA(isA<ImportRefused>().having((e) => e.code, 'code', 'already_imported')));
    final rows = await store.withLedger(grant, () => scope, (l) => l.managedBankAccounts(grant, includeBalances: true));
    expect(rows.where((a) => a['bank_name'] == 'كاش').single['balance_minor'], 90000);
  });

  // FYONA_IMPORT_PRODUCTS_BENCH=10000: products with prices in two
  // currencies, stock and a category, written through the product form's
  // own operation (opt-in: a long run).
  final pbench = int.tryParse(Platform.environment['FYONA_IMPORT_PRODUCTS_BENCH'] ?? '');
  test('large file: ${pbench ?? 0} products into the ledger', () async {
    final n = pbench!;
    final b = StringBuffer('الاسم,الباركود,سعر الشراء,سعر البيع,الكمية,العملة,التصنيف\n');
    for (var i = 0; i < n; i++) {
      b.write('منتج $i,62${'$i'.padLeft(10, '0')},${i % 50}.25,${i % 50 + 3}.5,${i % 999},${i % 3 == 0 ? 'USD' : ''},قسم ${i % 40}\n');
    }
    final (t, sha) = await file('big-products.csv', b.toString());
    final imp = BusinessImporter(
        store: store, access: scope, registry: registry,
        createProduct: inventory.createProduct, deleteProduct: inventory.deleteProduct,
        categories: inventory.categories, createCategory: inventory.createCategory);
    final sw = Stopwatch()..start();
    final review = await ImportReview.load(t, ImportTarget.products, autoMapColumns(ImportTarget.products, t.columns),
        defaultCurrency: 'SAR', enabledCurrencies: {'SAR', 'USD'});
    expect(review.acceptedCount, n);
    final checked = sw.elapsedMilliseconds;
    sw.reset();
    await imp.apply(review.toPreview(), fileSha: sha, fileName: 'big-products.csv');
    final written = sw.elapsedMilliseconds;
    expect(imp.skippedRows, isEmpty);
    _log('PRODUCTS_BENCH $n: review ${checked}ms, import ${written}ms (${(written / n).toStringAsFixed(1)} ms/product)');
  }, skip: pbench == null ? 'set FYONA_IMPORT_PRODUCTS_BENCH' : null, timeout: const Timeout(Duration(hours: 1)));
}
