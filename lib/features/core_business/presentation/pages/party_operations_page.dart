import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/document_number.dart';
import '../../data/local_directory/directory_database.dart';
import '../../data/local_directory/directory_party.dart';
import '../../data/local_directory/directory_pilot.dart';
import '../providers/business_ledger_session.dart';
import '../providers/local_commerce_navigation.dart';

/// Full, organized history of one customer/supplier: debts, invoices,
/// returns and payments, grouped by day. Device-local parties read the
/// branch ledger; legacy (server) parties show the invoice timeline the
/// detail page already loaded.
class PartyOperationsPage extends ConsumerStatefulWidget {
  const PartyOperationsPage({
    super.key,
    required this.isSupplier,
    required this.name,
    this.localParty,
    this.legacyOps = const [],
  });

  final bool isSupplier;
  final String name;
  final DirectoryPartyReference? localParty;
  final List<Map<String, dynamic>> legacyOps;

  @override
  ConsumerState<PartyOperationsPage> createState() =>
      _PartyOperationsPageState();
}

enum _Filter { all, invoices, payments, returns, debts }

class _PartyOperationsPageState extends ConsumerState<PartyOperationsPage> {
  List<Map<String, Object?>>? _ops;
  bool _failed = false;
  _Filter _filter = _Filter.all;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    final local = widget.localParty;
    if (local == null) {
      final type = widget.isSupplier ? 'purchase' : 'sale';
      _ops = [
        for (final o in widget.legacyOps)
          {
            'type': type,
            'id': o['invoice_id'],
            'number': o['invoice_number'],
            'date': o['date'],
            'currency': o['currency'],
            'amount': o['total'],
            'paid': o['paid'],
            'remaining': o['balance'],
          },
      ]..sort((a, b) => '${b['date']}'.compareTo('${a['date']}'));
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    final local = widget.localParty;
    if (local == null) return;
    final revision = ++_revision;
    try {
      final scope = local.requireScope(ref.read(directoryPilotAccessProvider));
      final rows = await withBusinessLedger(
        ref,
        scope,
        BusinessLedgerAction.readDebt,
        ['${local.kind.name}s.details', 'debts.details'],
        (ledger, grant) => ledger.partyActivity(grant, local),
      );
      if (!mounted || revision != _revision) return;
      setState(() {
        _ops = rows;
        _failed = false;
      });
    } catch (_) {
      if (!mounted || revision != _revision) return;
      setState(() {
        _ops ??= const [];
        _failed = true;
      });
    }
  }

  // ── presentation helpers ─────────────────────────────────────────────

  static const _blue = Color(0xFF2563C9);
  static const _green = Color(0xFF16855A);
  static const _amber = Color(0xFFC56A0A);
  static const _crimson = Color(0xFFB00020);

  _Filter _bucket(String type) => switch (type) {
    'sale' || 'purchase' => _Filter.invoices,
    'payment' => _Filter.payments,
    'sale_return' || 'purchase_return' => _Filter.returns,
    _ => _Filter.debts,
  };

  ({IconData icon, Color color, String label}) _look(
    AppLocalizations l10n,
    String type,
  ) => switch (type) {
    'sale' => (
      icon: Icons.receipt_long_rounded,
      color: _blue,
      label: l10n.translate('txKindSale'),
    ),
    'purchase' => (
      icon: Icons.shopping_bag_outlined,
      color: _blue,
      label: l10n.translate('txKindPurchase'),
    ),
    'payment' => (
      icon: Icons.payments_outlined,
      color: _green,
      label: l10n.translate(
        widget.isSupplier ? 'txKindSupplierPayment' : 'txKindCollection',
      ),
    ),
    'sale_return' => (
      icon: Icons.assignment_return_outlined,
      color: _amber,
      label: l10n.translate('txKindSaleReturn'),
    ),
    'purchase_return' => (
      icon: Icons.assignment_return_outlined,
      color: _amber,
      label: l10n.translate('txKindPurchaseReturn'),
    ),
    _ => (
      icon: Icons.account_balance_wallet_outlined,
      color: _crimson,
      label: l10n.translate('partyOpsDebt'),
    ),
  };

  double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

  String _day(String raw) => raw.length >= 10 ? raw.substring(0, 10) : raw;

  String _dayLabel(AppLocalizations l10n, String day) {
    final d = DateTime.tryParse(day);
    if (d == null) return day.isEmpty ? '—' : day;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(DateTime(d.year, d.month, d.day)).inDays;
    if (diff == 0) return l10n.translate('today');
    if (diff == 1) return l10n.translate('yesterday');
    return '${d.year}/${d.month.toString().padLeft(2, '0')}/'
        '${d.day.toString().padLeft(2, '0')}';
  }

  Future<void> _open(Map<String, Object?> op) async {
    final type = '${op['type']}';
    final local = widget.localParty;
    final scope = ref.read(businessLocalLedgerScopeProvider);
    switch (type) {
      case 'sale' || 'purchase':
        await openCommerceRecord(
          context,
          RouteNames.invoicesView,
          '${op['id']}',
          kind: type,
          fromLocal: local == null ? null : scope,
        );
      case 'sale_return' || 'purchase_return':
        await openCommerceRecord(
          context,
          RouteNames.returnsView,
          '${op['id']}',
          kind: type,
          fromLocal: scope,
        );
      case 'payment':
        final invoices = [
          for (final i in (op['invoices'] as List?) ?? const [])
            if (i is Map) Map<String, Object?>.from(i),
        ];
        if (invoices.length == 1) {
          await _openCovered(invoices.single);
        } else if (invoices.isNotEmpty) {
          await _pickCovered(invoices);
        }
      default:
        if (local == null) return;
        await context.push(
          '/debts/operation',
          extra: DirectoryDebtInvoiceReference(party: local, id: '${op['id']}'),
        );
    }
    if (mounted) await _load();
  }

  Future<void> _openCovered(Map<String, Object?> invoice) async {
    final local = widget.localParty;
    if ('${invoice['source']}' == 'debt') {
      if (local == null) return;
      await context.push(
        '/debts/operation',
        extra: DirectoryDebtInvoiceReference(party: local, id: '${invoice['id']}'),
      );
      return;
    }
    await openCommerceRecord(
      context,
      RouteNames.invoicesView,
      '${invoice['id']}',
      kind: '${invoice['invoice_type'] ?? (widget.isSupplier ? 'purchase' : 'sale')}',
      fromLocal: ref.read(businessLocalLedgerScopeProvider),
    );
  }

  Future<void> _pickCovered(List<Map<String, Object?>> invoices) async {
    final l10n = AppLocalizations.of(context);
    final picked = await showModalBottomSheet<Map<String, Object?>>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.translate('partyOpsCoveredTitle'),
                textAlign: TextAlign.center,
                style: _text(15, weight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              for (final i in invoices)
                ListTile(
                  leading: const Icon(Icons.receipt_long_rounded, color: _blue),
                  title: Text(
                    '#${shortDocumentNumber(i['number'])}',
                    style: _text(14, weight: FontWeight.w700),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.pop(ctx, i),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) await _openCovered(picked);
  }

  TextStyle _text(double size, {FontWeight weight = FontWeight.w500, Color? color}) =>
      TextStyle(
        fontFamily: 'Cairo',
        fontSize: size,
        fontWeight: weight,
        color: color ?? AppColors.textPrimary,
        height: 1.35,
      );

  // ── build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final all = _ops;
    final title = l10n.translate(
      widget.isSupplier ? 'partyOpsSupplierBtn' : 'partyOpsCustomerBtn',
    );
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: _text(16, weight: FontWeight.w800)),
            if (widget.name.isNotEmpty)
              Text(
                widget.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _text(12, color: AppColors.textSecondary),
              ),
          ],
        ),
      ),
      // Local data paints on the next frame; no spinner flashes meanwhile.
      body: all == null ? const SizedBox.shrink() : _body(l10n, all),
    );
  }

  Widget _body(AppLocalizations l10n, List<Map<String, Object?>> all) {
    final present = {for (final o in all) _bucket('${o['type']}')};
    final filters = [
      _Filter.all,
      for (final f in [_Filter.invoices, _Filter.payments, _Filter.returns, _Filter.debts])
        if (present.contains(f)) f,
    ];
    final shown = _filter == _Filter.all
        ? all
        : [for (final o in all) if (_bucket('${o['type']}') == _filter) o];
    final days = <String, List<Map<String, Object?>>>{};
    for (final o in shown) {
      days.putIfAbsent(_day('${o['date'] ?? ''}'), () => []).add(o);
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: AppColors.primary,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          _summary(l10n, all),
          if (filters.length > 2) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 38,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final f in filters)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: _chip(l10n, f),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 6),
          if (_failed && all.isEmpty)
            _empty(l10n.translate('errorOccurred'), Icons.error_outline)
          else if (shown.isEmpty)
            _empty(l10n.translate('debtEmptyOps'), Icons.inbox_outlined)
          else
            for (final day in days.entries) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                child: Row(
                  children: [
                    Icon(Icons.calendar_today_rounded,
                        size: 14, color: AppColors.textTertiary),
                    const SizedBox(width: 6),
                    Text(
                      _dayLabel(l10n, day.key),
                      style: _text(13, weight: FontWeight.w800,
                          color: AppColors.textSecondary),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Divider(color: AppColors.divider, height: 1)),
                  ],
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: AppColors.border.withValues(alpha: 0.6)),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (var i = 0; i < day.value.length; i++) ...[
                      if (i > 0)
                        Divider(height: 1, indent: 64, color: AppColors.divider),
                      _tile(l10n, day.value[i]),
                    ],
                  ],
                ),
              ),
            ],
        ],
      ),
    );
  }

  Widget _summary(AppLocalizations l10n, List<Map<String, Object?>> all) {
    int count(_Filter f) => all.where((o) => _bucket('${o['type']}') == f).length;
    Widget stat(String label, int n, Color color) => Expanded(
      child: Column(
        children: [
          Text('$n', style: _text(18, weight: FontWeight.w800, color: color)),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _text(11.5, color: AppColors.textSecondary)),
        ],
      ),
    );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          stat(l10n.translate('partyOpsAllCount'), all.length, AppColors.primary),
          stat(l10n.translate('invoices'), count(_Filter.invoices), _blue),
          stat(l10n.translate('payments'), count(_Filter.payments), _green),
          stat(l10n.translate('txKindReturn'), count(_Filter.returns), _amber),
          if (count(_Filter.debts) > 0)
            stat(l10n.translate('partyOpsDebts'), count(_Filter.debts), _crimson),
        ],
      ),
    );
  }

  Widget _chip(AppLocalizations l10n, _Filter f) {
    final selected = _filter == f;
    final label = switch (f) {
      _Filter.all => l10n.translate('all'),
      _Filter.invoices => l10n.translate('invoices'),
      _Filter.payments => l10n.translate('payments'),
      _Filter.returns => l10n.translate('txKindReturn'),
      _Filter.debts => l10n.translate('partyOpsDebts'),
    };
    return ChoiceChip(
      label: Text(label,
          style: _text(12.5,
              weight: FontWeight.w700,
              color: selected ? Colors.white : AppColors.textPrimary)),
      selected: selected,
      showCheckmark: false,
      selectedColor: AppColors.primary,
      backgroundColor: AppColors.surface,
      side: BorderSide(color: selected ? AppColors.primary : AppColors.border),
      shape: const StadiumBorder(),
      onSelected: (_) => setState(() => _filter = f),
    );
  }

  Widget _empty(String message, IconData icon) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Column(
      children: [
        Icon(icon, size: 44, color: AppColors.textTertiary),
        const SizedBox(height: 10),
        Text(message,
            textAlign: TextAlign.center,
            style: _text(13, color: AppColors.textSecondary)),
      ],
    ),
  );

  /// Amount + currency at the row end: compact, the number shrinks in steps
  /// with its length (and FittedBox guarantees even 13+ digits fit) so the
  /// title column always keeps its room.
  Widget _amount(String amount, String currency, Color color) {
    final digits = amount.replaceAll(RegExp(r'[^0-9]'), '').length;
    final size = digits <= 6
        ? 13.5
        : digits <= 8
            ? 12.5
            : digits <= 10
                ? 11.5
                : digits <= 12
                    ? 10.5
                    : 9.5;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.28,
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerEnd,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              amount,
              maxLines: 1,
              textDirection: TextDirection.ltr,
              style: _text(size, weight: FontWeight.w800, color: color)
                  .copyWith(height: 1.2),
            ),
            if (currency.trim().isNotEmpty)
              Text(
                currency,
                maxLines: 1,
                style: _text(10, weight: FontWeight.w600,
                        color: color.withValues(alpha: 0.75))
                    .copyWith(height: 1.15),
              ),
          ],
        ),
      ),
    );
  }

  Widget _tile(AppLocalizations l10n, Map<String, Object?> op) {
    final type = '${op['type']}';
    final look = _look(l10n, type);
    final arabic = Localizations.localeOf(context).languageCode == 'ar';
    final currency = currencyName('${op['currency'] ?? ''}',
        locale: arabic ? 'ar' : 'en');
    final amount = fmtNum(_num(op['amount']));
    final number = '${op['number'] ?? ''}';
    final remaining = _num(op['remaining']);
    final hasBalance = op.containsKey('remaining');
    String? sub;
    if (type == 'payment') {
      final covered = (op['invoices'] as List?) ?? const [];
      sub = covered.length == 1
          ? l10n.translate('partyOpsForInvoice', params: {
              'n': '#${shortDocumentNumber((covered.single as Map)['number'])}',
            })
          : l10n.translate('partyOpsForInvoices', params: {'n': '${covered.length}'});
      final account = '${op['account'] ?? ''}'.trim();
      if (account.isNotEmpty && account != 'null') sub = '$sub · $account';
    } else if (type.endsWith('_return')) {
      final inv = '${op['invoice_number'] ?? ''}';
      if (inv.isNotEmpty) {
        sub = l10n.translate('partyOpsForInvoice',
            params: {'n': '#${shortDocumentNumber(inv)}'});
      }
    } else if (hasBalance) {
      sub = remaining > 0.004
          ? '${l10n.translate('saleRemaining')}: ${fmtNum(remaining)} $currency'
          : l10n.translate('partyOpsSettled');
    }
    return InkWell(
      onTap: () => _open(op),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: look.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(look.icon, color: look.color, size: 22),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: LayoutBuilder(builder: (context, box) {
                // The label and the short number are never cut: each scales
                // down (rarely) instead of «فاتور…» / «#INV-…».
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        look.label,
                        maxLines: 1,
                        style: _text(13.5, weight: FontWeight.w700),
                      ),
                    ),
                    if (number.isNotEmpty || sub != null)
                      Row(
                        children: [
                          if (number.isNotEmpty)
                            ConstrainedBox(
                              // Leave room for «  ·  » and the remaining text.
                              constraints: BoxConstraints(
                                maxWidth: sub != null
                                    ? box.maxWidth * 0.55
                                    : box.maxWidth,
                              ),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: AlignmentDirectional.centerStart,
                                child: Text(
                                  '#${shortDocumentNumber(number)}',
                                  maxLines: 1,
                                  textDirection: TextDirection.ltr,
                                  style: _text(11.5,
                                      weight: FontWeight.w600,
                                      color: AppColors.textTertiary),
                                ),
                              ),
                            ),
                          if (number.isNotEmpty && sub != null)
                            Text('  ·  ',
                                style: _text(11.5,
                                    color: AppColors.textTertiary)),
                          if (sub != null)
                            Flexible(
                              child: Text(
                                sub,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: _text(
                                  11.5,
                                  color: hasBalance &&
                                          remaining <= 0.004 &&
                                          !type.endsWith('_return') &&
                                          type != 'payment'
                                      ? _green
                                      : AppColors.textSecondary,
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                );
              }),
            ),
            const SizedBox(width: 8),
            _amount(amount, currency, look.color),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded,
                size: 20, color: AppColors.textTertiary),
          ],
        ),
      ),
    );
  }
}
