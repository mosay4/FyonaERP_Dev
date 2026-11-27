import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/core_business/data/local_commerce/local_commerce_api.dart';
import '../../../features/core_business/data/local_directory/directory_pilot.dart';
import '../../../features/core_business/data/local_directory/directory_scope.dart';
import '../../../features/core_business/data/local_directory/directory_secure_storage.dart';
import '../../../features/inventory/presentation/providers/inventory_providers.dart';
import '../../di/providers.dart';
import '../../localization/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../business_import.dart';
import '../import_plan.dart';
import '../import_source.dart';
import '../sara_mapping.dart';

String _t(String key, [Map<String, dynamic>? p]) => AppLocalizations.t(key, p);
const _font = 'Cairo';

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
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SmartImportPage())),
      ),
    );
  }
}

class SmartImportPage extends ConsumerStatefulWidget {
  const SmartImportPage({super.key});
  @override
  ConsumerState<SmartImportPage> createState() => _SmartImportPageState();
}

class _SmartImportPageState extends ConsumerState<SmartImportPage> {
  ImportTarget _target = ImportTarget.parties;
  String _kind = 'customer';
  final _currency = TextEditingController(text: 'SAR');
  File? _file;
  String? _sha;
  List<ImportTable> _tables = const [];
  ImportTable? _table;
  Map<String, String> _mapping = {};
  ImportPreview? _preview;
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
    return BusinessImporter(
      store: ref.read(directoryPilotStoreProvider),
      access: _scope!,
      registry: reg,
      createProduct: inv.createProduct,
      deleteProduct: inv.deleteProduct,
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

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text, style: const TextStyle(fontFamily: _font))));
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
      _snack(_failure(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
          _fraction = null;
        });
      }
      await _loadBatches();
    }
  }

  Future<void> _pick() => _guard(() async {
        final picked = await FilePicker.pickFiles(type: FileType.any, withData: false);
        final path = picked?.files.single.path;
        if (path == null) return;
        final f = File(path);
        final tables = await readImportFile(f);
        final sha = '${await sha256.bind(f.openRead()).first}';
        setState(() {
          _file = f;
          _sha = sha;
          _tables = tables;
          _table = tables.first;
          _mapping = autoMapColumns(_target, tables.first.columns);
          _preview = null;
        });
      });

  void _selectTable(ImportTable t) => setState(() {
        _table = t;
        _mapping = autoMapColumns(_target, t.columns);
        _preview = null;
      });

  Future<void> _askSara() => _guard(() async {
        final t = _table;
        if (t == null) return;
        final m = await saraImportMapping(ref.read(apiClientProvider), _target, t);
        if (m == null || m.isEmpty) {
          _snack(_t('siSaraFailed'));
          return;
        }
        setState(() {
          _mapping = m;
          _preview = null;
        });
        _snack(_t('siSaraDone'));
      });

  Future<void> _buildPreview() => _guard(() async {
        final t = _table;
        if (t == null) return;
        final reg = await _reg();
        final existing = _target == ImportTarget.archive ? <String>{} : await _importer(reg).existingNames();
        final p = await buildImportPreview(t, _target, _mapping,
            defaultKind: _kind,
            defaultCurrency: _currency.text.trim().toUpperCase(),
            existing: existing, onRows: (n) {
          if (mounted) setState(() => _progress = _t('siRows', {'n': '$n'}));
        });
        setState(() => _preview = p);
      });

  Future<void> _apply() => _guard(() async {
        final p = _preview, f = _file, sha = _sha;
        if (p == null || f == null || sha == null) return;
        final reg = await _reg();
        final id = await _importer(reg).apply(p, fileSha: sha, fileName: f.uri.pathSegments.last, onProgress: (d, total) {
          if (!mounted) return;
          setState(() {
            _progress = _t('siImporting', {'done': '$d', 'total': '$total'});
            _fraction = total == 0 ? 1 : d / total;
          });
        });
        setState(() => _preview = null);
        _snack(_t('siDone', {'id': id.substring(0, 8)}));
      });

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
    if (ok != true) return;
    await _guard(() async {
      await _importer(await _reg()).undo(id);
      _snack(_t('siUndone'));
    });
  }

  String _money(int minor) => (minor / 100).toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final t = _table, p = _preview;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(_t('siTitle'), style: const TextStyle(fontFamily: _font))),
      body: _scope == null
          ? const SizedBox.shrink()
          : ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
              Text(_t('siIntro'), style: TextStyle(fontFamily: _font, fontSize: 12.5, color: AppColors.textSecondary)),
              const SizedBox(height: 12),
              if (_busy) ...[
                LinearProgressIndicator(value: _fraction),
                if (_progress != null) Text(_progress!, style: const TextStyle(fontFamily: _font, fontSize: 12)),
                const SizedBox(height: 8),
              ],
              Text(_t('siWhat'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
              for (final target in ImportTarget.values)
                RadioListTile<ImportTarget>(
                  key: Key('si-target-${target.name}'),
                  value: target,
                  groupValue: _target,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() {
                            _target = v!;
                            _mapping = t == null ? {} : autoMapColumns(v, t.columns);
                            _preview = null;
                          }),
                  title: Text(_t({'parties': 'siParties', 'products': 'siProducts', 'archive': 'siArchive'}[target.name]!),
                      style: const TextStyle(fontFamily: _font)),
                  subtitle: target == ImportTarget.archive
                      ? Text(_t('siArchiveHint'), style: const TextStyle(fontFamily: _font, fontSize: 12))
                      : null,
                ),
              if (_target == ImportTarget.parties)
                Row(children: [
                  Expanded(child: Text(_t('siDefaultKind'), style: const TextStyle(fontFamily: _font, fontSize: 13))),
                  DropdownButton<String>(
                    value: _kind,
                    items: [
                      DropdownMenuItem(value: 'customer', child: Text(_t('siCustomers'))),
                      DropdownMenuItem(value: 'supplier', child: Text(_t('siSuppliers'))),
                    ],
                    onChanged: _busy ? null : (v) => setState(() => _kind = v!),
                  ),
                ]),
              if (_target == ImportTarget.parties)
                TextField(
                  controller: _currency,
                  decoration: InputDecoration(labelText: _t('siCurrency')),
                  onChanged: (_) => setState(() => _preview = null),
                ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('si-pick'),
                onPressed: _busy ? null : _pick,
                icon: const Icon(Icons.folder_open_outlined),
                label: Text(_file == null ? _t('siPick') : _file!.uri.pathSegments.last, style: const TextStyle(fontFamily: _font)),
              ),
              if (_tables.length > 1)
                DropdownButton<ImportTable>(
                  isExpanded: true,
                  value: t,
                  items: [for (final x in _tables) DropdownMenuItem(value: x, child: Text('${_t('siTable')}: ${x.name}'))],
                  onChanged: _busy ? null : (v) => _selectTable(v!),
                ),
              if (t != null && _target != ImportTarget.archive) ...[
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(child: Text(_t('siColumns'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800))),
                  TextButton.icon(
                    key: const Key('si-sara'),
                    onPressed: _busy ? null : _askSara,
                    icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                    label: Text(_t('siAskSara'), style: const TextStyle(fontFamily: _font)),
                  ),
                ]),
                for (final f in importFields[_target]!)
                  Row(children: [
                    Expanded(child: Text(_t('siField_${f.key}'), style: const TextStyle(fontFamily: _font, fontSize: 13))),
                    Expanded(
                      child: DropdownButton<String?>(
                        key: Key('si-map-${f.key}'),
                        isExpanded: true,
                        value: _mapping[f.key],
                        items: [
                          DropdownMenuItem<String?>(value: null, child: Text(_t('siNone'))),
                          for (final c in t.columns) DropdownMenuItem<String?>(value: c, child: Text(c, overflow: TextOverflow.ellipsis)),
                        ],
                        onChanged: _busy
                            ? null
                            : (v) => setState(() {
                                  if (v == null) {
                                    _mapping.remove(f.key);
                                  } else {
                                    _mapping.removeWhere((_, c) => c == v);
                                    _mapping[f.key] = v;
                                  }
                                  _preview = null;
                                }),
                      ),
                    ),
                  ]),
              ],
              if (t != null) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  key: const Key('si-preview'),
                  onPressed: _busy || (_target != ImportTarget.archive && !_mapping.containsKey('name')) ? null : _buildPreview,
                  child: Text(_t('siPreview'), style: const TextStyle(fontFamily: _font)),
                ),
              ],
              if (p != null) ...[
                const SizedBox(height: 12),
                Text(_t('siRows', {'n': '${p.rows}'}), style: const TextStyle(fontFamily: _font)),
                Text(_t('siReady', {'n': '${p.ready}'}), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
                for (final k in p.totals.entries)
                  for (final c in k.value.entries)
                    Text(_t('siTotal', {'kind': _t(k.key == 'customer' ? 'siCustomers' : 'siSuppliers'), 'amount': _money(c.value), 'cur': c.key}),
                        style: const TextStyle(fontFamily: _font, fontSize: 13)),
                if (p.issueCount > 0) ...[
                  Text(_t('siSkipped', {'n': '${p.issueCount}'}), style: const TextStyle(fontFamily: _font, color: AppColors.warning)),
                  for (final i in p.issues.take(50))
                    Text(_t('siIssueRow', {'row': '${i.row}', 'reason': _t('siIssue_${i.code}')}),
                        style: const TextStyle(fontFamily: _font, fontSize: 12)),
                ],
                const SizedBox(height: 8),
                FilledButton(
                  key: const Key('si-apply'),
                  onPressed: _busy || p.ready == 0 ? null : _apply,
                  child: Text(_t('siImport', {'n': '${p.ready}'}), style: const TextStyle(fontFamily: _font)),
                ),
              ],
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
            ]),
    );
  }
}
