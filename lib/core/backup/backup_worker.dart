import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../media/media_store.dart';
import 'backup_crypto.dart';
import 'backup_engine.dart';
import 'backup_service.dart';

/// One backup job, run in a background isolate on its OWN connection to
/// the ledger file: the user's screen never waits for a backup, and the
/// app's database code is not touched (SQLite coordinates the two
/// connections; the backup only reads, plus its own `_bk_changes` table).
class BackupJob {
  BackupJob({
    required this.dbPath,
    required this.dbKeyHex,
    required this.backupKey,
    required this.wrappedKey,
    required this.scope,
    required this.localRoot,
    required this.state,
    this.mediaRoot,
    this.exclude = const {},
    this.keepSets = 3,
    this.extras,
  });

  final String dbPath;
  final String dbKeyHex; // the ledger's SQLCipher key (64 hex), or '' for plain
  final Uint8List backupKey;
  final Map<String, dynamic> wrappedKey;
  final String scope;
  final String localRoot;
  final Map<String, dynamic> state;
  final String? mediaRoot;
  final Set<String> exclude;
  final int keepSets;
  final Map<String, dynamic>? extras;
}

class BackupJobResult {
  BackupJobResult(this.state, this.backupId, this.newSet, this.changes, this.bytes, this.error);
  final Map<String, dynamic> state;
  final String? backupId;
  final bool newSet;
  final int changes;
  final int bytes;
  final String? error;
}

Future<Database> openLedgerFile(String path, String keyHex, {bool create = false}) async {
  if (keyHex.isNotEmpty && !RegExp(r'^[a-f0-9]{64}$').hasMatch(keyHex)) {
    throw ArgumentError('bad ledger key');
  }
  if (!create && !File(path).existsSync()) throw StateError('no ledger file');
  return createDatabaseFactoryFfi().openDatabase(path,
      options: OpenDatabaseOptions(
        singleInstance: false,
        onConfigure: (db) async {
          if (keyHex.isNotEmpty) {
            if ((await db.rawQuery('PRAGMA cipher_version')).isEmpty) throw StateError('no cipher');
            await db.execute('PRAGMA key = "x\'$keyHex\'"');
          }
          await db.rawQuery('SELECT count(*) FROM sqlite_master');
          await db.execute('PRAGMA busy_timeout = 5000');
          await db.rawQuery('PRAGMA journal_mode = DELETE');
          await db.execute('PRAGMA synchronous = FULL');
        },
      ));
}

Future<BackupJobResult> runBackupJob(BackupJob job) => Isolate.run(() => runBackupJobInline(job));

/// The same job on the calling isolate (tests / an isolate of your own).
Future<BackupJobResult> runBackupJobInline(BackupJob job) async {
  final state = BackupState.fromJson(job.state);
  Database? db;
  try {
    db = await openLedgerFile(job.dbPath, job.dbKeyHex);
    final engine = BackupEngine(exclude: job.exclude);
    await engine.install(db);
    final svc = BackupService(
      engine: engine,
      key: BackupKeys.keyFrom(job.backupKey),
      wrappedKey: job.wrappedKey,
      destinations: [LocalBackupDestination(Directory(job.localRoot))],
      scope: job.scope,
      media: job.mediaRoot == null ? null : MediaStore(Directory(job.mediaRoot!)),
      keepSets: job.keepSets,
    );
    final r = await svc.run(db, state, extras: job.extras);
    final err = r.failed.isEmpty ? null : r.failed.values.first;
    return BackupJobResult(state.toJson(), r.backupId, r.newSet, r.changes, r.bytes, err);
  } catch (e) {
    return BackupJobResult(state.toJson(), state.backupId, false, 0, 0, '$e');
  } finally {
    await db?.close();
  }
}

/// Restores a set from a local folder into a NEW ledger file (same key as
/// the live ledger), fully verified. The caller swaps files only on success.
/// Restore result: problems (empty = verified) + the set's app extras.
typedef RestoreOutcome = ({List<String> problems, Map<String, dynamic>? extras});

Future<RestoreOutcome> runRestoreJob({
  required String setRoot,
  required String backupId,
  required Uint8List backupKey,
  required String targetPath,
  required String dbKeyHex,
  String? mediaRoot,
  Set<String> exclude = const {},
}) =>
    Isolate.run(() async {
      final f = File(targetPath);
      if (f.existsSync()) f.deleteSync();
      final db = await openLedgerFile(targetPath, dbKeyHex, create: true);
      try {
        final src = LocalBackupDestination(Directory(setRoot));
        final key = BackupKeys.keyFrom(backupKey);
        final restorer = BackupRestorer(engine: BackupEngine(exclude: exclude));
        final problems = await restorer.restore(src, backupId, key, db,
            mediaStore: mediaRoot == null ? null : MediaStore(Directory(mediaRoot)));
        return (problems: problems, extras: await restorer.extras(src, backupId, key));
      } on BackupTampered catch (e) {
        return (problems: ['tampered: ${e.reason}'], extras: null);
      } finally {
        await db.close();
      }
    });
