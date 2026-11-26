import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One IPP attribute value as read from a response.
typedef IppAttributes = Map<String, List<Object>>;

/// IPP/2.0 job states (RFC 8011 §5.3.7).
abstract final class IppJobState {
  static const pending = 3;
  static const held = 4;
  static const processing = 5;
  static const stopped = 6;
  static const canceled = 7;
  static const aborted = 8;
  static const completed = 9;
}

class IppException implements Exception {
  final int status;
  final String message;
  const IppException(this.status, this.message);
  @override
  String toString() => 'IppException(0x${status.toRadixString(16)}): $message';
}

/// Response of one IPP operation.
class IppResponse {
  final int status;
  final IppAttributes operation;
  final IppAttributes printer;
  final IppAttributes job;
  const IppResponse(this.status, this.operation, this.printer, this.job);

  bool get ok => status < 0x0100; // successful-ok*
}

/// Minimal, dependency-free IPP client (RFC 8010 / 8011): Get-Printer-
/// Attributes, Print-Job and Get-Job-Attributes over HTTP (:631). Works on
/// every platform from Dart, so A4 / office printers print without the
/// system dialog.
class IppClient {
  IppClient(this.host,
      {this.port = 631,
      this.path = '/ipp/print',
      this.username,
      this.password,
      this.secure = false,
      this.timeout = const Duration(seconds: 15)});

  final String host;
  final int port;
  final String path;
  final String? username;
  final String? password;
  final bool secure;
  final Duration timeout;
  int _requestId = 1;

  String get printerUri => '${secure ? 'ipps' : 'ipp'}://$host:$port$path';

  // ── Encoding ──
  static const _tagOperation = 0x01;
  static const _tagJob = 0x02;
  static const _tagEnd = 0x03;
  static const _tagPrinter = 0x04;
  static const _integer = 0x21;
  static const _boolean = 0x22;
  static const _enum = 0x23;
  static const _keyword = 0x44;
  static const _uri = 0x45;
  static const _charset = 0x47;
  static const _language = 0x48;
  static const _mime = 0x49;
  static const _name = 0x42;

  static void _attr(BytesBuilder b, int tag, String name, List<int> value) {
    final n = utf8.encode(name);
    b
      ..addByte(tag)
      ..add([n.length >> 8, n.length & 0xFF])
      ..add(n)
      ..add([value.length >> 8, value.length & 0xFF])
      ..add(value);
  }

  static void _str(BytesBuilder b, int tag, String name, String value) =>
      _attr(b, tag, name, utf8.encode(value));

  static void _int(BytesBuilder b, int tag, String name, int value) =>
      _attr(b, tag, name, [
        (value >> 24) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF
      ]);

  /// An IPP request: header, operation attributes and optional job
  /// attributes, then the document bytes.
  Uint8List encode(int operation, void Function(BytesBuilder ops) ops,
      {void Function(BytesBuilder job)? job, Uint8List? document}) {
    final b = BytesBuilder(copy: false);
    final id = _requestId++;
    b.add([0x02, 0x00, operation >> 8, operation & 0xFF,
      (id >> 24) & 0xFF, (id >> 16) & 0xFF, (id >> 8) & 0xFF, id & 0xFF]);
    b.addByte(_tagOperation);
    _str(b, _charset, 'attributes-charset', 'utf-8');
    _str(b, _language, 'attributes-natural-language', 'en');
    _str(b, _uri, 'printer-uri', printerUri);
    ops(b);
    if (job != null) {
      b.addByte(_tagJob);
      job(b);
    }
    b.addByte(_tagEnd);
    if (document != null) b.add(document);
    return b.toBytes();
  }

  // ── Decoding ──
  static IppResponse decode(Uint8List data) {
    if (data.length < 9) throw const IppException(0x0500, 'short response');
    final bd = ByteData.sublistView(data);
    final status = bd.getUint16(2);
    final groups = <int, IppAttributes>{};
    var group = 0;
    var i = 8;
    String? last;
    while (i < data.length) {
      final tag = data[i++];
      if (tag == _tagEnd) break;
      if (tag < 0x10) {
        group = tag;
        groups.putIfAbsent(group, () => {});
        continue;
      }
      if (i + 2 > data.length) break;
      final nl = bd.getUint16(i);
      i += 2;
      final name = nl == 0 ? last : utf8.decode(data.sublist(i, i + nl), allowMalformed: true);
      i += nl;
      if (i + 2 > data.length) break;
      final vl = bd.getUint16(i);
      i += 2;
      if (i + vl > data.length) break;
      final raw = data.sublist(i, i + vl);
      i += vl;
      if (name == null) continue;
      last = name;
      final Object value = switch (tag) {
        _integer || _enum => vl == 4 ? ByteData.sublistView(raw).getInt32(0) : 0,
        _boolean => vl == 1 && raw[0] != 0,
        _ when tag >= 0x40 => utf8.decode(raw, allowMalformed: true),
        _ => raw,
      };
      (groups[group] ??= {}).putIfAbsent(name, () => []).add(value);
    }
    return IppResponse(status, groups[_tagOperation] ?? {},
        groups[_tagPrinter] ?? {}, groups[_tagJob] ?? {});
  }

  // ── Transport ──
  Future<IppResponse> send(Uint8List body) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final uri = Uri(scheme: secure ? 'https' : 'http', host: host, port: port, path: path);
      final req = await client.postUrl(uri).timeout(timeout);
      req.headers.contentType = ContentType('application', 'ipp');
      req.contentLength = body.length;
      if (username != null && username!.isNotEmpty) {
        final token = base64.encode(utf8.encode('$username:${password ?? ''}'));
        req.headers.set(HttpHeaders.authorizationHeader, 'Basic $token');
      }
      req.add(body);
      final res = await req.close().timeout(timeout);
      final bytes = await res
          .fold<BytesBuilder>(BytesBuilder(copy: false), (b, d) => b..add(d))
          .timeout(timeout);
      if (res.statusCode == 401) throw const IppException(0x0403, 'unauthorized');
      if (res.statusCode != 200) {
        throw IppException(0x0500, 'http ${res.statusCode}');
      }
      return decode(bytes.toBytes());
    } finally {
      client.close(force: true);
    }
  }

  /// Formats, state and name of the printer.
  Future<IppResponse> printerAttributes() => send(encode(0x000B, (b) {
        _str(b, _keyword, 'requested-attributes', 'document-format-supported');
        _str(b, _keyword, '', 'printer-state');
        _str(b, _keyword, '', 'printer-state-reasons');
        _str(b, _keyword, '', 'printer-make-and-model');
        _str(b, _keyword, '', 'pwg-raster-document-resolution-supported');
      }));

  /// Sends a document; returns the job id.
  Future<int> printJob(Uint8List document,
      {required String format, String jobName = 'FYONA', int copies = 1}) async {
    final res = await send(encode(0x0002, (b) {
      _str(b, _name, 'requesting-user-name', username?.isNotEmpty == true ? username! : 'FYONA');
      _str(b, _name, 'job-name', jobName);
      _str(b, _mime, 'document-format', format);
    }, job: (b) {
      if (copies > 1) _int(b, _integer, 'copies', copies);
    }, document: document));
    if (!res.ok) throw IppException(res.status, 'print-job refused');
    final id = res.job['job-id']?.firstOrNull;
    return id is int ? id : 0;
  }

  /// Current state of [jobId] (see [IppJobState]) and pages done.
  Future<({int state, int impressions})> jobState(int jobId) async {
    final res = await send(encode(0x0009, (b) {
      _int(b, _integer, 'job-id', jobId);
      _str(b, _keyword, 'requested-attributes', 'job-state');
      _str(b, _keyword, '', 'job-impressions-completed');
    }));
    if (!res.ok) throw IppException(res.status, 'get-job-attributes refused');
    final s = res.job['job-state']?.firstOrNull;
    final n = res.job['job-impressions-completed']?.firstOrNull;
    return (state: s is int ? s : 0, impressions: n is int ? n : 0);
  }
}

/// PWG Raster (PWG 5102.4) encoder: 8-bit grayscale pages with the
/// standard run-length compression, for IPP Everywhere printers that do not
/// take PDF.
abstract final class PwgRaster {
  static Uint8List encode(List<({Uint8List gray, int width, int height})> pages,
      {int dpi = 300}) {
    final b = BytesBuilder(copy: false)..add(ascii.encode('RaS2'));
    for (final p in pages) {
      b.add(_header(p.width, p.height, dpi));
      _compress(b, p.gray, p.width, p.height);
    }
    return b.toBytes();
  }

  static Uint8List _header(int w, int h, int dpi) {
    final hd = ByteData(1796);
    void str(int off, String s) {
      final bytes = ascii.encode(s);
      for (var i = 0; i < bytes.length && i < 63; i++) {
        hd.setUint8(off + i, bytes[i]);
      }
    }
    str(0, 'PwgRaster');
    str(64, 'auto'); // MediaColor
    str(128, 'stationery'); // MediaType
    str(192, ''); // PrintContentOptimize
    hd.setUint32(276, dpi); // HWResolution x
    hd.setUint32(280, dpi); // y
    hd.setUint32(352, (w * 72 / dpi).round()); // PageSize width (pt)
    hd.setUint32(356, (h * 72 / dpi).round());
    hd.setUint32(372, w); // Width
    hd.setUint32(376, h); // Height
    hd.setUint32(384, 8); // BitsPerColor
    hd.setUint32(388, 8); // BitsPerPixel
    hd.setUint32(392, w); // BytesPerLine
    hd.setUint32(396, 0); // ColorOrder chunky
    hd.setUint32(400, 18); // ColorSpace sgray
    hd.setUint32(420, 1); // NumColors
    hd.setUint32(452, 1); // TotalPageCount (unknown per page = 1)
    hd.setUint32(456, 1); // CrossFeedTransform
    hd.setUint32(460, 1); // FeedTransform
    str(1732, 'iso_a4_210x297mm'); // PageSizeName
    return hd.buffer.asUint8List();
  }

  /// Line repeat + PackBits-like runs (PWG 5102.4 §4.3).
  static void _compress(BytesBuilder out, Uint8List gray, int w, int h) {
    var y = 0;
    while (y < h) {
      final line = Uint8List.sublistView(gray, y * w, (y + 1) * w);
      var repeat = 0;
      while (repeat < 255 && y + repeat + 1 < h) {
        final next = Uint8List.sublistView(gray, (y + repeat + 1) * w, (y + repeat + 2) * w);
        if (!_same(line, next)) break;
        repeat++;
      }
      out.addByte(repeat);
      var x = 0;
      while (x < w) {
        var run = 1;
        while (x + run < w && run < 128 && line[x + run] == line[x]) {
          run++;
        }
        if (run > 1) {
          out.addByte(run - 1);
          out.addByte(line[x]);
          x += run;
          continue;
        }
        var lit = 1;
        while (x + lit < w && lit < 128 &&
            (x + lit + 1 >= w || line[x + lit] != line[x + lit + 1])) {
          lit++;
        }
        if (lit == 1) {
          // A single pixel is a run of one.
          out.addByte(0);
          out.addByte(line[x]);
        } else {
          out.addByte(257 - lit);
          out.add(Uint8List.sublistView(line, x, x + lit));
        }
        x += lit;
      }
      y += repeat + 1;
    }
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// RGBA8888 → 8-bit gray (white for transparent).
  static Uint8List grayFromRgba(Uint8List rgba, int w, int h) {
    final out = Uint8List(w * h);
    for (var i = 0, p = 0; p < out.length; i += 4, p++) {
      final a = rgba[i + 3];
      final lum = (rgba[i] * 299 + rgba[i + 1] * 587 + rgba[i + 2] * 114) ~/ 1000;
      out[p] = a < 100 ? 255 : lum;
    }
    return out;
  }
}
