import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

/// Smart import, step 1: read ANY supported file into tables of text cells.
/// Deterministic, on the device, no AI. Formats: CSV/TSV, XLSX, JSON, XML,
/// SQLite, SQL INSERT scripts, and a ZIP of those.
///
/// Everything here treats the file as hostile: bounded sizes, a ZIP entry
/// is never written to disk by its name, nested archives and compression
/// bombs are refused, XML entities are never expanded, SQLite files are
/// opened read-only and immutable.
const importMaxFileBytes = 512 * 1024 * 1024;
const importMaxEntryBytes = 256 * 1024 * 1024;
const importMaxZipEntries = 2000;
const importMaxZipTotal = 1024 * 1024 * 1024;
const importMaxRatio = 200;
const importMaxColumns = 500;
const importMaxCell = 32 * 1024;
const importMaxRows = 2000000;

class ImportRejected implements Exception {
  const ImportRejected(this.code, [this.detail]);

  /// too_large | bomb | nested | empty | format | encoding | unsupported
  final String code;
  final String? detail;
  @override
  String toString() => 'ImportRejected($code${detail == null ? '' : ': $detail'})';
}

/// One table found in the file.
class ImportTable {
  ImportTable(this.name, this.columns, this._rows);
  final String name;
  final List<String> columns;
  final Stream<List<String?>> Function() _rows;

  /// Rows (one list per row, aligned with [columns]); read again each call.
  Stream<List<String?>> rows() => _rows();

  Future<List<List<String?>>> sample([int n = 30]) async {
    final out = <List<String?>>[];
    await for (final r in rows()) {
      out.add(r);
      if (out.length >= n) break;
    }
    return out;
  }
}

String? _cell(Object? v) {
  if (v == null) return null;
  var s = v is double && v == v.truncateToDouble() && v.abs() < 1e15 ? v.toInt().toString() : '$v';
  if (s.length > importMaxCell) s = s.substring(0, importMaxCell);
  return s;
}

List<String> _header(List<Object?> raw) {
  if (raw.length > importMaxColumns) throw const ImportRejected('format', 'too many columns');
  final seen = <String, int>{};
  return [
    for (var i = 0; i < raw.length; i++)
      () {
        var h = (_cell(raw[i]) ?? '').trim();
        if (h.isEmpty) h = 'عمود ${i + 1}';
        final n = seen[h] = (seen[h] ?? 0) + 1;
        return n == 1 ? h : '$h ($n)';
      }(),
  ];
}

List<String?> _align(List<Object?> r, int width) =>
    [for (var i = 0; i < width; i++) i < r.length ? _cell(r[i]) : null];

/// Reads every table of [file] (the name decides the format; content is
/// checked). A ZIP yields the tables of each supported file inside it.
Future<List<ImportTable>> readImportFile(File file) async {
  final size = await file.length();
  if (size == 0) throw const ImportRejected('empty');
  if (size > importMaxFileBytes) throw const ImportRejected('too_large');
  final name = file.path.split(Platform.pathSeparator).last.split('/').last;
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  final head = await file.openRead(0, 16).fold<List<int>>([], (a, b) => a..addAll(b));
  if (_isZip(head) && ext != 'xlsx') return _zip(file);
  return _bytesTables(name, ext, () => file.openRead(), size, file: file);
}

bool _isZip(List<int> h) => h.length >= 4 && h[0] == 0x50 && h[1] == 0x4B && h[2] == 0x03 && h[3] == 0x04;
bool _isSqlite(List<int> h) => h.length >= 16 && ascii.decode(h.sublist(0, 15), allowInvalid: true) == 'SQLite format 3';

Future<List<ImportTable>> _bytesTables(String name, String ext, Stream<List<int>> Function() open, int size,
    {File? file, Uint8List? bytes}) async {
  final head = bytes != null
      ? bytes.sublist(0, bytes.length < 16 ? bytes.length : 16)
      : await open().take(1).fold<List<int>>([], (a, b) => a..addAll(b.take(16)));
  if (_isSqlite(head)) {
    if (file == null) throw const ImportRejected('nested', 'SQLite inside an archive');
    return _sqlite(file);
  }
  switch (ext) {
    case 'csv':
    case 'tsv':
    case 'txt':
      return [await _csv(name, open)];
    case 'xlsx':
      return _xlsx(bytes ?? await File(file!.path).readAsBytes());
    case 'json':
      return _json(name, await _text(open, size));
    case 'xml':
      return _xml(name, await _text(open, size));
    case 'sql':
      return _sql(await _text(open, size));
    case 'db':
    case 'sqlite':
    case 'sqlite3':
      throw const ImportRejected('format', 'not a SQLite file');
    case 'zip':
      throw const ImportRejected('nested');
    case 'xls':
      throw const ImportRejected('unsupported', 'xls');
  }
  throw ImportRejected('unsupported', ext);
}

/// UTF-8 (with or without BOM) or UTF-16 with BOM. Anything else: refused
/// with a clear message (never guessed into wrong letters).
String _decode(List<int> b) {
  if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
    return String.fromCharCodes(Uint8List.fromList(b.sublist(2)).buffer.asUint16List(0, (b.length - 2) ~/ 2));
  }
  if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
    final u = <int>[for (var i = 2; i + 1 < b.length; i += 2) (b[i] << 8) | b[i + 1]];
    return String.fromCharCodes(u);
  }
  try {
    final s = utf8.decode(b);
    return s.startsWith('﻿') ? s.substring(1) : s;
  } on FormatException {
    throw const ImportRejected('encoding');
  }
}

Future<String> _text(Stream<List<int>> Function() open, int size) async {
  if (size > 64 * 1024 * 1024) throw const ImportRejected('too_large', 'text file over 64 MB: use CSV');
  final b = BytesBuilder(copy: false);
  await for (final c in open()) {
    b.add(c);
  }
  return _decode(b.takeBytes());
}

// ── CSV ──────────────────────────────────────────────────────────────────

Future<ImportTable> _csv(String name, Stream<List<int>> Function() open) async {
  final first = await open().take(1).fold<List<int>>([], (a, b) => a..addAll(b));
  // Sniff the delimiter on whole lines only (a chunk can end inside a letter).
  var cut = first.length > 65536 ? 65536 : first.length;
  final nl = first.sublist(0, cut).lastIndexOf(0x0A);
  if (nl > 0) cut = nl;
  final probe = _decode(first.sublist(0, cut));
  final line = probe.split(RegExp(r'\r?\n')).firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
  var delim = ',';
  var best = -1;
  for (final d in [',', ';', '\t', '|']) {
    final n = d.allMatches(line).length;
    if (n > best) {
      best = n;
      delim = d;
    }
  }
  Stream<List<Object?>> all() {
    var firstChunk = true;
    final utf16 = first.length >= 2 && ((first[0] == 0xFF && first[1] == 0xFE) || (first[0] == 0xFE && first[1] == 0xFF));
    final Stream<String> text = utf16
        ? Stream.fromFuture(open().fold<List<int>>([], (a, b) => a..addAll(b)).then(_decode))
        : open().transform(const Utf8Decoder()).map((s) {
            if (firstChunk) {
              firstChunk = false;
              if (s.startsWith('﻿')) return s.substring(1);
            }
            return s;
          });
    return text
        .handleError((Object e) => throw const ImportRejected('encoding'), test: (e) => e is FormatException)
        .transform(CsvDecoder(fieldDelimiter: delim, dynamicTyping: false));
  }

  List<Object?>? header;
  await for (final r in all()) {
    if (r.every((v) => '${v ?? ''}'.trim().isEmpty)) continue;
    header = r;
    break;
  }
  if (header == null) throw const ImportRejected('empty');
  final cols = _header(header);
  Stream<List<String?>> rows() async* {
    var seenHeader = false;
    var n = 0;
    await for (final r in all()) {
      if (r.every((v) => '${v ?? ''}'.trim().isEmpty)) continue;
      if (!seenHeader) {
        seenHeader = true;
        continue;
      }
      if (++n > importMaxRows) throw const ImportRejected('too_large', 'rows');
      yield _align(r, cols.length);
    }
  }

  return ImportTable(name, cols, rows);
}

// ── XLSX ─────────────────────────────────────────────────────────────────

/// A ZIP entry from the central directory (sizes as declared).
class _ZipEntry {
  _ZipEntry(this.name, this.method, this.packed, this.size, this.offset, this.flags);
  final String name;
  final int method, packed, size, offset, flags;
  bool get isFile => !name.endsWith('/');
}

/// Minimal ZIP reader with hard limits (no zip64, no encryption): every
/// entry is inflated with a cap on its output, so a lying header or a
/// compression bomb stops at the limit instead of filling memory.
class _Zip extends Iterable<_ZipEntry> {
  _Zip(this.bytes, this.entries);
  final Uint8List bytes;
  final List<_ZipEntry> entries;
  @override
  Iterator<_ZipEntry> get iterator => entries.iterator;

  static _Zip open(Uint8List b) {
    final d = ByteData.sublistView(b);
    var eocd = -1;
    for (var i = b.length - 22; i >= 0 && i >= b.length - 22 - 65535; i--) {
      if (d.getUint32(i, Endian.little) == 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const ImportRejected('format', 'zip');
    final count = d.getUint16(eocd + 10, Endian.little);
    final cdSize = d.getUint32(eocd + 12, Endian.little);
    var p = d.getUint32(eocd + 16, Endian.little);
    if (count == 0xFFFF || p == 0xFFFFFFFF) throw const ImportRejected('unsupported', 'zip64');
    if (count > importMaxZipEntries) throw const ImportRejected('bomb', 'entries');
    if (p + cdSize > b.length) throw const ImportRejected('format', 'zip');
    final out = <_ZipEntry>[];
    var total = 0;
    for (var k = 0; k < count; k++) {
      if (p + 46 > b.length || d.getUint32(p, Endian.little) != 0x02014b50) throw const ImportRejected('format', 'zip');
      final flags = d.getUint16(p + 8, Endian.little);
      final method = d.getUint16(p + 10, Endian.little);
      final packed = d.getUint32(p + 20, Endian.little);
      final size = d.getUint32(p + 24, Endian.little);
      final nl = d.getUint16(p + 28, Endian.little), xl = d.getUint16(p + 30, Endian.little), cl = d.getUint16(p + 32, Endian.little);
      final off = d.getUint32(p + 42, Endian.little);
      if (p + 46 + nl > b.length) throw const ImportRejected('format', 'zip');
      final name = utf8.decode(b.sublist(p + 46, p + 46 + nl), allowMalformed: true);
      p += 46 + nl + xl + cl;
      total += size;
      if (size > importMaxEntryBytes || total > importMaxZipTotal) throw const ImportRejected('bomb');
      if (packed > 0 && size > 1024 * 1024 && size / packed > importMaxRatio) throw const ImportRejected('bomb');
      out.add(_ZipEntry(name, method, packed, size, off, flags));
    }
    return _Zip(b, out);
  }

  _ZipEntry? find(String name) => entries.where((e) => e.name == name).firstOrNull;

  Uint8List read(_ZipEntry e) {
    if (e.flags & 1 != 0) throw const ImportRejected('unsupported', 'encrypted zip');
    final d = ByteData.sublistView(bytes);
    final o = e.offset;
    if (o + 30 > bytes.length || d.getUint32(o, Endian.little) != 0x04034b50) throw const ImportRejected('format', 'zip');
    final start = o + 30 + d.getUint16(o + 26, Endian.little) + d.getUint16(o + 28, Endian.little);
    if (start + e.packed > bytes.length) throw const ImportRejected('format', 'zip');
    final raw = Uint8List.sublistView(bytes, start, start + e.packed);
    if (e.method == 0) {
      if (raw.length != e.size) throw const ImportRejected('format', 'zip');
      return raw;
    }
    if (e.method != 8) throw ImportRejected('unsupported', 'zip method ${e.method}');
    // Inflate in slices; stop past the declared size (never trust it).
    final cap = e.size;
    final out = BytesBuilder(copy: false);
    final sink = ByteConversionSink.withCallback((_) {});
    final inflate = ZLibDecoder(raw: true).startChunkedConversion(_CapSink(out, cap, sink));
    for (var i = 0; i < raw.length; i += 16384) {
      inflate.add(Uint8List.sublistView(raw, i, i + 16384 > raw.length ? raw.length : i + 16384));
    }
    inflate.close();
    final data = out.takeBytes();
    if (data.length != e.size) throw const ImportRejected('format', 'zip size');
    return data;
  }
}

class _CapSink implements Sink<List<int>> {
  _CapSink(this.out, this.cap, this.done);
  final BytesBuilder out;
  final int cap;
  final ByteConversionSink done;
  @override
  void add(List<int> data) {
    if (out.length + data.length > cap) throw const ImportRejected('bomb');
    out.add(data);
  }

  @override
  void close() => done.close();
}

int _colIndex(String ref) {
  var n = 0;
  for (final c in ref.codeUnits) {
    if (c >= 65 && c <= 90) {
      n = n * 26 + (c - 64);
    } else {
      break;
    }
  }
  return n - 1;
}

List<ImportTable> _xlsx(Uint8List bytes) {
  final zip = _Zip.open(bytes);
  _ZipEntry? find(String n) => zip.find(n);
  Uint8List entryBytes(_ZipEntry e) => zip.read(e);
  final shared = <String>[];
  final ss = find('xl/sharedStrings.xml');
  if (ss != null) {
    final buf = StringBuffer();
    var inSi = false, inT = false;
    for (final e in parseEvents(utf8.decode(entryBytes(ss), allowMalformed: true))) {
      if (e is XmlStartElementEvent) {
        if (e.localName == 'si') {
          inSi = true;
          buf.clear();
        } else if (e.localName == 't' && inSi) {
          inT = !e.isSelfClosing;
        } else if (e.localName == 'rPh') {
          inT = false;
        }
      } else if (e is XmlEndElementEvent) {
        if (e.localName == 't') inT = false;
        if (e.localName == 'si') {
          inSi = false;
          shared.add(buf.toString());
        }
      } else if (e is XmlTextEvent && inT) {
        buf.write(e.value);
      } else if (e is XmlCDATAEvent && inT) {
        buf.write(e.value);
      }
    }
  }
  // Sheet names from the workbook, in order.
  final names = <String, String>{};
  final wb = find('xl/workbook.xml');
  final rels = find('xl/_rels/workbook.xml.rels');
  final target = <String, String>{};
  if (rels != null) {
    for (final e in parseEvents(utf8.decode(entryBytes(rels), allowMalformed: true)).whereType<XmlStartElementEvent>()) {
      if (e.localName != 'Relationship') continue;
      String? a(String n) => e.attributes.where((x) => x.localName == n).map((x) => x.value).firstOrNull;
      final id = a('Id'), t = a('Target');
      if (id != null && t != null) target[id] = t.startsWith('/') ? t.substring(1) : 'xl/$t';
    }
  }
  if (wb != null) {
    for (final e in parseEvents(utf8.decode(entryBytes(wb), allowMalformed: true)).whereType<XmlStartElementEvent>()) {
      if (e.localName != 'sheet') continue;
      String? a(String n) => e.attributes.where((x) => x.localName == n).map((x) => x.value).firstOrNull;
      final rid = e.attributes.where((x) => x.localName == 'id').map((x) => x.value).firstOrNull;
      final path = rid == null ? null : target[rid];
      if (path != null && !path.contains('..')) names[path] = a('name') ?? path;
    }
  }
  if (names.isEmpty) {
    for (final f in zip) {
      if (RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(f.name)) names[f.name] = f.name.split('/').last;
    }
  }
  final out = <ImportTable>[];
  for (final e in names.entries) {
    final f = find(e.key);
    if (f == null) continue;
    final xml = utf8.decode(entryBytes(f), allowMalformed: true);
    Iterable<List<String?>> parsed() sync* {
      List<String?>? row;
      String? type;
      var col = -1;
      final text = StringBuffer();
      var inV = false;
      for (final ev in parseEvents(xml)) {
        if (ev is XmlStartElementEvent) {
          switch (ev.localName) {
            case 'row':
              row = <String?>[];
              if (ev.isSelfClosing) {
                yield row;
                row = null;
              }
            case 'c':
              type = ev.attributes.where((x) => x.localName == 't').map((x) => x.value).firstOrNull;
              final r = ev.attributes.where((x) => x.localName == 'r').map((x) => x.value).firstOrNull;
              col = r == null ? (row?.length ?? 0) : _colIndex(r);
              text.clear();
              if (col < 0 || col >= importMaxColumns) col = -1;
            case 'v':
            case 't':
              inV = !ev.isSelfClosing;
          }
        } else if (ev is XmlEndElementEvent) {
          switch (ev.localName) {
            case 'v':
            case 't':
              inV = false;
            case 'c':
              if (row != null && col >= 0) {
                while (row.length <= col) {
                  row.add(null);
                }
                var v = text.toString();
                if (type == 's') {
                  final i = int.tryParse(v);
                  v = i != null && i >= 0 && i < shared.length ? shared[i] : '';
                } else if (type == 'b') {
                  v = v == '1' ? 'TRUE' : 'FALSE';
                }
                row[col] = _cell(v);
              }
            case 'row':
              if (row != null) yield row;
              row = null;
          }
        } else if ((ev is XmlTextEvent || ev is XmlCDATAEvent) && inV) {
          text.write(ev is XmlTextEvent ? ev.value : (ev as XmlCDATAEvent).value);
        }
      }
    }

    List<String?>? head;
    for (final r in parsed()) {
      if (r.every((v) => (v ?? '').trim().isEmpty)) continue;
      head = r;
      break;
    }
    if (head == null) continue;
    final cols = _header(head);
    out.add(ImportTable(e.value, cols, () async* {
      var seen = false;
      var n = 0;
      for (final r in parsed()) {
        if (r.every((v) => (v ?? '').trim().isEmpty)) continue;
        if (!seen) {
          seen = true;
          continue;
        }
        if (++n > importMaxRows) throw const ImportRejected('too_large', 'rows');
        yield _align(r, cols.length);
      }
    }));
  }
  if (out.isEmpty) throw const ImportRejected('empty');
  return out;
}

// ── JSON / XML ───────────────────────────────────────────────────────────

ImportTable _fromMaps(String name, List<Map> maps) {
  final keys = <String>[];
  final seen = <String>{};
  for (final m in maps) {
    for (final k in m.keys) {
      if (seen.add('$k')) keys.add('$k');
      if (keys.length > importMaxColumns) throw const ImportRejected('format', 'too many columns');
    }
  }
  final cols = _header(keys);
  return ImportTable(name, cols, () async* {
    for (final m in maps) {
      yield [
        for (final k in keys)
          m[k] is Map || m[k] is List ? _cell(jsonEncode(m[k])) : _cell(m[k]),
      ];
    }
  });
}

List<ImportTable> _json(String name, String text) {
  final Object? data;
  try {
    data = jsonDecode(text);
  } on FormatException {
    throw const ImportRejected('format', 'json');
  }
  final out = <ImportTable>[];
  void take(String n, Object? v) {
    if (v is List && v.isNotEmpty && v.every((e) => e is Map)) {
      out.add(_fromMaps(n, v.cast<Map>()));
    } else if (v is List && v.isNotEmpty && v.every((e) => e is List)) {
      final rows = v.cast<List>();
      final cols = _header(rows.first);
      out.add(ImportTable(n, cols, () async* {
        for (final r in rows.skip(1)) {
          yield _align(r, cols.length);
        }
      }));
    }
  }

  if (data is List) {
    take(name, data);
  } else if (data is Map) {
    for (final e in data.entries) {
      take('${e.key}', e.value);
    }
  }
  if (out.isEmpty) throw const ImportRejected('empty');
  return out;
}

List<ImportTable> _xml(String name, String text) {
  final XmlDocument doc;
  try {
    // Only the five predefined entities and character references are known:
    // a DTD's own entities are never expanded (no "billion laughs").
    if (text.contains('<!ENTITY')) throw const ImportRejected('format', 'xml entities');
    doc = XmlDocument.parse(text);
  } on ImportRejected {
    rethrow;
  } catch (_) {
    throw const ImportRejected('format', 'xml');
  }
  // The element whose children repeat the most is the table.
  XmlElement? best;
  var count = 0;
  for (final el in doc.descendantElements) {
    final kids = el.childElements.toList();
    if (kids.length < 2) continue;
    final tag = kids.first.name.local;
    final same = kids.where((k) => k.name.local == tag).length;
    if (same > count) {
      count = same;
      best = el;
    }
  }
  if (best == null) throw const ImportRejected('empty');
  final tag = best.childElements.first.name.local;
  final maps = <Map<String, String>>[
    for (final r in best.childElements.where((k) => k.name.local == tag))
      {
        for (final a in r.attributes) a.name.local: a.value,
        for (final c in r.childElements) c.name.local: c.innerText.trim(),
      },
  ];
  return [_fromMaps(tag, maps)];
}

// ── SQL INSERT scripts ───────────────────────────────────────────────────

List<ImportTable> _sql(String text) {
  final tables = <String, (List<String>, List<List<Object?>>)>{};
  final re = RegExp(r'INSERT\s+INTO\s+[`"\[]?([A-Za-z0-9_؀-ۿ.]+)[`"\]]?\s*(\(([^)]*)\))?\s*VALUES\s*', caseSensitive: false);
  var pos = 0;
  while (true) {
    final m = re.firstMatch(text.substring(pos));
    if (m == null) break;
    final tname = m.group(1)!.split('.').last;
    final cols = m.group(3)?.split(',').map((c) => c.trim().replaceAll(RegExp(r'[`"\[\]]'), '')).toList();
    var i = pos + m.end;
    final rows = <List<Object?>>[];
    // Tuples: ( value, value, … ) [, (…)] ;
    while (i < text.length) {
      while (i < text.length && ' \t\r\n,'.contains(text[i])) {
        i++;
      }
      if (i >= text.length || text[i] != '(') break;
      i++;
      final row = <Object?>[];
      final cur = StringBuffer();
      var quoted = false, wasQuoted = false;
      while (i < text.length) {
        final ch = text[i];
        if (quoted) {
          if (ch == "'" && i + 1 < text.length && text[i + 1] == "'") {
            cur.write("'");
            i += 2;
            continue;
          }
          if (ch == '\\' && i + 1 < text.length) {
            cur.write(text[i + 1]);
            i += 2;
            continue;
          }
          if (ch == "'") {
            quoted = false;
          } else {
            cur.write(ch);
          }
          i++;
          continue;
        }
        if (ch == "'") {
          quoted = true;
          wasQuoted = true;
          i++;
          continue;
        }
        if (ch == ',' || ch == ')') {
          final v = cur.toString().trim();
          row.add(!wasQuoted && v.toUpperCase() == 'NULL' ? null : v);
          cur.clear();
          wasQuoted = false;
          i++;
          if (ch == ')') break;
          continue;
        }
        cur.write(ch);
        i++;
      }
      rows.add(row);
      if (row.length > importMaxColumns) throw const ImportRejected('format', 'too many columns');
    }
    final entry = tables.putIfAbsent(tname, () => (cols ?? [for (var k = 0; k < (rows.firstOrNull?.length ?? 0); k++) 'عمود ${k + 1}'], []));
    entry.$2.addAll(rows);
    pos = i;
  }
  if (tables.isEmpty) throw const ImportRejected('empty');
  return [
    for (final e in tables.entries)
      () {
        final cols = _header(e.value.$1);
        return ImportTable(e.key, cols, () async* {
          for (final r in e.value.$2) {
            yield _align(r, cols.length);
          }
        });
      }(),
  ];
}

// ── SQLite (read-only, immutable) ────────────────────────────────────────

Future<List<ImportTable>> _sqlite(File file) async {
  final uri = Uri.file(file.absolute.path).replace(query: 'mode=ro&immutable=1').toString();
  Future<Database> open() => databaseFactoryFfi.openDatabase(uri,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
  final Database db;
  try {
    db = await open();
  } catch (_) {
    throw const ImportRejected('format', 'sqlite');
  }
  final out = <ImportTable>[];
  try {
    await db.execute('PRAGMA trusted_schema = OFF');
    final names = [
      for (final r in await db.rawQuery("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"))
        '${r['name']}',
    ];
    for (final t in names) {
      final info = await db.rawQuery('PRAGMA table_info("${t.replaceAll('"', '""')}")');
      final cols = [for (final c in info) '${c['name']}'];
      if (cols.isEmpty) continue;
      final header = _header(cols);
      out.add(ImportTable(t, header, () async* {
        final d = await open();
        try {
          final q = cols.map((c) => '"${c.replaceAll('"', '""')}"').join(', ');
          final cur = await d.rawQueryCursor('SELECT $q FROM "${t.replaceAll('"', '""')}"', [], bufferSize: 2000);
          try {
            while (await cur.moveNext()) {
              final r = cur.current;
              yield [for (final c in cols) r[c] is List<int> ? null : _cell(r[c])];
            }
          } finally {
            await cur.close();
          }
        } finally {
          await d.close();
        }
      }));
    }
  } finally {
    await db.close();
  }
  if (out.isEmpty) throw const ImportRejected('empty');
  return out;
}

// ── ZIP of files ─────────────────────────────────────────────────────────

Future<List<ImportTable>> _zip(File file) async {
  final zip = _Zip.open(await file.readAsBytes());
  final out = <ImportTable>[];
  for (final f in zip) {
    if (!f.isFile) continue;
    final n = f.name.replaceAll('\\', '/');
    final base = n.split('/').last;
    if (base.startsWith('.') || n.startsWith('__MACOSX/')) continue;
    final ext = base.contains('.') ? base.split('.').last.toLowerCase() : '';
    if (ext == 'zip') throw const ImportRejected('nested');
    if (!const {'csv', 'tsv', 'txt', 'xlsx', 'json', 'xml', 'sql'}.contains(ext)) continue;
    final data = zip.read(f);
    if (_isZip(data) && ext != 'xlsx') throw const ImportRejected('nested');
    for (final t in await _bytesTables(base, ext, () => Stream.value(data), data.length, bytes: data)) {
      out.add(ImportTable('$base · ${t.name}', t.columns, t.rows));
    }
  }
  if (out.isEmpty) throw const ImportRejected('empty');
  return out;
}
