import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Where a media file lives in the cloud — decided by the SERVER from the
/// caller's credentials; the device only says which section it is in.
enum MediaSection { business, personal, chat }

/// FYONA's unified media store (images, audio, video, documents).
///
/// Files are stored ONCE on the device, named by their SHA-256:
/// `<app support>/media/<aa>/<sha256>` (+ `<sha256>.json` with mime/size).
/// Records keep only a short reference `media:<sha256>` — never the bytes —
/// so databases, sync operations and backups stay small. The same picture
/// used by several products is stored once. Files are verified against their
/// name whenever they come from outside (download, import, restore).
class MediaStore {
  MediaStore(this._root);

  /// Test seam / app default (`<application support>/media`).
  static Future<Directory> Function() rootProvider = () async {
    try {
      return Directory('${(await getApplicationSupportDirectory()).path}/media');
    } catch (_) {
      // No platform folder service (unit tests / headless tools).
      return Directory('${Directory.systemTemp.path}/fyona-media');
    }
  };

  static MediaStore? _instance;
  static Future<MediaStore> instance() async =>
      _instance ??= MediaStore(await rootProvider());

  /// The store once [instance] has resolved (sync readers: PDF, images).
  static MediaStore? get ready => _instance;

  /// Forget the cached instance (tests, logout).
  static void reset() => _instance = null;

  final Directory _root;
  Directory get root => _root;

  static const prefix = 'media:';
  static final _refRe = RegExp(r'^media:([0-9a-f]{64})$');

  static bool isRef(String? value) => value != null && _refRe.hasMatch(value);

  static String? shaOf(String? ref) => ref == null ? null : _refRe.firstMatch(ref)?.group(1);

  static String refFor(String sha) => '$prefix$sha';

  static String shaHex(List<int> bytes) => sha256.convert(bytes).toString();

  File _file(String sha) => File('${_root.path}/${sha.substring(0, 2)}/$sha');
  File _meta(String sha) => File('${_root.path}/${sha.substring(0, 2)}/$sha.json');

  /// Stores [bytes] (once) and returns its reference.
  Future<String> put(Uint8List bytes, {required String mime}) async {
    final sha = shaHex(bytes);
    final file = _file(sha);
    if (!await file.exists() || await file.length() != bytes.length) {
      await file.parent.create(recursive: true);
      // Atomic: a crash never leaves a half file under a valid name.
      final tmp = File('${file.path}.part');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    }
    await _meta(sha).writeAsString(jsonEncode({'mime': mime, 'size': bytes.length}));
    return refFor(sha);
  }

  /// Copies a file in (streamed: large videos never sit in memory).
  Future<String> putFile(File source, {required String mime}) async {
    final digest = await sha256.bind(source.openRead()).first;
    final sha = digest.toString();
    final file = _file(sha);
    final size = await source.length();
    if (!await file.exists() || await file.length() != size) {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.part');
      await source.copy(tmp.path);
      await tmp.rename(file.path);
    }
    await _meta(sha).writeAsString(jsonEncode({'mime': mime, 'size': size}));
    return refFor(sha);
  }

  /// Accepts bytes that must match [sha] (download / restore / import).
  Future<bool> putVerified(String sha, Uint8List bytes, {required String mime}) async {
    if (shaHex(bytes) != sha) return false;
    await put(bytes, mime: mime);
    return true;
  }

  /// The local file, or null when it is not on this device (yet).
  File? fileOf(String ref) {
    final sha = shaOf(ref);
    if (sha == null) return null;
    final f = _file(sha);
    return f.existsSync() ? f : null;
  }

  Uint8List? readSync(String ref) => fileOf(ref)?.readAsBytesSync();

  Future<Uint8List?> read(String ref) async => fileOf(ref)?.readAsBytes();

  ({String mime, int size})? metaOf(String ref) {
    final sha = shaOf(ref);
    if (sha == null) return null;
    final m = _meta(sha);
    if (!m.existsSync()) return null;
    try {
      final j = jsonDecode(m.readAsStringSync()) as Map;
      return (mime: '${j['mime']}', size: (j['size'] as num).toInt());
    } catch (_) {
      return null;
    }
  }

  /// Bytes used on the device by media.
  Future<int> usedBytes() async {
    if (!await _root.exists()) return 0;
    var total = 0;
    await for (final e in _root.list(recursive: true)) {
      if (e is File && !e.path.endsWith('.json')) total += await e.length();
    }
    return total;
  }

  /// Removes files no record references any more ([keep] = live refs).
  Future<int> sweep(Set<String> keep) async {
    if (!await _root.exists()) return 0;
    final shas = {for (final r in keep) ?shaOf(r)};
    var removed = 0;
    await for (final e in _root.list(recursive: true)) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      final sha = name.endsWith('.json') ? name.substring(0, name.length - 5) : name;
      if (sha.length == 64 && !shas.contains(sha)) {
        await e.delete();
        if (!name.endsWith('.json')) removed++;
      }
    }
    return removed;
  }
}
