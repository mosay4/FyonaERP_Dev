import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';

import '../media/media_store.dart';
import '../storage/free_space.dart';
import 'backup_cloud.dart';
import 'backup_crypto.dart';
import 'backup_engine.dart';
import 'backup_pack.dart';
import 'backup_service.dart';
import 'backup_worker.dart';

/// One database the user backs up (their Personal ledger, or a Business
/// workspace on this device they own).
class BackupSpace {
  BackupSpace({
    required this.id,
    required this.section,
    required this.dbPath,
    required this.dbKeyHex,
    this.extras,
    this.exclude = const {},
  });

  /// Stable, non-identifying id (derived from the ledger storage id).
  final String id;
  final MediaSection section; // personal / business
  final String dbPath;
  final String dbKeyHex;
  final Future<Map<String, dynamic>?> Function()? extras;
  final Set<String> exclude;
}

/// What the screen shows for a space.
class BackupStatus {
  BackupStatus(this.raw);
  final Map<String, dynamic> raw;
  bool get enabled => raw['enabled'] == true;
  bool get cloud => raw['cloud'] == true;
  bool get media => raw['media'] != false;
  int? get lastOkAt => (raw['last_ok'] as num?)?.toInt();
  int? get cloudOkAt => (raw['cloud_ok'] as num?)?.toInt();
  String? get lastError => raw['last_error'] as String?;
  String? get cloudError => raw['cloud_error'] as String?;
  int get lastBytes => (raw['last_bytes'] as num?)?.toInt() ?? 0;
  String? get backupId => (raw['state'] as Map?)?['id'] as String?;
}

class BackupSetInfo {
  BackupSetInfo({required this.id, required this.local, required this.cloud, this.bytes = 0});
  final String id;
  final bool local;
  final bool cloud;
  final int bytes;

  /// `bk-YYYYMMDD-HHMMSS-xxxxxx` → when the set was started (UTC).
  DateTime? get startedAt {
    final m = RegExp(r'^bk-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})').firstMatch(id);
    if (m == null) return null;
    int g(int i) => int.parse(m.group(i)!);
    return DateTime.utc(g(1), g(2), g(3), g(4), g(5), g(6));
  }
}

/// (stage, 0..1) of a long backup operation, for a percentage on screen.
typedef BackupProgress = void Function(String stage, double done);

class BackupRestoreFailure implements Exception {
  const BackupRestoreFailure(this.code, [this.detail]);

  /// key_needed | wrong_code | tampered | not_verified | no_set |
  /// apply_failed | no_space | not_a_backup
  final String code;
  final String? detail;
  @override
  String toString() => 'BackupRestoreFailure($code${detail == null ? '' : ': $detail'})';
}

/// Keeps every enabled space backed up: a background job every
/// [interval] (and on demand) writes the new changes to this device's
/// backup folder, then mirrors them to Cloudflare R2 when the cloud is on
/// and the device is online. Nothing here can block or fail the user's work.
class BackupCoordinator {
  BackupCoordinator({
    this.remoteFor,
    FlutterSecureStorage? vault,
    Future<Directory> Function()? root,
    this.interval = const Duration(minutes: 2),
    this.spaceCheckEvery = const Duration(seconds: 2),
  })  : _vault = vault ??
            const FlutterSecureStorage(
                aOptions: AndroidOptions(storageNamespace: 'fyona_backup_v2', resetOnError: false)),
        _root = root ?? (() async => Directory('${(await getApplicationSupportDirectory()).path}/backup_v2'));

  final BackupRemote Function(MediaSection section)? remoteFor;
  final FlutterSecureStorage _vault;
  final Future<Directory> Function() _root;
  final Duration interval;

  /// How often free space is watched during a rebuild.
  final Duration spaceCheckEvery;
  final _locks = <String, Lock>{};
  Timer? _timer;

  Lock _lock(String id) => _locks.putIfAbsent(id, Lock.new);
  String _prefKey(String id) => 'backup_v2_$id';

  Future<Directory> _sets(String id) async => Directory('${(await _root()).path}/$id/sets');

  Future<Map<String, dynamic>> _load(String id) async {
    final sp = await SharedPreferences.getInstance();
    final s = sp.getString(_prefKey(id));
    return s == null ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(s) as Map);
  }

  Future<void> _save(String id, Map<String, dynamic> m) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_prefKey(id), jsonEncode(m));
  }

  Future<BackupStatus> status(String id) async => BackupStatus(await _load(id));

  Future<Uint8List?> _key(String id) async {
    final s = await _vault.read(key: 'bk2-key-$id');
    return s == null ? null : base64Decode(s);
  }

  /// Turns continuous backup on. Returns the recovery code: shown ONCE to
  /// the user — with it (and only with it) a new device can open the
  /// backups. FYONA never stores it.
  Future<String> enable(BackupSpace space, {bool cloud = true, bool media = true, String? password}) =>
      _lock(space.id).synchronized(() async {
        final m = await _load(space.id);
        var raw = await _key(space.id);
        final key = raw == null ? await BackupKeys.newKey() : BackupKeys.keyFrom(raw);
        if (raw == null) {
          raw = await BackupKeys.keyBytes(key);
          await _vault.write(key: 'bk2-key-${space.id}', value: base64Encode(raw));
          if (await _key(space.id) == null) throw StateError('key store');
        }
        final code = BackupKeys.newRecoveryCode();
        // Argon2id is deliberately slow: off the UI isolate.
        m['wrapped'] = await _wrapOff(raw, code, password);
        m['enabled'] = true;
        m['cloud'] = cloud;
        m['media'] = media;
        // A new code means the next run starts a fresh set carrying it.
        (m['state'] as Map?)?.remove('id');
        await _save(space.id, m);
        return code;
      });

  Future<void> configure(String id, {bool? enabled, bool? cloud, bool? media}) => _lock(id).synchronized(() async {
        final m = await _load(id);
        if (enabled != null) m['enabled'] = enabled;
        if (cloud != null) m['cloud'] = cloud;
        if (media != null) m['media'] = media;
        await _save(id, m);
      });

  /// One backup run now (no-op when disabled or nothing changed).
  Future<BackupStatus> runNow(BackupSpace space, {bool force = false}) => _lock(space.id).synchronized(() async {
        final m = await _load(space.id);
        if (m['enabled'] != true && !force) return BackupStatus(m);
        final key = await _key(space.id);
        if (key == null || m['wrapped'] == null) {
          m['last_error'] = 'key_missing';
          await _save(space.id, m);
          return BackupStatus(m);
        }
        final sets = await _sets(space.id);
        final r = await runBackupJob(BackupJob(
          dbPath: space.dbPath,
          dbKeyHex: space.dbKeyHex,
          backupKey: key,
          wrappedKey: Map<String, dynamic>.from(m['wrapped'] as Map),
          scope: space.section.name,
          localRoot: sets.path,
          state: Map<String, dynamic>.from((m['state'] as Map?) ?? const {}),
          mediaRoot: m['media'] == false ? null : MediaStore.ready?.root.path,
          exclude: space.exclude,
          extras: space.extras == null ? null : await space.extras!(),
        ));
        m['state'] = r.state;
        if (r.error == null) {
          m['last_ok'] = DateTime.now().millisecondsSinceEpoch;
          m.remove('last_error');
          if (r.bytes > 0) m['last_bytes'] = r.bytes;
        } else {
          m['last_error'] = r.error;
        }
        await _save(space.id, m);
        if (m['cloud'] == true && r.backupId != null) await _push(space, m, sets, r.backupId!);
        return BackupStatus(m);
      });

  Future<void> _push(BackupSpace space, Map<String, dynamic> m, Directory sets, String backupId) async {
    final remote = remoteFor?.call(space.section);
    if (remote == null) return;
    final sent = Map<String, dynamic>.from((m['sent'] as Map?) ?? const {});
    final mine = Map<String, String>.from((sent[backupId] as Map?) ?? const {});
    final cloud = CloudBackupDestination(remote, temp: Directory('${sets.parent.path}/tmp'));
    try {
      await BackupMirror(cloud).push(Directory('${sets.path}/$backupId'), backupId, mine);
      m['cloud_ok'] = DateTime.now().millisecondsSinceEpoch;
      m.remove('cloud_error');
      // Older cloud sets the device no longer keeps are removed too.
      final keep = {for (final s in await LocalBackupDestination(sets).sets()) s};
      for (final old in sent.keys.where((k) => !keep.contains(k) && k != backupId).toList()) {
        try {
          await remote.delete(old);
          sent.remove(old);
        } catch (_) {}
      }
    } catch (e) {
      m['cloud_error'] = _short(e);
    } finally {
      sent[backupId] = mine;
      m['sent'] = sent;
      await _save(space.id, m);
    }
  }

  static String _short(Object e) {
    final s = '$e';
    return s.length > 160 ? s.substring(0, 160) : s;
  }

  /// Background schedule for the spaces [spaces] returns at each tick.
  void start(Future<List<BackupSpace>> Function() spaces) {
    _timer?.cancel();
    Future<void> tick() async {
      try {
        for (final s in await spaces()) {
          await runNow(s);
        }
      } catch (_) {}
    }

    _timer = Timer.periodic(interval, (_) => unawaited(tick()));
    unawaited(Future<void>.delayed(const Duration(seconds: 20), tick));
  }

  void stop() => _timer?.cancel();

  /// Sets on this device and in the cloud (complete ones only).
  Future<List<BackupSetInfo>> listSets(BackupSpace space) async {
    final local = (await LocalBackupDestination(await _sets(space.id)).sets()).toSet();
    final cloud = <String, int>{};
    final remote = remoteFor?.call(space.section);
    if (remote != null) {
      try {
        for (final b in await remote.list()) {
          if (b['complete'] == true) cloud['${b['backup_id']}'] = (b['bytes'] as num?)?.toInt() ?? 0;
        }
      } catch (_) {}
    }
    final ids = {...local, ...cloud.keys}.toList()..sort((a, b) => b.compareTo(a));
    return [for (final id in ids) BackupSetInfo(id: id, local: local.contains(id), cloud: cloud.containsKey(id), bytes: cloud[id] ?? 0)];
  }

  /// Rebuilds [set] into a NEW verified ledger file next to the live one.
  /// The key comes from this device's vault, else from [secret] (recovery
  /// code or password) with the set's wrapped key. Nothing live is touched:
  /// the caller applies the verified copy through the app's own restore.
  /// [onProgress]: (stage, 0..1) — `download`, `media`, `records`.
  Future<({String path, Map<String, dynamic>? extras})> rebuild(BackupSpace space, BackupSetInfo set,
      {String? secret, BackupProgress? onProgress}) async {
    final root = await _sets(space.id);
    var from = root;
    if (!set.local) {
      final remote = remoteFor?.call(space.section);
      if (remote == null) throw const BackupRestoreFailure('no_set');
      from = Directory('${root.parent.path}/download');
      if (await from.exists()) await from.delete(recursive: true);
      final mirror = BackupMirror(CloudBackupDestination(remote, temp: Directory('${root.parent.path}/tmp')));
      await mirror.pull(set.id, Directory('${from.path}/${set.id}'), const ['manifest.enc', 'key.json']);
    }
    final key = await _keyFor(space, from, set.id, secret == null ? null : () async => secret);
    if (!set.local) {
      // Now that the key opens the manifest, fetch exactly the listed parts.
      final man = await BackupRestorer(engine: _engine).manifest(
          LocalBackupDestination(from), set.id, BackupKeys.keyFrom(key));
      final parts = backupPartsOf(man);
      if (set.bytes > 0) await FreeSpace.require(root.parent.path, set.bytes + freeSpaceMargin);
      final remote = remoteFor!.call(space.section);
      final mirror = BackupMirror(CloudBackupDestination(remote, temp: Directory('${root.parent.path}/tmp')));
      final into = Directory('${from.path}/${set.id}');
      for (var i = 0; i < parts.length; i++) {
        await mirror.pull(set.id, into, [parts[i]]);
        onProgress?.call('download', (i + 1) / parts.length);
      }
    }
    return _rebuildFrom(space, from, set.id, key, onProgress);
  }

  /// The set's key: this device's own when it opens the manifest, else
  /// unwrapped from key.json with the secret [ask] returns.
  Future<Uint8List> _keyFor(BackupSpace space, Directory from, String id, Future<String?> Function()? ask) async {
    final own = await _key(space.id);
    if (own != null && await _opens(from, id, own)) return own;
    final secret = ask == null ? null : await ask();
    if (secret == null || secret.isEmpty) throw const BackupRestoreFailure('key_needed');
    final kj = File('${from.path}/$id/key.json');
    if (!await kj.exists() || await kj.length() > 1024 * 1024) throw const BackupRestoreFailure('no_set');
    final Object? w;
    try {
      w = jsonDecode(await kj.readAsString());
    } on FormatException {
      throw const BackupRestoreFailure('not_a_backup');
    }
    if (w is! Map) throw const BackupRestoreFailure('not_a_backup');
    final wraps = [for (final v in w.values) if (v is Map) Map<String, dynamic>.from(v)];
    final found = await _unwrapOff(wraps, secret);
    if (found == null || !await _opens(from, id, found)) throw const BackupRestoreFailure('wrong_code');
    return found;
  }

  Future<({String path, Map<String, dynamic>? extras})> _rebuildFrom(
      BackupSpace space, Directory from, String id, Uint8List key, BackupProgress? onProgress) async {
    // Leftovers of an interrupted earlier restore are never reused.
    await _sweepRestores(space);
    final setDir = Directory('${from.path}/$id');
    var media = 0, records = 0;
    await for (final f in setDir.list()) {
      if (f is! File) continue;
      final n = f.uri.pathSegments.last;
      if (n.startsWith('m-')) {
        media += await f.length();
      } else {
        records += await f.length();
      }
    }
    // Staged media + the new ledger (records expand when unpacked; the
    // monitor below stops cleanly if that is still not enough).
    final ledgerDir = File(space.dbPath).parent.path;
    await FreeSpace.require(ledgerDir, media + 4 * records + freeSpaceMargin);
    final target = '${space.dbPath}.restore-${DateTime.now().millisecondsSinceEpoch}';
    final root = await _sets(space.id);
    final work = Directory('${root.parent.path}/restore-work');
    await work.create(recursive: true);
    final stop = File('${work.parent.path}/restore-stop');
    if (await stop.exists()) await stop.delete();
    final watch = Timer.periodic(spaceCheckEvery, (_) async {
      final free = await FreeSpace.of(ledgerDir);
      if (free != null && free < freeSpaceMargin ~/ 2 && !stop.existsSync()) stop.createSync(recursive: true);
    });
    final RestoreOutcome out;
    try {
      out = await runRestoreJob(
        workRoot: work.path,
        setRoot: from.path,
        backupId: id,
        backupKey: key,
        targetPath: target,
        dbKeyHex: space.dbKeyHex,
        mediaRoot: MediaStore.ready?.root.path,
        exclude: space.exclude,
        onProgress: onProgress,
        stopFile: stop.path,
      );
    } finally {
      watch.cancel();
      if (await stop.exists()) await stop.delete();
    }
    if (out.problems.isNotEmpty) {
      final f = File(target);
      if (f.existsSync()) f.deleteSync();
      final first = out.problems.first;
      throw BackupRestoreFailure(
          first == 'no_space' ? 'no_space' : first.startsWith('tampered') ? 'tampered' : 'not_verified',
          out.problems.join('; '));
    }
    return (path: target, extras: out.extras);
  }

  /// Saves the local set [set] as ONE file [out] (see backup_pack.dart) the
  /// user can keep on the phone and restore from without the cloud. The
  /// file holds the set exactly as backed up: encrypted, and opened only
  /// with this device's key or the recovery code / password.
  Future<int> exportToFile(BackupSpace space, BackupSetInfo set, File out, {BackupProgress? onProgress}) =>
      _lock(space.id).synchronized(() async {
        if (!set.local) throw const BackupRestoreFailure('no_set');
        final key = await _key(space.id);
        if (key == null) throw const BackupRestoreFailure('key_needed');
        final root = await _sets(space.id);
        final man = await BackupRestorer(engine: _engine)
            .manifest(LocalBackupDestination(root), set.id, BackupKeys.keyFrom(key));
        final names = backupPartsOf(man);
        var bytes = 0;
        for (final n in ['key.json', 'manifest.enc', ...names]) {
          final f = File('${root.path}/${set.id}/$n');
          if (!await f.exists()) throw const BackupRestoreFailure('no_set');
          bytes += await f.length();
        }
        await out.parent.create(recursive: true);
        await FreeSpace.require(out.parent.path, bytes + freeSpaceMargin);
        return writeBackupPack(Directory('${root.path}/${set.id}'), set.id, names, out,
            onProgress: (d, t) => onProgress?.call('saving', t == 0 ? 1 : d / t));
      });

  /// Restores from a backup file the user picked (made by [exportToFile],
  /// on this or another device). Only its small index is read before the
  /// key opens it ([askSecret] is asked when this device's key does not);
  /// then exactly the parts it lists are copied, checked for room first,
  /// and rebuilt like any set. Returns the verified copy to apply.
  Future<({String path, Map<String, dynamic>? extras})> importFile(BackupSpace space, Stream<List<int>> input,
      {int? size, Future<String?> Function()? askSecret, BackupProgress? onProgress}) async {
    final root = await _sets(space.id);
    final dir = Directory('${root.parent.path}/imported');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    if (size != null) {
      if (size > backupPackMaxBytes) throw const BackupRestoreFailure('not_a_backup');
      await FreeSpace.require(dir.path, size + freeSpaceMargin);
    }
    try {
      Uint8List? key;
      final String id;
      try {
        id = await readBackupPack(input, dir,
            authenticate: (id, setDir) async {
              key = await _keyFor(space, dir, id, askSecret);
              final man = await BackupRestorer(engine: _engine)
                  .manifest(LocalBackupDestination(dir), id, BackupKeys.keyFrom(key!));
              return backupPartsOf(man).toSet();
            },
            beforeBulk: (rest) => FreeSpace.require(dir.path, rest + freeSpaceMargin),
            onProgress: (d, t) => onProgress?.call('reading', t == 0 ? 1 : d / t));
      } on BackupPackRejected {
        throw const BackupRestoreFailure('not_a_backup');
      } on BackupTampered {
        throw const BackupRestoreFailure('tampered');
      }
      return await _rebuildFrom(space, dir, id, key!, onProgress);
    } finally {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  static final _engine = BackupEngine();

  Future<void> _sweepRestores(BackupSpace space) async {
    final dir = File(space.dbPath).parent;
    final name = File(space.dbPath).uri.pathSegments.last;
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      final n = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (e is File && n.startsWith('$name.restore-')) await e.delete();
      if (e is Directory && n.startsWith('bk2-apply-')) await e.delete(recursive: true);
    }
  }

  Future<bool> _opens(Directory from, String id, Uint8List key) async {
    try {
      await BackupRestorer(engine: _engine).manifest(LocalBackupDestination(from), id, BackupKeys.keyFrom(key));
      return true;
    } catch (_) {
      return false;
    }
  }
}

// Top-level so the isolate receives only plain values.
Future<Map<String, dynamic>> _wrapOff(Uint8List key, String code, String? password) => Isolate.run(() async => {
      'recovery': await BackupKeys.wrap(BackupKeys.keyFrom(key), code),
      if (password != null && password.isNotEmpty)
        'password': await BackupKeys.wrap(BackupKeys.keyFrom(key), password, kind: 'password'),
    });

Future<Uint8List?> _unwrapOff(List<Map<String, dynamic>> wraps, String secret) => Isolate.run(() async {
      for (final v in wraps) {
        final k = await BackupKeys.unwrap(v, secret);
        if (k != null) return BackupKeys.keyBytes(k);
      }
      return null;
    });
