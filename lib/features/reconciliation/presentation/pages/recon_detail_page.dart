import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/localization/app_localizations.dart';
import '../recon_report_pdf.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/storage_util.dart';
import '../../../../shared/widgets/account_type_bar.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../../core_business/presentation/providers/business_ledger_session.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../data/reconciliation_api.dart';
import '../widgets/recon_motion.dart';
import '../recon_report_pdf_layout.dart';
export '../recon_report_pdf_layout.dart' show ReconPdfLayout;
import '../widgets/recon_results.dart';
import '../widgets/recon_widgets.dart';

/// Past-match details — popular wording, who did it + when, the colored
/// table (بالنظام / بالحقيقة / الفرق), the before→after summary, PDF export.
class ReconDetailPage extends ConsumerStatefulWidget {
  final String reconId;
  final LocalReconciliationLink? localLink;
  const ReconDetailPage({super.key, required this.reconId, this.localLink});

  @override
  ConsumerState<ReconDetailPage> createState() => _ReconDetailPageState();
}

class _ReconDetailPageState extends ConsumerState<ReconDetailPage> {
  Map<String, dynamic>? _rec;
  bool _loading = true;
  bool _busy = false;
  Object? _error;
  late final ReconciliationApi _source;

  @override
  void initState() {
    super.initState();
    _source = ref.read(reconciliationApiProvider);
    _load();
  }

  bool _matches(ReconciliationApi current) =>
      identical(current, _source) &&
      (widget.localLink?.matches(current) ?? !current.isDeviceLedger);

  bool _mayRead() => mounted && _matches(ref.read(reconciliationApiProvider));

  Future<void> _load() async {
    try {
      if (!_mayRead()) throw const DirectoryAccessDenied();
      final id = widget.localLink?.ids ?? widget.reconId;
      if (id.isEmpty) throw const DirectoryAccessDenied();
      final rec = await _source.detail(id);
      if (_mayRead())
        setState(() {
          _rec = rec;
          _error = null;
        });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
    if (mounted) setState(() => _loading = false);
  }

  bool get _isBank => '${_rec?['rtype']}' == 'bank';

  List<Map<String, dynamic>> get _lines => [
    for (final l in (_rec?['lines'] as List? ?? []).whereType<Map>())
      Map<String, dynamic>.from(l),
  ];

  /// Currencies that exist with more than one account type in this record —
  /// only those show a «جاري/توفير» badge (bank/cash only).
  Set<String> get _multiTypeCurrencies =>
      ReconPdfLayout.currenciesWithMultipleTypes(_lines);

  ReconEqualizeKind get _eqKind {
    final rec = _rec!;
    if ('${rec['rtype']}' == 'bank') {
      final scope = rec['scope_json'] is Map
          ? Map<String, dynamic>.from(rec['scope_json'] as Map)
          : <String, dynamic>{};
      return '${scope['kind'] ?? ''}' == 'cash'
          ? ReconEqualizeKind.cash
          : ReconEqualizeKind.bank;
    }
    return switch ('${rec['scope']}') {
      'product' => ReconEqualizeKind.product,
      'category' => ReconEqualizeKind.category,
      _ => ReconEqualizeKind.store,
    };
  }

  /// Inline equalization from the archive details — runs the REAL approve
  /// API, then the crystal success + reload. Only reachable when not yet
  /// equalized (the button is rendered only in that state).
  Future<void> _equalizeNow() async {
    final rec = _rec;
    if (rec == null || _busy || !_mayRead()) return;
    final authorityLabel = reconCashDecisionLabel(rec);
    if (authorityLabel != null) {
      showFyonaSnack(context, AppLocalizations.of(context).translate(authorityLabel), success: false);
      return;
    }
    setState(() => _busy = true);
    try {
      late Map<String, dynamic> updated;
      if ('${rec['rtype']}' == 'bank') {
        if (_source.isDeviceLedger) {
          final l10n = AppLocalizations.of(context);
          if (!await showEqualizeSummary(
                context,
                title: l10n.translate('reconBankCashTab'),
                entries: [
                  for (final row in _diffLines)
                    EqualizeEntry(
                      name: '${row['name']} · ${row['currency']}',
                      rows: [
                        EqualizeUnitRow(
                          '',
                          fmtNum(_system(row)),
                          fmtNum(_actual(row)),
                        ),
                      ],
                    ),
                ],
              ) ||
              !_mayRead())
            return;
        }
        updated = await _source.bankApprove(
          reconId: '${rec['id']}',
          entries: [
            for (final l in _diffLines)
              {
                'account_id': '${l['account_id']}',
                'actual': _actual(l).toDouble(),
                'expected_system': _system(l).toDouble(),
              },
          ],
        );
      } else {
        updated = await _source.inventoryApprove(
          reconId: '${rec['id']}',
          settlements: [
            for (final l in _diffLines)
              if (l['stale'] != true)
                {
                  'product_id': '${l['product_id']}',
                  'expected_system': _system(l).toDouble(),
                  'new_qty': _actual(l).toDouble(),
                },
          ],
        );
      }
      if (!_mayRead()) return;
      // Apply the REAL approved record immediately: the page behind the
      // success scene must never keep showing «لم تُنفَّذ المساواة بعد».
      setState(() {
        _rec = Map<String, dynamic>.from(updated);
        _busy = false;
      });
      if (_source.isDeviceLedger && _rec?['status'] != 'approved') return;
      await showCrystalSuccess(
        context,
        kind: _eqKind,
        onAgain: () {},
        onExit: () {},
      );
      await _load(); // authoritative refresh (settlements + status)
    } catch (e) {
      if (_mayRead()) showReconError(context, e);
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  bool get hasDiff => _lines.any(
    (l) => (((l['diff'] ?? 0) as num?) ?? 0).toDouble().abs() > 1e-9,
  );

  List<Map<String, dynamic>> get _diffLines => [
    for (final l in _lines)
      if ((((l['diff'] ?? 0) as num?) ?? 0).toDouble().abs() > 1e-9)
        Map<String, dynamic>.from(l),
  ];

  num _system(Map l) => (l['system'] ?? l['system_qty'] ?? 0) as num;
  num _actual(Map l) =>
      (l['actual'] ?? l['base_qty'] ?? l['counted_qty'] ?? 0) as num;

  Future<void> _exportPdf() async {
    final rec = _rec;
    bool mayExport() =>
        _mayRead() &&
        (!_source.isDeviceLedger ||
            ref.read(employeeCanProvider('reports.export')));
    if (rec == null || !mayExport()) return;
    final l10n = AppLocalizations.of(context);
    try {
      // The exact «R1» report design (bank/cash + inventory flavours).
      final scope = rec['scope_json'] is Map
          ? Map<String, dynamic>.from(rec['scope_json'] as Map)
          : <String, dynamic>{};
      final lines = _lines;
      final subject = _isBank
          ? (lines.isNotEmpty ? '${lines.first['bank_name'] ?? ''}' : '')
          : '${scope['category_name'] ?? ''}';
      final isAr = AppLocalizations.of(context).locale.languageCode != 'en';
      final bytes = await ReconReportPdf.build(
        record: rec,
        isBank: _isBank,
        isAr: isAr,
        scope: {'name': subject},
      );
      if (!mayExport()) return;
      final dir = await Directory.systemTemp.createTemp('recon_pdf');
      final file = File(
        '${dir.path}/fyona_${_isBank ? 'bank' : 'inventory'}_${rec['ref_code'] ?? rec['id']}.pdf',
      );
      await file.writeAsBytes(bytes);
      if (mayExport()) {
        await StorageUtil.showPdfOptions(
          context,
          file,
          file.path.split('/').last,
        );
      } else {
        await file.delete();
      }
    } catch (e) {
      if (mounted) {
        showFyonaSnack(
          context,
          l10n.translate('reconCheckFailed'),
          success: false,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_source.isDeviceLedger) {
      ref.listen(businessBankRevisionProvider, (_, __) {
        if (_rec?['authority_state'] == 'queued' && _mayRead()) _load();
      });
    }
    final current = ref.watch(reconciliationApiProvider);
    final allowed =
        _matches(current) &&
        (!current.isDeviceLedger ||
            ref.watch(widget.localLink?.rtype == 'inventory'
                ? localInventoryReconciliationAllowedProvider
                : localBankReconciliationAllowedProvider));
    final rec = allowed ? _rec : null;
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
        title: Text(
          '${rec?['ref_code'] ?? ''}',
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 15),
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
        actions: [
          if (rec != null &&
              (!current.isDeviceLedger ||
                  ref.watch(employeeCanProvider('reports.export'))))
            IconButton(
              tooltip: l10n.translate('reconExportPdf'),
              onPressed: _exportPdf,
              icon: const Icon(
                Icons.picture_as_pdf_outlined,
                color: AppColors.primary,
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: !allowed
            ? Center(child: Text(l10n.translate('reconDeviceDenied')))
            : _loading
            ? current.isDeviceLedger
                  ? const SizedBox.shrink()
                  : const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                      ),
                    )
            : rec == null
            ? Center(
                child: Text(
                  reconErrorMessage(l10n, _error ?? StateError('missing')),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  _metaCard(rec, l10n),
                  const SizedBox(height: 14),
                  _sectionTitle(l10n.translate('reconDetailsTitle')),
                  ReconDiffTable(
                    money: _isBank,
                    firstColumnLabel: _isBank
                        ? l10n.translate('currencyLabel')
                        : l10n.translate('repProducts'),
                    showUnitColumn: !_isBank,
                    rows: [
                      for (final l in _lines)
                        if (_isBank)
                          ReconResultRow(
                            name: '${l['currency']}',
                            mark: '${l['name'] ?? ''}',
                            markColorKey:
                                _multiTypeCurrencies.contains(
                                  '${l['currency']}'.toUpperCase(),
                                )
                                ? '${l['account_type'] ?? 'checking'}'
                                : null,
                            system: _system(l).toDouble(),
                            actual: _actual(l).toDouble(),
                            diff: (l['diff'] as num?)?.toDouble() ?? 0,
                            unit: '${l['currency']}',
                          )
                        else
                          ...expandProductRows(
                            name: '${l['name'] ?? ''}',
                            mark: '${l['unit'] ?? ''}',
                            markColorKey: null,
                            systemQty: _system(l),
                            actualQty: _actual(l).toDouble(),
                            diff: (l['diff'] as num?)?.toDouble() ?? 0,
                            unit: '${l['unit'] ?? ''}',
                            parts: l['parts'] ?? const [],
                            serverRows: l['unit_rows'],
                          ).map(
                            (rd) => ReconResultRow(
                              name: rd.name,
                              mark: rd.mark,
                              markColorKey: rd.markColorKey,
                              system: rd.system,
                              actual: rd.actual,
                              diff: rd.diff,
                              unit: rd.unit,
                            ),
                          ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if ('${rec['status']}' == 'approved')
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: kReconActual.withAlpha(20),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: kReconActual.withAlpha(90)),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.check_circle_rounded,
                            color: kReconActual,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            l10n.translate('reconEqDoneBanner'),
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 13),
                              fontWeight: FontWeight.w900,
                              color: kReconActual,
                            ),
                          ),
                        ],
                      ),
                    ),
                  _sectionTitle(l10n.translate('reconSettlements')),
                  if ((rec['settlements'] as List? ?? []).isEmpty) ...[
                    if (hasDiff) ...[
                      // Checked-but-not-equalized: show WHAT WOULD CHANGE
                      // (never claim «كل شي مطابق» when there IS a diff).
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: kReconSystem.withAlpha(18),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: kReconSystem.withAlpha(70)),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.info_outline_rounded,
                              size: 18,
                              color: kReconSystem,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                 l10n.translate(reconCashDecisionLabel(rec) ?? 'reconNotSettledYet'),
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: R.fontSize(context, 11),
                                  color: kReconSystem,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      _sectionTitle(l10n.translate('reconWouldBecome')),
                      ReconDiffTable(
                        money: _isBank,
                        firstColumnLabel: _isBank
                            ? l10n.translate('currencyLabel')
                            : l10n.translate('repProducts'),
                        rows: [
                          for (final l in _diffLines)
                            ...expandProductRows(
                              name: _isBank
                                  ? '${l['currency']}'
                                  : '${l['name'] ?? ''}',
                              mark: _isBank
                                  ? '${l['name'] ?? ''}'
                                  : '${l['unit'] ?? ''}',
                              markColorKey:
                                  _isBank &&
                                      _multiTypeCurrencies.contains(
                                        '${l['currency']}'.toUpperCase(),
                                      )
                                  ? '${l['account_type'] ?? 'checking'}'
                                  : null,
                              systemQty: _system(l),
                              actualQty: _actual(l).toDouble(),
                              diff: (l['diff'] as num?)?.toDouble() ?? 0,
                              unit: _isBank
                                  ? '${l['currency']}'
                                  : '${l['unit'] ?? ''}',
                              parts: l['parts'] ?? const [],
                              serverRows: l['unit_rows'],
                            ).map(
                              (rd) => ReconResultRow(
                                name: rd.name,
                                mark: rd.mark,
                                markColorKey: rd.markColorKey,
                                system: rd.system,
                                actual: rd.actual,
                                diff: rd.diff,
                                unit: rd.unit,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // ONLY when the equalization was not executed yet.
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                          ),
                          onPressed:
                              _busy ||
                                  (current.isDeviceLedger &&
                                      !ref.watch(
                                        employeeCanProvider(
                                          'reconciliation.equalize',
                                        ),
                                      ))
                              ? null
                              : _equalizeNow,
                          icon: const Icon(Icons.balance_rounded),
                          label: Text(
                            l10n.translate('reconEqNow'),
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontWeight: FontWeight.w900,
                              fontSize: 14.5,
                            ),
                          ),
                        ),
                      ),
                    ] else
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: kReconActual.withAlpha(14),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: kReconActual.withAlpha(60)),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.verified_rounded,
                              color: kReconActual,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                l10n.translate('reconNoDiffHint'),
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: R.fontSize(context, 12),
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ] else
                    for (final s
                        in (rec['settlements'] as List).whereType<Map>())
                      _SettlementCard(
                        s: Map<String, dynamic>.from(s),
                        bank: _isBank,
                        multiTypes: _multiTypeCurrencies,
                        lines: _lines,
                        l10n: l10n,
                      ),
                ],
              ),
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      t,
      style: TextStyle(
        fontFamily: 'Cairo',
        fontSize: R.fontSize(context, 14),
        fontWeight: FontWeight.w900,
        color: AppColors.textSecondary,
      ),
    ),
  );

  Widget _metaCard(Map rec, AppLocalizations l10n) {
    final bank = '${rec['rtype']}' == 'bank';
    final when = '${rec['created_at'] ?? ''}'
        .split('T')
        .join(' ')
        .split('.')
        .first;
    final approvedAt = '${rec['approved_at'] ?? ''}'
        .split('T')
        .join(' ')
        .split('.')
        .first;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.primary.withAlpha(60)),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withAlpha(20),
            blurRadius: 22,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(18),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  bank
                      ? Icons.account_balance_rounded
                      : Icons.inventory_2_rounded,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bank
                          ? l10n.translate('reconBankCashTab')
                          : l10n.translate('reconInventoryTab'),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 14),
                        fontWeight: FontWeight.w900,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      '${rec['ref_code'] ?? ''}',
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11),
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Visibility(
                visible: '${rec['status']}' == 'approved',
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: kReconActual.withAlpha(22),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    l10n.translate('reconStatusApproved'),
                    style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      color: kReconActual,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _kv(
            l10n.translate('reconWhoDid'),
            '${rec['created_by_name'] ?? '—'}',
          ),
          _kv(l10n.translate('reconWhenDone'), when.isEmpty ? '—' : when),
          if (approvedAt.isNotEmpty)
            _kv(l10n.translate('reconStatusApproved'), approvedAt),
          if ((rec['measured_at'] ?? '').toString().isNotEmpty)
            _kv(
              l10n.translate('reconMeasuredAt'),
              '${rec['measured_at']}'.split('.').first,
            ),
          if ((rec['notes'] ?? '').toString().isNotEmpty)
            _kv(l10n.translate('reconNotes'), '${rec['notes']}'),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(
            k,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 11),
              color: AppColors.textSecondary,
            ),
          ),
        ),
        Expanded(
          child: Text(
            v,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 11.5),
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        ),
      ],
    ),
  );
}

class _SettlementCard extends StatelessWidget {
  final Map<String, dynamic> s;
  final bool bank;
  final Set<String> multiTypes;
  final List<Map<String, dynamic>> lines;
  final AppLocalizations l10n;
  const _SettlementCard({
    required this.s,
    required this.bank,
    required this.multiTypes,
    required this.lines,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    final applied = s['applied'] == true;
    final parts = (s['parts'] as List?) ?? const [];
    final urs = ReconPdfLayout.unitRows(
      systemQty: (s['before'] as num?) ?? 0,
      baseAfter: (s['after'] as num?) ?? 0,
      parts: parts,
      serverRows: (s['unit_rows'] as List?) ?? const [],
    );
    final multiUnit = urs.length > 1;

    // Bank/cash فئة badge — ONLY when this currency has more than one type,
    // resolved from the record's own lines by ACCOUNT ID (see the helper for
    // why name+currency is ambiguous for «جيب» USD جاري + USD توفير).
    String? type;
    if (bank) {
      final cur = '${s['currency'] ?? ''}'.toUpperCase();
      if (multiTypes.contains(cur)) {
        type = ReconPdfLayout.settlementAccountType(s, lines) ?? 'checking';
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: applied
            ? AppColors.primary.withAlpha(10)
            : kReconActual.withAlpha(12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: applied
              ? AppColors.primary.withAlpha(50)
              : kReconActual.withAlpha(60),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                applied ? Icons.swap_horiz_rounded : Icons.check_rounded,
                size: 18,
                color: applied ? AppColors.primary : kReconActual,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        '${s['name'] ?? ''}'
                        '${(s['currency'] ?? '').toString().isNotEmpty ? ' (${s['currency']})' : (!multiUnit && (s['unit'] ?? '').toString().isNotEmpty ? ' (${s['unit']})' : '')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 12.5),
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    if (type != null) ...[
                      const SizedBox(width: 5),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 0.5,
                        ),
                        decoration: BoxDecoration(
                          color: accountTypeBarColor(type).withAlpha(24),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          ReconPdfLayout.accountTypeLabelStr(
                            type,
                            isAr: true,
                            short: true,
                          ),
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 8),
                            fontWeight: FontWeight.w700,
                            color: accountTypeBarColor(type),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (!multiUnit)
                Text(
                  applied
                      ? bank
                            ? '${fmtNum(s['before'])} ← ${fmtNum(s['after'])}'
                            : '${s['before']} ← ${s['after']}'
                      : l10n.translate('reconNoChange'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 11.5),
                    fontWeight: FontWeight.w900,
                    color: applied ? AppColors.primary : kReconActual,
                  ),
                ),
            ],
          ),
          // Per-unit breakdown INSIDE the same settlement card.
          for (final ur in urs)
            Padding(
              padding: const EdgeInsets.only(top: 3, right: 26),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      ur.unit,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 10.5),
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  Text(
                    '${ur.before} ← ${ur.after}',
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 10.5),
                      fontWeight: FontWeight.w700,
                      color: applied ? AppColors.primary : kReconActual,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
