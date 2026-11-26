import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// How the fake ESC/POS printer behaves.
enum FakeMode {
  /// Answers DLE EOT status and the GS ( H "finished" request (Epson-like).
  full,

  /// Never answers anything (cheap printers).
  silent,

  /// Reports "paper out" on DLE EOT.
  paperOut,

  /// Closes the connection after [FakeEscPosPrinter.dropAfter] bytes.
  drop,
}

/// A real TCP server on 127.0.0.1 speaking enough ESC/POS to test the
/// engine end to end over real sockets: it records every byte, answers
/// real-time status and the process-id ("finished") request.
class FakeEscPosPrinter {
  FakeEscPosPrinter._(this._server, this.mode, this.dropAfter);

  static Future<FakeEscPosPrinter> start(
      {FakeMode mode = FakeMode.full, int port = 0, int dropAfter = 2000}) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port, shared: true);
    final p = FakeEscPosPrinter._(server, mode, dropAfter);
    server.listen(p._client);
    return p;
  }

  final ServerSocket _server;
  final FakeMode mode;
  final int dropAfter;
  final BytesBuilder received = BytesBuilder(copy: true);
  int connections = 0;

  int get port => _server.port;
  Uint8List get bytes => received.toBytes();

  void _client(Socket s) {
    connections++;
    var scan = 0;
    s.listen((data) {
      received.add(data);
      if (mode == FakeMode.drop && received.length > dropAfter) {
        s.destroy();
        return;
      }
      if (mode == FakeMode.silent) return;
      final all = received.toBytes();
      for (; scan < all.length; scan++) {
        // DLE EOT n
        if (scan + 2 < all.length && all[scan] == 0x10 && all[scan + 1] == 0x04) {
          final n = all[scan + 2];
          final paperOut = mode == FakeMode.paperOut;
          final reply = switch (n) {
            1 => 0x16,
            2 => paperOut ? 0x32 : 0x12,
            4 => paperOut ? 0x72 : 0x12,
            _ => 0x12,
          };
          s.add([reply]);
        }
        // GS ( H 06 00 30 30 d1 d2 d3 d4 → 37 22 d1 d2 d3 d4 00
        if (scan + 9 < all.length &&
            all[scan] == 0x1D && all[scan + 1] == 0x28 && all[scan + 2] == 0x48 &&
            all[scan + 5] == 0x30 && all[scan + 6] == 0x30) {
          s.add([0x37, 0x22, ...all.sublist(scan + 7, scan + 11), 0x00]);
        }
      }
    }, onError: (_) {}, cancelOnError: true);
  }

  /// How many times [pattern] occurs in what was received.
  int count(List<int> pattern) {
    final b = bytes;
    var n = 0;
    outer:
    for (var i = 0; i + pattern.length <= b.length; i++) {
      for (var j = 0; j < pattern.length; j++) {
        if (b[i + j] != pattern[j]) continue outer;
      }
      n++;
    }
    return n;
  }

  Future<void> close() => _server.close();
}

/// A real HTTP server speaking the IPP subset the engine uses.
class FakeIppPrinter {
  FakeIppPrinter._(this._server);

  static Future<FakeIppPrinter> start(
      {List<String> formats = const ['application/pdf'], String? user, String? password}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final p = FakeIppPrinter._(server)
      ..formats = formats
      ..user = user
      ..password = password;
    server.listen(p._handle);
    return p;
  }

  final HttpServer _server;
  List<String> formats = const [];
  String? user;
  String? password;
  final List<Uint8List> documents = [];
  final List<String> documentFormats = [];
  int polls = 0;

  int get port => _server.port;

  Future<void> _handle(HttpRequest req) async {
    if (user != null) {
      final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
      final want = 'Basic ${_b64('$user:$password')}';
      if (auth != want) {
        req.response.statusCode = 401;
        await req.response.close();
        return;
      }
    }
    final body = await req.fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d));
    final data = body.toBytes();
    final op = (data[2] << 8) | data[3];
    final id = data.sublist(4, 8);
    final out = BytesBuilder()
      ..add([0x02, 0x00, 0x00, 0x00, ...id])
      ..addByte(0x01);
    _attr(out, 0x47, 'attributes-charset', 'utf-8');
    _attr(out, 0x48, 'attributes-natural-language', 'en');
    switch (op) {
      case 0x000B: // Get-Printer-Attributes
        out.addByte(0x04);
        for (var i = 0; i < formats.length; i++) {
          _attr(out, 0x49, i == 0 ? 'document-format-supported' : '', formats[i]);
        }
        _int(out, 0x23, 'printer-state', 3);
      case 0x0002: // Print-Job
        final end = data.indexOf(0x03, 8);
        documents.add(Uint8List.fromList(data.sublist(_docStart(data))));
        documentFormats.add(_format(data));
        assert(end > 0);
        out.addByte(0x02);
        _int(out, 0x21, 'job-id', 7);
        _int(out, 0x23, 'job-state', 3);
      case 0x0009: // Get-Job-Attributes
        polls++;
        out.addByte(0x02);
        _int(out, 0x23, 'job-state', polls < 2 ? 5 : 9);
        _int(out, 0x21, 'job-impressions-completed', polls < 2 ? 0 : 1);
    }
    out.addByte(0x03);
    req.response.headers.contentType = ContentType('application', 'ipp');
    req.response.add(out.toBytes());
    await req.response.close();
  }

  /// Where the document starts: after the end-of-attributes tag of a
  /// well-formed request (walks the attribute list).
  static int _docStart(Uint8List d) {
    var i = 8;
    while (i < d.length) {
      final tag = d[i++];
      if (tag == 0x03) return i;
      if (tag < 0x10) continue;
      final nl = (d[i] << 8) | d[i + 1];
      i += 2 + nl;
      final vl = (d[i] << 8) | d[i + 1];
      i += 2 + vl;
    }
    return d.length;
  }

  static String _format(Uint8List d) {
    final s = String.fromCharCodes(d.sublist(0, _docStart(d)));
    final m = RegExp(r'document-format.{2}([a-z/\-]+)').firstMatch(s);
    return m?.group(1) ?? '';
  }

  static void _attr(BytesBuilder b, int tag, String name, String value) {
    b
      ..addByte(tag)
      ..add([name.length >> 8, name.length & 0xFF])
      ..add(name.codeUnits)
      ..add([value.length >> 8, value.length & 0xFF])
      ..add(value.codeUnits);
  }

  static void _int(BytesBuilder b, int tag, String name, int v) {
    b
      ..addByte(tag)
      ..add([name.length >> 8, name.length & 0xFF])
      ..add(name.codeUnits)
      ..add([0, 4, (v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);
  }

  static String _b64(String s) => base64Encode(s.codeUnits);

  Future<void> close() => _server.close(force: true);
}

String base64Encode(List<int> bytes) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final out = StringBuffer();
  for (var i = 0; i < bytes.length; i += 3) {
    final b0 = bytes[i];
    final b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
    final b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out
      ..write(chars[b0 >> 2])
      ..write(chars[((b0 & 3) << 4) | (b1 >> 4)])
      ..write(i + 1 < bytes.length ? chars[((b1 & 15) << 2) | (b2 >> 6)] : '=')
      ..write(i + 2 < bytes.length ? chars[b2 & 63] : '=');
  }
  return out.toString();
}
