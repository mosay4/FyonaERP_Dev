import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../media/media_store.dart';
import 'backup_crypto.dart';
import 'backup_engine.dart';

/// Where backup parts go: this device's files, or Cloudflare R2.
abstract class BackupDestination {
  String get id;
  Future<void> put(String backupId, String part, Uint8List data);
  Future<Uint8List?> get(String backupId, String part);
  Future<List<String>> sets();
  Future<void> deleteSet(String backupId);
}

/// Backups as files on this device (`<root>/<backupId>/<part>`), written
/// atomically (temp file + rename): a crash never leaves a half part.
class LocalBackupDestination implements BackupDestination {
  LocalBackupDestination(this.root);
  final Directory root;
  @override
  String get id => 'local';

  @override
  Future<void> put(String backupId, String part, Uint8List data) async {
    final f = File('${root.path}/$backupId/$part');
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(data, flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<Uint8List?> get(String backupId, String part) async {
    final f = File('${root.path}/$backupId/$part');
    return await f.exists() ? f.readAsBytes() : null;
  }

  @override
  Future<List<String>> sets() async {
    if (!await root.exists()) return [];
    return [
      await for (final e in root.list())
        if (e is Directory && File('${e.path}/manifest.enc').existsSync()) e.uri.pathSegments.where((s) => s.isNotEmpty).last,
    ]..sort();
  }

  @override
  Future<void> deleteSet(String backupId) async {
    final d = Directory('${root.path}/$backupId');
    if (await d.exists()) await d.delete(recursive: true);
  }
}

/// Plain state of one database's backups (persisted by the caller).
class BackupState {
  BackupState({this.backupId, this.s0 = 0, this.lastSeq = 0, List<Map<String, dynamic>>? deltas,
      Set<String>? media, this.createdAt = 0, Map<String, int>? doneSeq, Map<String, int>? lastOkAt, this.checkpoint})
      : deltas = deltas ?? [],
        media = media ?? {},
        doneSeq = doneSeq ?? {},
        lastOkAt = lastOkAt ?? {};

  String? backupId;
  int s0;
  int lastSeq;
  final List<Map<String, dynamic>> deltas;
  final Set<String> media;
  int createdAt;

  /// Highest change seq each destination fully holds (manifest written).
  final Map<String, int> doneSeq;
  final Map<String, int> lastOkAt;
  Map<String, dynamic>? checkpoint;
  bool hasExtras = false;

  Map<String, dynamic> toJson() => {
        'x': hasExtras,
        'id': backupId, 's0': s0, 'last': lastSeq, 'deltas': deltas, 'media': media.toList(),
        'created': createdAt, 'done': doneSeq, 'ok': lastOkAt, 'cp': checkpoint,
      };

  static BackupState fromJson(Map? j) {
    if (j == null) return BackupState();
    return BackupState(
      backupId: j['id'] as String?,
      s0: (j['s0'] as num?)?.toInt() ?? 0,
      lastSeq: (j['last'] as num?)?.toInt() ?? 0,
      deltas: [for (final d in (j['deltas'] as List? ?? const [])) Map<String, dynamic>.from(d as Map)],
      media: {for (final m in (j['media'] as List? ?? const [])) '$m'},
      createdAt: (j['created'] as num?)?.toInt() ?? 0,
      doneSeq: {for (final e in (j['done'] as Map? ?? const {}).entries) '${e.key}': (e.value as num).toInt()},
      lastOkAt: {for (final e in (j['ok'] as Map? ?? const {}).entries) '${e.key}': (e.value as num).toInt()},
      checkpoint: (j['cp'] as Map?)?.cast<String, dynamic>(),
    )..hasExtras = j['x'] == true;
  }
}

/// Result of one backup run (for the status line and reports).
class BackupRun {
  BackupRun({required this.backupId, required this.newSet, required this.changes, required this.bytes,
      required this.destinations, required this.failed});
  final String backupId;
  final bool newSet;
  final int changes;
  final int bytes;
  final List<String> destinations;
  final Map<String, String> failed;
}

/// Runs FYONA backups for one database.
///
/// A *set* = one fuzzy snapshot (`s.fybk`) + ordered change parts
/// (`d-<from>-<to>.fybk`) + encrypted media (`m-<sha>.fybk`) + the wrapped
/// key (`key.json`) + `manifest.enc`, which is written LAST on every
/// destination: a set without its manifest (crash / network loss mid-way)
/// simply does not exist for restore. A new set starts every [setAge] or
/// after [maxDeltas] parts; [keepSets] newest complete sets are kept.
class BackupService {
  BackupService({
    required this.engine,
    required this.key,
    required this.wrappedKey,
    required this.destinations,
    required this.scope,
    this.media,
    this.setAge = const Duration(days: 7),
    this.maxDeltas = 200,
    this.keepSets = 3,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final BackupEngine engine;
  final SecretKey key;
  final Map<String, dynamic> wrappedKey;
  final List<BackupDestination> destinations;
  final String scope; // e.g. personal:<uid> / business:<org>/<branch>
  final MediaStore? media;
  final Duration setAge;
  final int maxDeltas;
  final int keepSets;
  final int Function() _now;

  static final _rng = Random.secure();

  String _newId() {
    final t = DateTime.fromMillisecondsSinceEpoch(_now(), isUtc: true);
    final stamp = '${t.year}${t.month.toString().padLeft(2, '0')}${t.day.toString().padLeft(2, '0')}'
        '-${t.hour.toString().padLeft(2, '0')}${t.minute.toString().padLeft(2, '0')}${t.second.toString().padLeft(2, '0')}';
    final rnd = List.generate(6, (_) => _rng.nextInt(36).toRadixString(36)).join();
    return 'bk-$stamp-$rnd';
  }

  /// One run: new set or new change part, sent to every destination.
  /// Never throws for destination problems (they are reported); the user's
  /// work is never affected by a failed backup.
  ///
  /// [extras]: small app data kept outside the database (e.g. Personal
  /// preferences), stored encrypted as `x.fybk` with every run.
  Future<BackupRun> run(Database db, BackupState state, {Map<String, dynamic>? extras}) async {
    final failed = <String, String>{};
    final newSet = state.backupId == null ||
        _now() - state.createdAt > setAge.inMilliseconds ||
        state.deltas.length >= maxDeltas;
    final parts = <String, Uint8List>{};
    var changes = 0;
    final prevSeq = state.lastSeq;
    final prevDone = Map<String, int>.of(state.doneSeq);
    if (newSet) {
      final lines = <String>[];
      final s0 = await engine.snapshot(db, lines.add);
      state
        ..backupId = _newId()
        ..s0 = s0
        ..lastSeq = s0
        ..deltas.clear()
        ..media.clear()
        ..createdAt = _now()
        ..doneSeq.clear();
      parts['s.fybk'] = await BackupContainer.seal(BackupEngine.pack(lines), key);
      parts['key.json'] = Uint8List.fromList(utf8.encode(jsonEncode(wrappedKey)));
      await _media(lines, state, parts);
      changes = lines.length;
    }
    final d = await engine.delta(db, state.lastSeq);
    if (d.lines.isNotEmpty || newSet) {
      final from = state.lastSeq, to = d.checkpoint.seq;
      if (d.lines.isNotEmpty) {
        final name = 'd-$from-$to.fybk';
        parts[name] = await BackupContainer.seal(BackupEngine.pack(d.lines), key);
        state.deltas.add({'name': name, 'from': from, 'to': to});
        await _media(d.lines, state, parts);
        changes += d.lines.length;
      }
      state
        ..lastSeq = to
        ..checkpoint = d.checkpoint.toJson();
    }
    if (extras != null && parts.isNotEmpty) {
      parts['x.fybk'] = await BackupContainer.seal(Uint8List.fromList(utf8.encode(jsonEncode(extras))), key);
      state.hasExtras = true;
    }
    if (parts.isEmpty) {
      return BackupRun(backupId: state.backupId!, newSet: false, changes: 0, bytes: 0, destinations: const [], failed: failed);
    }
    parts['manifest.enc'] = await BackupContainer.seal(Uint8List.fromList(utf8.encode(jsonEncode(_manifest(state)))), key);
    final ok = <String>[];
    for (final dest in destinations) {
      try {
        // Destinations that missed earlier parts of this set get them now.
        for (final e in parts.entries.where((e) => e.key != 'manifest.enc')) {
          await dest.put(state.backupId!, e.key, e.value);
        }
        // Only a destination that missed an earlier run needs catching up.
        if (!newSet && (prevDone[dest.id] ?? -1) < prevSeq) await _catchUp(dest, state, db);
        await dest.put(state.backupId!, 'manifest.enc', parts['manifest.enc']!);
        state.doneSeq[dest.id] = state.lastSeq;
        state.lastOkAt[dest.id] = _now();
        ok.add(dest.id);
        await _retention(dest, state.backupId!);
      } catch (e) {
        failed[dest.id] = '$e';
      }
    }
    // Changes every destination holds are no longer needed on the device.
    if (destinations.isNotEmpty && destinations.every((d) => (state.doneSeq[d.id] ?? -1) >= state.lastSeq)) {
      await engine.forget(db, state.lastSeq);
    }
    return BackupRun(backupId: state.backupId!, newSet: newSet, changes: changes,
        bytes: parts.values.fold(0, (s, p) => s + p.length), destinations: ok, failed: failed);
  }

  Future<void> _catchUp(BackupDestination dest, BackupState state, Database db) async {
    // A destination that failed before may lack earlier parts of this set.
    // Copy them from a destination that has them (identical bytes), else
    // rebuild change parts from the device log (kept until EVERY destination
    // holds them). A snapshot nobody has forces a new set next run.
    final id = state.backupId!;
    final need = ['s.fybk', 'key.json', for (final d in state.deltas) d['name'] as String,
      for (final m in state.media) 'm-${MediaStore.shaOf(m)}.fybk'];
    for (final name in need) {
      if (await dest.get(id, name) != null) continue;
      Uint8List? bytes;
      for (final other in destinations) {
        if (identical(other, dest)) continue;
        try {
          bytes = await other.get(id, name);
        } catch (_) {}
        if (bytes != null) break;
      }
      if (bytes == null && name.startsWith('d-')) {
        final d = state.deltas.firstWhere((d) => d['name'] == name);
        bytes = await BackupContainer.seal(
            BackupEngine.pack(await engine.range(db, d['from'] as int, d['to'] as int)), key);
      }
      if (bytes == null && name == 'key.json') bytes = Uint8List.fromList(utf8.encode(jsonEncode(wrappedKey)));
      if (bytes == null && name.startsWith('m-') && media != null) {
        final raw = await media!.read(MediaStore.refFor(name.substring(2, name.length - 5)));
        if (raw != null) bytes = await BackupContainer.seal(raw, key);
      }
      if (bytes == null) {
        state.createdAt = 0; // start a fresh set on the next run
        throw StateError('part $name lost on ${dest.id}; a new set will be made');
      }
      await dest.put(id, name, bytes);
    }
  }

  Future<void> _media(List<String> lines, BackupState state, Map<String, Uint8List> parts) async {
    final store = media;
    if (store == null) return;
    for (final ref in BackupEngine.mediaRefs(lines)) {
      if (state.media.contains(ref)) continue;
      final bytes = await store.read(ref);
      if (bytes == null) continue; // not on this device: listed as missing in the manifest
      parts['m-${MediaStore.shaOf(ref)}.fybk'] = await BackupContainer.seal(bytes, key);
      state.media.add(ref);
    }
  }

  Map<String, dynamic> _manifest(BackupState s) => {
        'v': 2, 'scope': scope, 'id': s.backupId, 'created': s.createdAt, 'updated': _now(),
        's0': s.s0, 'snapshot': 's.fybk', 'deltas': s.deltas, 'checkpoint': s.checkpoint,
        'media': [for (final m in s.media) MediaStore.shaOf(m)],
        if (s.hasExtras) 'extras': 'x.fybk',
      };

  Future<void> _retention(BackupDestination dest, String current) async {
    final sets = await dest.sets();
    final old = sets.where((s) => s != current).toList()..sort();
    while (old.length > keepSets - 1) {
      await dest.deleteSet(old.removeAt(0));
    }
  }
}

/// Reads and verifies a backup set, then rebuilds it into a NEW database.
class BackupRestorer {
  BackupRestorer({required this.engine});
  final BackupEngine engine;

  /// Opens the manifest (proves the key and integrity of the index).
  Future<Map<String, dynamic>> manifest(BackupDestination src, String backupId, SecretKey key) async {
    final m = await src.get(backupId, 'manifest.enc');
    if (m == null) throw const BackupTampered('no manifest (incomplete backup)');
    return (jsonDecode(utf8.decode(await BackupContainer.open(m, key))) as Map).cast<String, dynamic>();
  }

  /// The encrypted app extras of a set (null when it has none).
  Future<Map<String, dynamic>?> extras(BackupDestination src, String backupId, SecretKey key) async {
    final man = await manifest(src, backupId, key);
    if (man['extras'] == null) return null;
    final b = await src.get(backupId, '${man['extras']}');
    if (b == null) throw const BackupTampered('extras missing');
    return (jsonDecode(utf8.decode(await BackupContainer.open(b, key))) as Map).cast<String, dynamic>();
  }

  /// Every part is downloaded and authenticated BEFORE anything is written;
  /// then the database is rebuilt into [target] and verified (row counts +
  /// numeric totals of every table + SQLite integrity). Media files are
  /// verified against their SHA-256 and put in [mediaStore].
  Future<List<String>> restore(BackupDestination src, String backupId, SecretKey key, Database target,
      {MediaStore? mediaStore}) async {
    final man = await manifest(src, backupId, key);
    final snap = await src.get(backupId, '${man['snapshot']}');
    if (snap == null) throw const BackupTampered('snapshot missing');
    final snapLines = BackupEngine.unpack(await BackupContainer.open(snap, key));
    final changeLines = <String>[];
    var expectFrom = (man['s0'] as num).toInt();
    for (final d in (man['deltas'] as List).cast<Map>()) {
      if ((d['from'] as num).toInt() != expectFrom) throw const BackupTampered('gap in change parts');
      final p = await src.get(backupId, '${d['name']}');
      if (p == null) throw BackupTampered('missing ${d['name']}');
      changeLines.addAll(BackupEngine.unpack(await BackupContainer.open(p, key)));
      expectFrom = (d['to'] as num).toInt();
    }
    final missingMedia = <String>[];
    final mediaBytes = <String, Uint8List>{};
    for (final sha in (man['media'] as List).cast<String>()) {
      final p = await src.get(backupId, 'm-$sha.fybk');
      if (p == null) {
        missingMedia.add(sha);
        continue;
      }
      final bytes = await BackupContainer.open(p, key);
      if (MediaStore.shaHex(bytes) != sha) throw BackupTampered('media $sha altered');
      mediaBytes[sha] = bytes;
    }
    final problems = await engine.restore(
        target, snapLines, changeLines, BackupCheckpoint.fromJson(man['checkpoint'] as Map));
    if (mediaStore != null) {
      for (final e in mediaBytes.entries) {
        await mediaStore.putVerified(e.key, e.value, mime: 'application/octet-stream');
      }
    }
    return [...problems, for (final m in missingMedia) 'media $m not in the backup'];
  }
}
