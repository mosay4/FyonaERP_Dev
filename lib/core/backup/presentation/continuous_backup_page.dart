import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/core_business/data/local_directory/directory_database.dart';
import '../../../features/core_business/data/local_directory/directory_pilot.dart';
import '../../../features/personal/di/personal_providers.dart';
import '../../config/app_config.dart';
import '../../localization/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../backup_bridges.dart';
import '../backup_coordinator.dart';
import '../backup_providers.dart';
import '../../storage/free_space.dart';
import 'backup_file_io.dart';

String _t(String key, [Map<String, dynamic>? p]) => AppLocalizations.t(key, p);
const _font = 'Cairo';

/// Entry card placed on the existing backup screens.
class ContinuousBackupEntry extends StatelessWidget {
  const ContinuousBackupEntry({super.key, required this.kind});
  final BackupKind kind;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 16),
        color: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: AppColors.border)),
        child: ListTile(
          key: const Key('bk2-entry'),
          leading: const Icon(Icons.cloud_sync_outlined, color: AppColors.primary),
          title: Text(_t('bk2Title'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
          subtitle: Text(_t('bk2EntrySubtitle'), style: const TextStyle(fontFamily: _font, fontSize: 12)),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => ContinuousBackupPage(kind: kind),
          )),
        ),
      );
}

class ContinuousBackupPage extends ConsumerStatefulWidget {
  const ContinuousBackupPage({super.key, required this.kind});
  final BackupKind kind;

  @override
  ConsumerState<ContinuousBackupPage> createState() => _ContinuousBackupPageState();
}

class _ContinuousBackupPageState extends ConsumerState<ContinuousBackupPage> {
  BackupSpace? _space;
  BackupStatus? _status;
  List<BackupSetInfo> _sets = const [];
  bool _loading = true;
  bool _busy = false;
  String? _progress;
  double? _fraction;
  String? _stage;

  BackupCoordinator get _c => ref.read(backupCoordinatorProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final space = await resolveBackupSpace(ref.read, widget.kind);
    BackupStatus? status;
    var sets = const <BackupSetInfo>[];
    if (space != null) {
      status = await _c.status(space.id);
      sets = await _c.listSets(space);
    }
    if (!mounted) return;
    setState(() {
      _space = space;
      _status = status;
      _sets = sets;
      _loading = false;
    });
  }

  Future<void> _guard(String progress, Future<void> Function() work) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _progress = progress;
    });
    try {
      await work();
    } catch (e) {
      _snack(_failure(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
          _fraction = null;
          _stage = null;
        });
      }
      await _load();
    }
  }

  /// Stage + percentage from long operations (throttled to 0.5 %).
  void _onProgress(String stage, double done) {
    if (!mounted) return;
    final f = _fraction;
    if (stage == _stage && f != null && (done - f).abs() < 0.005 && done < 1) return;
    setState(() {
      _stage = stage;
      _fraction = done.clamp(0, 1).toDouble();
      _progress = _t('bk2Stage_$stage');
    });
  }

  String _failure(Object e) {
    if (e is NotEnoughSpace) return _t('bk2NoSpace', {'mb': '${e.missingMb}'});
    if (e is BackupRestoreFailure) return _t('bk2Err_${e.code}');
    if (e is BusinessBackupRejected && e.problem == BusinessBackupProblem.notEmpty) return _t('bk2Err_not_empty');
    return _t('bk2ErrGeneric');
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text, style: const TextStyle(fontFamily: _font))));
  }

  Future<void> _enable() async {
    final space = _space;
    if (space == null) return;
    final password = await _askPassword();
    if (password == null) return; // cancelled
    await _guard(_t('bk2Preparing'), () async {
      final code = await _c.enable(space, password: password.isEmpty ? null : password);
      if (mounted) await _showCode(code);
      await _c.runNow(space);
    });
  }

  Future<String?> _askPassword() {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t('bk2EnableTitle'), style: const TextStyle(fontFamily: _font)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_t('bk2EnableBody'), style: const TextStyle(fontFamily: _font, fontSize: 13)),
          const SizedBox(height: 12),
          TextField(
            key: const Key('bk2-password'),
            controller: ctrl,
            obscureText: true,
            decoration: InputDecoration(labelText: _t('bk2PasswordOptional')),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_t('cancel'))),
          FilledButton(
            key: const Key('bk2-enable-confirm'),
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: Text(_t('bk2Enable')),
          ),
        ],
      ),
    );
  }

  Future<void> _showCode(String code) async {
    var saved = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(_t('bk2CodeTitle'), style: const TextStyle(fontFamily: _font)),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_t('bk2CodeBody'), style: const TextStyle(fontFamily: _font, fontSize: 13)),
            const SizedBox(height: 12),
            Directionality(
              textDirection: TextDirection.ltr,
              child: SelectableText(code,
                  key: const Key('bk2-code'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: code)),
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: Text(_t('bk2Copy')),
            ),
            CheckboxListTile(
              key: const Key('bk2-code-saved'),
              contentPadding: EdgeInsets.zero,
              value: saved,
              onChanged: (v) => set(() => saved = v == true),
              title: Text(_t('bk2CodeSaved'), style: const TextStyle(fontFamily: _font, fontSize: 13)),
            ),
          ]),
          actions: [
            FilledButton(
              key: const Key('bk2-code-done'),
              onPressed: saved ? () => Navigator.pop(ctx) : null,
              child: Text(_t('bk2Done')),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _askSecret() {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t('bk2SecretTitle'), style: const TextStyle(fontFamily: _font)),
        content: TextField(
          key: const Key('bk2-secret'),
          controller: ctrl,
          decoration: InputDecoration(labelText: _t('bk2SecretLabel')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(_t('bk2Continue'))),
        ],
      ),
    );
  }

  Future<bool> _confirmRestore() async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(_t('bk2RestoreTitle'), style: const TextStyle(fontFamily: _font)),
          content: Text(_t(widget.kind == BackupKind.business ? 'bk2RestoreBodyBusiness' : 'bk2RestoreBodyPersonal'),
              style: const TextStyle(fontFamily: _font, fontSize: 13)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t('cancel'))),
            FilledButton(
                key: const Key('bk2-restore-confirm'),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(_t('bk2Restore'))),
          ],
        ),
      ) ==
      true;

  Future<void> _restore(BackupSetInfo set) async {
    final space = _space;
    if (space == null || !await _confirmRestore()) return;
    await _guard(_t('bk2Verifying'), () async {
      ({String path, Map<String, dynamic>? extras}) copy;
      try {
        copy = await _c.rebuild(space, set, onProgress: _onProgress);
      } on BackupRestoreFailure catch (e) {
        if (e.code != 'key_needed' && e.code != 'wrong_code') rethrow;
        if (!mounted) return;
        final secret = await _askSecret();
        if (secret == null || secret.isEmpty) return;
        if (mounted) setState(() => _progress = _t('bk2Verifying'));
        copy = await _c.rebuild(space, set, secret: secret, onProgress: _onProgress);
      }
      await _apply(space, copy);
    });
  }

  /// A backup file kept on this device (or copied from another one).
  Future<void> _restoreFromFile() async {
    final space = _space;
    if (space == null || !await _confirmRestore()) return;
    await _guard(_t('bk2Stage_reading'), () async {
      final picked = await ref.read(backupFileIoProvider).pick();
      if (picked == null) return;
      final copy = await _c.importFile(space, picked.data,
          size: picked.size, askSecret: () async => mounted ? _askSecret() : null, onProgress: _onProgress);
      await _apply(space, copy);
    });
  }

  Future<void> _saveAsFile(BackupSetInfo set) async {
    final space = _space;
    if (space == null) return;
    await _guard(_t('bk2Stage_saving'), () async {
      final name = 'fyona-${widget.kind.name}-${set.id}.fyonaset';
      final out = File('${Directory.systemTemp.path}/fyona-export-${DateTime.now().microsecondsSinceEpoch}/$name');
      try {
        await _c.exportToFile(space, set, out, onProgress: _onProgress);
        if (await ref.read(backupFileIoProvider).save(out, name)) _snack(_t('bk2SavedFile'));
      } finally {
        if (await out.parent.exists()) await out.parent.delete(recursive: true);
      }
    });
  }

  Future<void> _apply(BackupSpace space, ({String path, Map<String, dynamic>? extras}) copy) async {
    if (mounted) setState(() => _progress = _t('bk2Applying'));
    if (widget.kind == BackupKind.personal) {
      try {
        final res = await BackupBridges.applyPersonal(ref.read(backupServiceProvider), copy.path, space.dbKeyHex,
            copy.extras, appVersion: AppConfig.appVersion, onProgress: (_, f) => _onProgress('applying', f));
        _snack(res.success ? _t('bk2Restored') : res.message);
      } finally {
        final f = File(copy.path);
        if (f.existsSync()) f.deleteSync();
      }
    } else {
      final scope = backupBusinessScope(ref.read);
      if (scope == null) {
        final f = File(copy.path);
        if (f.existsSync()) f.deleteSync();
        throw const BackupRestoreFailure('apply_failed');
      }
      final r = await BackupBridges.applyBusiness(
        copyPath: copy.path,
        dbKeyHex: space.dbKeyHex,
        access: scope,
        live: ref.read(directoryPilotStoreProvider),
        allowed: () => backupBusinessAllowed(ref.read, scope),
        onProgress: _onProgress,
      );
      _snack(r.alreadyRestored ? _t('bk2AlreadyRestored') : _t('bk2Restored'));
    }
  }

  String _when(int? ms) {
    if (ms == null) return _t('bk2Never');
    final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(_t('bk2Title'), style: const TextStyle(fontFamily: _font)),
        actions: [IconButton(onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh_rounded))],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _space == null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_t('bk2Unavailable'), style: const TextStyle(fontFamily: _font)),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    Text(_t(widget.kind == BackupKind.business ? 'bk2IntroBusiness' : 'bk2IntroPersonal'),
                        style: TextStyle(fontFamily: _font, fontSize: 12.5, color: AppColors.textSecondary)),
                    const SizedBox(height: 12),
                    if (_progress != null) ...[
                      LinearProgressIndicator(key: const Key('bk2-progress'), value: _fraction),
                      const SizedBox(height: 6),
                      Text(
                          _fraction == null ? _progress! : '${_progress!} — ${(_fraction! * 100).floor()}%',
                          key: const Key('bk2-progress-text'),
                          style: const TextStyle(fontFamily: _font, fontSize: 12)),
                      const SizedBox(height: 12),
                    ],
                    _card([
                      SwitchListTile.adaptive(
                        key: const Key('bk2-enabled'),
                        value: s?.enabled == true,
                        onChanged: _busy
                            ? null
                            : (v) => v
                                ? _enable()
                                : _guard('', () => _c.configure(_space!.id, enabled: false)),
                        title: Text(_t('bk2Continuous'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700)),
                        subtitle: Text(_t('bk2ContinuousHint'), style: const TextStyle(fontFamily: _font, fontSize: 12)),
                      ),
                      if (s?.enabled == true) ...[
                        SwitchListTile.adaptive(
                          key: const Key('bk2-cloud'),
                          value: s!.cloud,
                          onChanged: _busy ? null : (v) => _guard('', () => _c.configure(_space!.id, cloud: v)),
                          title: Text(_t('bk2Cloud'), style: const TextStyle(fontFamily: _font)),
                          subtitle: Text(_t('bk2CloudHint'), style: const TextStyle(fontFamily: _font, fontSize: 12)),
                        ),
                        SwitchListTile.adaptive(
                          key: const Key('bk2-media'),
                          value: s.media,
                          onChanged: _busy ? null : (v) => _guard('', () => _c.configure(_space!.id, media: v)),
                          title: Text(_t('bk2Media'), style: const TextStyle(fontFamily: _font)),
                        ),
                      ],
                    ]),
                    if (s?.enabled == true) ...[
                      const SizedBox(height: 12),
                      _card([
                        _row(Icons.phone_android_rounded, _t('bk2LastDevice'), _when(s!.lastOkAt)),
                        if (s.cloud) _row(Icons.cloud_done_outlined, _t('bk2LastCloud'), _when(s.cloudOkAt)),
                        if (s.lastError != null || (s.cloud && s.cloudError != null))
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                            child: Text(_t(s.lastError != null ? 'bk2ProblemDevice' : 'bk2ProblemCloud'),
                                style: const TextStyle(fontFamily: _font, fontSize: 12, color: AppColors.warning)),
                          ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                          child: FilledButton.icon(
                            key: const Key('bk2-now'),
                            onPressed: _busy ? null : () => _guard(_t('bk2Running'), () async {
                              await _c.runNow(_space!);
                              _snack(_t('bk2Done'));
                            }),
                            icon: const Icon(Icons.backup_outlined),
                            label: Text(_t('bk2Now'), style: const TextStyle(fontFamily: _font)),
                          ),
                        ),
                      ]),
                    ],
                    const SizedBox(height: 18),
                    Text(_t('bk2Sets'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    _card([
                      ListTile(
                        key: const Key('bk2-from-file'),
                        enabled: !_busy,
                        leading: const Icon(Icons.file_open_outlined, color: AppColors.primary),
                        title: Text(_t('bk2FromFile'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700)),
                        subtitle: Text(_t('bk2FromFileHint'), style: const TextStyle(fontFamily: _font, fontSize: 12)),
                        onTap: _busy ? null : _restoreFromFile,
                      ),
                    ]),
                    if (_sets.isEmpty)
                      Text(_t('bk2NoSets'), style: TextStyle(fontFamily: _font, fontSize: 12, color: AppColors.textSecondary)),
                    for (final set in _sets)
                      _card([
                        ListTile(
                          title: Text(_when(set.startedAt?.millisecondsSinceEpoch),
                              style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700)),
                          subtitle: Text(
                            [if (set.local) _t('bk2OnDevice'), if (set.cloud) _t('bk2InCloud')].join(' · '),
                            style: const TextStyle(fontFamily: _font, fontSize: 12),
                          ),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            if (set.local)
                              IconButton(
                                key: Key('bk2-save-${set.id}'),
                                tooltip: _t('bk2SaveFile'),
                                onPressed: _busy ? null : () => _saveAsFile(set),
                                icon: const Icon(Icons.save_alt_rounded),
                              ),
                            TextButton(
                              onPressed: _busy ? null : () => _restore(set),
                              child: Text(_t('bk2Restore'), style: const TextStyle(fontFamily: _font)),
                            ),
                          ]),
                        ),
                      ]),
                  ],
                ),
    );
  }

  Widget _card(List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );

  Widget _row(IconData icon, String label, String value) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Row(children: [
          Icon(icon, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: const TextStyle(fontFamily: _font, fontSize: 13))),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.end,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: _font, fontSize: 13, fontWeight: FontWeight.w700)),
          ),
        ]),
      );
}
