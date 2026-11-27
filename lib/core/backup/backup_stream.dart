import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';

import 'backup_crypto.dart';

/// Streaming form of [BackupContainer] (same bytes on disk): a part of any
/// size is written and read one 1 MiB frame at a time, so a 1 GB backup
/// never sits in memory — neither when it is made nor when it is restored.
///
/// Limits that protect the device from damaged or hostile files:
/// * a frame is at most [BackupContainer.frameSize] + tag; anything else is
///   rejected before a byte is allocated for it;
/// * one record line is at most [maxLine] bytes;
/// * decompressed data per part is bounded ([maxRatio] × its file size), so
///   a "zip bomb" stops early instead of filling the disk;
/// * decompression is fed in small slices, so memory stays bounded even for
///   a maximal-ratio input.
abstract final class BackupStream {
  static const maxLine = 64 * 1024 * 1024;
  static const maxRatio = 1100; // zlib's own ceiling is ~1032:1
  static const partBytes = 32 * 1024 * 1024; // one cloud object (server cap: 64 MB)
  static const _slice = 16 * 1024;
  static final _aead = Chacha20.poly1305Aead();
  static final _rng = Random.secure();

  static Uint8List _random(int n) => Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256)));

  static Uint8List _aad(List<int> fileId, int index, bool last) {
    final b = BytesBuilder()
      ..add(utf8.encode('fybk2'))
      ..add(fileId)
      ..add([(index >> 24) & 0xFF, (index >> 16) & 0xFF, (index >> 8) & 0xFF, index & 0xFF])
      ..addByte(last ? 1 : 0);
    return b.toBytes();
  }

  /// Authenticated plaintext frames of a container file, in order.
  /// Throws [BackupTampered] on any inconsistency (nothing after it is used).
  static Stream<Uint8List> frames(File file, SecretKey key) async* {
    final raf = await file.open();
    try {
      final total = await raf.length();
      if (total < 21) throw const BackupTampered('short');
      final head = await raf.read(21);
      for (var i = 0; i < 4; i++) {
        if (head[i] != BackupContainer.magic[i]) throw const BackupTampered('magic');
      }
      if (head[4] != BackupContainer.version) throw const BackupTampered('version');
      final fileId = Uint8List.sublistView(head, 5, 21);
      var pos = 21, index = 0;
      var sawLast = false;
      while (pos < total) {
        if (pos + 4 + 12 + 16 > total) throw const BackupTampered('truncated frame');
        final h = await raf.read(16);
        final len = (h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3];
        if (len < 16 || len > BackupContainer.frameSize + 16) throw const BackupTampered('frame length');
        pos += 16;
        if (pos + len > total) throw const BackupTampered('frame length');
        final body = await raf.read(len);
        if (body.length != len) throw const BackupTampered('truncated frame');
        pos += len;
        final last = pos == total;
        final List<int> plain;
        try {
          plain = await _aead.decrypt(
              SecretBox(Uint8List.sublistView(body, 0, len - 16),
                  nonce: Uint8List.sublistView(h, 4, 16), mac: Mac(Uint8List.sublistView(body, len - 16))),
              secretKey: key,
              aad: _aad(fileId, index, last));
        } on SecretBoxAuthenticationError {
          throw BackupTampered(last ? 'last frame (truncated or altered)' : 'frame $index altered');
        }
        sawLast = last;
        index++;
        yield plain is Uint8List ? plain : Uint8List.fromList(plain);
      }
      if (!sawLast) throw const BackupTampered('no final frame');
    } finally {
      await raf.close();
    }
  }

  /// Decrypted bytes of one or more chunk files (one logical part), with
  /// their SHA-256 checked at the end when [sha] is given.
  static Stream<Uint8List> bytes(List<File> files, SecretKey key, {String? sha}) async* {
    final out = _DigestSink();
    final digest = hash.sha256.startChunkedConversion(out);
    for (final f in files) {
      await for (final b in frames(f, key)) {
        digest.add(b);
        yield b;
      }
    }
    digest.close();
    if (sha != null && out.value.toString() != sha) throw const BackupTampered('content hash');
  }

  /// JSONL records of a gzip+container part split over [files].
  static Stream<String> lines(List<File> files, SecretKey key) async* {
    for (final f in files) {
      final budget = (await f.length()) * maxRatio + maxLine;
      final splitter = _Lines(budget);
      final inflate = ZLibDecoder(gzip: true).startChunkedConversion(splitter);
      await for (final frame in frames(f, key)) {
        for (var i = 0; i < frame.length; i += _slice) {
          inflate.add(Uint8List.sublistView(frame, i, min(i + _slice, frame.length)));
          while (splitter.ready.isNotEmpty) {
            yield splitter.ready.removeFirst();
          }
        }
      }
      inflate.close();
      splitter.finish();
      while (splitter.ready.isNotEmpty) {
        yield splitter.ready.removeFirst();
      }
    }
  }
}

class _DigestSink implements Sink<hash.Digest> {
  late hash.Digest value;
  @override
  void add(hash.Digest data) => value = data;
  @override
  void close() {}
}

/// Byte-level line splitter with hard limits (no unbounded buffers).
class _Lines implements Sink<List<int>> {
  _Lines(this._budget);
  final int _budget;
  final ready = _Queue<String>();
  final _buf = BytesBuilder(copy: true);
  int _seen = 0;

  @override
  void add(List<int> data) {
    _seen += data.length;
    if (_seen > _budget) throw const BackupTampered('decompressed size');
    var start = 0;
    for (var i = 0; i < data.length; i++) {
      if (data[i] != 0x0A) continue;
      _buf.add(data is Uint8List ? Uint8List.sublistView(data, start, i) : data.sublist(start, i));
      _emit();
      start = i + 1;
    }
    if (start < data.length) {
      _buf.add(data is Uint8List ? Uint8List.sublistView(data, start) : data.sublist(start));
      if (_buf.length > BackupStream.maxLine) throw const BackupTampered('record too long');
    }
  }

  void _emit() {
    if (_buf.length > BackupStream.maxLine) throw const BackupTampered('record too long');
    final b = _buf.takeBytes();
    if (b.isEmpty) return;
    try {
      ready.add(utf8.decode(b));
    } on FormatException {
      throw const BackupTampered('text encoding');
    }
  }

  @override
  void close() {}

  void finish() {
    if (_buf.isNotEmpty) _emit();
  }
}

class _Queue<T> {
  final _l = <T>[];
  var _h = 0;
  bool get isNotEmpty => _h < _l.length;
  void add(T v) => _l.add(v);
  T removeFirst() {
    final v = _l[_h++];
    if (_h == _l.length) {
      _l.clear();
      _h = 0;
    }
    return v;
  }
}

/// Writes one container file incrementally (`.tmp`, renamed on [close]).
class BackupFileWriter {
  BackupFileWriter(this.file, this._key) : _fileId = BackupStream._random(16);
  final File file;
  final SecretKey _key;
  final Uint8List _fileId;
  final _pending = BytesBuilder(copy: true);
  RandomAccessFile? _raf;
  int _index = 0;
  int written = 0;

  File get _tmp => File('${file.path}.tmp');

  Future<RandomAccessFile> _open() async {
    if (_raf != null) return _raf!;
    await file.parent.create(recursive: true);
    final r = await _tmp.open(mode: FileMode.write);
    await r.writeFrom([...BackupContainer.magic, BackupContainer.version, ..._fileId]);
    written = 21;
    return _raf = r;
  }

  /// Plain bytes; frames are sealed as soon as a full one is known not to
  /// be the last (the final frame is marked in its AAD).
  Future<void> add(List<int> data) async {
    _pending.add(data);
    while (_pending.length > BackupContainer.frameSize) {
      final all = _pending.takeBytes();
      await _frame(Uint8List.sublistView(all, 0, BackupContainer.frameSize), last: false);
      _pending.add(Uint8List.sublistView(all, BackupContainer.frameSize));
    }
  }

  int get pending => _pending.length;

  Future<void> _frame(Uint8List plain, {required bool last}) async {
    final raf = await _open();
    final nonce = BackupStream._random(12);
    final box = await BackupStream._aead
        .encrypt(plain, secretKey: _key, nonce: nonce, aad: BackupStream._aad(_fileId, _index, last));
    final len = box.cipherText.length + box.mac.bytes.length;
    await raf.writeFrom([(len >> 24) & 0xFF, (len >> 16) & 0xFF, (len >> 8) & 0xFF, len & 0xFF, ...nonce]);
    await raf.writeFrom(box.cipherText);
    await raf.writeFrom(box.mac.bytes);
    written += 16 + len;
    _index++;
  }

  Future<File> close() async {
    await _frame(_pending.takeBytes(), last: true);
    final raf = _raf!;
    await raf.flush();
    await raf.close();
    _raf = null;
    return _tmp.rename(file.path);
  }

  Future<void> abort() async {
    await _raf?.close();
    _raf = null;
    if (await _tmp.exists()) await _tmp.delete();
  }
}

/// Writes JSONL records as gzip inside containers, starting a new chunk
/// file after [BackupStream.partBytes]: `<base>.fybk`, `<base>.1.fybk`, …
/// (each chunk is complete on its own, so a cloud upload can resume per
/// chunk and no object exceeds the server limit).
class BackupLineWriter {
  BackupLineWriter(this.dir, this.base, this._key, {this.partBytes = BackupStream.partBytes, this.onLine});
  final Directory dir;
  final String base;
  final SecretKey _key;
  final int partBytes;
  final void Function(String line)? onLine;
  final names = <String>[];
  int lineCount = 0;
  int bytes = 0;

  BackupFileWriter? _file;
  ByteConversionSink? _gz;
  final _out = _Collect();

  String _name(int i) => i == 0 ? '$base.fybk' : '$base.$i.fybk';

  void _start() {
    final name = _name(names.length);
    names.add(name);
    _file = BackupFileWriter(File('${dir.path}/$name'), _key);
    _gz = ZLibEncoder(gzip: true, level: 6).startChunkedConversion(_out);
  }

  Future<void> add(String line) async {
    if (_gz == null) _start();
    onLine?.call(line);
    _gz!.add(utf8.encode('$line\n'));
    lineCount++;
    if (_out.length >= 256 * 1024) await _file!.add(_out.take());
    if (_file!.written + _file!.pending >= partBytes) await _rotate();
  }

  Future<void> _rotate() async {
    _gz!.close();
    await _file!.add(_out.take());
    bytes += (await _file!.close()).lengthSync();
    _file = null;
    _gz = null;
  }

  /// Chunk names written (at least one, even when empty).
  Future<List<String>> close() async {
    if (_gz == null) _start();
    await _rotate();
    return names;
  }

  Future<void> abort() async {
    await _file?.abort();
    for (final n in names) {
      final f = File('${dir.path}/$n');
      if (await f.exists()) await f.delete();
    }
  }
}

class _Collect implements Sink<List<int>> {
  final _b = BytesBuilder(copy: true);
  int get length => _b.length;
  bool get isEmpty => _b.isEmpty;
  Uint8List take() => _b.takeBytes();
  @override
  void add(List<int> data) => _b.add(data);
  @override
  void close() {}
}

/// Seals a (possibly large) file into chunk containers, streamed.
Future<List<String>> sealFileChunks(File source, Directory dir, String base, SecretKey key,
    {int partBytes = BackupStream.partBytes}) async {
  final names = <String>[];
  BackupFileWriter? w;
  var inPart = 0;
  await for (final b in source.openRead()) {
    var off = 0;
    while (off < b.length) {
      if (w == null) {
        final name = names.isEmpty ? '$base.fybk' : '$base.${names.length}.fybk';
        names.add(name);
        w = BackupFileWriter(File('${dir.path}/$name'), key);
        inPart = 0;
      }
      final take = min(b.length - off, partBytes - inPart);
      await w.add(Uint8List.sublistView(b is Uint8List ? b : Uint8List.fromList(b), off, off + take));
      off += take;
      inPart += take;
      if (inPart >= partBytes) {
        await w.close();
        w = null;
      }
    }
  }
  if (w != null || names.isEmpty) {
    w ??= BackupFileWriter(File('${dir.path}/$base.fybk'), key);
    if (names.isEmpty) names.add('$base.fybk');
    await w.close();
  }
  return names;
}
