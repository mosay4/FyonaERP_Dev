import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/database/database_helper.dart';
import '../../../../core/database/repositories/personal_cache_repository.dart';
import '../../../../core/database/repositories/personal_repository.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/network/api_client.dart';
import 'backup/backup_integrity.dart';
import 'backup/backup_snapshot.dart';
import 'backup/server_backup_service.dart';
import 'personal_finance_service.dart';

const String _kBackupFileName = 'FYONA_ERP_Backup.json';
const String _kAutoSyncEnabledKey = 'backup_auto_sync_enabled';
const String _kLastBackupTimeKey = 'backup_last_time';
const String _kLastSyncTimeKey = 'backup_last_sync_time';
const String _kSavedUriKey = 'backup_saved_uri';
const String _kSavedFilePathKey = 'backup_saved_file_path';
const String _kSavedFileNameKey = 'backup_saved_file_name';
const String _kSyncStatusKey = 'backup_sync_status';
const String _kSavedTreeUriKey = 'backup_saved_tree_uri';
const String _kSavedTreeNameKey = 'backup_saved_tree_name';
const String _kSavedRelativePathKey = 'backup_saved_relative_path';
const String _kLastSyncRowCountKey = 'backup_last_sync_row_count';
// New 4.0.0 keys (source selector, server state, pending completion).
const String _kSourceKey = 'backup_source'; // 'device' | 'server'
const String _kServerLastIdKey = 'backup_server_last_id';
const String _kServerLastTimeKey = 'backup_server_last_time';
const String _kServerLastVersionKey = 'backup_server_last_version';
const String _kServerRestorePendingKey = 'backup_server_restore_pending';

enum SyncStatus { synced, syncing, failed, unknown }

/// Backup source selected by the user (top of the Backup page).
enum BackupSource { device, server }

/// Full application state backup service (Personal).
///
/// Schema 4.0.0, single source of truth built by [BackupSnapshotBuilder],
/// sealed by [BackupIntegrity] (checksum always, HMAC when the per-user key
/// is available), validated before anything is wiped, restored atomically,
/// and VERIFIED before SUCCESS is ever reported.
///
/// Boundaries (never crossed here): the sync engine/outbox, finance logic,
/// balances, payments, subscriptions, exchange engines. This service only
/// reads committed rows, freezes its OWN timers/flags around operations,
/// and reports precise per-layer results.
/// Explicit backup identity. Backup/Restore/auto paths NEVER fall back to
/// `userId = 1` or an empty UUID when the real session is known: identity
/// is bound from the auth/session layer (see di provider) or passed
/// explicitly per call. Unresolvable identity refuses loudly.
class BackupIdentity {
  final int localUserId;
  final String serverUserUuid;
  const BackupIdentity({required this.localUserId, required this.serverUserUuid});

  bool get isValid => localUserId > 0 && serverUserUuid.isNotEmpty;
}

class BackupService {
  bool _syncInProgress = false;
  bool _restoreInProgress = false;
  bool _backupInProgress = false;
  Timer? _autoSyncTimer;
  Timer? _debounceTimer;
  final PersonalFinanceService? _financeService;
  final ServerBackupService _server;
  BackupIdentity? _boundIdentity;

  /// Set by providers on login/user change. Auto paths resolve explicit >
  /// bound > refuse (never silent defaults).
  // ignore: use_setters_to_change_properties
  void bindIdentity({required int localUserId, required String serverUserUuid}) {
    _boundIdentity = BackupIdentity(
        localUserId: localUserId, serverUserUuid: serverUserUuid);
  }

  BackupIdentity? _resolveIdentity({int? localUserId, String? serverUserUuid}) {
    final bound = _boundIdentity;
    // Explicit FALLBACK values (<=0 / empty) never override a bound real
    // identity — they only fill gaps when nothing better is known.
    final effLocal = (localUserId != null && localUserId > 0)
        ? localUserId
        : (bound?.localUserId ?? -1);
    final effUuid = (serverUserUuid != null && serverUserUuid.isNotEmpty)
        ? serverUserUuid
        : (bound?.serverUserUuid ?? '');
    final resolved =
        BackupIdentity(localUserId: effLocal, serverUserUuid: effUuid);
    return resolved.isValid ? resolved : null;
  }

  static const _channel = MethodChannel('com.fyona.erp/backup_storage');

  static Future<Map<String, dynamic>?> readDocumentContent(String uri) => _readDocument(uri);

  static Future<Map<String, dynamic>?> _readDocument(String uri) async {
    try {
      final Map<dynamic, dynamic> result = await _channel.invokeMethod(
        'readDocumentContent',
        {'uri': uri},
      );
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _verifyStoredContent(String uri, String expected) async {
    // MediaStore SIZE can lag a fresh write: retry briefly before judging
    // a good file as broken (a false negative deletes a valid backup).
    for (var attempt = 0; attempt < 3; attempt++) {
      final read = await _readDocument(uri);
      final content = read?['content'] as String?;
      final size = read?['size'] as int?;
      if (content != null &&
          size != null &&
          size > 0 &&
          size == utf8.encode(expected).length &&
          content == expected) {
        return true;
      }
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    return false;
  }

  /// Deletes a backup URI best-effort (retirement of a replaced file).
  /// Failures are swallowed: an orphan file is harmless, a deleted
  /// live file would be catastrophic.
  static Future<void> _retireUri(String? uri) async {
    if (uri == null || uri.isEmpty) return;
    try {
      await _channel.invokeMethod('deleteBackupByUri', {'uri': uri});
    } catch (_) {}
  }

  static bool _dbListenerAttached = false;

  /// The instance currently owning the DB hook. Re-pointed on every
  /// construction (last-wins): a stale first instance must never swallow
  /// auto-backup triggers with an outdated (or unbound) identity while a
  /// newer session instance exists (re-login, tests).
  static BackupService? _activeHookOwner;

  /// Reset guard: set while Reset Account runs. Auto backup paths refuse
  /// while set; manual paths too (a snapshot mid-reset would be torn).
  /// Static so UI reset flow can set it without a provider handle.
  static bool _resetGuard = false;

  static void setResetGuard(bool v) {
    _resetGuard = v;
  }

  static bool get isResetGuarded => _resetGuard;

  static int _countRows(Map<String, dynamic> data) {
    int count = 0;
    final tables = data['tables'];
    if (tables is Map) {
      for (final entry in tables.entries) {
        if (entry.value is List) count += (entry.value as List).length;
      }
    } else {
      for (final entry in data.entries) {
        if (entry.value is List) count += (entry.value as List).length;
      }
    }
    return count;
  }

  // `repo` is kept for constructor compatibility (providers pass it);
  // snapshot/restore go through DatabaseHelper + the finance service.
  BackupService({
    PersonalRepository? repo,
    PersonalFinanceService? financeService,
    ApiClient? apiClient,
    ServerBackupService? serverBackup,
  })  : _financeService = financeService,
        _server = serverBackup ?? ServerBackupService(apiClient: apiClient) {
    _activeHookOwner = this;
    if (!_dbListenerAttached) {
      _dbListenerAttached = true;
      DatabaseHelper.onDataChanged = () {
        _activeHookOwner?.onDataChanged();
      };
      debugPrint('BackupService: DatabaseHelper.onDataChanged listener attached');
    }
  }

  static Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  // ── prefs: auto-backup toggle / times / status / saved file ──

  static Future<bool> getAutoSyncEnabled() async {
    final p = await _prefs;
    return p.getBool(_kAutoSyncEnabledKey) ?? false;
  }

  static Future<void> setAutoSyncEnabled(bool v) async {
    final p = await _prefs;
    await p.setBool(_kAutoSyncEnabledKey, v);
  }

  static Future<String?> getLastBackupTime() async {
    final p = await _prefs;
    return p.getString(_kLastBackupTimeKey);
  }

  static Future<String?> getLastSyncTime() async {
    final p = await _prefs;
    return p.getString(_kLastSyncTimeKey);
  }

  static Future<SyncStatus> getSyncStatus() async {
    final p = await _prefs;
    final raw = p.getString(_kSyncStatusKey);
    switch (raw) {
      case 'synced':
        return SyncStatus.synced;
      case 'syncing':
        return SyncStatus.syncing;
      case 'failed':
        return SyncStatus.failed;
      default:
        return SyncStatus.unknown;
    }
  }

  static Future<void> _setSyncStatus(SyncStatus s) async {
    final p = await _prefs;
    await p.setString(_kSyncStatusKey, s.name);
  }

  static Future<String?> getSavedUri() async {
    final p = await _prefs;
    return p.getString(_kSavedUriKey);
  }

  static Future<String?> getSavedFilePath() async {
    final p = await _prefs;
    return p.getString(_kSavedFilePathKey);
  }

  static Future<String?> getSavedFileName() async {
    final p = await _prefs;
    return p.getString(_kSavedFileNameKey);
  }

  static Future<void> _saveFileInfo({
    required String uri,
    required String filePath,
    required String fileName,
  }) async {
    final p = await _prefs;
    await p.setString(_kSavedUriKey, uri);
    await p.setString(_kSavedFilePathKey, filePath);
    await p.setString(_kSavedFileNameKey, fileName);
  }

  static Future<void> _clearSavedFileInfo() async {
    final p = await _prefs;
    await p.remove(_kSavedUriKey);
    await p.remove(_kSavedFilePathKey);
    await p.remove(_kSavedFileNameKey);
  }

  /// Fixed backup filename — always the same, never changes.
  static String get backupFileName => _kBackupFileName;

  /// Check if backup file exists on device.
  static Future<bool> backupFileExists() async {
    try {
      final Map<dynamic, dynamic> result = await _channel.invokeMethod(
        'findBackupFile',
        {'fileName': _kBackupFileName},
      );
      return result['found'] == true;
    } catch (_) {
      return false;
    }
  }

  // ── source selector + server state prefs ──

  static Future<BackupSource> getBackupSource() async {
    final p = await _prefs;
    return p.getString(_kSourceKey) == 'server' ? BackupSource.server : BackupSource.device;
  }

  static Future<void> setBackupSource(BackupSource source) async {
    final p = await _prefs;
    await p.setString(_kSourceKey, source == BackupSource.server ? 'server' : 'device');
  }

  static const String _kServerLastSizeKey = 'backup_server_last_size';
  static const String _kServerLastCountKey = 'backup_server_last_count';

  static Future<Map<String, dynamic>?> getLastServerBackup() async {
    final p = await _prefs;
    final id = p.getString(_kServerLastIdKey);
    if (id == null || id.isEmpty) return null;
    return {
      'id': id,
      'time': p.getString(_kServerLastTimeKey),
      'version': p.getInt(_kServerLastVersionKey),
      'size_bytes': p.getInt(_kServerLastSizeKey) ?? 0,
      'record_count': p.getInt(_kServerLastCountKey) ?? 0,
    };
  }

  static Future<void> _saveLastServerBackup({
    required String id,
    required int version,
    int sizeBytes = 0,
    int recordCount = 0,
  }) async {
    final p = await _prefs;
    await p.setString(_kServerLastIdKey, id);
    await p.setString(_kServerLastTimeKey, DateTime.now().toIso8601String());
    await p.setInt(_kServerLastVersionKey, version);
    await p.setInt(_kServerLastSizeKey, sizeBytes);
    await p.setInt(_kServerLastCountKey, recordCount);
  }

  static Future<void> _clearLastServerBackupIf(String id) async {
    final p = await _prefs;
    if (p.getString(_kServerLastIdKey) == id) {
      await p.remove(_kServerLastIdKey);
      await p.remove(_kServerLastTimeKey);
      await p.remove(_kServerLastVersionKey);
      await p.remove(_kServerLastSizeKey);
      await p.remove(_kServerLastCountKey);
    }
  }

  static Future<String?> getPendingServerRestore() async {
    final p = await _prefs;
    return p.getString(_kServerRestorePendingKey);
  }

  static Future<void> _setPendingServerRestore(String? backupId) async {
    final p = await _prefs;
    if (backupId == null || backupId.isEmpty) {
      await p.remove(_kServerRestorePendingKey);
    } else {
      await p.setString(_kServerRestorePendingKey, backupId);
    }
  }

  static Future<void> clearPendingServerRestore() async {
    await _setPendingServerRestore(null);
  }

  // ── snapshot construction (with sync-quiescence guard) ──

  /// Builds + seals a 4.0.0 snapshot. Stability is sampled around the dump
  /// (outbox count AND mirror row count, twice, 300ms apart, up to 3
  /// rounds): a concurrent commit forces a re-dump; after bounded retries
  /// the snapshot is still taken but flagged `snapshot_quiesced=false` so
  /// the UI can warn instead of silently shipping a torn snapshot.
  /// Sampling reads sync_queue + mirror (READ-ONLY — sync logic untouched),
  /// and callers hold the backup mutex (no second backup/restore runs
  /// concurrently — see saveBackup/autoSync/restoreFromBackup guards).
  Future<Map<String, dynamic>> buildSnapshot({
    required int localUserId,
    required String serverUserUuid,
    String source = 'device',
    void Function(String stage, double progress)? onProgress,
  }) async {
    onProgress?.call('collect', 0.1);
    var quiesced = true;
    Map<String, dynamic> snap = {};
    for (var attempt = 0; attempt < 3; attempt++) {
      final before = await _activityFingerprint(localUserId);
      snap = await BackupSnapshotBuilder.build(
        localUserId: localUserId,
        serverUserUuid: serverUserUuid,
        appVersion: AppConfig.appVersion,
        source: source,
      );
      final after = await _activityFingerprint(localUserId);
      if (before == after) break;
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      } else {
        quiesced = false;
      }
    }
    (snap['meta'] as Map<String, dynamic>)['snapshot_quiesced'] = quiesced;
    onProgress?.call('seal', 0.7);
    final hmacKey = await _server.getCachedHmacKey();
    var sealed = BackupIntegrity.sealSnapshot(snap, hmacKeyB64: hmacKey);
    if (sealed['hmac'] == null) {
      // A fresh install (or a cleared keystore) has no cached HMAC key yet,
      // which is exactly why brand-new device files read back as
      // "authenticity: unverified". One best-effort fetch — offline it throws
      // immediately and we keep the valid checksum-only file.
      try {
        final fetched = await _server.fetchHmacKey();
        if (fetched.isNotEmpty) {
          sealed = BackupIntegrity.sealSnapshot(snap, hmacKeyB64: fetched);
        }
      } catch (_) {}
    }
    onProgress?.call('sealed', 0.8);
    return sealed;
  }

  Future<int> _outboxCount() async {
    try {
      final rows = await DatabaseHelper.rawQuery(
          'SELECT COUNT(*) AS c FROM sync_queue');
      if (rows.isEmpty) return 0;
      return (rows.first['c'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Stability fingerprint for snapshot quiescence: outbox depth plus the
  /// mirror row count for this user. Compared before/after the dump; any
  /// drift means a concurrent write landed mid-snapshot.
  Future<String> _activityFingerprint(int localUserId) async {
    final outbox = await _outboxCount();
    var mirror = -1;
    try {
      final rows = await DatabaseHelper.rawQuery(
        'SELECT COUNT(*) AS c FROM personal_entity_cache WHERE user_id = ?',
        [localUserId],
      );
      if (rows.isNotEmpty) {
        mirror = (rows.first['c'] as num?)?.toInt() ?? -1;
      }
    } catch (_) {}
    return '$outbox:$mirror';
  }

  static const String _kDeviceVersionKey = 'backup_device_version';

  static Future<int> _nextDeviceVersion() async {
    // Infer from existing files (survives reinstall when prefs cleared).
    var maxVer = 0;
    try {
      final files = await listBackups();
      final re = RegExp(r'v(\d+)');
      for (final f in files) {
        final m = re.firstMatch(f.name);
        if (m != null) {
          final v = int.tryParse(m.group(1) ?? '') ?? 0;
          if (v > maxVer) maxVer = v;
        } else if (f.name == _kBackupFileName) {
          if (maxVer < 1) maxVer = 1;
        }
      }
    } catch (_) {}
    try {
      final p = await _prefs;
      final saved = p.getInt(_kDeviceVersionKey) ?? 0;
      if (saved > maxVer) maxVer = saved;
    } catch (_) {}
    return maxVer + 1;
  }

  /// Creates a NEW versioned device backup (FYONA_ERP_Backup_vN_*.json).
  /// Used by "إنشاء نسخة احتياطية" — increments version, keeps previous versions.
  Future<BackupResult> createDeviceBackup({
    int? localUserId,
    String? serverUserUuid,
    void Function(String stage, double progress)? onProgress,
  }) async {
    if (_backupInProgress || _restoreInProgress || _resetGuard) {
      return const BackupResult(success: false, message: 'busy', filePath: null);
    }
    final identity = _resolveIdentity(localUserId: localUserId, serverUserUuid: serverUserUuid);
    if (identity == null) {
      return BackupResult(success: false, message: AppLocalizations.t('backupErrNoIdentity'), filePath: null);
    }
    _backupInProgress = true;
    try {
      final sealed = await buildSnapshot(
        localUserId: identity.localUserId,
        serverUserUuid: identity.serverUserUuid,
        source: 'device',
        onProgress: onProgress,
      );
      if (!_hasAnyData(sealed)) {
        return BackupResult(success: false, message: AppLocalizations.t('backupErrEmptyFile'), filePath: null);
      }
      final jsonContent = const JsonEncoder.withIndent('  ').convert(sealed);
      final now = DateTime.now();
      final stamp = now.toIso8601String().replaceAll(RegExp(r'[^0-9]'), '').substring(0, 14);
      final version = await _nextDeviceVersion();
      final fileName = 'FYONA_ERP_Backup_v${version}_$stamp.json';
      onProgress?.call('write', 0.85);
      final Map<dynamic, dynamic> nativeResult = await _channel.invokeMethod(
        'saveAtomic',
        {'fileName': fileName, 'content': jsonContent},
      );
      if (nativeResult['success'] != true) {
        return BackupResult(success: false, message: nativeResult['message']?.toString() ?? AppLocalizations.t('backupErrDiskWrite'), filePath: null);
      }
      final uri = nativeResult['uri'] as String? ?? '';
      final filePath = nativeResult['filePath'] as String? ?? '';
      final savedName = nativeResult['fileName'] as String? ?? fileName;
      final fileSize = nativeResult['fileSize'] as int? ?? 0;
      if (uri.isEmpty || !await _verifyStoredContent(uri, jsonContent)) {
        try { await _channel.invokeMethod('deleteBackupByUri', {'uri': uri}); } catch (_) {}
        return BackupResult(success: false, message: AppLocalizations.t('backupErrVerifyDeleted'), filePath: null);
      }
      onProgress?.call('done', 1.0);
      final p = await _prefs;
      await p.setInt(_kDeviceVersionKey, version);
      await p.setString(_kLastBackupTimeKey, now.toIso8601String());
      await _saveFileInfo(uri: uri, filePath: filePath, fileName: savedName);
      return BackupResult(success: true, message: AppLocalizations.t('backupSavedOk'), filePath: filePath, fileUri: uri, fileSize: fileSize, createdAt: now.toIso8601String(), recordCount: _countRows(sealed));
    } catch (_) {
      return BackupResult(success: false, message: AppLocalizations.t('backupErrSaveFailed'), filePath: null);
    } finally {
      _backupInProgress = false;
    }
  }

  /// Manual-save primitive ("حفظ البيانات الحالية"): rewrites the bytes of
  /// ONE existing version ([uri]) with a fresh snapshot — same uri, same
  /// name, no new file, no rename, and no other version is ever listed,
  /// touched or retired. On any failure nothing is deleted (the previous
  /// bytes stay until a verified write lands).
  Future<BackupResult> overwriteLatestBackup({
    required String uri,
    int? localUserId,
    String? serverUserUuid,
    void Function(String stage, double progress)? onProgress,
  }) async {
    if (_backupInProgress || _restoreInProgress || _resetGuard) {
      return const BackupResult(success: false, message: 'busy', filePath: null);
    }
    final identity =
        _resolveIdentity(localUserId: localUserId, serverUserUuid: serverUserUuid);
    if (identity == null) {
      return BackupResult(
        success: false,
        message: AppLocalizations.t('backupErrNoIdentity'),
        filePath: null,
      );
    }
    if (uri.isEmpty) {
      return BackupResult(
        success: false,
        message: AppLocalizations.t('backupNoBackup'),
        filePath: null,
      );
    }
    _backupInProgress = true;
    try {
      final sealed = await buildSnapshot(
        localUserId: identity.localUserId,
        serverUserUuid: identity.serverUserUuid,
        onProgress: onProgress,
      );
      if (!_hasAnyData(sealed)) {
        return BackupResult(
            success: false,
            message: AppLocalizations.t('backupErrEmptyFile'),
            filePath: null);
      }
      final jsonContent = const JsonEncoder.withIndent('  ').convert(sealed);
      onProgress?.call('write', 0.85);
      final Map<dynamic, dynamic> nativeResult = await _channel.invokeMethod(
        'overwriteFixedBackup',
        {'uri': uri, 'content': jsonContent},
      );
      if (nativeResult['success'] != true) {
        return BackupResult(
          success: false,
          message: nativeResult['message']?.toString() ??
              AppLocalizations.t('backupErrDiskWrite'),
          filePath: null,
        );
      }
      final bool verified = await _verifyStoredContent(uri, jsonContent);
      debugPrint('Backup: overwrite $uri verified=$verified');
      if (!verified) {
        return BackupResult(
          success: false,
          message: AppLocalizations.t('backupSyncVerifyFailed'),
          filePath: null,
        );
      }
      onProgress?.call('done', 1.0);
      final now = DateTime.now().toIso8601String();
      final p = await _prefs;
      await p.setString(_kLastSyncTimeKey, now);
      await p.setInt(_kLastSyncRowCountKey, _countRows(sealed));
      await _setSyncStatus(SyncStatus.synced);
      return BackupResult(
        success: true,
        message: AppLocalizations.t('backupSyncedOk'),
        filePath: await getSavedFilePath(),
        fileUri: uri,
        fileSize: (nativeResult['fileSize'] as num?)?.toInt() ?? 0,
        createdAt: now,
        recordCount: _countRows(sealed),
      );
    } catch (_) {
      return BackupResult(
        success: false,
        message: AppLocalizations.t('backupErrSaveFailed'),
        filePath: null,
      );
    } finally {
      _backupInProgress = false;
    }
  }

  /// Manual-save target: the prefs-tracked file when it is still readable,
  /// otherwise the newest version on disk (adopted into prefs), else null
  /// when no version exists at all. Never creates, deletes or renames.
  static Future<String?> resolveLatestDeviceUri() async {
    var target = await getSavedUri();
    if (target != null && target.isNotEmpty) {
      try {
        final doc = await readDocumentContent(target);
        if ((doc?['content'] as String?)?.isNotEmpty == true) return target;
      } catch (_) {}
    }
    try {
      final files = await listBackups();
      if (files.isNotEmpty) {
        target = files.first.uri;
        await _saveFileInfo(
          uri: target,
          filePath: files.first.relativePath + files.first.name,
          fileName: files.first.name,
        );
        return target;
      }
    } catch (_) {}
    return null;
  }

  // ── device backup ──

  /// Save backup — always overwrites the single file `FYONA_ERP_Backup.json`
  /// using a verified native write (the native layer keeps the previous
  /// file until the new one is verified — never delete-before-write).
  /// Identity resolves explicit > bound; unresolvable identity refuses
  /// loudly instead of snapshotting as a wrong user.
  /// Kept for tests and as fallback; UI create now uses versioned create above.
  Future<BackupResult> saveBackup({
    int? localUserId,
    String? serverUserUuid,
    void Function(String stage, double progress)? onProgress,
  }) async {
    if (_backupInProgress || _restoreInProgress || _resetGuard) {
      return const BackupResult(
        success: false,
        message: 'busy',
        filePath: null,
      );
    }
    final identity =
        _resolveIdentity(localUserId: localUserId, serverUserUuid: serverUserUuid);
    if (identity == null) {
      return BackupResult(
        success: false,
        message: AppLocalizations.t('backupErrNoIdentity'),
        filePath: null,
      );
    }
    _backupInProgress = true;
    try {
      final sealed = await buildSnapshot(
        localUserId: identity.localUserId,
        serverUserUuid: identity.serverUserUuid,
        onProgress: onProgress,
      );
      // Never overwrite a good backup with an empty snapshot (e.g. right
      // after a reset or on a fresh account with no data yet).
      if (!_hasAnyData(sealed)) {
        return BackupResult(
          success: false,
          message: AppLocalizations.t('backupErrEmptyFile'),
          filePath: null,
        );
      }
      final jsonContent = const JsonEncoder.withIndent('  ').convert(sealed);
      final now = DateTime.now().toIso8601String();
      onProgress?.call('write', 0.85);

      // Remember the previous URI first: only it — never a name match —
      // is retired after the new file verifies.
      final previousUri = await getSavedUri();
      String uri = '';
      String filePath = '';
      String savedName = _kBackupFileName;
      int fileSize = 0;
      String relativePath = '';
      // Collision-free path first: a stale same-name MediaStore row breaks
      // fresh inserts ("Failed to build unique file"), so when the fixed
      // file already exists we overwrite its bytes in place instead.
      // [overwroteInPlace] guards the failure path below: the fixed row is
      // never deleted (only a brand-new unverified row is).
      var overwroteInPlace = false;
      // Collision-free path first: a stale same-name MediaStore row breaks
      // fresh inserts ("Failed to build unique file"), so when the fixed
      // file already exists we overwrite its bytes in place instead.
      String? existingUri;
      try {
        final files = await listBackups();
        for (final f in files) {
          if (f.name == _kBackupFileName) {
            existingUri = f.uri;
            break;
          }
        }
      } catch (_) {}
      if (existingUri != null && existingUri.isNotEmpty) {
        final Map<dynamic, dynamic> owResult = await _channel.invokeMethod(
          'overwriteFixedBackup',
          {'uri': existingUri, 'content': jsonContent},
        );
        if (owResult['success'] != true) {
          return BackupResult(
            success: false,
            message: owResult['message']?.toString() ??
                AppLocalizations.t('backupErrDiskWrite'),
            filePath: null,
          );
        }
        uri = owResult['uri']?.toString() ?? existingUri;
        fileSize = (owResult['fileSize'] as num?)?.toInt() ?? 0;
        filePath = await getSavedFilePath() ?? '';
        overwroteInPlace = true;
      } else {
        final Map<dynamic, dynamic> nativeResult = await _channel.invokeMethod(
          'saveAtomic',
          {'fileName': _kBackupFileName, 'content': jsonContent},
        );

        if (nativeResult['success'] != true) {
          return BackupResult(
            success: false,
            message: nativeResult['message']?.toString() ??
                AppLocalizations.t('backupErrDiskWrite'),
            filePath: null,
          );
        }

        uri = nativeResult['uri'] as String? ?? '';
        filePath = nativeResult['filePath'] as String? ?? '';
        savedName = nativeResult['fileName'] as String? ?? _kBackupFileName;
        fileSize = (nativeResult['fileSize'] as num?)?.toInt() ?? 0;
        relativePath = nativeResult['relativePath'] as String? ?? '';
      }

      if (uri.isEmpty) {
        return const BackupResult(
          success: false,
          message: 'backupErrNoFileId',
          filePath: null,
        );
      }

      final bool verified = await _verifyStoredContent(uri, jsonContent);
      debugPrint('Backup: $savedName size=$fileSize verified=$verified');
      if (!verified) {
        // Only a brand-new row may be rolled back: the fixed file overwritten
        // in place is never deleted (its previous content is the fallback).
        if (!overwroteInPlace) {
          try {
            await _channel.invokeMethod('deleteBackupByUri', {'uri': uri});
          } catch (_) {}
        }
        return BackupResult(
          success: false,
          message: AppLocalizations.t('backupErrVerifyDeleted'),
          filePath: null,
        );
      }
      onProgress?.call('done', 1.0);

      if (previousUri != null &&
          previousUri.isNotEmpty &&
          previousUri != uri) {
        await _retireUri(previousUri);
      }
      final p = await _prefs;
      await p.setString(_kLastBackupTimeKey, now);
      if (relativePath.isNotEmpty) {
        await p.setString(_kSavedRelativePathKey, relativePath);
      }
      await p.setInt(_kLastSyncRowCountKey, _countRows(sealed));
      await _saveFileInfo(uri: uri, filePath: filePath, fileName: savedName);

      return BackupResult(
        success: true,
        message: AppLocalizations.t('backupSavedOk'),
        filePath: filePath,
        fileUri: uri,
        fileSize: fileSize,
        createdAt: now,
        recordCount: _countRows(sealed),
      );
    } catch (e) {
      return BackupResult(
        success: false,
        message: AppLocalizations.t('backupErrSaveFailed'),
        filePath: null,
      );
    } finally {
      _backupInProgress = false;
    }
  }

  /// Pre-restore safety net: writes the current state to a DISTINCTLY named
  /// file (`FYONA_ERP_Backup_safety_<timestamp>.json`) so it can never
  /// silently replace — or be confused with — the backup about to be
  /// restored. Never touches the saved-URI prefs. Keeps the latest 2
  /// safety files, pruning older ones best-effort.
  Future<BackupResult> saveSafetyBackup({
    int? localUserId,
    String? serverUserUuid,
  }) async {
    if (_backupInProgress || _restoreInProgress || _resetGuard) {
      return const BackupResult(
          success: false, message: 'busy', filePath: null);
    }
    final identity =
        _resolveIdentity(localUserId: localUserId, serverUserUuid: serverUserUuid);
    if (identity == null) {
      return BackupResult(
        success: false,
        message: AppLocalizations.t('backupErrNoIdentity'),
        filePath: null,
      );
    }
    _backupInProgress = true;
    try {
      final sealed = await buildSnapshot(
        localUserId: identity.localUserId,
        serverUserUuid: identity.serverUserUuid,
      );
      if (!_hasAnyData(sealed)) {
        return BackupResult(
          success: false,
          message: AppLocalizations.t('backupErrEmptyFile'),
          filePath: null,
        );
      }
      final jsonContent = const JsonEncoder.withIndent('  ').convert(sealed);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[^0-9]'), '')
          .substring(0, 14);
      final name = 'FYONA_ERP_Backup_safety_$stamp.json';
      final Map<dynamic, dynamic> nativeResult = await _channel.invokeMethod(
        'saveAtomic',
        {'fileName': name, 'content': jsonContent},
      );
      if (nativeResult['success'] != true) {
        return BackupResult(
          success: false,
          message: nativeResult['message']?.toString() ??
              AppLocalizations.t('backupErrDiskWrite'),
          filePath: null,
        );
      }
      final uri = nativeResult['uri'] as String? ?? '';
      if (uri.isEmpty ||
          !await _verifyStoredContent(uri, jsonContent)) {
        try {
          await _channel.invokeMethod('deleteBackupByUri', {'uri': uri});
        } catch (_) {}
        return BackupResult(
          success: false,
          message: AppLocalizations.t('backupErrVerifyDeleted'),
          filePath: null,
        );
      }
      await _pruneSafetyBackups(keepUris: {uri});
      return BackupResult(
        success: true,
        message: AppLocalizations.t('backupSavedOk'),
        filePath: nativeResult['filePath'] as String? ?? '',
        fileUri: uri,
        fileSize: (nativeResult['fileSize'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.now().toIso8601String(),
        recordCount: _countRows(sealed),
      );
    } catch (_) {
      return BackupResult(
        success: false,
        message: AppLocalizations.t('backupErrSaveFailed'),
        filePath: null,
      );
    } finally {
      _backupInProgress = false;
    }
  }

  /// Keeps [keep] safety files IN TOTAL (including the just-written one),
  /// deleting older ones best-effort. Never touches the main backup file
  /// or URIs it doesn't own.
  Future<void> _pruneSafetyBackups(
      {required Set<String> keepUris, int keep = 2}) async {
    try {
      final files = await listBackups();
      final safety = files
          .where((f) =>
              f.name.startsWith('FYONA_ERP_Backup_safety_') &&
              !keepUris.contains(f.uri))
          .toList()
        // Safety names embed a timestamp (FYONA_ERP_Backup_safety_<ts>),
        // so lexicographic order is chronological — deterministic even
        // when filesystem dates share the same second.
        ..sort((a, b) => b.name.compareTo(a.name));
      final keepOthers = (keep - keepUris.length).clamp(0, keep);
      for (final extra in safety.skip(keepOthers)) {
        try {
          await _channel.invokeMethod(
              'deleteBackupByUri', {'uri': extra.uri});
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<BackupReadResult> readBackupContent(
    String content, {
    String? fileName,
    String serverUserUuid = '',
    int localUserId = 1,
  }) async {
    try {
      if (content.isEmpty) {
        return BackupReadResult(
          success: false,
          message: AppLocalizations.t('backupErrEmpty'),
        );
      }

      final dynamic decoded;
      try {
        decoded = jsonDecode(content);
      } catch (e) {
        return BackupReadResult(
          success: false,
          message: AppLocalizations.t('backupErrCorrupt'),
        );
      }

      if (decoded is! Map<String, dynamic>) {
        return BackupReadResult(
          success: false,
          message: AppLocalizations.t('backupErrBadFormat'),
        );
      }

      Map<String, dynamic> data = decoded;
      // Explicit migration for 3.0.0 files (re-stamped + re-sealed below by
      // the caller before any restore; never partial-restored as-is).
      if (data['schema_version']?.toString() == '3.0.0') {
        try {
          data = BackupIntegrity.migrate30to40(
            data,
            serverUserUuid: serverUserUuid,
            localUserId: localUserId,
            appVersion: AppConfig.appVersion,
          );
        } catch (_) {
          return BackupReadResult(
            success: false,
            message: AppLocalizations.t('backupErrUnmigratable'),
          );
        }
      }

      final hmacKey = await _server.getCachedHmacKey();
      final issues = BackupIntegrity.validateSnapshot(data, hmacKeyB64: hmacKey);
      final validation = BackupValidation(
        isValid: issues.ok,
        errors: issues.errors.map((e) => e.code).toList(),
        schemaVersion: data['schema_version']?.toString(),
        createdAt: data['created_at']?.toString(),
        hasData: _hasAnyData(data),
        authenticity: issues.authenticity,
        recordCount: _countRows(data),
      );
      if (!issues.ok) {
        return BackupReadResult(
          success: false,
          message: AppLocalizations.t('backupErrInvalid',
              {'errors': validation.errors.join(', ')}),
          validation: validation,
          fileName: fileName,
        );
      }

      return BackupReadResult(
        success: true,
        message: AppLocalizations.t('backupFileValid'),
        data: data,
        validation: validation,
        fileName: fileName,
      );
    } catch (e) {
      return BackupReadResult(
        success: false,
        message: AppLocalizations.t('backupErrReadFailed'),
      );
    }
  }

  static bool _hasAnyData(Map<String, dynamic> data) {
    final tables = data['tables'];
    if (tables is Map) {
      for (final v in tables.values) {
        if (v is List && v.isNotEmpty) return true;
      }
    }
    final entities = data['entities'];
    if (entities is Map) {
      for (final v in entities.values) {
        if (v is List && v.isNotEmpty) return true;
      }
    }
    // Legacy 3.0.0 shape (pre-migration safety net).
    for (final entry in data.entries) {
      if (entry.value is List &&
          (entry.value as List).isNotEmpty &&
          entry.key != 'checksum' &&
          entry.key != 'hmac') {
        return true;
      }
    }
    final prefs = data['preferences'];
    if (prefs is Map && prefs.isNotEmpty) return true;
    return false;
  }

  // ── restore ──

  /// Tables wiped + reinserted on local restore. Business tables, `users`
  /// (login state), and ALL sync/operational tables are deliberately NOT
  /// touched — personal restore must never endanger them.
  static const List<String> restoreTables = [
    'personal_wallets',
    'personal_transactions',
    'savings_goals',
    'spending_categories',
    'personal_bank_accounts',
    'personal_bank_transactions',
    'personal_debts',
    'personal_debt_payments',
    'personal_exchange_rates',
    'personal_recurring_transactions',
    'personal_budgets',
    'budget_categories',
    'personal_entity_cache',
    'file_uploads',
  ];

  /// Fails loudly (before any write) when a required table is absent, so a
  /// half-capable database can never enter the restore step.
  static Future<List<String>> missingRestoreTables() async {
    final missing = <String>[];
    for (final table in restoreTables) {
      try {
        final rows = await DatabaseHelper.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          [table],
        );
        if (rows.isEmpty) missing.add(table);
      } catch (_) {
        missing.add(table);
      }
    }
    return missing;
  }

  /// Full restore pipeline — SAFE MERGE by stable identity (never wipe).
  /// Order (never violated): VALIDATE → OWNERSHIP → RELATIONS recheck →
  /// SERVER attempt (capability-probed) → LOCAL upsert → prefs → VERIFY →
  /// result. Identity rule: same stable ID = same record (updated in place,
  /// never duplicated); unknown ID = inserted; rows outside the backup are
  /// left untouched. SUCCESS is only returned fully verified; server trouble
  /// yields an explicit partial result with a safe retry — never a lie.
  Future<RestoreResult> restoreFromBackup(
    Map<String, dynamic> data, {
    int userId = 1,
    String serverUserUuid = '',
    bool skipServer = false,
    void Function(String stage, double progress)? onProgress,
    // Where this snapshot came from: 'device' (default) or 'server:<id>'.
    // Decides how a deferred server layer is retried later.
    String snapshotOrigin = 'device',
  }) async {
    if (_restoreInProgress || _backupInProgress || _resetGuard) {
      return RestoreResult(
        success: false,
        message: AppLocalizations.t('backupRestoreBusy'),
      );
    }
    _restoreInProgress = true;
    stopAutoSyncTimer();
    try {
      onProgress?.call('validate', 0.05);
      // Work on a private deep copy: merge planning rewrites ids and FKs
      // in place, and callers may reuse their map for a second restore
      // (cached validation) — which must validate identically, not fail
      // on our own mutations.
      try {
        data = Map<String, dynamic>.from(
            jsonDecode(jsonEncode(data)) as Map);
      } catch (_) {
        return RestoreResult(
          success: false,
          message: AppLocalizations.t('backupErrInvalidData',
              {'errors': 'unserializable'}),
        );
      }
      // Re-validate the exact map about to be applied (never trust a
      // validation done earlier on different bytes).
      final hmacKey = await _server.getCachedHmacKey();
      final issues = BackupIntegrity.validateSnapshot(data, hmacKeyB64: hmacKey);
      if (!issues.ok) {
        return RestoreResult(
          success: false,
          message: AppLocalizations.t('backupErrInvalidData',
              {'errors': issues.errors.map((e) => e.code).join(', ')}),
        );
      }

      // Ownership: refuse another user's snapshot (when both sides known).
      final snapUser = data['user_uuid']?.toString() ?? '';
      if (snapUser.isNotEmpty &&
          serverUserUuid.isNotEmpty &&
          snapUser != serverUserUuid) {
        return RestoreResult(
          success: false,
          message: AppLocalizations.t('backupErrForeignUser'),
        );
      }

      final entities = data['entities'];
      var entitiesEmpty = true;
      if (entities is Map) {
        for (final v in entities.values) {
          if (v is List && v.isNotEmpty) {
            entitiesEmpty = false;
            break;
          }
        }
      }

      // Relations recheck on the exact payload (dedicated visible stage).
      onProgress?.call('relations', 0.12);
      final relationIssues =
          BackupIntegrity.validateEntities(data['entities']);
      if (relationIssues.isNotEmpty) {
        return RestoreResult(
          success: false,
          message: AppLocalizations.t('backupErrInvalidData',
              {'errors': relationIssues.map((e) => e.code).join(', ')}),
        );
      }

      // ── SERVER layer (capability-probed; never blind). ──
      var serverState = 'skipped';
      if (!skipServer && _financeService != null) {
        onProgress?.call('server', 0.2);
        if (entitiesEmpty) {
          return RestoreResult(
            success: false,
            message: AppLocalizations.t('backupErrNoEntities'),
          );
        }
        _ServerProbe? probe;
        try {
          probe = await _probeServerRestore().timeout(
            const Duration(seconds: 20),
            onTimeout: () => _ServerProbe.offline,
          );
        } catch (_) {
          // A capability probe must never abort the local restore (a
          // transient key-route 500 after repeated restores used to fail
          // the whole operation): the server layer is marked failed with
          // its explicit retry path, local proceeds below.
          probe = null;
          serverState = 'failed';
          await _setPendingServerRestore(
              _pendingOrigin(data, snapshotOrigin));
        }
        if (probe == _ServerProbe.unsupported) {
          // Old server without the verified-restore contract: local-only
          // restore, stated plainly. No blind POST that could wipe.
          serverState = 'unsupported';
        } else if (probe == _ServerProbe.offline) {
          serverState = 'pending_offline';
          await _setPendingServerRestore(_pendingOrigin(data, snapshotOrigin));
        } else {
          try {
            await _restoreServerEntities(data);
            serverState = 'verified';
          } on RestoreFailure catch (e) {
            // Local restore still proceeds below; the server layer stays
            // pending/failed with an explicit retry path (idempotent —
            // upsert by stable ID can never duplicate).
            serverState = e.offline ? 'pending_offline' : 'failed';
            await _setPendingServerRestore(
                _pendingOrigin(data, snapshotOrigin));
          }
        }
      }

      // ── LOCAL layer: single SQLite transaction (all-or-nothing). ──
      onProgress?.call('local', 0.5);
      final tables = data['tables'];
      if (tables is! Map) {
        return RestoreResult(
          success: false,
          message: AppLocalizations.t('backupErrNoTables'),
        );
      }
      final missingTables = await missingRestoreTables();
      if (missingTables.isNotEmpty) {
        return RestoreResult(
          success: false,
          message: AppLocalizations.t('backupErrVerifyFailed',
              {'errors': 'missing tables: ${missingTables.join(', ')}}'}),
          serverState: serverState,
        );
      }
      // ── ACCOUNT MERGE (logical identity): snapshot bank rows merge
      // into same-key existing rows instead of duplicating; referencing
      // rows are remapped in the snapshot tables in place. The namespace
      // comes from the snapshot rows themselves (never a default).
      onProgress?.call('local', 0.45);
      var mergedAccounts = 0;
      var sweptStubs = 0;
      var leftoverDupes = 0;
      var mergeNs = userId;
      final cacheRowsForNs = tables['personal_entity_cache'];
      if (cacheRowsForNs is List) {
        for (final r in cacheRowsForNs) {
          if (r is Map && r['user_id'] is int) {
            mergeNs = r['user_id'] as int;
            break;
          }
        }
      }
      // Merge PLANNING only (no writes): remaps snapshot rows in place and
      // returns stub ids to sweep. The sweep executes INSIDE the restore
      // transaction below, so a later failure rolls everything back.
      var sweepIds = <String>[];
      var catSweepIds = <String>[];
      try {
        final plan = await _planMirrorMerge(tables, mergeNs);
        mergedAccounts = plan.merged;
        leftoverDupes = plan.leftover;
        sweepIds = plan.sweepIds;
        catSweepIds = plan.catSweepIds;
      } catch (_) {}
      final nowIso = DateTime.now().toIso8601String();
      await DatabaseHelper.transaction((tx) async {
        for (final sweepId in sweepIds) {
          await tx.rawDelete(
            'DELETE FROM personal_entity_cache WHERE user_id = ? AND entity_type = ? AND remote_id = ?',
            [mergeNs, 'personal_bank_account', sweepId],
          );
          sweptStubs++;
        }
        // Absorbed duplicate categories: drop the stale legacy rows (the
        // surviving rows carry the backup values via upsert below).
        for (final sweepId in catSweepIds) {
          await tx.rawDelete(
            'DELETE FROM budget_categories WHERE id = ?',
            [sweepId],
          );
          sweptStubs++;
        }
        for (final table in restoreTables) {
          final rows = tables[table];
          if (rows is! List) continue;
          for (final row in rows) {
            if (row is! Map) continue;
            await _upsertRow(
              tx,
              table,
              Map<String, dynamic>.from(row),
              nowIso: nowIso,
            );
          }
        }
      });

      // ── Preferences (typed, user-data only). ──
      onProgress?.call('prefs', 0.8);
      final prefsData = data['preferences'];
      if (prefsData is Map<String, dynamic>) {
        await BackupSnapshotBuilder.writeUserPrefs(prefsData);
      } else if (prefsData is Map) {
        await BackupSnapshotBuilder.writeUserPrefs(
            Map<String, dynamic>.from(prefsData));
      }

      // ── VERIFY local layer against the snapshot. ──
      onProgress?.call('verify', 0.9);
      final verifyErrors = await _verifyLocalRestore(data);
      if (verifyErrors.isNotEmpty) {
        return RestoreResult(
          success: false,
          message: AppLocalizations.t('backupErrVerifyFailed',
              {'errors': verifyErrors.join(', ')}),
          serverState: serverState,
        );
      }
      // Heal exact-duplicate cash rows (zero + unreferenced only — money
      // never moves): stale stubs beside the restored rows are exactly what
      // painted phantom-zero cards after a restore.
      try {
        await _financeService?.sweepDuplicateCashAccounts();
      } catch (_) {}
      onProgress?.call('done', 1.0);

      final totalRows = _countRows(data);
      final checks = <String>['data', 'relations'];
      if (serverState == 'verified') checks.add('server');
      if (serverState == 'pending_offline' || serverState == 'failed') {
        return RestoreResult(
          success: true,
          message:
              '${AppLocalizations.t('backupRestoredVerified', {'count': totalRows})} '
              '${AppLocalizations.t(serverState == 'pending_offline' ? 'backupServerPendingNote' : 'backupErrServerFailed')}'
                  .trim(),
          restoredRows: totalRows,
          serverState: serverState,
          authenticity: issues.authenticity,
          checks: checks,
          mergedAccounts: mergedAccounts,
          sweptStubs: sweptStubs,
          leftoverDupes: leftoverDupes,
        );
      }
      final serverNote = serverState == 'unsupported'
          ? ' ${AppLocalizations.t('backupServerUnsupportedNote')}'
          : '';
      return RestoreResult(
        success: true,
        message: AppLocalizations.t('backupRestoredVerified',
                {'count': totalRows}) +
            serverNote,
        restoredRows: totalRows,
        serverState: serverState,
        authenticity: issues.authenticity,
        checks: checks,
        mergedAccounts: mergedAccounts,
        sweptStubs: sweptStubs,
        leftoverDupes: leftoverDupes,
      );
    } on RestoreFailure catch (e) {
      return RestoreResult(success: false, message: e.message);
    } catch (e) {
      return RestoreResult(
        success: false,
        message: AppLocalizations.t('backupErrRestoreFailed'),
      );
    } finally {
      _restoreInProgress = false;
    }
  }

  /// Logical merge key for bank accounts. Cash names collapse by the
  /// engine's currency BUCKET (same rules as
  /// PersonalFinanceService.cashBucket/isCashAccount — called, never
  /// redefined); every other bank keys by (name, exact currency), so
  /// different banks or different currencies never merge.
  static String _accountMergeKey(String bankName, String currency) {
    final name = bankName.trim();
    final cur = currency.trim().toUpperCase();
    if (name == 'كاش' || name == 'Cash' || name == 'CASH') {
      return 'cash\u0000${PersonalFinanceService.cashBucket(cur)}\u0000checking';
    }
    return 'bank\u0000${name.toLowerCase()}\u0000$cur';
  }

  /// Merge PLAN for snapshot bank rows (pure planning, zero writes).
  /// Mutates ONLY the in-memory snapshot tables:
  /// - exact remote_id hit → normal upsert, no remap;
  /// - same logical key, other id → survivor keeps its row, takes snapshot
  ///   values (backup wins), snapshot id remaps to survivor; referencing
  ///   transaction/recurring mirror rows are rewritten to the survivor;
  /// - zero-balance stub duplicates of a key (reset artifacts) with no
  ///   referencing transactions are listed for sweeping (the caller deletes
  ///   them INSIDE the restore transaction — never here);
  /// - non-zero historical duplicates are left untouched and REPORTED
  ///   (never silently delete money).
  /// Snapshot cache rows are RAW table rows
  /// (user_id/entity_type/remote_id/data_json); existing rows come decoded
  /// from the mirror, where the stable id lives in `id` (== remote_id).
  Future<_MergePlan> _planMirrorMerge(
    Map tables,
    int userId,
  ) async {
    int remapped = 0;
    final sweepIds = <String>[];
    final repo = PersonalCacheRepository();
    List<Map<String, dynamic>> existingBanks;
    List<Map<String, dynamic>> existingTxs;
    try {
      existingBanks =
          await repo.getCollection(userId, 'personal_bank_account');
      existingTxs =
          await repo.getCollection(userId, 'personal_transaction');
    } catch (_) {
      return const _MergePlan.named(merged: 0, sweepIds: [], leftover: 0);
    }
    Map<String, dynamic> asMap(dynamic v) =>
        v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
    dynamic tryJson(String raw) {
      try {
        return jsonDecode(raw);
      } catch (_) {
        return null;
      }
    }

    // Existing rows keyed by logical merge key (stable id = `id`).
    final byKey = <String, List<Map<String, dynamic>>>{};
    for (final m in existingBanks) {
      final key = _accountMergeKey(
          m['bank_name']?.toString() ?? '', m['currency']?.toString() ?? '');
      byKey.putIfAbsent(key, () => []).add(m);
    }
    final existingTxAccountIds = <String>{};
    for (final m in existingTxs) {
      final aid = m['bank_account_id']?.toString() ?? '';
      if (aid.isNotEmpty) existingTxAccountIds.add(aid);
    }

    final cacheRows = tables['personal_entity_cache'];
    if (cacheRows is! List) return const _MergePlan.named(merged: 0, sweepIds: [], leftover: 0);
    // LIVE row maps (mutated in place — no copies, so FK rewrites stick).
    final liveRows = <Map<String, dynamic>>[];
    for (final r in cacheRows) {
      if (r is Map) {
        liveRows.add(Map<String, dynamic>.from(r));
      }
    }

    num balanceOf(Map<String, dynamic> m) {
      final b = m['balance'];
      if (b is num) return b;
      return num.tryParse(b?.toString() ?? '') ?? 0;
    }

    Map<String, dynamic>? decodeData(Map<String, dynamic> row) {
      final dj = row['data_json'];
      if (dj is Map) return Map<String, dynamic>.from(dj);
      if (dj is String) {
        final d = tryJson(dj);
        if (d is Map) return Map<String, dynamic>.from(d);
      }
      return null;
    }

    final remap = <String, String>{};
    final catRemap = <String, String>{};
    final catSweepIds = <String>[];
    // ── Budget-category logical merge (same budget + normalized name).
    // Categories recreated with fresh UUIDs (budget rebuilds, other
    // devices) must remap onto the live row instead of duplicating it —
    // otherwise per-category spent shows twice after a restore. First
    // snapshot row per key wins values (never fabricates money); absorbed
    // snapshot ids remap so their transactions keep pointing at the kept
    // row; zero-allocated unreferenced live orphans are swept.
    String catKey(String budgetId, String name) =>
        '${budgetId.trim()}\u0000${name.trim()}';
    num moneyOf(dynamic v) {
      if (v is num) return v;
      return num.tryParse(v?.toString() ?? '') ?? 0;
    }

    // Live categories by key (from embedded mirror budget rows).
    final liveCats = <String, List<Map<String, dynamic>>>{};
    List<Map<String, dynamic>> existingBudgets = const [];
    try {
      existingBudgets =
          await repo.getCollection(userId, 'personal_budget');
    } catch (_) {}
    for (final b in existingBudgets) {
      final bid = (b['id'] ?? '').toString();
      if (bid.isEmpty) continue;
      final cats = b['categories'];
      if (cats is! List) continue;
      for (final c in cats) {
        if (c is! Map) continue;
        final m = Map<String, dynamic>.from(c);
        final cid = (m['id'] ?? '').toString();
        if (cid.isEmpty) continue;
        liveCats
            .putIfAbsent(catKey(bid, m['name']?.toString() ?? ''), () => [])
            .add(m);
      }
    }
    // Referenced category ids (live + snapshot) — never sweep those.
    final referencedCatIds = <String>{};
    try {
      final txAll = await repo.getCollection(userId, 'personal_transaction');
      final recAll =
          await repo.getCollection(userId, 'personal_recurring_transaction');
      for (final t in [...txAll, ...recAll]) {
        final cid = (t['budget_category_id'] ?? '').toString();
        if (cid.isNotEmpty) referencedCatIds.add(cid);
      }
    } catch (_) {}

    // Fold every snapshot budget's categories by key: the first row per
    // key is kept — remapped onto the live survivor when one exists so
    // backup values win on upsert exactly like bank rows — and later
    // same-key rows are absorbed (their transactions remapped, their own
    // ids rewritten to the kept id so upserts converge). First wins
    // values: never fabricates money.
    final Map<String, String> snapKeptCat = {};
    for (final row in liveRows) {
      if (row['entity_type']?.toString() != 'personal_budget') continue;
      final dj = decodeData(row);
      if (dj == null) continue;
      final bid = (dj['id'] ?? row['remote_id'] ?? '').toString();
      final cats = dj['categories'];
      if (cats is! List) continue;
      final folded = <Map<String, dynamic>>[];
      for (final c in cats) {
        if (c is! Map) continue;
        final cm = Map<String, dynamic>.from(c);
        final cid = (cm['id'] ?? '').toString();
        if (cid.isEmpty) continue;
        final key = catKey(bid, cm['name']?.toString() ?? '');
        final keptId = snapKeptCat[key];
        if (keptId == null) {
          final group = liveCats[key] ?? const [];
          final exact =
              group.any((m) => (m['id'] ?? '').toString() == cid);
          if (!exact && group.isNotEmpty) {
            final survivor = group.first;
            final survivorId = (survivor['id'] ?? '').toString();
            if (survivorId.isNotEmpty && survivorId != cid) {
              catRemap[cid] = survivorId;
              cm['id'] = survivorId;
              remapped++;
              // Sweep zero-allocated, zero-spent, unreferenced live
              // orphans sharing the key (reset artifacts). Collected
              // here; deleted INSIDE the restore transaction by the
              // caller.
              for (final m in group) {
                final mid = (m['id'] ?? '').toString();
                if (mid == survivorId) continue;
                if (moneyOf(m['allocated_amount'] ?? m['amount']) != 0) {
                  continue;
                }
                if (moneyOf(m['spent_amount']) != 0) continue;
                if (referencedCatIds.contains(mid)) continue;
                if (!catSweepIds.contains(mid)) catSweepIds.add(mid);
              }
            }
          }
          snapKeptCat[key] = (cm['id'] ?? '').toString();
          folded.add(cm);
          continue;
        }
        // Intra-snapshot duplicate: fold FK references onto the kept id.
        if (keptId.isNotEmpty && keptId != cid) {
          catRemap[cid] = keptId;
          remapped++;
        }
      }
      dj['categories'] = folded;
      try {
        row['data_json'] = jsonEncode(dj);
      } catch (_) {}
    }
    // Point legacy snapshot category rows at their surviving ids too, so
    // their upserts overwrite instead of inserting duplicates.
    final legacyCats = tables['budget_categories'];
    if (legacyCats is List) {
      for (final r in legacyCats) {
        if (r is! Map) continue;
        final id = (r['id'] ?? '').toString();
        final target = catRemap[id];
        if (id.isNotEmpty && target != null && target.isNotEmpty) {
          r['id'] = target;
        }
      }
    }
    // Point snapshot tx/recurring rows at surviving category ids.
    for (final row in liveRows) {
      final et = row['entity_type']?.toString() ?? '';
      if (et != 'personal_transaction' &&
          et != 'personal_recurring_transaction') {
        continue;
      }
      final dj = decodeData(row);
      if (dj == null) continue;
      final cur = dj['budget_category_id']?.toString() ?? '';
      final target = catRemap[cur];
      if (target == null || target.isEmpty) continue;
      dj['budget_category_id'] = target;
      try {
        row['data_json'] = jsonEncode(dj);
      } catch (_) {}
    }

    for (final row in liveRows) {
      if (row['entity_type']?.toString() != 'personal_bank_account') continue;
      final snapId = row['remote_id']?.toString() ?? '';
      if (snapId.isEmpty) continue;
      final sData = decodeData(row) ?? <String, dynamic>{};
      final key = _accountMergeKey(
        sData['bank_name']?.toString() ?? '',
        sData['currency']?.toString() ?? 'SAR',
      );
      final group = byKey[key] ?? const [];
      if (group.any((m) => (m['id']?.toString() ?? '') == snapId)) {
        continue; // exact identity present: plain upsert, no remap
      }
      if (group.isEmpty) continue; // brand new: plain insert
      Map<String, dynamic> survivor = group.first;
      for (final m in group) {
        if (balanceOf(m) != 0) {
          survivor = m;
          break;
        }
      }
      final survivorId = survivor['id']?.toString() ?? '';
      if (survivorId.isEmpty || survivorId == snapId) continue;
      remap[snapId] = survivorId;
      remapped++;
      // Point the snapshot row at the survivor (upsert then overwrites it
      // with backup values instead of creating a duplicate row).
      row['remote_id'] = survivorId;
      final dj = decodeData(row);
      if (dj != null) {
        dj['id'] = survivorId;
        try {
          row['data_json'] = jsonEncode(dj);
        } catch (_) {}
      }
      // Sweep zero-balance stubs sharing the key (reset artifacts): only
      // when nothing (snapshot or existing) references them. IDs are
      // collected here; the caller deletes them INSIDE the restore
      // transaction so a later failure rolls everything back.
      for (final m in group) {
        final mid = m['id']?.toString() ?? '';
        if (mid == survivorId || balanceOf(m) != 0) continue;
        var referenced = existingTxAccountIds.contains(mid);
        if (!referenced) {
          for (final t in liveRows) {
            if (t['entity_type']?.toString() != 'personal_transaction' &&
                t['entity_type']?.toString() !=
                    'personal_recurring_transaction') {
              continue;
            }
            final td = decodeData(t);
            if ((td?['bank_account_id']?.toString() ?? '') == mid) {
              referenced = true;
              break;
            }
          }
        }
        if (referenced) continue;
        sweepIds.add(mid);
      }
    }

    if (remap.isNotEmpty) {
      // Rewrite FKs inside snapshot mirror tx/recurring rows.
      for (final row in liveRows) {
        final et = row['entity_type']?.toString() ?? '';
        if (et != 'personal_transaction' &&
            et != 'personal_recurring_transaction') {
          continue;
        }
        final dj = decodeData(row);
        if (dj == null) continue;
        final cur = dj['bank_account_id']?.toString() ?? '';
        final target = remap[cur];
        if (target == null) continue;
        dj['bank_account_id'] = target;
        try {
          row['data_json'] = jsonEncode(dj);
        } catch (_) {}
      }
    }
    tables['personal_entity_cache'] = liveRows;

    // Count leftover non-zero duplicates for transparency.
    var leftover = 0;
    try {
      final after = await repo.getCollection(userId, 'personal_bank_account');
      final seen = <String>{};
      for (final m in after) {
        final key = _accountMergeKey(
            m['bank_name']?.toString() ?? '',
            m['currency']?.toString() ?? '');
        if (!seen.add(key)) leftover++;
      }
    } catch (_) {}
    return _MergePlan.named(
        merged: remapped,
        sweepIds: sweepIds,
        catSweepIds: catSweepIds,
        leftover: leftover);
  }

  dynamic _tryJson(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  /// Upserts one snapshot row by stable identity inside the restore
  /// transaction. Mirror cache: (user_id, entity_type, remote_id). Legacy
  /// tables: `id`. Present rows take backup values; missing rows are
  /// inserted; anything else is untouched. No fuzzy matching anywhere.
  Future<void> _upsertRow(
    dynamic tx,
    String table,
    Map<String, dynamic> rowMap, {
    required String nowIso,
  }) async {
    if (table == 'personal_entity_cache') {
      final entityType = rowMap['entity_type']?.toString() ?? '';
      final remoteId = rowMap['remote_id']?.toString() ?? '';
      if (entityType.isEmpty || remoteId.isEmpty) return;
      final rowUserId = rowMap['user_id'] is int
          ? rowMap['user_id'] as int
          : int.tryParse(rowMap['user_id']?.toString() ?? '');
      if (rowUserId == null) return;
      final dataJson = rowMap['data_json']?.toString() ?? '{}';
      final updated = await tx.update(
        table,
        {'data_json': dataJson, 'updated_at': nowIso},
        where: 'user_id = ? AND entity_type = ? AND remote_id = ?',
        whereArgs: [rowUserId, entityType, remoteId],
      );
      if (updated == 0) {
        await tx.insert(table, {
          'user_id': rowUserId,
          'entity_type': entityType,
          'remote_id': remoteId,
          'data_json': dataJson,
          'updated_at': nowIso,
        });
      }
      return;
    }
    if (table == 'users') return; // login state is never rewritten
    final id = rowMap['id'];
    if (id == null) return;
    final values = Map<String, dynamic>.from(rowMap)..remove('id');
    if (values.isEmpty) return;
    final updated = await tx.update(
      table,
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
    if (updated == 0) {
      await tx.insert(table, rowMap);
    }
  }

  /// Capability probe: only servers exposing the verified-restore contract
  /// (HMAC key route) may receive a bulk restore. Old servers answer 404 —
  /// we skip the server layer instead of posting a shape they would
  /// misinterpret (their legacy endpoint wipes before inserting).
  /// Offline is reported distinctly so the caller defers (not skips).
  Future<_ServerProbe> _probeServerRestore() async {
    try {
      await _server.fetchHmacKey();
      return _ServerProbe.supported;
    } on ServerBackupException catch (e) {
      // Route exists (key parse anomaly) — capable; the bulk call decides.
      if (e.code == 'key_empty') return _ServerProbe.supported;
      return _ServerProbe.unsupported;
    } on DioException catch (e) {
      if ((e.response?.statusCode ?? 0) == 404) {
        return _ServerProbe.unsupported;
      }
      if (_isOfflineDio(e)) return _ServerProbe.offline;
      rethrow;
    }
  }

  String _pendingOrigin(Map<String, dynamic> data, String snapshotOrigin) {
    if (snapshotOrigin.startsWith('server:')) return snapshotOrigin;
    return 'device:${data['backup_id']?.toString() ?? ''}';
  }

  /// Server layer of restore: POSTs the snapshot `entities` to the bulk
  /// endpoint and demands a VERIFIED response.
  /// Throws [RestoreFailure] — loud, never silent. No fallback path exists
  /// by design (the old lossy per-item fallback was removed).
  Future<Map<String, dynamic>> _restoreServerEntities(
      Map<String, dynamic> data) async {
    final svc = _financeService;
    if (svc == null) throw RestoreFailure(AppLocalizations.t('backupErrNoService'));
    final entities = data['entities'];
    if (entities is! Map) {
      throw RestoreFailure(AppLocalizations.t('backupErrNoEntities'));
    }
    late final Map<String, dynamic> result;
    try {
      final dynamic raw = await svc.bulkRestoreV2(
        schemaVersion: data['schema_version']?.toString() ?? '4.0.0',
        backupId: data['backup_id']?.toString(),
        entities: Map<String, dynamic>.from(entities),
      );
      if (raw is! Map) throw RestoreFailure(AppLocalizations.t('backupErrBadServerReply'));
      result = Map<String, dynamic>.from(raw);
    } on RestoreFailure {
      rethrow;
    } catch (e) {
      if (e is DioException && _isOfflineDio(e)) {
        throw RestoreFailure(AppLocalizations.t('backupServerOffline'), offline: true);
      }
      throw RestoreFailure(_serverErrorMessage(e));
    }
    if (result['verified'] != true) {
      throw RestoreFailure(AppLocalizations.t('backupErrServerUnverified'));
    }
    return result;
  }

  bool _isOfflineDio(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.unknown:
        return (e.message ?? '').contains('SocketException');
      default:
        return false;
    }
  }

  String _serverErrorMessage(Object e) {
    if (e is DioException) {
      final code = e.response?.statusCode ?? 0;
      final body = e.response?.data;
      String detail = '';
      try {
        if (body is Map) {
          final d = body['detail'];
          if (d is Map && d['errors'] is List) {
            detail = ': ${(d['errors'] as List).take(3).join('; ')}';
          } else if (d is String) {
            detail = ': $d';
          }
        }
      } catch (_) {}
      if (code == 422) {
        return AppLocalizations.t('backupErrServerRejected') + detail;
      }
      if (code == 401 || code == 403) {
        return AppLocalizations.t('backupErrServerForbidden');
      }
      if (code >= 500) return AppLocalizations.t('backupErrServerError');
    }
    return AppLocalizations.t('backupErrServerFailed');
  }

  /// Re-reads every restored table and proves each SNAPSHOT row is present
  /// with exact values. Pre-existing rows outside the snapshot are allowed
  /// (safe-merge never deletes) — only snapshot rows must match. Mirror
  /// cache matches by stable remote_id; legacy tables by id; `users` is
  /// skipped (never rewritten). `updated_at` of the mirror cache is
  /// excluded since restore re-stamps it by design. Returns mismatches
  /// (empty = verified). Message list is capped to stay readable.
  Future<List<String>> _verifyLocalRestore(Map<String, dynamic> data) async {
    final problems = <String>[];
    final tables = data['tables'];
    if (tables is! Map) return ['no_tables'];
    for (final table in restoreTables) {
      if (table == 'users') continue;
      final want = tables[table];
      if (want is! List) continue;
      List<Map<String, dynamic>> have;
      try {
        have = await DatabaseHelper.query(table);
      } catch (_) {
        problems.add('unreadable:$table');
        continue;
      }
      String rowKey(Map<String, dynamic> r, int index) {
        if (table == 'personal_entity_cache') {
          final et = r['entity_type']?.toString() ?? '';
          final rid = r['remote_id']?.toString() ?? '';
          if (et.isNotEmpty && rid.isNotEmpty) return '$et::$rid';
        }
        return r['id']?.toString() ?? 'row$index';
      }

      final wantById = <String, Map<String, dynamic>>{};
      var wi = 0;
      for (final r in want) {
        if (r is Map) {
          wantById[rowKey(Map<String, dynamic>.from(r), wi++)] =
              Map<String, dynamic>.from(r);
        }
      }
      final haveById = <String, Map<String, dynamic>>{};
      var hi = 0;
      for (final r in have) {
        haveById[rowKey(Map<String, dynamic>.from(r), hi++)] =
            Map<String, dynamic>.from(r);
      }
      final missing = wantById.keys.toSet().difference(haveById.keys.toSet());
      if (missing.isNotEmpty) {
        problems.add('$table: ${missing.length} ids missing');
        continue;
      }
      var fieldDiffs = 0;
      for (final id in wantById.keys) {
        final w = wantById[id]!;
        final h = haveById[id]!;
        for (final key in w.keys) {
          if (table == 'personal_entity_cache' &&
              (key == 'updated_at' || key == 'id')) {
            continue; // re-stamped / autoincrement by design; the stable
            // identity is remote_id and entity time lives in data_json
          }
          if (!_fieldEquals(w[key], h[key])) {
            fieldDiffs++;
            if (problems.length < 5 && fieldDiffs <= 3) {
              problems.add('$table:$id field $key differs');
            }
          }
        }
        if (fieldDiffs > 20) break;
      }
      if (fieldDiffs > 0 && !problems.any((p) => p.startsWith('$table:'))) {
        problems.add('$table: $fieldDiffs field values differ');
      }
    }
    return problems;
  }

  /// Exact-enough field equality: numeric vs numeric by value (covers
  /// int/double storage forms of the same number), everything else by
  /// exact string form. Never rounds, never converts currency.
  static bool _fieldEquals(dynamic a, dynamic b) {
    if (a == null || b == null) return a == null && b == null;
    if (a is num && b is num) return a == b;
    if (a is num || b is num) {
      final pa = num.tryParse(a.toString());
      final pb = num.tryParse(b.toString());
      if (pa != null && pb != null) return pa == pb;
      return false;
    }
    return a.toString() == b.toString();
  }

  // ── auto backup (file update, NOT sync) ──

  Future<BackupResult> autoSync({int? localUserId, String? serverUserUuid}) async {
    if (_resetGuard) {
      return const BackupResult(
        success: false,
        message: 'busy',
        filePath: null,
      );
    }
    if (_restoreInProgress) {
      return BackupResult(
        success: false,
        message: AppLocalizations.t('backupSyncPaused'),
        filePath: null,
      );
    }
    if (_syncInProgress || _backupInProgress) {
      return BackupResult(
        success: false,
        message: AppLocalizations.t('backupSyncRunning'),
        filePath: null,
      );
    }
    final identity =
        _resolveIdentity(localUserId: localUserId, serverUserUuid: serverUserUuid);
    if (identity == null) {
      // Background path: nothing to show; skip silently instead of
      // snapshotting as a wrong user.
      debugPrint('BackupService.autoSync: unknown identity — skipped');
      return const BackupResult(
        success: false,
        message: 'busy',
        filePath: null,
      );
    }

    _syncInProgress = true;
    await _setSyncStatus(SyncStatus.syncing);

    try {
      // Complete a pending server restore first (offline restore earlier).
      await completePendingServerRestore();

      var savedUri = await getSavedUri();
      if (savedUri == null || savedUri.isEmpty) {
        // After reinstall prefs are cleared but files remain in Download — discover the latest.
        try {
          final files = await listBackups();
          if (files.isNotEmpty) {
            savedUri = files.first.uri;
            await _saveFileInfo(
              uri: savedUri,
              filePath: files.first.relativePath + files.first.name,
              fileName: files.first.name,
            );
          }
        } catch (_) {}
      }
      if (savedUri == null || savedUri.isEmpty) {
        _syncInProgress = false;
        await _setSyncStatus(SyncStatus.failed);
        return BackupResult(
          success: false,
          message: AppLocalizations.t('backupNoBackup'),
          filePath: null,
        );
      }

      final sealed = await buildSnapshot(
        localUserId: identity.localUserId,
        serverUserUuid: identity.serverUserUuid,
      );

      // ── Safety guard: skip auto-backup if data decreased (likely reset/clear) ──
      final newRowCount = _countRows(sealed);
      final p = await _prefs;
      final lastSyncCount = p.getInt(_kLastSyncRowCountKey) ?? 0;
      if (lastSyncCount > 0 && newRowCount < lastSyncCount) {
        debugPrint('BackupService: autoSync skipped — data decreased ($newRowCount < $lastSyncCount)');
        _syncInProgress = false;
        await _setSyncStatus(SyncStatus.synced);
        return BackupResult(
          success: true,
          message: AppLocalizations.t('backupSyncSkipped'),
          filePath: await getSavedFilePath(),
          fileUri: savedUri,
        );
      }

      final jsonContent = const JsonEncoder.withIndent('  ').convert(sealed);
      final Map<dynamic, dynamic> nativeResult = await _channel.invokeMethod(
        'updateExistingBackup',
        {'uri': savedUri, 'content': jsonContent},
      );

      final success = nativeResult['success'] == true;
      if (!success) {
        _syncInProgress = false;
        await _setSyncStatus(SyncStatus.failed);
        return BackupResult(
          success: false,
          message: nativeResult['message']?.toString() ??
              AppLocalizations.t('backupErrSyncFailed'),
          filePath: await getSavedFilePath(),
        );
      }

      // The native layer rotates to a new URI (atomic replace): persist
      // it, then retire exactly the previous URI (never by name match).
      final newUri = nativeResult['uri']?.toString() ?? savedUri;
      if (newUri.isNotEmpty && newUri != savedUri) {
        await _saveFileInfo(
          uri: newUri,
          filePath: nativeResult['filePath']?.toString() ?? '',
          fileName: nativeResult['fileName']?.toString() ?? _kBackupFileName,
        );
      }

      final verified = await _verifyStoredContent(newUri, jsonContent);
      if (!verified) {
        _syncInProgress = false;
        await _setSyncStatus(SyncStatus.failed);
        return BackupResult(
          success: false,
          message: AppLocalizations.t('backupSyncVerifyFailed'),
          filePath: await getSavedFilePath(),
        );
      }
      // Verified: now (and only now) retire the exact previous URI.
      if (newUri != savedUri) {
        await _retireUri(savedUri);
      }

      final now = DateTime.now().toIso8601String();
      await p.setString(_kLastSyncTimeKey, now);
      await p.setInt(_kLastSyncRowCountKey, newRowCount);
      await _setSyncStatus(SyncStatus.synced);

      _syncInProgress = false;

      return BackupResult(
        success: true,
        message: AppLocalizations.t('backupSyncedOk'),
        filePath: await getSavedFilePath(),
        fileUri: newUri,
        fileSize: (nativeResult['fileSize'] as num?)?.toInt() ?? 0,
        createdAt: now,
      );
    } catch (e) {
      _syncInProgress = false;
      await _setSyncStatus(SyncStatus.failed);
      return BackupResult(
        success: false,
        message: AppLocalizations.t('backupErrSync'),
        filePath: null,
      );
    }
  }

  /// Retries a deferred server restore (server layer only — local data is
  /// never touched). Pending values are `device:<backup_id>` (re-read the
  /// device file) or `server:<backup_id>` (re-download that version).
  /// Returns true when the server layer verified and the flag cleared.
  /// Idempotent: upsert-by-ID can be retried safely, never duplicating.
  Future<bool> completePendingServerRestore() async {
    try {
      final pending = await getPendingServerRestore();
      if (pending == null || pending.isEmpty) return true;
      if (_financeService == null) return false;
      Map<String, dynamic>? decoded;
      if (pending.startsWith('server:')) {
        final id = pending.substring('server:'.length);
        if (id.isEmpty) {
          await _setPendingServerRestore(null);
          return false;
        }
        Map<String, dynamic> meta;
        try {
          meta = await _server.listBackups();
        } catch (_) {
          return false;
        }
        final found = (meta['backups'] as List? ?? []).whereType<Map>().any(
            (b) => b['id']?.toString() == id);
        if (!found) {
          await _setPendingServerRestore(null);
          return false;
        }
        try {
          final bytes = await _server.downloadBackup(id);
          final parsed = jsonDecode(utf8.decode(bytes));
          if (parsed is Map<String, dynamic>) decoded = parsed;
        } catch (_) {
          return false;
        }
      } else {
        final backupId = pending.startsWith('device:')
            ? pending.substring('device:'.length)
            : pending;
        final uri = await getSavedUri();
        if (uri == null || uri.isEmpty) {
          await _setPendingServerRestore(null);
          return false;
        }
        final doc = await _readDocument(uri);
        final content = doc?['content'] as String?;
        if (content == null || content.isEmpty) return false;
        final parsed = jsonDecode(content);
        if (parsed is! Map<String, dynamic>) return false;
        if ((parsed['backup_id']?.toString() ?? '') != backupId) {
          // Rotation superseded the pending snapshot: converge with the
          // CURRENT file instead of dropping the intent — upsert is safe
          // and the current file is a superset of the restored state.
          // The flag clears only on verified success below.
          debugPrint(
              'BackupService: pending snapshot superseded; converging current file');
        }
        decoded = parsed;
      }
      if (decoded == null) return false;
      final hmacKey = await _server.getCachedHmacKey();
      final issues =
          BackupIntegrity.validateSnapshot(decoded, hmacKeyB64: hmacKey);
      if (!issues.ok) {
        await _setPendingServerRestore(null);
        return false;
      }
      await _restoreServerEntities(decoded);
      await _setPendingServerRestore(null);
      debugPrint('BackupService: pending server restore completed ($pending)');
      return true;
    } catch (_) {
      // Stays pending; retried on the next tick or by explicit retry.
      return false;
    }
  }

  void startAutoSyncTimer() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
      final enabled = await getAutoSyncEnabled();
      if (enabled) {
        await autoSync();
      }
    });
  }

  void stopAutoSyncTimer() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
  }

  Future<void> onDataChanged() async {
    if (_restoreInProgress || _resetGuard) return;
    final enabled = await getAutoSyncEnabled();
    if (!enabled) return;

    // Short debounce: coalesce bursts, then snapshot the settled state.
    // Bound identity is resolved inside autoSync (refuses when unknown).
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 800), () async {
      if (!_syncInProgress &&
          !_restoreInProgress &&
          !_backupInProgress &&
          !_resetGuard) {
        await autoSync();
      }
    });
  }

  void dispose() {
    stopAutoSyncTimer();
    _debounceTimer?.cancel();
    if (identical(_activeHookOwner, this)) _activeHookOwner = null;
  }

  // ── server backup flows ──

  /// Builds a fresh snapshot and uploads it as a NEW server version.
  /// Offline (or any failure) → explicit failure, previous versions untouched.
  Future<ServerBackupResult> uploadServerBackup({
    int? localUserId,
    String? serverUserUuid,
    void Function(String stage, double progress)? onProgress,
  }) async {
    if (_backupInProgress || _restoreInProgress || _resetGuard) {
      return ServerBackupResult.fail(AppLocalizations.t('backupRestoreBusy'));
    }
    final identity =
        _resolveIdentity(localUserId: localUserId, serverUserUuid: serverUserUuid);
    if (identity == null) {
      return ServerBackupResult.fail(
          AppLocalizations.t('backupErrNoIdentity'));
    }
    _backupInProgress = true;
    try {
      onProgress?.call('collect', 0.1);
      String hmacKey = await _server.getCachedHmacKey();
      if (hmacKey.isEmpty) {
        onProgress?.call('key', 0.15);
        try {
          hmacKey = await _server.fetchHmacKey();
        } catch (e) {
          return ServerBackupResult.fail(
              AppLocalizations.t('backupServerOffline'));
        }
      }
      final sealed = await buildSnapshot(
        localUserId: identity.localUserId,
        serverUserUuid: identity.serverUserUuid,
        source: 'server',
        onProgress: onProgress,
      );
      // Re-seal with the (possibly just fetched) key.
      final resealed = BackupIntegrity.sealSnapshot(sealed, hmacKeyB64: hmacKey);
      final bytes =
          Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(resealed)));
      onProgress?.call('upload', 0.85);
      final createdName =
          'FYONA_ERP_Backup_v_${DateTime.now().millisecondsSinceEpoch}.json';
      late final Map<String, dynamic> meta;
      try {
        meta = await _server.uploadBackup(bytes, createdName);
      } catch (e) {
        return ServerBackupResult.fail(_mapServerFailure(e));
      }
      final id = meta['id']?.toString() ?? '';
      final version = (meta['version'] as num?)?.toInt() ?? 0;
      final size = (meta['size_bytes'] as num?)?.toInt() ?? bytes.length;
      final count = (meta['record_count'] as num?)?.toInt() ?? 0;
      if (id.isNotEmpty) {
        await _saveLastServerBackup(
            id: id, version: version, sizeBytes: size, recordCount: count);
      }
      onProgress?.call('done', 1.0);
      return ServerBackupResult.ok(meta);
    } catch (e) {
      return ServerBackupResult.fail(_mapServerFailure(e));
    } finally {
      _backupInProgress = false;
    }
  }

  Future<ServerBackupResult> updateServerBackup({
    required String backupId,
    int? localUserId,
    String? serverUserUuid,
    void Function(String stage, double progress)? onProgress,
  }) async {
    if (_backupInProgress || _restoreInProgress || _resetGuard) {
      return ServerBackupResult.fail(AppLocalizations.t('backupRestoreBusy'));
    }
    final identity =
        _resolveIdentity(localUserId: localUserId, serverUserUuid: serverUserUuid);
    if (identity == null) {
      return ServerBackupResult.fail(AppLocalizations.t('backupErrNoIdentity'));
    }
    _backupInProgress = true;
    try {
      onProgress?.call('collect', 0.1);
      String hmacKey = await _server.getCachedHmacKey();
      if (hmacKey.isEmpty) {
        onProgress?.call('key', 0.15);
        try {
          hmacKey = await _server.fetchHmacKey();
        } catch (e) {
          return ServerBackupResult.fail(AppLocalizations.t('backupServerOffline'));
        }
      }
      final sealed = await buildSnapshot(
        localUserId: identity.localUserId,
        serverUserUuid: identity.serverUserUuid,
        source: 'server',
        onProgress: onProgress,
      );
      final resealed = BackupIntegrity.sealSnapshot(sealed, hmacKeyB64: hmacKey);
      final bytes = Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(resealed)));
      onProgress?.call('upload', 0.85);
      late final Map<String, dynamic> meta;
      try {
        meta = await _server.updateBackup(backupId, bytes, 'FYONA_ERP_Backup.json');
      } catch (e) {
        return ServerBackupResult.fail(_mapServerFailure(e));
      }
      final version = (meta['version'] as num?)?.toInt() ?? 0;
      final size = (meta['size_bytes'] as num?)?.toInt() ?? bytes.length;
      final count = (meta['record_count'] as num?)?.toInt() ?? 0;
      await _saveLastServerBackup(id: backupId, version: version, sizeBytes: size, recordCount: count);
      onProgress?.call('done', 1.0);
      return ServerBackupResult.ok(meta);
    } catch (e) {
      return ServerBackupResult.fail(_mapServerFailure(e));
    } finally {
      _backupInProgress = false;
    }
  }

  String _mapServerFailure(Object e) {
    final code = serverFailureCode(e);
    switch (code) {
      case 'server_offline':
        return AppLocalizations.t('backupServerOffline');
      case 'server_forbidden':
        return AppLocalizations.t('backupErrServerForbidden');
      case 'server_not_found':
        return AppLocalizations.t('backupErrServerGone');
      case 'server_integrity':
        return AppLocalizations.t('backupErrChecksum');
      case 'server_too_large':
        return AppLocalizations.t('backupErrTooLarge');
      case 'server_rejected':
        return AppLocalizations.t('backupErrServerRejected');
      case 'server_error':
        return AppLocalizations.t('backupErrServerError');
      default:
        return AppLocalizations.t('backupErrServerFailed');
    }
  }

  Future<List<Map<String, dynamic>>> fetchServerBackups() async {
    try {
      final data = await _server.listBackups();
      return data['backups'] ?? const [];
    } catch (_) {
      return const [];
    }
  }

  Future<ServerBackupResult> deleteServerBackup(String id) async {
    try {
      await _server.deleteBackup(id);
      await _clearLastServerBackupIf(id);
      return ServerBackupResult.ok({'id': id});
    } catch (e) {
      return ServerBackupResult.fail(_mapServerFailure(e));
    }
  }

  /// Downloads a server version and restores it through the standard
  /// validated pipeline (ownership + verify included).
  Future<RestoreResult> restoreServerBackup(
    String id, {
    required int localUserId,
    required String serverUserUuid,
    void Function(String stage, double progress)? onProgress,
  }) async {
    Uint8List bytes;
    try {
      bytes = await _server.downloadBackup(id);
    } catch (e) {
      return RestoreResult(success: false, message: _mapServerFailure(e));
    }
    final read = await readBackupContent(
      utf8.decode(bytes),
      serverUserUuid: serverUserUuid,
      localUserId: localUserId,
    );
    if (!read.success || read.data == null) {
      return RestoreResult(success: false, message: read.message);
    }
    return restoreFromBackup(
      read.data!,
      userId: localUserId,
      serverUserUuid: serverUserUuid,
      onProgress: onProgress,
      snapshotOrigin: 'server:$id',
    );
  }

  // ── native helpers (unchanged surface) ──

  static Future<void> openFileInManager(String uri) async {
    try {
      await _channel.invokeMethod('openFileInManager', {'uri': uri});
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> pickDocument({bool anyType = false}) async {
    try {
      final Map<dynamic, dynamic> result = await _channel.invokeMethod(
        'pickDocument',
        {'anyType': anyType},
      );
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> pickAnyDocument() => pickDocument(anyType: true);

  static Future<Map<String, dynamic>?> selectBackupFolder() async {
    try {
      final Map<dynamic, dynamic> result = await _channel.invokeMethod('pickBackupFolder');
      if (result['success'] != true) return null;
      final uri = result['uri'] as String? ?? '';
      if (uri.isEmpty) return null;
      final p = await _prefs;
      await p.setString(_kSavedTreeUriKey, uri);
      await p.setString(_kSavedTreeNameKey, result['name'] as String? ?? '');
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> getSavedTreeUri() async {
    final p = await _prefs;
    return p.getString(_kSavedTreeUriKey);
  }

  static Future<String?> getSavedTreeName() async {
    final p = await _prefs;
    return p.getString(_kSavedTreeNameKey);
  }

  static Future<bool> deleteBackup(String uri) async {
    try {
      final Map<dynamic, dynamic> result =
          await _channel.invokeMethod('deleteBackupByUri', {'uri': uri});
      final ok = result['success'] == true;
      if (ok) {
        final p = await _prefs;
        if (p.getString(_kSavedUriKey) == uri) {
          await _clearSavedFileInfo();
        }
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>?> requestStoragePermission() async {
    try {
      final Map<dynamic, dynamic> result = await _channel.invokeMethod('requestStoragePermission');
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return null;
    }
  }

  static Future<List<BackupFileInfo>> listBackups() async {
    try {
      final Map<dynamic, dynamic> result = await _channel.invokeMethod('listBackups');
      if (result['success'] != true) return [];
      final list = result['backups'] as List<dynamic>? ?? [];
      return list.map((e) => BackupFileInfo.fromMap(Map<String, dynamic>.from(e))).toList();
    } catch (_) {
      return [];
    }
  }
}

class BackupFileInfo {
  final String uri;
  final String name;
  final int size;
  final int dateModified;
  final String relativePath;

  BackupFileInfo({
    required this.uri,
    required this.name,
    required this.size,
    required this.dateModified,
    required this.relativePath,
  });

  factory BackupFileInfo.fromMap(Map<String, dynamic> m) => BackupFileInfo(
    uri: m['uri'] ?? '',
    name: m['name'] ?? '',
    size: m['size'] ?? 0,
    dateModified: m['dateModified'] ?? 0,
    relativePath: m['relativePath'] ?? '',
  );

  DateTime get date => DateTime.fromMillisecondsSinceEpoch(dateModified * 1000);

  String get formattedSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class BackupResult {
  final bool success;
  final String message;
  final String? filePath;
  final String? fileUri;
  final int? fileSize;
  final String? createdAt;
  final bool fileDeleted;

  /// Snapshot record count (for the result card). -1 when unknown.
  final int recordCount;

  const BackupResult({
    required this.success,
    required this.message,
    this.filePath,
    this.fileUri,
    this.fileSize,
    this.createdAt,
    this.fileDeleted = false,
    this.recordCount = -1,
  });
}

class BackupReadResult {
  final bool success;
  final String message;
  final Map<String, dynamic>? data;
  final BackupValidation? validation;
  final String? fileName;

  BackupReadResult({
    required this.success,
    required this.message,
    this.data,
    this.validation,
    this.fileName,
  });
}

class RestoreResult {
  final bool success;
  final String message;
  final int restoredRows;
  final String serverState;
  final String authenticity;

  /// Which verification stages passed: any of
  /// 'data' (all snapshot rows present with exact values),
  /// 'relations' (FK/duplicate/shape recheck clean),
  /// 'server' (server layer verified). Shown as a checklist on success.
  final List<String> checks;

  /// Logical account merges applied during local restore (deduplication
  /// report): remapped snapshot rows, swept zero-stubs, leftover non-zero
  /// duplicates kept deliberately (never silently deleted).
  final int mergedAccounts;
  final int sweptStubs;
  final int leftoverDupes;

  RestoreResult({
    required this.success,
    required this.message,
    this.restoredRows = 0,
    this.serverState = 'skipped',
    this.authenticity = 'unverified',
    this.checks = const [],
    this.mergedAccounts = 0,
    this.sweptStubs = 0,
    this.leftoverDupes = 0,
  });
}

class RestoreFailure implements Exception {
  final String message;
  final bool offline;
  RestoreFailure(this.message, {this.offline = false});
}

enum _ServerProbe { supported, unsupported, offline }

/// Merge plan produced before the restore transaction: how many snapshot
/// rows were remapped onto survivors, which stub ids to sweep INSIDE the
/// transaction, and how many pre-existing duplicates were seen.
class _MergePlan {
  final int merged;
  final List<String> sweepIds;
  final List<String> catSweepIds;
  final int leftover;
  const _MergePlan(this.merged, this.sweepIds, this.leftover,
      [this.catSweepIds = const []]);
  const _MergePlan.named(
      {required this.merged,
      required this.sweepIds,
      required this.leftover,
      this.catSweepIds = const []});
}

class BackupValidation {
  final bool isValid;
  final List<String> errors;
  final String? schemaVersion;
  final String? createdAt;
  final bool hasData;
  final String authenticity;
  final int recordCount;

  BackupValidation({
    required this.isValid,
    required this.errors,
    this.schemaVersion,
    this.createdAt,
    required this.hasData,
    this.authenticity = 'unverified',
    this.recordCount = 0,
  });
}

class ServerBackupResult {
  final bool success;
  final String message;
  final Map<String, dynamic>? meta;

  const ServerBackupResult._(this.success, this.message, this.meta);

  factory ServerBackupResult.ok(Map<String, dynamic> meta) =>
      ServerBackupResult._(true, '', meta);

  factory ServerBackupResult.fail(String message) =>
      ServerBackupResult._(false, message, null);
}
