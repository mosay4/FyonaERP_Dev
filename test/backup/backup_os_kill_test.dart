import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/backup/backup_crypto.dart';
import 'package:fyona_flutter/core/backup/backup_service.dart';
import 'package:fyona_flutter/core/backup/backup_worker.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A real force-kill: the backup runs in another OS process that is killed
/// with SIGKILL (no cleanup, no flush) at random moments, five times. After
/// every kill, every backup set the app would offer must open and verify,
/// and a final run must restore exactly the live data.
/// Opt-in (it compiles a child test): FYONA_OS_KILL_TEST=1, Linux.
void main() {
  final enabled = Platform.environment['FYONA_OS_KILL_TEST'] == '1' && Platform.isLinux;
  test('backup survives SIGKILL of the app process at random moments', () async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('fyona-oskill-');
    final path = '${dir.path}/live.db';
    final db = await databaseFactoryFfi.openDatabase(path);
    await db.execute('CREATE TABLE stock (id INTEGER PRIMARY KEY, name TEXT, qty INTEGER, note TEXT)');
    final b = db.batch();
    for (var i = 0; i < 30000; i++) {
      b.insert('stock', {'id': i, 'name': 'منتج $i', 'qty': i % 97, 'note': 'x' * 60});
    }
    await b.commit(noResult: true);
    await db.close();
    final kb = await BackupKeys.keyBytes(await BackupKeys.newKey());
    final rnd = Random();
    var completedRuns = 0;
    for (var k = 0; k < 5; k++) {
      final child = await Process.start('setsid', [
        'flutter', 'test', '--no-pub', 'test/backup/kill_child_test.dart',
      ], environment: {'FYONA_KILL_CHILD_DB': path, 'FYONA_KILL_CHILD_KEY': base64Encode(kb)});
      var runs = 0;
      child.stdout.transform(utf8.decoder).listen((s) => runs += 'CHILD_RUN_OK'.allMatches(s).length);
      child.stderr.drain<void>();
      // Wait until it is really backing up, then kill at a random moment.
      final until = DateTime.now().add(const Duration(minutes: 3));
      while (runs < 1 + k % 2 && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await Future<void>.delayed(Duration(milliseconds: rnd.nextInt(1500)));
      Process.runSync('kill', ['-KILL', '--', '-${child.pid}']); // the whole process group
      await child.exitCode;
      completedRuns += runs;
      final dest = LocalBackupDestination(Directory('${dir.path}/sets'));
      for (final id in await dest.sets()) {
        final t = '${dir.path}/check.db';
        final out = await runRestoreJob(setRoot: '${dir.path}/sets', backupId: id, backupKey: kb, targetPath: t, dbKeyHex: '');
        expect(out.problems, isEmpty, reason: 'after kill $k, set $id');
        File(t).deleteSync();
      }
    }
    expect(completedRuns, greaterThan(0));
    final stateFile = File('${dir.path}/state.json');
    final state = jsonDecode(stateFile.readAsStringSync()) as Map<String, dynamic>;
    final r = await runBackupJob(BackupJob(dbPath: path, dbKeyHex: '', backupKey: kb, wrappedKey: const {},
        scope: 's', localRoot: '${dir.path}/sets', state: state, keepSets: 2));
    expect(r.error, isNull);
    final t = '${dir.path}/final.db';
    expect((await runRestoreJob(setRoot: '${dir.path}/sets', backupId: r.backupId!, backupKey: kb, targetPath: t, dbKeyHex: ''))
        .problems, isEmpty);
    final a = await databaseFactoryFfi.openDatabase(path), z = await databaseFactoryFfi.openDatabase(t);
    expect(await z.rawQuery('SELECT * FROM stock ORDER BY id'), await a.rawQuery('SELECT * FROM stock ORDER BY id'));
    await a.close();
    await z.close();
    // ignore: avoid_print
    print('OS_KILL_TEST kills=5 completed_runs_before_kills=$completedRuns');
    await dir.delete(recursive: true);
  }, skip: enabled ? false : 'set FYONA_OS_KILL_TEST=1 (Linux) to run', timeout: const Timeout(Duration(minutes: 20)));
}
