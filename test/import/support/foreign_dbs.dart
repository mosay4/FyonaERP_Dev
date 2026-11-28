// Databases of OTHER accounting / POS apps for the smart import tests,
// each built differently on purpose:
//
//  * shop: an English multi-branch system shaped like the owner's real test
//    file (branches, currencies, products without prices, prices / units /
//    barcodes / pictures / stock-per-branch in their own tables, customer
//    receivables, supplier payables, cash boxes, bank accounts) plus tables
//    FYONA has no place for (employees, invoices, payments, maintenance work
//    orders, warranty contracts, subscription plans, audit logs) and
//    deliberately wrong rows.
//  * arabic: an Arabic desktop program (Arabic table and column names).
//  * csv zip: a cloud bookkeeping export (one CSV per list in a ZIP).
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Uint8List _png(int seed) {
  final r = Random(seed);
  return Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List.generate(400, (_) => r.nextInt(256))]);
}

String _bc(String head, int i) => '$head${'$i'.padLeft(10, '0')}';

/// What a correct import of the shop file (branch 2 «فرع الحصبة», currency
/// SAR) must give.
class ShopExpect {
  int products = 0, productsOk = 0, sameName = 0, dupBarcode = 0, noName = 0;
  int extraUnits = 0, extraBarcodes = 0, droppedCodes = 0, images = 0, usdPrices = 0, negativeStock = 0;
  int customers = 0, customersOk = 0, customersOtherBranch = 0, customersDup = 0, multiCurrency = 0, credit = 0;
  int suppliersOk = 0, accountsOk = 0;
  int customerTotalMinor = 0, supplierTotalMinor = 0, accountTotalMinor = 0;

  /// sale/cost minor and stock (×1000) of every accepted product by barcode.
  final sale = <String, int>{}, cost = <String, int>{}, stock = <String, int>{};
  final category = <String, String>{};
  final roles = <String, String>{};
}

Future<ShopExpect> buildShopDb(String path, {int products = 5500, int customers = 800, int seed = 3}) async {
  final f = File(path);
  if (f.existsSync()) f.deleteSync();
  final db = await databaseFactoryFfi.openDatabase(path);
  final e = ShopExpect();
  final rnd = Random(seed);
  Future<void> table(String sql, String role) async {
    await db.execute(sql);
    e.roles[RegExp(r'CREATE TABLE (\w+)').firstMatch(sql)![1]!] = role;
  }

  await table('CREATE TABLE branches (id INTEGER PRIMARY KEY, name TEXT, city TEXT, phone TEXT)', 'branches');
  await table('CREATE TABLE currencies (id INTEGER PRIMARY KEY, code TEXT, name TEXT, symbol TEXT)', 'currencies');
  await table('CREATE TABLE categories (id INTEGER PRIMARY KEY, name TEXT, parent_id INTEGER, sort_order INTEGER)', 'categories');
  await table(
      'CREATE TABLE products (id INTEGER PRIMARY KEY, name_ar TEXT, name_en TEXT, sku TEXT, barcode TEXT, category_id INTEGER, '
          'brand TEXT, description TEXT, unit TEXT, tax_rate REAL, min_qty REAL, is_active INTEGER, weight REAL, '
          'created_at TEXT, updated_at TEXT, notes TEXT, supplier_id INTEGER)',
      'products');
  await table('CREATE TABLE product_units (id INTEGER PRIMARY KEY, product_id INTEGER, unit_name TEXT, factor REAL, barcode TEXT, price REAL)', 'units');
  await table('CREATE TABLE product_barcodes (id INTEGER PRIMARY KEY, product_id INTEGER, barcode TEXT)', 'barcodes');
  await table('CREATE TABLE product_prices (id INTEGER PRIMARY KEY, product_id INTEGER, price_type TEXT, price REAL, currency_id INTEGER)', 'prices');
  await table('CREATE TABLE product_images (id INTEGER PRIMARY KEY, product_id INTEGER, image BLOB, is_main INTEGER)', 'images');
  await table('CREATE TABLE inventory_stock (id INTEGER PRIMARY KEY, product_id INTEGER, branch_id INTEGER, quantity REAL, updated_at TEXT)', 'stock');
  await table('CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT, phone TEXT, email TEXT, branch_id INTEGER, credit_limit REAL, created_at TEXT)', 'customers');
  await table('CREATE TABLE suppliers (id INTEGER PRIMARY KEY, name TEXT, phone TEXT, email TEXT, created_at TEXT)', 'suppliers');
  await table(
      'CREATE TABLE customer_receivables (id INTEGER PRIMARY KEY, customer_id INTEGER, invoice_id INTEGER, amount_due REAL, '
          'paid_amount REAL, due_date TEXT, currency_id INTEGER)',
      'balances');
  await table('CREATE TABLE supplier_payables (id INTEGER PRIMARY KEY, supplier_id INTEGER, amount REAL, due_date TEXT)', 'balances');
  await table('CREATE TABLE cash_boxes (id INTEGER PRIMARY KEY, name TEXT, balance REAL, currency_id INTEGER)', 'accounts');
  await table(
      'CREATE TABLE bank_accounts (id INTEGER PRIMARY KEY, bank_name TEXT, account_name TEXT, account_no TEXT, iban TEXT, balance REAL, currency_id INTEGER)',
      'accounts');
  await table('CREATE TABLE employees (id INTEGER PRIMARY KEY, full_name TEXT, salary REAL, hire_date TEXT, branch_id INTEGER)', 'unsupported');
  await table('CREATE TABLE invoices (id INTEGER PRIMARY KEY, invoice_no TEXT, customer_id INTEGER, invoice_date TEXT, total REAL, paid REAL)', 'history');
  await table('CREATE TABLE invoice_items (id INTEGER PRIMARY KEY, invoice_id INTEGER, product_id INTEGER, qty REAL, price REAL)', 'history');
  await table('CREATE TABLE payments (id INTEGER PRIMARY KEY, invoice_id INTEGER, amount REAL, paid_at TEXT, method TEXT)', 'history');
  await table(
      'CREATE TABLE equipment_maintenance_work_orders (id INTEGER PRIMARY KEY, equipment_name TEXT, issue TEXT, technician TEXT, '
          'cost REAL, status TEXT, opened_at TEXT)',
      'unsupported');
  await table(
      'CREATE TABLE warranty_contracts (id INTEGER PRIMARY KEY, customer_id INTEGER, product_id INTEGER, start_date TEXT, end_date TEXT, terms TEXT)',
      'unsupported');
  await table('CREATE TABLE subscription_billing_plans (id INTEGER PRIMARY KEY, plan_name TEXT, monthly_fee REAL, cycle TEXT)', 'unsupported');
  await table('CREATE TABLE audit_logs (id INTEGER PRIMARY KEY, user_name TEXT, action TEXT, at TEXT)', 'unsupported');

  final b = db.batch();
  b.insert('branches', {'id': 1, 'name': 'الفرع الرئيسي', 'city': 'صنعاء', 'phone': '01'});
  b.insert('branches', {'id': 2, 'name': 'فرع الحصبة', 'city': 'صنعاء', 'phone': '02'});
  b.insert('currencies', {'id': 1, 'code': 'SAR', 'name': 'ريال سعودي', 'symbol': 'ر.س'});
  b.insert('currencies', {'id': 2, 'code': 'USD', 'name': 'دولار', 'symbol': r'$'});
  b.insert('currencies', {'id': 3, 'code': 'YER', 'name': 'ريال يمني', 'symbol': 'ر.ي'});
  for (var c = 1; c <= 25; c++) {
    b.insert('categories', {'id': c, 'name': 'قسم $c', 'parent_id': null, 'sort_order': c});
  }
  final names = <String>{};
  for (var i = 1; i <= products; i++) {
    e.products++;
    var name = 'منتج $i ${['أحمر', 'أزرق', 'كبير', 'صغير'][i % 4]}';
    var barcode = _bc('628', i);
    String? nm = name;
    if (i % 211 == 0) nm = null; // no name: refused
    var dupCode = false;
    if (i % 307 == 0) {
      barcode = _bc('628', i - 1); // same barcode as the one before: refused
      dupCode = i - 1 > 0 && (i - 1) % 211 != 0;
    }
    if (i % 401 == 0) {
      nm = 'منتج ${i - 1} ${['أحمر', 'أزرق', 'كبير', 'صغير'][(i - 1) % 4]}'; // a second product with the same name
    }
    final ok = nm != null && !dupCode;
    if (nm == null) e.noName++;
    if (dupCode) e.dupBarcode++;
    if (ok) {
      e.productsOk++;
      if (!names.add(nm)) e.sameName++;
    }
    name = nm ?? '';
    b.insert('products', {
      'id': i, 'name_ar': nm, 'name_en': 'Product $i', 'sku': 'SKU-$i', 'barcode': barcode, 'category_id': i % 25 + 1,
      'brand': 'ماركة ${i % 9}', 'description': i % 5 == 0 ? 'وصف $i' : null, 'unit': 'حبة', 'tax_rate': 15.0, 'min_qty': 3,
      'is_active': 1, 'weight': 0.5, 'created_at': '2024-01-01', 'updated_at': '2025-01-01', 'notes': null, 'supplier_id': i % 120 + 1,
    });
    // Prices: retail (float noise, e.g. 3.3000000000000003), wholesale (no
    // place in a FYONA product), cost, and USD retail for some.
    final k = i % 90 + 1;
    final retail = k * 1.1, cost = k * 0.7 + 0.25;
    b.insert('product_prices', {'product_id': i, 'price_type': 'retail', 'price': retail, 'currency_id': 1});
    b.insert('product_prices', {'product_id': i, 'price_type': 'wholesale', 'price': retail * 0.9, 'currency_id': 1});
    b.insert('product_prices', {'product_id': i, 'price_type': 'cost', 'price': cost, 'currency_id': 1});
    if (i % 10 == 0) b.insert('product_prices', {'product_id': i, 'price_type': 'retail', 'price': k * 0.3, 'currency_id': 2});
    // The base unit listed again (factor 1, the product's barcode) and a
    // carton for odd products.
    b.insert('product_units', {'product_id': i, 'unit_name': 'حبة', 'factor': 1, 'barcode': barcode, 'price': retail});
    if (i % 2 == 1) {
      b.insert('product_units', {'product_id': i, 'unit_name': 'كرتون', 'factor': 12, 'barcode': _bc('629', i), 'price': retail * 12});
    }
    if (i % 4 == 0) b.insert('product_barcodes', {'product_id': i, 'barcode': _bc('627', i)});
    // An extra code that is another product's own barcode: left out.
    if (i % 50 == 0) b.insert('product_barcodes', {'product_id': i, 'barcode': _bc('628', i - 2)});
    if (i % 7 == 0) b.insert('product_images', {'product_id': i, 'image': _png(i), 'is_main': 1});
    final q1 = (i * 3 % 200).toDouble(), q2 = i % 97 == 0 ? -4.0 : (i * 7 % 150) + 0.5;
    b.insert('inventory_stock', {'product_id': i, 'branch_id': 1, 'quantity': q1, 'updated_at': '2025-01-01'});
    b.insert('inventory_stock', {'product_id': i, 'branch_id': 2, 'quantity': q2, 'updated_at': '2025-01-01'});
    if (ok) {
      if (i % 2 == 1) e.extraUnits++;
      if (i % 4 == 0) e.extraBarcodes++;
      if (i % 50 == 0) {
        // The other product's barcode is in use only if that product is imported.
        final other = i - 2;
        final otherOk = other % 211 != 0 && !(other % 307 == 0);
        if (otherOk) {
          e.droppedCodes++;
        } else {
          e.extraBarcodes++;
        }
      }
      if (i % 7 == 0) e.images++;
      if (i % 10 == 0) e.usdPrices++;
      if (q2 < 0) e.negativeStock++;
      e.sale[barcode] = k * 110;
      e.cost[barcode] = k * 70 + 25;
      e.stock[barcode] = q2 < 0 ? 0 : (q2 * 1000).round();
      e.category[barcode] = 'قسم ${i % 25 + 1}';
    }
  }
  // A unit and a price pointing at no product (orphans).
  b.insert('product_units', {'product_id': 999999, 'unit_name': 'كرتون', 'factor': 6, 'barcode': 'x', 'price': 1});
  final seenCust = <String>{};
  for (var c = 1; c <= customers; c++) {
    e.customers++;
    final branch = c % 3 == 0 ? 1 : 2;
    var name = 'عميل $c';
    final phone = '77${'$c'.padLeft(7, '0')}';
    if (c % 150 == 0) name = 'عميل ${c - 1}'; // the same person again (same phone? no: other phone → kept)
    b.insert('customers', {'id': c, 'name': name, 'phone': c % 150 == 0 ? '77${'${c - 1}'.padLeft(7, '0')}' : phone,
        'email': 'c$c@example.test', 'branch_id': branch, 'credit_limit': 5000, 'created_at': '2024-02-02'});
    // Receivables: 0–3 open invoices; some paid; one customer in two
    // currencies; one overpaid (credit).
    var total = 0, sar = 0;
    final rows = c % 4;
    var usd = false;
    for (var x = 0; x < rows; x++) {
      final due = 1000 + rnd.nextInt(90000), paid = x == 0 && c % 5 == 0 ? 500 : 0;
      final cur = c % 113 == 0 && x == 1 ? 2 : 1;
      if (cur == 2) usd = true;
      b.insert('customer_receivables', {'customer_id': c, 'invoice_id': c * 10 + x, 'amount_due': due / 100,
          'paid_amount': paid / 100, 'due_date': '2025-03-0${x + 1}', 'currency_id': cur});
      total += due - paid;
      if (cur == 1) sar += due - paid;
    }
    if (c % 211 == 0) {
      b.insert('customer_receivables', {'customer_id': c, 'invoice_id': c * 10 + 9, 'amount_due': 0, 'paid_amount': (total + 700) / 100,
          'due_date': '2025-03-09', 'currency_id': 1});
      total -= total + 700;
    }
    if (branch != 2) {
      e.customersOtherBranch++;
      continue;
    }
    final dup = c % 150 == 0 && (c - 1) % 3 != 0; // same name + same phone as a branch-2 customer
    if (dup) {
      e.customersDup++;
      continue;
    }
    if (usd && rows > 1) {
      // Imported: one opening debt per currency (FYONA's recordOpeningDebt).
      e.multiCurrency++;
      e.customersOk++;
      e.customerTotalMinor += sar;
      continue;
    }
    if (total < 0) {
      e.credit++;
      continue;
    }
    if (!seenCust.add(name)) {
      // same name, other phone → still imported (warning)
    }
    e.customersOk++;
    e.customerTotalMinor += total;
  }
  for (var s = 1; s <= 120; s++) {
    final amount = 5000 + rnd.nextInt(400000);
    b.insert('suppliers', {'id': s, 'name': 'مورد $s', 'phone': '71${'$s'.padLeft(7, '0')}', 'email': null, 'created_at': '2024-01-01'});
    b.insert('supplier_payables', {'supplier_id': s, 'amount': amount / 100, 'due_date': '2025-04-01'});
    e.suppliersOk++;
    e.supplierTotalMinor += amount;
  }
  for (var a = 1; a <= 3; a++) {
    b.insert('cash_boxes', {'id': a, 'name': 'صندوق $a', 'balance': a * 250.5, 'currency_id': 1});
    e.accountsOk++;
    e.accountTotalMinor += (a * 25050);
  }
  for (var a = 1; a <= 4; a++) {
    b.insert('bank_accounts', {'id': a, 'bank_name': 'بنك ${a % 2 == 0 ? 'الكريمي' : 'التضامن'}', 'account_name': 'حساب $a',
        'account_no': '000$a', 'iban': null, 'balance': a * 1000.0, 'currency_id': a == 4 ? 2 : 1});
    // FYONA keeps one account per bank and currency: the second «بنك
    // التضامن» in SAR is refused (the banks screen refuses it too).
    if (a == 3) continue;
    e.accountsOk++;
    if (a != 4) e.accountTotalMinor += a * 100000; // the USD one is counted apart
  }
  for (var x = 1; x <= 40; x++) {
    b.insert('employees', {'full_name': 'موظف $x', 'salary': 3000.0 + x, 'hire_date': '2022-01-01', 'branch_id': 1});
  }
  for (var v = 1; v <= 2000; v++) {
    b.insert('invoices', {'invoice_no': 'INV-$v', 'customer_id': v % customers + 1, 'invoice_date': '2025-01-0${v % 9 + 1}', 'total': v * 2.5, 'paid': v * 1.0});
    b.insert('invoice_items', {'invoice_id': v, 'product_id': v % products + 1, 'qty': 2, 'price': 3.5});
    b.insert('payments', {'invoice_id': v, 'amount': v * 1.0, 'paid_at': '2025-01-02', 'method': 'cash'});
  }
  for (var x = 1; x <= 15; x++) {
    b.insert('equipment_maintenance_work_orders',
        {'equipment_name': 'ثلاجة $x', 'issue': 'تبريد', 'technician': 'فني', 'cost': 120.0, 'status': 'open', 'opened_at': '2025-02-02'});
    b.insert('warranty_contracts', {'customer_id': x, 'product_id': x, 'start_date': '2025-01-01', 'end_date': '2026-01-01', 'terms': 'سنة'});
    b.insert('subscription_billing_plans', {'plan_name': 'خطة $x', 'monthly_fee': 10.0 * x, 'cycle': 'monthly'});
    b.insert('audit_logs', {'user_name': 'admin', 'action': 'login', 'at': '2025-01-01'});
  }
  await b.commit(noResult: true);
  await db.close();
  return e;
}

/// An Arabic desktop program: Arabic table and column names, prices and
/// quantities on the item row, units and groups in their own tables.
class ArabicExpect {
  int productsOk = 0, units = 0, customersOk = 0, suppliersOk = 0, boxes = 0;
  int customerTotalMinor = 0, supplierTotalMinor = 0;
  final roles = <String, String>{};
}

Future<ArabicExpect> buildArabicDb(String path, {int products = 1200}) async {
  final f = File(path);
  if (f.existsSync()) f.deleteSync();
  final db = await databaseFactoryFfi.openDatabase(path);
  final e = ArabicExpect();
  Future<void> table(String name, String cols, String role) async {
    await db.execute('CREATE TABLE "$name" ($cols)');
    e.roles[name] = role;
  }

  await table('المجموعات', '"رقم المجموعة" INTEGER PRIMARY KEY, "اسم المجموعة" TEXT', 'categories');
  await table('الأصناف', '"رقم الصنف" INTEGER PRIMARY KEY, "اسم الصنف" TEXT, "الباركود" TEXT, "رقم المجموعة" INTEGER, '
      '"سعر الشراء" REAL, "سعر البيع" REAL, "الكمية" REAL, "الوحدة" TEXT, "حد الطلب" REAL', 'products');
  await table('وحدات الأصناف', '"م" INTEGER PRIMARY KEY, "رقم الصنف" INTEGER, "الوحدة" TEXT, "العدد" REAL, "سعر الوحدة" REAL', 'units');
  await table('العملاء', '"رقم العميل" INTEGER PRIMARY KEY, "اسم العميل" TEXT, "الجوال" TEXT, "مدين" REAL, "دائن" REAL', 'customers');
  await table('الموردين', '"رقم المورد" INTEGER PRIMARY KEY, "اسم المورد" TEXT, "الهاتف" TEXT, "الرصيد" REAL', 'suppliers');
  await table('الصناديق', '"رقم" INTEGER PRIMARY KEY, "اسم الصندوق" TEXT, "الرصيد" REAL', 'accounts');
  await table('فواتير المبيعات', '"رقم الفاتورة" INTEGER PRIMARY KEY, "التاريخ" TEXT, "رقم العميل" INTEGER, "الإجمالي" REAL, "المدفوع" REAL', 'history');
  await table('الموظفين', '"رقم الموظف" INTEGER PRIMARY KEY, "الاسم" TEXT, "الراتب" REAL', 'unsupported');
  final b = db.batch();
  void ins(String t, Map<String, Object?> row) => b.rawInsert(
      'INSERT INTO "$t" (${row.keys.map((k) => '"$k"').join(', ')}) VALUES (${List.filled(row.length, '?').join(', ')})',
      row.values.toList());
  for (var g = 1; g <= 12; g++) {
    ins('المجموعات', {'رقم المجموعة': g, 'اسم المجموعة': 'مجموعة $g'});
  }
  for (var i = 1; i <= products; i++) {
    ins('الأصناف', {'رقم الصنف': i, 'اسم الصنف': 'صنف $i', 'الباركود': _bc('620', i), 'رقم المجموعة': i % 12 + 1,
        'سعر الشراء': i % 40 + 0.5, 'سعر البيع': i % 40 + 1.75, 'الكمية': i % 60, 'الوحدة': 'حبة', 'حد الطلب': 2});
    e.productsOk++;
    if (i % 3 == 0) {
      ins('وحدات الأصناف', {'رقم الصنف': i, 'الوحدة': 'درزن', 'العدد': 12, 'سعر الوحدة': (i % 40 + 1.75) * 12});
      e.units++;
    }
  }
  for (var c = 1; c <= 300; c++) {
    final dr = c * 13 % 9000, cr = c % 5 == 0 ? 100 : 0;
    ins('العملاء', {'رقم العميل': c, 'اسم العميل': 'زبون $c', 'الجوال': '05${'$c'.padLeft(8, '0')}', 'مدين': dr / 10, 'دائن': cr / 10});
    final net = dr * 10 - cr * 10;
    if (net >= 0) {
      e.customersOk++;
      e.customerTotalMinor += net;
    }
  }
  for (var s = 1; s <= 40; s++) {
    ins('الموردين', {'رقم المورد': s, 'اسم المورد': 'مورد $s', 'الهاتف': '01$s', 'الرصيد': s * 10.25});
    e.suppliersOk++;
    e.supplierTotalMinor += s * 1025;
  }
  for (var x = 1; x <= 2; x++) {
    ins('الصناديق', {'رقم': x, 'اسم الصندوق': 'الصندوق $x', 'الرصيد': x * 500.0});
    e.boxes++;
  }
  for (var v = 1; v <= 200; v++) {
    ins('فواتير المبيعات', {'رقم الفاتورة': v, 'التاريخ': '2025-01-01', 'رقم العميل': v % 300 + 1, 'الإجمالي': 10.0, 'المدفوع': 5.0});
  }
  ins('الموظفين', {'رقم الموظف': 1, 'الاسم': 'سالم', 'الراتب': 3000});
  await b.commit(noResult: true);
  await db.close();
  return e;
}

/// A cloud bookkeeping export: one CSV per list in a ZIP (English titles,
/// "Open Balance", amounts with thousands separators and currency words).
class CsvZipExpect {
  int productsOk = 0, customersOk = 0, vendorsOk = 0;
  int customerTotalMinor = 0, vendorTotalMinor = 0;
  final roles = <String, String>{};
}

CsvZipExpect buildCsvZip(String path, {int products = 400}) {
  final e = CsvZipExpect();
  final items = StringBuffer('Item Name,SKU,Type,Sales Price,Purchase Cost,Quantity On Hand,Reorder Point,Income Account\n');
  for (var i = 1; i <= products; i++) {
    items.write('Item $i,IT-$i,Inventory,${i % 30 + 1}.${(i % 4) * 25} SAR,${i % 30}.10,${i % 70},5,Sales\n');
    e.productsOk++;
  }
  final customers = StringBuffer('Customer,Company,Phone,Email,Open Balance,Currency\n');
  for (var c = 1; c <= 120; c++) {
    final bal = c * 137 % 20000;
    customers.write('Customer $c,Co $c,+967 77${'$c'.padLeft(7, '0')},c$c@x.test,"${bal ~/ 100}.${(bal % 100).toString().padLeft(2, '0')}",SAR\n');
    e.customersOk++;
    e.customerTotalMinor += bal;
  }
  final vendors = StringBuffer('Vendor,Phone,Open Balance\n');
  for (var v = 1; v <= 30; v++) {
    vendors.write('Vendor $v,0$v,"1,${(v * 3).toString().padLeft(3, '0')}.50"\n');
    e.vendorsOk++;
    e.vendorTotalMinor += (1000 + v * 3) * 100 + 50;
  }
  const invoices = 'Invoice No,Date,Customer,Total,Balance Due\n1001,2025-01-01,Customer 1,100,50\n';
  const coa = 'Account,Type,Detail Type\nSales,Income,Sales\nRent,Expense,Rent\n';
  final zip = Archive()
    ..addFile(ArchiveFile.bytes('Items.csv', utf8.encode(items.toString())))
    ..addFile(ArchiveFile.bytes('Customers.csv', utf8.encode(customers.toString())))
    ..addFile(ArchiveFile.bytes('Vendors.csv', utf8.encode(vendors.toString())))
    ..addFile(ArchiveFile.bytes('Invoices.csv', utf8.encode(invoices)))
    ..addFile(ArchiveFile.bytes('Chart of Accounts.csv', utf8.encode(coa)));
  e.roles.addAll({'Items': 'products', 'Customers': 'customers', 'Vendors': 'suppliers', 'Invoices': 'history'});
  File(path).writeAsBytesSync(ZipEncoder().encode(zip));
  return e;
}
