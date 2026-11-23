import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/reconciliation_api.dart';
import '../../../core_business/presentation/providers/business_ledger_session.dart';
import '../widgets/recon_results.dart';
import '../widgets/recon_widgets.dart';

/// Past matches (السجل): TWO main section buttons (bank/cash · inventory),
/// then simple filters — الكل / هذا الشهر / هذه السنة / بين تاريخين — using
/// the EXACT same date-range calendar as the reports section.
class ReconArchivePage extends ConsumerStatefulWidget {
  const ReconArchivePage({super.key});

  @override
  ConsumerState<ReconArchivePage> createState() => _ReconArchivePageState();
}

class _ReconArchivePageState extends ConsumerState<ReconArchivePage> {
  String _rtype = ''; // '' = none yet? default bank
  String _period = 'all';
  DateTime? _from;
  DateTime? _to;
  bool _loading = true;
  int _generation = 0;
  Object? _error;
  ReconciliationApi? _shown;
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();
    _rtype = 'bank';
    _load();
  }

  (String?, String?) _bounds() {
    final now = DateTime.now();
    switch (_period) {
      case 'month':
        return (
          DateTime(now.year, now.month).toIso8601String().split('T').first,
          null,
        );
      case 'year':
        return (DateTime(now.year).toIso8601String().split('T').first, null);
      case 'range':
        return (
          _from?.toIso8601String().split('T').first,
          _to != null
              ? DateTime(
                  _to!.year,
                  _to!.month,
                  _to!.day,
                  23,
                  59,
                  59,
                ).toIso8601String()
              : null,
        );
      default:
        return (null, null);
    }
  }

  Future<void> _openDetail(Map<String, dynamic> item) async {
    final api = ref.read(reconciliationApiProvider);
    if (!identical(_shown, api)) return;
    final id = '${item['id']}';
    if (api.isDeviceLedger) {
      final link = LocalReconciliationLink(
        api,
        id,
        rtype: '${item['rtype'] ?? 'bank'}',
      );
      if (!link.matches(api)) return;
      await context.push('/reconciliation/detail', extra: link);
    } else {
      await context.push('/reconciliation/detail?id=$id');
    }
    if (mounted) await _load();
  }

  Future<void> _load() async {
    final api = ref.read(reconciliationApiProvider);
    final generation = ++_generation;
    bool current() =>
        mounted &&
        generation == _generation &&
        identical(api, ref.read(reconciliationApiProvider));
    setState(() {
      _shown = api;
      _loading = true;
      _items = const [];
      _error = null;
    });
    final (f, t) = _bounds();
    try {
      final items = await api.archive(rtype: _rtype, dateFrom: f, dateTo: t);
      // newest → oldest, always (backend already sorts; belt and braces).
      final sortedItems = [...items]
        ..sort(
          (a, b) => ('${b['created_at'] ?? ''}').compareTo(
            '${a['created_at'] ?? ''}',
          ),
        );
      if (current()) setState(() => _items = sortedItems);
    } catch (e) {
      if (current()) setState(() => _error = e);
    }
    if (current()) setState(() => _loading = false);
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: now,
      initialDateRange: DateTimeRange(
        start: _from ?? now.subtract(const Duration(days: 30)),
        end: _to ?? now,
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _period = 'range';
        _from = picked.start;
        _to = picked.end;
      });
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final api = ref.watch(reconciliationApiProvider);
    if (api.isDeviceLedger) {
      ref.listen(businessBankRevisionProvider, (_, __) {
        if (mounted && _rtype != 'inventory') _load();
      });
    }
    ref.listen(reconciliationApiProvider, (_, __) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    });
    final allowed =
        !api.isDeviceLedger ||
        (_rtype == 'inventory'
            ? ref.watch(localInventoryReconciliationAllowedProvider)
            : ref.watch(localBankReconciliationAllowedProvider));
    final items = identical(_shown, api)
        ? _items
        : const <Map<String, dynamic>>[];
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
          l10n.translate('reconArchive'),
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 16),
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // ── The two main section buttons ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Row(
                children: [
                  Expanded(
                    child: _SectionButton(
                      label: l10n.translate('reconBankCashTab'),
                      icon: Icons.account_balance_rounded,
                      active: _rtype == 'bank',
                      onTap: () {
                        setState(() => _rtype = 'bank');
                        _load();
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _SectionButton(
                      label: l10n.translate('reconInventoryTab'),
                      icon: Icons.inventory_2_rounded,
                      active: _rtype == 'inventory',
                      onTap: () {
                        setState(() => _rtype = 'inventory');
                        _load();
                      },
                    ),
                  ),
                ],
              ),
            ),
            // ── Filters: الكل / هذا الشهر / هذه السنة / بين تاريخين ──
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                children: [
                  _chip(l10n.translate('reconFilterAll'), 'all'),
                  _chip(l10n.translate('reconFilterMonth'), 'month'),
                  _chip(l10n.translate('reconFilterYear'), 'year'),
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: ActionChip(
                      avatar: const Icon(
                        Icons.date_range_rounded,
                        size: 15,
                        color: AppColors.primary,
                      ),
                      label: Text(
                        _period == 'range' && _from != null
                            ? '${_from!.toIso8601String().split('T').first}'
                                  ' — ${_to?.toIso8601String().split('T').first}'
                            : l10n.translate('reconFilterRange'),
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary,
                        ),
                      ),
                      backgroundColor: _period == 'range'
                          ? AppColors.primary.withAlpha(30)
                          : null,
                      onPressed: _pickRange,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: !allowed
                  ? Center(child: Text(l10n.translate('reconDeviceDenied')))
                  : _loading
                  ? api.isDeviceLedger
                        ? const SizedBox.shrink()
                        : const Center(
                            child: CircularProgressIndicator(
                              color: AppColors.primary,
                            ),
                          )
                  : _error != null
                  ? Center(child: Text(reconErrorMessage(l10n, _error!)))
                  : items.isEmpty
                  ? Center(
                      child: Text(
                        l10n.translate('reconEmpty'),
                        style: const TextStyle(fontFamily: 'Cairo'),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      itemCount: items.length,
                      itemBuilder: (_, i) => _ArchiveRow(
                        item: items[i],
                        dark: dark,
                        l10n: l10n,
                        onTap: () => _openDetail(items[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, String value) {
    final selected = _period == value;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: ChoiceChip(
        label: Text(
          label,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : AppColors.textSecondary,
          ),
        ),
        selected: selected,
        selectedColor: AppColors.primary,
        showCheckmark: false,
        onSelected: (_) {
          setState(() => _period = value);
          _load();
        },
      ),
    );
  }
}

class _SectionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  const _SectionButton({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 8),
        decoration: BoxDecoration(
          color: active ? AppColors.primary.withAlpha(20) : AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active ? AppColors.primary : AppColors.border,
            width: active ? 1.4 : 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: active ? AppColors.primary : AppColors.textSecondary,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 11.5),
                  fontWeight: FontWeight.w800,
                  color: active ? AppColors.primary : AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArchiveRow extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool dark;
  final AppLocalizations l10n;
  final VoidCallback onTap;
  const _ArchiveRow({
    required this.item,
    required this.dark,
    required this.l10n,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final rtype = '${item['rtype']}';
    final status = '${item['status']}';
    final when = '${item['created_at'] ?? ''}'
        .split('T')
        .join(' ')
        .split('.')
        .first;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      child: ReconTiltCard(
        onTap: onTap,
        elevation: 5,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(16),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  rtype == 'bank'
                      ? Icons.account_balance_rounded
                      : Icons.inventory_2_rounded,
                  color: AppColors.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${item['ref_code'] ?? ''}',
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        _statusChip(status),
                      ],
                    ),
                    Text(
                      when,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 10.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: AppColors.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// ONLY the result state: اختلاف (red) when reality ≠ system, سليم (green)
  /// otherwise — no other labels.
  Widget _statusChip(String status) {
    final bool hasDiff = item['has_diff'] == true;
    final (color, label) = hasDiff
        ? (kReconDiff, l10n.translate('reconChipDiff'))
        : (kReconActual, l10n.translate('reconChipOk'));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(22),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
