// Review before import: every row checked again after each edit; the
// user's decisions; only accepted rows reach the import.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/import/import_plan.dart';
import 'package:fyona_flutter/core/import/import_source.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('fyona-review-'));
  tearDown(() => dir.delete(recursive: true));

  Future<ImportTable> csv(String text) async =>
      (await readImportFile(File('${dir.path}/t.csv')..writeAsStringSync(text))).single;

  test('edit a cell, the row is checked again; duplicates follow the edits', () async {
    final t = await csv('الاسم,الرصيد,ملاحظة داخلية\nأحمد,abc,x\nسالم,10,y\nسالم,20,z\n');
    final r = await ImportReview.load(t, ImportTarget.parties, autoMapColumns(ImportTarget.parties, t.columns));
    expect(r.unusedColumns, ['ملاحظة داخلية']); // never saved
    expect([for (final x in r.rows) x.reasons], [['bad_number'], <String>[], ['duplicate_in_file']]);
    r.edit(r.rows[0], 'balance', '١٥٠٫٥');
    r.edit(r.rows[2], 'name', 'سالم الثاني');
    expect(r.acceptedCount, 3);
    final p = r.toPreview();
    expect(p.parties.map((e) => (e.name, e.amountMinor)), [('أحمد', 15050), ('سالم', 1000), ('سالم الثاني', 2000)]);
    expect(p.totals, {'customer': {'SAR': 18050}});
  });

  test('leave out rows, put them back; only accepted rows are imported', () async {
    final t = await csv('name,balance\nA,1\nB,2\nC,3\n');
    final r = await ImportReview.load(t, ImportTarget.parties, autoMapColumns(ImportTarget.parties, t.columns));
    r.setRejected(r.rows.take(2), true);
    expect(r.acceptedCount, 1);
    expect(r.refusedByReason, {'rejected_by_user': 2});
    expect(r.toPreview().parties.single.name, 'C');
    r.setRejected([r.rows.first], false);
    expect(r.toPreview().parties.map((e) => e.name), ['A', 'C']);
  });

  test('a whole column given to another field (Sara was wrong) changes every row', () async {
    final t = await csv('المنتج,السعر,الكمية\nقلم,2.5,100\nدفتر,7,3\n');
    final wrong = await ImportReview.load(t, ImportTarget.products, {'name': 'المنتج', 'stock': 'السعر', 'sale_price': 'الكمية'});
    expect(wrong.toPreview().products.first.stock, '2.5');
    final right = await ImportReview.load(t, ImportTarget.products, {'name': 'المنتج', 'stock': 'الكمية', 'sale_price': 'السعر'});
    expect(right.toPreview().products.map((p) => (p.sale, p.stock)), [('2.5', '100'), ('7', '3')]);
  });

  test('large files: 100 000 products checked, edited and re-checked quickly', () async {
    final b = StringBuffer('الصنف,الباركود,سعر الشراء,سعر البيع,الكمية,الوحدة,التصنيف\n');
    for (var i = 0; i < 100000; i++) {
      b.write('منتج رقم $i,62${'$i'.padLeft(10, '0')},${i % 50}.25,${i % 50 + 3}.5,${i % 999},حبة,قسم ${i % 40}\n');
    }
    b.write('منتج رقم 5,999,1,1,1,حبة,x\n'); // duplicate name
    b.write(',1,1,1,1,حبة,x\n'); // no name
    final t = await csv(b.toString());
    final sw = Stopwatch()..start();
    final rss = ProcessInfo.currentRss;
    final r = await ImportReview.load(t, ImportTarget.products, autoMapColumns(ImportTarget.products, t.columns));
    final load = sw.elapsedMilliseconds;
    expect(r.acceptedCount, 100000);
    expect(r.refusedByReason, {'duplicate_in_file': 1, 'missing_name': 1});
    sw.reset();
    r.edit(r.rows.last, 'name', 'منتج جديد');
    final recheck = sw.elapsedMilliseconds;
    expect(r.acceptedCount, 100001);
    // ignore: avoid_print
    print('REVIEW_BENCH 100002 rows: load ${load}ms, re-check after an edit ${recheck}ms, '
        'RSS +${((ProcessInfo.currentRss - rss) / 1048576).toStringAsFixed(1)} MB');
    expect(recheck, lessThan(3000));
    expect(jsonEncode(r.toPreview().products.length), '100001');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
