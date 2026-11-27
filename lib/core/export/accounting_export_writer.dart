import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

/// Writes an accounting export as one ZIP:
///
/// ```
/// manifest.json        what is inside, row counts, SHA-256 of every file,
///                      control totals, warnings, definitions
/// accounting.xlsx      one sheet per table (Excel / LibreOffice / Numbers)
/// csv/<sheet>.csv      the same tables, UTF-8 with BOM (Arabic opens
///                      correctly in Excel), RFC 4180
/// images/…             product photos referenced by the stock sheet
/// ```
///
/// Rows are streamed to disk as they come (CSV and sheet XML together), so
/// 100 000s of rows never sit in memory; the ZIP is built in a background
/// isolate from the files. Text that a spreadsheet would run as a formula
/// (`= + - @` …) is neutralised.
class AccountingExportWriter {
  AccountingExportWriter({
    required this.work,
    required this.sheets,
    required this.numeric,
    required this.arabic,
  });

  final Directory work;
  final Map<String, List<String>> sheets;
  final Set<String> numeric;
  final bool arabic;

  static const maxSheetRows = 1048575; // Excel limit minus the header row
  final _csv = <String, IOSink>{};
  final _xml = <String, List<_Part>>{};
  final rows = <String, int>{};
  bool _open = false;

  Future<void> _start() async {
    if (_open) return;
    _open = true;
    await Directory('${work.path}/csv').create(recursive: true);
    await Directory('${work.path}/xl').create(recursive: true);
    for (final s in sheets.keys) {
      final csv = File('${work.path}/csv/$s.csv').openWrite();
      csv.add(const [0xEF, 0xBB, 0xBF]); // BOM: Excel reads UTF-8 (Arabic)
      csv.write('${sheets[s]!.map((c) => _csvCell(_header(c), false)).join(',')}\r\n');
      _csv[s] = csv;
      rows[s] = 0;
      _xml[s] = [];
      _newPart(s);
    }
  }

  void _newPart(String s) {
    final n = _xml.values.fold<int>(0, (a, l) => a + l.length) + 1;
    final f = File('${work.path}/xl/sheet$n.xml');
    final sink = f.openWrite();
    final part = _Part(s, f, sink, _xml[s]!.length + 1);
    _xml[s]!.add(part);
    sink.write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<sheetViews><sheetView workbookViewId="0"${arabic ? ' rightToLeft="1"' : ''}>'
        '<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'
        '<sheetData><row>');
    for (final c in sheets[s]!) {
      sink.write('<c t="inlineStr" s="2"><is><t>${_xmlText(_header(c))}</t></is></c>');
    }
    sink.write('</row>');
  }

  Future<void> add(String sheet, List<Object?> values) async {
    await _start();
    final cols = sheets[sheet]!;
    final csv = _csv[sheet]!;
    final b = StringBuffer();
    for (var i = 0; i < cols.length; i++) {
      if (i > 0) b.write(',');
      b.write(_csvCell(_text(i < values.length ? values[i] : null), numeric.contains(cols[i])));
    }
    b.write('\r\n');
    csv.write(b);
    var part = _xml[sheet]!.last;
    if (part.rows >= maxSheetRows) {
      _newPart(sheet);
      part = _xml[sheet]!.last;
    }
    final x = StringBuffer('<row>');
    for (var i = 0; i < cols.length; i++) {
      final v = _text(i < values.length ? values[i] : null);
      if (v.isEmpty) {
        x.write('<c/>');
      } else if (numeric.contains(cols[i]) && _number.hasMatch(v)) {
        x.write('<c s="${_money.contains(cols[i]) ? 1 : 0}"><v>$v</v></c>');
      } else {
        x.write('<c t="inlineStr"><is><t xml:space="preserve">${_xmlText(v)}</t></is></c>');
      }
    }
    x.write('</row>');
    part.sink.write(x);
    part.rows++;
    rows[sheet] = rows[sheet]! + 1;
    // Let the sinks drain now and then (bounded buffers).
    if (rows[sheet]! % 2000 == 0) {
      await csv.flush();
      await part.sink.flush();
    }
  }

  static final _number = RegExp(r'^-?\d+(\.\d+)?$');
  static const _money = {
    'balance_cutoff', 'balance_now', 'value_cutoff', 'total', 'paid_cutoff', 'remaining_cutoff',
    'remaining_now', 'unit_price', 'discount', 'original', 'applied', 'delta', 'balance_after', 'avg_cost',
  };

  /// Closes the tables and writes the ZIP at [zip]. [files] are extra files
  /// (path inside the ZIP → file on disk, e.g. images).
  Future<File> finish(File zip, Map<String, Object?> manifest, {Map<String, File> files = const {}}) async {
    await _start();
    for (final s in _csv.values) {
      await s.flush();
      await s.close();
    }
    final parts = [for (final l in _xml.values) ...l];
    for (final p in parts) {
      p.sink.write('</sheetData></worksheet>');
      await p.sink.flush();
      await p.sink.close();
    }
    final names = <String>[];
    for (final p in parts) {
      final title = _sheetTitle(p.sheet);
      names.add(_safeSheet(p.index == 1 ? title : '$title ${p.index}'));
    }
    final xlsx = File('${work.path}/accounting.xlsx');
    final xlsxPath = xlsx.path;
    final sheetPaths = [for (final p in parts) p.file.path];
    await Isolate.run(() => _buildXlsx(xlsxPath, sheetPaths, names));
    final entries = <String, String>{
      'accounting.xlsx': xlsx.path,
      for (final s in sheets.keys) 'csv/$s.csv': '${work.path}/csv/$s.csv',
      for (final e in files.entries) e.key: e.value.path,
    };
    final list = <Map<String, Object?>>[];
    for (final e in entries.entries) {
      final f = File(e.value);
      list.add({'path': e.key, 'bytes': await f.length(), 'sha256': '${await sha256.bind(f.openRead()).first}'});
    }
    final man = File('${work.path}/manifest.json');
    await man.writeAsString(const JsonEncoder.withIndent('  ').convert({
      ...manifest,
      'sheets': {for (final s in sheets.keys) s: rows[s]},
      'files': list,
    }));
    final zipPath = zip.path;
    final all = {'manifest.json': man.path, ...entries};
    await Isolate.run(() => _buildZip(zipPath, all));
    return zip;
  }

  String _header(String key) => (arabic ? _ar : _en)[key] ?? key;
  String _sheetTitle(String key) => (arabic ? _arSheets : _enSheets)[key] ?? key;

  static String _safeSheet(String s) {
    final t = s.replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ');
    return t.length > 31 ? t.substring(0, 31) : t;
  }

  static String _text(Object? v) => v == null ? '' : '$v';

  static String _csvCell(String v, bool number) {
    var s = v;
    // A cell starting with = + - @ (or tab / CR) runs as a formula in
    // spreadsheets: kept as text with a leading apostrophe.
    if (!number && s.isNotEmpty && '=+-@\t\r'.contains(s[0])) s = "'$s";
    if (s.contains(RegExp('[",\r\n]')) || s.startsWith(' ') || s.endsWith(' ')) {
      s = '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  static final _badXml = RegExp('[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]');
  static String _xmlText(String v) => v
      .replaceAll(_badXml, '')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static const _arSheets = {
    'opening_accounts': 'أرصدة الحسابات', 'opening_parties': 'أرصدة العملاء والموردين',
    'opening_stock': 'المخزون الافتتاحي', 'documents': 'الفواتير والمستندات', 'document_lines': 'بنود الفواتير',
    'payments': 'الدفعات', 'returns': 'المرتجعات', 'bank_movements': 'حركات الحسابات',
  };
  static const _enSheets = {
    'opening_accounts': 'Account balances', 'opening_parties': 'Customer & supplier balances',
    'opening_stock': 'Opening stock', 'documents': 'Invoices & documents', 'document_lines': 'Invoice lines',
    'payments': 'Payments', 'returns': 'Returns', 'bank_movements': 'Account movements',
  };
  static const _ar = {
    'account_id': 'معرف الحساب', 'bank': 'البنك', 'account_name': 'اسم الحساب', 'account_number': 'رقم الحساب',
    'iban': 'الآيبان', 'currency': 'العملة', 'balance_cutoff': 'الرصيد في تاريخ القطع', 'balance_now': 'الرصيد الحالي',
    'party_id': 'معرف الطرف', 'kind': 'النوع', 'name': 'الاسم', 'phone': 'الجوال', 'email': 'البريد',
    'open_documents': 'مستندات مفتوحة', 'product_id': 'معرف المنتج', 'sku': 'رمز المنتج', 'barcode': 'الباركود',
    'unit': 'الوحدة', 'quantity_cutoff': 'الكمية في تاريخ القطع', 'quantity_now': 'الكمية الحالية',
    'avg_cost': 'متوسط التكلفة', 'value_cutoff': 'القيمة في تاريخ القطع', 'image_file': 'ملف الصورة',
    'document_id': 'معرف المستند', 'source': 'المصدر', 'type': 'النوع', 'number': 'الرقم', 'date': 'التاريخ',
    'party_kind': 'نوع الطرف', 'party_name': 'اسم الطرف', 'total': 'الإجمالي', 'paid_cutoff': 'المدفوع حتى تاريخ القطع',
    'remaining_cutoff': 'المتبقي في تاريخ القطع', 'remaining_now': 'المتبقي الحالي', 'status_cutoff': 'الحالة في تاريخ القطع',
    'warning': 'تنبيه', 'line_id': 'معرف البند', 'description': 'الوصف', 'quantity': 'الكمية', 'unit_price': 'سعر الوحدة',
    'discount': 'الخصم', 'tax_rate': 'نسبة الضريبة', 'payment_id': 'معرف الدفعة', 'method': 'طريقة الدفع',
    'payment_currency': 'عملة الدفع', 'original': 'المبلغ الأصلي', 'applied': 'المبلغ المطبق', 'debt_currency': 'عملة الدين',
    'exchange_rate': 'سعر الصرف', 'return_id': 'معرف المرتجع', 'date_time': 'التاريخ والوقت', 'delta': 'المبلغ',
    'balance_after': 'الرصيد بعد الحركة', 'reference': 'المرجع',
  };
  static const _en = {
    'account_id': 'Account ID', 'bank': 'Bank', 'account_name': 'Account name', 'account_number': 'Account number',
    'iban': 'IBAN', 'currency': 'Currency', 'balance_cutoff': 'Balance at cut-off', 'balance_now': 'Current balance',
    'party_id': 'Party ID', 'kind': 'Kind', 'name': 'Name', 'phone': 'Phone', 'email': 'Email',
    'open_documents': 'Open documents', 'product_id': 'Product ID', 'sku': 'SKU', 'barcode': 'Barcode', 'unit': 'Unit',
    'quantity_cutoff': 'Quantity at cut-off', 'quantity_now': 'Current quantity', 'avg_cost': 'Average cost',
    'value_cutoff': 'Value at cut-off', 'image_file': 'Image file', 'document_id': 'Document ID', 'source': 'Source',
    'type': 'Type', 'number': 'Number', 'date': 'Date', 'party_kind': 'Party kind', 'party_name': 'Party name',
    'total': 'Total', 'paid_cutoff': 'Paid by cut-off', 'remaining_cutoff': 'Remaining at cut-off',
    'remaining_now': 'Remaining now', 'status_cutoff': 'Status at cut-off', 'warning': 'Warning', 'line_id': 'Line ID',
    'description': 'Description', 'quantity': 'Quantity', 'unit_price': 'Unit price', 'discount': 'Discount',
    'tax_rate': 'Tax rate', 'payment_id': 'Payment ID', 'method': 'Method', 'payment_currency': 'Payment currency',
    'original': 'Original amount', 'applied': 'Applied amount', 'debt_currency': 'Debt currency',
    'exchange_rate': 'Exchange rate', 'return_id': 'Return ID', 'date_time': 'Date and time', 'delta': 'Amount',
    'balance_after': 'Balance after', 'reference': 'Reference',
  };
}

class _Part {
  _Part(this.sheet, this.file, this.sink, this.index);
  final String sheet;
  final File file;
  final IOSink sink;
  final int index;
  int rows = 0;
}

const _ns = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const _rel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

Future<void> _buildXlsx(String path, List<String> sheetFiles, List<String> names) async {
  final dir = Directory('${File(path).parent.path}/xlsx-meta')..createSync(recursive: true);
  File meta(String name, String body) => File('${dir.path}/${name.replaceAll('/', '_')}')..writeAsStringSync(body);
  String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
  final n = sheetFiles.length;
  final enc = ZipFileEncoder()..create(path, level: 6);
  final files = <String, File>{
    '[Content_Types].xml': meta('ct.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '${[for (var i = 1; i <= n; i++) '<Override PartName="/xl/worksheets/sheet$i.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'].join()}'
        '</Types>'),
    '_rels/.rels': meta('rels.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="$_rel/officeDocument" Target="xl/workbook.xml"/></Relationships>'),
    'xl/workbook.xml': meta('wb.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="$_ns" xmlns:r="$_rel"><sheets>'
        '${[for (var i = 1; i <= n; i++) '<sheet name="${esc(names[i - 1])}" sheetId="$i" r:id="rId$i"/>'].join()}'
        '</sheets></workbook>'),
    'xl/_rels/workbook.xml.rels': meta('wbrels.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '${[for (var i = 1; i <= n; i++) '<Relationship Id="rId$i" Type="$_rel/worksheet" Target="worksheets/sheet$i.xml"/>'].join()}'
        '<Relationship Id="rId${n + 1}" Type="$_rel/styles" Target="styles.xml"/></Relationships>'),
    'xl/styles.xml': meta('styles.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="$_ns"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'
        '<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
        '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
        '<xf numFmtId="4" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
        '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs></styleSheet>'),
    for (var i = 1; i <= n; i++) 'xl/worksheets/sheet$i.xml': File(sheetFiles[i - 1]),
  };
  for (final e in files.entries) {
    await enc.addFile(e.value, e.key);
  }
  await enc.close();
  dir.deleteSync(recursive: true);
}

Future<void> _buildZip(String path, Map<String, String> entries) async {
  final enc = ZipFileEncoder()..create(path, level: 6);
  for (final e in entries.entries) {
    final input = InputFileStream(e.value);
    final f = ArchiveFile.stream(e.key, input)..lastModTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Photos are already compressed: stored as they are, streamed from disk.
    if (e.key.startsWith('images/') || e.key.endsWith('.xlsx')) f.compression = CompressionType.none;
    enc.addArchiveFile(f);
    await input.close();
  }
  await enc.close();
}
