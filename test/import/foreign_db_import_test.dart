// Databases of other apps, each built differently (see support/foreign_dbs):
// every table recognised by itself (no manual mapping), joined through its
// real links, checked, and imported into a real branch ledger EXACTLY —
// prices from a prices table, quantities of the chosen branch from a stock
// table, balances from receivables / payables tables, currency ids through
// the file's currencies table — while invoices, employees, maintenance,
// warranty, subscription and log tables are refused with their reason.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/import/business_import.dart';
import 'package:fyona_flutter/core/import/import_plan.dart';
import 'package:fyona_flutter/core/import/import_schema.dart';
import 'package:fyona_flutter/core/import/import_session.dart';
import 'package:fyona_flutter/core/import/import_source.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/core_business/data/local_commerce/local_commerce_api.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../support/directory_test_keys.dart';
import 'support/foreign_dbs.dart';

String _id() => const Uuid().v4();
// ignore: avoid_print
void _log(String s) => print(s);
String _money(int m) => '${m < 0 ? '-' : ''}${m.abs() ~/ 100}.${(m.abs() % 100).toString().padLeft(2, '0')}';

class _Ledger {
  _Ledger._(this.store, this.scope, this.sibling, this.registry, this.inv);
  final DirectoryPilotStore store;
  final DirectoryAccess scope, sibling;
  final ImportRegistry registry;
  final LocalInventoryApi inv;
  final pictures = <String>[];

  static Future<_Ledger> open(Directory dir) async {
    final w = DirectoryWorkspace(server: DirectoryPilotBuild.baseUrl, accountId: _id(), organizationId: _id());
    DirectoryAccess access(String b) => DirectoryAccess(workspace: w, branchId: b,
        readable: DirectoryPartyKind.values.toSet(), writable: DirectoryPartyKind.values.toSet(), financialCutover: true);
    final scope = access(_id()), sibling = access(_id());
    final store = DirectoryPilotStore(root: () async => Directory('${dir.path}/ledger'), keys: FixtureDirectoryKeys());
    final status = {
      'status': 'active', 'business_setup_completed': true,
      'sections': {'business': {'active': true, 'end_date': DateTime.now().add(const Duration(days: 2)).toIso8601String()}},
    };
    await store.remember(scope, status);
    await store.remember(sibling, status);
    final registry = await ImportRegistry.open('${dir.path}/imports.sqlite', '');
    final inv = LocalInventoryApi(ApiClient(dio: Dio()), LocalCommerceBridge(store, () => scope, (_) => true));
    return _Ledger._(store, scope, sibling, registry, inv);
  }

  BusinessImporter importer(ImportImages images) => BusinessImporter(
        store: store, access: scope, registry: registry,
        createProduct: inv.createProduct, deleteProduct: inv.deleteProduct,
        categories: inv.categories, createCategory: inv.createCategory,
        createUnit: inv.createUnit, addBarcode: inv.addBarcode,
        picture: (name) async {
          final p = await images.load(name);
          if (p == null) return null;
          pictures.add(p.$2);
          return 'media:${sha256.convert(p.$1)}';
        },
      );

  BusinessLedgerAccess get grant => BusinessLedgerAccess(scope, BusinessLedgerAction.values.toSet());

  Future<List<Map<String, dynamic>>> products() async {
    final out = <Map<String, dynamic>>[];
    for (var page = 1;; page++) {
      final p = await inv.listProducts(page: page, perPage: 500);
      out.addAll(p.cast<Map<String, dynamic>>());
      if (p.length < 500) return out;
    }
  }

  Future<Map<String, dynamic>> report(String currency) {
    final g = grant;
    return store.withLedger(g, () => scope, (l) => l.debtReport(g, currency: currency));
  }

  /// Imports every reviewed table of [s] (as the window does).
  Future<void> importAll(ImportSession s, File file) async {
    final sha = '${await sha256.bind(file.openRead()).first}';
    final imp = importer(s.images);
    for (final e in s.reviews.entries) {
      await imp.apply(e.value.toPreview(), fileSha: '$sha|${e.key.table.name}', fileName: file.uri.pathSegments.last);
    }
  }

  Future<void> close() async {
    await registry.close();
    await store.close();
  }
}

Map<String, String> _roles(List<TableAnalysis> a) => {for (final x in a) x.table.name: x.role.name};

void main() {
  sqfliteFfiInit();
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('fyona-foreign-'));
  tearDown(() => dir.delete(recursive: true));

  test('three different databases: every table recognised and linked by itself', () async {
    final shop = await buildShopDb('${dir.path}/shop.db', products: 400, customers: 120);
    final s1 = await ImportSession.analyze(await readImportFile(File('${dir.path}/shop.db')),
        currentBranchName: 'فرع الحصبه');
    expect(_roles(s1.analysis), shop.roles);
    expect(s1.sourceBranch, 'فرع الحصبة'); // the file's branch named like the FYONA one
    expect(s1.branchChoices.keys.toSet(), {'الفرع الرئيسي', 'فرع الحصبة'});
    expect(s1.context.currencyCodes, {'1': 'SAR', '2': 'USD', '3': 'YER'});
    TableAnalysis t(String n) => s1.analysis.firstWhere((x) => x.table.name == n);
    expect(t('products').mapping, allOf(containsPair('name', 'name_ar'), containsPair('barcode', 'barcode'),
        containsPair('sku', 'sku'), containsPair('category', 'category_id'), containsPair('unit', 'unit'),
        containsPair('min_stock', 'min_qty')));
    expect(t('customers').mapping.containsKey('credit'), isFalse, reason: 'credit_limit is no credit balance');
    for (final p in ['product_units', 'product_barcodes', 'product_prices', 'product_images', 'inventory_stock']) {
      expect(t(p).link?.column, 'product_id', reason: p);
      expect(t(p).link?.parent.name, 'products', reason: p);
    }
    expect(t('customer_receivables').link?.column, 'customer_id');
    expect(t('customer_receivables').link?.parent.name, 'customers');
    expect(t('supplier_payables').link?.parent.name, 'suppliers');
    expect(t('bank_accounts').mapping, allOf(containsPair('bank', 'bank_name'), containsPair('number', 'account_no'),
        containsPair('currency', 'currency_id')));

    final arabic = await buildArabicDb('${dir.path}/ar.db', products: 120);
    final s2 = await ImportSession.analyze(await readImportFile(File('${dir.path}/ar.db')));
    expect(_roles(s2.analysis), arabic.roles);
    final items = s2.analysis.firstWhere((x) => x.table.name == 'الأصناف');
    expect(items.mapping, allOf(containsPair('name', 'اسم الصنف'), containsPair('category', 'رقم المجموعة'),
        containsPair('sale_price', 'سعر البيع'), containsPair('cost_price', 'سعر الشراء'), containsPair('stock', 'الكمية')));
    expect(s2.analysis.firstWhere((x) => x.table.name == 'وحدات الأصناف').link?.column, 'رقم الصنف');
    expect(s2.analysis.firstWhere((x) => x.table.name == 'الصناديق').mapping['name'], 'اسم الصندوق');

    final csv = buildCsvZip('${dir.path}/export.zip', products: 50);
    final s3 = await ImportSession.analyze(await readImportFile(File('${dir.path}/export.zip')));
    String role3(String file) => s3.analysis.firstWhere((x) => x.table.name.startsWith('$file.csv')).role.name;
    csv.roles.forEach((k, v) => expect(role3(k), v, reason: k));
    expect(role3('Chart of Accounts'), 'unsupported');
  });

  test('the review of the shop file: prices, stock of the chosen branch, balances, codes', () async {
    final e = await buildShopDb('${dir.path}/shop.db', products: 1300, customers: 400);
    final f = File('${dir.path}/shop.db');
    final s = await ImportSession.analyze(await readImportFile(f), images: await readImportImages(f), currentBranchName: 'فرع الحصبة');
    await s.buildReviews();
    ImportReview r(String n) => s.reviews.entries.firstWhere((x) => x.key.table.name == n).value;
    final products = r('products');
    expect(products.acceptedCount, e.productsOk);
    expect(products.refusedByReason, {
      if (e.noName > 0) 'missing_name': e.noName,
      if (e.dupBarcode > 0) 'duplicate_in_file': e.dupBarcode,
    });
    final p = products.toPreview();
    for (final x in p.products) {
      expect(importMinor(x.sale), e.sale[x.barcode], reason: '${x.name} sale');
      expect(importMinor(x.cost), e.cost[x.barcode], reason: '${x.name} cost');
      final st = x.stock == null ? 0 : (double.parse(x.stock!) * 1000).round();
      expect(st, e.stock[x.barcode], reason: '${x.name} stock');
      expect(x.category, e.category[x.barcode]);
      expect(x.unit, 'حبة');
    }
    expect(p.products.fold<int>(0, (a, x) => a + x.units.length), e.extraUnits);
    expect(p.products.fold<int>(0, (a, x) => a + x.barcodes.length), e.extraBarcodes);
    expect(products.rows.where((x) => x.warnings.contains('code_skipped')).length, e.droppedCodes);
    expect(products.rows.where((x) => x.accepted && x.warnings.contains('negative_stock')).length, e.negativeStock);
    expect(p.products.where((x) => x.prices.any((pr) => pr['currency'] == 'USD')).length, e.usdPrices);
    expect(p.products.where((x) => x.image != null).length, e.images);
    final customers = r('customers');
    expect(customers.acceptedCount, e.customersOk);
    expect(customers.refusedByReason['other_branch'], e.customersOtherBranch);
    expect(customers.refusedByReason['multi_currency'] ?? 0, e.multiCurrency);
    expect(customers.refusedByReason['credit_balance'] ?? 0, e.credit);
    expect(customers.toPreview().totals['customer']?['SAR'] ?? 0, e.customerTotalMinor);
    expect(r('suppliers').toPreview().totals['supplier']?['SAR'], e.supplierTotalMinor);
    final accounts = [...r('cash_boxes').toPreview().accounts, ...r('bank_accounts').toPreview().accounts];
    expect(accounts.length, e.accountsOk);
    expect(accounts.where((a) => a.currency == 'SAR').fold<int>(0, (a, x) => a + x.amountMinor), e.accountTotalMinor);
    expect(accounts.where((a) => a.currency == 'USD').single.amountMinor, 400000);

    // All branches: quantities of both branches add up; customers of both.
    s.setSourceBranch(null);
    await s.buildReviews();
    expect(r('customers').refusedByReason['other_branch'], isNull);
  });

  test('Sara\'s operations change the review by the app\'s rules', () async {
    await buildShopDb('${dir.path}/shop.db', products: 200, customers: 60);
    final s = await ImportSession.analyze(await readImportFile(File('${dir.path}/shop.db')), currentBranchName: 'فرع الحصبة');
    await s.buildReviews();
    final before = s.reviews.entries.firstWhere((x) => x.key.table.name == 'products').value.toPreview().products.first;
    final done = await s.applyOps([
      {'op': 'adjust', 'field': 'sale_price', 'percent': 10},
      {'op': 'set_field', 'target': 'products', 'field': 'min_stock', 'value': '7', 'only_empty': false},
      {'op': 'reject', 'target': 'customers', 'where': {'field': 'phone', 'op': 'contains', 'value': '7700000'}},
      {'op': 'set_role', 'table': 'audit_logs', 'role': 'unsupported'},
      {'op': 'map', 'table': 'products', 'field': 'description', 'column': 'name_en'},
    ]);
    expect(done.length, 5);
    await s.buildReviews();
    final after = s.reviews.entries.firstWhere((x) => x.key.table.name == 'products').value.toPreview().products.first;
    expect(after.description, 'Product ${after.row}');
    // The review was rebuilt after the mapping change: Sara's price rise
    // and the minimum stock are still there (never lost).
    expect(importMinor(after.sale), ((importMinor(before.sale)! * 1.1)).round());
    expect(after.minStock, '7');
    await s.applyOps([{'op': 'set_currency', 'currency': 'YER'}]);
    expect(s.currency, 'YER');
    expect(s.reviews, isEmpty); // rebuilt with the new currency
  });

  if (!DirectoryPilotBuild.signupEnabled) return;

  // Windows CI disks write each row slowly: there it checks a small file.
  final shopCount = Platform.isWindows ? 200 : 5500;
  test('shop file ($shopCount products) imported exactly into a real branch', () async {
    final e = await buildShopDb('${dir.path}/shop.db', products: shopCount, customers: Platform.isWindows ? 100 : 800);
    final file = File('${dir.path}/shop.db');
    final led = await _Ledger.open(dir);
    final sw = Stopwatch()..start();
    final s = await ImportSession.analyze(await readImportFile(file),
        images: await readImportImages(file), currentBranchName: 'فرع الحصبة');
    s.existing = await led.importer(s.images).existingNames();
    await s.buildReviews();
    final review = sw.elapsedMilliseconds;
    sw.reset();
    await led.importAll(s, file);
    final import = sw.elapsedMilliseconds;
    final list = await led.products();
    expect(list.length, e.productsOk);
    for (final p in list) {
      final bc = '${p['barcode']}';
      expect(importMinor(importDecimal('${p['price']}')), e.sale[bc], reason: '${p['name']}');
      expect((double.parse('${p['stock']}') * 1000).round(), e.stock[bc], reason: '${p['name']}');
      expect(p['category_name'] ?? p['category'], e.category[bc]);
    }
    expect((await led.inv.categories()).length, 25);
    expect(led.pictures.length, e.images);
    final rep = await led.report('SAR');
    expect((rep['customers'] as Map)['total'], _money(e.customerTotalMinor));
    expect((rep['suppliers'] as Map)['total'], _money(e.supplierTotalMinor));
    final g = led.grant;
    final accounts = await led.store.withLedger(g, () => led.scope, (l) => l.accounts(g));
    expect(accounts.length, e.accountsOk);
    expect(accounts.where((x) => x['currency'] == 'SAR').fold<int>(0, (a, x) => a + (x['balance_minor'] as int)), e.accountTotalMinor);
    final gs = BusinessLedgerAccess(led.sibling, BusinessLedgerAction.values.toSet());
    expect(await led.store.withLedger(gs, () => led.sibling, (l) => l.accounts(gs)), isEmpty);
    // The same file again: nothing doubled.
    final s2 = await ImportSession.analyze(await readImportFile(file), images: s.images, currentBranchName: 'فرع الحصبة');
    s2.existing = await led.importer(s.images).existingNames();
    await s2.buildReviews();
    expect(s2.reviews.entries.firstWhere((x) => x.key.table.name == 'products').value.acceptedCount, 0);
    _log('SHOP_BENCH ${e.products} products (${e.productsOk} ok, ${e.extraUnits} cartons, ${e.extraBarcodes} codes, '
        '${e.images} pictures, ${e.usdPrices} USD prices), ${e.customersOk} customers, ${e.suppliersOk} suppliers, '
        '${e.accountsOk} accounts; 23 tables: analyse+review ${review} ms, import ${(import / 1000).toStringAsFixed(1)} s');
    await led.close();
  }, timeout: const Timeout(Duration(minutes: 40)));

  test('Arabic program and a CSV export imported exactly', () async {
    final a = await buildArabicDb('${dir.path}/ar.db', products: Platform.isWindows ? 100 : 1200);
    final led = await _Ledger.open(dir);
    final f1 = File('${dir.path}/ar.db');
    final s1 = await ImportSession.analyze(await readImportFile(f1));
    s1.existing = await led.importer(s1.images).existingNames();
    await s1.buildReviews();
    await led.importAll(s1, f1);
    expect((await led.products()).length, a.productsOk);
    expect((await led.inv.categories()).length, 12);
    var rep = await led.report('SAR');
    expect((rep['customers'] as Map)['total'], _money(a.customerTotalMinor));
    expect((rep['suppliers'] as Map)['total'], _money(a.supplierTotalMinor));

    final c = buildCsvZip('${dir.path}/export.zip', products: Platform.isWindows ? 50 : 400);
    final f2 = File('${dir.path}/export.zip');
    final s2 = await ImportSession.analyze(await readImportFile(f2));
    s2.existing = await led.importer(s2.images).existingNames();
    await s2.buildReviews();
    // Vendor phones 011, 012… are already used by the Arabic file's
    // suppliers: those vendors are added without the phone (noted).
    final vendors = s2.reviews.entries.firstWhere((x) => x.key.role == TableRole.suppliers).value;
    expect(vendors.acceptedCount, c.vendorsOk);
    expect(vendors.rows.where((x) => x.warnings.contains('phone_skipped')).length, greaterThan(0));
    await led.importAll(s2, f2);
    expect((await led.products()).length, a.productsOk + c.productsOk);
    rep = await led.report('SAR');
    expect((rep['customers'] as Map)['total'], _money(a.customerTotalMinor + c.customerTotalMinor));
    expect((rep['suppliers'] as Map)['total'], _money(a.supplierTotalMinor + c.vendorTotalMinor));
    await led.close();
  }, timeout: const Timeout(Duration(minutes: 20)));
}
