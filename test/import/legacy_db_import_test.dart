// The whole old database at once (5 500 products and their parts,
// customers, suppliers, accounts, past invoices, employees): recognised
// without manual mapping, joined, checked, imported into a real branch
// ledger exactly, nothing unsupported stored, double import refused.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/import/business_import.dart';
import 'package:fyona_flutter/core/import/import_plan.dart';
import 'package:fyona_flutter/core/import/import_schema.dart';
import 'package:fyona_flutter/core/import/import_source.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/core_business/data/local_commerce/local_commerce_api.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../support/directory_test_keys.dart';
import 'support/legacy_db.dart';

String _id() => const Uuid().v4();
// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  sqfliteFfiInit();
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('fyona-legacy-'));
  tearDown(() => dir.delete(recursive: true));

  test('every table recognised and joined without manual mapping', () async {
    final e = await buildLegacyDb('${dir.path}/old.db', products: 600);
    final tables = await readImportFile(File('${dir.path}/old.db'));
    final sw = Stopwatch()..start();
    final a = await analyzeImportSchema(tables);
    final roles = {for (final x in a) x.table.name: x.role};
    expect(roles, {
      'tbl_categories': TableRole.categories,
      'tbl_items': TableRole.products,
      'tbl_item_units': TableRole.units,
      'tbl_item_barcodes': TableRole.barcodes,
      'tbl_item_images': TableRole.images,
      'tbl_customers': TableRole.customers,
      'tbl_suppliers': TableRole.suppliers,
      'tbl_bank_accounts': TableRole.accounts,
      'tbl_sales_invoices': TableRole.history,
      'tbl_invoice_details': TableRole.history,
      'tbl_employees': TableRole.unsupported,
      'tbl_settings': TableRole.unsupported,
    });
    final items = a.firstWhere((x) => x.role == TableRole.products);
    expect(items.mapping, containsPair('name', 'ItemName'));
    expect(items.mapping, containsPair('barcode', 'Barcode'));
    expect(items.mapping, containsPair('sale_price', 'SalePrice'));
    expect(items.mapping, containsPair('cost_price', 'BuyPrice'));
    expect(items.mapping, containsPair('stock', 'Qty'));
    expect(items.mapping, containsPair('category', 'CatID'));
    for (final part in a.where((x) => x.role.productPart && x.role != TableRole.categories)) {
      expect(part.link?.column, 'ItemID', reason: part.table.name);
      expect(part.link?.parentColumn, 'ItemID');
    }
    final parts = await joinProductParts(a, items.table);
    expect(parts.orphans, {'tbl_item_units': 1});
    final review = await ImportReview.load(items.table, ImportTarget.products, items.mapping,
        blobImages: true, parts: parts);
    expect(review.acceptedCount, e.productsOk);
    final p = review.toPreview();
    expect(p.products.fold<int>(0, (s, x) => s + x.units.length), e.unitsOk);
    final one = p.products.firstWhere((x) => e.sample.containsKey(x.name));
    final want = e.sample[one.name]!;
    expect(one.category, want['category']);
    expect(one.barcode, want['barcode']);
    expect(one.units.length, want['units']);
    expect(one.image != null, want['image']);
    _log('SCHEMA_BENCH 12 tables, 600 products: analysed + joined + checked in ${sw.elapsedMilliseconds} ms');
  });

  if (!DirectoryPilotBuild.signupEnabled) return;

  // Windows CI disks write each row slowly (~100 ms): there it checks the
  // import works (300 products); the 5 500 run on Linux.
  final count = Platform.isWindows ? 300 : 5500;
  test('$count products with units, barcodes, pictures and categories + parties + accounts: exact', () async {
    final e = await buildLegacyDb('${dir.path}/old.db', products: count);
    final file = File('${dir.path}/old.db');
    final sha = '${await sha256.bind(file.openRead()).first}';
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
    final images = await readImportImages(file);
    final pictures = <String>[];
    final imp = BusinessImporter(
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
    final sw = Stopwatch()..start();
    final a = await analyzeImportSchema(await readImportFile(file));
    final analyse = sw.elapsedMilliseconds;
    final existing = await imp.existingNames();
    final batches = <String>[];
    var reviewMs = 0, importMs = 0;
    for (final t in a.where((x) => x.role.importable)) {
      final s0 = Stopwatch()..start();
      final parts = t.role == TableRole.products ? await joinProductParts(a, t.table) : null;
      final r = await ImportReview.load(t.table, t.role.target!, t.mapping,
          defaultKind: t.role == TableRole.suppliers ? 'supplier' : 'customer',
          existing: existing, blobImages: true, parts: parts);
      reviewMs += s0.elapsedMilliseconds;
      s0.reset();
      batches.add(await imp.apply(r.toPreview(), fileSha: '$sha|${t.table.name}', fileName: 'old.db'));
      importMs += s0.elapsedMilliseconds;
    }
    final g = BusinessLedgerAccess(scope, BusinessLedgerAction.values.toSet());
    Future<List<Map<String, dynamic>>> all() async {
      final out = <Map<String, dynamic>>[];
      for (var page = 1;; page++) {
        final p = await inv.listProducts(page: page, perPage: 500);
        out.addAll(p);
        if (p.length < 500) return out;
      }
    }

    final list = await all();
    expect(list.length, e.productsOk);
    expect(pictures.length, greaterThan(e.images * 9 ~/ 10));
    for (final entry in e.sample.entries) {
      final p = list.firstWhere((x) => x['name'] == entry.key);
      expect(p['barcode'], entry.value['barcode']);
      expect(double.parse('${p['price']}'), entry.value['sale']);
      expect(double.parse('${p['stock']}'), entry.value['stock']);
      final units = (await inv.productUnits('${p['id']}'))['units'] as List? ?? const [];
      expect(units.where((u) => '${(u as Map)['name']}' == 'كرتون').length, entry.value['units'], reason: entry.key);
    }
    final cats = await inv.categories();
    expect(cats.length, 40); // each created once
    final rep = await store.withLedger(g, () => scope, (l) => l.debtReport(g, currency: 'SAR'));
    String money(int m) => '${m ~/ 100}.${(m % 100).toString().padLeft(2, '0')}';
    expect((rep['customers'] as Map)['total'], money(e.customerTotalMinor));
    expect((rep['suppliers'] as Map)['total'], money(e.supplierTotalMinor));
    final accounts = await store.withLedger(g, () => scope, (l) => l.accounts(g));
    final imported = accounts.where((x) => '${x['account_name']}'.startsWith('حساب '));
    expect(imported.length, e.accounts);
    expect(imported.fold<int>(0, (s, x) => s + (x['balance_minor'] as int)), e.accountTotalMinor);
    // The sibling branch saw nothing.
    final gs = BusinessLedgerAccess(sibling, BusinessLedgerAction.values.toSet());
    expect(await store.withLedger(gs, () => sibling, (l) => l.accounts(gs)), isEmpty);
    // The same file again: refused, nothing doubled.
    final again = a.firstWhere((x) => x.role == TableRole.products);
    final r2 = await ImportReview.load(again.table, ImportTarget.products, again.mapping,
        existing: await imp.existingNames(), blobImages: true, parts: await joinProductParts(a, again.table));
    expect(r2.acceptedCount, 0); // every product now "exists"
    await expectLater(imp.apply(r2.toPreview(), fileSha: '$sha|tbl_items', fileName: 'old.db'),
        throwsA(isA<ImportRefused>()));
    expect((await all()).length, e.productsOk);
    _log('LEGACY_BENCH ${e.products} products (${e.productsOk} ok, ${e.unitsOk} units, ${e.barcodes} barcodes, ${e.images} pictures), '
        '${e.customersOk} customers, ${e.suppliersOk} suppliers, ${e.accounts} accounts: analyse ${analyse} ms, '
        'review ${reviewMs} ms, import ${(importMs / 1000).toStringAsFixed(1)} s');
    await registry.close();
    await store.close();
  }, timeout: const Timeout(Duration(minutes: 40)));
}
