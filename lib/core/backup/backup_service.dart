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
import 'backup_stream.dart';

/// Where backup parts go: this device's files, or Cloudflare R2.
///
/// Parts move as FILES (streamed): a part never has to fit in memory.
/// [put] / [get] remain for the small parts (manifest, key, extras).
abstract class BackupDestination {
  String get id;
  Future<void> put(String backupId, String part, Uint8List data);
  Future<Uint8List?> get(String backupId, String part);
  Future<void> putFile(String backupId, String part, File source, {bool move = false});
  Future<bool> getFile(String backupId, String part, File into);
  Future<bool> has(String backupId, String part);
  Future<List<String>> sets();
  Future<void> deleteSet(String backupId);
}

/// The largest part read whole into memory (manifest / key / extras).
const backupSmallPartMax = 64 * 1024 * 1024;

/// Backups as files on this device (`<root>/<backupId>/<part>`), written
/// atomically (temp file + rename): a crash never leaves a half part.
class LocalBackupDestination implements BackupDestination {
  LocalBackupDestination(this.root);
  final Directory root;
  @override
  String get id => 'local';

  File file(String backupId, String part) => File('${root.path}/$backupId/$part');

  @override
  Future<void> put(String backupId, String part, Uint8List data) async {
    final f = file(backupId, part);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(data, flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<void> putFile(String backupId, String part, File source, {bool move = false}) async {
    final f = file(backupId, part);
    await f.parent.create(recursive: true);
    if (move) {
      try {
        await source.rename(f.path);
        return;
      } on FileSystemException {
        // another volume: copy below
      }
    }
    final tmp = File('${f.path}.tmp');
    await source.copy(tmp.path);
    await tmp.rename(f.path);
  }

  @override
  Future<Uint8List?> get(String backupId, String part) async {
    final f = file(backupId, part);
    if (!await f.exists()) return null;
    if (await f.length() > backupSmallPartMax) throw const BackupTampered('part too large');
    return f.readAsBytes();
  }

  @override
  Future<bool> getFile(String backupId, String part, File into) async {
    final f = file(backupId, part);
    if (!await f.exists()) return false;
    await into.parent.create(recursive: true);
    await f.copy(into.path);
    return true;
  }

  @override
  Future<bool> has(String backupId, String part) => file(backupId, part).exists();

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
      Set<String>? media, this.createdAt = 0, Map<String, int>? doneSeq, Map<String, int>? lastOkAt, this.checkpoint,
      List<String>? snapshot, Map<String, int>? mediaParts})
      : deltas = deltas ?? [],
        media = media ?? {},
        doneSeq = doneSeq ?? {},
        lastOkAt = lastOkAt ?? {},
        snapshot = snapshot ?? ['s.fybk'],
        mediaParts = mediaParts ?? {};

  String? backupId;
  int s0;
  int lastSeq;
  final List<Map<String, dynamic>> deltas;
  final Set<String> media;
  int createdAt;

  /// Chunk files of the snapshot (one for small ledgers).
  List<String> snapshot;

  /// Media sha → number of chunk files (absent = 1).
  final Map<String, int> mediaParts;

  /// Highest change seq each destination fully holds (manifest written).
  final Map<String, int> doneSeq;
  final Map<String, int> lastOkAt;
  Map<String, dynamic>? checkpoint;
  bool hasExtras = false;

  Map<String, dynamic> toJson() => {
        'x': hasExtras,
        'id': backupId, 's0': s0, 'last': lastSeq, 'deltas': deltas, 'media': media.toList(),
        'created': createdAt, 'done': doneSeq, 'ok': lastOkAt, 'cp': checkpoint,
        'sp': snapshot, 'mp': mediaParts,
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
      snapshot: [for (final n in (j['sp'] as List? ?? const ['s.fybk'])) '$n'],
      mediaParts: {for (final e in (j['mp'] as Map? ?? const {}).entries) '${e.key}': (e.value as num).toInt()},
    )..hasExtras = j['x'] == true;
  }
}

/// Chunk file names of a logical part `<base>.fybk` split in [n].
List<String> backupChunks(String base, int n) => [for (var i = 0; i < n; i++) i == 0 ? '$base.fybk' : '$base.$i.fybk'];

/// Every file of a set, from its manifest (old single-file sets included).
List<String> backupPartsOf(Map<String, dynamic> man) {
  final snap = man['snapshot'];
  final mp = (man['mparts'] as Map? ?? const {});
  return [
    if (snap is List) ...snap.map((e) => '$e') else '$snap',
    for (final d in (man['deltas'] as List? ?? const []).cast<Map>())
      ...((d['parts'] as List?)?.map((e) => '$e') ?? ['${d['name']}']),
    for (final sha in (man['media'] as List? ?? const []).cast<String>())
      ...backupChunks('m-$sha', (mp[sha] as num?)?.toInt() ?? 1),
    if (man['extras'] != null) '${man['extras']}',
  ];
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
/// A *set* = one fuzzy snapshot (`s.fybk`, `s.1.fybk`, … chunks) + ordered
/// change parts (`d-<from>-<to>.fybk`, chunked the same way) + encrypted
/// media (`m-<sha>.fybk` …) + the wrapped key (`key.json`) +
/// `manifest.enc`, which is written LAST on every destination: a set without
/// its manifest (crash / network loss mid-way) simply does not exist for
/// restore. Everything is streamed through files in [work], so the size of
/// the ledger does not matter for memory. A new set starts every [setAge]
/// or after [maxDeltas] parts; [keepSets] newest complete sets are kept.
class BackupService {
  BackupService({
    required this.engine,
    required this.key,
    required this.wrappedKey,
    required this.destinations,
    required this.scope,
    this.media,
    Directory? work,
    this.setAge = const Duration(days: 7),
    this.maxDeltas = 200,
    this.keepSets = 3,
    this.partBytes = BackupStream.partBytes,
    int Function()? now,
  })  : work = work ?? Directory('${Directory.systemTemp.path}/fyona-backup-work-$pid-${_rng.nextInt(1 << 32)}'),
        _sweep = work != null,
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final BackupEngine engine;
  final SecretKey key;
  final Map<String, dynamic> wrappedKey;
  final List<BackupDestination> destinations;
  final String scope; // e.g. personal:<uid> / business:<org>/<branch>
  final MediaStore? media;
  final Directory work;
  final Duration setAge;
  final int maxDeltas;
  final int keepSets;
  final int partBytes;
  final bool _sweep; // a dedicated work folder: leftovers of a killed run are removed
  final int Function() _now;

  static final _rng = Random.secure();

  String _rand() => List.generate(6, (_) => _rng.nextInt(36).toRadixString(36)).join();

  String _newId() {
    final t = DateTime.fromMillisecondsSinceEpoch(_now(), isUtc: true);
    final stamp = '${t.year}${t.month.toString().padLeft(2, '0')}${t.day.toString().padLeft(2, '0')}'
        '-${t.hour.toString().padLeft(2, '0')}${t.minute.toString().padLeft(2, '0')}${t.second.toString().padLeft(2, '0')}';
    return 'bk-$stamp-${_rand()}';
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
    // Nothing written since the last run: no work at all (no table scan).
    if (!newSet && await engine.lastSeq(db) == state.lastSeq &&
        destinations.every((d) => (state.doneSeq[d.id] ?? -1) >= state.lastSeq)) {
      return BackupRun(backupId: state.backupId!, newSet: false, changes: 0, bytes: 0, destinations: const [], failed: failed);
    }
    if (_sweep && await work.exists()) {
      await for (final e in work.list()) {
        if (e is Directory && e.uri.pathSegments.where((s) => s.isNotEmpty).last.startsWith('run-')) {
          await e.delete(recursive: true);
        }
      }
    }
    final dir = Directory('${work.path}/run-${_now()}-${_rand()}');
    await dir.create(recursive: true);
    try {
      return await _run(db, state, extras, newSet, dir, failed);
    } finally {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  Future<BackupRun> _run(Database db, BackupState state, Map<String, dynamic>? extras, bool newSet, Directory dir,
      Map<String, String> failed) async {
    final parts = <String>[]; // files in [dir], in upload order
    var changes = 0;
    final prevSeq = state.lastSeq;
    final prevDone = Map<String, int>.of(state.doneSeq);
    final refs = <String>{};
    void collect(String line) => refs.addAll(BackupEngine.mediaRefsOf(line));
    if (newSet) {
      final w = BackupLineWriter(dir, 's', key, partBytes: partBytes, onLine: collect);
      final s0 = await engine.snapshot(db, w.add);
      final names = await w.close();
      state
        ..backupId = _newId()
        ..s0 = s0
        ..lastSeq = s0
        ..snapshot = names
        ..deltas.clear()
        ..media.clear()
        ..mediaParts.clear()
        ..createdAt = _now()
        ..doneSeq.clear();
      parts.addAll(names);
      await File('${dir.path}/key.json').writeAsString(jsonEncode(wrappedKey), flush: true);
      parts.add('key.json');
      changes = w.lineCount;
    }
    final head = await engine.head(db);
    if (head.seq > state.lastSeq || newSet) {
      final from = state.lastSeq, to = head.seq;
      if (to > from) {
        final w = BackupLineWriter(dir, 'd-$from-$to', key, partBytes: partBytes, onLine: collect);
        await for (final l in engine.changeLines(db, from, to)) {
          await w.add(l);
        }
        final names = await w.close();
        state.deltas.add({'name': names.first, 'from': from, 'to': to, if (names.length > 1) 'parts': names});
        parts.addAll(names);
        changes += w.lineCount;
      }
      state
        ..lastSeq = to
        ..checkpoint = head.toJson();
    }
    parts.addAll(await _media(refs, state, dir));
    if (extras != null && parts.isNotEmpty) {
      await _small(dir, 'x.fybk', utf8.encode(jsonEncode(extras)));
      parts.add('x.fybk');
      state.hasExtras = true;
    }
    if (parts.isEmpty && destinations.every((d) => (prevDone[d.id] ?? -1) >= prevSeq)) {
      return BackupRun(backupId: state.backupId!, newSet: false, changes: 0, bytes: 0, destinations: const [], failed: failed);
    }
    await _small(dir, 'manifest.enc', utf8.encode(jsonEncode(_manifest(state))));
    var bytes = 0;
    for (final p in [...parts, 'manifest.enc']) {
      bytes += await File('${dir.path}/$p').length();
    }
    final ok = <String>[];
    for (var i = 0; i < destinations.length; i++) {
      final dest = destinations[i];
      final last = i == destinations.length - 1;
      try {
        // Destinations that missed earlier parts of this set get them now.
        for (final p in parts) {
          await dest.putFile(state.backupId!, p, File('${dir.path}/$p'), move: last);
        }
        // Only a destination that missed an earlier run needs catching up.
        if (!newSet && (prevDone[dest.id] ?? -1) < prevSeq) await _catchUp(dest, state, db, dir);
        await dest.putFile(state.backupId!, 'manifest.enc', File('${dir.path}/manifest.enc'), move: last);
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
        bytes: bytes, destinations: ok, failed: failed);
  }

  Future<void> _small(Directory dir, String name, List<int> plain) async {
    final w = BackupFileWriter(File('${dir.path}/$name'), key);
    await w.add(plain);
    await w.close();
  }

  Future<void> _catchUp(BackupDestination dest, BackupState state, Database db, Directory dir) async {
    // A destination that failed before may lack earlier parts of this set.
    // Copy them from a destination that has them (identical bytes), else
    // rebuild change parts from the device log (kept until EVERY destination
    // holds them). A snapshot nobody has forces a new set next run.
    final id = state.backupId!;
    final fix = Directory('${dir.path}/catch-up');
    await fix.create(recursive: true);
    Future<bool> fromOthers(String name) async {
      for (final other in destinations) {
        if (identical(other, dest)) continue;
        try {
          final f = File('${fix.path}/$name');
          if (await other.getFile(id, name, f)) {
            await dest.putFile(id, name, f, move: true);
            return true;
          }
        } catch (_) {}
      }
      return false;
    }

    Never lost(String name) {
      state.createdAt = 0; // start a fresh set on the next run
      throw StateError('part $name lost on ${dest.id}; a new set will be made');
    }

    for (final name in state.snapshot) {
      if (!await dest.has(id, name) && !await fromOthers(name)) lost(name);
    }
    if (!await dest.has(id, 'key.json') && !await fromOthers('key.json')) {
      await dest.put(id, 'key.json', Uint8List.fromList(utf8.encode(jsonEncode(wrappedKey))));
    }
    for (final d in state.deltas) {
      final names = [for (final n in (d['parts'] as List?) ?? [d['name']]) '$n'];
      var missing = false;
      for (final n in names) {
        if (!await dest.has(id, n) && !await fromOthers(n)) missing = true;
      }
      if (!missing) continue;
      final from = d['from'] as int, to = d['to'] as int;
      final w = BackupLineWriter(fix, 'd-$from-$to', key, partBytes: partBytes);
      await for (final l in engine.changeLines(db, from, to)) {
        await w.add(l);
      }
      final rebuilt = await w.close();
      if (rebuilt.length != names.length) lost(names.first);
      for (final n in rebuilt) {
        await dest.putFile(id, n, File('${fix.path}/$n'), move: true);
      }
    }
    for (final ref in state.media) {
      final sha = MediaStore.shaOf(ref)!;
      final names = backupChunks('m-$sha', state.mediaParts[sha] ?? 1);
      var missing = false;
      for (final n in names) {
        if (!await dest.has(id, n) && !await fromOthers(n)) missing = true;
      }
      if (!missing) continue;
      final src = media?.fileOf(ref);
      if (src == null) lost(names.first);
      final made = await sealFileChunks(src, fix, 'm-$sha', key, partBytes: partBytes);
      if (made.length != names.length) lost(names.first);
      for (final n in made) {
        await dest.putFile(id, n, File('${fix.path}/$n'), move: true);
      }
    }
  }

  /// Media referenced by new records: sealed straight from the device file
  /// (streamed, chunked like any part).
  Future<List<String>> _media(Set<String> refs, BackupState state, Directory dir) async {
    final store = media;
    if (store == null) return const [];
    final out = <String>[];
    for (final ref in refs) {
      if (state.media.contains(ref)) continue;
      final file = store.fileOf(ref);
      if (file == null) continue; // not on this device: listed as missing in the manifest
      final sha = MediaStore.shaOf(ref)!;
      final names = await sealFileChunks(file, dir, 'm-$sha', key, partBytes: partBytes);
      if (names.length > 1) state.mediaParts[sha] = names.length;
      state.media.add(ref);
      out.addAll(names);
    }
    return out;
  }

  Map<String, dynamic> _manifest(BackupState s) => {
        'v': 2, 'scope': scope, 'id': s.backupId, 'created': s.createdAt, 'updated': _now(),
        's0': s.s0, 'snapshot': s.snapshot, 'deltas': s.deltas, 'checkpoint': s.checkpoint,
        'media': [for (final m in s.media) MediaStore.shaOf(m)],
        if (s.mediaParts.isNotEmpty) 'mparts': s.mediaParts,
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
///
/// Streamed end to end: each part is read frame by frame (authenticated
/// before use), decompressed in small slices and applied in batches inside
/// one transaction of the new database. Media are verified by SHA-256 into
/// a staging folder and only handed to the media store once the whole
/// database is rebuilt and verified — until then nothing is visible.
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

  /// [onProgress]: (stage, count done); [onFraction]: (stage, 0..1) with
  /// stage `media` (files verified) then `records` (rows rebuilt, against
  /// the row count the manifest promises; the last step, the full check,
  /// is not counted so 1.0 is only reported once verified).
  Future<List<String>> restore(BackupDestination src, String backupId, SecretKey key, Database target,
      {MediaStore? mediaStore,
      Directory? work,
      void Function(String stage, int done)? onProgress,
      void Function(String stage, double done)? onFraction}) async {
    final man = await manifest(src, backupId, key);
    final dir = work ?? Directory('${Directory.systemTemp.path}/fyona-restore-${DateTime.now().microsecondsSinceEpoch}');
    await dir.create(recursive: true);
    final mediaTotal = (man['media'] as List? ?? const []).length;
    final rows = ((man['checkpoint'] as Map?)?['counts'] as Map? ?? const {})
        .values
        .fold<int>(0, (a, b) => a + (b as num).toInt());
    void report(String stage, int done) {
      onProgress?.call(stage, done);
      final total = stage == 'media' ? mediaTotal : rows;
      onFraction?.call(stage, total <= 0 ? 0.99 : (done / total).clamp(0, 0.99).toDouble());
    }

    try {
      final problems = await _restore(src, backupId, key, target, man, mediaStore, dir, report);
      if (problems.isEmpty) onFraction?.call('records', 1);
      return problems;
    } finally {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  Future<List<String>> _restore(BackupDestination src, String backupId, SecretKey key, Database target,
      Map<String, dynamic> man, MediaStore? mediaStore, Directory dir,
      void Function(String stage, int done)? onProgress) async {
    // The chain must be complete before anything is read.
    var expectFrom = (man['s0'] as num).toInt();
    for (final d in (man['deltas'] as List).cast<Map>()) {
      if ((d['from'] as num).toInt() != expectFrom) throw const BackupTampered('gap in change parts');
      expectFrom = (d['to'] as num).toInt();
    }
    Future<File> fetch(String name) async {
      if (src is LocalBackupDestination) {
        final f = src.file(backupId, name);
        if (!await f.exists()) throw BackupTampered('missing $name');
        return f;
      }
      final f = File('${dir.path}/parts/$name');
      if (!await src.getFile(backupId, name, f)) throw BackupTampered('missing $name');
      return f;
    }

    final snap = man['snapshot'];
    final snapFiles = [for (final n in snap is List ? snap : [snap]) await fetch('$n')];
    final deltaFiles = [
      for (final d in (man['deltas'] as List).cast<Map>())
        [for (final n in (d['parts'] as List?) ?? [d['name']]) await fetch('$n')],
    ];
    // Media first, into staging: verified (hash) before the database is built.
    final mp = (man['mparts'] as Map? ?? const {});
    final missingMedia = <String>[];
    final staged = <String, File>{};
    var m = 0;
    for (final sha in (man['media'] as List).cast<String>()) {
      final names = backupChunks('m-$sha', (mp[sha] as num?)?.toInt() ?? 1);
      final files = <File>[];
      try {
        for (final n in names) {
          files.add(await fetch(n));
        }
      } on BackupTampered {
        files.clear();
      }
      if (files.length != names.length) {
        missingMedia.add(sha);
        continue;
      }
      final out = File('${dir.path}/media/$sha');
      await out.parent.create(recursive: true);
      final sink = out.openWrite();
      try {
        await sink.addStream(BackupStream.bytes(files, key, sha: sha));
        await sink.flush();
      } on BackupTampered {
        await sink.close();
        throw BackupTampered('media $sha altered');
      }
      await sink.close();
      staged[sha] = out;
      onProgress?.call('media', ++m);
    }
    Stream<String> changes() async* {
      for (final files in deltaFiles) {
        yield* BackupStream.lines(files, key);
      }
    }

    final problems = await engine.restoreStream(
        target, BackupStream.lines(snapFiles, key), changes(), BackupCheckpoint.fromJson(man['checkpoint'] as Map),
        onProgress: (n) => onProgress?.call('records', n));
    if (problems.isEmpty && mediaStore != null) {
      for (final e in staged.entries) {
        await mediaStore.adopt(e.key, e.value, mime: 'application/octet-stream');
      }
    }
    return [...problems, for (final m in missingMedia) 'media $m not in the backup'];
  }
}
