import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/auth/presentation/widgets/app_pin_sheet.dart';
import '../../../features/branches/data/branch_api.dart';
import '../../../features/branches/data/branch_epoch.dart';
import '../../../features/branches/data/branch_scope.dart';
import '../../../features/core_business/data/local_commerce/local_commerce_api.dart';
import '../../../features/core_business/data/local_directory/directory_pilot.dart';
import '../../../features/core_business/data/local_directory/directory_scope.dart';
import '../../../features/core_business/data/local_directory/directory_secure_storage.dart';
import '../../../features/inventory/presentation/providers/inventory_providers.dart';
import '../../backup/presentation/operation_motion.dart';
import '../../di/providers.dart';
import '../../localization/app_localizations.dart';
import '../../services/connectivity_service.dart';
import '../../services/currency/business_currency_scope.dart';
import '../../media/media_store.dart';
import '../../theme/app_colors.dart';
import '../business_import.dart';
import '../import_plan.dart';
import '../import_schema.dart';
import '../import_session.dart';
import '../import_source.dart';
import '../sara_mapping.dart';
import 'sara_scan.dart';
import '../../../shared/widgets/biz_currency_items.dart';
import '../../utils/currency_formatter.dart' show currencyLabel;

String _t(String key, [Map<String, dynamic>? p]) => AppLocalizations.t(key, p);
const _font = 'Cairo';


/// The app's one currency label: Arabic name in Arabic, code in English.
String _curLabel(String code) => currencyLabel(code);

// FYONA's own colours: the brand red for actions, green / red only to say
// "will be added" / "will not be added".
const _red = Color(0xFFC62828);
const _yellow = Color(0xFFB7791F);
const _green = Color(0xFF2E7D32);
const _blue = Color(0xFF37474F);

/// Final confirmation before an import or an undo (fingerprint or the
/// app's PIN). Replaceable in tests.
typedef ImportConfirm = Future<bool> Function(BuildContext context, WidgetRef ref, String reason);
final smartImportConfirmProvider = Provider<ImportConfirm>(
  (ref) => (context, widgetRef, reason) =>
      verifySensitiveAction(context, widgetRef, reason: reason, existingCredentialsOnly: true),
);

/// Sara's two calls in the window (replaceable in tests): she checks the
/// whole file, or does one thing the user asks. Null: she could not be
/// reached (the window says so and offers to try again).
class SmartImportSara {
  const SmartImportSara({required this.schema, required this.agent});
  final Future<List<Map<String, dynamic>>?> Function(List<TableAnalysis> tables) schema;
  final Future<SaraAgentAnswer?> Function(String message, ImportSession s) agent;
}

final smartImportSaraProvider = Provider<SmartImportSara>((ref) {
  final api = ref.read(apiClientProvider);
  return SmartImportSara(
    schema: (tables) => saraImportSchema(api, tables),
    agent: (message, s) => saraImportAgent(api, message: message, currency: s.currency, tables: s.analysis),
  );
});

/// The owner's FYONA branches the import can go to (tests replace it).
final smartImportBranchesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final rows = await ref.read(branchApiProvider).list();
  return [
    for (final b in rows)
      if (b['id'] != null && b['is_archived'] != true && b['is_active'] != false) b,
  ];
});

/// Sara's official picture (never a generic icon).
class SaraAvatar extends StatelessWidget {
  const SaraAvatar({super.key, this.size = 40, this.ring = false});
  final double size;
  final bool ring;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(ring ? 2 : 0),
        decoration: BoxDecoration(shape: BoxShape.circle, color: ring ? Colors.white : null),
        child: ClipOval(
          child: Image.asset('assets/images/sara_avatar.jpg',
              fit: BoxFit.cover,
              cacheWidth: (size * 3).round(),
              errorBuilder: (_, _, _) => Container(color: AppColors.primary.withValues(alpha: .12))),
        ),
      );
}

/// Every place a table of the file can go (the four imported sections,
/// what joins into them, and what is never imported).
const importRoleGroups = <String, List<TableRole>>{
  'cards': [TableRole.accounts, TableRole.products, TableRole.customers, TableRole.suppliers],
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
        leading: const Icon(Icons.move_to_inbox_rounded, color: AppColors.primary),
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

/// The section of FYONA a table goes to (the four imported sections).
String _sectionOf(TableRole r) => switch (r) {
      TableRole.accounts => 'accounts',
      TableRole.products => 'products',
      TableRole.customers => 'customers',
      _ => 'suppliers',
    };

enum _SaraState { idle, working, done, failed }

class SmartImportPage extends ConsumerStatefulWidget {
  const SmartImportPage({super.key, this.initialFile});

  /// Tests: start with this file (no picker).
  final File? initialFile;
  @override
  ConsumerState<SmartImportPage> createState() => _SmartImportPageState();
}

class _SmartImportPageState extends ConsumerState<SmartImportPage> {
  int _step = 0; // 0 file · 1 check · 2 review · 3 confirm
  File? _file;
  String? _sha;
  ImportSession? _session;
  TableAnalysis? _current;
  bool _busy = false;
  String? _progress;
  List<Map<String, Object?>> _batches = const [];
  ImportRegistry? _registry;
  List<String> _enabled = const [];
  final _rows = <TableAnalysis, int>{};

  // Sara: one button in the header («تحليل سارة»), no chat. She only
  // suggests; every table she changed can be put back.
  _SaraState _sara = _SaraState.idle;

  /// The user chose the currency of amounts without one (else the
  /// branch's own currency is used: choosing is optional).
  bool _currencyChosen = false;

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
      fallbackCurrency: _session?.currency ?? _enabled.firstOrNull ?? 'SAR',
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

  void _snack(String text, {bool error = false, VoidCallback? retry}) {
    if (!mounted) return;
    // The newest message replaces the one on screen (never queued behind).
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
      backgroundColor: error ? _red : null,
      content: Text(text, style: const TextStyle(fontFamily: _font)),
      action: retry == null
          ? null
          : SnackBarAction(label: _t('si3SaraRetry'), textColor: Colors.white, onPressed: retry),
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

  // ── step 0: where to, and the file ──────────────────────────────────

  /// The FYONA branch the data goes to: the app's own branch switch, done
  /// right here (before any file), then this window follows it.
  Future<void> _selectTarget(Map<String, dynamic> picked) async {
    final id = '${picked['id']}';
    if (!BranchScope.allMode && id == BranchScope.branchId) return;
    final org = BranchScope.organizationId ?? _scope?.workspace.organizationId;
    if (org == null) return;
    await _guard(() async {
      await ref.read(branchApiProvider).selectFromDrawer(
            organizationId: org,
            branchId: id,
            all: false,
            connected: ref.read(connectivityServiceProvider).isOnline,
          );
      ref.invalidate(branchAccessProvider);
      ref.read(branchEpochProvider.notifier).state++;
      // The ledger scope follows the switch: wait for it (a moment).
      for (var i = 0; i < 50 && ref.read(businessLocalLedgerScopeProvider)?.branchId != id; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await _registry?.close();
      _registry = null;
      _session = null;
      _file = null;
      _currencyChosen = false;
      try {
        _enabled = (await ref.read(bizEnabledCurrenciesProvider.future)).toList();
      } catch (_) {}
      await _loadBatches();
    });
    if (mounted) setState(() {});
  }

  Future<void> _pick() async {
    final picked = await FilePicker.pickFiles(type: FileType.any, withData: false);
    final path = picked?.files.single.path;
    if (path != null) await _open(File(path));
  }

  /// Reads the file and understands every table (deterministic rules).
  /// Sara looks at the tables the rules were not sure of; the full check
  /// is one tap away («فحص بواسطة سارة»).
  Future<void> _open(File f) => _guard(() async {
        var existing = <String>{};
        try {
          existing = await _importer(await _reg()).existingNames();
        } catch (_) {}
        try {
          _enabled = (await ref.read(bizEnabledCurrenciesProvider.future)).toList();
        } catch (_) {}
        final saraOk = <bool?>[null];
        Future<ImportSession> work(void Function(String s, double d) stage) async {
          stage(_t('si2StageRead'), .05);
          final tables = await readImportFile(f);
          final images = await readImportImages(f);
          stage(_t('si2StageUnderstand', {'n': '${tables.length}'}), .3);
          // No currency is assumed: the file's own, or the user's choice.
          final s = await ImportSession.analyze(tables,
              images: images,
              enabled: _enabled.toSet(),
              // Optional choice: amounts the file leaves without a currency
              // are in the branch's own currency until the user picks one.
              currency: _enabled.firstOrNull,
              currentBranchName: BranchScope.branchName);
          s.existing = existing;
          stage(_t('si2StageLink'), .55);
          final unclear = s.forSara;
          if (unclear.isNotEmpty) {
            stage(_t('si2StageSara', {'n': '${unclear.length}'}), .7);
            final answers = await ref.read(smartImportSaraProvider).schema(unclear);
            saraOk[0] = answers != null;
            if (answers != null) await s.applySara(answers);
          }
          stage(_t('si2StageCheck'), .85);
          _sha = '${await sha256.bind(f.openRead()).first}';
          _rows.clear();
          for (final a in s.analysis) {
            _rows[a] = await a.table.count();
          }
          return s;
        }

        if (!mounted) return;
        final ImportSession s;
        if (widget.initialFile != null) {
          s = await work((_, _) {});
        } else {
          s = await OperationMotion.run<ImportSession>(context,
              kind: MotionKind.smartImport, doneText: _t('si2Arranged'), failureText: _failure, work: (m) => work(m.stage));
        }
        setState(() {
          _file = f;
          _session = s;
          _currencyChosen = false;
          _current = s.importable.firstOrNull;
          _sara = saraOk[0] == false ? _SaraState.failed : (saraOk[0] == true ? _SaraState.done : _SaraState.idle);
          _step = 1;
        });
      });

  // ── Sara: «تحليل سارة» (a button in the header; no chat) ────────────

  /// Sara reads every table and places it; the scan plays meanwhile. Her
  /// changes are marked on each table and can be undone one by one.
  Future<void> _saraCheck() async {
    final s = _session;
    if (s == null || _sara == _SaraState.working || _busy) return;
    setState(() => _sara = _SaraState.working);
    final ans = await SaraScan.run<List<Map<String, dynamic>>?>(
      context,
      tables: [for (final a in s.analysis) a.table.name.split(' · ').last],
      work: () => ref.read(smartImportSaraProvider).schema(s.analysis),
      ok: (a) => a != null,
      motion: widget.initialFile == null,
    );
    if (!mounted) return;
    if (ans == null) {
      setState(() => _sara = _SaraState.failed);
      _snack(_t('si3SaraOff'), error: true, retry: _saraCheck);
      return;
    }
    final n = await s.applySara(ans, everything: true);
    if (_step == 2) await _toReview();
    if (!mounted) return;
    setState(() {
      _sara = _SaraState.done;
      _current = s.importable.contains(_current) ? _current : s.importable.firstOrNull;
    });
    _snack(n == 0 ? _t('si3SaraAllGood', {'n': '${ans.length}'}) : _t('si3SaraChanged', {'n': '$n'}));
  }

  Future<void> _undoSara(TableAnalysis a) async {
    final s = _session;
    if (s == null) return;
    await _guard(() async {
      await s.revertSara(a);
      if (_step == 2) await s.buildReviews();
    });
    _snack(_t('si4SaraUndone'));
  }

  /// «تحليل سارة» in the header: her picture and the name, nothing else.
  Widget _saraButton() {
    final working = _sara == _SaraState.working;
    return Material(
      color: Colors.white,
      shape: const StadiumBorder(),
      elevation: 0,
      child: InkWell(
        key: const Key('si-sara-check'),
        customBorder: const StadiumBorder(),
        onTap: working || _busy ? null : _saraCheck,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(4, 4, 12, 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Stack(alignment: Alignment.center, children: [
              const SaraAvatar(size: 30),
              if (working)
                const SizedBox(
                    width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary)),
            ]),
            const SizedBox(width: 7),
            Text(_t('si4SaraButton'),
                key: const Key('si-sara-status'),
                style: const TextStyle(fontFamily: _font, fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.primary)),
          ]),
        ),
      ),
    );
  }

  // ── step 1: the check ───────────────────────────────────────────────

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
      if (_step == 2) await s.buildReviews();
    });
  }

  Future<String?> _chooseCurrency(String? current) => showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.background,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
        builder: (_) => _CurrencyPicker(current: current, enabled: _enabled),
      );

  Future<void> _pickCurrency() async {
    final s = _session;
    if (s == null) return;
    final code = await _chooseCurrency(s.currency);
    if (code != null) {
      setState(() {
        _currencyChosen = true;
        s.setCurrency(code);
      });
    }
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
          _SheetTitle(icon: Icons.call_split_rounded, title: _t('si2BranchTitle'), hint: _t('si3FileBranchHint')),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final b in choices)
                ListTile(
                  key: Key('si-branch-$b'),
                  leading: const Icon(Icons.description_outlined, color: AppColors.primary),
                  title: Text(b, style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700)),
                  trailing: s.sourceBranch == b ? const Icon(Icons.check_circle_rounded, color: _green) : null,
                  onTap: () => Navigator.pop(ctx, b),
                ),
            ]),
          ),
          const SizedBox(height: 12),
        ]),
      ),
    );
    if (picked != null) setState(() => s.setSourceBranch(picked));
  }

  /// The key an import batch of table [a] is kept under (file + table).
  String _batchKey(TableAnalysis a) => '${sha256.convert(utf8.encode('$_sha|${a.table.name}|${a.role.name}'))}';

  Future<void> _toReview() => _guard(() async {
        final s = _session!;
        final imp = _importer(await _reg());
        final existing = await imp.existingNames();
        // What this branch already has from this same file: shown as
        // "already in FYONA", never as an error, and never added twice.
        final imported = <String, Set<int>>{
          for (final a in s.importable) a.table.name: await imp.importedRows(_batchKey(a), a.role.target!),
        };
        bool same(Map<String, Set<int>> x, Map<String, Set<int>> y) =>
            x.length == y.length && x.entries.every((e) => y[e.key]?.length == e.value.length && y[e.key]!.containsAll(e.value));
        if (existing.length != s.existing.length || !existing.containsAll(s.existing) || !same(imported, s.imported)) {
          s.existing = existing;
          s.imported = imported;
          s.reviews.clear();
        }
        await s.buildReviews(onRows: (t, n) {
          if (mounted) setState(() => _progress = '$t · ${_t('siRows', {'n': '$n'})}');
        });
        // Not chosen by the user: the currency most of the file's amounts
        // name (one of the branch's), else the branch's own.
        if (!_currencyChosen) {
          final count = <String, int>{};
          for (final r in s.reviews.values) {
            for (final row in r.rows.take(3000)) {
              final c = importCurrency(row['currency'], null, s.context.currencyCodes, s.enabled);
              if (c != null && _enabled.contains(c)) count[c] = (count[c] ?? 0) + 1;
            }
          }
          final best = count.entries.fold<MapEntry<String, int>?>(null, (a, e) => a == null || e.value > a.value ? e : a)?.key;
          if (best != null && best != s.currency) {
            s.setCurrency(best);
            await s.buildReviews();
          }
        }
        setState(() {
          _current = s.reviews.keys.contains(_current) ? _current : s.reviews.keys.firstOrNull;
          _step = 2;
        });
      });

  // ── step 3: confirm → save ──────────────────────────────────────────

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
      Future<List<String>> work(void Function(String) stage, void Function(double) progress) async {
        final reg = await _reg();
        final imp = _importer(reg);
        var base = 0;
        final ids = <String>[];
        for (final e in ready) {
          final p = e.value.toPreview();
          stage(_t('siImportingTable', {'t': _t('si2Role_${e.key.role.name}')}));
          progress(base / total);
          ids.add(await imp.apply(p,
              fileSha: _batchKey(e.key),
              fileName: _file!.uri.pathSegments.last,
              onProgress: (d, n) => progress((base + d) / total)));
          refusedByRules += imp.skippedRows.length;
          base += p.ready;
        }
        return ids;
      }

      if (widget.initialFile != null) {
        await work((_) {}, (_) {});
      } else {
        await OperationMotion.run<List<String>>(context,
            kind: MotionKind.smartImport,
            doneText: _t('siDoneShort', {'n': '$total'}),
            failureText: _failure,
            work: (m) => work(m.stage, m.progress));
      }
      _snack(refusedByRules == 0 ? _t('si3Done', {'n': '$total'}) : _t('si2DoneSome', {'n': '$refusedByRules'}));
      setState(() {
        _step = 0;
        _session = null;
        _file = null;
        _sara = _SaraState.idle;
      });
    } catch (e) {
      if (widget.initialFile != null) _snack(_failure(e), error: true);
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
          TextButton(
              key: const Key('si-undo-confirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_t('siUndo'), style: const TextStyle(color: _red, fontWeight: FontWeight.w800))),
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

  void _back() {
    if (_busy) return;
    if (_step > 0) {
      setState(() => _step = _step == 1 ? 0 : _step - 1);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _step == 0 && !_busy,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _back();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: _scope == null
            ? const SizedBox.shrink()
            : DefaultTextStyle.merge(
                style: TextStyle(color: AppColors.textPrimary),
                child: Column(children: [
                  _Header(
                    step: _step,
                    trailing: _session != null && (_step == 1 || _step == 2) ? _saraButton() : null,
                    onClose: () => Navigator.of(context).maybePop(),
                    onStep: _busy ? null : (i) => setState(() => _step = i < _step ? i : _step),
                  ),
                  if (_busy)
                    Column(children: [
                      const LinearProgressIndicator(minHeight: 3),
                      if (_progress != null)
                        Padding(
                          padding: const EdgeInsets.all(6),
                          child: Text(_progress!,
                              style: TextStyle(fontFamily: _font, fontSize: 12, color: AppColors.textSecondary)),
                        ),
                    ]),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      switchInCurve: Curves.easeOutCubic,
                      transitionBuilder: (child, a) => FadeTransition(opacity: a, child: child),
                      child: KeyedSubtree(
                        key: ValueKey(_step),
                        child: switch (_step) {
                          0 => _fileStep(),
                          1 => _checkStep(),
                          2 => _reviewStep(),
                          _ => _confirmStep(),
                        },
                      ),
                    ),
                  ),
                ])),
      ),
    );
  }

  Widget _primary({required Key key, required String label, required IconData icon, VoidCallback? onPressed}) => SizedBox(
        width: double.infinity,
        height: 52,
        child: FilledButton.icon(
          key: key,
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 52),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: _font, fontSize: 15.5, fontWeight: FontWeight.w800)),
        ),
      );

  Widget _fileStep() {
    final branches = ref.watch(smartImportBranchesProvider).valueOrNull ?? const <Map<String, dynamic>>[];
    final needsBranch = BranchScope.allMode;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 28), children: [
      Text(_t('si3Hero'), style: const TextStyle(fontFamily: _font, fontSize: 19, fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      Text(_t('si3HeroSub'), style: TextStyle(fontFamily: _font, fontSize: 13, color: AppColors.textSecondary, height: 1.5)),
      const SizedBox(height: 14),
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 2.6,
        children: [
          for (final r in [TableRole.accounts, TableRole.products, TableRole.customers, TableRole.suppliers])
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: .09), shape: BoxShape.circle),
                  child: Icon(importRoleIcon(r), size: 17, color: AppColors.primary),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_t('si3Section_${_sectionOf(r)}'),
                      maxLines: 2,
                      style: const TextStyle(fontFamily: _font, fontSize: 12.5, fontWeight: FontWeight.w700, height: 1.25)),
                ),
              ]),
            ),
        ],
      ),
      const SizedBox(height: 16),
      // Where the data goes: the owner's FYONA branches, chosen right here
      // (before the file). One branch: it is simply the one.
      Text(_t('si4TargetTitle'), style: const TextStyle(fontFamily: _font, fontSize: 14.5, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      if (branches.length < 2 && !needsBranch)
        _SettingChip(
          key: const Key('si-target'),
          icon: Icons.storefront_rounded,
          label: _t('si3TargetLabel'),
          value: BranchScope.branchName ?? _t('si3TargetCurrent'),
          showArrow: false,
        )
      else
        for (final b in branches)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _BranchCard(
              key: Key('si-target-${b['id']}'),
              name: '${b['name'] ?? ''}',
              on: !BranchScope.allMode && '${b['id']}' == BranchScope.branchId,
              onTap: _busy ? null : () => _selectTarget(b),
            ),
          ),
      const SizedBox(height: 12),
      _primary(
        key: const Key('si-pick'),
        label: _t('siPick'),
        icon: Icons.upload_file_rounded,
        onPressed: _busy || needsBranch ? null : _pick,
      ),
      const SizedBox(height: 8),
      Text(_t('si2Formats'),
          textAlign: TextAlign.center, style: TextStyle(fontFamily: _font, fontSize: 11.5, color: AppColors.textSecondary)),
      if (_batches.isNotEmpty) ...[
        const SizedBox(height: 18),
        Material(
          color: AppColors.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: AppColors.border)),
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
                            style: TextButton.styleFrom(minimumSize: const Size(0, 36)),
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
  }

  Widget _checkStep() {
    final s = _session;
    if (s == null) return const SizedBox.shrink();
    final importable = s.importable, linked = s.linked;
    final excluded = [...s.reference, ...s.skipped];
    final branches = s.branchChoices;
    int rowsOf(TableRole r) => [for (final a in importable) if (a.role == r) _rows[a] ?? 0].fold(0, (x, y) => x + y);
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 20), children: [
          Row(children: [
            for (final r in [TableRole.accounts, TableRole.products, TableRole.customers, TableRole.suppliers]) ...[
              Expanded(
                child: _Count(icon: importRoleIcon(r), n: rowsOf(r), label: _t('si3Short_${_sectionOf(r)}')),
              ),
              if (r != TableRole.suppliers) const SizedBox(width: 6),
            ],
          ]),
          const SizedBox(height: 12),
          _SettingChip(
            key: const Key('si-currency'),
            icon: Icons.payments_rounded,
            label: _t('si4CurrencyOptional'),
            value: s.currency == null
                ? _t('si3CurrencyNone')
                : _currencyChosen
                    ? _curLabel(s.currency!)
                    : _t('si4CurrencyAuto', {'c': _curLabel(s.currency!)}),
            leading: s.currency == null ? null : bizCurrencyFlag(s.currency!, size: 26),
            warn: s.currency == null,
            onTap: _busy ? null : _pickCurrency,
          ),
          if (branches.length > 1) ...[
            const SizedBox(height: 8),
            _SettingChip(
              key: const Key('si-branch'),
              icon: Icons.call_split_rounded,
              label: _t('si3FileBranch'),
              value: s.sourceBranch ?? '—',
              onTap: _busy ? null : _pickBranch,
            ),
          ],
          const SizedBox(height: 16),
          if (importable.isNotEmpty) ...[
            _SectionTitle(text: _t('si2WillAdd'), color: _green, icon: Icons.check_circle_rounded),
            for (final a in importable)
              _TableCard(
                key: Key('si-table-${a.table.name}'),
                analysis: a,
                rows: _rows[a],
                children: [for (final p in linked) if (p.link?.parent == a.table) p],
                onRole: _busy ? null : _changeRole,
                onColumns: _busy ? null : _editColumns,
                bySara: s.saraBefore.containsKey(a),
                onUndoSara: _busy ? null : () => _undoSara(a),
              ),
          ] else
            _Note(text: _t('si3NothingFound'), color: _yellow, icon: Icons.info_outline_rounded),
          if (excluded.isNotEmpty) ...[
            const SizedBox(height: 6),
            Material(
              color: AppColors.surface,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: AppColors.border)),
              child: Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: const Key('si-excluded'),
                  leading: const Icon(Icons.remove_circle_outline_rounded, color: _red),
                  title: Text(_t('si3Excluded', {'n': '${excluded.length}'}),
                      style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800, fontSize: 14)),
                  subtitle: Text(_t('si3ExcludedHint'),
                      style: TextStyle(fontFamily: _font, fontSize: 11.5, color: AppColors.textSecondary)),
                  children: [
                    for (final a in excluded)
                      ListTile(
                        key: Key('si-table-${a.table.name}'),
                        dense: true,
                        leading: Icon(importRoleIcon(a.role), size: 20, color: AppColors.textSecondary),
                        title: Text(a.table.name.split(' · ').last,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700, fontSize: 13)),
                        subtitle: Text(_t('si3Why_${a.role.name}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontFamily: _font, fontSize: 11.5, color: AppColors.textSecondary)),
                        trailing: _RoleChip(
                            key: Key('si-dest-${a.table.name}'),
                            role: a.role,
                            onTap: _busy ? null : () => _changeRole(a)),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ]),
      ),
      _BottomBar(
        child: _primary(
          key: const Key('si-review'),
          label: _t('si2ToReview', {'n': '${importable.length}'}),
          icon: Icons.fact_check_rounded,
          onPressed: _busy || importable.isEmpty || importable.any((a) => !a.mapping.containsKey('name')) ? null : _toReview,
        ),
      ),
    ]);
  }

  Widget _reviewStep() {
    final s = _session;
    if (s == null) return const SizedBox.shrink();
    if (s.reviews.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _primary(
              key: const Key('si-rebuild'), label: _t('si2ToReview', {'n': '${s.importable.length}'}), icon: Icons.refresh_rounded,
              onPressed: _busy ? null : _toReview),
        ),
      );
    }
    final keys = s.reviews.keys.toList();
    final cur = keys.contains(_current) ? _current! : keys.first;
    final total = s.readyCount;
    final blocked = s.reviews.values.fold<int>(0, (a, r) => a + r.skippedCount);
    // The sections side by side, each fully visible (no sideways scroll).
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
        child: Row(children: [
          for (final a in keys) ...[
            Expanded(
              child: _SectionTab(
                key: Key('si-review-${a.table.name}'),
                icon: importRoleIcon(a.role),
                label: keys.where((k) => k.role == a.role).length > 1
                    ? a.table.name.split(' · ').last
                    : _t('si3Short_${_sectionOf(a.role)}'),
                n: s.reviews[a]!.acceptedCount,
                on: a == cur,
                onTap: () => setState(() => _current = a),
              ),
            ),
            if (a != keys.last) const SizedBox(width: 6),
          ],
        ]),
      ),
      Expanded(
        child: ImportReviewView(
          key: ValueKey(cur),
          review: s.reviews[cur]!,
          images: s.images,
          currencies: _enabled,
          chooseCurrency: _chooseCurrency,
          onColumns: _busy ? null : () => _editColumns(cur),
          onChanged: () => setState(() {}),
        ),
      ),
      _BottomBar(
        child: Row(children: [
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_t('siWillAdd', {'n': '$total'}),
                  style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800, color: _green, fontSize: 14.5)),
              if (blocked > 0)
                Text(_t('si3NotAdded', {'n': '$blocked'}),
                    style: const TextStyle(fontFamily: _font, fontSize: 11.5, color: _red, fontWeight: FontWeight.w700)),
            ]),
          ),
          const SizedBox(width: 10),
          // A bounded width: the app's buttons are as wide as they may be
          // (an unbounded Row made the whole screen blank).
          SizedBox(
            width: 150,
            height: 48,
            child: FilledButton.icon(
              key: const Key('si-next'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 48),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: _busy || total == 0 ? null : () => setState(() => _step = 3),
              icon: const Icon(Icons.arrow_forward_rounded, size: 19),
              label: Text(_t('si3Next'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
            ),
          ),
        ]),
      ),
    ]);
  }

  Widget _confirmStep() {
    final s = _session;
    if (s == null || s.reviews.isEmpty) return const SizedBox.shrink();
    final total = s.readyCount;
    final bySection = <String, List<ImportReview>>{};
    for (final e in s.reviews.entries) {
      (bySection[_sectionOf(e.key.role)] ??= []).add(e.value);
    }
    String money(int minor) {
      final neg = minor < 0;
      final a = minor.abs();
      final whole = '${a ~/ 100}'.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
      return '${neg ? '-' : ''}$whole.${(a % 100).toString().padLeft(2, '0')}';
    }

    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 20), children: [
          _SettingChip(
              icon: Icons.storefront_rounded,
              label: _t('si3TargetLabel'),
              value: BranchScope.branchName ?? _t('si3TargetCurrent'),
              showArrow: false),
          const SizedBox(height: 8),
          _SettingChip(
              icon: Icons.description_outlined,
              label: _t('si3FileLabel'),
              value: _file?.uri.pathSegments.last ?? '',
              showArrow: false),
          const SizedBox(height: 14),
          for (final section in const ['accounts', 'products', 'customers', 'suppliers'])
            if (bySection[section] case final reviews?)
              Builder(builder: (_) {
                final ok = reviews.fold<int>(0, (a, r) => a + r.acceptedCount);
                final no = reviews.fold<int>(0, (a, r) => a + r.skippedCount);
                final present = reviews.fold<int>(0, (a, r) => a + r.countOf(RowStatus.present));
                final elsewhere = reviews.fold<int>(0, (a, r) => a + r.countOf(RowStatus.elsewhere));
                final totals = <String, int>{};
                for (final r in reviews) {
                  final p = r.toPreview();
                  for (final m in p.totals.values) {
                    m.forEach((c, v) => totals[c] = (totals[c] ?? 0) + v);
                  }
                  for (final a in p.accounts) {
                    totals[a.currency] = (totals[a.currency] ?? 0) + a.amountMinor;
                  }
                }
                return Container(
                  key: Key('si-confirm-$section'),
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(importRoleIcon(reviews.first.target == ImportTarget.accounts
                          ? TableRole.accounts
                          : reviews.first.target == ImportTarget.products
                              ? TableRole.products
                              : section == 'customers'
                                  ? TableRole.customers
                                  : TableRole.suppliers),
                          color: AppColors.primary, size: 22),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_t('si3Section_$section'),
                            style: const TextStyle(fontFamily: _font, fontSize: 15, fontWeight: FontWeight.w800)),
                      ),
                      Text('$ok', style: const TextStyle(fontFamily: _font, fontSize: 18, fontWeight: FontWeight.w800, color: _green)),
                    ]),
                    if (present > 0)
                      _StatusLine(icon: Icons.verified_rounded, color: _blue, text: _t('si4PresentN', {'n': '$present'})),
                    if (elsewhere > 0)
                      _StatusLine(
                          icon: Icons.call_split_rounded,
                          color: AppColors.textSecondary,
                          text: _t('si4ElsewhereN', {'n': '$elsewhere'})),
                    if (no > 0) _StatusLine(icon: Icons.error_outline_rounded, color: _red, text: _t('si3NotAdded', {'n': '$no'})),
                    for (final e in totals.entries)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('${money(e.value)} ${_curLabel(e.key)}',
                            textDirection: TextDirection.rtl,
                            style: TextStyle(fontFamily: _font, fontSize: 12.5, color: AppColors.textSecondary)),
                      ),
                  ]),
                );
              }),
          if (s.reviews.values.any((r) => r.countOf(RowStatus.elsewhere) > 0) && s.sourceBranch != null) ...[
            _Note(
                text: _t('si4ElsewhereHow', {'b': s.sourceBranch!}),
                color: AppColors.textSecondary,
                icon: Icons.call_split_rounded),
            const SizedBox(height: 8),
          ],
          _Note(text: _t('si3OnlyFour'), color: AppColors.textSecondary, icon: Icons.info_outline_rounded),
        ]),
      ),
      _BottomBar(
        child: _primary(
          key: const Key('si-apply'),
          label: _t('siImport', {'n': '$total'}),
          icon: Icons.fingerprint_rounded,
          onPressed: _busy || total == 0 ? null : _apply,
        ),
      ),
    ]);
  }
}

// ── pieces ──────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.step, required this.onClose, this.onStep, this.trailing});
  final int step;
  final VoidCallback onClose;
  final void Function(int)? onStep;

  /// «تحليل سارة» (on the end side of the title).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 12, 12),
            child: Column(children: [
              Row(children: [
                IconButton(
                    key: const Key('si-close'),
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded, color: Colors.white)),
                Expanded(
                  child: Text(_t('siTitle'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: _font, fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white)),
                ),
                if (trailing != null) trailing!,
              ]),
              const SizedBox(height: 4),
              _Steps(step: step, onTap: onStep),
            ]),
          ),
        ),
      );
}

class _Steps extends StatelessWidget {
  const _Steps({required this.step, this.onTap});
  final int step;
  final void Function(int)? onTap;
  @override
  Widget build(BuildContext context) => Row(children: [
        for (var i = 0; i < 4; i++) ...[
          Expanded(
            child: InkWell(
              key: Key('si-step-$i'),
              borderRadius: BorderRadius.circular(12),
              onTap: onTap == null ? null : () => onTap!(i),
              child: Column(children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: i <= step ? 1 : .28),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 6),
                Text(_t('si3Step$i'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: _font,
                        fontSize: 11.5,
                        fontWeight: i == step ? FontWeight.w800 : FontWeight.w600,
                        color: Colors.white.withValues(alpha: i <= step ? 1 : .7))),
              ]),
            ),
          ),
          if (i < 3) const SizedBox(width: 6),
        ],
      ]);
}

class _Count extends StatelessWidget {
  const _Count({required this.icon, required this.n, required this.label});
  final IconData icon;
  final int n;
  final String label;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(children: [
          Icon(icon, size: 18, color: n > 0 ? AppColors.primary : AppColors.textSecondary),
          const SizedBox(height: 2),
          FittedBox(
            child: Text('$n',
                style: TextStyle(
                    fontFamily: _font,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: n > 0 ? AppColors.textPrimary : AppColors.textSecondary)),
          ),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: _font, fontSize: 11, color: AppColors.textSecondary)),
        ]),
      );
}

class _SettingChip extends StatelessWidget {
  const _SettingChip(
      {super.key,
      required this.icon,
      required this.label,
      required this.value,
      this.onTap,
      this.warn = false,
      this.showArrow = true,
      this.leading});
  final IconData icon;

  /// Shown instead of the icon (a currency's flag).
  final Widget? leading;
  final String label, value;
  final VoidCallback? onTap;

  /// Still to be chosen (shown in the warning colour).
  final bool warn;
  final bool showArrow;
  @override
  Widget build(BuildContext context) => Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16), border: Border.all(color: warn ? _yellow : AppColors.border)),
            child: Row(children: [
              leading ?? Icon(icon, size: 20, color: warn ? _yellow : AppColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: TextStyle(fontFamily: _font, fontSize: 11, color: AppColors.textSecondary)),
                  Text(value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: _font, fontSize: 13, fontWeight: FontWeight.w800, color: warn ? _yellow : null)),
                ]),
              ),
              if (showArrow && onTap != null) Icon(Icons.expand_more_rounded, color: AppColors.textSecondary),
            ]),
          ),
        ),
      );
}

/// One line of a section's summary (already there, other branches…).
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: TextStyle(fontFamily: _font, fontSize: 12, color: color, fontWeight: FontWeight.w700)),
          ),
        ]),
      );
}

/// A section of the review (icon, short name, how many will be added).
class _SectionTab extends StatelessWidget {
  const _SectionTab({super.key, required this.icon, required this.label, required this.n, required this.on, this.onTap});
  final IconData icon;
  final String label;
  final int n;
  final bool on;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: on ? AppColors.primary : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: on ? AppColors.primary : AppColors.border),
            ),
            child: Column(children: [
              Icon(icon, size: 19, color: on ? Colors.white : AppColors.primary),
              const SizedBox(height: 2),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: _font, fontSize: 11.5, fontWeight: FontWeight.w800, color: on ? Colors.white : null)),
              Text('$n',
                  style: TextStyle(
                      fontFamily: _font, fontSize: 12, fontWeight: FontWeight.w800, color: on ? Colors.white : _green)),
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
  const _TableCard(
      {super.key,
      required this.analysis,
      this.rows,
      this.children = const [],
      this.onRole,
      this.onColumns,
      this.bySara = false,
      this.onUndoSara});

  /// Sara changed this table: marked, with one tap back to the system's.
  final bool bySara;
  final VoidCallback? onUndoSara;
  final TableAnalysis analysis;
  final int? rows;
  final List<TableAnalysis> children;
  final Future<void> Function(TableAnalysis)? onRole;
  final Future<void> Function(TableAnalysis)? onColumns;

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
                Text(
                  [
                    if (rows != null) _t('si2RowsN', {'n': '$rows'}),
                    _t('siColumnsCount', {'n': '${a.table.columns.length}'}),
                  ].join(' · '),
                  style: TextStyle(fontFamily: _font, fontSize: 11.5, color: AppColors.textSecondary),
                ),
              ]),
            ),
            const SizedBox(width: 6),
            _RoleChip(key: Key('si-dest-${a.table.name}'), role: a.role, onTap: onRole == null ? null : () => onRole!(a)),
          ]),
          if (bySara) ...[
            const SizedBox(height: 8),
            Container(
              key: Key('si-bysara-${a.table.name}'),
              padding: const EdgeInsetsDirectional.fromSTEB(4, 4, 4, 4),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: .06),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(children: [
                const SaraAvatar(size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_t('si4BySara'),
                      style: const TextStyle(
                          fontFamily: _font, fontSize: 12, fontWeight: FontWeight.w800, color: AppColors.primary)),
                ),
                TextButton.icon(
                  key: Key('si-sara-undo-${a.table.name}'),
                  style: TextButton.styleFrom(minimumSize: const Size(0, 32), padding: const EdgeInsets.symmetric(horizontal: 10)),
                  onPressed: onUndoSara,
                  icon: const Icon(Icons.undo_rounded, size: 17),
                  label: Text(_t('si4UndoSara'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
                ),
              ]),
            ),
          ],
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
                  minimumSize: const Size(0, 42),
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

/// One FYONA branch the import can go to (a tap switches to it).
class _BranchCard extends StatelessWidget {
  const _BranchCard({super.key, required this.name, required this.on, this.onTap});
  final String name;
  final bool on;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: on ? AppColors.primary.withValues(alpha: .07) : AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: on ? null : onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: on ? AppColors.primary : AppColors.border, width: on ? 1.6 : 1),
            ),
            child: Row(children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                    color: on ? AppColors.primary : AppColors.primary.withValues(alpha: .09), shape: BoxShape.circle),
                child: Icon(Icons.storefront_rounded, size: 19, color: on ? Colors.white : AppColors.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(name,
                    maxLines: 2,
                    style: TextStyle(
                        fontFamily: _font, fontSize: 14, fontWeight: on ? FontWeight.w800 : FontWeight.w600, height: 1.3)),
              ),
              Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: on ? AppColors.primary : AppColors.textSecondary),
            ]),
          ),
        ),
      );
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
  const _CurrencyPicker({required this.current, this.enabled = const []});
  final String? current;

  /// The currencies of the branch the data goes to (only these are
  /// offered: a record is saved only in one of them).
  final List<String> enabled;
  @override
  Widget build(BuildContext context) {
    final codes = enabled.isNotEmpty ? enabled : importCurrencies;
    return SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const _Grip(),
        _SheetTitle(icon: Icons.payments_rounded, title: _t('si2CurrencyTitle'), hint: _t('si3CurrencyHint')),
        Flexible(
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(14, 2, 14, 16), children: [
            for (final c in codes)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: c == current ? AppColors.primary.withValues(alpha: .07) : AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    key: Key('si-cur-$c'),
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => Navigator.pop(context, c),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: c == current ? AppColors.primary : AppColors.border, width: c == current ? 1.6 : 1),
                      ),
                      child: Row(children: [
                        bizCurrencyFlag(c, size: 38),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(_curLabel(c),
                              style: const TextStyle(fontFamily: _font, fontSize: 15, fontWeight: FontWeight.w800)),
                        ),
                        if (c == current) const Icon(Icons.check_circle_rounded, color: AppColors.primary),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ]),
    );
  }
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
class ImportReviewView extends StatefulWidget {
  const ImportReviewView({
    super.key,
    required this.review,
    required this.onChanged,
    this.images,
    this.skipped = const [],
    this.currencies = const [],
    this.chooseCurrency,
    this.onColumns,
  });
  final ImportReview review;
  final ImportImages? images;
  final List<String> skipped;
  final VoidCallback onChanged;

  /// The business's currencies, and how one is chosen (a sheet).
  final List<String> currencies;
  final Future<String?> Function(String? current)? chooseCurrency;

  /// Swap / change which column is which field.
  final VoidCallback? onColumns;
  @override
  State<ImportReviewView> createState() => _ImportReviewViewState();
}

/// The review as FYONA shows records: one card per row (picture first,
/// then the name and what matters), four clear groups — will be added,
/// already in FYONA, other branches of the file, not added — search,
/// sort, edit in a sheet, choose several. Built lazily (tens of
/// thousands of rows), never scrolled sideways.
class _ImportReviewViewState extends State<ImportReviewView> {
  RowStatus _status = RowStatus.add;
  String _query = '';
  String? _reason;
  final _selected = <int>{};
  late List<ReviewRow> _shown;
  Timer? _typing;
  String? _sortBy;
  bool _sortUp = true;

  ImportReview get r => widget.review;

  @override
  void didUpdateWidget(ImportReviewView old) {
    super.didUpdateWidget(old);
    if (old.review != widget.review) _selected.clear();
    _filter();
  }

  @override
  void initState() {
    super.initState();
    _filter();
  }

  @override
  void dispose() {
    _typing?.cancel();
    super.dispose();
  }

  void _filter() {
    final q = importFold(_query);
    _shown = [
      for (final row in r.rows)
        if (row.status == _status &&
            (_reason == null || (row.reasons.isNotEmpty ? row.reasons.first : 'rejected_by_user') == _reason) &&
            (q.isEmpty || row.values.values.any((v) => v != null && importFold(v).contains(q))))
          row,
    ];
    final by = _sortBy;
    if (by != null) {
      int cmp(ReviewRow a, ReviewRow b) {
        final x = a[by], y = b[by];
        if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1;
        final nx = double.tryParse(importDecimal(x) ?? ''), ny = double.tryParse(importDecimal(y) ?? '');
        final c = nx != null && ny != null ? nx.compareTo(ny) : importFold(x).compareTo(importFold(y));
        return _sortUp ? c : -c;
      }

      _shown.sort(cmp);
    }
  }

  void _show(RowStatus st) {
    _status = st;
    _reason = null;
    _selected.clear();
    setState(_filter);
  }

  void _sort(String field) => setState(() {
        if (_sortBy == field) {
          _sortUp = !_sortUp;
        } else {
          _sortBy = field;
          _sortUp = true;
        }
        _filter();
      });

  Future<void> _bulkCurrency() async {
    final code = await widget.chooseCurrency?.call(null);
    if (code == null) return;
    r.setCurrency(r.rows.where((e) => _selected.contains(e.row)), code);
    _selected.clear();
    _changed();
  }

  void _bulkRename() {
    r.renameExisting(r.rows.where((e) => _selected.contains(e.row)));
    _selected.clear();
    _changed();
  }

  void _changed() {
    if (mounted) setState(_filter);
    widget.onChanged();
  }

  Future<void> _editCell(ReviewRow row, String field) async {
    if (field == 'currency' && widget.chooseCurrency != null) {
      final code = await widget.chooseCurrency!(row[field]);
      if (code == null) return;
      r.setCurrency([row], code);
      _changed();
      return;
    }
    final ctrl = TextEditingController(text: row[field] ?? '');
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(_t('siField_$field'), style: const TextStyle(fontFamily: _font, fontSize: 15, fontWeight: FontWeight.w800)),
        content: TextField(key: const Key('si-edit-field'), controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_t('cancel'))),
          FilledButton(
              key: const Key('si-edit-save'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: Text(_t('save'))),
        ],
      ),
    );
    if (v == null) return;
    r.edit(row, field, v);
    _changed();
  }

  /// The fields of this section shown in a row's sheet (branch only
  /// chooses rows: never saved, never shown).
  List<String> get _fields => [
        for (final f in importFields[r.target]!)
          if (f.key != 'branch' &&
              (r.mapping.containsKey(f.key) || f.key == 'currency' || (f.key == 'image' && r.blobImages)))
            f.key,
      ];

  static const _statusColor = {
    RowStatus.add: _green,
    RowStatus.present: _blue,
    RowStatus.elsewhere: Color(0xFF6B7280),
    RowStatus.skipped: _red,
  };
  static const _statusIcon = {
    RowStatus.add: Icons.check_circle_rounded,
    RowStatus.present: Icons.verified_rounded,
    RowStatus.elsewhere: Icons.call_split_rounded,
    RowStatus.skipped: Icons.error_outline_rounded,
  };
  static const _statusKey = {
    RowStatus.add: 'si-tab-add',
    RowStatus.present: 'si-tab-present',
    RowStatus.elsewhere: 'si-tab-elsewhere',
    RowStatus.skipped: 'si-tab-refused',
  };

  @override
  Widget build(BuildContext context) {
    final counts = {for (final st in RowStatus.values) st: r.countOf(st)};
    final tabs = [for (final st in RowStatus.values) if (st == RowStatus.add || counts[st]! > 0) st];
    final reasons = _status == RowStatus.skipped ? r.refusedByReason : const <String, int>{};
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
        child: Row(children: [
          for (final st in tabs) ...[
            Expanded(child: _tab(st, counts[st]!)),
            if (st != tabs.last) const SizedBox(width: 6),
          ],
        ]),
      ),
      if (_status != RowStatus.add)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
          child: _hint(switch (_status) {
            RowStatus.present => _t('si4PresentHint'),
            RowStatus.elsewhere => _t('si4ElsewhereHint'),
            _ => [
                for (final t in widget.skipped) t,
                if (r.unusedColumns.isNotEmpty) _t('siSkippedColumns', {'c': r.unusedColumns.join('، ')}),
                if (widget.skipped.isEmpty && r.unusedColumns.isEmpty) _t('si4SkippedHint'),
              ].join('\n'),
          }, _statusColor[_status]!),
        ),
      if (reasons.length > 1)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final e in reasons.entries)
              FilterChip(
                key: Key('si-reason-${e.key}'),
                visualDensity: VisualDensity.compact,
                label: Text('${_t('siIssue_${e.key}')} (${e.value})', style: const TextStyle(fontFamily: _font, fontSize: 12)),
                selected: _reason == e.key,
                onSelected: (v) => setState(() {
                  _reason = v ? e.key : null;
                  _filter();
                }),
              ),
          ]),
        )
      else if (reasons.length == 1)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text('${_t('siIssue_${reasons.keys.first}')} (${reasons.values.first})',
                key: Key('si-reason-${reasons.keys.first}'),
                style: const TextStyle(fontFamily: _font, fontSize: 12.5, color: _red, fontWeight: FontWeight.w800)),
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 2),
        child: Row(children: [
          Expanded(
            child: SizedBox(
              height: 44,
              child: TextField(
                key: const Key('si-search'),
                style: const TextStyle(fontFamily: _font, fontSize: 13.5),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: AppColors.surface,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  hintText: _t('siSearch'),
                  hintStyle: TextStyle(fontFamily: _font, fontSize: 13, color: AppColors.textSecondary),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: AppColors.border)),
                  enabledBorder:
                      OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: AppColors.border)),
                ),
                onChanged: (v) {
                  _typing?.cancel();
                  _typing = Timer(const Duration(milliseconds: 250), () {
                    if (!mounted) return;
                    setState(() {
                      _query = v;
                      _filter();
                    });
                  });
                },
              ),
            ),
          ),
          PopupMenuButton<String>(
            key: const Key('si-sort'),
            tooltip: _t('si4Sort'),
            icon: Icon(Icons.sort_rounded, color: _sortBy == null ? AppColors.textSecondary : AppColors.primary),
            onSelected: _sort,
            itemBuilder: (_) => [
              for (final f in _fields)
                if (f != 'image')
                  PopupMenuItem(
                    key: Key('si-sort-$f'),
                    value: f,
                    child: Row(children: [
                      Expanded(child: Text(_t('siField_$f'), style: const TextStyle(fontFamily: _font))),
                      if (_sortBy == f)
                        Icon(_sortUp ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                            size: 16, color: AppColors.primary),
                    ]),
                  ),
            ],
          ),
          if (widget.onColumns != null)
            IconButton(
              key: const Key('si-swap-columns'),
              tooltip: _t('si3SwapColumns'),
              onPressed: widget.onColumns,
              icon: const Icon(Icons.swap_horiz_rounded, color: AppColors.primary),
            ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 6, 0),
        child: Row(children: [
          Expanded(
            child: Text(_t('siShowing', {'n': '${_shown.length}'}),
                style: TextStyle(fontFamily: _font, fontSize: 11.5, color: AppColors.textSecondary)),
          ),
          TextButton(
            key: const Key('si-select-all'),
            style: TextButton.styleFrom(minimumSize: const Size(0, 34), padding: const EdgeInsets.symmetric(horizontal: 8)),
            onPressed: () => setState(() {
              if (_selected.length == _shown.length && _shown.isNotEmpty) {
                _selected.clear();
              } else {
                _selected
                  ..clear()
                  ..addAll(_shown.map((e) => e.row));
              }
            }),
            child: Text(_selected.isNotEmpty && _selected.length == _shown.length ? _t('si4SelectNone') : _t('siSelectAll'),
                style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700, fontSize: 12.5)),
          ),
        ]),
      ),
      if (_selected.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            if (_status == RowStatus.add || (_status == RowStatus.skipped))
              _bulk(
                  'si-bulk',
                  _status == RowStatus.skipped ? Icons.undo_rounded : Icons.remove_circle_outline_rounded,
                  _status == RowStatus.skipped
                      ? _t('siApproveSel', {'n': '${_selected.length}'})
                      : _t('siRejectSel', {'n': '${_selected.length}'}), () {
                final rows = r.rows.where((e) => _selected.contains(e.row));
                r.setRejected(rows, _status != RowStatus.skipped);
                _selected.clear();
                _changed();
              }),
            if (widget.chooseCurrency != null && _status != RowStatus.elsewhere)
              _bulk('si-bulk-currency', Icons.payments_rounded, _t('si3SetCurrency', {'n': '${_selected.length}'}), _bulkCurrency),
            if (r.target != ImportTarget.accounts &&
                r.rows.any((e) => _selected.contains(e.row) && e.reasons.contains('exists')))
              _bulk('si-bulk-rename', Icons.drive_file_rename_outline_rounded, _t('si3RenameNew'), _bulkRename),
          ]),
        ),
      Expanded(
        child: _shown.isEmpty
            ? Center(
                child: Text(_t('si4Empty'),
                    style: TextStyle(fontFamily: _font, fontSize: 13, color: AppColors.textSecondary)),
              )
            : ListView.builder(
                key: const Key('si-rows'),
                padding: const EdgeInsets.fromLTRB(10, 2, 10, 16),
                itemExtent: 92,
                itemCount: _shown.length,
                itemBuilder: (context, i) => _card(_shown[i]),
              ),
      ),
    ]);
  }

  Widget _tab(RowStatus st, int n) {
    final on = _status == st;
    final c = _statusColor[st]!;
    return InkWell(
      key: Key(_statusKey[st]!),
      onTap: () => _show(st),
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
        decoration: BoxDecoration(
          color: on ? c : AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: on ? c : AppColors.border),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(_statusIcon[st], size: 15, color: on ? Colors.white : c),
            const SizedBox(width: 4),
            Text('$n', style: TextStyle(fontFamily: _font, fontWeight: FontWeight.w800, fontSize: 13.5, color: on ? Colors.white : c)),
          ]),
          Text(_t('si4Tab_${st.name}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: _font, fontSize: 11, fontWeight: FontWeight.w700, color: on ? Colors.white : c)),
        ]),
      ),
    );
  }

  Widget _hint(String text, Color c) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: c.withValues(alpha: .08), borderRadius: BorderRadius.circular(12)),
        child: Text(text,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontFamily: _font, fontSize: 12, color: c, height: 1.45, fontWeight: FontWeight.w600)),
      );

  Widget _bulk(String key, IconData icon, String label, VoidCallback onTap) => ActionChip(
        key: Key(key),
        avatar: Icon(icon, size: 17, color: AppColors.primary),
        label: Text(label, style: const TextStyle(fontFamily: _font, fontSize: 12.5, fontWeight: FontWeight.w700)),
        onPressed: onTap,
      );

  String _cur(ReviewRow row) => _curLabel(row['currency'] ?? r.defaultCurrency ?? '—');

  /// What matters of a row, in one line (the rest is in its sheet).
  String _facts(ReviewRow row) {
    String? money(String? v) => v == null ? null : '$v ${_cur(row)}';
    final parts = switch (r.target) {
      ImportTarget.products => [
          row['barcode'],
          money(row['sale_price']),
          if (row['stock'] != null) '${_t('siField_stock')}: ${row['stock']}',
          if (row.units.isNotEmpty) _t('si4UnitsN', {'n': '${row.units.length}'}),
        ],
      ImportTarget.parties => [
          row['phone'],
          money(row['balance'] ?? row['debit'] ?? row['credit']),
          for (final (c, minor) in row.more) '+ ${(minor / 100).toStringAsFixed(2)} ${_curLabel(c ?? r.defaultCurrency ?? '—')}',
        ],
      ImportTarget.accounts => [row['bank'], money(row['balance'])],
    };
    return parts.whereType<String>().where((x) => x.trim().isNotEmpty).join('  ·  ');
  }

  String _note(ReviewRow row) => row.accepted
      ? [for (final w in row.warnings) if (w != 'multi_currency') _t('siIssue_$w')].join(' · ')
      : [for (final x in row.reasons.isEmpty ? ['rejected_by_user'] : row.reasons) _t('siIssue_$x')].join(' · ');

  IconData get _sectionIcon => switch (r.target) {
        ImportTarget.products => Icons.inventory_2_rounded,
        ImportTarget.accounts => Icons.account_balance_rounded,
        ImportTarget.parties => r.defaultKind == 'supplier' ? Icons.local_shipping_rounded : Icons.person_rounded,
      };

  Widget _card(ReviewRow row) {
    final st = row.status;
    final c = _statusColor[st]!;
    final picked = _selected.contains(row.row);
    final note = _note(row);
    final facts = _facts(row);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: picked ? AppColors.primary.withValues(alpha: .07) : AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: Key('si-row-${row.row}'),
          borderRadius: BorderRadius.circular(16),
          onTap: _selected.isNotEmpty ? () => _toggle(row) : () => _openRow(row),
          onLongPress: () => _toggle(row),
          child: Container(
            padding: const EdgeInsetsDirectional.fromSTEB(0, 8, 10, 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              // One colour all round (rounded corners need it); the row's
              // state is the strip at its start.
              border: Border.all(color: picked ? AppColors.primary : AppColors.border),
            ),
            child: Row(children: [
              Container(
                width: 4,
                margin: const EdgeInsetsDirectional.only(end: 6),
                decoration: BoxDecoration(
                  color: st == RowStatus.add ? Colors.transparent : c,
                  borderRadius: const BorderRadiusDirectional.horizontal(end: Radius.circular(4)),
                ),
              ),
              if (_selected.isNotEmpty)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: Icon(picked ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                      color: picked ? AppColors.primary : AppColors.textSecondary),
                ),
              _thumb(row),
              const SizedBox(width: 10),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(row['name'] ?? '—',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontFamily: _font,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: row['name'] == null ? AppColors.textSecondary : null)),
                  if (facts.isNotEmpty)
                    Text(facts,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontFamily: _font, fontSize: 12, color: AppColors.textSecondary)),
                  if (note.isNotEmpty)
                    Row(children: [
                      Icon(st == RowStatus.add ? Icons.info_outline_rounded : _statusIcon[st], size: 13, color: st == RowStatus.add ? _yellow : c),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(note,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontFamily: _font,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: st == RowStatus.add ? _yellow : c)),
                      ),
                    ]),
                ]),
              ),
              Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary, size: 20),
            ]),
          ),
        ),
      ),
    );
  }

  void _toggle(ReviewRow row) => setState(() => _selected.contains(row.row) ? _selected.remove(row.row) : _selected.add(row.row));

  Widget _thumb(ReviewRow row, {double size = 50}) {
    final img = row['image'];
    final pic = img == null ? null : _picture(img, size);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: pic ?? Icon(_sectionIcon, color: AppColors.primary, size: size * .46),
    );
  }

  /// One row in full: every field (tap to edit), its units / codes /
  /// prices, and what can be done with it.
  Future<void> _openRow(ReviewRow row) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.background,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
        builder: (ctx) => StatefulBuilder(builder: (ctx, refresh) {
          Future<void> edit(String f) async {
            await _editCell(row, f);
            refresh(() {});
          }

          final st = row.status;
          final note = _note(row);
          return FractionallySizedBox(
            heightFactor: .86,
            child: SafeArea(
              child: Column(children: [
                const _Grip(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Row(children: [
                    _thumb(row, size: 58),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(row['name'] ?? '—',
                            style: const TextStyle(fontFamily: _font, fontSize: 16, fontWeight: FontWeight.w800, height: 1.35)),
                        Container(
                          margin: const EdgeInsets.only(top: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                              color: _statusColor[st]!.withValues(alpha: .1), borderRadius: BorderRadius.circular(10)),
                          child: Text(_t('si4Tab_${st.name}'),
                              style: TextStyle(
                                  fontFamily: _font, fontSize: 11.5, fontWeight: FontWeight.w800, color: _statusColor[st])),
                        ),
                      ]),
                    ),
                  ]),
                ),
                if (note.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _hint(note, st == RowStatus.add ? _yellow : _statusColor[st]!),
                  ),
                Expanded(
                  child: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 12), children: [
                    for (final f in _fields)
                      if (f != 'image')
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: ListTile(
                            tileColor: AppColors.surface,
                            key: Key('si-cell-${row.row}-$f'),
                            dense: true,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14), side: BorderSide(color: AppColors.border)),
                            title: Text(_t('siField_$f'),
                                style: TextStyle(fontFamily: _font, fontSize: 11.5, color: AppColors.textSecondary)),
                            subtitle: Row(children: [
                              if (f == 'currency' && (row[f] ?? r.defaultCurrency) != null)
                                Padding(
                                  padding: const EdgeInsetsDirectional.only(end: 6),
                                  child: bizCurrencyFlag((row[f] ?? r.defaultCurrency)!, size: 20),
                                ),
                              Expanded(
                                child: Text(f == 'currency' ? _cur(row) : (row[f] ?? '—'),
                                    style: TextStyle(
                                        fontFamily: _font,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        color: row[f] == null && f != 'currency' ? AppColors.textSecondary : AppColors.textPrimary)),
                              ),
                            ]),
                            trailing: const Icon(Icons.edit_rounded, size: 18, color: AppColors.primary),
                            onTap: st == RowStatus.elsewhere ? null : () => edit(f),
                          ),
                        ),
                    for (final u in row.units)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.straighten_rounded, color: AppColors.primary),
                        title: Text('${u['name'] ?? '—'} × ${u['factor'] ?? '1'}',
                            style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700)),
                        subtitle: Text([u['barcode'], u['sale_price'], u['cost_price']].whereType<String>().join(' · ')),
                      ),
                    for (final b in row.barcodes)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.qr_code_2_rounded, color: AppColors.primary),
                        title: Text(b),
                        trailing: row.droppedCodes.contains(b) ? const Icon(Icons.block_rounded, color: _yellow, size: 18) : null,
                      ),
                    for (final p in row.prices)
                      ListTile(
                        dense: true,
                        leading: bizCurrencyFlag('${p['currency']}', size: 26),
                        title: Text('${p['price'] ?? '—'} ${_curLabel('${p['currency']}')}',
                            style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w700)),
                      ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  child: Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                    if (st == RowStatus.add || (st == RowStatus.skipped && row.rejectedByUser))
                      OutlinedButton.icon(
                        key: const Key('si-row-toggle'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42)),
                        onPressed: () {
                          r.setRejected([row], st == RowStatus.add);
                          _changed();
                          refresh(() {});
                        },
                        icon: Icon(st == RowStatus.add ? Icons.remove_circle_outline_rounded : Icons.undo_rounded, size: 18),
                        label: Text(st == RowStatus.add ? _t('si4Exclude') : _t('si4Include'),
                            style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
                      ),
                    if (r.target != ImportTarget.accounts && row.reasons.contains('exists'))
                      OutlinedButton.icon(
                        key: const Key('si-row-rename'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42)),
                        onPressed: () {
                          r.renameExisting([row]);
                          _changed();
                          refresh(() {});
                        },
                        icon: const Icon(Icons.drive_file_rename_outline_rounded, size: 18),
                        label: Text(_t('si3RenameNew'), style: const TextStyle(fontFamily: _font, fontWeight: FontWeight.w800)),
                      ),
                  ]),
                ),
              ]),
            ),
          );
        }),
      );

  final _thumbs = <String, Uint8List?>{};
  final _loading = <String>{};
  Widget? _picture(String name, double size) {
    if (ImportImages.isBlob(name) && !_thumbs.containsKey(name)) {
      if (_loading.add(name)) {
        widget.images?.load(name).then((p) {
          if (mounted) setState(() => _thumbs[name] = p?.$1);
        });
      }
      return null;
    }
    final b = _thumbs.putIfAbsent(name, () => widget.images?.read(name)?.$1);
    if (b == null) return null;
    return Image.memory(b,
        width: size,
        height: size,
        cacheWidth: (size * 2.5).round(),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Icon(_sectionIcon, color: AppColors.primary, size: size * .46));
  }
}
