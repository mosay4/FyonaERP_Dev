import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../core_business/presentation/widgets/business_number_field.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../../core_business/presentation/providers/business_ledger_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/amount_input_formatter.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../../shared/services/scan_sfx.dart';
import '../../../../shared/widgets/account_type_bar.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../data/reconciliation_api.dart';
import '../recon_report_pdf_layout.dart';
import '../widgets/recon_motion.dart';
import '../widgets/recon_results.dart';
import '../widgets/recon_widgets.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// Bank / cash reconciliation — the merchant flow:
///   1. bank cards (NAME ONLY, no currencies) → «ابدأ المطابقة»
///   2. tick the currencies you actually hold (NO balances shown at all)
///   3. type the real amount for each ticked currency
///   4. «ابدأ المطابقة» → 4s cinematic → result table
///   5. «مساواة النظام» → compact before/after summary → تأكيد
/// ─────────────────────────────────────────────────────────────────────────

/// Step 1 — the bank/cash cards: name only + «ابدأ المطابقة».
class ReconAccountsPage extends ConsumerStatefulWidget {
  const ReconAccountsPage({super.key});

  @override
  ConsumerState<ReconAccountsPage> createState() => _ReconAccountsPageState();
}

class _ReconAccountsPageState extends ConsumerState<ReconAccountsPage> {
  List<Map<String, dynamic>> _accounts = [];
  bool _loading = true;
  late final ReconciliationApi _source;

  @override
  void initState() {
    super.initState();
    _source = ref.read(reconciliationApiProvider);
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _source.accounts();
      if (mounted) setState(() => _accounts = list);
    } catch (_) {
      if (mounted) {
        showFyonaSnack(
          context,
          AppLocalizations.of(context).translate('reconCheckFailed'),
          success: false,
        );
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  List<List<Map<String, dynamic>>> get _groups {
    final g = <String, List<Map<String, dynamic>>>{};
    for (final a in _accounts) {
      final key = ((a['bank_name'] ?? '') as String).trim();
      g.putIfAbsent(key, () => []).add(a);
    }
    final entries = g.entries.toList()
      ..sort((x, y) {
        final xc = isCashName(x.key);
        final yc = isCashName(y.key);
        if (xc != yc) return xc ? -1 : 1;
        return x.key.compareTo(y.key);
      });
    return [for (final e in entries) e.value];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final current = ref.watch(reconciliationApiProvider);
    final allowed =
        !(_source.isDeviceLedger || current.isDeviceLedger) ||
        (identical(current, _source) &&
            ref.watch(localBankReconciliationAllowedProvider));
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
          l10n.translate('reconBankCashTab'),
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 16),
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
      ),
      body: SafeArea(
        child: !allowed
            ? Center(child: Text(l10n.translate('reconDeviceDenied')))
            : _loading
            ? _source.isDeviceLedger
                  ? const SizedBox.shrink()
                  : const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                      ),
                    )
            : _accounts.isEmpty
            ? Center(
                child: Text(
                  l10n.translate('reconNoAccounts'),
                  style: const TextStyle(fontFamily: 'Cairo'),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                children: [
                  Text(
                    l10n.translate('reconTapAccount'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 12),
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (final group in _groups) ...[
                    _BankNameCard(accounts: group, dark: dark, source: _source),
                    const SizedBox(height: 14),
                  ],
                ],
              ),
      ),
    );
  }
}

/// One bank/cash card: NAME ONLY (no currencies, no balances) + the button.
class _BankNameCard extends StatelessWidget {
  final List<Map<String, dynamic>> accounts;
  final bool dark;
  final ReconciliationApi source;
  const _BankNameCard({
    required this.accounts,
    required this.dark,
    required this.source,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final name = '${accounts.first['bank_name'] ?? ''}';
    final isCash = isCashName(name);
    final ids = accounts.map((a) => '${a['id']}').join(',');
    void open() {
      unawaited(ScanSfx.warmUp());
      _openBankStep(context, RouteNames.reconciliationBankSelect, source, ids);
    }

    return ReconTiltCard(
      onTap: open,
      elevation: 8,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.primary.withAlpha(60)),
        ),
        child: Column(
          children: [
            Row(
              children: [
                ReconGlyph(
                  isCash ? ReconGlyphKind.cash : ReconGlyphKind.bank,
                  size: 44,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 15),
                          fontWeight: FontWeight.w900,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        isCash
                            ? l10n.translate('reconCash')
                            : l10n.translate('reconBank'),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 11),
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: open,
                icon: const Icon(Icons.balance_rounded, size: 18),
                label: Text(
                  l10n.translate('reconStartRecon'),
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool isCashName(String name) {
  final n = name.trim().toUpperCase();
  return n == 'كاش' || n == 'CASH';
}

void _openBankStep(
  BuildContext context,
  String route,
  ReconciliationApi source,
  String ids,
) {
  if (source.isDeviceLedger) {
    if (source.canReadDeviceBank)
      context.push(route, extra: LocalReconciliationLink(source, ids));
  } else {
    context.push('$route?ids=$ids');
  }
}

/// Step 2 — tick the currencies (NO balances shown), then «التالي».
class ReconBankSelectPage extends ConsumerStatefulWidget {
  final String accountIds;
  final LocalReconciliationLink? localLink;
  const ReconBankSelectPage({
    super.key,
    required this.accountIds,
    this.localLink,
  });

  @override
  ConsumerState<ReconBankSelectPage> createState() =>
      _ReconBankSelectPageState();
}

class _ReconBankSelectPageState extends ConsumerState<ReconBankSelectPage> {
  List<Map<String, dynamic>> _accounts = [];
  final Set<String> _selected = {};
  bool _loading = true;
  late final ReconciliationApi _source;

  @override
  void initState() {
    super.initState();
    _source = ref.read(reconciliationApiProvider);
    _load();
  }

  Future<void> _load() async {
    try {
      final link = widget.localLink;
      if (link != null && !link.matches(_source))
        throw const DirectoryAccessDenied();
      final ids = (link?.ids ?? widget.accountIds).split(',').toSet();
      final all = await _source.accounts();
      final picked = [
        for (final a in all)
          if (ids.contains('${a['id']}')) a,
      ];
      if (!mounted) return;
      setState(() {
        _accounts = picked;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
        showReconError(context, StateError('load'));
      }
    }
  }

  void _next() {
    if (!identical(_source, ref.read(reconciliationApiProvider))) return;
    if (_selected.isEmpty) {
      showFyonaSnack(
        context,
        AppLocalizations.of(context).translate('reconPickCurrenciesHint'),
        success: false,
      );
      return;
    }
    final ids = _accounts
        .where((a) => _selected.contains('${a['id']}'))
        .map((a) => '${a['id']}')
        .join(',');
    _openBankStep(context, RouteNames.reconciliationBankRun, _source, ids);
  }

  /// Currencies that exist with more than one account type in this bank/cash —
  /// only those show a «جاري/توفير» badge.
  Set<String> get _multiTypeCurrencies =>
      ReconPdfLayout.currenciesWithMultipleTypes(_accounts);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final current = ref.watch(reconciliationApiProvider);
    final allowed =
        !(widget.localLink != null ||
            _source.isDeviceLedger ||
            current.isDeviceLedger) ||
        (identical(current, _source) &&
            (widget.localLink?.matches(current) ?? current.isDeviceLedger) &&
            ref.watch(localBankReconciliationAllowedProvider));
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
          '${allowed && _accounts.isNotEmpty ? _accounts.first['bank_name'] : ''}',
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 15),
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
      ),
      body: SafeArea(
        child: !allowed
            ? Center(child: Text(l10n.translate('reconDeviceDenied')))
            : _loading
            ? _source.isDeviceLedger
                  ? const SizedBox.shrink()
                  : const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                      ),
                    )
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                    child: Column(
                      children: [
                        Text(
                          l10n.translate('reconPickCurrencies'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 16),
                            fontWeight: FontWeight.w900,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.translate('reconPickCurrenciesHint'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 11.5),
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      children: [
                        for (final a in _accounts)
                          _CurrencyTickRow(
                            account: a,
                            showType: _multiTypeCurrencies.contains(
                              '${a['currency'] ?? ''}'.toUpperCase(),
                            ),
                            selected: _selected.contains('${a['id']}'),
                            onChanged: (v) => setState(() {
                              final id = '${a['id']}';
                              if (v) {
                                _selected.add(id);
                              } else {
                                _selected.remove(id);
                              }
                            }),
                          ),
                      ],
                    ),
                  ),
                  _bottomBar(l10n),
                ],
              ),
      ),
    );
  }

  Widget _bottomBar(AppLocalizations l10n) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        10,
        16,
        12 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border, width: .5)),
      ),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          onPressed: _next,
          icon: const Icon(Icons.arrow_forward_rounded, size: 18),
          label: Text(
            '${l10n.translate('reconNext')}'
            '${_selected.isNotEmpty ? ' (${_selected.length})' : ''}',
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
        ),
      ),
    );
  }
}

/// One currency/account tick row: «العملة» + (only when this currency exists
/// with more than one type) its «جاري/توفير» badge and colored bar. NO balance
/// anywhere.
class _CurrencyTickRow extends StatelessWidget {
  final Map<String, dynamic> account;
  final bool showType;
  final bool selected;
  final ValueChanged<bool> onChanged;
  const _CurrencyTickRow({
    required this.account,
    required this.selected,
    required this.onChanged,
    this.showType = false,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cur = '${account['currency'] ?? ''}';
    final type = '${account['account_type'] ?? 'checking'}';
    final markColor = accountTypeBarColor(type);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: selected ? AppColors.primary : AppColors.border,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => onChanged(!selected),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              if (showType) ...[
                AccountTypeBar(type: type, height: 34),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cur,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 15),
                        fontWeight: FontWeight.w900,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (showType)
                      Text(
                        accountTypeLabel(l10n, type),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 11),
                          fontWeight: FontWeight.w700,
                          color: markColor,
                        ),
                      ),
                  ],
                ),
              ),
              Checkbox(
                value: selected,
                activeColor: AppColors.primary,
                onChanged: (v) => onChanged(v ?? false),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Step 3 — type the real amount per ticked currency, then «ابدأ المطابقة».
class ReconBankRunPage extends ConsumerStatefulWidget {
  final String accountIds;
  final LocalReconciliationLink? localLink;
  const ReconBankRunPage({super.key, required this.accountIds, this.localLink});

  @override
  ConsumerState<ReconBankRunPage> createState() => _ReconBankRunPageState();
}

class _ReconBankRunPageState extends ConsumerState<ReconBankRunPage> {
  List<Map<String, dynamic>> _accounts = [];
  final Map<String, TextEditingController> _actual = {};
  bool _busy = false;
  bool _loaded = false;
  late final ReconciliationApi _source;

  @override
  void initState() {
    super.initState();
    _source = ref.read(reconciliationApiProvider);
    _load();
  }

  Future<void> _load() async {
    try {
      final link = widget.localLink;
      if (link != null && !link.matches(_source))
        throw const DirectoryAccessDenied();
      final all = await _source.accounts();
      final ids = (link?.ids ?? widget.accountIds).split(',').toSet();
      final picked = [
        for (final a in all)
          if (ids.contains('${a['id']}')) a,
      ];
      if (!mounted) return;
      setState(() {
        _accounts = picked;
        _loaded = true;
        for (final a in picked) {
          _actual['${a['id']}'] = TextEditingController();
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loaded = true);
        showReconError(context, e);
      }
    }
  }

  /// Currencies with more than one account type in this bank/cash — only those
  /// show a «جاري/توفير» badge.
  Set<String> get _multiTypeCurrencies =>
      ReconPdfLayout.currenciesWithMultipleTypes(_accounts);

  Future<void> _start() async {
    if (_busy || !identical(_source, ref.read(reconciliationApiProvider)))
      return;
    final l10n = AppLocalizations.of(context);
    final entries = <Map<String, dynamic>>[];
    for (final a in _accounts) {
      final id = '${a['id']}';
      final raw = _actual[id]!.text.trim();
      if (raw.isEmpty) continue;
      final v = double.tryParse(raw.replaceAll(',', ''));
      if (v == null || !v.isFinite || v < 0) {
        showFyonaSnack(
          context,
          l10n.translate('reconEnterActual'),
          success: false,
        );
        return;
      }
      entries.add({
        'account_id': id,
        'actual': _source.isDeviceLedger ? raw.replaceAll(',', '') : v,
      });
    }
    if (entries.isEmpty) {
      showFyonaSnack(
        context,
        l10n.translate('reconEnterActual'),
        success: false,
      );
      return;
    }
    setState(() => _busy = true);
    final api = _source;
    // ONE operation id per «بدء المطابقة» tap: even if the check is retried or
    // the overlay rebuilds, the backend returns the SAME record (no twins →
    // no phantom «لم تنفذ المساواة» rows, and the approved record is the one
    // the user actually opened).
    final future = api.bankCheck(
      entries: entries,
      idempotencyKey: ReconciliationApi.newOperationId(),
    );
    void openResult(dynamic result) => context.push(
      RouteNames.reconciliationBankResult,
      extra: {
        'record': Map<String, dynamic>.from(result as Map),
        if (api.isDeviceLedger) 'source': api,
      },
    );
    if (api.isDeviceLedger) {
      try {
        final record = await future;
        if (mounted &&
            identical(api, ref.read(reconciliationApiProvider)) &&
            api.canReadDeviceBank) {
          openResult(record);
        }
      } catch (e) {
        if (mounted) showReconError(context, e);
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ReconCoreOverlay(
            variant: ReconSceneVariant.bank,
            processingText: l10n.translate('reconProcessing'),
            future: future,
            onResult: (_, result) {
              if (!mounted) return;
              setState(() => _busy = false);
              context.pop(); // close the cinematic
              if (identical(api, ref.read(reconciliationApiProvider)))
                openResult(result);
            },
            onError: (_, e) {
              if (mounted) {
                setState(() => _busy = false);
                context.pop();
                showReconError(context, e);
              }
            },
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    for (final c in _actual.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final current = ref.watch(reconciliationApiProvider);
    final allowed =
        !(widget.localLink != null ||
            _source.isDeviceLedger ||
            current.isDeviceLedger) ||
        (identical(current, _source) &&
            (widget.localLink?.matches(current) ?? current.isDeviceLedger) &&
            ref.watch(localBankReconciliationAllowedProvider));
    final bankName = allowed && _accounts.isNotEmpty
        ? '${_accounts.first['bank_name']}'
        : '';
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
          bankName,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 15),
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
      ),
      body: SafeArea(
        child: !allowed
            ? Center(child: Text(l10n.translate('reconDeviceDenied')))
            : !_loaded
            ? _source.isDeviceLedger
                  ? const SizedBox.shrink()
                  : const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                      ),
                    )
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                    child: Text(
                      l10n.translate('reconEnterActual'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 16),
                        fontWeight: FontWeight.w900,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      children: [
                        for (final a in _accounts)
                          _ActualAmountCard(
                            account: a,
                            showType: _multiTypeCurrencies.contains(
                              '${a['currency'] ?? ''}'.toUpperCase(),
                            ),
                            ctrl: _actual['${a['id']}']!,
                          ),
                      ],
                    ),
                  ),
                  Container(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      10,
                      16,
                      12 + MediaQuery.of(context).padding.bottom,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      border: Border(
                        top: BorderSide(color: AppColors.border, width: .5),
                      ),
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      child: BranchScope.readOnly
                          ? const SizedBox.shrink()
                          : FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                              ),
                              onPressed: _busy ? null : _start,
                              icon: const Icon(Icons.play_circle_fill_rounded),
                              label: Text(
                                l10n.translate('reconCheckNow'),
                                style: const TextStyle(
                                  fontFamily: 'Cairo',
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Amount card: currency + (only for multi-type currencies) its type mark +
/// «كم عندك بالحقيقة؟» input (no system balance anywhere — the merchant types
/// what they truly hold).
class _ActualAmountCard extends StatelessWidget {
  final Map<String, dynamic> account;
  final bool showType;
  final TextEditingController ctrl;
  const _ActualAmountCard({
    required this.account,
    required this.ctrl,
    this.showType = false,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cur = '${account['currency'] ?? ''}';
    final type = '${account['account_type'] ?? 'checking'}';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              if (showType) ...[
                AccountTypeBar(type: type, height: 30),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cur,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 15),
                        fontWeight: FontWeight.w900,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (showType)
                      Text(
                        accountTypeLabel(l10n, type),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 11),
                          fontWeight: FontWeight.w700,
                          color: accountTypeBarColor(type),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          BusinessNumberField(
            controller: ctrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [AmountInputFormatter()],
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
            decoration: InputDecoration(
              labelText: l10n.translate('reconActualField'),
              isDense: true,
            ),
          ),
        ],
      ),
    );
  }
}

/// Step 5 — the result page: warm header + colored table + «مساواة النظام»
/// with the compact before/after summary and the real approval.
class ReconBankResultPage extends ConsumerStatefulWidget {
  final Map<String, dynamic> record;
  final ReconciliationApi? localSource;
  const ReconBankResultPage({
    super.key,
    required this.record,
    this.localSource,
  });

  @override
  ConsumerState<ReconBankResultPage> createState() =>
      _ReconBankResultPageState();
}

class _ReconBankResultPageState extends ConsumerState<ReconBankResultPage> {
  late Map<String, dynamic> _rec;
  late final ReconciliationApi _source;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _source = ref.read(reconciliationApiProvider);
    _rec = Map<String, dynamic>.from(widget.record);
  }

  bool _matches(ReconciliationApi current) =>
      identical(current, _source) &&
      (widget.localSource == null
          ? !current.isDeviceLedger
          : identical(widget.localSource, _source) &&
                current.canReadDeviceBank);

  List<Map<String, dynamic>> get _lines => [
    for (final l in (_rec['lines'] as List? ?? []).whereType<Map>())
      Map<String, dynamic>.from(l),
  ];

  /// Currencies with more than one account type in this record — only those
  /// show a «جاري/توفير» badge.
  Set<String> get _multiTypeCurrencies =>
      ReconPdfLayout.currenciesWithMultipleTypes(_lines);

  Future<void> _equalize() async {
    if (_busy || !_matches(ref.read(reconciliationApiProvider))) return;
    final l10n = AppLocalizations.of(context);
    final state = reconCashDecisionLabel(_rec);
    if (state != null) {
      showFyonaSnack(context, l10n.translate(state), success: false);
      return;
    }
    final toSettle = [
      for (final l in _lines)
        if (asDoubleValue(l['diff']).abs() > 1e-9)
          {
            'account_id': '${l['account_id']}',
            'actual': asDoubleValue(l['actual']),
            'expected_system': asDoubleValue(l['system']),
            'name': '${l['name']}',
            'currency': '${l['currency']}',
            'type': '${l['account_type'] ?? 'checking'}',
            // Raw values: the summary sheet formats them once. Formatting
            // twice turned «-10,500» into an unparseable string shown as 0.
            'before': l['system'],
            'after': l['actual'],
          },
    ];
    if (toSettle.isEmpty) {
      showFyonaSnack(context, l10n.translate('reconNoDiffHint'), success: true);
      return;
    }
    final bankName =
        '${_lines.isNotEmpty ? _lines.first['bank_name'] ?? '' : ''}';
    final multi = ReconPdfLayout.currenciesWithMultipleTypes(_lines);
    setState(() => _busy = true);
    final ok = await showEqualizeSummary(
      context,
      title: bankName.isEmpty ? l10n.translate('reconBankCashTab') : bankName,
      entries: [
        for (final s in toSettle)
          EqualizeEntry(
            name: '${s['currency']}',
            type: multi.contains('${s['currency']}'.toUpperCase())
                ? '${s['type']}'
                : null,
            rows: [
              EqualizeUnitRow(
                '',
                '${fmtNum(s['before'])}',
                '${fmtNum(s['after'])}',
              ),
            ],
          ),
      ],
    );
    if (!mounted) return;
    if (!ok || !_matches(ref.read(reconciliationApiProvider))) {
      setState(() => _busy = false);
      return;
    }
    try {
      final rec = await _source.bankApprove(
        reconId: '${_rec['id']}',
        entries: [
          for (final s in toSettle)
            {
              'account_id': s['account_id'],
              'actual': s['actual'],
              'expected_system': s['expected_system'],
            },
        ],
      );
      if (!mounted) return;
      if (!_matches(ref.read(reconciliationApiProvider))) {
        setState(() => _busy = false);
        return;
      }
      setState(() {
        _busy = false;
        _rec = Map<String, dynamic>.from(rec);
      });
      if (_source.isDeviceLedger && _rec['status'] != 'approved') return;
      // The premium Crystal Balance Seal — the REAL recorded kind from the
      // backend (scope_json.kind), never a guess from account names.
      final scope = _rec['scope_json'] is Map
          ? Map<String, dynamic>.from(_rec['scope_json'] as Map)
          : <String, dynamic>{};
      final kind = '${scope['kind'] ?? ''}' == 'cash'
          ? ReconEqualizeKind.cash
          : ReconEqualizeKind.bank;
      await showCrystalSuccess(
        context,
        kind: kind,
        onAgain: () {},
        onExit: () {},
      ).then((action) {
        if (!mounted) return;
        if (action == ReconSuccessAction.again) {
          context.go(RouteNames.reconciliationBank);
        } else {
          context.go(RouteNames.dashboard);
        }
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final fresh = ref.read(reconciliationApiProvider).conflictFresh(e);
      if (e.response?.statusCode == 409 && fresh != null) {
        final id = '${fresh['account_id']}';
        for (final l in _lines) {
          if ('${l['account_id']}' == id) {
            l['system'] = fresh['system'];
            l['diff'] =
                ((l['actual'] ?? 0) as num).toDouble() -
                asDoubleValue(fresh['system']);
          }
        }
        unawaited(ScanSfx.error());
        showFyonaSnack(
          context,
          l10n.translate('reconConflict'),
          success: false,
        );
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

  Future<void> _refreshEqualization() async {
    if (!_matches(ref.read(reconciliationApiProvider)) ||
        _rec['authority_state'] != 'queued') return;
    try {
      final record = await _source.detail('${_rec['id']}');
      if (mounted && _matches(ref.read(reconciliationApiProvider))) {
        setState(() => _rec = record);
      }
    } catch (_) {
      // A revoked/suspended scope never falls back to the legacy writer.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final current = ref.watch(reconciliationApiProvider);
    if (current.isDeviceLedger) {
      ref.listen(businessBankRevisionProvider, (_, __) { unawaited(_refreshEqualization()); });
    }
    final allowed =
        _matches(current) &&
        (!current.isDeviceLedger ||
            ref.watch(localBankReconciliationAllowedProvider));
    final lines = allowed ? _lines : <Map<String, dynamic>>[];
    final matched = lines
        .where((l) => asDoubleValue(l['diff']).abs() <= 1e-9)
        .length;
    final short = lines.where((l) => asDoubleValue(l['diff']) < -1e-9).length;
    final surplus = lines.where((l) => asDoubleValue(l['diff']) > 1e-9).length;
    final approved = '${_rec['status']}' == 'approved';
    final authorityLabel = allowed ? reconCashDecisionLabel(_rec) : null;
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
          l10n.translate('reconResultTitle'),
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 16),
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
      ),
      body: SafeArea(
        child: !allowed
            ? Center(child: Text(l10n.translate('reconDeviceDenied')))
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  ReconResultHeader(
                    matched: matched,
                    shortCount: short,
                    surplusCount: surplus,
                  ),
                  const SizedBox(height: 16),
                  ReconDiffTable(
                    money: true,
                    firstColumnLabel: l10n.translate('currencyLabel'),
                    rows: [
                      for (final l in lines)
                        ReconResultRow(
                          name: '${l['currency']}',
                          mark: '${l['name']}',
                          markColorKey:
                              _multiTypeCurrencies.contains(
                                '${l['currency']}'.toUpperCase(),
                              )
                              ? '${l['account_type'] ?? 'checking'}'
                              : null,
                          system: asDoubleValue(l['system']),
                          actual: asDoubleValue(l['actual']),
                          diff: asDoubleValue(l['diff']),
                          unit: '${l['currency']}',
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (authorityLabel != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(l10n.translate(authorityLabel), textAlign: TextAlign.center),
                    ),
                  if (!approved &&
                      ref.watch(
                        employeeCanProvider('reconciliation.equalize'),
                      ) &&
                      lines.any((l) => asDoubleValue(l['diff']).abs() > 1e-9))
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                        ),
                        onPressed: _busy ? null : _equalize,
                        icon: const Icon(Icons.balance_rounded),
                        label: Text(
                          l10n.translate('reconEqualizeSystem'),
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                          ),
                        ),
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
                      child: Row(
                        children: [
                          const Icon(
                            Icons.verified_rounded,
                            color: kReconActual,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            l10n.translate('reconEqualized'),
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontWeight: FontWeight.w800,
                              color: kReconActual,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
