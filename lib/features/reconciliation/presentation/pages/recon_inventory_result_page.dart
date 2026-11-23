import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/services/scan_sfx.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../data/reconciliation_api.dart';
import '../widgets/recon_results.dart';
import '../widgets/recon_motion.dart';
import '../recon_report_pdf_layout.dart';
import '../widgets/recon_widgets.dart';

/// Inventory result — the EXACT same presentation as the bank flow:
/// system (orange) / real (green) / difference (red) + «مساواة النظام»
/// with the compact before/after summary and a real approval.
class ReconInventoryResultPage extends ConsumerStatefulWidget {
  final Map<String, dynamic> record;
  final LocalReconciliationLink? localLink;
  const ReconInventoryResultPage({super.key, required this.record, this.localLink});

  @override
  ConsumerState<ReconInventoryResultPage> createState() =>
      _ReconInventoryResultPageState();
}

class _ReconInventoryResultPageState
    extends ConsumerState<ReconInventoryResultPage> {
  late Map<String, dynamic> _rec;
  bool _busy = false;
  late final ReconciliationApi _source;

  bool _canContinue(ReconciliationApi current) =>
      identical(_source, current) &&
      (widget.localLink?.matches(current) ?? !current.isDeviceLedger);

  bool get _active => mounted && _canContinue(ref.read(reconciliationApiProvider));

  @override
  void initState() {
    super.initState();
    _source = ref.read(reconciliationApiProvider);
    _rec = Map<String, dynamic>.from(widget.record);
  }

  List<Map<String, dynamic>> get _lines => [
        for (final l in (_rec['lines'] as List? ?? []).whereType<Map>())
          if (l['base_qty'] != null) Map<String, dynamic>.from(l)
      ];

  /// Confirmation entries for one product: a multi-unit product shows EVERY
  /// unit in its own row inside the product rectangle (entered qty per unit);
  /// a single-unit product shows one simple row.
  List<EqualizeEntry> _equalizeEntriesFor(Map<String, dynamic> s) {
    final parts = (s['parts'] as List?) ?? const [];
    final urs = ReconPdfLayout.unitRows(
      systemQty: (s['expected_system'] as num?) ?? 0,
      baseAfter: (s['new_qty'] as num?) ?? 0,
      parts: parts,
      serverRows: (s['unit_rows'] as List?) ?? const [],
    );
    if (urs.length > 1) {
      return [
        EqualizeEntry(
          name: '${s['name']}',
          rows: [
            for (final ur in urs)
              EqualizeUnitRow(ur.unit, ur.before, ur.after),
          ],
        )
      ];
    }
    return [
      EqualizeEntry(
        name: '${s['name']} (${s['unit']})',
        rows: [EqualizeUnitRow('', '${s['before']}', '${s['after']}')],
      )
    ];
  }

  Future<void> _equalize() async {
    if (_busy || !_active || !ref.read(employeeCanProvider('reconciliation.equalize'))) return;
    final l10n = AppLocalizations.of(context);
    final staleCount = _lines.where((l) => l['stale'] == true).length;
    final toSettle = [
      for (final l in _lines)
        if (l['stale'] != true &&
            ((l['diff'] ?? 0) as num).toDouble().abs() > 1e-9)
          {
            'product_id': '${l['product_id']}',
            'expected_system': (l['system_qty'] as num?)?.toDouble() ?? 0,
            'new_qty': (l['base_qty'] as num?)?.toDouble() ?? 0,
            'name': '${l['name']}',
            'unit': '${l['unit'] ?? ''}',
            'before': '${l['system_qty']}',
            'after': '${l['base_qty']}',
            'parts': l['parts'] ?? const [],
            'unit_rows': l['unit_rows'] ?? const [],
          }
    ];
    if (toSettle.isEmpty) {
      showFyonaSnack(
          context,
          staleCount > 0
              ? l10n.translate('reconStaleHint')
              : l10n.translate('reconNoDiffHint'),
          success: true);
      return;
    }
    final ok = await showEqualizeSummary(
      context,
      title: l10n.translate('reconInventoryTab'),
      entries: [
        for (final s in toSettle)
          ..._equalizeEntriesFor(s),
      ],
    );
    if (!ok || !_active) return;
    setState(() => _busy = true);
    try {
      final rec = await _source.inventoryApprove(
            reconId: widget.localLink?.ids ?? '${_rec['id']}',
            settlements: [
              for (final s in toSettle)
                {
                  'product_id': s['product_id'],
                  'expected_system': s['expected_system'],
                  'new_qty': s['new_qty'],
                }
            ],
          );
      if (!_active) return;
      setState(() {
        _busy = false;
        _rec = Map<String, dynamic>.from(rec);
      });
      final kind = switch ('${_rec['scope']}') {
        'product' => ReconEqualizeKind.product,
        'category' => ReconEqualizeKind.category,
        _ => ReconEqualizeKind.store,
      };
      await showCrystalSuccess(
        context,
        kind: kind,
        onAgain: () {},
        onExit: () {},
      ).then((action) {
        if (!mounted) return;
        if (action == ReconSuccessAction.again) {
          context.go(RouteNames.reconciliationInventory);
        } else {
          context.go(RouteNames.dashboard);
        }
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final fresh = ref.read(reconciliationApiProvider).conflictFresh(e);
      if (e.response?.statusCode == 409 && fresh != null) {
        final pid = '${fresh['product_id']}';
        for (final l in _lines) {
          if ('${l['product_id']}' == pid) {
            l['system_qty'] = fresh['system_qty'];
            l['diff'] = ((l['base_qty'] ?? 0) as num).toDouble() -
                (fresh['system_qty'] as num).toDouble();
            l['stale'] = true;
          }
        }
        unawaited(ScanSfx.error());
        showFyonaSnack(context, l10n.translate('reconConflict'),
            success: false);
        setState(() {});
      } else {
        showReconError(context, e);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showReconError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final current = ref.watch(reconciliationApiProvider);
    final allowed = (!current.isDeviceLedger ||
        ref.watch(localInventoryReconciliationAllowedProvider)) && _canContinue(current);
    final lines = _lines;
    final matched = lines
        .where((l) => ((l['diff'] ?? 0) as num).toDouble().abs() <= 1e-9)
        .length;
    final short = lines
        .where((l) => ((l['diff'] ?? 0) as num).toDouble() < -1e-9)
        .length;
    final surplus = lines
        .where((l) => ((l['diff'] ?? 0) as num).toDouble() > 1e-9)
        .length;
    final stale = lines.where((l) => l['stale'] == true).length;
    final approved = '${_rec['status']}' == 'approved';
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
        title: Text(l10n.translate('reconResultTitle'),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 16),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
      ),
      body: !allowed
          ? Center(child: Text(reconErrorMessage(l10n, const DirectoryAccessDenied())))
          : SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            ReconResultHeader(
                matched: matched, shortCount: short, surplusCount: surplus),
            if (stale > 0) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: kReconSystem.withAlpha(20),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: kReconSystem.withAlpha(80)),
                ),
                child: Row(children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 18, color: kReconSystem),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(l10n.translate('reconStaleHint'),
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 10.5),
                            height: 1.4,
                            color: kReconSystem)),
                  ),
                ]),
              ),
            ],
            const SizedBox(height: 16),
            ReconDiffTable(
              firstColumnLabel: l10n.translate('repProducts'),
              showUnitColumn: true,
              rows: [
                for (final l in lines)
                  ...expandProductRows(
                    name: '${l['name']}',
                    mark: null,
                    markColorKey: null,
                    systemQty: (l['system_qty'] as num?)?.toDouble() ?? 0,
                    actualQty: (l['base_qty'] as num?)?.toDouble() ?? 0,
                    diff: (l['diff'] as num?)?.toDouble() ?? 0,
                    unit: '${l['unit'] ?? ''}',
                    parts: l['parts'] ?? const [],
                    serverRows: l['unit_rows'],
                  ).map((rd) => ReconResultRow(
                    name: rd.name,
                    mark: rd.mark,
                    markColorKey: rd.markColorKey,
                    system: rd.system,
                    actual: rd.actual,
                    diff: rd.diff,
                    unit: rd.unit,
                  )),
              ],
            ),
            const SizedBox(height: 16),
            if (!approved && ref.watch(employeeCanProvider('reconciliation.equalize')) &&
                lines.any((l) =>
                    l['stale'] != true &&
                    ((l['diff'] ?? 0) as num).toDouble().abs() > 1e-9))
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(vertical: 15)),
                  onPressed: _busy ? null : _equalize,
                  icon: const Icon(Icons.balance_rounded),
                  label: Text(l10n.translate('reconEqualizeSystem'),
                      style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontWeight: FontWeight.w900,
                          fontSize: 16)),
                ),
              )
            else if (approved)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: kReconActual.withAlpha(18),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: kReconActual.withAlpha(80)),
                ),
                child: Row(children: [
                  const Icon(Icons.verified_rounded, color: kReconActual),
                  const SizedBox(width: 8),
                  Text(l10n.translate('reconApproved'),
                      style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontWeight: FontWeight.w800,
                          color: kReconActual)),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}
