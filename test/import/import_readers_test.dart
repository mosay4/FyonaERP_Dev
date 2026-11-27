// Smart import readers: every supported format, and hostile files.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' hide ZLibEncoder;
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/import/import_plan.dart';
import 'package:fyona_flutter/core/import/import_source.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _xlsxSheet(List<List<String>> rows, {bool shared = false, List<String>? sst}) {
  final b = StringBuffer('<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>');
  for (var r = 0; r < rows.length; r++) {
    b.write('<row r="${r + 1}">');
    for (var c = 0; c < rows[r].length; c++) {
      final ref = '${String.fromCharCode(65 + c)}${r + 1}';
      final v = rows[r][c];
      if (num.tryParse(v) != null) {
        b.write('<c r="$ref"><v>$v</v></c>');
      } else if (shared) {
        sst!.add(v);
        b.write('<c r="$ref" t="s"><v>${sst.length - 1}</v></c>');
      } else {
        b.write('<c r="$ref" t="inlineStr"><is><t>${const HtmlEscape().convert(v)}</t></is></c>');
      }
    }
    b.write('</row>');
  }
  b.write('</sheetData></worksheet>');
  return b.toString();
}

Uint8List _zip(Map<String, List<int>> files) {
  final a = Archive();
  for (final e in files.entries) {
    a.addFile(ArchiveFile(e.key, e.value.length, e.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(a));
}

Uint8List _xlsx(List<List<String>> rows, {bool shared = false}) {
  final sst = <String>[];
  final sheet = _xlsxSheet(rows, shared: shared, sst: sst);
  return _zip({
    '[Content_Types].xml': utf8.encode('<Types/>'),
    'xl/workbook.xml': utf8.encode('<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="العملاء" sheetId="1" r:id="rId1"/></sheets></workbook>'),
    'xl/_rels/workbook.xml.rels': utf8.encode('<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>'),
    'xl/worksheets/sheet1.xml': utf8.encode(sheet),
    if (shared) 'xl/sharedStrings.xml': utf8.encode('<sst>${sst.map((s) => '<si><t>${const HtmlEscape().convert(s)}</t></si>').join()}</sst>'),
  });
}

const _rows = [
  ['الاسم', 'الجوال', 'الرصيد'],
  ['محمد علي', '0500000001', '1,250.50'],
  ['شركة النور، فرع "1"', '0500000002', '٣٠٠٫٢٥'],
];

void main() {
  sqfliteFfiInit();
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('fyona-import-'));
  tearDown(() => dir.delete(recursive: true));

  File put(String name, List<int> bytes) => File('${dir.path}/$name')..writeAsBytesSync(bytes);

  Future<List<List<String?>>> all(ImportTable t) => t.rows().toList();

  test('CSV: Arabic with BOM, semicolons, quotes and commas inside cells', () async {
    final csv = '﻿الاسم;الجوال;الرصيد\r\nمحمد علي;0500000001;"1,250.50"\r\n"شركة النور، فرع ""1""";0500000002;٣٠٠٫٢٥\r\n\r\n';
    final t = (await readImportFile(put('a.csv', utf8.encode(csv)))).single;
    expect(t.columns, ['الاسم', 'الجوال', 'الرصيد']);
    expect(await all(t), [_rows[1], _rows[2]]);
  });

  test('XLSX (inline and shared strings), JSON, XML, SQL INSERT, SQLite: same rows', () async {
    for (final shared in [false, true]) {
      final t = (await readImportFile(put('a$shared.xlsx', _xlsx(_rows, shared: shared)))).single;
      expect(t.name, 'العملاء');
      expect(t.columns, _rows.first);
      expect(await all(t), [_rows[1], _rows[2]]);
    }
    final json = jsonEncode([for (final r in _rows.skip(1)) {for (var i = 0; i < 3; i++) _rows[0][i]: r[i]}]);
    expect(await all((await readImportFile(put('a.json', utf8.encode(json)))).single), [_rows[1], _rows[2]]);
    final xml = '<?xml version="1.0"?><customers>${_rows.skip(1).map((r) => '<customer><الاسم>${const HtmlEscape().convert(r[0])}</الاسم><الجوال>${r[1]}</الجوال><الرصيد>${r[2]}</الرصيد></customer>').join()}</customers>';
    final x = (await readImportFile(put('a.xml', utf8.encode(xml)))).single;
    expect(x.columns, _rows.first);
    expect(await all(x), [_rows[1], _rows[2]]);
    final sql = "INSERT INTO customers (`الاسم`, `الجوال`, `الرصيد`) VALUES ('محمد علي', '0500000001', '1,250.50'),\n"
        "('شركة النور، فرع \"1\"', '0500000002', '٣٠٠٫٢٥');\nINSERT INTO notes VALUES (1, 'it''s', NULL);";
    final s = await readImportFile(put('a.sql', utf8.encode(sql)));
    expect(s.first.columns, _rows.first);
    expect(await all(s.first), [_rows[1], _rows[2]]);
    expect(await all(s.last), [['1', "it's", null]]);
    final dbFile = '${dir.path}/old.db';
    final db = await databaseFactoryFfi.openDatabase(dbFile);
    await db.execute('CREATE TABLE customers (name TEXT, phone TEXT, balance REAL)');
    await db.insert('customers', {'name': 'محمد علي', 'phone': '0500000001', 'balance': 1250.5});
    await db.close();
    final q = (await readImportFile(File(dbFile))).single;
    expect(q.columns, ['name', 'phone', 'balance']);
    expect(await all(q), [['محمد علي', '0500000001', '1250.5']]);
  });

  test('a ZIP of files: every table inside, names never used as paths', () async {
    final z = _zip({
      '../../evil/customers.csv': utf8.encode('name,balance\nA,1\n'),
      'sub/products.xlsx': _xlsx([['المنتج', 'الكمية'], ['قلم', '5']]),
      'readme.pdf': [1, 2, 3],
    });
    final tables = await readImportFile(put('data.zip', z));
    expect(tables.map((t) => t.name), ['customers.csv · customers.csv', 'products.xlsx · العملاء']);
    expect(File('${dir.path}/../evil/customers.csv').existsSync(), isFalse);
  });

  group('hostile files are refused', () {
    Future<void> refused(String name, List<int> bytes, String code) =>
        expectLater(readImportFile(put(name, bytes)), throwsA(isA<ImportRejected>().having((e) => e.code, 'code', code)));

    test('compression bomb (declared huge, or lying about its size)', () async {
      // 300 MB of zeros, declared honestly: over the per-file cap.
      final enc = ZLibEncoder(raw: true);
      final zeros = Uint8List(1 << 20);
      final sink = BytesBuilder();
      final conv = enc.startChunkedConversion(ByteConversionSink.withCallback(sink.add));
      for (var i = 0; i < 300; i++) {
        conv.add(zeros);
      }
      conv.close();
      final packed = sink.takeBytes();
      Uint8List entry(int declared) {
        final name = utf8.encode('big.csv');
        final local = BytesBuilder()
          ..add([0x50, 0x4B, 0x03, 0x04, 20, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0])
          ..add((ByteData(8)
                ..setUint32(0, packed.length, Endian.little)
                ..setUint32(4, declared, Endian.little))
              .buffer
              .asUint8List())
          ..add([name.length, 0, 0, 0])
          ..add(name)
          ..add(packed);
        final l = local.takeBytes();
        final cd = BytesBuilder()
          ..add([0x50, 0x4B, 0x01, 0x02, 20, 0, 20, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0])
          ..add((ByteData(8)
                ..setUint32(0, packed.length, Endian.little)
                ..setUint32(4, declared, Endian.little))
              .buffer
              .asUint8List())
          ..add([name.length, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
          ..add(name);
        final c = cd.takeBytes();
        final end = ByteData(22)
          ..setUint32(0, 0x06054b50, Endian.little)
          ..setUint16(8, 1, Endian.little)
          ..setUint16(10, 1, Endian.little)
          ..setUint32(12, c.length, Endian.little)
          ..setUint32(16, l.length, Endian.little);
        return Uint8List.fromList([...l, ...c, ...end.buffer.asUint8List()]);
      }

      final rss = ProcessInfo.currentRss;
      await refused('bomb.zip', entry(300 << 20), 'bomb');
      await refused('liar.zip', entry(1000), 'bomb');
      expect(ProcessInfo.currentRss - rss, lessThan(200 << 20));
    });

    test('nested archive, too many entries, XML entities, unknown encoding, empty', () async {
      await refused('n.zip', _zip({'inner.zip': _zip({'a.csv': utf8.encode('a\n1')})}), 'nested');
      await refused('many.zip', _zip({for (var i = 0; i < 2001; i++) 'f$i.csv': utf8.encode('a\n1')}), 'bomb');
      await refused('e.xml', utf8.encode('<?xml version="1.0"?><!DOCTYPE l [<!ENTITY a "aaaa"><!ENTITY b "&a;&a;&a;">]><r><x>&b;</x><x>&b;</x></r>'), 'format');
      await refused('w.csv', [0x43, 0xC7, 0xE1, 0x0A, 0xE3, 0xCD], 'encoding');
      await refused('e.csv', [], 'empty');
      await refused('old.xls', [0xD0, 0xCF, 0x11, 0xE0], 'unsupported');
    });
  });

  test('numbers as people write them; columns found by their titles', () {
    expect(importDecimal('1,250.50'), '1250.50');
    expect(importDecimal('١٬٢٥٠٫٥٠'), '1250.50');
    expect(importDecimal('1.250,50'), '1250.50');
    expect(importDecimal('(300)'), '-300');
    expect(importDecimal('300-'), '-300');
    expect(importDecimal('SAR 99'), '99');
    expect(importDecimal('12,5'), '12.5');
    expect(importDecimal('abc'), isNull);
    expect(importMinor('1250.50'), 125050);
    expect(importMinor('1.005'), isNull);
    expect(importMinor('1.500'), 150);
    expect(autoMapColumns(ImportTarget.parties, ['م', 'اسم العميل', 'رقم الجوال', 'الرصيد المستحق', 'العملة']),
        {'name': 'اسم العميل', 'phone': 'رقم الجوال', 'balance': 'الرصيد المستحق', 'currency': 'العملة'});
    expect(autoMapColumns(ImportTarget.products, ['Item', 'Barcode', 'Qty', 'Price']),
        {'name': 'Item', 'barcode': 'Barcode', 'stock': 'Qty', 'sale_price': 'Price'});
  });
}
