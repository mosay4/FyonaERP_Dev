import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/backup/backup_crypto.dart';
import 'package:fyona_flutter/core/backup/backup_engine.dart';
import 'package:fyona_flutter/core/backup/backup_service.dart';
import 'package:fyona_flutter/core/media/media_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A destination that can go offline (the cloud without internet).
class FlakyDestination extends LocalBackupDestination {
  FlakyDestination(super.root, this._id);
  final String _id;
  bool down = false;
  @override
  String get id => _id;
  @override
  Future<void> put(String b, String p, Uint8List d) => down ? throw const SocketException('offline') : super.put(b, p, d);
  @override
  Future<Uint8List?> get(String b, String p) => down ? throw const SocketException('offline') : super.get(b, p);
  @override
  Future<void> putFile(String b, String p, File f, {bool move = false}) =>
      down ? throw const SocketException('offline') : super.putFile(b, p, f, move: move);
  @override
  Future<bool> getFile(String b, String p, File f) => down ? throw const SocketException('offline') : super.getFile(b, p, f);
  @override
  Future<bool> has(String b, String p) => down ? throw const SocketException('offline') : super.has(b, p);
}

void main() {
  sqfliteFfiInit();
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('fyona-bks-'));
  tearDown(() => dir.delete(recursive: true));

  Future<Database> seeded(String name) async {
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/$name');
    await db.execute('CREATE TABLE accounts (id INTEGER PRIMARY KEY, name TEXT, balance_minor INTEGER, image TEXT)');
    for (var i = 1; i <= 200; i++) {
      await db.insert('accounts', {'id': i, 'name': 'حساب $i', 'balance_minor': i * 1000});
    }
    return db;
  }

  Future<String> dump(Database db) async => (await db.rawQuery('SELECT * FROM accounts ORDER BY id')).toString();

  test('continuous backup: every run carries only the new changes, restore is exact', () async {
    final engine = BackupEngine();
    final db = await seeded('a.db');
    await engine.install(db);
    final key = await BackupKeys.newKey();
    final local = LocalBackupDestination(Directory('${dir.path}/local'));
    final svc = BackupService(engine: engine, key: key, wrappedKey: await BackupKeys.wrap(key, 'X', memory: 1024, iterations: 1),
        destinations: [local], scope: 'personal:test');
    final state = BackupState();
    final first = await svc.run(db, state);
    expect(first.newSet, isTrue);
    await db.rawUpdate('UPDATE accounts SET balance_minor = balance_minor - 50 WHERE id = 7');
    final second = await svc.run(db, state);
    expect(second.newSet, isFalse);
    expect(second.changes, 1);
    expect((await svc.run(db, state)).changes, 0, reason: 'nothing new, nothing sent');
    // Captured changes every destination holds are cleared from the device.
    expect((await db.rawQuery('SELECT COUNT(*) AS n FROM ${BackupEngine.changes}')).first['n'], 0);

    // State survives a restart (persisted as JSON).
    final again = BackupState.fromJson(state.toJson());
    await db.insert('accounts', {'id': 999, 'name': 'جديد', 'balance_minor': 5});
    await svc.run(db, again);

    final target = await databaseFactoryFfi.openDatabase('${dir.path}/restored.db');
    final problems = await BackupRestorer(engine: engine).restore(local, again.backupId!, key, target);
    expect(problems, isEmpty);
    expect(await dump(target), await dump(db));
  });

  test('cloud offline: the device copy still works, the cloud catches up later, restore from cloud is exact', () async {
    final engine = BackupEngine();
    final db = await seeded('b.db');
    await engine.install(db);
    final key = await BackupKeys.newKey();
    final local = LocalBackupDestination(Directory('${dir.path}/local'));
    final cloud = FlakyDestination(Directory('${dir.path}/cloud'), 'r2');
    final svc = BackupService(engine: engine, key: key, wrappedKey: const {}, destinations: [local, cloud], scope: 's');
    final state = BackupState();
    await svc.run(db, state);
    cloud.down = true;
    await db.rawUpdate('UPDATE accounts SET balance_minor = 1 WHERE id = 1');
    final r = await svc.run(db, state);
    expect(r.destinations, ['local']);
    expect(r.failed.keys, ['r2']);
    // Not cleared: the cloud still needs these changes.
    expect((await db.rawQuery('SELECT COUNT(*) AS n FROM ${BackupEngine.changes}')).first['n'], greaterThan(0));
    cloud.down = false;
    await db.rawUpdate('UPDATE accounts SET balance_minor = 2 WHERE id = 2');
    final r2 = await svc.run(db, state);
    expect(r2.destinations, ['local', 'r2']);
    final target = await databaseFactoryFfi.openDatabase('${dir.path}/from-cloud.db');
    expect(await BackupRestorer(engine: engine).restore(cloud, state.backupId!, key, target), isEmpty);
    expect(await dump(target), await dump(db));
  });

  test('a backup interrupted before its manifest is not offered for restore', () async {
    final local = LocalBackupDestination(Directory('${dir.path}/local'));
    await local.put('bk-half', 's.fybk', Uint8List(10));
    expect(await local.sets(), isEmpty);
    // A leftover temp file from a crash is never read as a part.
    File('${dir.path}/local/bk-half/manifest.enc.tmp').writeAsBytesSync([1, 2, 3]);
    expect(await local.sets(), isEmpty);
  });

  test('a missing or altered part stops the restore before anything is used', () async {
    final engine = BackupEngine();
    final db = await seeded('c.db');
    await engine.install(db);
    final key = await BackupKeys.newKey();
    final local = LocalBackupDestination(Directory('${dir.path}/local'));
    final svc = BackupService(engine: engine, key: key, wrappedKey: const {}, destinations: [local], scope: 's');
    final state = BackupState();
    await svc.run(db, state);
    await db.rawUpdate('UPDATE accounts SET balance_minor = 3 WHERE id = 3');
    await svc.run(db, state);
    final delta = File('${dir.path}/local/${state.backupId}/${state.deltas.single['name']}');
    final bytes = delta.readAsBytesSync()..[40] ^= 1;
    delta.writeAsBytesSync(bytes);
    final target = await databaseFactoryFfi.openDatabase('${dir.path}/t.db');
    await expectLater(BackupRestorer(engine: engine).restore(local, state.backupId!, key, target),
        throwsA(isA<BackupTampered>()));
    expect((await target.rawQuery("SELECT COUNT(*) AS n FROM sqlite_schema WHERE type='table'")).first['n'], 0);
    delta.deleteSync();
    await expectLater(BackupRestorer(engine: engine).restore(local, state.backupId!, key, target),
        throwsA(isA<BackupTampered>()));
  });

  test('photos go inside the backup and come back verified on a new device', () async {
    final engine = BackupEngine();
    final db = await seeded('d.db');
    await engine.install(db);
    final store = MediaStore(Directory('${dir.path}/media'));
    final img = Uint8List.fromList([0xFF, 0xD8, 0xFF, ...List.generate(5000, (i) => i % 256)]);
    final ref = await store.put(img, mime: 'image/jpeg');
    await db.rawUpdate('UPDATE accounts SET image = ? WHERE id = 5', [ref]);
    final key = await BackupKeys.newKey();
    final local = LocalBackupDestination(Directory('${dir.path}/local'));
    final state = BackupState();
    await BackupService(engine: engine, key: key, wrappedKey: const {}, destinations: [local], scope: 's', media: store)
        .run(db, state);
    final newDevice = MediaStore(Directory('${dir.path}/media2'));
    final target = await databaseFactoryFfi.openDatabase('${dir.path}/e.db');
    expect(await BackupRestorer(engine: engine).restore(local, state.backupId!, key, target, mediaStore: newDevice), isEmpty);
    expect(newDevice.readSync(ref), img);
  });

  test('old sets are pruned: only the newest are kept', () async {
    var clock = 0;
    final engine = BackupEngine();
    final db = await seeded('f.db');
    await engine.install(db);
    final key = await BackupKeys.newKey();
    final local = LocalBackupDestination(Directory('${dir.path}/local'));
    final svc = BackupService(engine: engine, key: key, wrappedKey: const {}, destinations: [local], scope: 's',
        keepSets: 2, setAge: const Duration(days: 1), now: () => clock);
    final state = BackupState();
    for (var day = 0; day < 4; day++) {
      clock = day * 2 * 86400000 + 1000;
      await db.rawUpdate('UPDATE accounts SET balance_minor = ? WHERE id = 1', [day]);
      await svc.run(db, state);
    }
    expect((await local.sets()).length, 2);
    expect((await local.sets()).last, state.backupId);
  });
}
