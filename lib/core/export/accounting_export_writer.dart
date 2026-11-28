import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';

/// Writes an accounting export as ONE Excel workbook (.xlsx) — the file
/// every accounting program and spreadsheet opens and imports (owner,
/// 28-11: a ZIP of files is accepted by none):
///
/// ```
/// one sheet per table       (accounts, customers & suppliers, stock,
///                            invoices, lines, payments, returns, movements)
/// product pictures          inside the stock sheet, each in its row
/// «File details» sheet      what is inside: date, cut-off, counts,
///                           control totals, warnings, definitions
/// ```
///
/// Rows are streamed to disk as they come (sheet XML), so 100 000s of rows
/// never sit in memory; the workbook is packed in a background isolate
/// from the files. Text that a spreadsheet would run as a formula
/// (`= + - @` …) is kept as text.
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

  /// The column that holds a product's picture (shown as the picture).
  static const imageColumn = 'image_file';
  static const _imageRowHeight = 48; // points (64 px)
  static const _imageEmu = 571500; // 60 px

  final _xml = <String, List<_Part>>{};
  final rows = <String, int>{};
  bool _open = false;

  Future<void> _start() async {
    if (_open) return;
    _open = true;
    await Directory('${work.path}/xl').create(recursive: true);
    for (final s in sheets.keys) {
      rows[s] = 0;
      _xml[s] = [];
      _newPart(s);
    }
  }

  int _parts() => _xml.values.fold<int>(0, (a, l) => a + l.length);

  void _newPart(String s) {
    final n = _parts() + 1;
    final f = File('${work.path}/xl/sheet$n.xml');
    final sink = f.openWrite();
    final part = _Part(s, f, sink, _xml[s]!.length + 1);
    _xml[s]!.add(part);
    final cols = sheets[s]!;
    final img = cols.indexOf(imageColumn);
    sink.write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="$_ns" xmlns:r="$_rel">'
        '<sheetViews><sheetView workbookViewId="0"${arabic ? ' rightToLeft="1"' : ''}>'
        '<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'
        '<sheetFormatPr defaultRowHeight="15"/>'
        '<cols>${[
          for (var i = 0; i < cols.length; i++)
            '<col min="${i + 1}" max="${i + 1}" width="${i == img ? 10 : _colWidth(cols[i])}" customWidth="1"/>',
        ].join()}</cols>'
        '<sheetData><row>');
    for (final c in cols) {
      sink.write('<c t="inlineStr" s="2"><is><t>${_xmlText(_header(c))}</t></is></c>');
    }
    sink.write('</row>');
  }

  static int _colWidth(String key) => switch (key) {
        'name' || 'party_name' || 'description' || 'account_name' => 32,
        'bank' || 'warning' || 'reference' => 24,
        'date' || 'date_time' || 'number' || 'barcode' || 'phone' || 'iban' || 'account_number' => 20,
        _ when key.endsWith('_id') => 38,
        _ => 16,
      };

  Future<void> add(String sheet, List<Object?> values) async {
    await _start();
    final cols = sheets[sheet]!;
    var part = _xml[sheet]!.last;
    if (part.rows >= maxSheetRows) {
      _newPart(sheet);
      part = _xml[sheet]!.last;
    }
    final img = cols.indexOf(imageColumn);
    final picture = img < 0 || img >= values.length ? '' : _text(values[img]);
    final x = StringBuffer(picture.isEmpty ? '<row>' : '<row ht="$_imageRowHeight" customHeight="1">');
    for (var i = 0; i < cols.length; i++) {
      final v = _text(i < values.length ? values[i] : null);
      if (v.isEmpty || i == img) {
        x.write('<c/>');
      } else if (numeric.contains(cols[i]) && _number.hasMatch(v)) {
        x.write('<c s="${_money.contains(cols[i]) ? 1 : 0}"><v>$v</v></c>');
      } else {
        // An inline string is text, never a formula, in every program.
        x.write('<c t="inlineStr"><is><t xml:space="preserve">${_xmlText(v)}</t></is></c>');
      }
    }
    x.write('</row>');
    part.rows++;
    // The picture sits in its cell (row 0 is the header).
    if (picture.isNotEmpty) part.pictures.add((part.rows, img, picture));
    part.sink.write(x);
    rows[sheet] = rows[sheet]! + 1;
    // Let the sinks drain now and then (bounded buffers).
    if (rows[sheet]! % 2000 == 0) await part.sink.flush();
  }

  static final _number = RegExp(r'^-?\d+(\.\d+)?$');
  static const _money = {
    'balance_cutoff', 'balance_now', 'value_cutoff', 'total', 'paid_cutoff', 'remaining_cutoff',
    'remaining_now', 'unit_price', 'discount', 'original', 'applied', 'delta', 'balance_after', 'avg_cost',
  };

  /// Closes the tables and writes the workbook at [out]. [files]: the
  /// pictures (the stock sheet's picture value → the photo on disk); a
  /// picture Excel cannot show (e.g. WebP) is left out and counted in
  /// [skippedPictures]. [details]: the «File details» sheet.
  int skippedPictures = 0;

  Future<File> finish(File out, Map<String, Object?> details, {Map<String, File> files = const {}}) async {
    await _start();
    final parts = [for (final l in _xml.values) ...l];
    final media = <String>[]; // xl/media/imageN.ext ← file
    final mediaOf = <String, int>{};
    final anchors = <List<List<int>>>[];
    for (final p in parts) {
      final mine = <List<int>>[];
      for (final (row, col, key) in p.pictures) {
        final f = files[key];
        final ext = f == null ? null : _pictureExt(f);
        if (ext == null) {
          skippedPictures++;
          continue;
        }
        final i = mediaOf.putIfAbsent(key, () {
          media.add(f!.path);
          return media.length;
        });
        mine.add([row, col, i]);
      }
      anchors.add(mine);
      p.sink.write(mine.isEmpty ? '</sheetData></worksheet>' : '</sheetData><drawing r:id="rId1"/></worksheet>');
      await p.sink.flush();
      await p.sink.close();
    }
    final names = <String>[];
    for (final p in parts) {
      final title = _sheetTitle(p.sheet);
      names.add(_safeSheet(p.index == 1 ? title : '$title ${p.index}'));
    }
    // «File details»: one line per item (nested values as JSON).
    final info = File('${work.path}/xl/info.xml');
    final b = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="$_ns"><sheetViews><sheetView workbookViewId="0"${arabic ? ' rightToLeft="1"' : ''}/></sheetViews>'
        '<cols><col min="1" max="1" width="28" customWidth="1"/><col min="2" max="2" width="90" customWidth="1"/></cols>'
        '<sheetData>');
    for (final e in {...details, 'sheets': {for (final s in sheets.keys) s: rows[s]}}.entries) {
      var v = e.value is String ? e.value as String : jsonEncode(e.value);
      if (v.length > 32000) v = '${v.substring(0, 32000)}…';
      b.write('<row><c t="inlineStr" s="2"><is><t>${_xmlText(e.key)}</t></is></c>'
          '<c t="inlineStr"><is><t xml:space="preserve">${_xmlText(v)}</t></is></c></row>');
    }
    b.write('</sheetData></worksheet>');
    await info.writeAsString(b.toString());
    names.add(arabic ? 'معلومات الملف' : 'File details');
    await out.parent.create(recursive: true);
    final outPath = out.path;
    final sheetPaths = [for (final p in parts) p.file.path, info.path];
    anchors.add(const []);
    final px = _imageEmu;
    await Isolate.run(() => _buildXlsx(outPath, sheetPaths, names, anchors, media, px));
    return out;
  }

  static String? _pictureExt(File f) {
    try {
      final raf = f.openSync();
      final h = raf.readSync(4);
      raf.closeSync();
      if (h.length >= 3 && h[0] == 0xFF && h[1] == 0xD8) return 'jpeg';
      if (h.length >= 4 && h[0] == 0x89 && h[1] == 0x50 && h[2] == 0x4E && h[3] == 0x47) return 'png';
      if (h.length >= 3 && h[0] == 0x47 && h[1] == 0x49 && h[2] == 0x46) return 'gif';
    } catch (_) {}
    return null;
  }

  String _header(String key) => (arabic ? _ar : _en)[key] ?? key;
  String _sheetTitle(String key) => (arabic ? _arSheets : _enSheets)[key] ?? key;

  static String _safeSheet(String s) {
    final t = s.replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ');
    return t.length > 31 ? t.substring(0, 31) : t;
  }

  static String _text(Object? v) => v == null ? '' : '$v';

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
    'avg_cost': 'متوسط التكلفة', 'value_cutoff': 'القيمة في تاريخ القطع', 'image_file': 'الصورة',
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
    'value_cutoff': 'Value at cut-off', 'image_file': 'Picture', 'document_id': 'Document ID', 'source': 'Source',
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

  /// (row, column, picture key) of this part's pictures.
  final pictures = <(int, int, String)>[];
}

const _ns = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const _rel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

const _drawingNs = 'http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing';
const _aNs = 'http://schemas.openxmlformats.org/drawingml/2006/main';

/// Packs the workbook: the sheets, a drawing per sheet with pictures
/// (each anchored in its cell: [row, column, media number]) and the media.
Future<void> _buildXlsx(String path, List<String> sheetFiles, List<String> names, List<List<List<int>>> anchors,
    List<String> media, int px) async {
  final dir = Directory('${File(path).parent.path}/xlsx-meta-${DateTime.now().microsecondsSinceEpoch}')
    ..createSync(recursive: true);
  File meta(String name, String body) => File('${dir.path}/${name.replaceAll('/', '_')}')..writeAsStringSync(body);
  String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
  String ext(String p) {
    final h = File(p).openSync();
    final b = h.readSync(4);
    h.closeSync();
    return b[0] == 0xFF ? 'jpeg' : b[0] == 0x89 ? 'png' : 'gif';
  }

  final n = sheetFiles.length;
  final drawings = <int, int>{}; // sheet → drawing number
  for (var i = 0; i < n; i++) {
    if (anchors[i].isNotEmpty) drawings[i + 1] = drawings.length + 1;
  }
  final mediaNames = [for (var i = 0; i < media.length; i++) 'image${i + 1}.${ext(media[i])}'];
  final files = <String, File>{
    '[Content_Types].xml': meta('ct.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Default Extension="png" ContentType="image/png"/>'
        '<Default Extension="jpeg" ContentType="image/jpeg"/>'
        '<Default Extension="gif" ContentType="image/gif"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '${[for (var i = 1; i <= n; i++) '<Override PartName="/xl/worksheets/sheet$i.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'].join()}'
        '${[for (final d in drawings.values) '<Override PartName="/xl/drawings/drawing$d.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>'].join()}'
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
        '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>'
        '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>'),
    for (var i = 1; i <= n; i++) 'xl/worksheets/sheet$i.xml': File(sheetFiles[i - 1]),
  };
  for (final e in drawings.entries) {
    final sheet = e.key, d = e.value;
    files['xl/worksheets/_rels/sheet$sheet.xml.rels'] = meta('s${sheet}rels.xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="$_rel/drawing" Target="../drawings/drawing$d.xml"/></Relationships>');
    final used = <int>{for (final a in anchors[sheet - 1]) a[2]}.toList()..sort();
    files['xl/drawings/_rels/drawing$d.xml.rels'] = meta('d${d}rels.xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '${[for (final m in used) '<Relationship Id="rId$m" Type="$_rel/image" Target="../media/${mediaNames[m - 1]}"/>'].join()}'
        '</Relationships>');
    final b = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<xdr:wsDr xmlns:xdr="$_drawingNs" xmlns:a="$_aNs" xmlns:r="$_rel">');
    var id = 1;
    for (final a in anchors[sheet - 1]) {
      id++;
      b.write('<xdr:oneCellAnchor><xdr:from><xdr:col>${a[1]}</xdr:col><xdr:colOff>9525</xdr:colOff>'
          '<xdr:row>${a[0]}</xdr:row><xdr:rowOff>9525</xdr:rowOff></xdr:from><xdr:ext cx="$px" cy="$px"/>'
          '<xdr:pic><xdr:nvPicPr><xdr:cNvPr id="$id" name="Picture $id"/><xdr:cNvPicPr><a:picLocks noChangeAspect="1"/>'
          '</xdr:cNvPicPr></xdr:nvPicPr><xdr:blipFill><a:blip r:embed="rId${a[2]}"/><a:stretch><a:fillRect/></a:stretch>'
          '</xdr:blipFill><xdr:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$px" cy="$px"/></a:xfrm>'
          '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic><xdr:clientData/></xdr:oneCellAnchor>');
    }
    b.write('</xdr:wsDr>');
    files['xl/drawings/drawing$d.xml'] = meta('d$d.xml', b.toString());
  }
  final enc = ZipFileEncoder()..create(path, level: 6);
  for (final e in files.entries) {
    await enc.addFile(e.value, e.key);
  }
  // Photos are already compressed: stored as they are.
  for (var i = 0; i < media.length; i++) {
    final input = InputFileStream(media[i]);
    final f = ArchiveFile.stream('xl/media/${mediaNames[i]}', input)..compression = CompressionType.none;
    enc.addArchiveFile(f);
    await input.close();
  }
  await enc.close();
  dir.deleteSync(recursive: true);
}
