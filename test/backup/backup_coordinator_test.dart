import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/backup/backup_cloud.dart';
import 'package:fyona_flutter/core/backup/account_backup_keys.dart';
import 'package:fyona_flutter/core/backup/backup_coordinator.dart';
import 'package:fyona_flutter/core/backup/backup_crypto.dart';
import 'package:fyona_flutter/core/backup/device_backup_folder.dart';
import 'package:cryptography/cryptography.dart';
import 'package:fyona_flutter/core/backup/backup_pack.dart';
import 'package:fyona_flutter/core/storage/free_space.dart';
import 'package:fyona_flutter/core/backup/backup_worker.dart';
import 'package:fyona_flutter/core/media/media_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Server + R2 stand-in: a private object store per tenant, signed-URL
/// style (real HTTP PUT/GET through the app's transfer code).
class FakeCloud implements BackupRemote {
  FakeCloud._(this._server);
  final HttpServer _server;
  final objects = <String, Uint8List>{};
  bool down = false;

  static Future<FakeCloud> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final c = FakeCloud._(s);
    s.listen((req) async {
      final key = req.uri.path.substring(1);
      if (req.method == 'PUT') {
        final b = BytesBuilder();
        await for (final x in req) {
          b.add(x);
        }
        c.objects[key] = b.takeBytes();
      } else {
        final o = c.objects[key];
        if (o == null) {
          req.response.statusCode = 404;
        } else {
          req.response.add(o);
        }
      }
      await req.response.close();
    });
    return c;
  }

  String _u(String id, String part) => 'http://127.0.0.1:${_server.port}/b/$id/$part';
  void _check() {
    if (down) throw const SocketException('offline');
  }

  @override
  Future<String> uploadUrl(String backupId, String part, int size) async {
    _check();
    return _u(backupId, part);
  }
  @override
  Future<String> downloadUrl(String backupId, String part) async {
    _check();
    return _u(backupId, part);
  }
  @override
  Future<List<Map<String, dynamic>>> list() async {
    _check();
    final ids = {for (final k in objects.keys) k.split('/')[1]};
    return [for (final id in ids) {'backup_id': id, 'complete': objects.containsKey('b/$id/manifest.enc')}];
  }

  @override
  Future<void> delete(String backupId) async => objects.removeWhere((k, _) => k.startsWith('b/$backupId/'));
  Future<void> close() => _server.close(force: true);
}

void main() {
  sqfliteFfiInit();
  late Directory dir;
  late FakeCloud cloud;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('fyona-bkc-');
    cloud = await FakeCloud.start();
  });
  tearDown(() async {
    FreeSpace.probe = null;
    await cloud.close();
    await dir.delete(recursive: true);
  });

  Future<BackupSpace> space() async {
    final path = '${dir.path}/ledger.sqlite';
    final db = await openLedgerFile(path, '', create: true);
    await db.execute('CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, v TEXT, amount INTEGER)');
    await db.close();
    return BackupSpace(id: 'p-test', section: MediaSection.personal, dbPath: path, dbKeyHex: '');
  }

  Future<void> write(String path, String sql) async {
    final db = await openLedgerFile(path, '');
    await db.execute(sql);
    await db.close();
  }

  test('on, backed up to device + cloud; a new device opens it only with the recovery code', () async {
    final s = await space();
    final c = BackupCoordinator(remoteFor: (_) => cloud, root: () async => Directory('${dir.path}/device1'));
    final code = await c.enable(s, password: 'p@ss-1');
    await write(s.dbPath, "INSERT INTO t VALUES (1, 'رصيد', 125000)");
    var st = await c.runNow(s);
    expect(st.lastError, isNull);
    expect(st.cloudError, isNull);
    await write(s.dbPath, 'UPDATE t SET amount = amount - 500 WHERE id = 1');
    st = await c.runNow(s);
    expect(cloud.objects.keys.any((k) => k.endsWith('manifest.enc')), isTrue);
    // Nothing readable in the cloud.
    for (final o in cloud.objects.values) {
      expect(String.fromCharCodes(o).contains('رصيد'), isFalse);
    }

    // New device: empty vault, nothing local, only the cloud.
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final c2 = BackupCoordinator(remoteFor: (_) => cloud, root: () async => Directory('${dir.path}/device2'));
    final sets = await c2.listSets(s);
    expect(sets.single.cloud, isTrue);
    expect(sets.single.local, isFalse);
    await expectLater(c2.rebuild(s, sets.single), throwsA(isA<BackupRestoreFailure>().having((e) => e.code, 'code', 'key_needed')));
    await expectLater(c2.rebuild(s, sets.single, secret: 'AAAA-BBBB-CCCC-DDDD-EEEE-FFFF'),
        throwsA(isA<BackupRestoreFailure>().having((e) => e.code, 'code', 'wrong_code')));
    for (final secret in [code.toLowerCase(), 'p@ss-1']) {
      final copy = await c2.rebuild(s, sets.single, secret: secret);
      final db = await openLedgerFile(copy.path, '');
      expect(await db.rawQuery('SELECT * FROM t'), [{'id': 1, 'v': 'رصيد', 'amount': 124500}]);
      await db.close();
      File(copy.path).deleteSync();
    }
  });

  test('cloud down: device copy still made, cloud catches up later; turning off stops runs', () async {
    final s = await space();
    final c = BackupCoordinator(remoteFor: (_) => cloud, root: () async => Directory('${dir.path}/d'));
    await c.enable(s);
    cloud.down = true;
    await write(s.dbPath, "INSERT INTO t VALUES (2, 'x', 1)");
    var st = await c.runNow(s);
    expect(st.lastError, isNull);
    expect(st.cloudError, isNotNull);
    expect((await c.listSets(s)).single.local, isTrue);
    cloud.down = false;
    await write(s.dbPath, "INSERT INTO t VALUES (3, 'y', 2)");
    st = await c.runNow(s);
    expect(st.cloudError, isNull);
    final sets = await c.listSets(s);
    expect(sets.single.local && sets.single.cloud, isTrue);
    await c.configure(s.id, enabled: false);
    final before = (await c.status(s.id)).lastOkAt;
    await write(s.dbPath, "INSERT INTO t VALUES (4, 'z', 3)");
    expect((await c.runNow(s)).lastOkAt, before);
  });

  group('backup kept as ONE file on the phone (no cloud)', () {
    Future<(BackupSpace, BackupCoordinator, String, File)> made() async {
      final s = await space();
      final c = BackupCoordinator(root: () async => Directory('${dir.path}/phone1'));
      final code = await c.enable(s, cloud: false);
      await write(s.dbPath, "INSERT INTO t VALUES (1, 'رصيد افتتاحي', 125000)");
      await write(s.dbPath, "WITH RECURSIVE n(v) AS (SELECT 1 UNION ALL SELECT v + 1 FROM n WHERE v < 3000) "
          "INSERT INTO t SELECT 1 + v, hex(randomblob(400)), v FROM n");
      expect((await c.runNow(s)).lastError, isNull);
      await write(s.dbPath, 'UPDATE t SET amount = amount - 500 WHERE id = 1');
      expect((await c.runNow(s)).lastError, isNull);
      final set = (await c.listSets(s)).single;
      final out = File('${dir.path}/Download/fyona.$backupPackExtension');
      final steps = <double>[];
      final size = await c.exportToFile(s, set, out, onProgress: (_, d) => steps.add(d));
      expect(size, out.lengthSync());
      expect(steps.last, 1.0);
      // Nothing readable in the file.
      expect(latin1.decode(out.readAsBytesSync()).contains('125000'), isFalse);
      return (s, c, code, out);
    }

    /// A new phone: empty vault and settings, no cloud.
    BackupCoordinator newPhone() {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      return BackupCoordinator(root: () async => Directory('${dir.path}/phone2'));
    }

    /// The file as the picker streams it, counting the bytes read.
    (Stream<List<int>>, int Function()) stream(File f) {
      var read = 0;
      return (f.openRead().map((b) {
        read += b.length;
        return b;
      }), () => read);
    }

    Future<List<Map<String, Object?>>> rows(String path) async {
      final db = await openLedgerFile(path, '');
      try {
        return await db.rawQuery('SELECT id, amount FROM t WHERE id = 1');
      } finally {
        await db.close();
      }
    }

    test('restores on a new phone with the recovery code, with progress', () async {
      final (s, _, code, file) = await made();
      final c2 = newPhone();
      final stages = <String, double>{};
      var asked = 0;
      final copy = await c2.importFile(s, file.openRead(), size: file.lengthSync(),
          askSecret: () async {
            asked++;
            return code;
          },
          onProgress: (st, d) => stages[st] = d);
      expect(asked, 1);
      expect(await rows(copy.path), [{'id': 1, 'amount': 124500}]);
      expect(stages['reading'], 1.0);
      expect(stages['records'], 1.0);
      File(copy.path).deleteSync();
      // Nothing of the file is left in the app's folders.
      expect(Directory('${dir.path}/phone2/imported').existsSync(), isFalse);
    });

    test('the same phone opens it with its own key (no code asked)', () async {
      final (s, c, _, file) = await made();
      final copy = await c.importFile(s, file.openRead(), askSecret: () async => fail('asked'));
      expect(await rows(copy.path), [{'id': 1, 'amount': 124500}]);
      File(copy.path).deleteSync();
    });

    test('wrong code: refused after reading only the small index', () async {
      final (s, _, _, file) = await made();
      final c2 = newPhone();
      final (input, read) = stream(file);
      await expectLater(c2.importFile(s, input, askSecret: () async => 'AAAA-BBBB-CCCC-DDDD-EEEE-FFFF'),
          throwsA(isA<BackupRestoreFailure>().having((e) => e.code, 'code', 'wrong_code')));
      expect(read(), lessThan(file.lengthSync() ~/ 2));
      expect(Directory('${dir.path}/phone2/imported').existsSync(), isFalse);
    });

    test('not a FYONA file, truncated, altered, or a part the manifest does not list: refused', () async {
      final (s, _, code, file) = await made();
      final c2 = newPhone();
      Future<void> refused(List<int> bytes, String want) => expectLater(
          c2.importFile(s, Stream.value(bytes), askSecret: () async => code),
          throwsA(isA<BackupRestoreFailure>().having((e) => e.code, 'code', want)));
      final good = file.readAsBytesSync();
      await refused(utf8.encode('PK\x03\x04 not a backup' * 100), 'not_a_backup');
      await refused(good.sublist(0, good.length - 10), 'not_a_backup');
      final altered = Uint8List.fromList(good)..[good.length - 100] ^= 1;
      await expectLater(c2.importFile(s, Stream.value(altered), askSecret: () async => code),
          throwsA(isA<BackupRestoreFailure>().having((e) => e.code, 'code', anyOf('tampered', 'not_verified'))));
      // Header naming an extra part (path tricks are refused by name too).
      final len = ByteData.sublistView(good, 10, 14).getUint32(0);
      final header = jsonDecode(utf8.decode(good.sublist(14, 14 + len))) as Map;
      for (final name in ['extra.fybk', '../../evil.fybk']) {
        final h = Map.of(header)..['files'] = [...header['files'] as List, {'n': name, 's': 3}];
        final hb = utf8.encode(jsonEncode(h));
        await refused([...good.sublist(0, 10), ...(ByteData(4)..setUint32(0, hb.length)).buffer.asUint8List(), ...hb,
          ...good.sublist(14 + len), 1, 2, 3], 'not_a_backup');
      }
      expect(Directory('${dir.path}/phone2/imported').existsSync(), isFalse);
      expect(File('${dir.path}/evil.fybk').existsSync(), isFalse);
    });

    test('not enough free space: refused before copying, nothing changed', () async {
      final (s, _, code, file) = await made();
      final c2 = newPhone();
      FreeSpace.probe = (_) async => 10 * 1024 * 1024;
      final (input, read) = stream(file);
      await expectLater(c2.importFile(s, input, size: file.lengthSync(), askSecret: () async => code),
          throwsA(isA<NotEnoughSpace>().having((e) => e.missingMb, 'missing MB', greaterThan(100))));
      expect(read(), 0);
      FreeSpace.probe = null;
      // Size unknown (some pickers): checked once the index proves the file.
      FreeSpace.probe = (_) async => 10 * 1024 * 1024;
      final (input2, read2) = stream(file);
      await expectLater(c2.importFile(s, input2, askSecret: () async => code), throwsA(isA<NotEnoughSpace>()));
      expect(read2(), lessThan(file.lengthSync()));
      expect(Directory('${dir.path}/phone2/imported').existsSync(), isFalse);
    });

    test('disk fills up during the rebuild: stopped cleanly, nothing left', () async {
      final (s, _, code, file) = await made();
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final c2 = BackupCoordinator(
          root: () async => Directory('${dir.path}/phone2'), spaceCheckEvery: const Duration(milliseconds: 1));
      var calls = 0;
      // Room for the checks before starting; then the disk is nearly full.
      FreeSpace.probe = (_) async => ++calls <= 2 ? 1 << 40 : 1024;
      await expectLater(c2.importFile(s, file.openRead(), askSecret: () async => code),
          throwsA(isA<BackupRestoreFailure>().having((e) => e.code, 'code', 'no_space')));
      final left = Directory(dir.path).listSync().where((f) => f.path.contains('.restore-'));
      expect(left, isEmpty);
      expect(Directory('${dir.path}/phone2/imported').existsSync(), isFalse);
      expect(File('${dir.path}/phone2/restore-stop').existsSync(), isFalse);
    });
  });

  group('no code: the account key (server-derived) opens the backups', () {
    final accountA = SecretKey(List.generate(32, (i) => i));
    final accountB = SecretKey(List.generate(32, (i) => 100 + i));

    Future<BackupSpace> spaceWith(SecretKey? account) async {
      final s0 = await space();
      return BackupSpace(id: s0.id, section: s0.section, dbPath: s0.dbPath, dbKeyHex: '',
          accountKey: () async => account);
    }

    test('a new device restores from the cloud with NO code; another account cannot', () async {
      final s = await spaceWith(accountA);
      final c = BackupCoordinator(remoteFor: (_) => cloud, root: () async => Directory('${dir.path}/phoneA'));
      await c.ensureEnabled(s);
      await write(s.dbPath, "INSERT INTO t VALUES (1, 'رصيد', 125000)");
      expect((await c.runNow(s)).cloudError, isNull);
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final c2 = BackupCoordinator(remoteFor: (_) => cloud, root: () async => Directory('${dir.path}/phoneB'));
      final set = (await c2.listSets(s)).single;
      final copy = await c2.rebuild(s, set); // no secret at all
      final db = await openLedgerFile(copy.path, '');
      expect(await db.rawQuery('SELECT amount FROM t'), [{'amount': 125000}]);
      await db.close();
      final other = await spaceWith(accountB);
      await expectLater(c2.rebuild(other, set),
          throwsA(isA<BackupRestoreFailure>().having((e) => e.code, 'code', 'key_needed')));
    });

    test('a space enabled before account keys gets them on its next run (new set)', () async {
      final old = await spaceWith(null);
      final c = BackupCoordinator(remoteFor: (_) => cloud, root: () async => Directory('${dir.path}/p'));
      await c.enable(old); // recovery code only (older app)
      await write(old.dbPath, "INSERT INTO t VALUES (2, 'x', 5)");
      await c.runNow(old);
      final first = (await c.listSets(old)).single.id;
      final s = await spaceWith(accountA);
      await write(s.dbPath, "INSERT INTO t VALUES (3, 'y', 6)");
      await c.runNow(s);
      final sets = await c.listSets(s);
      final fresh = sets.map((e) => e.id).where((id) => id != first).single;
      final kj = jsonDecode(File('${dir.path}/p/${s.id}/sets/$fresh/key.json').readAsStringSync()) as Map;
      expect(kj['account'], isNotNull);
      expect(await BackupKeys.unwrapForAccount(Map<String, dynamic>.from(kj['account'] as Map), accountA), isNotNull);
    });

    test('automatic backup on: the newest file in the FYONA folder follows the data; off: it does not', () async {
      final folder = Directory('${dir.path}/Download/FYONA ERP');
      DeviceBackupFolder.folderOverride = () async => folder;
      addTearDown(() => DeviceBackupFolder.folderOverride = null);
      final s = await spaceWith(accountA);
      final c = BackupCoordinator(root: () async => Directory('${dir.path}/auto'), deviceEvery: Duration.zero);
      await c.ensureEnabled(s);
      await c.configure(s.id, cloud: false);
      await write(s.dbPath, "INSERT INTO t VALUES (20, 'v', 1)");
      await c.runNow(s);
      expect(await c.refreshDeviceFile(s), isNotNull); // first file
      final first = (await c.deviceFiles(s)).single;
      // Nothing new: no new file.
      await c.runNow(s);
      expect(await c.refreshDeviceFile(s), isNull);
      // The user enters data: the next schedule tick writes a fresh file
      // holding it (bigger, newer).
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      for (var i = 0; i < 300; i++) {
        await write(s.dbPath, "INSERT INTO t VALUES (${100 + i}, '${'x' * 200}', $i)");
      }
      await c.runNow(s);
      final fresh = await c.refreshDeviceFile(s);
      expect(fresh, isNotNull);
      expect(fresh!.name, isNot(first.name));
      expect(fresh.size, greaterThan(first.size));
      // Automatic backup off: changes do not touch the folder.
      await c.configure(s.id, enabled: false);
      await write(s.dbPath, "INSERT INTO t VALUES (999, 'z', 1)");
      await c.runNow(s);
      expect(await c.refreshDeviceFile(s), isNull);
    });

    test('a cloud backup deleted by the user is gone; the next run starts a complete new one', () async {
      final s = await spaceWith(accountA);
      final c = BackupCoordinator(remoteFor: (_) => cloud, root: () async => Directory('${dir.path}/del'));
      await c.ensureEnabled(s);
      await write(s.dbPath, "INSERT INTO t VALUES (40, 'v', 1)");
      await c.runNow(s);
      final set = (await c.listSets(s)).firstWhere((x) => x.cloud);
      await c.deleteCloudSet(s, set.id);
      expect(cloud.objects.keys.where((k) => k.contains(set.id)), isEmpty);
      await write(s.dbPath, "INSERT INTO t VALUES (41, 'v', 2)");
      await c.runNow(s);
      final again = (await c.listSets(s)).where((x) => x.cloud).toList();
      expect(again.single.id, isNot(set.id)); // a new, complete set
      final copy = await c.rebuild(s, again.single);
      final db = await openLedgerFile(copy.path, '');
      expect((await db.rawQuery('SELECT COUNT(*) AS n FROM t WHERE id >= 40')).single['n'], 2);
      await db.close();
    });

    test('backup kept in the FYONA folder; listed, numbered and restored there', () async {
      final folder = Directory('${dir.path}/Download/FYONA ERP');
      DeviceBackupFolder.folderOverride = () async => folder;
      addTearDown(() => DeviceBackupFolder.folderOverride = null);
      final s = await spaceWith(accountA);
      final c = BackupCoordinator(root: () async => Directory('${dir.path}/phone1'));
      await c.ensureEnabled(s);
      await c.configure(s.id, cloud: false);
      for (var i = 0; i < 5; i++) {
        await write(s.dbPath, "INSERT INTO t VALUES (${10 + i}, 'v', $i)");
        await c.runNow(s, force: true);
        await c.saveToDevice(s);
        await Future<void>.delayed(const Duration(milliseconds: 1100)); // distinct names
      }
      final files = await c.deviceFiles(s);
      expect(files.length, 3); // the 3 newest kept
      // A new phone (app reinstalled): the folder is still there.
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final c2 = BackupCoordinator(root: () async => Directory('${dir.path}/phone2'));
      final copy = await c2.restoreDeviceFile(s, files.first);
      final db = await openLedgerFile(copy.path, '');
      expect((await db.rawQuery('SELECT COUNT(*) AS n FROM t WHERE id >= 10')).single['n'], 5);
      await db.close();
    });
  });

  test('a personal backup text is encrypted with the account key; older plain text still reads', () async {
    final k = SecretKey(List.filled(32, 9));
    const plain = '{"schema_version":"4.0.0","rows":"سري"}';
    final sealed = await BackupEnvelope.sealText(plain, k);
    expect(BackupEnvelope.isSealedText(sealed), isTrue);
    expect(sealed.contains('سري'), isFalse);
    expect(await BackupEnvelope.openText(sealed, k), plain);
    expect(BackupEnvelope.isSealedText(plain), isFalse);
    await expectLater(BackupEnvelope.openText(sealed, SecretKey(List.filled(32, 8))), throwsA(anything));
  });
}
