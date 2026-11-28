// A database shaped like the owner's own test file: prices and barcodes per
// UNIT (unit_id), today's quantity per branch next to lots and movements
// (history, never added twice), receivables with a remaining amount, the
// main branch flagged, pictures stored inside the database.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/import/import_schema.dart';
import 'package:fyona_flutter/core/import/import_session.dart';
import 'package:fyona_flutter/core/import/import_source.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  test('unit prices and barcodes go to their unit; lots and movements are history; main branch first', () async {
    final dir = await Directory.systemTemp.createTemp('fyona-unitdb-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/shop.db';
    final db = await databaseFactoryFfi.openDatabase(path);
    for (final sql in [
      'CREATE TABLE branches (id INTEGER PRIMARY KEY, name TEXT, is_main INTEGER)',
      'CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT, sku TEXT, barcode TEXT, unit TEXT, purchase_price REAL, sale_price REAL, currency TEXT, stock REAL)',
      'CREATE TABLE product_units (id INTEGER PRIMARY KEY, product_id INTEGER, name TEXT, conversion_factor REAL, is_base INTEGER)',
      'CREATE TABLE product_barcodes (id INTEGER PRIMARY KEY, product_id INTEGER, unit_id INTEGER, barcode TEXT)',
      'CREATE TABLE product_prices (id INTEGER PRIMARY KEY, product_id INTEGER, unit_id INTEGER, currency TEXT, purchase_price REAL, sale_price REAL)',
      'CREATE TABLE product_images (id INTEGER PRIMARY KEY, product_id INTEGER, file_name TEXT, mime_type TEXT, image_data BLOB)',
      'CREATE TABLE branch_stock (id INTEGER PRIMARY KEY, branch_id INTEGER, product_id INTEGER, quantity REAL)',
      'CREATE TABLE inventory_lots (id INTEGER PRIMARY KEY, branch_id INTEGER, product_id INTEGER, quantity REAL, remaining_quantity REAL)',
      'CREATE TABLE inventory_movements (id INTEGER PRIMARY KEY, branch_id INTEGER, product_id INTEGER, movement_type TEXT, quantity REAL)',
      'CREATE TABLE customers (id INTEGER PRIMARY KEY, branch_id INTEGER, name TEXT, phone TEXT)',
      'CREATE TABLE customer_receivables (id INTEGER PRIMARY KEY, customer_id INTEGER, invoice_id INTEGER, branch_id INTEGER, amount REAL, remaining_amount REAL, currency TEXT)',
      'CREATE TABLE expenses (id INTEGER PRIMARY KEY, branch_id INTEGER, category TEXT, amount REAL, currency TEXT, expense_date TEXT)',
    ]) {
      await db.execute(sql);
    }
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List.filled(50, 3)]);
    final b = db.batch();
    b.insert('branches', {'id': 1, 'name': 'الفرع الرئيسي', 'is_main': 1});
    b.insert('branches', {'id': 2, 'name': 'فرع الشمال', 'is_main': 0});
    for (var p = 1; p <= 40; p++) {
      b.insert('products', {'id': p, 'name': 'منتج $p', 'sku': 'S$p', 'barcode': '20$p', 'unit': 'كيس',
          'purchase_price': 10.0, 'sale_price': 15.5, 'currency': 'SAR', 'stock': 999});
      b.insert('product_units', {'id': p * 2 - 1, 'product_id': p, 'name': 'كيس', 'conversion_factor': 1, 'is_base': 1});
      b.insert('product_units', {'id': p * 2, 'product_id': p, 'name': 'كرتون', 'conversion_factor': 6, 'is_base': 0});
      b.insert('product_barcodes', {'product_id': p, 'unit_id': p * 2 - 1, 'barcode': '20$p'});
      b.insert('product_barcodes', {'product_id': p, 'unit_id': p * 2, 'barcode': '30$p'});
      for (final (unit, factor) in [(p * 2 - 1, 1), (p * 2, 6)]) {
        b.insert('product_prices', {'product_id': p, 'unit_id': unit, 'currency': 'SAR', 'purchase_price': 10.0 * factor, 'sale_price': 15.5 * factor});
        b.insert('product_prices', {'product_id': p, 'unit_id': unit, 'currency': 'USD', 'purchase_price': 3.0 * factor, 'sale_price': 4.25 * factor});
      }
      b.insert('product_images', {'product_id': p, 'file_name': 'p$p.png', 'mime_type': 'image/png', 'image_data': png});
      b.insert('branch_stock', {'branch_id': 1, 'product_id': p, 'quantity': p * 10.0});
      b.insert('branch_stock', {'branch_id': 2, 'product_id': p, 'quantity': 7.0});
      b.insert('inventory_lots', {'branch_id': 1, 'product_id': p, 'quantity': 50.0, 'remaining_quantity': 5.0});
      b.insert('inventory_movements', {'branch_id': 1, 'product_id': p, 'movement_type': 'in', 'quantity': 50.0});
    }
    for (var c = 1; c <= 20; c++) {
      b.insert('customers', {'id': c, 'branch_id': c <= 10 ? 1 : 2, 'name': 'عميل $c', 'phone': '77$c'});
      b.insert('customer_receivables', {'customer_id': c, 'invoice_id': c, 'branch_id': c <= 10 ? 1 : 2,
          'amount': 100.0, 'remaining_amount': 40.25, 'currency': 'SAR'});
    }
    b.insert('expenses', {'branch_id': 1, 'category': 'كهرباء', 'amount': 50.0, 'currency': 'SAR', 'expense_date': '2025-01-01'});
    await b.commit(noResult: true);
    await db.close();

    final f = File(path);
    final s = await ImportSession.analyze(await readImportFile(f), images: await readImportImages(f), currency: 'SAR');
    String role(String t) => s.analysis.firstWhere((a) => a.table.name == t).role.name;
    expect(role('inventory_lots'), 'history');
    expect(role('inventory_movements'), 'history');
    expect(role('expenses'), 'history');
    expect(role('branch_stock'), 'stock');
    expect(s.sourceBranch, 'الفرع الرئيسي'); // the main branch, flagged in the file
    expect(s.analysis.firstWhere((a) => a.table.name == 'product_images').mapping['image'], 'image_data');
    expect(s.analysis.firstWhere((a) => a.role == TableRole.balances).mapping['amount'], 'remaining_amount');
    await s.buildReviews();
    final products = s.reviews.entries.firstWhere((e) => e.key.role == TableRole.products).value.toPreview().products;
    expect(products.length, 40);
    for (final p in products) {
      final n = int.parse(p.name.split(' ').last);
      expect(p.sale, '15.5');
      expect(p.cost, '10');
      expect(double.parse(p.stock!), n * 10); // main branch only, lots/movements not added
      expect(p.units.single.name, 'كرتون');
      expect(p.units.single.barcode, '30$n');
      expect(p.units.single.sale, '93');
      expect(p.barcodes, isEmpty); // the carton code went to the carton
      expect(p.prices.single['currency'], 'USD');
      expect(p.prices.single['price'], '4.25');
      expect(p.image, isNotNull);
    }
    final customers = s.reviews.entries.firstWhere((e) => e.key.role == TableRole.customers).value;
    expect(customers.acceptedCount, 10);
    expect(customers.toPreview().totals['customer']?['SAR'], 10 * 4025);
  });
}
