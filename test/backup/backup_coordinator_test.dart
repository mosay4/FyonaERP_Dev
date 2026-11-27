import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/backup/backup_cloud.dart';
import 'package:fyona_flutter/core/backup/backup_coordinator.dart';
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
}
