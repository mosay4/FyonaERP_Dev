import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/backup/backup_worker.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Child process of backup_os_kill_test.dart: works and backs up in a loop
/// until the parent kills the whole process (SIGKILL). Does nothing in a
/// normal test run.
void main() {
  final dbPath = Platform.environment['FYONA_KILL_CHILD_DB'];
  if (dbPath == null) return;
  test('kill child loop', () async {
    sqfliteFfiInit();
    final dir = File(dbPath).parent.path;
    final key = base64Decode(Platform.environment['FYONA_KILL_CHILD_KEY']!);
    final stateFile = File('$dir/state.json');
    for (var round = 0;; round++) {
      final db = await databaseFactoryFfi.openDatabase(dbPath, options: OpenDatabaseOptions(singleInstance: false));
      await db.execute('PRAGMA busy_timeout = 5000');
      await db.rawUpdate('UPDATE stock SET qty = qty + 1 WHERE id % 13 = ?', [round % 13]);
      await db.close();
      final state = stateFile.existsSync() ? jsonDecode(stateFile.readAsStringSync()) as Map<String, dynamic> : <String, dynamic>{};
      final r = await runBackupJobInline(BackupJob(dbPath: dbPath, dbKeyHex: '', backupKey: key, wrappedKey: const {},
          scope: 's', localRoot: '$dir/sets', state: state, keepSets: 2));
      if (r.error != null) continue;
      // Saved only after a completed run, atomically (as the app does).
      final tmp = File('${stateFile.path}.tmp')..writeAsStringSync(jsonEncode(r.state), flush: true);
      tmp.renameSync(stateFile.path);
      stdout.writeln('CHILD_RUN_OK $round');
    }
  }, timeout: Timeout.none);
}
