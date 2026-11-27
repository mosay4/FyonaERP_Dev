import 'dart:async';

import 'package:fyona_flutter/core/backup/presentation/backup_list_sheet.dart';
import 'package:fyona_flutter/core/backup/presentation/operation_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../auth/presentation/widgets/app_pin_sheet.dart';
import '../../di/personal_providers.dart';
import '../../domain/services/backup_service.dart';
import '../providers/personal_providers.dart';

/// Backup home: source selector, one status card, two primary actions,
/// management sheet, secondary auto-update toggle. Same black/red identity,
/// Cairo type, card language as the rest of the app.
class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});

  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  BackupSource _source = BackupSource.device;
  bool _autoUpdate = false;
  bool _busy = false;

  // Last-backup summary per source.
  String? _deviceLastTime;
  int? _deviceLastSize;
  int? _deviceLastCount;
  String _deviceState = 'none'; // ok | unverified | invalid | none
  Map<String, dynamic>? _serverLast;

  bool _pendingServerRestore = false;
  String? _errorBanner;
  String? _progressStage;
  double? _progressValue;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  int get _localUserId {
    try {
      return ref.read(personalFinanceServiceProvider).currentUserId;
    } catch (_) {
      return 1;
    }
  }

  String get _serverUserUuid => ref.read(authProvider).user?.id ?? '';

  // ── state ──

  Future<void> _loadState() async {
    final enabled = await BackupService.getAutoSyncEnabled();
    final source = await BackupService.getBackupSource();
    final pending = await BackupService.getPendingServerRestore();
    String? deviceTime;
    int? deviceSize;
    int? deviceCount;
    String deviceState = 'none';
    Map<String, dynamic>? serverLast;
    if (source == BackupSource.device) {
      final bs = ref.read(backupServiceProvider);
      deviceTime = await BackupService.getLastBackupTime();
      final uri = await BackupService.getSavedUri();
      if (uri != null && uri.isNotEmpty) {
        try {
          final doc = await BackupService.readDocumentContent(uri);
          final content = doc?['content'] as String?;
          if (content != null && content.isNotEmpty) {
            final read = await bs.readBackupContent(
              content,
              serverUserUuid: _serverUserUuid,
              localUserId: _localUserId,
            );
            deviceSize = content.length;
            deviceCount = read.validation?.recordCount;
            deviceState =
                read.success ? (read.validation?.authenticity == 'verified' ? 'ok' : 'unverified') : 'invalid';
            if (!read.success) deviceTime = null;
          }
        } catch (_) {}
      }
      // Fallback after reinstall: prefs cleared → discover files in Download/FYONA ERP directly.
      if ((deviceTime == null || deviceSize == null) ) {
        try {
          final files = await BackupService.listBackups();
          if (files.isNotEmpty) {
            final f = files.first;
            try {
              final doc = await BackupService.readDocumentContent(f.uri);
              final content = doc?['content'] as String?;
              if (content != null && content.isNotEmpty) {
                final read = await bs.readBackupContent(
                  content,
                  serverUserUuid: _serverUserUuid,
                  localUserId: _localUserId,
                );
                if (read.success) {
                  deviceTime = f.date.toIso8601String();
                  deviceSize = f.size;
                  deviceCount = read.validation?.recordCount;
                  deviceState = read.validation?.authenticity == 'verified' ? 'ok' : 'unverified';
                }
              }
            } catch (_) {
              deviceTime = f.date.toIso8601String();
              deviceSize = f.size;
              deviceState = 'unverified';
            }
          }
        } catch (_) {}
      }
    } else {
      serverLast = await BackupService.getLastServerBackup();
      if (serverLast == null) {
        try {
          final bs = ref.read(backupServiceProvider);
          final list = await bs.fetchServerBackups();
          if (list.isNotEmpty) serverLast = list.first;
        } catch (_) {}
      }
    }
    if (!mounted) return;
    setState(() {
      _autoUpdate = enabled;
      _source = source;
      _deviceLastTime = deviceTime;
      _deviceLastSize = deviceSize;
      _deviceLastCount = deviceCount;
      _deviceState = deviceState;
      _serverLast = serverLast;
      _pendingServerRestore =
          pending != null && pending.isNotEmpty;
    });
    if (enabled) {
      try {
        ref.read(backupServiceProvider).startAutoSyncTimer();
      } catch (_) {}
    }
  }

  Future<void> _switchSource(BackupSource source) async {
    await BackupService.setBackupSource(source);
    if (!mounted) return;
    setState(() {
      _source = source;
      _errorBanner = null;
    });
    await _loadState();
  }

  void _onProgress(String stage, double value) {
    if (!mounted) return;
    setState(() {
      _progressStage = stage;
      _progressValue = value;
    });
  }

  String _stageLabel(String stage) {
    final l10n = AppLocalizations.of(context);
    switch (stage) {
      case 'collect':
        return l10n.translate('backupStageCollect');
      case 'seal':
        return l10n.translate('backupStageSeal');
      case 'write':
      case 'upload':
        return l10n.translate(stage == 'upload' ? 'backupStageUpload' : 'backupStageWrite');
      case 'validate':
        return l10n.translate('backupStageValidate');
      case 'relations':
        return l10n.translate('backupStageRelations');
      case 'server':
        return l10n.translate('backupStageServer');
      case 'relations':
        return l10n.translate('backupStageRelations');
      case 'prefs':
        return l10n.translate('backupStagePrefs');
      case 'local':
        return l10n.translate('backupStageRestoreData');
      case 'prefs':
        return l10n.translate('backupStagePrefs');
      case 'verify':
        return l10n.translate('backupStageVerify');
      default:
        return l10n.translate('backupStageDone');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _errorBanner = message);
  }

  void _showCreateResult({
    required String sourceLabel,
    required String version,
    required String date,
    required int size,
    required int count,
    required bool healthy,
  }) {
    final l10n = AppLocalizations.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Icon(Icons.check_circle, color: AppColors.success),
          const SizedBox(width: 8),
          Expanded(
              child: Text(l10n.translate('backupCreateAction'),
                  style: TextStyle(fontFamily: 'Cairo'))),
        ]),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _resultLine(
                  l10n.translate('backupSourceActive'), sourceLabel),
              _resultLine(
                  l10n.translate('backupVersionLabel'), version),
              _resultLine(l10n.translate('backupLastBackup'),
                  date.isNotEmpty ? _formatDate(date) : '—'),
              _resultLine(l10n.translate('backupSizeLabel'),
                  _formatBytes(size)),
              _resultLine(
                  l10n.translate('backupRecordCountLabel'),
                  count < 0 ? '?' : '$count'),
              const SizedBox(height: 4),
              Row(children: [
                Icon(
                    healthy ? Icons.check_circle : Icons.warning_amber_outlined,
                    size: 14,
                    color: healthy ? AppColors.success : AppColors.warning),
                const SizedBox(width: 6),
                Text(
                    l10n.translate(healthy
                        ? 'backupStateOk'
                        : 'backupStateUnverified'),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: healthy
                            ? AppColors.success
                            : AppColors.warning)),
              ]),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.translate('ok'),
                  style: TextStyle(fontFamily: 'Cairo'))),
        ],
      ),
    );
  }

  Widget _resultLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        Expanded(
            child: Text(label,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    color: AppColors.textSecondary))),
        Text(value,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12,
                fontWeight: FontWeight.w700)),
      ]),
    );
  }

  // ── create ──

  Future<void> _createBackup() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _errorBanner = null;
    });
    try {
      if (_source == BackupSource.server && _serverUserUuid.isEmpty) {
        _showError(AppLocalizations.of(context).translate('backupErrServerForbidden'));
        return;
      }
      final bs = ref.read(backupServiceProvider);
      final l10n = AppLocalizations.of(context);
      if (_source == BackupSource.device) {
        final result = await bs.createDeviceBackup(
          localUserId: _localUserId,
          serverUserUuid: _serverUserUuid,
          onProgress: (s, v) => _onProgress(_stageLabel(s), v),
        );
        if (!mounted) return;
        if (!result.success) {
          _showError(result.message);
          return;
        }
        _showCreateResult(
          sourceLabel: l10n.translate('backupSourceDevice'),
          version: '4.0.0',
          date: result.createdAt ?? '',
          size: result.fileSize ?? 0,
          count: result.recordCount,
          healthy: true,
        );
        // First successful backup → auto enabled by default (only once).
        final isFirstBackup = _deviceLastTime == null && _serverLast == null;
        if (!_autoUpdate && isFirstBackup) {
          await BackupService.setAutoSyncEnabled(true);
          if (mounted) setState(() => _autoUpdate = true);
          try { ref.read(backupServiceProvider).startAutoSyncTimer(); } catch (_) {}
        }
      } else {
        final result = await bs.uploadServerBackup(
          localUserId: _localUserId,
          serverUserUuid: _serverUserUuid,
          onProgress: (s, v) => _onProgress(_stageLabel(s), v),
        );
        if (!mounted) return;
        if (!result.success) {
          _showError(result.message);
          return;
        }
        _showCreateResult(
          sourceLabel: l10n.translate('backupSourceServer'),
          version: '${result.meta?['version'] ?? ''}',
          date: DateTime.now().toIso8601String(),
          size: (result.meta?['size_bytes'] as num?)?.toInt() ?? 0,
          count: (result.meta?['record_count'] as num?)?.toInt() ?? -1,
          healthy: true,
        );
        final isFirstBackup = _deviceLastTime == null && _serverLast == null;
        if (!_autoUpdate && isFirstBackup) {
          await BackupService.setAutoSyncEnabled(true);
          if (mounted) setState(() => _autoUpdate = true);
          try { ref.read(backupServiceProvider).startAutoSyncTimer(); } catch (_) {}
        }
      }
      await _loadState();
    } catch (e) {
      if (mounted) {
        _showError(AppLocalizations.of(context)
            .translate('backupErrorWithDetail', params: {'error': e}));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progressStage = null;
          _progressValue = null;
        });
      }
    }
  }

  /// Manual "حفظ البيانات الحالية" — updates the latest backup's data in place (no new version/file).
  Future<void> _saveCurrentData() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _errorBanner = null;
    });
    try {
      final bs = ref.read(backupServiceProvider);
      if (_source == BackupSource.device) {
        // Device manual save: refresh the NEWEST existing version in place.
        // No new file is ever created here and no other version is listed,
        // touched or retired — only the latest version's bytes are updated.
        // (This mirrors the server flow, which updates the latest version.)
        var result = await _overwriteNewestDeviceBackup(bs, onProgress: (s, v) => _onProgress(_stageLabel(s), v));
        if (!mounted) return;
        if (!result.success) {
          _showError(result.message);
          return;
        }
        _showCreateResult(
          sourceLabel: AppLocalizations.of(context).translate('backupSourceDevice'),
          version: '4.0.0',
          date: result.createdAt ?? DateTime.now().toIso8601String(),
          size: result.fileSize ?? 0,
          count: result.recordCount,
          healthy: true,
        );
        } else {
        if (_serverUserUuid.isEmpty) {
          _showError(AppLocalizations.of(context).translate('backupErrServerForbidden'));
          return;
        }
        // Server: update the latest version in place if exists (fetch from server if prefs lost after reinstall), else upload first.
        var last = await BackupService.getLastServerBackup();
        if (last == null) {
          try {
            final list = await bs.fetchServerBackups();
            if (list.isNotEmpty) last = list.first;
          } catch (_) {}
        }
        if (last != null && last['id'] != null) {
          final id = last['id'].toString();
          final result = await bs.updateServerBackup(
            backupId: id,
            localUserId: _localUserId,
            serverUserUuid: _serverUserUuid,
            onProgress: (s, v) => _onProgress(_stageLabel(s), v),
          );
          if (!mounted) return;
          if (!result.success) {
            _showError(result.message);
            return;
          }
          _showCreateResult(
            sourceLabel: AppLocalizations.of(context).translate('backupSourceServer'),
            version: '${result.meta?['version'] ?? last['version'] ?? ''}',
            date: DateTime.now().toIso8601String(),
            size: (result.meta?['size_bytes'] as num?)?.toInt() ?? 0,
            count: (result.meta?['record_count'] as num?)?.toInt() ?? -1,
            healthy: true,
          );
        } else {
          final result = await bs.uploadServerBackup(
            localUserId: _localUserId,
            serverUserUuid: _serverUserUuid,
            onProgress: (s, v) => _onProgress(_stageLabel(s), v),
          );
          if (!mounted) return;
          if (!result.success) {
            _showError(result.message);
            return;
          }
          _showCreateResult(
            sourceLabel: AppLocalizations.of(context).translate('backupSourceServer'),
            version: '${result.meta?['version'] ?? ''}',
            date: DateTime.now().toIso8601String(),
            size: (result.meta?['size_bytes'] as num?)?.toInt() ?? 0,
            count: (result.meta?['record_count'] as num?)?.toInt() ?? -1,
            healthy: true,
          );
        }
      }
      await _loadState();
    } catch (e) {
      if (mounted) {
        _showError(AppLocalizations.of(context).translate('backupErrorWithDetail', params: {'error': e}));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progressStage = null;
          _progressValue = null;
        });
      }
    }
  }

  /// Resolves the manual-save target: the prefs-tracked file when it is
  /// still readable, otherwise the newest version on disk (adopted), else
  /// null when no version exists at all (the caller creates the first one).
  Future<BackupResult> _overwriteNewestDeviceBackup(
    BackupService bs, {
    required void Function(String, double) onProgress,
  }) async {
    // Target resolution lives in the service (prefs keys are private
    // there): tracked file when readable, else newest on disk, else null.
    final target = await BackupService.resolveLatestDeviceUri();
    if (target == null || target.isEmpty) {
      return bs.createDeviceBackup(
        localUserId: _localUserId,
        serverUserUuid: _serverUserUuid,
        onProgress: onProgress,
      );
    }
    return bs.overwriteLatestBackup(
      uri: target,
      localUserId: _localUserId,
      serverUserUuid: _serverUserUuid,
      onProgress: onProgress,
    );
  }

  // ── restore: numbered list → fingerprint/PIN → motion ──

  /// Every backup of the chosen place, numbered from the oldest (1) to the
  /// newest (highest, on top) with date, time and size. No code to type:
  /// the account key opens them after sign-in.
  Future<void> _openRestoreList() async {
    final l10n = AppLocalizations.of(context);
    final bs = ref.read(backupServiceProvider);
    final device = _source == BackupSource.device;
    final items = <BackupListItem>[];
    String empty = l10n.translate(device ? 'backupNoBackupInDeviceFolder' : 'backupServerEmpty');
    try {
      if (device) {
        for (final f in await BackupService.listBackups()) {
          items.add(BackupListItem(f.name, f.date, f.size, payload: f));
        }
      } else {
        // Older plain versions move to the encrypted cloud (in background).
        unawaited(bs.server.migrateToEncrypted().catchError((Object _) => 0));
        for (final v in await bs.fetchServerBackups()) {
          items.add(BackupListItem(
            '${v['filename'] ?? v['id']}',
            DateTime.tryParse('${v['created_at']}')?.toLocal() ?? DateTime.now(),
            (v['size_bytes'] as num?)?.toInt() ?? 0,
            payload: v,
          ));
        }
      }
    } catch (_) {
      empty = l10n.translate('backupServerUnreachable');
    }
    if (!mounted) return;
    items.sort((a, b) => a.when.compareTo(b.when));
    final pick = await BackupListSheet.show(context,
        title: l10n.translate(device ? 'bkhFromDevice' : 'bkhFromFyonaServer'),
        icon: device ? Icons.phone_android_rounded : Icons.cloud_rounded,
        items: items,
        empty: empty);
    if (pick == null || !mounted) return;
    if (device) {
      final file = pick.payload as BackupFileInfo;
      final checked = await _validateDeviceFile(bs, file);
      if (!mounted) return;
      if (checked == null) {
        _showError(l10n.translate('backupInvalidBackup'));
        return;
      }
      await _restoreWithMotion(
        kind: MotionKind.deviceRestore,
        summary: '${l10n.translate('bkhItemName', params: {'n': '${pick.serial}'})} • '
            '${l10n.translate('backupRecordCount', params: {'count': '${checked['count']}'})}',
        run: (m) => bs.restoreFromBackup(
          checked['data'] as Map<String, dynamic>,
          userId: _localUserId,
          serverUserUuid: _serverUserUuid,
          skipServer: false,
          onProgress: (s, v) => m.stage(_stageLabel(s), v),
        ),
      );
    } else {
      final v = pick.payload as Map<String, dynamic>;
      await _restoreWithMotion(
        kind: MotionKind.cloudRestore,
        summary: '${l10n.translate('bkhItemName', params: {'n': '${pick.serial}'})} • '
            '${l10n.translate('backupRecordCount', params: {'count': '${v['record_count'] ?? '?'}'})}',
        run: (m) => bs.restoreServerBackup(
          '${v['id']}',
          localUserId: _localUserId,
          serverUserUuid: _serverUserUuid,
          onProgress: (s, p) => m.stage(_stageLabel(s), p),
        ),
      );
    }
  }

  Future<void> _restoreWithMotion({
    required MotionKind kind,
    required String summary,
    required Future<RestoreResult> Function(MotionController m) run,
  }) async {
    if (_busy) return;
    if (!await _confirmRestore(summary: summary) || !mounted) return;
    final l10n = AppLocalizations.of(context);
    if (!await verifySensitiveAction(context, ref,
            reason: l10n.translate('bkhVerifyReason'), existingCredentialsOnly: true) ||
        !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _errorBanner = null;
    });
    try {
      await OperationMotion.run(context,
          kind: kind,
          doneText: l10n.translate('bk2Restored'),
          failureText: (e) => e is _RestoreNotDone ? e.message : l10n.translate('bk2ErrGeneric'),
          work: (m) async {
        final result = await run(m);
        if (!result.success) throw _RestoreNotDone(result.message);
        return result;
      });
      try {
        await BackupService.clearPendingServerRestore();
      } catch (_) {}
      ref.read(personalFinanceProvider.notifier).load();
    } catch (_) {
      // shown by the motion
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progressStage = null;
          _progressValue = null;
        });
      }
      await _loadState();
    }
  }

  // ── manage sheet ──

  Future<void> _openManageSheet({required bool restoreMode}) async {
    try {
      if (_source == BackupSource.device) {
        final files = await BackupService.listBackups();
        if (!mounted) return;
        await _showDeviceSheet(files, restoreMode: restoreMode);
      } else {
        final bs = ref.read(backupServiceProvider);
        List<Map<String, dynamic>> items = const [];
        try {
          items = await bs.fetchServerBackups();
        } catch (_) {
          if (!mounted) return;
          _showError(AppLocalizations.of(context)
              .translate('backupServerUnreachable'));
          return;
        }
        if (!mounted) return;
        await _showServerSheet(items, restoreMode: restoreMode);
      }
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> _validateDeviceFile(
      BackupService bs, BackupFileInfo file) async {
    try {
      final doc = await BackupService.readDocumentContent(file.uri);
      final content = doc?['content'] as String?;
      if (content == null || content.isEmpty) return null;
      final res = await bs.readBackupContent(
        content,
        fileName: file.name,
        serverUserUuid: _serverUserUuid,
        localUserId: _localUserId,
      );
      if (!res.success || res.data == null) return null;
      return {
        'data': res.data!,
        'count': res.validation?.recordCount ?? 0,
        'authenticity': res.validation?.authenticity ?? 'unverified',
        'createdAt': res.validation?.createdAt,
      };
    } catch (_) {
      return null;
    }
  }

  Future<void> _showDeviceSheet(List<BackupFileInfo> files,
      {required bool restoreMode}) async {
    final l10n = AppLocalizations.of(context);
    final bs = ref.read(backupServiceProvider);
    final validated = <String, Map<String, dynamic>?>{};
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(2))),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(l10n.translate('backupManageTitle'),
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: AppColors.textPrimary)),
                    ),
                    InkWell(
                      onTap: () => Navigator.pop(ctx),
                      child: Icon(Icons.close,
                          color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: files.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                                l10n.translate('backupNoBackupYet'),
                                style: TextStyle(
                                    fontFamily: 'Cairo',
                                    color: AppColors.textSecondary)),
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primary,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10)),
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                ),
                                onPressed: () async {
                                  // Open system folder picker for Download/FYONA ERP (SAF) — correct for files, not photos.
                                  final picked = await BackupService.selectBackupFolder();
                                  if (picked == null) {
                                    // Fallback: try direct scan (may need permission on some devices).
                                    final newFiles = await BackupService.listBackups();
                                    if (newFiles.isEmpty) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                          content: Text(l10n.translate('backupNoBackupInDeviceFolder'),
                                              style: TextStyle(fontFamily: 'Cairo')),
                                          backgroundColor: AppColors.warning,
                                        ));
                                      }
                                      return;
                                    }
                                    if (ctx.mounted) Navigator.pop(ctx);
                                    await _showDeviceSheet(newFiles, restoreMode: restoreMode);
                                    return;
                                  }
                                  final newFiles = await BackupService.listBackups();
                                  if (newFiles.isEmpty) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                        content: Text(l10n.translate('backupNoBackupInDeviceFolder'),
                                            style: TextStyle(fontFamily: 'Cairo')),
                                        backgroundColor: AppColors.warning,
                                      ));
                                    }
                                    return;
                                  }
                                  if (ctx.mounted) Navigator.pop(ctx);
                                  await _showDeviceSheet(newFiles, restoreMode: restoreMode);
                                },
                                icon: Icon(Icons.folder_open, size: 18, color: Colors.white),
                                label: Text(l10n.translate('backupImportDevice'),
                                    style: TextStyle(
                                        fontFamily: 'Cairo',
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white)),
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        padding:
                            const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        itemCount: files.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: 8),
                        itemBuilder: (_, i) {
                          final f = files[i];
                          return FutureBuilder<Map<String, dynamic>?>(
                            future: validated.containsKey(f.uri)
                                ? Future.value(validated[f.uri])
                                : _validateDeviceFile(bs, f)
                                    .then((v) {
                                  validated[f.uri] = v;
                                  return v;
                                }),
                            builder: (_, snap) {
                              final v = snap.data;
                              final ok = v != null;
                              return _manageRow(
                                title: f.name,
                                subtitle:
                                    '${_formatDate(f.date.toIso8601String())} • ${f.formattedSize}'
                                    '${ok ? ' • ${l10n.translate('backupRecordCount', params: {'count': '${v['count']}'})}' : ''}',
                                stateChip: _stateChip(ok
                                    ? (v['authenticity'] == 'verified'
                                        ? 'ok'
                                        : 'unverified')
                                    : 'invalid'),
                                onRestore: ok
                                    ? () async {
                                        Navigator.pop(ctx);
                                        await _runDeviceRestore(
                                            f,
                                            v['data']
                                                as Map<String, dynamic>,
                                            v['count'] as int? ?? 0);
                                      }
                                    : null,
                                onDelete: () async {
                                  Navigator.pop(ctx);
                                  await _deleteDeviceFile(f);
                                },
                                restoreMode: restoreMode,
                              );
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
    await _loadState();
  }

  Future<void> _showServerSheet(List<Map<String, dynamic>> items,
      {required bool restoreMode}) async {
    final l10n = AppLocalizations.of(context);
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(l10n.translate('backupManageTitle'),
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary)),
                  ),
                  InkWell(
                    onTap: () => Navigator.pop(ctx),
                    child:
                        Icon(Icons.close, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            Flexible(
              child: items.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(l10n.translate('backupServerEmpty'),
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              color: AppColors.textSecondary)),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      padding:
                          const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      itemCount: items.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final item = items[i];
                        final created =
                            item['created_at']?.toString() ?? '';
                        return _manageRow(
                          title: item['filename']?.toString() ??
                              '${item['id']}',
                          subtitle:
                              '${created.isNotEmpty ? _formatDate(created) : ''} • '
                              '${_formatBytes((item['size_bytes'] as num?)?.toInt() ?? 0)} • '
                              '${l10n.translate('backupServerVersion', params: {'version': '${item['version'] ?? ''}'})} • '
                              '${l10n.translate('backupRecordCount', params: {'count': '${item['record_count'] ?? 0}'})}',
                          stateChip: _stateChip('ok'),
                          onRestore: () async {
                            Navigator.pop(ctx);
                            await _runServerRestore(item);
                          },
                          onDelete: () async {
                            Navigator.pop(ctx);
                            await _deleteServerVersion(item);
                          },
                          restoreMode: restoreMode,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
    await _loadState();
  }

  Widget _stateChip(String state) {
    final l10n = AppLocalizations.of(context);
    Color color;
    String label;
    IconData icon;
    if (state == 'ok') {
      color = AppColors.success;
      label = l10n.translate('backupStateOk');
      icon = Icons.check_circle;
    } else if (state == 'unverified') {
      color = AppColors.warning;
      label = l10n.translate('backupStateUnverified');
      icon = Icons.warning_amber_outlined;
    } else {
      color = AppColors.danger;
      label = l10n.translate('backupInvalidBackup');
      icon = Icons.error_outline;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
          color: color.withAlpha(18),
          borderRadius: BorderRadius.circular(6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 10, color: color),
        const SizedBox(width: 4),
        Flexible(
            child: Text(label,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: color),
                overflow: TextOverflow.ellipsis)),
      ]),
    );
  }

  Widget _manageRow({
    required String title,
    required String subtitle,
    required Widget stateChip,
    required Future<void> Function()? onRestore,
    required Future<void> Function() onDelete,
    required bool restoreMode,
  }) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
                child: Text(title,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary),
                    overflow: TextOverflow.ellipsis)),
            stateChip,
          ]),
          const SizedBox(height: 4),
          Text(subtitle,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 11,
                  color: AppColors.textSecondary)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onRestore == null
                    ? null
                    : () => onRestore(),
                icon: const Icon(Icons.restore_outlined, size: 15),
                label: Text(l10n.translate('backupRestoreThis'),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 11,
                        fontWeight: FontWeight.w700)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF2E7D32),
                  side: const BorderSide(color: Color(0xFF2E7D32)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
            if (!restoreMode) ...[
              const SizedBox(width: 8),
              IconButton(
                onPressed: () => onDelete(),
                icon: Icon(Icons.delete_outline,
                    size: 18, color: AppColors.danger),
                tooltip: l10n.translate('delete'),
              ),
            ],
          ]),
        ],
      ),
    );
  }

  // ── restore flows ──

  Future<bool> _confirmRestore({required String summary}) async {
    final l10n = AppLocalizations.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.translate('backupConfirmRestoreTitle'),
            style: TextStyle(fontFamily: 'Cairo')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.translate('backupRestoreSummary'),
                  style: TextStyle(fontFamily: 'Cairo')),
              const SizedBox(height: 8),
              Text(summary,
                  style: TextStyle(
                      fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              Text(l10n.translate('backupReplaceAllData'),
                  style: TextStyle(fontFamily: 'Cairo')),
              const SizedBox(height: 16),
              Text(l10n.translate('areYouSure'),
                  style: TextStyle(
                      fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.translate('cancel'),
                  style: TextStyle(fontFamily: 'Cairo'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.translate('backupRestoreAction'),
                style:
                    TextStyle(fontFamily: 'Cairo', color: Colors.white)),
          ),
        ],
      ),
    );
    return confirm == true;
  }

  void _showRestoreResult(RestoreResult result) {
    final l10n = AppLocalizations.of(context);
    final ok = result.success;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Icon(ok ? Icons.check_circle : Icons.error_outline,
              color: ok ? AppColors.success : AppColors.danger),
          const SizedBox(width: 8),
          Expanded(
              child: Text(
                  l10n.translate(ok
                      ? 'backupRestoreDoneTitle'
                      : 'backupRestoreFailedTitle'),
                  style: TextStyle(fontFamily: 'Cairo'))),
        ]),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(result.message, style: TextStyle(fontFamily: 'Cairo')),
              if (ok) ...[
                const SizedBox(height: 12),
                _checkRow(true,
                    l10n.translate('backupCheckData')),
                _checkRow(result.checks.contains('relations'),
                    l10n.translate('backupCheckRelations')),
                _checkRow(true,
                    l10n.translate('backupCheckNoDuplicates')),
                if (result.serverState == 'verified')
                  _checkRow(true,
                      l10n.translate('backupCheckServer')),
                if (result.serverState == 'pending_offline' ||
                    result.serverState == 'failed' ||
                    result.serverState == 'unsupported')
                  _checkRow(false,
                      result.serverState == 'unsupported'
                          ? l10n.translate(
                              'backupServerUnsupportedNote')
                          : l10n.translate(
                              'backupCheckServerPending')),
              ],
            ],
          ),
        ),
        actions: [
          if (ok &&
              (result.serverState == 'pending_offline' ||
                  result.serverState == 'failed'))
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary),
              onPressed: () async {
                Navigator.pop(ctx);
                await _retryPendingServer();
              },
              child: Text(l10n.translate('backupRetry'),
                  style: TextStyle(
                      fontFamily: 'Cairo', color: Colors.white)),
            ),
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.translate('ok'),
                  style: TextStyle(fontFamily: 'Cairo'))),
        ],
      ),
    );
  }

  Widget _checkRow(bool passed, String label) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        Icon(passed ? Icons.check_circle : Icons.cancel_outlined,
            size: 15,
            color: passed ? AppColors.success : AppColors.warning),
        const SizedBox(width: 6),
        Expanded(
            child: Text(label,
                style:
                    TextStyle(fontFamily: 'Cairo', fontSize: 12))),
      ]),
    );
  }

  Future<void> _retryPendingServer() async {
    setState(() => _busy = true);
    try {
      final bs = ref.read(backupServiceProvider);
      final done = await bs.completePendingServerRestore();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            done
                ? AppLocalizations.of(context)
                    .translate('backupStateOk')
                : AppLocalizations.of(context)
                    .translate('backupServerUnreachable'),
            style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor:
            done ? AppColors.success : AppColors.warning,
      ));
      ref.read(personalFinanceProvider.notifier).load();
      await _loadState();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runDeviceRestore(
      BackupFileInfo file, Map<String, dynamic> data, int count) async {
    if (_busy) return;
    final ok = await _confirmRestore(
        summary: '${file.name} • ${AppLocalizations.of(context).translate('backupRecordCount', params: {'count': '$count'})}');
    if (!ok || !mounted) return;
    setState(() {
      _busy = true;
      _errorBanner = null;
    });
    try {
      final bs = ref.read(backupServiceProvider);
      // No safety file is written before restore (per product decision):
      // restores must not spawn extra files in the backup folder.
      final result = await bs.restoreFromBackup(
        data,
        userId: _localUserId,
        serverUserUuid: _serverUserUuid,
        // Online this pushes the same snapshot to the server first (the
        // confirm dialog already warns server data is replaced), so a
        // post-restore refresh can never resurrect stale server zeros over
        // the restored rows — online restores land exactly like offline
        // ones. Offline the server layer defers with an explicit retry.
        skipServer: false,
        onProgress: (s, v) => _onProgress(_stageLabel(s), v),
      );
      if (!mounted) return;
      // Device restore is local-verified; clear any stale server-pending flag so success is not misread as failure.
      if (result.success) {
        try { await BackupService.clearPendingServerRestore(); } catch (_) {}
      }
      _showRestoreResult(result);
      if (result.success) {
        ref.read(personalFinanceProvider.notifier).load();
        await _loadState();
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progressStage = null;
          _progressValue = null;
        });
      }
    }
  }

  Future<void> _runServerRestore(Map<String, dynamic> item) async {
    if (_busy) return;
    final id = item['id']?.toString() ?? '';
    if (id.isEmpty) return;
    final ok = await _confirmRestore(
        summary:
            '${item['filename'] ?? id} • ${AppLocalizations.of(context).translate('backupRecordCount', params: {'count': '${item['record_count'] ?? '?'}'})}');
    if (!ok || !mounted) return;
    setState(() {
      _busy = true;
      _errorBanner = null;
    });
    try {
      final bs = ref.read(backupServiceProvider);
      // No safety file is written before restore (per product decision).
      final result = await bs.restoreServerBackup(
        id,
        localUserId: _localUserId,
        serverUserUuid: _serverUserUuid,
        onProgress: (s, v) => _onProgress(_stageLabel(s), v),
      );
      if (!mounted) return;
      _showRestoreResult(result);
      if (result.success) {
        // A verified server restore supersedes any stale pending flag left
        // by an earlier deferred layer — otherwise success keeps reading as
        // a server failure on the next open.
        try { await BackupService.clearPendingServerRestore(); } catch (_) {}
        ref.read(personalFinanceProvider.notifier).load();
        await _loadState();
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progressStage = null;
          _progressValue = null;
        });
      }
    }
  }

  Future<void> _deleteDeviceFile(BackupFileInfo file) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context).translate('backupDeleteTitle'),
            style: TextStyle(fontFamily: 'Cairo')),
        content: Text(
            AppLocalizations.of(context).translate('backupDeleteConfirm',
                params: {'name': file.name}),
            style: const TextStyle(fontFamily: 'Cairo')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppLocalizations.of(context).translate('cancel'),
                  style: TextStyle(fontFamily: 'Cairo'))),
          ElevatedButton(
            style:
                ElevatedButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppLocalizations.of(context).translate('delete'),
                style:
                    TextStyle(fontFamily: 'Cairo', color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await BackupService.deleteBackup(file.uri);
    if (mounted) await _loadState();
  }

  Future<void> _deleteServerVersion(Map<String, dynamic> item) async {
    final id = item['id']?.toString() ?? '';
    if (id.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
            AppLocalizations.of(context)
                .translate('backupDeleteServerTitle'),
            style: TextStyle(fontFamily: 'Cairo')),
        content: Text(
            AppLocalizations.of(context).translate(
                'backupDeleteServerConfirm',
                params: {'name': '${item['filename'] ?? id}'}),
            style: const TextStyle(fontFamily: 'Cairo')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppLocalizations.of(context).translate('cancel'),
                  style: TextStyle(fontFamily: 'Cairo'))),
          ElevatedButton(
            style:
                ElevatedButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppLocalizations.of(context).translate('delete'),
                style:
                    TextStyle(fontFamily: 'Cairo', color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final bs = ref.read(backupServiceProvider);
    final result = await bs.deleteServerBackup(id);
    if (!mounted) return;
    if (!result.success) {
      _showError(result.message);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          AppLocalizations.of(context)
              .translate('backupDeleteServerDone'),
          style: const TextStyle(fontFamily: 'Cairo')),
      backgroundColor: AppColors.success,
    ));
    await _loadState();
  }

  Future<void> _toggleAutoUpdate(bool value) async {
    setState(() => _autoUpdate = value);
    await BackupService.setAutoSyncEnabled(value);
    final bs = ref.read(backupServiceProvider);
    if (value) {
      bs.startAutoSyncTimer();
    } else {
      bs.stopAutoSyncTimer();
    }
  }

  Future<void> _showStoragePermissionDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
            AppLocalizations.of(context)
                .translate('backupStoragePermissionTitle'),
            style: TextStyle(fontFamily: 'Cairo')),
        content: Text(
            AppLocalizations.of(context)
                .translate('backupStoragePermissionBody'),
            style: TextStyle(fontFamily: 'Cairo')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppLocalizations.of(context).translate('ok'),
                  style: TextStyle(fontFamily: 'Cairo'))),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              BackupService.requestStoragePermission();
            },
            child: Text(AppLocalizations.of(context).translate('retry'),
                style: TextStyle(fontFamily: 'Cairo')),
          ),
        ],
      ),
    );
  }

  String _formatDate(String isoDate) {
    try {
      final dt = DateTime.parse(isoDate);
      return DateFormat('yyyy/MM/dd hh:mm a').format(dt);
    } catch (_) {
      return isoDate;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // ── layout ──

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isServer = _source == BackupSource.server;
    final hasBackup = isServer
        ? _serverLast != null
        : (_deviceLastTime != null);
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(l10n.translate('backupSourceSectionTitle'),
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          Row(children: [
            _sourceOption(
              active: !isServer,
              icon: Icons.sd_storage_outlined,
              label: l10n.translate('backupSourceDevice'),
              onTap: () => _switchSource(BackupSource.device),
            ),
            const SizedBox(width: 8),
            _sourceOption(
              active: isServer,
              icon: Icons.cloud_outlined,
              label: l10n.translate('backupSourceServer'),
              onTap: () => _switchSource(BackupSource.server),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
              l10n.translate(isServer
                  ? 'backupServerOneLine'
                  : 'backupDeviceOneLine'),
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 11,
                  color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          if (_errorBanner != null) _buildErrorBanner(),
          if (_pendingServerRestore) _buildPendingBanner(),
          _buildStatusCard(),
          const SizedBox(height: 12),
          if (_progressStage != null) _buildProgressCard(),
          _bigButton(
            icon: isServer
                ? Icons.cloud_upload_outlined
                : Icons.backup_outlined,
            label: l10n.translate('backupCreateAction'),
            color: AppColors.primary,
            loading: _busy,
            onTap: _createBackup,
          ),
          const SizedBox(height: 10),
          _bigButton(
            icon: Icons.restore_outlined,
            label: l10n.translate('backupRestoreTitle'),
            color: const Color(0xFF2E7D32),
            loading: _busy,
            onTap: hasBackup
                ? _openRestoreList
                : null,
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _openManageSheet(restoreMode: false),
              icon: const Icon(Icons.settings_outlined, size: 16),
              label: Text(l10n.translate('backupManageAction'),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textPrimary,
                side: BorderSide(color: AppColors.border),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
            ),
          ),
          if (!hasBackup) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                onPressed: _busy ? null : _createBackup,
                child: Text(l10n.translate('backupCreateFirst'),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ),
            ),
          ],
          const SizedBox(height: 12),
          _buildAutoUpdate(),
          if (!_autoUpdate) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                onPressed: _busy ? null : _saveCurrentData,
                icon: Icon(Icons.save_outlined, size: 18, color: Colors.white),
                label: Text(l10n.translate('backupSaveCurrentData'),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sourceOption({
    required bool active,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: active
                ? AppColors.primary.withAlpha(22)
                : AppColors.surface,
            border: Border.all(
              color: active ? AppColors.primary : AppColors.border,
              width: active ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 18,
                  color: active
                      ? AppColors.primary
                      : AppColors.textSecondary),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: active
                          ? AppColors.primary
                          : AppColors.textPrimary)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    final l10n = AppLocalizations.of(context);
    final isServer = _source == BackupSource.server;
    final hasBackup = isServer
        ? _serverLast != null
        : (_deviceLastTime != null);
    final String dateLine;
    final String sizeLine;
    if (!hasBackup) {
      dateLine = l10n.translate('backupNoBackupYet');
      sizeLine = '';
    } else if (isServer) {
      dateLine = _formatDate(_serverLast!['time']?.toString() ??
          _serverLast!['created_at']?.toString() ??
          '');
      sizeLine =
          '${_formatBytes((_serverLast!['size_bytes'] as num?)?.toInt() ?? 0)} • '
          '${l10n.translate('backupRecordCount', params: {'count': '${_serverLast!['record_count'] ?? 0}'})}';
    } else {
      dateLine = _formatDate(_deviceLastTime!);
      sizeLine =
          '${_formatBytes(_deviceLastSize ?? 0)} • ${l10n.translate('backupRecordCount', params: {'count': '${_deviceLastCount ?? 0}'})}';
    }
    final stateOk = hasBackup &&
        (isServer
            ? (_serverLast!['status']?.toString() ?? 'complete') ==
                'complete'
            : _deviceState == 'ok' || _deviceState == 'unverified');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.shield_outlined,
                size: 16, color: AppColors.primary),
            const SizedBox(width: 6),
            Text(l10n.translate('backupLastBackup'),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary)),
          ]),
          const SizedBox(height: 8),
          _statusLine(Icons.storage_outlined,
              l10n.translate(isServer ? 'backupSourceServer' : 'backupSourceDevice')),
          const SizedBox(height: 4),
          _statusLine(Icons.access_time, dateLine),
          if (sizeLine.isNotEmpty) ...[
            const SizedBox(height: 4),
            _statusLine(Icons.info_outline, sizeLine),
          ],
          const SizedBox(height: 4),
          Row(children: [
            Icon(
                !hasBackup
                    ? Icons.help_outline
                    : stateOk
                        ? Icons.check_circle
                        : Icons.error_outline,
                size: 13,
                color: !hasBackup
                    ? AppColors.textDisabled
                    : stateOk
                        ? AppColors.success
                        : AppColors.danger),
            const SizedBox(width: 6),
            Text(
                !hasBackup
                    ? l10n.translate('backupStateNone')
                    : stateOk
                        ? l10n.translate('backupStateOk')
                        : l10n.translate('backupInvalidBackup'),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: !hasBackup
                        ? AppColors.textDisabled
                        : stateOk
                            ? AppColors.success
                            : AppColors.danger)),
          ]),
        ],
      ),
    );
  }

  Widget _statusLine(IconData icon, String value) {
    return Row(children: [
      Icon(icon, size: 12, color: AppColors.textSecondary),
      const SizedBox(width: 6),
      Expanded(
          child: Text(value,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 11,
                  color: AppColors.textPrimary),
              overflow: TextOverflow.ellipsis)),
    ]);
  }

  Widget _bigButton({
    required IconData icon,
    required String label,
    required Color color,
    required bool loading,
    required VoidCallback? onTap,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
        onPressed: (loading || onTap == null) ? null : onTap,
        icon: loading
            ? DotsLoader(size: 7, spacing: 3, color: Colors.white)
            : Icon(icon, size: 20, color: Colors.white),
        label: Text(label,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: Colors.white)),
      ),
    );
  }

  Widget _buildAutoUpdate() {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.translate('backupAutoUpdateTitle'),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 2),
              Text(l10n.translate('backupAutoUpdateHint'),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 11,
                      color: AppColors.textSecondary)),
            ],
          ),
        ),
        Switch(value: _autoUpdate, onChanged: _toggleAutoUpdate),
      ]),
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.danger.withAlpha(14),
        border: Border.all(color: AppColors.danger.withAlpha(50)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: AppColors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_errorBanner!,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    color: AppColors.textPrimary)),
          ),
          InkWell(
            onTap: () => setState(() => _errorBanner = null),
            child:
                Icon(Icons.close, size: 16, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingBanner() {
    final l10n = AppLocalizations.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warning.withAlpha(14),
        border: Border.all(color: AppColors.warning.withAlpha(50)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.cloud_off_outlined,
              size: 18, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(l10n.translate('backupServerPendingBanner'),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    color: AppColors.textPrimary)),
          ),
          TextButton(
            onPressed: _busy ? null : _retryPendingServer,
            child: Text(l10n.translate('backupRetry'),
                style: TextStyle(fontFamily: 'Cairo')),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            DotsLoader(size: 6, spacing: 3, color: AppColors.primary),
            const SizedBox(width: 8),
            Expanded(
                child: Text(_progressStage ?? '',
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12,
                        color: AppColors.textPrimary))),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _progressValue,
              minHeight: 6,
              backgroundColor: AppColors.border,
              valueColor:
                  AlwaysStoppedAnimation<Color>(AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }

}


class _RestoreNotDone implements Exception {
  const _RestoreNotDone(this.message);
  final String message;
}
