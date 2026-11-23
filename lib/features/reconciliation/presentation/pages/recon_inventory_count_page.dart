import 'dart:async';

import 'package:flutter/material.dart';
import '../../../core_business/presentation/widgets/business_number_field.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/services/units/custom_units.dart';
import '../../../../core/services/units/unit_breakdown.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/services/scan_sfx.dart';
import '../../../inventory/presentation/widgets/business_product_image.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../../inventory/presentation/providers/inventory_providers.dart';
import '../../../purchases/presentation/pages/barcode_scan_page.dart';
import '../../data/reconciliation_api.dart';
import '../widgets/recon_motion.dart';
import '../widgets/recon_widgets.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

final _countPhotoProvider = FutureProvider.autoDispose.family<
  String?, ({LocalReconciliationLink link, String productId})
>((ref, key) async {
  final api = ref.watch(reconciliationApiProvider);
  if (!ref.watch(localInventoryReconciliationAllowedProvider) ||
      !key.link.matches(api)) return null;
  return api.inventoryCountPhoto(key.link.ids, key.productId);
});

/// The counting sheet: product (image + name only — NO system quantity
/// anywhere) + one input box per unit (base unit + extra units), laid out in
/// a responsive wrap that survives products with many units. Bottom button
/// «تنفيذ المطابقة» → save → real check → 4s cinematic → result page.
class ReconInventoryCountPage extends ConsumerStatefulWidget {
  final Map<String, dynamic> record;
  final LocalReconciliationLink? localLink;
  const ReconInventoryCountPage({super.key, required this.record, this.localLink});

  @override
  ConsumerState<ReconInventoryCountPage> createState() =>
      _ReconInventoryCountPageState();
}

class _ReconInventoryCountPageState
    extends ConsumerState<ReconInventoryCountPage> {
  late Map<String, dynamic> _rec;
  late List<Map<String, dynamic>> _lines;
  Map<String, List<Map<String, dynamic>>> _units = {};
  final Map<String, TextEditingController> _boxes = {};
  // Linked counting: per product, EXACTLY ONE box holds the merchant's real
  // entry (the "active" unit); every other box is locked and shows the
  // computed equivalent — never an independent conflicting quantity.
  final Map<String, String?> _activeBox = {};
  final Map<String, double> _activeQty = {};
  final _searchCtrl = TextEditingController();
  String _search = '';
  bool _busy = false;
  late final ReconciliationApi _source;

  bool _canContinue(ReconciliationApi current) =>
      identical(_source, current) &&
      (widget.localLink?.matches(current) ?? !current.isDeviceLedger);

  bool get _active => mounted && _canContinue(ref.read(reconciliationApiProvider));

  List<Map<String, dynamic>> get _visibleLines {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return _lines;
    return [
      for (final l in _lines)
        if ('${l['name']}'.toLowerCase().contains(q) ||
            '${l['barcode'] ?? ''}'.toLowerCase().contains(q))
          l
    ];
  }

  Future<void> _scanBarcode() async {
    final l10n = AppLocalizations.of(context);
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => const BarcodeScanPage(),
    ));
    if (code == null || code.isEmpty || !_active) return;
    try {
      final res = await ref.read(inventoryApiProvider).resolveBarcode(code);
      if (!_active) return;
      final product = res['product'] as Map?;
      final pid = product == null ? null : '${product['id']}';
      final inList = pid != null &&
          _lines.any((l) => '${l['product_id']}' == pid);
      if (inList) {
        // Found inside THIS count — filter straight to it.
        final name = '${product!['name'] ?? ''}';
        _searchCtrl.text = name;
        setState(() => _search = name);
        return;
      }
      unawaited(ScanSfx.error());
      final isCategory = '${_rec['scope']}' == 'category';
      showFyonaSnack(
          context,
          isCategory
              ? l10n.translate('reconNotInCategory')
              : l10n.translate('reconNotInList'),
          success: false);
    } catch (_) {
      if (!_active) return;
      unawaited(ScanSfx.error());
      showFyonaSnack(context, l10n.translate('reconNotInList'),
          success: false);
    }
  }

  @override
  void initState() {
    super.initState();
    _source = ref.read(reconciliationApiProvider);
    _rec = Map<String, dynamic>.from(widget.record);
    _lines = [
      for (final l in (_rec['lines'] as List? ?? []).whereType<Map>())
        Map<String, dynamic>.from(l)
    ];
    _units = {
      for (final e in (_rec['units'] as Map? ?? {}).entries)
        '${e.key}': [
          for (final u in (e.value as List? ?? []).whereType<Map>())
            Map<String, dynamic>.from(u)
        ]
    };
    for (final l in _lines) {
      final pid = '${l['product_id']}';
      _boxes['$pid|'] = TextEditingController(); // base unit box
      for (final u in _units[pid] ?? const []) {
        _boxes['$pid|${u['unit_id']}'] = TextEditingController();
      }
    }
  }

  /// Boxes for one product: the base unit + ONLY the REAL extra units.
  /// A unit with factor 1 (or the same name as the base unit) is the base
  /// itself — showing it again produced the bogus duplicate «قطعة (1×0)».
  List<(String key, String label, double factor)> _boxesFor(
      Map<String, dynamic> line) {
    final pid = '${line['product_id']}';
    final baseName = '${line['unit'] ?? ''}'.trim();
    final out = <(String, String, double)>[('$pid|', baseName, 1.0)];
    for (final u in _units[pid] ?? const []) {
      final factor = ((u['factor'] ?? 1) as num).toDouble();
      final name = '${u['name'] ?? ''}'.trim();
      if (factor <= 1.0) continue;                 // not an extra unit
      if (name == baseName) continue;              // duplicate of the base
      out.add(('$pid|${u['unit_id']}', '$name (×${factor.toStringAsFixed(0)})', factor));
    }
    return out;
  }

  /// Display an equivalent quantity (up to 2 decimals, no trailing noise).
  String _fmtEq(double v) => _fmtEqStatic(v);

  Map<String, dynamic>? _lineOf(String pid) {
    for (final l in _lines) {
      if ('${l['product_id']}' == pid) return l;
    }
    return null;
  }

  List<UnitBreakdownInput> _breakdownInputs(
      String pid, Map<String, dynamic> line) {
    final baseName = '${line['unit'] ?? ''}'.trim();
    final inputs = <UnitBreakdownInput>[
      UnitBreakdownInput(
        name: baseName,
        factor: 1,
        group: unitGroupOfName(baseName) ?? 'count',
      ),
      for (final u in _units[pid] ?? const [])
        UnitBreakdownInput(
          name: '${u['name'] ?? ''}'.replaceAll(RegExp(r'\s*\([^)]*\)\s*$'), '').trim(),
          factor: ((u['factor'] ?? 1) as num).toDouble(),
          group: ('${u['group'] ?? ''}'.isNotEmpty
                  ? '${u['group']}'
                  : unitGroupOfName('${u['name'] ?? ''}')) ??
              'count',
        ),
    ];
    return inputs;
  }

  /// A locked box's equivalent, formatted by the unit's nature. Indivisible
  /// (`count`) units decompose through EVERY smaller unit, so a product with
  /// pack + carton + piece shows «1 كرتون + 4 باكيت + 3 قطعة» exactly, never a
  /// rounded decimal or a remainder in the wrong unit.
  String _equivalentFor(
      String pid, String key, double base, Map<String, dynamic> line) {
    final baseUnit = '${line['unit'] ?? ''}';
    final uid = key.contains('|') ? key.split('|').last : '';
    String unitName = baseUnit;
    double factor = 1;
    String? group;
    if (uid.isEmpty) {
      group = unitGroupOfName(baseUnit);
    } else {
      for (final u in _units[pid] ?? const []) {
        if ('${u['unit_id']}' == uid) {
          unitName = '${u['name'] ?? baseUnit}';
          factor = ((u['factor'] ?? 1) as num).toDouble();
          final g = '${u['group'] ?? ''}';
          group = g.isNotEmpty ? g : unitGroupOfName(unitName);
          break;
        }
      }
    }
    final cleanName =
        unitName.replaceAll(RegExp(r'\s*\([^)]*\)\s*$'), '').trim();
    if ((group ?? 'count') != 'count') {
      return '${_fmtEq(base / factor)} $cleanName'.trim();
    }
    final parts = decomposeCountUnits(
      base,
      _breakdownInputs(pid, line),
      fromFactor: factor,
    );
    if (parts.isNotEmpty) return formatUnitBreakdown(parts);
    return '${_fmtEq(base / factor)} $cleanName'.trim();
  }

  /// The user typed in [key] (factor [factor]): that box becomes the product's
  /// single real entry; the rest lock and show equivalents. Clearing the box
  /// reopens every field.
  void _onBoxChanged(String pid, String key, double factor, String text) {
    final t = text.trim().replaceAll(',', '');
    final line = _lineOf(pid);
    if (line == null) return;
    if (t.isEmpty) {
      _activeBox[pid] = null;
      _activeQty.remove(pid);
      for (final e in _boxes.entries) {
        if (e.key == pid || e.key.startsWith('$pid|')) e.value.clear();
      }
      if (mounted) setState(() {});
      return;
    }
    final q = double.tryParse(t);
    if (q == null || q < 0) {
      showFyonaSnack(context,
          AppLocalizations.of(context).translate('reconHowManyReal'),
          success: false);
      return;
    }
    _activeBox[pid] = key;
    _activeQty[pid] = q;
    final base = q * factor;
    for (final (k, _, _) in _boxesFor(line)) {
      if (k == key) continue;
      final c = _boxes[k];
      if (c != null) c.text = _equivalentFor(pid, k, base, line);
    }
    if (mounted) setState(() {});
  }

  Future<void> _run() async {
    if (_busy || !_active) return;
    final l10n = AppLocalizations.of(context);
    // SINGLE-ENTRY counts: only the active (user-typed) box per product is
    // sent. The locked boxes hold computed equivalents — never extra stock.
    final counts = <Map<String, dynamic>>[];
    for (final line in _lines) {
      final pid = '${line['product_id']}';
      final akey = _activeBox[pid];
      final aqty = _activeQty[pid];
      if (akey == null || aqty == null) continue;
      (String, String, double)? box;
      for (final b in _boxesFor(line)) {
        if (b.$1 == akey) box = b;
      }
      if (box == null) continue;
      final (key, label, _) = box;
      counts.add({
        'product_id': pid,
        'parts': [
          {
            'unit_id':
                key.contains('|') && key.split('|').last.isNotEmpty
                    ? key.split('|').last
                    : null,
            'unit_name': label,
            'qty': _source.isDeviceLedger
                ? _boxes[key]!.text.trim().replaceAll(',', '')
                : aqty,
          }
        ],
      });
    }
    if (counts.isEmpty) {
      showFyonaSnack(context, l10n.translate('reconHowManyReal'),
          success: false);
      return;
    }
    setState(() => _busy = true);
    final api = _source;
    final id = widget.localLink?.ids ?? '${_rec['id']}';
    // Create the save→check future ONCE (not inside the route builder) so a
    // rebuild can never fire a second save/check pair.
    final future = () async {
      await api.inventorySave(reconId: id, counts: counts);
      if (!_active) throw const DirectoryAccessDenied();
      return api.inventoryCheck(reconId: id);
    }();
    void openResult(Map<String, dynamic> result) =>
        context.push(RouteNames.reconciliationInventoryResult, extra: {
          'record': result,
          if (widget.localLink != null) 'local': widget.localLink!,
        });
    if (api.isDeviceLedger) {
      try {
        final checked = await future;
        if (_active) openResult(checked);
      } catch (e) {
        if (_active) showReconError(context, e);
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    unawaited(Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReconCoreOverlay(
        variant: switch ('${_rec['scope']}') {
          'product' => ReconSceneVariant.inventoryProduct,
          'category' => ReconSceneVariant.inventoryCategory,
          _ => ReconSceneVariant.inventoryFull,
        },
        processingText: l10n.translate('reconProcessing'),
        future: future,
        onResult: (_, result) {
          if (!mounted) return;
          setState(() => _busy = false);
          context.pop();
          if (_active) openResult(Map<String, dynamic>.from(result as Map));
        },
        onError: (_, e) {
          if (mounted) {
            setState(() => _busy = false);
            context.pop();
            showReconError(context, e);
          }
        },
      ),
    )));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    for (final c in _boxes.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _emptyCategory(AppLocalizations l10n) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 74,
            height: 74,
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(14),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.inventory_2_outlined,
                size: 34, color: AppColors.primary),
          ),
          const SizedBox(height: 16),
          Text(l10n.translate('reconCategoryEmptyTitle'),
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 6),
          Text(l10n.translate('reconCategoryEmptyBody'),
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 12.5,
                  height: 1.5,
                  color: AppColors.textSecondary)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(reconciliationApiProvider);
    final allowed = (!current.isDeviceLedger ||
        ref.watch(localInventoryReconciliationAllowedProvider)) && _canContinue(current);
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          color: AppColors.textPrimary,
          onPressed: () => reconBack(context),
        ),
        title: Text(l10n.translate('reconHowManyReal'),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 15),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
      ),
      body: !allowed
          ? Center(child: Text(reconErrorMessage(l10n, const DirectoryAccessDenied())))
          : SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(children: [
              Expanded(
                child: FyonaTextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _search = v.trim()),
                  style: const TextStyle(fontFamily: 'Cairo'),
                  decoration: InputDecoration(
                    hintText: l10n.translate('reconSearchBarcodeHint'),
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: _scanBarcode,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(18),
                    borderRadius: BorderRadius.circular(12),
                    border:
                        Border.all(color: AppColors.primary.withAlpha(90)),
                  ),
                  child: const Icon(Icons.qr_code_scanner_rounded,
                      color: AppColors.primary),
                ),
              ),
            ]),
          ),
          Expanded(
            child: _lines.isEmpty
                ? _emptyCategory(l10n)
                : _visibleLines.isEmpty
                    ? Center(
                        child: Text(l10n.translate('invNoProducts'),
                            style: const TextStyle(fontFamily: 'Cairo')))
                    : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    itemCount: _visibleLines.length,
                     itemBuilder: (_, i) => _CountCard(
                       line: _visibleLines[i],
                       localLink: widget.localLink,
                      boxes: _boxesFor(_visibleLines[i]),
                      controllers: _boxes,
                      activeKey:
                          _activeBox['${_visibleLines[i]['product_id']}'],
                      onBoxChanged: (key, factor, text) => _onBoxChanged(
                          '${_visibleLines[i]['product_id']}',
                          key,
                          factor,
                          text),
                    ),
                  ),
          ),
          Container(
            padding: EdgeInsets.fromLTRB(
                16, 10, 16, 12 + MediaQuery.of(context).padding.bottom),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border(
                  top: BorderSide(color: AppColors.border, width: .5)),
            ),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                onPressed: _busy || _lines.isEmpty ? null : _run,
                icon: const Icon(Icons.play_circle_fill_rounded),
                label: Text(l10n.translate('reconRunMatch'),
                    style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontWeight: FontWeight.w800,
                        fontSize: 15)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// One product card: image + name, a responsive wrap of unit boxes, and the
/// single converted base total. Typing in ANY box locks the rest (they show
/// computed equivalents); clearing reopens every box.
class _CountCard extends StatelessWidget {
  final Map<String, dynamic> line;
  final List<(String, String, double)> boxes;
  final Map<String, TextEditingController> controllers;
  final String? activeKey;
  final void Function(String key, double factor, String text) onBoxChanged;
  final LocalReconciliationLink? localLink;
  const _CountCard(
      {required this.line,
      required this.boxes,
      required this.controllers,
      required this.activeKey,
      this.localLink,
      required this.onBoxChanged});

  @override
  Widget build(BuildContext context) {
    final img = line['image']?.toString() ?? '';
    final fallback = Container(
      color: AppColors.surfaceVariant.withAlpha(80),
      child: Icon(Icons.inventory_2_outlined, size: 22, color: AppColors.textSecondary),
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(children: [
        Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 48,
              height: 48,
               child: localLink != null
                   ? Consumer(builder: (context, ref, _) {
                       final photo = ref.watch(_countPhotoProvider(
                         (link: localLink!, productId: '${line['product_id']}'),
                       )).asData?.value;
                       return photo == null ? fallback : BusinessProductImage(
                         url: photo, width: 48, height: 48, placeholder: fallback,
                       );
                     })
                   : img.isEmpty ? fallback : BusinessProductImage(url: img, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text('${line['name'] ?? ''}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13.5),
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary)),
          ),
        ]),
        const SizedBox(height: 10),
        // Responsive unit boxes — the ACTIVE box takes the real entry; the
        // rest lock and show the converted equivalents (never extra stock).
        LayoutBuilder(builder: (context, constraints) {
          final perRow = boxes.length <= 1
              ? 1
              : (boxes.length == 2 ? 2 : (constraints.maxWidth > 340 ? 3 : 2));
          final w = (constraints.maxWidth - (perRow - 1) * 8) / perRow;
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (key, label, factor) in boxes)
                SizedBox(
                  width: w,
                  child: (activeKey != null && activeKey != key)
                      ? _LockedCountBox(
                          label: label,
                          value: controllers[key]?.text ?? '',
                        )
                      : BusinessNumberField(
                    controller: controllers[key],
                    readOnly: false,
                    onChanged: (v) => onBoxChanged(key, factor, v),
                    // Units (قطعة/باكيت/كرتون) are indivisible: integers only,
                    // never a decimal that hides a counting error.
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: activeKey != null && activeKey != key
                            ? AppColors.textSecondary
                            : AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: label,
                      hintText:
                          AppLocalizations.of(context).translate('reconQtyHint'),
                      hintStyle: const TextStyle(
                          fontFamily: 'Cairo', fontSize: 10.5),
                      isDense: true,
                      filled: activeKey != null && activeKey != key,
                      fillColor: AppColors.surfaceVariant.withAlpha(110),
                    ),
                  ),
                ),
            ],
          );
        }),
        // The single converted base total (shown once an entry is active).
        if (activeKey != null) ...[
          const SizedBox(height: 8),
          Builder(builder: (context) {
            (String, String, double)? abox;
            for (final b in boxes) {
              if (b.$1 == activeKey) abox = b;
            }
            final q = double.tryParse(
                    (controllers[activeKey]?.text ?? '').trim()) ??
                0;
            final base = abox == null ? 0.0 : q * abox.$3;
            final baseUnit = '${line['unit'] ?? ''}';
            return Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(12),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        '${AppLocalizations.of(context).translate('reconBaseTotal')}: '
                        '${_fmtEqStatic(base)} $baseUnit',
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: AppColors.primary)),
                    Builder(builder: (context) {
                      final baseUnit = '${line['unit'] ?? ''}'.trim();
                      final inputs = <UnitBreakdownInput>[
                        UnitBreakdownInput(
                          name: baseUnit,
                          factor: 1,
                          group: unitGroupOfName(baseUnit) ?? 'count',
                        ),
                        for (final (_, label, factor) in boxes)
                          if (factor > 1)
                            UnitBreakdownInput(
                              name: label
                                  .replaceAll(RegExp(r'\s*\([^)]*\)\s*$'), '')
                                  .trim(),
                              factor: factor,
                              group: unitGroupOfName(label) ?? 'count',
                            ),
                      ];
                      final breakdown =
                          formatUnitBreakdown(decomposeCountUnits(base, inputs));
                      if (breakdown.isEmpty) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text('= $breakdown',
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textSecondary)),
                      );
                    }),
                  ]),
            );
          }),
        ],
      ]),
    );
  }
}

class _LockedCountBox extends StatelessWidget {
  final String label;
  final String value;
  const _LockedCountBox({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      padding: const EdgeInsets.fromLTRB(12, 20, 12, 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withAlpha(110),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.border),
      ),
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(
          top: -17,
          left: 8,
          right: 8,
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 10.5,
                  color: AppColors.textSecondary)),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: SizedBox(
            width: double.infinity,
            height: 26,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(value,
                  maxLines: 1,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textSecondary)),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Format an equivalent/base quantity (integer when whole, ≤2 decimals).
String _fmtEqStatic(double v) {
  if ((v - v.roundToDouble()).abs() < 1e-9) return v.round().toString();
  var s = v.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '');
  return s.replaceAll(RegExp(r'\.$'), '');
}
