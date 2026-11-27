// A realistic old point-of-sale database (SQLite) for the smart import
// tests: 5 500 products with categories, extra units, extra barcodes and
// pictures stored IN the database, customers, suppliers, accounts — plus
// past invoices (refused: already in today's balances), employees and
// settings (no place in FYONA), and deliberately wrong rows.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class LegacyExpect {
  int products = 0, productsOk = 0, units = 0, unitsOk = 0, barcodes = 0, images = 0;
  int customers = 0, customersOk = 0, suppliers = 0, suppliersOk = 0, accounts = 0;
  int customerTotalMinor = 0, supplierTotalMinor = 0, accountTotalMinor = 0;
  final sample = <String, Map<String, Object?>>{}; // product name → expected facts
}

Uint8List _png(int seed) {
  // A real (tiny) PNG header + random body: recognised as a picture.
  final r = Random(seed);
  return Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List.generate(600, (_) => r.nextInt(256))]);
}

Future<LegacyExpect> buildLegacyDb(String path, {int products = 5500, int seed = 1}) async {
  final f = File(path);
  if (f.existsSync()) f.deleteSync();
  final db = await databaseFactoryFfi.openDatabase(path);
  final e = LegacyExpect();
  final rnd = Random(seed);
  await db.execute('CREATE TABLE tbl_categories (CatID INTEGER PRIMARY KEY, CatName TEXT)');
  await db.execute('CREATE TABLE tbl_items (ItemID INTEGER PRIMARY KEY, ItemName TEXT, Barcode TEXT, CatID INTEGER, '
      'BuyPrice REAL, SalePrice REAL, Qty REAL, MinQty REAL, UnitName TEXT, Notes TEXT)');
  await db.execute('CREATE TABLE tbl_item_units (UnitID INTEGER PRIMARY KEY, ItemID INTEGER, UnitName TEXT, Factor REAL, '
      'UnitBarcode TEXT, UnitPrice REAL)');
  await db.execute('CREATE TABLE tbl_item_barcodes (ID INTEGER PRIMARY KEY, ItemID INTEGER, Barcode TEXT)');
  await db.execute('CREATE TABLE tbl_item_images (ID INTEGER PRIMARY KEY, ItemID INTEGER, Img BLOB)');
  await db.execute('CREATE TABLE tbl_customers (CustID INTEGER PRIMARY KEY, CustName TEXT, Mobile TEXT, Balance REAL, Currency TEXT)');
  await db.execute('CREATE TABLE tbl_suppliers (SuppID INTEGER PRIMARY KEY, SuppName TEXT, Phone TEXT, Balance REAL)');
  await db.execute('CREATE TABLE tbl_bank_accounts (AccID INTEGER PRIMARY KEY, AccountName TEXT, BankName TEXT, AccountNumber TEXT, Balance REAL)');
  await db.execute('CREATE TABLE tbl_sales_invoices (InvID INTEGER PRIMARY KEY, InvDate TEXT, CustID INTEGER, Total REAL, Paid REAL)');
  await db.execute('CREATE TABLE tbl_invoice_details (ID INTEGER PRIMARY KEY, InvID INTEGER, ItemID INTEGER, Qty REAL, Price REAL)');
  await db.execute('CREATE TABLE tbl_employees (EmpID INTEGER PRIMARY KEY, EmpName TEXT, Salary REAL, HireDate TEXT)');
  await db.execute('CREATE TABLE tbl_settings (SetKey TEXT, SetValue TEXT)');

  final b = db.batch();
  for (var c = 1; c <= 40; c++) {
    b.insert('tbl_categories', {'CatID': c, 'CatName': 'قسم $c'});
  }
  final seen = <String>{};
  for (var i = 1; i <= products; i++) {
    e.products++;
    // ~1% wrong rows: no name, a repeated name, a negative quantity.
    String? name = 'صنف رقم $i ${['أحمر', 'أزرق', 'كبير', 'صغير'][i % 4]}';
    double qty = (i * 7 % 500).toDouble();
    if (i % 211 == 0) name = null;
    if (i % 307 == 0) name = 'صنف رقم ${i - 1} ${['أحمر', 'أزرق', 'كبير', 'صغير'][(i - 1) % 4]}';
    if (i % 401 == 0) qty = -3;
    // A repeated name has its own barcode: a second product (FYONA allows
    // it, the review notes it). A negative quantity is added as zero.
    final ok = name != null;
    if (name != null) seen.add(name);
    if (ok) e.productsOk++;
    final buy = (i % 90 + 1) + .25, sale = buy * 1.3;
    b.insert('tbl_items', {
      'ItemID': i, 'ItemName': name, 'Barcode': '628${'$i'.padLeft(10, '0')}', 'CatID': i % 40 + 1,
      'BuyPrice': buy, 'SalePrice': double.parse(sale.toStringAsFixed(2)), 'Qty': qty, 'MinQty': 5,
      'UnitName': 'حبة', 'Notes': i % 9 == 0 ? 'ملاحظة $i' : null,
    });
    if (ok && i % 100 == 7) {
      e.sample[name] = {'barcode': '628${'$i'.padLeft(10, '0')}', 'sale': double.parse(sale.toStringAsFixed(2)),
          'stock': qty < 0 ? 0.0 : qty, 'category': 'قسم ${i % 40 + 1}', 'units': i % 2 == 1 ? 1 : 0, 'image': i % 7 == 0};
    }
    if (i % 2 == 1) {
      e.units++;
      if (ok) e.unitsOk++;
      b.insert('tbl_item_units', {'ItemID': i, 'UnitName': 'كرتون', 'Factor': 12, 'UnitBarcode': '629${'$i'.padLeft(10, '0')}',
          'UnitPrice': double.parse((sale * 12).toStringAsFixed(2))});
    }
    if (i % 4 == 0) {
      e.barcodes++;
      b.insert('tbl_item_barcodes', {'ItemID': i, 'Barcode': '627${'$i'.padLeft(10, '0')}'});
    }
    if (i % 7 == 0) {
      e.images++;
      b.insert('tbl_item_images', {'ItemID': i, 'Img': _png(i)});
    }
  }
  // A unit pointing at no product (orphan): listed, never imported.
  b.insert('tbl_item_units', {'ItemID': 999999, 'UnitName': 'كرتون', 'Factor': 6, 'UnitBarcode': 'x', 'UnitPrice': 1});
  final names = <String>{};
  for (var c = 1; c <= 1200; c++) {
    e.customers++;
    final cents = rnd.nextInt(500000);
    final bal = c % 97 == 0 ? -50.0 : cents / 100; // a credit balance: entered by hand
    final name = 'عميل $c';
    if (bal >= 0 && names.add('c|$name')) {
      e.customersOk++;
      e.customerTotalMinor += (bal * 100).round();
    }
    b.insert('tbl_customers', {'CustID': c, 'CustName': name, 'Mobile': '05${'$c'.padLeft(8, '0')}', 'Balance': bal, 'Currency': 'SAR'});
  }
  for (var s = 1; s <= 150; s++) {
    e.suppliers++;
    e.suppliersOk++;
    final cents = rnd.nextInt(900000);
    e.supplierTotalMinor += cents;
    b.insert('tbl_suppliers', {'SuppID': s, 'SuppName': 'مورد $s', 'Phone': '01${'$s'.padLeft(8, '0')}', 'Balance': cents / 100});
  }
  for (var a = 1; a <= 5; a++) {
    e.accounts++;
    e.accountTotalMinor += a * 100000;
    b.insert('tbl_bank_accounts', {'AccID': a, 'AccountName': 'حساب $a', 'BankName': 'بنك ${a % 2 == 0 ? 'الراجحي' : 'الأهلي'}',
        'AccountNumber': 'SA$a${'0' * 10}', 'Balance': a * 1000.0});
  }
  for (var v = 1; v <= 3000; v++) {
    b.insert('tbl_sales_invoices', {'InvID': v, 'InvDate': '2025-0${v % 9 + 1}-1${v % 9}', 'CustID': v % 1200 + 1, 'Total': v * 1.5, 'Paid': v * 1.0});
    b.insert('tbl_invoice_details', {'InvID': v, 'ItemID': v % products + 1, 'Qty': 2, 'Price': 3.5});
  }
  for (var x = 1; x <= 30; x++) {
    b.insert('tbl_employees', {'EmpID': x, 'EmpName': 'موظف $x', 'Salary': 4000 + x, 'HireDate': '2023-01-01'});
  }
  b.insert('tbl_settings', {'SetKey': 'tax', 'SetValue': '15'});
  await b.commit(noResult: true);
  await db.close();
  return e;
}
