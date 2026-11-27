import 'dart:convert';
import 'dart:io';
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
import '../../di/providers.dart';
import '../../localization/app_localizations.dart';
import '../../backup/presentation/operation_motion.dart';
import '../../media/media_store.dart';
import '../../theme/app_colors.dart';
import '../business_import.dart';
import '../import_plan.dart';
import '../import_schema.dart';
import '../import_source.dart';
import '../sara_mapping.dart';

String _t(String key, [Map<String, dynamic>? p]) => AppLocalizations.t(key, p);
const _font = 'Cairo';
const _red = Color(0xFFD32F2F);
const _yellow = Color(0xFFF9A825);
const _green = Color(0xFF2E7D32);

/// Final confirmation before an import or an undo (fingerprint or the
/// app's PIN). Replaceable in tests.
typedef ImportConfirm = Future<bool> Function(BuildContext context, WidgetRef ref, String reason);
final smartImportConfirmProvider = Provider<ImportConfirm>(
  (ref) => (context, widgetRef, reason) =>
      verifySensitiveAction(context, widgetRef, reason: reason, existingCredentialsOnly: true),
);

/// Where one table of the file goes.
enum ImportDestination { customers, suppliers, products, accounts, none }

ImportTarget? _targetOf(ImportDestination d) => switch (d) {
      ImportDestination.customers || ImportDestination.suppliers => ImportTarget.parties,
      ImportDestination.products => ImportTarget.products,
      ImportDestination.accounts => ImportTarget.accounts,
      ImportDestination.none => null,
    };

/// Best destination from the column titles (the user can change it).
ImportDestination suggestDestination(ImportTable t) {
  final p = autoMapColumns(ImportTarget.parties, t.columns), q = autoMapColumns(ImportTarget.products, t.columns);
  if (!p.containsKey('name') && !q.containsKey('name')) return ImportDestination.none;
  final productHints = ['barcode', 'sale_price', 'cost_price', 'stock', 'unit', 'sku'].where(q.containsKey).length;
  final partyHints = ['phone', 'balance', 'debit', 'credit', 'kind'].where(p.containsKey).length;
  if (productHints > partyHints) return ImportDestination.products;
  final kind = t.columns.map(importFold).join(' ');
  return kind.contains('مورد') || kind.contains('supplier') || kind.contains('vendor') || t.name.contains('مورد')
      ? ImportDestination.suppliers
      : ImportDestination.customers;
}

/// Entry card on the Business backup screen (owner of a device ledger).
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
        leading: const Icon(Icons.upload_file_outlined, color: AppColors.primary),
        title: Text(_t('siTitle'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
        subtitle: Text(_t('siEntrySubtitle'), style: const TextStyle(fontFamily: _font, fontSize: 12)),
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

ImportDestination destinationOf(TableRole r) => switch (r) {
      TableRole.customers => ImportDestination.customers,
      TableRole.suppliers => ImportDestination.suppliers,
      TableRole.products => ImportDestination.products,
      TableRole.accounts => ImportDestination.accounts,
      _ => ImportDestination.none,
    };

class _TableState {
  _TableState(this.analysis)
      : destination = destinationOf(analysis.role),
        mapping = Map.of(analysis.mapping);
  final TableAnalysis analysis;
  ImportTable get table => analysis.table;
  ImportDestination destination;
  Map<String, String> mapping;
  List<List<String?>> sample = const [];
  ImportReview? review;

  /// Joined into the products (units, barcodes, pictures, categories).
  bool get partOfProducts => analysis.role.productPart && analysis.link != null;
}

class SmartImportPage extends ConsumerStatefulWidget {
  const SmartImportPage({super.key, this.initialFile});

  /// Tests: start with this file (no picker).
  final File? initialFile;
  @override
  ConsumerState<SmartImportPage> createState() => _SmartImportPageState();
}

class _SmartImportPageState extends ConsumerState<SmartImportPage> {
  int _step = 0; // 0 file · 1 columns · 2 review
  final _currency = TextEditingController(text: 'SAR');
  File? _file;
  String? _sha;
  ImportImages _images = ImportImages.none;
  List<_TableState> _tables = const [];
  int _current = 0;
  bool _busy = false;
  String? _progress;
  double? _fraction;
  List<Map<String, Object?>> _batches = const [];
  ImportRegistry? _registry;

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
    _currency.dispose();
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
    final images = _images;
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
          _fraction = null;
        });
      }
    }
  }

  // ── step 0: the file ────────────────────────────────────────────────

  Future<void> _pick() async {
    final picked = await FilePicker.pickFiles(type: FileType.any, withData: false);
    final path = picked?.files.single.path;
    if (path != null) await _open(File(path));
  }

  Future<void> _open(File f) => _guard(() async {
        final tables = await readImportFile(f);
        final sha = '${await sha256.bind(f.openRead()).first}';
        final images = await readImportImages(f);
        setState(() => _progress = _t('siAnalyzing'));
        final analysis = await analyzeImportSchema(tables);
        final states = [for (final a in analysis) _TableState(a)];
        for (final s in states) {
          s.sample = await s.table.sample(5);
        }
        setState(() {
          _file = f;
          _sha = sha;
          _images = images;
          _tables = states;
          _current = 0;
          _step = 1;
        });
      });

  // ── step 1: tables and columns ──────────────────────────────────────

  void _setDestination(_TableState s, ImportDestination d) => setState(() {
        final before = _targetOf(s.destination), after = _targetOf(d);
        s.destination = d;
        if (after == null) {
          s.mapping = {};
        } else if (after != before) {
          s.mapping = autoMapColumns(after, s.table.columns);
        }
        s.review = null;
      });

  /// Puts [column] on [field]; the field's previous column goes where
  /// [column] was (a swap), or back to the unused list.
  void _assign(_TableState s, String field, String? column) => setState(() {
        final old = s.mapping[field];
        String? from;
        if (column != null) {
          for (final e in s.mapping.entries) {
            if (e.value == column) from = e.key;
          }
        }
        if (column == null) {
          s.mapping.remove(field);
        } else {
          s.mapping[field] = column;
          if (from != null && from != field) {
            if (old != null) {
              s.mapping[from] = old;
            } else {
              s.mapping.remove(from);
            }
          }
        }
        s.review = null;
      });

  Future<void> _askSara(_TableState s) => _guard(() async {
        final target = _targetOf(s.destination);
        if (target == null) return;
        final m = await saraImportMapping(ref.read(apiClientProvider), target, s.table);
        if (m == null || m.isEmpty) {
          _snack(_t('siSaraFailed'));
          return;
        }
        setState(() {
          s.mapping = m;
          s.review = null;
        });
        _snack(_t('siSaraDone'));
      });

  Future<void> _askSaraSchema() => _guard(() async {
        final all = [for (final t in _tables) t.analysis];
        final answers = await saraImportSchema(ref.read(apiClientProvider), all.where((a) => a.role == TableRole.unknown).toList());
        if (answers == null) {
          _snack(_t('siSaraFailed'));
          return;
        }
        final n = await applySaraSchema(all, answers);
        setState(() {
          for (final t in _tables) {
            t.destination = destinationOf(t.analysis.role);
            t.mapping = Map.of(t.analysis.mapping);
            t.review = null;
          }
        });
        _snack(n > 0 ? _t('siSaraDone') : _t('siSaraFailed'));
      });

  Future<void> _toReview() => _guard(() async {
        final reg = await _reg();
        final existing = await _importer(reg).existingNames();
        final branches = {
          _scope!.branchId,
          if (BranchScope.branchName != null) BranchScope.branchName!,
        };
        final active = _tables.where((s) => _targetOf(s.destination) != null).toList();
        for (var i = 0; i < active.length; i++) {
          final s = active[i];
          if (s.review != null) continue;
          setState(() => _progress = '${s.table.name} (${i + 1}/${active.length})');
          final parts = s.destination == ImportDestination.products
              ? await joinProductParts([for (final t in _tables) if (t.partOfProducts || t.analysis.role == TableRole.categories) t.analysis], s.table)
              : null;
          s.review = await ImportReview.load(s.table, _targetOf(s.destination)!, s.mapping,
              defaultKind: s.destination == ImportDestination.suppliers ? 'supplier' : 'customer',
              defaultCurrency: _currency.text.trim().toUpperCase(),
              existing: existing,
              branches: branches,
              images: _images.names,
              blobImages: _images.has('fyblob:'),
              parts: parts, onRows: (n) {
            if (mounted) setState(() => _progress = _t('siRows', {'n': '$n'}));
          });
        }
        setState(() {
          _current = _tables.indexWhere((s) => s.review != null);
          if (_current < 0) _current = 0;
          _step = 2;
        });
      });

  // ── step 2: review → confirm → import ───────────────────────────────

  Future<void> _apply() async {
    final ready = _tables.where((s) => s.review != null && s.review!.acceptedCount > 0).toList();
    final total = ready.fold<int>(0, (a, s) => a + s.review!.acceptedCount);
    if (total == 0 || _file == null || _sha == null) return;
    if (!await ref.read(smartImportConfirmProvider)(context, ref, _t('siConfirmReason', {'n': '$total'}))) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final ids = await OperationMotion.run<List<String>>(context,
          kind: MotionKind.smartImport,
          doneText: _t('siDoneShort', {'n': '$total'}),
          failureText: _failure, work: (m) async {
        final reg = await _reg();
        final imp = _importer(reg);
        var base = 0;
        final ids = <String>[];
        for (final s in ready) {
          final p = s.review!.toPreview();
          m.stage(_t('siImportingTable', {'t': _t('siDest_${s.destination.name}')}), base / total);
          final key = '$_sha|${s.table.name}|${s.destination.name}';
          ids.add(await imp.apply(p, fileSha: '${sha256.convert(utf8.encode(key))}', fileName: _file!.uri.pathSegments.last,
              onProgress: (d, n) => m.progress((base + d) / total)));
          base += p.ready;
        }
        return ids;
      });
      _snack(_t('siDone', {'id': ids.map((i) => i.substring(0, 8)).join(', ')}));
      setState(() {
        _step = 0;
        _tables = const [];
        _file = null;
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
      appBar: AppBar(
        title: Text(_t('siTitle'), style: const TextStyle(fontFamily: _font)),
        leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.of(context).maybePop()),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: _Steps(step: _step, onTap: _busy ? null : (i) => setState(() => _step = i > _step ? _step : i)),
        ),
      ),
      body: _scope == null
          ? const SizedBox.shrink()
          : Column(children: [
              if (_busy) ...[
                LinearProgressIndicator(value: _fraction),
                if (_progress != null)
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(_progress!, style: const TextStyle(fontFamily: _font, fontSize: 12)),
                  ),
              ],
              Expanded(child: switch (_step) { 0 => _fileStep(), 1 => _columnsStep(), _ => _reviewStep() }),
            ]),
    );
  }

  Widget _fileStep() => ListView(padding: const EdgeInsets.all(16), children: [
        Text(_t('siIntro'), style: TextStyle(fontFamily: _font, fontSize: 13, color: AppColors.textSecondary)),
        const SizedBox(height: 12),
        TextField(controller: _currency, decoration: InputDecoration(labelText: _t('siCurrency'))),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const Key('si-pick'),
          onPressed: _busy ? null : _pick,
          icon: const Icon(Icons.folder_open_outlined),
          label: Text(_t('siPick'), style: const TextStyle(fontFamily: _font)),
        ),
        if (_batches.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text(_t('siBatches'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
          for (final b in _batches)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${b['file_name']}', style: const TextStyle(fontFamily: _font)),
              subtitle: Text('${_t('siStatus_${b['status']}')} · ${b['rows_done']}/${b['rows_ready']} · ${'${b['id']}'.substring(0, 8)}',
                  style: const TextStyle(fontFamily: _font, fontSize: 12)),
              trailing: b['status'] == 'undone'
                  ? null
                  : TextButton(
                      onPressed: _busy ? null : () => _undo('${b['id']}'),
                      child: Text(_t('siUndo'), style: const TextStyle(fontFamily: _font)),
                    ),
            ),
        ],
      ]);

  Widget _columnsStep() {
    if (_tables.isEmpty) return const SizedBox.shrink();
    final s = _tables[_current];
    final target = _targetOf(s.destination);
    final used = s.mapping.values.toSet();
    final unused = [for (final c in s.table.columns) if (!used.contains(c)) c];
    String sampleOf(String c) {
      final i = s.table.columns.indexOf(c);
      for (final r in s.sample) {
        final v = i < r.length ? r[i] : null;
        if (v != null && v.trim().isNotEmpty) return v.length > 24 ? '${v.substring(0, 24)}…' : v;
      }
      return '';
    }

    Widget chip(String c, {bool onField = false}) {
      final body = Material(
        color: onField ? AppColors.primary.withValues(alpha: 0.12) : AppColors.surface,
        shape: StadiumBorder(side: BorderSide(color: onField ? AppColors.primary : AppColors.border)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(c, style: const TextStyle(fontFamily: _font, fontSize: 12.5, fontWeight: FontWeight.w700)),
            if (sampleOf(c).isNotEmpty)
              Text(sampleOf(c), style: TextStyle(fontFamily: _font, fontSize: 10.5, color: AppColors.textSecondary)),
          ]),
        ),
      );
      return LongPressDraggable<String>(
        key: Key('si-col-$c'),
        data: c,
        delay: const Duration(milliseconds: 150),
        feedback: Material(color: Colors.transparent, child: body),
        childWhenDragging: Opacity(opacity: 0.35, child: body),
        child: Draggable<String>(
          data: c,
          feedback: Material(color: Colors.transparent, child: body),
          childWhenDragging: Opacity(opacity: 0.35, child: body),
          child: body,
        ),
      );
    }

    return ListView(padding: const EdgeInsets.all(12), children: [
      // Every table of the file and where it goes.
      Text(_t('siTables'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
      for (var i = 0; i < _tables.length; i++)
        Card(
          color: i == _current ? AppColors.primary.withValues(alpha: 0.06) : AppColors.surface,
          child: ListTile(
            key: Key('si-table-$i'),
            onTap: () => setState(() => _current = i),
            title: Text(_tables[i].table.name, style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700)),
            subtitle: _tableNote(_tables[i]),
            trailing: _tables[i].partOfProducts
                ? const Icon(Icons.link_rounded, color: AppColors.primary)
                : DropdownButton<ImportDestination>(
              key: Key('si-dest-$i'),
              value: _tables[i].destination,
              items: [
                for (final d in ImportDestination.values)
                  DropdownMenuItem(value: d, child: Text(_t('siDest_${d.name}'), style: const TextStyle(fontFamily: _font))),
              ],
              onChanged: _busy ? null : (d) => _setDestination(_tables[i], d!),
            ),
          ),
        ),
      if (_tables.any((t) => t.analysis.role == TableRole.unknown))
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const Key('si-sara-schema'),
            onPressed: _busy ? null : _askSaraSchema,
            icon: const Icon(Icons.auto_awesome_outlined, size: 18),
            label: Text(_t('siSaraSchema'), style: const TextStyle(fontFamily: _font)),
          ),
        ),
      const SizedBox(height: 12),
      if (target == null)
        _warning(_t('siNoPlace'))
      else ...[
        Row(children: [
          Expanded(child: Text(_t('siColumns'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800))),
          TextButton.icon(
            key: const Key('si-sara'),
            onPressed: _busy ? null : () => _askSara(s),
            icon: const Icon(Icons.auto_awesome_outlined, size: 18),
            label: Text(_t('siAskSara'), style: const TextStyle(fontFamily: _font)),
          ),
        ]),
        Text(_t('siDragHint'), style: TextStyle(fontFamily: _font, fontSize: 12, color: AppColors.textSecondary)),
        const SizedBox(height: 8),
        for (final f in importFields[target]!)
          DragTarget<String>(
            onAcceptWithDetails: (d) => _assign(s, f.key, d.data),
            builder: (context, hovering, _) => Container(
              key: Key('si-field-${f.key}'),
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: hovering.isNotEmpty ? AppColors.primary.withValues(alpha: 0.10) : AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: hovering.isNotEmpty ? AppColors.primary : AppColors.border),
              ),
              child: Row(children: [
                SizedBox(
                  width: 120,
                  child: Text('${_t('siField_${f.key}')}${f.required ? ' *' : ''}',
                      style: const TextStyle(fontFamily: _font, fontSize: 13, fontWeight: FontWeight.w700)),
                ),
                Expanded(
                  child: s.mapping[f.key] == null
                      ? Text(_t('siDropHere'), style: TextStyle(fontFamily: _font, fontSize: 12, color: AppColors.textSecondary))
                      : Align(alignment: AlignmentDirectional.centerStart, child: chip(s.mapping[f.key]!, onField: true)),
                ),
                PopupMenuButton<String>(
                  key: Key('si-pickcol-${f.key}'),
                  tooltip: _t('siChooseColumn'),
                  icon: const Icon(Icons.swap_horiz_rounded),
                  onSelected: (v) => _assign(s, f.key, v == '' ? null : v),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: '', child: Text(_t('siNone'))),
                    for (final c in s.table.columns) PopupMenuItem(value: c, child: Text(c)),
                  ],
                ),
              ]),
            ),
          ),
        const SizedBox(height: 10),
        Text(_t('siUnusedColumns'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
        if (unused.isEmpty)
          Text('—', style: TextStyle(color: AppColors.textSecondary))
        else ...[
          _warning(_t('siUnusedHint')),
          const SizedBox(height: 6),
          DragTarget<String>(
            onAcceptWithDetails: (d) {
              final f = s.mapping.entries.where((e) => e.value == d.data).map((e) => e.key).firstOrNull;
              if (f != null) _assign(s, f, null);
            },
            builder: (context, _, _) => Wrap(spacing: 6, runSpacing: 6, children: [for (final c in unused) chip(c)]),
          ),
        ],
      ],
      const SizedBox(height: 16),
      FilledButton(
        key: const Key('si-review'),
        onPressed: _busy ||
                !_tables.any((t) => _targetOf(t.destination) != null) ||
                _tables.any((t) => _targetOf(t.destination) != null && !t.mapping.containsKey('name'))
            ? null
            : _toReview,
        child: Text(_t('siToReview'), style: const TextStyle(fontFamily: _font)),
      ),
    ]);
  }

  /// What the file's table was recognised as, or why it is not imported.
  Widget _tableNote(_TableState t) {
    final a = t.analysis;
    final cols = _t('siColumnsCount', {'n': '${t.table.columns.length}'});
    if (t.partOfProducts) {
      return Text('${_t('siPart_${a.role.name}')} · ${_t('siLinkedBy', {'c': a.link!.column})}',
          style: const TextStyle(fontFamily: _font, fontSize: 12, color: _green));
    }
    if (t.destination == ImportDestination.none) {
      final why = a.reason ?? 'no_place';
      return Text('⚠ ${_t('siWhy_$why')}',
          style: const TextStyle(fontFamily: _font, fontSize: 12, color: _yellow, fontWeight: FontWeight.w700));
    }
    final who = a.by == 'sara' ? _t('siBySara') : _t('siByRules');
    final sure = a.confidence >= .9 ? '' : ' · ${_t('siCheckIt')}';
    return Text('$cols · $who$sure', style: const TextStyle(fontFamily: _font, fontSize: 12));
  }

  Widget _warning(String text) => Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: _red.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _red.withValues(alpha: 0.5)),
        ),
        child: Row(children: [
          const Icon(Icons.warning_amber_rounded, color: _yellow, size: 18),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text,
                style: const TextStyle(fontFamily: _font, fontSize: 12.5, color: _yellow, fontWeight: FontWeight.w700)),
          ),
        ]),
      );

  Widget _reviewStep() {
    final reviewed = [for (var i = 0; i < _tables.length; i++) if (_tables[i].review != null) i];
    final skipped = [for (final t in _tables) if (t.review == null && !t.partOfProducts) t];
    if (reviewed.isEmpty) return const SizedBox.shrink();
    if (!reviewed.contains(_current)) _current = reviewed.first;
    final s = _tables[_current];
    final total = reviewed.fold<int>(0, (a, i) => a + _tables[i].review!.acceptedCount);
    return Column(children: [
      if (reviewed.length > 1)
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
            for (final i in reviewed)
              Padding(
                padding: const EdgeInsets.all(4),
                child: ChoiceChip(
                  label: Text('${_tables[i].table.name} · ${_t('siDest_${_tables[i].destination.name}')}',
                      style: const TextStyle(fontFamily: _font, fontSize: 12)),
                  selected: i == _current,
                  onSelected: (_) => setState(() => _current = i),
                ),
              ),
          ]),
        ),
      Expanded(
        child: ImportReviewView(
          key: ValueKey(s),
          review: s.review!,
          images: _images,
          skipped: [
            for (final t in skipped)
              _t('siSkippedTableWhy', {'t': t.table.name, 'why': _t('siWhy_${t.analysis.reason ?? 'no_place'}')}),
          ],
          onChanged: () => setState(() {}),
        ),
      ),
      SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: BoxDecoration(color: AppColors.surface, border: Border(top: BorderSide(color: AppColors.border))),
          child: Row(children: [
            Expanded(
              child: Text(_t('siWillAdd', {'n': '$total'}),
                  style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800, color: _green)),
            ),
            FilledButton.icon(
              key: const Key('si-apply'),
              onPressed: _busy || total == 0 ? null : _apply,
              icon: const Icon(Icons.fingerprint_rounded),
              label: Text(_t('siImport', {'n': '$total'}), style: const TextStyle(fontFamily: _font)),
            ),
          ]),
        ),
      ),
    ]);
  }
}

class _Steps extends StatelessWidget {
  const _Steps({required this.step, this.onTap});
  final int step;
  final void Function(int)? onTap;
  @override
  Widget build(BuildContext context) => Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var i = 0; i < 3; i++) ...[
          InkWell(
            onTap: onTap == null ? null : () => onTap!(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text('${i + 1}. ${_t('siStep$i')}',
                  style: TextStyle(
                      fontFamily: _font,
                      fontSize: 12.5,
                      fontWeight: i == step ? FontWeight.w800 : FontWeight.w500,
                      color: i == step ? AppColors.primary : AppColors.textSecondary)),
            ),
          ),
          if (i < 2) Icon(Icons.chevron_left_rounded, size: 16, color: AppColors.textSecondary),
        ],
      ]);
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
          if (r.mapping.containsKey(f.key) || (f.key == 'image' && r.rows.any((x) => x['image'] != null))) f.key,
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
        title: Text('${_t('siField_$field')} — ${_t('siRowN', {'n': '${row.row}'})}',
            style: const TextStyle(fontFamily: _font, fontSize: 15)),
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
        'phone' || 'barcode' || 'sku' || 'category' => 130,
        _ => 100,
      };

  @override
  Widget build(BuildContext context) {
    final fields = _fields;
    const check = 44.0, rowNo = 56.0, reasonW = 220.0;
    // + the 3 px red edge of a refused row.
    final width = check + rowNo + fields.fold<double>(0, (a, f) => a + _width(f)) + reasonW + 3;
    final reasons = r.refusedByReason;
    return Column(children: [
      // Two parts: added / not added.
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: Row(children: [
          Expanded(
            child: _tab(key: 'si-tab-add', label: _t('siTabAdd', {'n': '${r.acceptedCount}'}), color: _green, on: !_refused, () {
              _refused = false;
              _reason = null;
              _selected.clear();
              setState(_filter);
            }),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _tab(key: 'si-tab-refused', label: _t('siTabRefused', {'n': '${r.refusedCount}'}), color: _red, on: _refused, () {
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
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            child: _yellowNote([
              for (final t in widget.skipped) t,
              if (r.unusedColumns.isNotEmpty) _t('siSkippedColumns', {'c': r.unusedColumns.join('، ')}),
            ].join('\n')),
          ),
        if (reasons.isNotEmpty)
          SizedBox(
            height: 44,
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
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
        child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: 260,
            child: TextField(
              key: const Key('si-search'),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                hintText: _t('siSearch'),
              ),
              onChanged: (v) => setState(() {
                _query = v;
                _filter();
              }),
            ),
          ),
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
            child: Text(_t('siSelectAll'), style: const TextStyle(fontFamily: _font)),
          ),
          if (_selected.isNotEmpty)
            FilledButton.tonal(
              key: const Key('si-bulk'),
              onPressed: () {
                final rows = r.rows.where((e) => _selected.contains(e.row));
                r.setRejected(rows, !_refused);
                _selected.clear();
                _changed();
              },
              child: Text(_refused ? _t('siApproveSel', {'n': '${_selected.length}'}) : _t('siRejectSel', {'n': '${_selected.length}'}),
                  style: const TextStyle(fontFamily: _font)),
            ),
        ]),
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

  Widget _tab(VoidCallback onTap, {required String key, required String label, required Color color, required bool on}) =>
      InkWell(
        key: Key(key),
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? color.withValues(alpha: 0.14) : AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: on ? color : AppColors.border, width: on ? 2 : 1),
          ),
          child: Text(label, style: TextStyle(fontFamily: _font, fontWeight: FontWeight.w800, color: color)),
        ),
      );

  Widget _yellowNote(String text) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: _red.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _red.withValues(alpha: 0.5)),
        ),
        child: Text(text, style: const TextStyle(fontFamily: _font, fontSize: 12, color: _yellow, fontWeight: FontWeight.w700)),
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
        color: refused ? _red.withValues(alpha: 0.08) : null,
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
                  style: TextStyle(fontFamily: _font, fontSize: 11.5, color: refused ? _yellow : AppColors.textSecondary,
                      fontWeight: refused ? FontWeight.w800 : FontWeight.w500)),
            ),
          ]),
        ),
      ]),
    );
  }

  Future<void> _showParts(ReviewRow row) => showModalBottomSheet<void>(
        context: context,
        builder: (_) => SafeArea(
          child: ListView(padding: const EdgeInsets.all(16), shrinkWrap: true, children: [
            Text(row['name'] ?? '', style: const TextStyle(fontFamily: _font, fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            for (final u in row.units)
              ListTile(
                dense: true,
                leading: const Icon(Icons.inventory_2_outlined),
                title: Text('${u['name'] ?? '—'} × ${u['factor'] ?? '1'}', style: const TextStyle(fontFamily: _font)),
                subtitle: Text([u['barcode'], u['sale_price'], u['cost_price']].whereType<String>().join(' · ')),
              ),
            for (final b in row.barcodes)
              ListTile(dense: true, leading: const Icon(Icons.qr_code_2_rounded), title: Text(b)),
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
      borderRadius: BorderRadius.circular(4),
      child: Image.memory(b, width: 36, height: 36, cacheWidth: 72, fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined, size: 18)),
    );
  }
}
