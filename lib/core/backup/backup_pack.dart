import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';

import 'backup_service.dart';

/// A whole backup set as ONE file the user keeps on the phone (or a card,
/// a computer…) and restores from without the cloud.
///
/// Layout: `FYBKPACK1\n`, a 4-byte big-endian header length, a JSON header
/// `{"v":1,"set":id,"files":[{"n":name,"s":size}…]}` (key.json and
/// manifest.enc first), then the files' bytes in that order. The parts
/// themselves stay exactly as the backup wrote them: encrypted and
/// authenticated frame by frame, so the pack adds no new trust.
///
/// Reading is untrusted until proven otherwise: only the header and the
/// two small index files (at most [backupPackUntrustedMax] together) are
/// read before the caller opens the manifest with the user's key. After
/// that the file is known to be a FYONA backup made with that key, and the
/// rest may be as large as the backup is ([backupPackMaxBytes]), but only
/// the parts that authenticated manifest lists are accepted.
const backupPackExtension = 'fyonaset';
const backupPackUntrustedMax = 64 * 1024 * 1024;
const backupPackMaxBytes = 64 * 1024 * 1024 * 1024;
final _magic = ascii.encode('FYBKPACK1\n');
const _headerMax = 4 * 1024 * 1024;
final _setId = RegExp(r'^bk-[0-9]{8}-[0-9]{6}-[a-z0-9]{1,32}$');
final _partName = RegExp(r'^[a-z0-9][a-z0-9.\-]{0,150}\.fybk$');

class BackupPackRejected implements Exception {
  const BackupPackRejected(this.reason);
  final String reason;
  @override
  String toString() => 'BackupPackRejected($reason)';
}

/// Writes [names] of the set folder [setDir] (id [setId]) into [out]
/// (a temp file renamed at the end). Returns the pack size.
Future<int> writeBackupPack(Directory setDir, String setId, List<String> names, File out,
    {void Function(int done, int total)? onProgress}) async {
  if (!_setId.hasMatch(setId)) throw const BackupPackRejected('set id');
  final order = ['key.json', 'manifest.enc', ...names.where((n) => n != 'key.json' && n != 'manifest.enc')];
  final files = <Map<String, Object>>[];
  var total = 0;
  for (final n in order) {
    final f = File('${setDir.path}/$n');
    if (!await f.exists()) throw BackupPackRejected('missing $n');
    final s = await f.length();
    files.add({'n': n, 's': s});
    total += s;
  }
  final header = utf8.encode(jsonEncode({'v': 1, 'set': setId, 'files': files}));
  final tmp = File('${out.path}.tmp');
  await tmp.parent.create(recursive: true);
  final sink = tmp.openWrite();
  var done = 0;
  try {
    sink.add(_magic);
    sink.add((ByteData(4)..setUint32(0, header.length)).buffer.asUint8List());
    sink.add(header);
    for (final n in order) {
      await for (final b in File('${setDir.path}/$n').openRead()) {
        sink.add(b);
        done += b.length;
        onProgress?.call(done, total);
      }
      await sink.flush();
    }
    await sink.flush();
    await sink.close();
  } catch (_) {
    await sink.close().catchError((_) {});
    if (await tmp.exists()) await tmp.delete();
    rethrow;
  }
  final size = await tmp.length();
  await tmp.rename(out.path);
  return size;
}

/// Reads a pack into `<dest>/<set id>/…`. [authenticate] runs once key.json
/// and manifest.enc are on disk: it must open the manifest (throwing when
/// the key does not open it) and return every part name the set lists.
/// [beforeBulk] gets the bytes still to come (for a free-space check).
/// Returns the set id. On any error the partial folder is removed.
Future<String> readBackupPack(
  Stream<List<int>> input,
  Directory dest, {
  required Future<Set<String>> Function(String setId, Directory setDir) authenticate,
  Future<void> Function(int remaining)? beforeBulk,
  void Function(int done, int total)? onProgress,
}) async {
  final r = ChunkedStreamReader(input);
  Directory? setDir;
  try {
    final magic = await r.readBytes(_magic.length);
    if (magic.length != _magic.length || !_same(magic, _magic)) throw const BackupPackRejected('not a FYONA backup');
    final lenBytes = await r.readBytes(4);
    if (lenBytes.length != 4) throw const BackupPackRejected('truncated');
    final len = ByteData.sublistView(lenBytes).getUint32(0);
    if (len < 2 || len > _headerMax) throw const BackupPackRejected('header size');
    final raw = await r.readBytes(len);
    if (raw.length != len) throw const BackupPackRejected('truncated');
    final Object? h;
    try {
      h = jsonDecode(utf8.decode(raw));
    } on FormatException {
      throw const BackupPackRejected('header');
    }
    if (h is! Map || h['v'] != 1 || h['set'] is! String || h['files'] is! List) {
      throw const BackupPackRejected('header');
    }
    final setId = h['set'] as String;
    if (!_setId.hasMatch(setId)) throw const BackupPackRejected('set id');
    final files = <(String, int)>[];
    final seen = <String>{};
    var total = 0;
    for (final e in h['files'] as List) {
      if (e is! Map || e['n'] is! String || e['s'] is! int) throw const BackupPackRejected('entry');
      final n = e['n'] as String, s = e['s'] as int;
      final known = files.isEmpty
          ? n == 'key.json'
          : files.length == 1
              ? n == 'manifest.enc'
              : _partName.hasMatch(n) && !n.contains('..');
      if (!known || !seen.add(n) || s < 0 || s > backupSmallPartMax) throw BackupPackRejected('entry $n');
      files.add((n, s));
      total += s;
      if (total > backupPackMaxBytes) throw const BackupPackRejected('too large');
    }
    if (files.length < 3) throw const BackupPackRejected('incomplete');
    // Untrusted phase: only the header and the two index files.
    if (len + files[0].$2 + files[1].$2 > backupPackUntrustedMax) throw const BackupPackRejected('index too large');
    setDir = Directory('${dest.path}/$setId');
    if (await setDir.exists()) await setDir.delete(recursive: true);
    await setDir.create(recursive: true);
    var done = 0;
    Future<void> copy(String name, int size) async {
      final sink = File('${setDir!.path}/$name').openWrite();
      try {
        var got = 0;
        await for (final b in r.readStream(size)) {
          sink.add(b);
          got += b.length;
          done += b.length;
          onProgress?.call(done, total);
        }
        if (got != size) throw const BackupPackRejected('truncated');
        await sink.flush();
      } finally {
        await sink.close();
      }
    }

    await copy(files[0].$1, files[0].$2);
    await copy(files[1].$1, files[1].$2);
    final listed = await authenticate(setId, setDir);
    final parts = files.skip(2).map((f) => f.$1).toSet();
    if (!listed.containsAll(parts) || !parts.containsAll(listed)) {
      throw const BackupPackRejected('parts differ from the manifest');
    }
    await beforeBulk?.call(total - done);
    for (final f in files.skip(2)) {
      await copy(f.$1, f.$2);
    }
    if ((await r.readBytes(1)).isNotEmpty) throw const BackupPackRejected('trailing data');
    return setId;
  } catch (_) {
    final d = setDir;
    if (d != null && await d.exists()) await d.delete(recursive: true);
    rethrow;
  } finally {
    await r.cancel();
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
