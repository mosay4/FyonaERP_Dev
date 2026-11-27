import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../../features/core_business/data/local_directory/directory_database.dart';
import '../../features/core_business/data/local_directory/directory_pilot.dart';
import '../../features/core_business/data/local_directory/directory_scope.dart';
import '../../features/personal/data/ledger/personal_ledger_backup.dart';
import '../../features/personal/data/ledger/personal_ledger_database.dart';
import '../../features/personal/domain/services/backup/backup_integrity.dart';
import '../../features/personal/domain/services/backup/backup_snapshot.dart';
import '../../features/personal/domain/services/backup_service.dart' as v1;
import 'backup_worker.dart';

/// Applying a verified v2 copy goes through the app's OWN, proven restore
/// paths — never by swapping the live database — so every accounting,
/// sync and permission rule that already protects a restore still applies:
///
/// * Personal: the copy is read into the regular v4 snapshot and handed to
///   the existing restore (validation, merge by stable ids, and the
///   restored rows reach the user's other devices through the relay).
/// * Business: the copy produces the regular per-branch archive, applied by
///   the existing branch restore (only into an empty branch, marked as a
///   recovered ledger that cannot publish to the relay until re-approved).
abstract final class BackupBridges {
  /// Personal extras stored with every run.
  static Future<Map<String, dynamic>> personalExtras(v1.BackupService svc) async {
    final id = svc.boundIdentity;
    return {
      'prefs': await BackupSnapshotBuilder.readUserPrefs(),
      if (id != null) 'local_user_id': id.localUserId,
      if (id != null) 'user_uuid': id.serverUserUuid,
    };
  }

  /// The v4 snapshot of a restored Personal ledger copy.
  static Future<Map<String, dynamic>> personalSnapshot(
      Database copy, Map<String, dynamic>? extras, {required int localUserId, required String appVersion}) async {
    final user = (extras?['local_user_id'] as num?)?.toInt() ?? localUserId;
    Future<List<Map<String, dynamic>>> table(String t) async {
      if (t == PersonalLedgerBackup.mirrorTable) {
        final rows = await copy.rawQuery('SELECT seq, user_id, entity_type, id, data_json, updated_us '
            'FROM ${PersonalLedgerDatabase.rows} WHERE deleted = 0 ORDER BY seq ASC');
        return [
          for (final r in rows)
            {
              'id': r['seq'], 'user_id': r['user_id'], 'entity_type': r['entity_type'], 'remote_id': r['id'],
              'data_json': r['data_json'],
              'updated_at': DateTime.fromMicrosecondsSinceEpoch((r['updated_us'] as num).toInt()).toIso8601String(),
            },
        ];
      }
      if (PersonalLedgerDatabase.legacyTables.contains(t)) {
        return [for (final r in await copy.query(t)) Map<String, dynamic>.from(r)];
      }
      return const []; // users / file_uploads are not part of the ledger
    }

    Future<List<Map<String, dynamic>>> mirror(String type) async => [
          for (final r in await copy.rawQuery(
              'SELECT data_json FROM ${PersonalLedgerDatabase.rows} '
              'WHERE user_id = ? AND entity_type = ? AND deleted = 0 ORDER BY seq ASC',
              [user, type]))
            if (_map(r['data_json']) case final m?) m,
        ];

    return BackupSnapshotBuilder.build(
      localUserId: localUserId,
      serverUserUuid: '${extras?['user_uuid'] ?? ''}',
      appVersion: appVersion,
      source: 'backup-v2',
      tableSource: table,
      mirrorSource: mirror,
      preferences: (extras?['prefs'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  static Map<String, dynamic>? _map(Object? json) {
    try {
      final m = jsonDecode('$json');
      return m is Map && m.isNotEmpty ? Map<String, dynamic>.from(m) : null;
    } catch (_) {
      return null;
    }
  }

  /// Rebuilt Personal copy → existing restore.
  static Future<v1.RestoreResult> applyPersonal(v1.BackupService svc, String copyPath, String dbKeyHex,
      Map<String, dynamic>? extras, {required String appVersion, void Function(String, double)? onProgress}) async {
    final id = svc.boundIdentity;
    if (id == null) throw StateError('no identity');
    final db = await openLedgerFile(copyPath, dbKeyHex);
    Map<String, dynamic> snap;
    try {
      snap = await personalSnapshot(db, extras, localUserId: id.localUserId, appVersion: appVersion);
    } finally {
      await db.close();
    }
    final hmac = await svc.cachedHmacKey();
    final sealed = BackupIntegrity.sealSnapshot(snap, hmacKeyB64: hmac);
    return svc.restoreFromBackup(sealed,
        userId: id.localUserId, serverUserUuid: id.serverUserUuid, onProgress: onProgress);
  }

  /// Rebuilt Business copy → per-branch archive → existing branch restore.
  static Future<BusinessBackupRestore> applyBusiness({
    required String copyPath,
    required String dbKeyHex,
    required DirectoryAccess access,
    required DirectoryPilotStore live,
    required bool Function() allowed,
  }) async {
    final work = Directory('${File(copyPath).parent.path}/bk2-apply-${DateTime.now().microsecondsSinceEpoch}');
    await work.create(recursive: true);
    final storage = access.workspace.storageId;
    final copyFile = DirectoryDatabase.filePath(work, access.workspace);
    await File(copyPath).rename(copyFile);
    final copy = DirectoryPilotStore(root: () async => work, keys: _CopyKeys(storage, dbKeyHex));
    // The temporary copy only extracts the branch archive. The real gate
    // (live entitlement, owner, empty branch) is the live restore below.
    await copy.remember(access, {
      'status': 'active', 'business_setup_completed': true,
      'sections': {'business': {'active': true, 'end_date': DateTime.now().add(const Duration(days: 1)).toIso8601String()}},
    });
    final grant = BusinessLedgerAccess(access, {BusinessLedgerAction.manageBackup});
    final archive = File('${work.path}/branch.fybackup');
    final code = BusinessBackupCode.generate();
    try {
      // Same archive format and rules as a branch backup, but no 64 MB cap:
      // SQLite copies the rows page by page on disk.
      await copy.withLedger(grant, () => access, (l) => l.captureBackup(grant,
          id: const Uuid().v4(), destination: archive, code: code, allowed: allowed,
          maxBytes: businessBackupRebuildMaxBytes));
      await copy.close();
      // The copy is no longer needed: free its disk space before the restore.
      for (final f in [copyFile, '$copyFile-journal', '$copyFile-wal', '$copyFile-shm']) {
        if (File(f).existsSync()) File(f).deleteSync();
      }
      return await live.withLedger(grant, () => access,
          (l) => l.restoreBackup(grant, source: archive, code: code, allowed: allowed,
              maxBytes: businessBackupRebuildMaxBytes));
    } finally {
      await copy.close();
      if (await work.exists()) await work.delete(recursive: true);
    }
  }
}

final class _CopyKeys implements DirectoryKeyStore {
  _CopyKeys(String id, String key) : _m = {id: key};
  final Map<String, String> _m;
  @override
  Future<String?> read(String workspaceId) async => _m[workspaceId];
  @override
  Future<void> write(String workspaceId, String key) async => _m[workspaceId] = key;
}
