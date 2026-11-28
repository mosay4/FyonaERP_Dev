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
    final items = [for (final s in sets) BackupListItem(s.id, s.updated ?? s.startedAt?.toLocal() ?? DateTime.now(), s.bytes, cloud: s)]
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
        colors: _brand,
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
        icon: Icons.move_to_inbox_rounded,
        colors: _brand,
        scenes: [
          IntroScene(const [Icons.upload_file_rounded, Icons.storefront_rounded], _t('si3Intro1')),
          IntroScene(const [Icons.table_chart_rounded, Icons.face_rounded], _t('si3Intro2'), saraAt: 1),
          IntroScene(const [Icons.edit_note_rounded, Icons.fact_check_rounded], _t('si3Intro3')),
          IntroScene(const [Icons.fingerprint_rounded, Icons.verified_rounded], _t('siIntro4')),
        ],
        points: [
          (Icons.inventory_2_rounded, _t('si3Point1')),
          (Icons.shield_rounded, _t('si3Point2')),
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
        // The two ways to restore, side by side as squares, each in its
        // own colour (as the screen was before; owner, 28-11).
        Row(children: [
          Expanded(
            child: _Square(
              key: const Key('bkh-device'),
              icon: Icons.phone_android_rounded,
              title: _t('bkhFromDevice'),
              color: const Color(0xFF9E1B32),
              onTap: _busy ? null : _restoreFromDevice,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _Square(
              key: const Key('bkh-cloud'),
              icon: Icons.cloud_download_rounded,
              title: _t('bkhFromCloud'),
              color: const Color(0xFF1E5AA8),
              onTap: _busy ? null : _restoreFromCloud,
            ),
          ),
        ]),
        const SizedBox(height: 12),
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
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8),
            child: Text(_t('bkhMoveData'),
                style: TextStyle(fontFamily: _font, fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.textSecondary)),
          ),
          // Small squares, each with a moving icon that says what it does.
          Row(children: [
            Expanded(
              child: _MoveSquare(
                key: const Key('bkh-export'),
                title: _t('bkhExportBtn'),
                color: const Color(0xFF0F766E),
                export: true,
                onTap: _busy ? null : _openExport,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _MoveSquare(
                key: const Key('bkh-import'),
                title: _t('siTitle'),
                color: const Color(0xFF9E1B32),
                export: false,
                onTap: _busy ? null : _openImport,
              ),
            ),
          ]),
        ],
      ]),
    );
  }
}

/// FYONA's brand red (the explainers of export and import).
const _brand = [Color(0xFF9E1B32), Color(0xFF6B0E22)];

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
          boxShadow: [BoxShadow(color: const Color(0xFF9E1B32).withValues(alpha: .18), blurRadius: 14, offset: const Offset(0, 6))],
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

/// A way to restore: a square in its own colour.
class _Square extends StatelessWidget {
  const _Square({super.key, required this.icon, required this.title, required this.color, this.onTap});
  final IconData icon;
  final String title;
  final Color color;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onTap == null ? .55 : 1,
        child: Material(
          color: color.withValues(alpha: .07),
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onTap,
            child: Container(
              height: 122,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: color.withValues(alpha: .28)),
              ),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [color, Color.lerp(color, Colors.black, .25)!]),
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: color.withValues(alpha: .3), blurRadius: 12, offset: const Offset(0, 5))],
                  ),
                  child: Icon(icon, color: Colors.white, size: 25),
                ),
                const SizedBox(height: 10),
                Text(title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    style: TextStyle(fontFamily: _font, fontSize: 13.5, fontWeight: FontWeight.w800, color: color, height: 1.3)),
              ]),
            ),
          ),
        ),
      );
}

/// Export / smart import: a small square whose icon moves — a sheet of
/// data leaving its box (export), rows of data dropping into the tray
/// (import). No Sara here: she has her own place inside the import.
class _MoveSquare extends StatefulWidget {
  const _MoveSquare({super.key, required this.title, required this.color, required this.export, this.onTap});
  final String title;
  final Color color;
  final bool export;
  final VoidCallback? onTap;
  @override
  State<_MoveSquare> createState() => _MoveSquareState();
}

class _MoveSquareState extends State<_MoveSquare> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200));

  @override
  void initState() {
    super.initState();
    // Widget tests wait for the screen to settle: the icon moves in the
    // app only.
    if (!_inTest) _c.repeat();
  }

  static bool get _inTest => WidgetsBinding.instance.runtimeType.toString().contains('TestWidgetsFlutterBinding');

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    return Opacity(
      opacity: widget.onTap == null ? .55 : 1,
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: widget.onTap,
          child: Container(
            height: 104,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: c.withValues(alpha: .25)),
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              SizedBox(
                width: 54,
                height: 46,
                child: AnimatedBuilder(
                  animation: _c,
                  builder: (_, _) => CustomPaint(painter: _MovePainter(t: _c.value, color: c, export: widget.export)),
                ),
              ),
              const SizedBox(height: 8),
              Text(widget.title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: _font, fontSize: 12.5, fontWeight: FontWeight.w800, color: c, height: 1.25)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Export: a data sheet rises out of an open box and flies off with an
/// arrow. Import: three rows of data drop one after another into a tray.
class _MovePainter extends CustomPainter {
  _MovePainter({required this.t, required this.color, required this.export});
  final double t;
  final Color color;
  final bool export;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final soft = Paint()..color = color.withValues(alpha: .14);
    // The tray / box at the bottom.
    final tray = Path()
      ..moveTo(w * .12, h * .58)
      ..lineTo(w * .12, h * .92)
      ..lineTo(w * .88, h * .92)
      ..lineTo(w * .88, h * .58);
    canvas.drawRRect(RRect.fromLTRBR(w * .12, h * .58, w * .88, h * .92, const Radius.circular(4)), soft);
    canvas.drawPath(tray, stroke);
    if (export) {
      // The sheet rises, then lifts away with the arrow, then a new one.
      final p = Curves.easeInOut.transform((t * 1.25).clamp(0.0, 1.0));
      final y = h * .62 - p * h * .55;
      final x = w * .5 + (p > .6 ? (p - .6) * w * .5 : 0);
      final fade = p > .75 ? 1 - (p - .75) / .25 : 1.0;
      final sheet = RRect.fromLTRBR(x - w * .17, y - h * .2, x + w * .17, y + h * .22, const Radius.circular(3));
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(0, 0, w, h * .9));
      canvas.drawRRect(sheet, Paint()..color = Colors.white.withValues(alpha: fade));
      canvas.drawRRect(sheet, Paint()
        ..color = color.withValues(alpha: fade)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
      for (var i = 0; i < 3; i++) {
        final ly = y - h * .1 + i * h * .1;
        canvas.drawLine(Offset(x - w * .1, ly), Offset(x + w * (i == 2 ? .03 : .1), ly),
            Paint()
              ..color = color.withValues(alpha: .6 * fade)
              ..strokeWidth = 1.8
              ..strokeCap = StrokeCap.round);
      }
      canvas.restore();
      // The arrow: up and out.
      final a = Curves.easeOut.transform(((t - .35) * 2).clamp(0.0, 1.0));
      if (a > 0 && a < 1) {
        final o = Offset(w * .78, h * .42 - a * h * .3);
        final arrow = Paint()
          ..color = color.withValues(alpha: 1 - a * .8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(o.translate(0, h * .2), o, arrow);
        canvas.drawLine(o, o.translate(-w * .07, h * .08), arrow);
        canvas.drawLine(o, o.translate(w * .07, h * .08), arrow);
      }
    } else {
      // Rows of data fall into the tray, one after another.
      for (var i = 0; i < 3; i++) {
        final k = ((t - i * .18) * 1.6).clamp(0.0, 1.0);
        if (k <= 0) continue;
        final p = Curves.easeIn.transform(k);
        final target = h * (.84 - i * .09);
        final y = -h * .1 + p * (target + h * .1);
        final fade = t > .9 ? (1 - (t - .9) / .1) : 1.0;
        final rw = w * (.5 - i * .06);
        canvas.drawRRect(
            RRect.fromLTRBR(w * .5 - rw / 2, y - h * .035, w * .5 + rw / 2, y + h * .035, const Radius.circular(3)),
            Paint()..color = color.withValues(alpha: (.55 + i * .15) * fade));
      }
      // The arrow pointing in.
      final bob = (t * 2 % 1) < .5 ? (t * 2 % 1) * 2 : 2 - (t * 2 % 1) * 2;
      final lip = h * .58 + bob * h * .02;
      final arrow = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(w * .12, lip), Offset(w * .3, lip), arrow);
      canvas.drawLine(Offset(w * .7, lip), Offset(w * .88, lip), arrow);
    }
  }

  @override
  bool shouldRepaint(_MovePainter o) => o.t != t || o.color != color;
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
