import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/core_business/data/local_directory/directory_database.dart';
import '../../../features/core_business/data/local_directory/directory_pilot.dart';
import '../../../features/core_business/data/local_ledger/business_local_backups.dart';
import '../../../features/core_business/presentation/providers/business_backup_provider.dart';
import '../../../features/profile/presentation/pages/business_backup_file_actions.dart';
import '../../export/presentation/accounting_export_page.dart';
import '../../import/presentation/smart_import_page.dart';
import '../../localization/app_localizations.dart';
import '../../storage/free_space.dart';
import '../../theme/app_colors.dart';
import '../backup_bridges.dart';
import '../backup_coordinator.dart';
import '../backup_providers.dart';
import '../device_backup_folder.dart';
import 'backup_list_sheet.dart';
import 'feature_intro.dart';
import 'operation_motion.dart';

String _t(String key, [Map<String, dynamic>? p]) => AppLocalizations.t(key, p);
const _font = 'Cairo';

/// Business backup, redesigned (owner's brief 27-11): one button to back up
/// (device + FYONA cloud), two ways to restore — both list the backups
/// right here, no code to type, no file manager.
class BusinessBackupHome extends ConsumerStatefulWidget {
  const BusinessBackupHome({super.key});
  @override
  ConsumerState<BusinessBackupHome> createState() => _BusinessBackupHomeState();
}

class _BusinessBackupHomeState extends ConsumerState<BusinessBackupHome> {
  BackupSpace? _space;
  BackupStatus? _status;
  bool _loading = true;
  bool _busy = false;

  BackupCoordinator get _c => ref.read(backupCoordinatorProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final space = await resolveBackupSpace(ref.read, BackupKind.business);
    final status = space == null ? null : await _c.status(space.id);
    if (!mounted) return;
    setState(() {
      _space = space;
      _status = status;
      _loading = false;
    });
  }

  void _snack(String text, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: error ? AppColors.danger : null,
      content: Text(text, style: const TextStyle(fontFamily: _font)),
    ));
  }

  String _failure(Object e) {
    if (e is NotEnoughSpace) return _t('bk2NoSpace', {'mb': '${e.missingMb}'});
    if (e is BackupRestoreFailure) return _t('bk2Err_${e.code}');
    if (e is BusinessBackupRejected && e.problem == BusinessBackupProblem.notEmpty) return _t('bk2Err_not_empty');
    if (e is SocketException) return _t('bkhOffline');
    return _t('bk2ErrGeneric');
  }

  Future<bool> _verify(String reason) async =>
      ref.read(businessBackupVerifierProvider)(context, ref, reason, true);

  // ── back up now ─────────────────────────────────────────────────────

  Future<void> _backupNow() async {
    final space = _space;
    if (space == null || _busy) return;
    setState(() => _busy = true);
    try {
      await OperationMotion.run(context, kind: MotionKind.backup, doneText: _t('bkhSaved'), failureText: _failure,
          work: (m) async {
        m.stage(_t('bkhStagePreparing'), 0.05);
        await _c.ensureEnabled(space);
        m.stage(_t('bkhStageSaving'), 0.15);
        final st = await _c.runNow(space, force: true);
        if (st.lastError != null) throw const BackupRestoreFailure('apply_failed');
        m.stage(_t('bkhStageDevice'), 0.6);
        await _c.saveToDevice(space, onProgress: (_, d) => m.progress(0.6 + d * 0.38));
        if (st.cloud && st.cloudError != null) m.stage(_t('bkhCloudLater'), 0.99);
      });
    } catch (_) {
      // shown by the motion
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  Future<void> _toggleAuto(bool on) async {
    final space = _space;
    if (space == null) return;
    try {
      if (on) {
        await _c.ensureEnabled(space);
      } else {
        await _c.configure(space.id, enabled: false);
      }
    } catch (e) {
      _snack(_failure(e), error: true);
    }
    await _load();
  }

  // ── restore ─────────────────────────────────────────────────────────

  Future<void> _restoreFromDevice() async {
    final space = _space;
    if (space == null) return;
    List<DeviceBackupFile> packs = const [], legacy = const [];
    try {
      packs = await _c.deviceFiles(space);
      legacy = await DeviceBackupFolder.list([businessBackupExtension]);
    } catch (_) {}
    if (!mounted) return;
    final items = [
      for (final f in packs) BackupListItem(f.name, f.modified, f.size, device: f),
      for (final f in legacy) BackupListItem(f.name, f.modified, f.size, device: f, legacy: true),
    ]..sort((a, b) => a.when.compareTo(b.when));
    final pick = await BackupListSheet.show(context,
        title: _t('bkhFromDevice'),
        icon: Icons.phone_android_rounded,
        items: items,
        empty: _t('bkhNoDevice'),
        onDelete: (picked) async => [
              for (final it in picked)
                if (await _tryDelete(() => DeviceBackupFolder.delete(it.device!))) it,
            ]);
    await _load();
    if (pick == null || !mounted) return;
    await _restore(MotionKind.deviceRestore, pick);
  }

  Future<void> _restoreFromCloud() async {
    final space = _space;
    if (space == null) return;
    List<BackupSetInfo> sets = const [];
    String? error;
    try {
      sets = (await _c.listSets(space)).where((s) => s.cloud).toList();
    } catch (e) {
      error = _failure(e);
    }
    if (!mounted) return;
    final items = [for (final s in sets) BackupListItem(s.id, s.startedAt?.toLocal() ?? DateTime.now(), s.bytes, cloud: s)]
      ..sort((a, b) => a.when.compareTo(b.when));
    final pick = await BackupListSheet.show(context,
        title: _t('bkhFromCloud'),
        icon: Icons.cloud_rounded,
        items: items,
        empty: error ?? _t('bkhNoCloud'),
        onDelete: (picked) async => [
              for (final it in picked)
                if (await _tryDelete(() => _c.deleteCloudSet(space, it.cloud!.id))) it,
            ]);
    await _load();
    if (pick == null || !mounted) return;
    await _restore(MotionKind.cloudRestore, pick);
  }

  Future<bool> _tryDelete(Future<void> Function() run) async {
    try {
      await run();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _restore(MotionKind kind, BackupListItem item) async {
    final space = _space;
    final scope = backupBusinessScope(ref.read);
    if (space == null || scope == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t('bkhRestoreTitle', {'n': '${item.serial}'}), style: const TextStyle(fontFamily: _font)),
        content: Text(_t('bkhRestoreBody'), style: const TextStyle(fontFamily: _font, fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t('cancel'))),
          FilledButton(key: const Key('bkh-restore-confirm'), onPressed: () => Navigator.pop(ctx, true), child: Text(_t('bk2Restore'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (!await _verify(_t('bkhVerifyReason'))) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await OperationMotion.run(context, kind: kind, doneText: _t('bk2Restored'), failureText: _failure, work: (m) async {
        void stage(String s, double d) {
          final base = {'download': 0.0, 'reading': 0.0, 'media': 0.25, 'records': 0.45, 'preparing': 0.75, 'applying': 0.8}[s] ?? 0.0;
          final span = {'download': 0.25, 'reading': 0.25, 'media': 0.2, 'records': 0.3, 'preparing': 0.05, 'applying': 0.19}[s] ?? 0.0;
          m.stage(_t('bk2Stage_$s'), base + span * d);
        }

        if (item.legacy) {
          await _restoreLegacyFile(item.device!, (s, d) => m.stage(_t('bkStage_${s.name}'), d));
          return;
        }
        final copy = item.device != null
            ? await _c.restoreDeviceFile(space, item.device!, onProgress: stage)
            : await _c.rebuild(space, item.cloud!, onProgress: stage);
        final r = await BackupBridges.applyBusiness(
          copyPath: copy.path,
          dbKeyHex: space.dbKeyHex,
          access: scope,
          live: ref.read(directoryPilotStoreProvider),
          allowed: () => backupBusinessAllowed(ref.read, scope),
          onProgress: stage,
        );
        if (r.alreadyRestored) m.stage(_t('bk2AlreadyRestored'), 1);
      });
    } catch (_) {
      // shown by the motion
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  /// An older branch file (.fyonabiz): the business's own key first; a file
  /// made with a written recovery code asks for it once.
  Future<void> _restoreLegacyFile(DeviceBackupFile f, BusinessBackupProgress onProgress) async {
    final local = ref.read(localBusinessBackupsProvider);
    final scope = backupBusinessScope(ref.read);
    if (local == null || scope == null) throw const BackupRestoreFailure('apply_failed');
    final account = await ref.read(accountBackupKeysProvider).business(scope.workspace.organizationId);
    final tmp = File('${Directory.systemTemp.path}/fyona-legacy-${DateTime.now().microsecondsSinceEpoch}');
    try {
      await DeviceBackupFolder.copyTo(f, tmp);
      Future<void> attempt(BusinessBackupCode code) =>
          local.restoreStream(tmp.openRead(), code, size: f.size, onProgress: onProgress);
      try {
        if (account == null) throw const BusinessBackupRejected(BusinessBackupProblem.invalidArchive);
        await attempt(BusinessBackupCode.forAccount(await account.extractBytes()));
      } on BusinessBackupRejected catch (e) {
        if (e.problem != BusinessBackupProblem.invalidArchive || !mounted) rethrow;
        final code = await showDialog<BusinessBackupCode>(context: context, builder: (_) => const _LegacyCodeDialog());
        if (code == null) throw const BackupRestoreFailure('key_needed');
        await attempt(code);
      }
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  bool get _owner {
    final scope = ref.watch(businessLocalLedgerScopeProvider);
    return scope != null && !scope.member;
  }

  void _openExport() => showFeatureIntro(
        context,
        title: _t('axTitle'),
        icon: Icons.ios_share_rounded,
        colors: const [Color(0xFF0F766E), Color(0xFF14B8A6)],
        scenes: [
          IntroScene(const [Icons.event_rounded], _t('axIntro1')),
          IntroScene(const [Icons.account_balance_wallet_rounded, Icons.all_inbox_rounded, Icons.checklist_rounded], _t('axIntro2')),
          IntroScene(const [Icons.table_view_rounded, Icons.ios_share_rounded], _t('axIntro3')),
        ],
        points: [
          (Icons.account_balance_wallet_rounded, _t('axPoint1')),
          (Icons.checklist_rounded, _t('axPoint2')),
          (Icons.table_view_rounded, _t('axPoint3')),
        ],
        start: _t('axStart'),
        onStart: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AccountingExportPage())),
      );

  void _openImport() => showFeatureIntro(
        context,
        title: _t('siTitle'),
        icon: Icons.auto_awesome_rounded,
        colors: const [Color(0xFF7B2FF7), Color(0xFFE0457B)],
        scenes: [
          IntroScene(const [Icons.upload_file_rounded], _t('siIntro1')),
          IntroScene(const [Icons.table_chart_rounded, Icons.auto_awesome_rounded], _t('siIntro2')),
          IntroScene(const [Icons.check_circle_rounded, Icons.block_rounded, Icons.fact_check_rounded], _t('siIntro3')),
          IntroScene(const [Icons.fingerprint_rounded, Icons.verified_rounded], _t('siIntro4')),
        ],
        points: [
          (Icons.auto_awesome_rounded, _t('siPoint1')),
          (Icons.fact_check_rounded, _t('siPoint2')),
          (Icons.shield_rounded, _t('siPoint3')),
        ],
        start: _t('siStart'),
        onStart: () => openSmartImport(context),
      );

  String _when(int? ms) {
    if (ms == null) return _t('bkhNever');
    final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    return backupWhen(d);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final s = _status;
    final on = s?.enabled == true;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 32), children: [
        _Hero(
          lastDevice: _when(s?.lastOkAt),
          lastCloud: s?.cloud == true ? _when(s?.cloudOkAt) : null,
          problem: s?.lastError != null || (s?.cloud == true && s?.cloudError != null),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 56,
          child: FilledButton.icon(
            key: const Key('bkh-now'),
            style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
            onPressed: _busy || _space == null ? null : _backupNow,
            icon: const Icon(Icons.shield_moon_outlined),
            label: Text(_t('bkhNow'), style: const TextStyle(fontFamily: _font, fontSize: 16, fontWeight: FontWeight.w800)),
          ),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: _Tile(
              key: const Key('bkh-device'),
              icon: Icons.phone_android_rounded,
              title: _t('bkhFromDevice'),
              onTap: _busy ? null : _restoreFromDevice,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _Tile(
              key: const Key('bkh-cloud'),
              icon: Icons.cloud_download_rounded,
              title: _t('bkhFromCloud'),
              onTap: _busy ? null : _restoreFromCloud,
            ),
          ),
        ]),
        const SizedBox(height: 14),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: SwitchListTile.adaptive(
            key: const Key('bkh-auto'),
            value: on,
            onChanged: _busy || _space == null ? null : _toggleAuto,
            title: Text(_t('bkhAuto'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700)),
            subtitle: Text(_t('bkhAutoHint'), style: const TextStyle(fontFamily: _font, fontSize: 12)),
          ),
        ),
        if (_owner) ...[
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
              child: FeatureButton(
                key: const Key('bkh-export'),
                title: _t('bkhExportBtn'),
                icon: Icons.ios_share_rounded,
                colors: const [Color(0xFF0F766E), Color(0xFF14B8A6)],
                onTap: _busy ? null : _openExport,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FeatureButton(
                key: const Key('bkh-import'),
                title: _t('siTitle'),
                icon: Icons.auto_awesome_rounded,
                colors: const [Color(0xFF7B2FF7), Color(0xFFE0457B)],
                onTap: _busy ? null : _openImport,
              ),
            ),
          ]),
        ],
      ]),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.lastDevice, required this.problem, this.lastCloud});
  final String lastDevice;
  final String? lastCloud;
  final bool problem;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(colors: [Color(0xFF9E1B32), Color(0xFF6B0E22)]),
          boxShadow: [BoxShadow(color: const Color(0xFF9E1B32).withValues(alpha: .25), blurRadius: 18, offset: const Offset(0, 8))],
        ),
        child: Row(children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: .14), borderRadius: BorderRadius.circular(16)),
            child: Icon(problem ? Icons.gpp_maybe_rounded : Icons.verified_user_rounded, color: Colors.white, size: 30),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_t('bkhLast'), style: TextStyle(fontFamily: _font, fontSize: 12, color: Colors.white.withValues(alpha: .8))),
              const SizedBox(height: 2),
              Row(children: [
                const Icon(Icons.phone_android_rounded, size: 15, color: Colors.white),
                const SizedBox(width: 6),
                Text(lastDevice, style: const TextStyle(fontFamily: _font, fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white)),
              ]),
              if (lastCloud != null)
                Row(children: [
                  const Icon(Icons.cloud_done_rounded, size: 15, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(lastCloud!, style: const TextStyle(fontFamily: _font, fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white)),
                ]),
            ]),
          ),
        ]),
      );
}

class _Tile extends StatelessWidget {
  const _Tile({super.key, required this.icon, required this.title, this.onTap});
  final IconData icon;
  final String title;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Container(
            height: 118,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: AppColors.border)),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: .10), shape: BoxShape.circle),
                child: Icon(icon, color: AppColors.primary),
              ),
              const SizedBox(height: 10),
              Text(title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: _font, fontSize: 13.5, fontWeight: FontWeight.w800)),
            ]),
          ),
        ),
      );
}

class _LegacyCodeDialog extends StatefulWidget {
  const _LegacyCodeDialog();
  @override
  State<_LegacyCodeDialog> createState() => _LegacyCodeDialogState();
}

class _LegacyCodeDialogState extends State<_LegacyCodeDialog> {
  final _c = TextEditingController();
  bool _bad = false;
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(_t('bkhLegacyTitle'), style: const TextStyle(fontFamily: _font)),
        content: TextField(
          controller: _c,
          textDirection: TextDirection.ltr,
          decoration: InputDecoration(labelText: _t('bkhLegacyLabel'), errorText: _bad ? _t('bk2Err_wrong_code') : null),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(_t('cancel'))),
          FilledButton(
            onPressed: () {
              try {
                Navigator.pop(context, BusinessBackupCode.parse(_c.text));
              } on BusinessBackupRejected {
                setState(() => _bad = true);
              }
            },
            child: Text(_t('bk2Continue')),
          ),
        ],
      );
}
