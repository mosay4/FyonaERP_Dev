import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/auth/presentation/widgets/app_pin_sheet.dart';
import '../../../features/branches/data/branch_scope.dart';
import '../../../features/core_business/data/local_commerce/local_commerce_api.dart';
import '../../../features/core_business/data/local_directory/directory_pilot.dart';
import '../../../features/core_business/data/local_directory/directory_scope.dart';
import '../../../features/core_business/data/local_directory/directory_secure_storage.dart';
import '../../../features/inventory/presentation/providers/inventory_providers.dart';
import '../../backup/presentation/operation_motion.dart';
import '../../di/providers.dart';
import '../../localization/app_localizations.dart';
import '../../media/media_store.dart';
import '../../theme/app_colors.dart';
import '../business_import.dart';
import '../import_plan.dart';
import '../import_schema.dart';
import '../import_session.dart';
import '../import_source.dart';
import '../sara_mapping.dart';

String _t(String key, [Map<String, dynamic>? p]) => AppLocalizations.t(key, p);
const _font = 'Cairo';
const _red = Color(0xFFD32F2F);
const _yellow = Color(0xFFE09A00);
const _green = Color(0xFF2E7D32);
const _blue = Color(0xFF1565C0);
const _sara1 = Color(0xFF7B2FF7), _sara2 = Color(0xFFE0457B);

/// Final confirmation before an import or an undo (fingerprint or the
/// app's PIN). Replaceable in tests.
typedef ImportConfirm = Future<bool> Function(BuildContext context, WidgetRef ref, String reason);
final smartImportConfirmProvider = Provider<ImportConfirm>(
  (ref) => (context, widgetRef, reason) =>
      verifySensitiveAction(context, widgetRef, reason: reason, existingCredentialsOnly: true),
);

/// Sara's two calls in the window (replaceable in tests).
class SmartImportSara {
  const SmartImportSara({required this.schema, required this.agent});
  final Future<List<Map<String, dynamic>>?> Function(List<TableAnalysis> tables) schema;
  final Future<SaraAgentAnswer?> Function(String message, ImportSession s, List<Map<String, String>> history) agent;
}

final smartImportSaraProvider = Provider<SmartImportSara>((ref) {
  final api = ref.read(apiClientProvider);
  return SmartImportSara(
    schema: (tables) => saraImportSchema(api, tables),
    agent: (message, s, history) =>
        saraImportAgent(api, message: message, currency: s.currency, tables: s.analysis, history: history),
  );
});

/// Every place a table of the file can go in FYONA (the user can choose
/// any of them), grouped as the picker shows them.
const importRoleGroups = <String, List<TableRole>>{
  'cards': [TableRole.customers, TableRole.suppliers, TableRole.products, TableRole.accounts],
  'productParts': [TableRole.units, TableRole.barcodes, TableRole.images, TableRole.categories, TableRole.prices, TableRole.stock],
  'balances': [TableRole.balances],
  'reference': [TableRole.branches, TableRole.currencies],
  'none': [TableRole.history, TableRole.unsupported],
};

IconData importRoleIcon(TableRole r) => switch (r) {
      TableRole.customers => Icons.people_alt_rounded,
      TableRole.suppliers => Icons.local_shipping_rounded,
      TableRole.products => Icons.inventory_2_rounded,
      TableRole.accounts => Icons.account_balance_rounded,
      TableRole.units => Icons.straighten_rounded,
      TableRole.barcodes => Icons.qr_code_2_rounded,
      TableRole.images => Icons.photo_library_rounded,
      TableRole.categories => Icons.category_rounded,
      TableRole.prices => Icons.sell_rounded,
      TableRole.stock => Icons.warehouse_rounded,
      TableRole.balances => Icons.request_quote_rounded,
      TableRole.branches => Icons.storefront_rounded,
      TableRole.currencies => Icons.currency_exchange_rounded,
      TableRole.history => Icons.history_rounded,
      TableRole.unsupported => Icons.block_rounded,
      TableRole.unknown => Icons.help_outline_rounded,
    };

Color importRoleColor(TableRole r) => r.importable
    ? _green
    : r.part || r == TableRole.categories
        ? _blue
        : r.reference
            ? AppColors.textSecondary
            : _red;

/// Entry card (kept for places that list it as a row).
class SmartImportEntry extends ConsumerWidget {
  const SmartImportEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(businessLocalLedgerScopeProvider);
    if (scope == null || scope.member) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: AppColors.border)),
      child: ListTile(
        key: const Key('si-entry'),
        leading: const Icon(Icons.auto_awesome_rounded, color: AppColors.primary),
        title: Text(_t('siTitle'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => openSmartImport(context),
      ),
    );
  }
}

/// Opens the import as its own full-screen window (also from Sara).
Future<void> openSmartImport(BuildContext context) => Navigator.of(context).push(
      MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => const SmartImportPage()),
    );

class SmartImportPage extends ConsumerStatefulWidget {
  const SmartImportPage({super.key, this.initialFile});

  /// Tests: start with this file (no picker).
  final File? initialFile;
  @override
  ConsumerState<SmartImportPage> createState() => _SmartImportPageState();
}

class _SmartImportPageState extends ConsumerState<SmartImportPage> {
  int _step = 0; // 0 file · 1 plan · 2 review
  File? _file;
  String? _sha;
  ImportSession? _session;
  TableAnalysis? _current;
  bool _busy = false;
  String? _progress;
  String? _saraNote;
  List<Map<String, Object?>> _batches = const [];
  ImportRegistry? _registry;
  final _chat = <({bool me, String text, List<String> done})>[];

  DirectoryAccess? get _scope {
    final s = ref.read(businessLocalLedgerScopeProvider);
    return s == null || s.member ? null : s;
  }

  @override
  void initState() {
    super.initState();
    _loadBatches();
    final f = widget.initialFile;
    if (f != null) WidgetsBinding.instance.addPostFrameCallback((_) => _open(f));
  }

  @override
  void dispose() {
    _registry?.close();
    super.dispose();
  }

  Future<ImportRegistry> _reg() async {
    final r = _registry;
    if (r != null) return r;
    final scope = _scope!;
    final key = await const SecureDirectoryKeys().read(scope.workspace.storageId);
    if (key == null) throw StateError('no key');
    final root = await businessDirectoryRoot();
    return _registry = await ImportRegistry.open('${root.path}/imports/${scope.workspace.storageId}.sqlite', key);
  }

  BusinessImporter _importer(ImportRegistry reg) {
    final inv = ref.read(inventoryApiProvider);
    if (inv is! LocalInventoryApi) throw StateError('not a device ledger');
    final images = _session?.images ?? ImportImages.none;
    return BusinessImporter(
      store: ref.read(directoryPilotStoreProvider),
      access: _scope!,
      registry: reg,
      createProduct: inv.createProduct,
      deleteProduct: inv.deleteProduct,
      categories: inv.categories,
      createCategory: inv.createCategory,
      createUnit: inv.createUnit,
      addBarcode: inv.addBarcode,
      picture: (name) async {
        final p = await images.load(name);
        if (p == null) return null;
        return (await MediaStore.instance()).put(p.$1, mime: p.$2);
      },
    );
  }

  Future<void> _loadBatches() async {
    final scope = _scope;
    if (scope == null) return;
    try {
      final list = await (await _reg()).batches(scope.branchId);
      if (mounted) setState(() => _batches = list);
    } catch (_) {}
  }

  void _snack(String text, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: error ? _red : null,
      content: Text(text, style: const TextStyle(fontFamily: _font)),
    ));
  }

  String _failure(Object e) {
    if (e is ImportRejected) return _t('siErr_${e.code}');
    if (e is ImportRefused) return _t('siErr_${e.code}', {'n': '${e.count}'});
    return _t('siErrGeneric');
  }

  Future<void> _guard(Future<void> Function() work) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await work();
    } catch (e) {
      _snack(_failure(e), error: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  // ── step 0: the file → Sara arranges it ─────────────────────────────

  Future<void> _pick() async {
    final picked = await FilePicker.pickFiles(type: FileType.any, withData: false);
    final path = picked?.files.single.path;
    if (path != null) await _open(File(path));
  }

  /// Reads the file, understands every table, then Sara looks at what the
  /// rules were not sure of — all automatic, shown as it happens.
  Future<void> _open(File f) => _guard(() async {
        // What the branch already has (read again before the review).
        var existing = <String>{};
        try {
          existing = await _importer(await _reg()).existingNames();
        } catch (_) {}
        final saraOk = <bool>[true];
        Future<ImportSession> work(void Function(String s, double d) stage) async {
          stage(_t('si2StageRead'), .05);
          final tables = await readImportFile(f);
          final images = await readImportImages(f);
          stage(_t('si2StageUnderstand', {'n': '${tables.length}'}), .3);
          final s = await ImportSession.analyze(tables, images: images, currentBranchName: BranchScope.branchName);
          s.existing = existing;
          stage(_t('si2StageLink'), .55);
          final unclear = s.forSara;
          if (unclear.isNotEmpty) {
            stage(_t('si2StageSara', {'n': '${unclear.length}'}), .7);
            final answers = await ref.read(smartImportSaraProvider).schema(unclear);
            if (answers == null) {
              saraOk[0] = false;
            } else {
              await s.applySara(answers);
            }
          }
          stage(_t('si2StageCheck'), .85);
          _sha = '${await sha256.bind(f.openRead()).first}';
          await s.buildReviews();
          return s;
        }

        if (!mounted) return;
        final ImportSession s;
        if (widget.initialFile != null) {
          // Tests: no motion route.
          s = await work((_, _) {});
        } else {
          s = await OperationMotion.run<ImportSession>(context,
              kind: MotionKind.smartImport,
              doneText: _t('si2Arranged'),
              failureText: _failure,
              work: (m) => work(m.stage));
        }
        setState(() {
          _file = f;
          _session = s;
          _current = s.importable.firstOrNull;
          _saraNote = saraOk[0] ? null : _t('si2SaraOffline');
          _step = 1;
        });
      });

  // ── step 1: the plan ────────────────────────────────────────────────

  Future<void> _changeRole(TableAnalysis a) async {
    final role = await showModalBottomSheet<TableRole>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (_) => _RolePicker(table: a.table.name, current: a.role),
    );
    if (role == null || role == a.role || _session == null) return;
    await _guard(() async {
      await _session!.setRole(a, role);
      if (role.part && a.link == null) _snack(_t('si2NoLinkFound', {'t': a.table.name}), error: true);
    });
  }

  Future<void> _editColumns(TableAnalysis a) async {
    final s = _session;
    if (s == null) return;
    final changed = await showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (_) => FractionallySizedBox(heightFactor: .92, child: ColumnMappingSheet(analysis: a)),
    );
    if (changed == null) return;
    await _guard(() async {
      s.setMapping(a, changed);
      if (a.role.part) await linkImportSchema(s.analysis, context: s.context);
    });
  }

  Future<void> _pickCurrency() async {
    final s = _session;
    if (s == null) return;
    final code = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (_) => _CurrencyPicker(current: s.currency),
    );
    if (code != null) setState(() => s.setCurrency(code));
  }

  Future<void> _pickBranch() async {
    final s = _session;
    if (s == null) return;
    final choices = s.branchChoices.keys.toList();
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const _Grip(),
          _SheetTitle(icon: Icons.storefront_rounded, title: _t('si2BranchTitle'), hint: _t('si2BranchHint')),
          for (final b in ['', ...choices])
            ListTile(
              key: Key('si-branch-$b'),
              leading: Icon(b.isEmpty ? Icons.all_inclusive_rounded : Icons.storefront_rounded, color: AppColors.primary),
              title: Text(b.isEmpty ? _t('si2AllBranches') : b, style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700)),
              trailing: (s.sourceBranch ?? '') == b ? const Icon(Icons.check_circle_rounded, color: _green) : null,
              onTap: () => Navigator.pop(ctx, b),
            ),
          const SizedBox(height: 12),
        ]),
      ),
    );
    if (picked != null) setState(() => s.setSourceBranch(picked.isEmpty ? null : picked));
  }

  Future<void> _toReview() => _guard(() async {
        final s = _session!;
        final existing = await _importer(await _reg()).existingNames();
        if (existing.length != s.existing.length || !existing.containsAll(s.existing)) {
          s.existing = existing;
          s.reviews.clear();
        }
        await s.buildReviews(onRows: (t, n) {
          if (mounted) setState(() => _progress = '$t · ${_t('siRows', {'n': '$n'})}');
        });
        setState(() {
          _current = s.reviews.keys.firstOrNull;
          _step = 2;
        });
      });

  // ── Sara inside the window ──────────────────────────────────────────

  Future<void> _openSara() async {
    final s = _session;
    if (s == null) {
      _snack(_t('si2SaraNeedsFile'));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FractionallySizedBox(
        heightFactor: .88,
        child: _SaraChat(
          history: _chat,
          onSend: (text) async {
            final hist = [
              for (final m in _chat.reversed.take(8).toList().reversed) {'role': m.me ? 'user' : 'assistant', 'content': m.text},
            ];
            setState(() => _chat.add((me: true, text: text, done: const [])));
            final ans = await ref.read(smartImportSaraProvider).agent(text, s, hist);
            if (ans == null) {
              _chat.add((me: false, text: _t('si2SaraOffline'), done: const []));
            } else {
              final done = await s.applyOps(ans.ops);
              _chat.add((me: false, text: ans.reply.isEmpty ? _t('si2SaraDoneShort') : ans.reply, done: done));
            }
            if (mounted) setState(() {});
          },
          onArrange: () async {
            final unclear = s.analysis.where((a) => a.by != 'user' && !a.role.importable || a.confidence < .9).toList();
            final ans = await ref.read(smartImportSaraProvider).schema(unclear.isEmpty ? s.analysis : unclear);
            if (ans == null) {
              _chat.add((me: false, text: _t('si2SaraOffline'), done: const []));
            } else {
              final n = await s.applySara(ans);
              _chat.add((me: false, text: _t('si2SaraArranged', {'n': '$n'}), done: const []));
            }
            if (mounted) setState(() {});
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  // ── step 2: review → confirm → import ───────────────────────────────

  Future<void> _apply() async {
    final s = _session;
    if (s == null) return;
    final ready = [for (final e in s.reviews.entries) if (e.value.acceptedCount > 0) e];
    final total = ready.fold<int>(0, (a, e) => a + e.value.acceptedCount);
    if (total == 0 || _file == null || _sha == null) return;
    if (!await ref.read(smartImportConfirmProvider)(context, ref, _t('siConfirmReason', {'n': '$total'}))) return;
    if (!mounted) return;
    setState(() => _busy = true);
    var refusedByRules = 0;
    try {
      final ids = await OperationMotion.run<List<String>>(context,
          kind: MotionKind.smartImport,
          doneText: _t('siDoneShort', {'n': '$total'}),
          failureText: _failure, work: (m) async {
        final reg = await _reg();
        final imp = _importer(reg);
        var base = 0;
        final ids = <String>[];
        for (final e in ready) {
          final p = e.value.toPreview();
          m.stage(_t('siImportingTable', {'t': _t('si2Role_${e.key.role.name}')}), base / total);
          final key = '$_sha|${e.key.table.name}|${e.key.role.name}';
          ids.add(await imp.apply(p, fileSha: '${sha256.convert(utf8.encode(key))}', fileName: _file!.uri.pathSegments.last,
              onProgress: (d, n) => m.progress((base + d) / total)));
          refusedByRules += imp.skippedRows.length;
          base += p.ready;
        }
        return ids;
      });
      _snack(refusedByRules == 0
          ? _t('siDone', {'id': ids.map((i) => i.substring(0, 8)).join(', ')})
          : _t('si2DoneSome', {'n': '$refusedByRules'}));
      setState(() {
        _step = 0;
        _session = null;
        _file = null;
        _chat.clear();
      });
    } catch (_) {
      // shown by the motion
    } finally {
      if (mounted) setState(() => _busy = false);
      await _loadBatches();
    }
  }

  Future<void> _undo(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t('siUndoTitle'), style: const TextStyle(fontFamily: _font)),
        content: Text(_t('siUndoBody'), style: const TextStyle(fontFamily: _font, fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t('cancel'))),
          FilledButton(key: const Key('si-undo-confirm'), onPressed: () => Navigator.pop(ctx, true), child: Text(_t('siUndo'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (!await ref.read(smartImportConfirmProvider)(context, ref, _t('siUndoTitle'))) return;
    await _guard(() async {
      await _importer(await _reg()).undo(id);
      _snack(_t('siUndone'));
      await _loadBatches();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: _scope == null
          ? const SizedBox.shrink()
          : Column(children: [
              _Header(
                step: _step,
                onClose: () => Navigator.of(context).maybePop(),
                onStep: _busy ? null : (i) => setState(() => _step = i < _step ? i : _step),
                onSara: _busy ? null : _openSara,
              ),
              if (_busy)
                Column(children: [
                  const LinearProgressIndicator(minHeight: 3),
                  if (_progress != null)
                    Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text(_progress!, style: TextStyle(fontFamily: _font, fontSize: 12, color: AppColors.textSecondary)),
                    ),
                ]),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 380),
                  switchInCurve: Curves.easeOutCubic,
                  transitionBuilder: (child, a) => FadeTransition(
                    opacity: a,
                    child: SlideTransition(position: Tween(begin: const Offset(0, .04), end: Offset.zero).animate(a), child: child),
                  ),
                  child: KeyedSubtree(
                    key: ValueKey(_step),
                    child: switch (_step) { 0 => _fileStep(), 1 => _planStep(), _ => _reviewStep() },
                  ),
                ),
              ),
            ]),
    );
  }

  Widget _fileStep() => ListView(padding: const EdgeInsets.fromLTRB(18, 8, 18, 28), children: [
        const _Orbit(),
        const SizedBox(height: 6),
        Text(_t('si2Hero'),
            textAlign: TextAlign.center, style: const TextStyle(fontFamily: _font, fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(_t('si2HeroSub'),
            textAlign: TextAlign.center, style: TextStyle(fontFamily: _font, fontSize: 13.5, color: AppColors.textSecondary, height: 1.6)),
        const SizedBox(height: 16),
        Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
          _Pill(icon: Icons.auto_awesome_rounded, text: _t('si2Point1'), color: _sara1),
          _Pill(icon: Icons.fact_check_rounded, text: _t('si2Point2'), color: _green),
          _Pill(icon: Icons.shield_rounded, text: _t('si2Point3'), color: AppColors.primary),
        ]),
        const SizedBox(height: 22),
        SizedBox(
          height: 58,
          child: FilledButton.icon(
            key: const Key('si-pick'),
            style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
            onPressed: _busy ? null : _pick,
            icon: const Icon(Icons.upload_file_rounded),
            label: Text(_t('siPick'), style: const TextStyle(fontFamily: _font, fontSize: 16.5, fontWeight: FontWeight.w800)),
          ),
        ),
        const SizedBox(height: 10),
        Text(_t('si2Formats'),
            textAlign: TextAlign.center, style: TextStyle(fontFamily: _font, fontSize: 12, color: AppColors.textSecondary)),
        if (_batches.isNotEmpty) ...[
          const SizedBox(height: 22),
          Container(
            decoration: BoxDecoration(
                color: AppColors.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: AppColors.border)),
            child: Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                leading: const Icon(Icons.history_rounded, color: AppColors.primary),
                title: Text(_t('siBatches'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
                children: [
                  for (final b in _batches)
                    ListTile(
                      dense: true,
                      title: Text('${b['file_name']}', style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700)),
                      subtitle: Text('${_t('siStatus_${b['status']}')} · ${b['rows_done']}/${b['rows_ready']}',
                          style: const TextStyle(fontFamily: _font, fontSize: 12)),
                      trailing: b['status'] == 'undone'
                          ? null
                          : TextButton(
                              onPressed: _busy ? null : () => _undo('${b['id']}'),
                              child: Text(_t('siUndo'), style: const TextStyle(fontFamily: _font, color: _red)),
                            ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ]);

  Widget _planStep() {
    final s = _session;
    if (s == null) return const SizedBox.shrink();
    final importable = s.importable, linked = s.linked, reference = s.reference, skipped = s.skipped;
    final branches = s.branchChoices;
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 20), children: [
          _Summary(add: importable.length, linked: linked.length, skipped: skipped.length),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: _SettingChip(
                key: const Key('si-currency'),
                icon: Icons.payments_rounded,
                label: _t('si2Currency'),
                value: '${_t('cur_${s.currency}')} (${s.currency})',
                onTap: _busy ? null : _pickCurrency,
              ),
            ),
            if (branches.length > 1) ...[
              const SizedBox(width: 10),
              Expanded(
                child: _SettingChip(
                  key: const Key('si-branch'),
                  icon: Icons.storefront_rounded,
                  label: _t('si2FileBranch'),
                  value: s.sourceBranch ?? _t('si2AllBranches'),
                  onTap: _busy ? null : _pickBranch,
                ),
              ),
            ],
          ]),
          if (_saraNote != null) ...[
            const SizedBox(height: 10),
            _Note(text: _saraNote!, color: _yellow, icon: Icons.cloud_off_rounded),
          ],
          const SizedBox(height: 16),
          if (importable.isNotEmpty) ...[
            _SectionTitle(text: _t('si2WillAdd'), color: _green, icon: Icons.add_circle_rounded),
            for (final a in importable)
              _TableCard(
                key: Key('si-table-${a.table.name}'),
                analysis: a,
                children: [for (final p in linked) if (p.link?.parent == a.table) p],
                onRole: _busy ? null : _changeRole,
                onColumns: _busy ? null : _editColumns,
              ),
          ],
          if (reference.isNotEmpty) ...[
            const SizedBox(height: 8),
            _SectionTitle(text: _t('si2ForReference'), color: AppColors.textSecondary, icon: Icons.info_rounded),
            for (final a in reference)
              _TableCard(key: Key('si-table-${a.table.name}'), analysis: a, onRole: _busy ? null : _changeRole),
          ],
          if (skipped.isNotEmpty) ...[
            const SizedBox(height: 8),
            _SectionTitle(text: _t('si2WontAdd', {'n': '${skipped.length}'}), color: _red, icon: Icons.remove_circle_rounded),
            for (final a in skipped)
              _TableCard(key: Key('si-table-${a.table.name}'), analysis: a, onRole: _busy ? null : _changeRole, compact: true),
          ],
        ]),
      ),
      _BottomBar(
        child: SizedBox(
          width: double.infinity,
          height: 54,
          child: FilledButton.icon(
            key: const Key('si-review'),
            style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
            onPressed: _busy || importable.isEmpty || importable.any((a) => !a.mapping.containsKey('name')) ? null : _toReview,
            icon: const Icon(Icons.fact_check_rounded),
            label: Text(_t('si2ToReview', {'n': '${importable.length}'}),
                style: const TextStyle(fontFamily: _font, fontSize: 15.5, fontWeight: FontWeight.w800)),
          ),
        ),
      ),
    ]);
  }

  Widget _reviewStep() {
    final s = _session;
    if (s == null || s.reviews.isEmpty) return const SizedBox.shrink();
    final keys = s.reviews.keys.toList();
    final cur = keys.contains(_current) ? _current! : keys.first;
    final total = s.readyCount;
    return Column(children: [
      SizedBox(
        height: 56,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), children: [
          for (final a in keys)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: ChoiceChip(
                key: Key('si-review-${a.table.name}'),
                avatar: Icon(importRoleIcon(a.role), size: 18, color: a == cur ? Colors.white : AppColors.primary),
                label: Text('${_t('si2Role_${a.role.name}')} · ${s.reviews[a]!.acceptedCount}',
                    style: TextStyle(fontFamily: _font, fontSize: 12.5, fontWeight: FontWeight.w700, color: a == cur ? Colors.white : null)),
                selected: a == cur,
                selectedColor: AppColors.primary,
                showCheckmark: false,
                onSelected: (_) => setState(() => _current = a),
              ),
            ),
        ]),
      ),
      Expanded(
        child: ImportReviewView(
          key: ValueKey(cur),
          review: s.reviews[cur]!,
          images: s.images,
          skipped: [
            for (final t in s.skipped) _t('siSkippedTableWhy', {'t': t.table.name, 'why': _t('siWhy_${t.reason ?? 'no_place'}')}),
          ],
          onChanged: () => setState(() {}),
        ),
      ),
      _BottomBar(
        child: Row(children: [
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_t('siWillAdd', {'n': '$total'}),
                  style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800, color: _green, fontSize: 15)),
              Text(_t('si2SavedOnlyAfter'), style: TextStyle(fontFamily: _font, fontSize: 11.5, color: AppColors.textSecondary)),
            ]),
          ),
          SizedBox(
            height: 50,
            child: FilledButton.icon(
              key: const Key('si-apply'),
              style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
              onPressed: _busy || total == 0 ? null : _apply,
              icon: const Icon(Icons.fingerprint_rounded),
              label: Text(_t('siImport', {'n': '$total'}), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
            ),
          ),
        ]),
      ),
    ]);
  }
}

// ── pieces ──────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.step, required this.onClose, this.onStep, this.onSara});
  final int step;
  final VoidCallback onClose;
  final void Function(int)? onStep;
  final VoidCallback? onSara;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [Color(0xFF9E1B32), Color(0xFF6B0E22)], begin: Alignment.topRight, end: Alignment.bottomLeft),
          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(26)),
          boxShadow: [BoxShadow(color: const Color(0xFF9E1B32).withValues(alpha: .25), blurRadius: 18, offset: const Offset(0, 6))],
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 12, 14),
            child: Column(children: [
              Row(children: [
                IconButton(
                    key: const Key('si-close'),
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded, color: Colors.white)),
                Expanded(
                  child: Text(_t('siTitle'),
                      style: const TextStyle(fontFamily: _font, fontSize: 19, fontWeight: FontWeight.w800, color: Colors.white)),
                ),
                _SaraButton(onTap: onSara),
              ]),
              const SizedBox(height: 8),
              _Steps(step: step, onTap: onStep),
            ]),
          ),
        ),
      );
}

/// Sara, always at the top of the window.
class _SaraButton extends StatefulWidget {
  const _SaraButton({this.onTap});
  final VoidCallback? onTap;
  @override
  State<_SaraButton> createState() => _SaraButtonState();
}

class _SaraButtonState extends State<_SaraButton> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, child) => Container(
          padding: const EdgeInsets.all(1.6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: SweepGradient(
              colors: const [_sara1, _sara2, Colors.white, _sara1],
              transform: GradientRotation(_c.value * 2 * math.pi),
            ),
          ),
          child: child,
        ),
        child: Material(
          color: const Color(0xFF2A0710),
          borderRadius: BorderRadius.circular(21),
          child: InkWell(
            key: const Key('si-sara'),
            borderRadius: BorderRadius.circular(21),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 6),
                Text(_t('si2Sara'), style: const TextStyle(fontFamily: _font, color: Colors.white, fontWeight: FontWeight.w800)),
              ]),
            ),
          ),
        ),
      );
}

class _Steps extends StatelessWidget {
  const _Steps({required this.step, this.onTap});
  final int step;
  final void Function(int)? onTap;
  static const _icons = [Icons.upload_file_rounded, Icons.account_tree_rounded, Icons.fact_check_rounded];
  @override
  Widget build(BuildContext context) => Row(children: [
        for (var i = 0; i < 3; i++) ...[
          Expanded(
            child: InkWell(
              key: Key('si-step-$i'),
              borderRadius: BorderRadius.circular(14),
              onTap: onTap == null ? null : () => onTap!(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
                decoration: BoxDecoration(
                  color: i == step ? Colors.white : Colors.white.withValues(alpha: i < step ? .22 : .10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(i < step ? Icons.check_circle_rounded : _icons[i],
                      size: 17, color: i == step ? AppColors.primary : Colors.white),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(_t('si2Step$i'),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontFamily: _font,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: i == step ? AppColors.primary : Colors.white)),
                  ),
                ]),
              ),
            ),
          ),
          if (i < 2) const SizedBox(width: 6),
        ],
      ]);
}

/// The first screen's moving picture: the kinds of data circling FYONA.
class _Orbit extends StatefulWidget {
  const _Orbit();
  @override
  State<_Orbit> createState() => _OrbitState();
}

class _OrbitState extends State<_Orbit> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 14))..repeat();
  static const _icons = [
    Icons.inventory_2_rounded,
    Icons.people_alt_rounded,
    Icons.qr_code_2_rounded,
    Icons.account_balance_rounded,
    Icons.photo_library_rounded,
    Icons.local_shipping_rounded,
  ];
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 190,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) {
            final t = _c.value * 2 * math.pi;
            return Stack(alignment: Alignment.center, children: [
              Container(
                width: 150,
                height: 150,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: AppColors.primary.withValues(alpha: .12), width: 1.5)),
              ),
              Transform.scale(
                scale: 1 + .04 * math.sin(t * 3),
                child: Container(
                  width: 78,
                  height: 78,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(colors: [Color(0xFF9E1B32), Color(0xFF6B0E22)]),
                    boxShadow: [BoxShadow(color: AppColors.primary.withValues(alpha: .35), blurRadius: 22, spreadRadius: 2)],
                  ),
                  child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 34),
                ),
              ),
              for (var i = 0; i < _icons.length; i++)
                Transform.translate(
                  offset: Offset(math.cos(t + i * math.pi / 3) * 75, math.sin(t + i * math.pi / 3) * 75),
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .08), blurRadius: 8, offset: const Offset(0, 3))],
                    ),
                    child: Icon(_icons[i], size: 19, color: AppColors.primary),
                  ),
                ),
            ]);
          },
        ),
      );
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(color: color.withValues(alpha: .09), borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontFamily: _font, fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
        ]),
      );
}

class _Summary extends StatelessWidget {
  const _Summary({required this.add, required this.linked, required this.skipped});
  final int add, linked, skipped;
  @override
  Widget build(BuildContext context) {
    Widget cell(String n, String label, Color c, IconData icon) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(color: c.withValues(alpha: .08), borderRadius: BorderRadius.circular(16)),
            child: Column(children: [
              Icon(icon, color: c, size: 20),
              const SizedBox(height: 4),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: double.parse(n)),
                duration: const Duration(milliseconds: 700),
                builder: (_, v, _) => Text('${v.round()}',
                    style: TextStyle(fontFamily: _font, fontSize: 22, fontWeight: FontWeight.w800, color: c)),
              ),
              Text(label, textAlign: TextAlign.center, style: TextStyle(fontFamily: _font, fontSize: 11.5, color: c, fontWeight: FontWeight.w700)),
            ]),
          ),
        );
    return Row(children: [
      cell('$add', _t('si2SumAdd'), _green, Icons.add_circle_rounded),
      const SizedBox(width: 8),
      cell('$linked', _t('si2SumLinked'), _blue, Icons.link_rounded),
      const SizedBox(width: 8),
      cell('$skipped', _t('si2SumSkipped'), _red, Icons.remove_circle_rounded),
    ]);
  }
}

class _SettingChip extends StatelessWidget {
  const _SettingChip({super.key, required this.icon, required this.label, required this.value, this.onTap});
  final IconData icon;
  final String label, value;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border)),
            child: Row(children: [
              Icon(icon, size: 20, color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: TextStyle(fontFamily: _font, fontSize: 11, color: AppColors.textSecondary)),
                  Text(value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: _font, fontSize: 13, fontWeight: FontWeight.w800)),
                ]),
              ),
              Icon(Icons.expand_more_rounded, color: AppColors.textSecondary),
            ]),
          ),
        ),
      );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.text, required this.color, required this.icon});
  final String text;
  final Color color;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Row(children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontFamily: _font, fontSize: 14.5, fontWeight: FontWeight.w800, color: color)),
        ]),
      );
}

class _Note extends StatelessWidget {
  const _Note({required this.text, required this.color, required this.icon});
  final String text;
  final Color color;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: color.withValues(alpha: .10), borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontFamily: _font, fontSize: 12.5, fontWeight: FontWeight.w700, color: color))),
        ]),
      );
}

/// One table of the file: what it is in FYONA (tap to put it anywhere
/// else), its rows, its columns, and the tables joined into it.
class _TableCard extends StatelessWidget {
  const _TableCard({super.key, required this.analysis, this.children = const [], this.onRole, this.onColumns, this.compact = false});
  final TableAnalysis analysis;
  final List<TableAnalysis> children;
  final Future<void> Function(TableAnalysis)? onRole;
  final Future<void> Function(TableAnalysis)? onColumns;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final a = analysis;
    final color = importRoleColor(a.role);
    final skipped = !a.role.importable && !a.role.reference && !(a.role.part && a.link != null) && a.role != TableRole.categories;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: skipped ? _red.withValues(alpha: .04) : AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: skipped ? _red.withValues(alpha: .25) : AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(12)),
              child: Icon(importRoleIcon(a.role), color: color, size: 21),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.table.name.split(' · ').last,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(fontFamily: _font, fontSize: 14, fontWeight: FontWeight.w800)),
                FutureBuilder<int>(
                  future: a.table.count(),
                  builder: (_, snap) => Text(
                    [
                      if (snap.hasData) _t('si2RowsN', {'n': '${snap.data}'}),
                      _t('siColumnsCount', {'n': '${a.table.columns.length}'}),
                      if (a.by == 'sara') _t('siBySara'),
                    ].join(' · '),
                    style: TextStyle(fontFamily: _font, fontSize: 11.5, color: AppColors.textSecondary),
                  ),
                ),
              ]),
            ),
            const SizedBox(width: 6),
            _RoleChip(key: Key('si-dest-${a.table.name}'), role: a.role, onTap: onRole == null ? null : () => onRole!(a)),
          ]),
          if (skipped) ...[
            const SizedBox(height: 8),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.warning_amber_rounded, size: 16, color: _yellow),
              const SizedBox(width: 6),
              Expanded(
                child: Text(_t('siWhy_${a.reason ?? 'no_place'}'),
                    style: const TextStyle(fontFamily: _font, fontSize: 12, color: _yellow, fontWeight: FontWeight.w700, height: 1.5)),
              ),
            ]),
          ],
          if (a.role.importable && a.confidence < .9) ...[
            const SizedBox(height: 8),
            _Note(text: _t('si2CheckColumns'), color: _yellow, icon: Icons.visibility_rounded),
          ],
          if (children.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final c in children)
                Tooltip(
                  message: c.table.name,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: _blue.withValues(alpha: .08), borderRadius: BorderRadius.circular(12)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(importRoleIcon(c.role), size: 15, color: _blue),
                      const SizedBox(width: 5),
                      Text(_t('si2Role_${c.role.name}'),
                          style: const TextStyle(fontFamily: _font, fontSize: 12, color: _blue, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ),
            ]),
          ],
          if (a.role.importable && onColumns != null) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: Key('si-columns-${a.table.name}'),
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  side: BorderSide(color: AppColors.border),
                ),
                onPressed: () => onColumns!(a),
                icon: const Icon(Icons.view_column_rounded, size: 18),
                label: Text(_t('si2Columns', {'n': '${a.mapping.length}'}),
                    style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({super.key, required this.role, this.onTap});
  final TableRole role;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final c = importRoleColor(role);
    return Material(
      color: c.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(_t('si2Role_${role.name}'),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: _font, fontSize: 12.5, fontWeight: FontWeight.w800, color: c)),
            ),
            Icon(Icons.expand_more_rounded, size: 18, color: c),
          ]),
        ),
      ),
    );
  }
}

class _Grip extends StatelessWidget {
  const _Grip();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Container(width: 42, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
      );
}

class _SheetTitle extends StatelessWidget {
  const _SheetTitle({required this.icon, required this.title, this.hint});
  final IconData icon;
  final String title;
  final String? hint;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: AppColors.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: const TextStyle(fontFamily: _font, fontSize: 16, fontWeight: FontWeight.w800))),
          ]),
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(hint!, style: TextStyle(fontFamily: _font, fontSize: 12.5, color: AppColors.textSecondary, height: 1.5)),
          ],
        ]),
      );
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border(top: BorderSide(color: AppColors.border)),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .04), blurRadius: 10, offset: const Offset(0, -3))],
          ),
          child: child,
        ),
      );
}

/// Every place in FYONA a table can go, grouped, each with what it means.
class _RolePicker extends StatelessWidget {
  const _RolePicker({required this.table, required this.current});
  final String table;
  final TableRole current;
  @override
  Widget build(BuildContext context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .85),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const _Grip(),
            _SheetTitle(icon: Icons.alt_route_rounded, title: _t('si2WhereTitle'), hint: table.split(' · ').last),
            Flexible(
              child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(12, 0, 12, 16), children: [
                for (final g in importRoleGroups.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 10, 6, 6),
                    child: Text(_t('si2Group_${g.key}'),
                        style: TextStyle(fontFamily: _font, fontSize: 12.5, fontWeight: FontWeight.w800, color: AppColors.textSecondary)),
                  ),
                  for (final r in g.value)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Material(
                        color: r == current ? importRoleColor(r).withValues(alpha: .10) : AppColors.surface,
                        borderRadius: BorderRadius.circular(14),
                        child: InkWell(
                          key: Key('si-role-${r.name}'),
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => Navigator.pop(context, r),
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Row(children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(color: importRoleColor(r).withValues(alpha: .12), borderRadius: BorderRadius.circular(10)),
                                child: Icon(importRoleIcon(r), size: 19, color: importRoleColor(r)),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(_t('si2Role_${r.name}'), style: const TextStyle(fontFamily: _font, fontSize: 14, fontWeight: FontWeight.w800)),
                                  Text(_t('si2RoleHint_${r.name}'),
                                      style: TextStyle(fontFamily: _font, fontSize: 11.5, color: AppColors.textSecondary)),
                                ]),
                              ),
                              if (r == current) Icon(Icons.check_circle_rounded, color: importRoleColor(r)),
                            ]),
                          ),
                        ),
                      ),
                    ),
                ],
              ]),
            ),
          ]),
        ),
      );
}

const importCurrencies = ['SAR', 'YER', 'USD', 'AED', 'KWD', 'QAR', 'OMR', 'BHD', 'EGP', 'JOD', 'IQD', 'EUR', 'TRY', 'GBP'];

class _CurrencyPicker extends StatelessWidget {
  const _CurrencyPicker({required this.current});
  final String current;
  @override
  Widget build(BuildContext context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const _Grip(),
          _SheetTitle(icon: Icons.payments_rounded, title: _t('si2CurrencyTitle'), hint: _t('si2CurrencyHint')),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
            child: GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.7,
              children: [
                for (final c in importCurrencies)
                  Material(
                    color: c == current ? AppColors.primary : AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      key: Key('si-cur-$c'),
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => Navigator.pop(context, c),
                      child: Container(
                        decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: c == current ? AppColors.primary : AppColors.border)),
                        alignment: Alignment.center,
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Text(c,
                              style: TextStyle(
                                  fontFamily: _font, fontSize: 15, fontWeight: FontWeight.w800, color: c == current ? Colors.white : null)),
                          Text(_t('cur_$c'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontFamily: _font, fontSize: 11, color: c == current ? Colors.white70 : AppColors.textSecondary)),
                        ]),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ]),
      );
}

/// Which column is which field, for one table: drag a column onto a field
/// (a busy field swaps), or pick from the list. Returns the new mapping.
class ColumnMappingSheet extends StatefulWidget {
  const ColumnMappingSheet({super.key, required this.analysis});
  final TableAnalysis analysis;
  @override
  State<ColumnMappingSheet> createState() => _ColumnMappingSheetState();
}

class _ColumnMappingSheetState extends State<ColumnMappingSheet> {
  late final Map<String, String> _m = Map.of(widget.analysis.mapping);
  List<List<String?>> _sample = const [];

  TableAnalysis get a => widget.analysis;
  List<ImportField> get _fields =>
      a.role.target != null ? importFields[a.role.target]! : partFields[a.role] ?? const <ImportField>[];

  @override
  void initState() {
    super.initState();
    a.table.sample(5).then((s) {
      if (mounted) setState(() => _sample = s);
    });
  }

  void _assign(String field, String? column) => setState(() {
        final old = _m[field];
        String? from;
        if (column != null) {
          for (final e in _m.entries) {
            if (e.value == column) from = e.key;
          }
        }
        if (column == null) {
          _m.remove(field);
        } else {
          _m[field] = column;
          if (from != null && from != field) {
            if (old != null) {
              _m[from] = old;
            } else {
              _m.remove(from);
            }
          }
        }
      });

  String _sampleOf(String c) {
    final i = a.table.columns.indexOf(c);
    for (final r in _sample) {
      final v = i < r.length ? r[i] : null;
      if (v != null && v.trim().isNotEmpty) return v.length > 22 ? '${v.substring(0, 22)}…' : v;
    }
    return '';
  }

  Widget _chip(String c, {bool onField = false}) {
    final body = Material(
      color: onField ? AppColors.primary.withValues(alpha: 0.10) : AppColors.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12), side: BorderSide(color: onField ? AppColors.primary : AppColors.border)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c, style: const TextStyle(fontFamily: _font, fontSize: 12.5, fontWeight: FontWeight.w800)),
          if (_sampleOf(c).isNotEmpty)
            Text(_sampleOf(c), style: TextStyle(fontFamily: _font, fontSize: 10.5, color: AppColors.textSecondary)),
        ]),
      ),
    );
    return Draggable<String>(
      key: Key('si-col-$c'),
      data: c,
      feedback: Material(color: Colors.transparent, child: body),
      childWhenDragging: Opacity(opacity: 0.35, child: body),
      child: body,
    );
  }

  @override
  Widget build(BuildContext context) {
    final used = _m.values.toSet();
    final unused = [for (final c in a.table.columns) if (!used.contains(c)) c];
    return SafeArea(
      child: Column(children: [
        const _Grip(),
        _SheetTitle(icon: Icons.view_column_rounded, title: _t('siColumns'), hint: _t('siDragHint')),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 14), children: [
            for (final f in _fields)
              DragTarget<String>(
                onAcceptWithDetails: (d) => _assign(f.key, d.data),
                builder: (context, hovering, _) => AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  key: Key('si-field-${f.key}'),
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: hovering.isNotEmpty ? AppColors.primary.withValues(alpha: 0.10) : AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: hovering.isNotEmpty ? AppColors.primary : AppColors.border),
                  ),
                  child: Row(children: [
                    SizedBox(
                      width: 112,
                      child: Text('${_t('siField_${f.key}')}${f.required ? ' *' : ''}',
                          style: const TextStyle(fontFamily: _font, fontSize: 13, fontWeight: FontWeight.w800)),
                    ),
                    Expanded(
                      child: _m[f.key] == null
                          ? Text(_t('siDropHere'), style: TextStyle(fontFamily: _font, fontSize: 12, color: AppColors.textSecondary))
                          : Align(alignment: AlignmentDirectional.centerStart, child: _chip(_m[f.key]!, onField: true)),
                    ),
                    PopupMenuButton<String>(
                      key: Key('si-pickcol-${f.key}'),
                      tooltip: _t('siChooseColumn'),
                      icon: const Icon(Icons.swap_horiz_rounded),
                      onSelected: (v) => _assign(f.key, v == '' ? null : v),
                      itemBuilder: (_) => [
                        PopupMenuItem(value: '', child: Text(_t('siNone'))),
                        for (final c in a.table.columns) PopupMenuItem(value: c, child: Text(c)),
                      ],
                    ),
                  ]),
                ),
              ),
            const SizedBox(height: 8),
            Text(_t('siUnusedColumns'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            if (unused.isEmpty)
              Text('—', style: TextStyle(color: AppColors.textSecondary))
            else ...[
              Text(_t('siUnusedHint'), style: const TextStyle(fontFamily: _font, fontSize: 12, color: _yellow, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              DragTarget<String>(
                onAcceptWithDetails: (d) {
                  final f = _m.entries.where((e) => e.value == d.data).map((e) => e.key).firstOrNull;
                  if (f != null) _assign(f, null);
                },
                builder: (context, _, _) => Wrap(spacing: 6, runSpacing: 6, children: [for (final c in unused) _chip(c)]),
              ),
            ],
          ]),
        ),
        _BottomBar(
          child: SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton(
              key: const Key('si-columns-done'),
              onPressed: () => Navigator.pop(context, _m),
              child: Text(_t('si2Done'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Sara inside the import window: the user asks in their own words
/// ("prices in dollars", "add 10% to the sale prices", "this table is my
/// customers"); Sara answers with operations the app applies by its rules.
class _SaraChat extends StatefulWidget {
  const _SaraChat({required this.history, required this.onSend, required this.onArrange});
  final List<({bool me, String text, List<String> done})> history;
  final Future<void> Function(String text) onSend;
  final Future<void> Function() onArrange;
  @override
  State<_SaraChat> createState() => _SaraChatState();
}

class _SaraChatState extends State<_SaraChat> {
  final _c = TextEditingController();
  final _scroll = ScrollController();
  bool _thinking = false;

  @override
  void dispose() {
    _c.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_thinking) return;
    setState(() => _thinking = true);
    try {
      await work();
    } finally {
      if (mounted) setState(() => _thinking = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      });
    }
  }

  Future<void> _send([String? text]) async {
    final msg = (text ?? _c.text).trim();
    if (msg.isEmpty) return;
    _c.clear();
    await _run(() => widget.onSend(msg));
  }

  String _doneLabel(String d) {
    final p = d.split(':');
    return switch (p.first) {
      'role' => _t('si2DidRole', {'t': p.length > 1 ? p[1] : '', 'r': p.length > 2 ? _t('si2Role_${p[2]}') : ''}),
      'map' => _t('si2DidMap', {'t': p.length > 1 ? p[1] : '', 'f': p.length > 2 ? _t('siField_${p[2]}') : ''}),
      'currency' => _t('si2DidCurrency', {'c': p.length > 1 ? p[1] : ''}),
      'set' || 'adjust' => _t('si2DidRows', {'n': p.length > 2 ? p[2] : '0'}),
      'reject' => _t('si2DidReject', {'n': p.length > 1 ? p[1] : '0'}),
      'accept' => _t('si2DidAccept', {'n': p.length > 1 ? p[1] : '0'}),
      _ => d,
    };
  }

  @override
  Widget build(BuildContext context) {
    final msgs = widget.history;
    return Container(
      decoration: BoxDecoration(color: AppColors.background, borderRadius: const BorderRadius.vertical(top: Radius.circular(26))),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [_sara1, _sara2]),
            borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
          ),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: .18), shape: BoxShape.circle),
              child: const Icon(Icons.auto_awesome_rounded, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_t('si2SaraTitle'), style: const TextStyle(fontFamily: _font, fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white)),
                Text(_t('si2SaraSub'), style: TextStyle(fontFamily: _font, fontSize: 11.5, color: Colors.white.withValues(alpha: .85))),
              ]),
            ),
            IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded, color: Colors.white)),
          ]),
        ),
        Expanded(
          child: ListView(controller: _scroll, padding: const EdgeInsets.all(14), children: [
            _Bubble(me: false, text: _t('si2SaraHello')),
            for (final m in msgs) ...[
              _Bubble(me: m.me, text: m.text),
              if (m.done.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final d in m.done)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(color: _green.withValues(alpha: .10), borderRadius: BorderRadius.circular(12)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.check_rounded, size: 14, color: _green),
                          const SizedBox(width: 4),
                          Text(_doneLabel(d), style: const TextStyle(fontFamily: _font, fontSize: 11.5, color: _green, fontWeight: FontWeight.w700)),
                        ]),
                      ),
                  ]),
                ),
            ],
            if (_thinking) const _Typing(),
          ]),
        ),
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            ActionChip(
              key: const Key('si-sara-arrange'),
              avatar: const Icon(Icons.auto_fix_high_rounded, size: 16, color: _sara1),
              label: Text(_t('si2Suggest0'), style: const TextStyle(fontFamily: _font, fontSize: 12)),
              onPressed: _thinking ? null : () => _run(widget.onArrange),
            ),
            for (final k in ['si2Suggest1', 'si2Suggest2', 'si2Suggest3'])
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 6),
                child: ActionChip(
                  label: Text(_t(k), style: const TextStyle(fontFamily: _font, fontSize: 12)),
                  onPressed: _thinking ? null : () => _send(_t(k)),
                ),
              ),
          ]),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, 6, 12, 10 + MediaQuery.of(context).viewInsets.bottom),
            child: Row(children: [
              Expanded(
                child: TextField(
                  key: const Key('si-sara-input'),
                  controller: _c,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: _t('si2SaraHint'),
                    filled: true,
                    fillColor: AppColors.surface,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide(color: AppColors.border)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                decoration: const BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [_sara1, _sara2])),
                child: IconButton(
                  key: const Key('si-sara-send'),
                  onPressed: _thinking ? null : _send,
                  icon: const Icon(Icons.send_rounded, color: Colors.white),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.me, required this.text});
  final bool me;
  final String text;
  @override
  Widget build(BuildContext context) => Align(
        alignment: me ? AlignmentDirectional.centerStart : AlignmentDirectional.centerEnd,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .78),
          decoration: BoxDecoration(
            gradient: me ? null : const LinearGradient(colors: [Color(0xFFF3EAFE), Color(0xFFFDE8EF)]),
            color: me ? AppColors.primary : null,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(text, style: TextStyle(fontFamily: _font, fontSize: 13.5, height: 1.5, color: me ? Colors.white : const Color(0xFF2B1B3D))),
        ),
      );
}

class _Typing extends StatefulWidget {
  const _Typing();
  @override
  State<_Typing> createState() => _TypingState();
}

class _TypingState extends State<_Typing> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Align(
        alignment: AlignmentDirectional.centerEnd,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) => Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < 3; i++)
              Container(
                margin: const EdgeInsets.all(3),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _sara1.withValues(alpha: .3 + .7 * ((math.sin((_c.value * 2 * math.pi) - i) + 1) / 2)),
                ),
              ),
          ]),
        ),
      );
}

/// The two-part review of one table: what will be added (editable) and
/// what will not (red, with the reason in yellow). Rows are built lazily,
/// so thousands stay smooth.
class ImportReviewView extends StatefulWidget {
  const ImportReviewView({
    super.key,
    required this.review,
    required this.onChanged,
    this.images,
    this.skipped = const [],
  });
  final ImportReview review;
  final ImportImages? images;
  final List<String> skipped;
  final VoidCallback onChanged;
  @override
  State<ImportReviewView> createState() => _ImportReviewViewState();
}

class _ImportReviewViewState extends State<ImportReviewView> {
  bool _refused = false;
  String _query = '';
  String? _reason;
  final _selected = <int>{};
  late List<ReviewRow> _shown;
  final _h = ScrollController();

  ImportReview get r => widget.review;

  List<String> get _fields => [
        for (final f in importFields[r.target]!)
          if (r.mapping.containsKey(f.key) ||
              (f.key == 'image' && r.rows.any((x) => x['image'] != null)) ||
              (const {'sale_price', 'cost_price', 'stock', 'unit', 'balance', 'currency'}.contains(f.key) &&
                  r.rows.take(200).any((x) => x[f.key] != null)))
            f.key,
        if (r.rows.any((x) => x.units.isNotEmpty)) '_units',
        if (r.rows.any((x) => x.barcodes.isNotEmpty)) '_codes',
      ];

  @override
  void initState() {
    super.initState();
    _filter();
  }

  @override
  void dispose() {
    _h.dispose();
    super.dispose();
  }

  void _filter() {
    final q = importFold(_query);
    _shown = [
      for (final row in r.rows)
        if (row.accepted != _refused &&
            (_reason == null || (row.reasons.isNotEmpty ? row.reasons.first : 'rejected_by_user') == _reason) &&
            (q.isEmpty || row.values.values.any((v) => v != null && importFold(v).contains(q))))
          row,
    ];
  }

  void _changed() {
    setState(_filter);
    widget.onChanged();
  }

  Future<void> _editCell(ReviewRow row, String field) async {
    final ctrl = TextEditingController(text: row[field] ?? '');
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('${_t('siField_$field')} — ${_t('siRowN', {'n': '${row.row}'})}',
            style: const TextStyle(fontFamily: _font, fontSize: 15, fontWeight: FontWeight.w800)),
        content: TextField(key: const Key('si-edit-field'), controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_t('cancel'))),
          FilledButton(key: const Key('si-edit-save'), onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(_t('save'))),
        ],
      ),
    );
    if (v == null) return;
    r.edit(row, field, v);
    _changed();
  }

  double _width(String f) => switch (f) {
        '_units' || '_codes' => 90,
        'name' => 200,
        'image' => 70,
        'phone' || 'barcode' || 'sku' || 'category' || 'description' || 'notes' => 130,
        _ => 100,
      };

  @override
  Widget build(BuildContext context) {
    final fields = _fields;
    const check = 44.0, rowNo = 56.0, reasonW = 230.0;
    final width = check + rowNo + fields.fold<double>(0, (a, f) => a + _width(f)) + reasonW + 3;
    final reasons = r.refusedByReason;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 2, 10, 0),
        child: Row(children: [
          Expanded(
            child: _tab(key: 'si-tab-add', label: _t('siTabAdd', {'n': '${r.acceptedCount}'}), color: _green, on: !_refused,
                icon: Icons.check_circle_rounded, () {
              _refused = false;
              _reason = null;
              _selected.clear();
              setState(_filter);
            }),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _tab(key: 'si-tab-refused', label: _t('siTabRefused', {'n': '${r.refusedCount}'}), color: _red, on: _refused,
                icon: Icons.block_rounded, () {
              _refused = true;
              _selected.clear();
              setState(_filter);
            }),
          ),
        ]),
      ),
      if (_refused) ...[
        if (widget.skipped.isNotEmpty || r.unusedColumns.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
            child: _yellowNote([
              for (final t in widget.skipped) t,
              if (r.unusedColumns.isNotEmpty) _t('siSkippedColumns', {'c': r.unusedColumns.join('، ')}),
            ].join('\n')),
          ),
        if (reasons.isNotEmpty)
          SizedBox(
            height: 46,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
              for (final e in reasons.entries)
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: FilterChip(
                    key: Key('si-reason-${e.key}'),
                    avatar: const Icon(Icons.warning_amber_rounded, color: _yellow, size: 16),
                    label: Text('${_t('siIssue_${e.key}')} (${e.value})', style: const TextStyle(fontFamily: _font, fontSize: 12)),
                    selected: _reason == e.key,
                    onSelected: (v) => setState(() {
                      _reason = v ? e.key : null;
                      _filter();
                    }),
                  ),
                ),
            ]),
          ),
      ],
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
        child: Row(children: [
          Expanded(
            child: TextField(
              key: const Key('si-search'),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: AppColors.surface,
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                hintText: _t('siSearch'),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: AppColors.border)),
              ),
              onChanged: (v) => setState(() {
                _query = v;
                _filter();
              }),
            ),
          ),
          const SizedBox(width: 6),
          TextButton(
            key: const Key('si-select-all'),
            onPressed: () => setState(() {
              if (_selected.length == _shown.length) {
                _selected.clear();
              } else {
                _selected
                  ..clear()
                  ..addAll(_shown.map((e) => e.row));
              }
            }),
            child: Text(_t('siSelectAll'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700)),
          ),
        ]),
      ),
      if (_selected.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              key: const Key('si-bulk'),
              onPressed: () {
                final rows = r.rows.where((e) => _selected.contains(e.row));
                r.setRejected(rows, !_refused);
                _selected.clear();
                _changed();
              },
              icon: Icon(_refused ? Icons.undo_rounded : Icons.remove_circle_outline_rounded),
              label: Text(_refused ? _t('siApproveSel', {'n': '${_selected.length}'}) : _t('siRejectSel', {'n': '${_selected.length}'}),
                  style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      Text(_t('siShowing', {'n': '${_shown.length}'}), style: TextStyle(fontFamily: _font, fontSize: 11.5, color: AppColors.textSecondary)),
      Expanded(
        child: Scrollbar(
          controller: _h,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _h,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: Column(children: [
                Container(
                  height: 40,
                  color: AppColors.surface,
                  child: Row(children: [
                    const SizedBox(width: check),
                    _head('#', rowNo),
                    for (final f in fields) _head(_t('siField_$f'), _width(f)),
                    _head(_refused ? _t('siWhyNot') : _t('siNotes'), reasonW),
                  ]),
                ),
                Expanded(
                  child: ListView.builder(
                    key: const Key('si-rows'),
                    itemExtent: 46,
                    itemCount: _shown.length,
                    itemBuilder: (context, i) => _row(_shown[i], fields, check, rowNo, reasonW),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _tab(VoidCallback onTap, {required String key, required String label, required Color color, required bool on, required IconData icon}) =>
      InkWell(
        key: Key(key),
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.symmetric(vertical: 11),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? color : AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: on ? color : AppColors.border),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 18, color: on ? Colors.white : color),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontFamily: _font, fontWeight: FontWeight.w800, color: on ? Colors.white : color)),
          ]),
        ),
      );

  Widget _yellowNote(String text) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: _red.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _red.withValues(alpha: 0.35)),
        ),
        child: Text(text, style: const TextStyle(fontFamily: _font, fontSize: 12, color: _yellow, fontWeight: FontWeight.w700, height: 1.5)),
      );

  Widget _head(String text, double w) => SizedBox(
        width: w,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(text,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: _font, fontSize: 12, fontWeight: FontWeight.w800)),
        ),
      );

  Widget _row(ReviewRow row, List<String> fields, double check, double rowNo, double reasonW) {
    final refused = !row.accepted;
    final note = refused
        ? [for (final x in row.reasons.isEmpty ? ['rejected_by_user'] : row.reasons) _t('siIssue_$x')].join(' · ')
        : [for (final w in row.warnings) _t('siIssue_$w')].join(' · ');
    return Container(
      key: Key('si-row-${row.row}'),
      decoration: BoxDecoration(
        color: refused ? _red.withValues(alpha: 0.07) : null,
        border: Border(
          bottom: BorderSide(color: AppColors.border.withValues(alpha: 0.6)),
          left: BorderSide(color: refused ? _red : Colors.transparent, width: 3),
        ),
      ),
      child: Row(children: [
        SizedBox(
          width: check,
          child: Checkbox(
            value: _selected.contains(row.row),
            onChanged: (v) => setState(() => v == true ? _selected.add(row.row) : _selected.remove(row.row)),
          ),
        ),
        SizedBox(width: rowNo, child: Text('${row.row}', style: TextStyle(fontSize: 11.5, color: AppColors.textSecondary))),
        for (final f in fields)
          SizedBox(
            width: _width(f),
            child: InkWell(
              key: Key('si-cell-${row.row}-$f'),
              onTap: f.startsWith('_') ? () => _showParts(row) : () => _editCell(row, f),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: f == 'image'
                    ? _picture(row[f])
                    : f.startsWith('_')
                        ? Text('${f == '_units' ? row.units.length : row.barcodes.length}',
                            style: const TextStyle(fontFamily: _font, fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.primary))
                        : Text(row[f] ?? '—',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontFamily: _font, fontSize: 12.5, color: row[f] == null ? AppColors.textSecondary : null)),
              ),
            ),
          ),
        SizedBox(
          width: reasonW,
          child: Row(children: [
            if (note.isNotEmpty) Icon(refused ? Icons.block_rounded : Icons.info_outline_rounded, size: 15, color: refused ? _red : _yellow),
            const SizedBox(width: 4),
            Expanded(
              child: Text(note,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: _font,
                      fontSize: 11.5,
                      color: refused ? _yellow : AppColors.textSecondary,
                      fontWeight: refused ? FontWeight.w800 : FontWeight.w500)),
            ),
          ]),
        ),
      ]),
    );
  }

  Future<void> _showParts(ReviewRow row) => showModalBottomSheet<void>(
        context: context,
        backgroundColor: AppColors.background,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (_) => SafeArea(
          child: ListView(padding: const EdgeInsets.all(16), shrinkWrap: true, children: [
            Text(row['name'] ?? '', style: const TextStyle(fontFamily: _font, fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            for (final u in row.units)
              ListTile(
                dense: true,
                leading: const Icon(Icons.straighten_rounded),
                title: Text('${u['name'] ?? '—'} × ${u['factor'] ?? '1'}', style: const TextStyle(fontFamily: _font)),
                subtitle: Text([u['barcode'], u['sale_price'], u['cost_price']].whereType<String>().join(' · ')),
              ),
            for (final b in row.barcodes)
              ListTile(
                dense: true,
                leading: const Icon(Icons.qr_code_2_rounded),
                title: Text(b),
                trailing: row.droppedCodes.contains(b) ? const Icon(Icons.block_rounded, color: _yellow, size: 18) : null,
              ),
            for (final p in row.prices)
              ListTile(
                dense: true,
                leading: const Icon(Icons.sell_rounded),
                title: Text('${p['price'] ?? '—'} ${p['currency']}', style: const TextStyle(fontFamily: _font)),
              ),
          ]),
        ),
      );

  final _thumbs = <String, Uint8List?>{};
  final _loading = <String>{};
  Widget _picture(String? name) {
    if (name == null) return const Text('—');
    if (ImportImages.isBlob(name) && !_thumbs.containsKey(name)) {
      if (_loading.add(name)) {
        widget.images?.load(name).then((p) {
          if (mounted) setState(() => _thumbs[name] = p?.$1);
        });
      }
      return const SizedBox(width: 36, height: 36, child: Icon(Icons.image_outlined, size: 18));
    }
    final b = _thumbs.putIfAbsent(name, () => widget.images?.read(name)?.$1);
    if (b == null) return const Icon(Icons.image_not_supported_outlined, size: 18, color: _yellow);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.memory(b, width: 36, height: 36, cacheWidth: 72, fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined, size: 18)),
    );
  }
}
