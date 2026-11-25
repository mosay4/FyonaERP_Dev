import 'package:flutter/material.dart';
import '../../../core_business/presentation/widgets/business_number_field.dart';
import 'package:fyona_flutter/features/core_business/presentation/widgets/debt_section_picker.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fyona_flutter/shared/widgets/biz_currency_items.dart';
import '../../../../../core/localization/app_localizations.dart';
import '../../../../../core/responsive/r_api.dart';
import '../../../../../core/services/currency/currency_engine.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/utils/currency_formatter.dart';
import '../../../../../core/utils/amount_input_formatter.dart';
import '../../../../../shared/widgets/business_selection_sheet.dart';
import '../../../sales/presentation/providers/sale_providers.dart'
    show SalePaymentRow, SaleItem;
import '../../../sales/presentation/widgets/sale_field.dart';
import '../../../sales/presentation/widgets/sale_payment_section.dart'
    show openBankCurrencyPicker;
import '../../../sales/presentation/widgets/sale_section_card.dart';
import '../providers/purchase_providers.dart';

/// Payment for a purchase invoice — identical mechanism to the sale payment
/// section (multi-account / multi-currency, frozen rate snapshot, split for
/// full+partial, invoice-currency override only with >1 bank), with the money
/// moving OUT of the accounts instead of in.
class PurchasePaymentSection extends ConsumerWidget {
  final List<String> allowedModes;
  const PurchasePaymentSection(
      {super.key,
      this.allowedModes = const ['full', 'partial', 'credit']});

  static const _payModes = ['full', 'partial', 'credit'];

  Future<void> _pickMode(
      BuildContext context, WidgetRef ref, int? current) async {
    final l10n = AppLocalizations.of(context);
    // A CASH supplier (no registered party) can be paid in full — cash sales
    // cannot be indebted, so «دفع كامل» must appear even in debt mode.
    final isCash = (ref.read(purchaseDraftProvider).supplier?.id ?? '').isEmpty;
    final modes = List<String>.from(allowedModes);
    if (isCash && !modes.contains('full')) modes.insert(0, 'full');
    final picked = await showBusinessSelectionSheet<String>(
      context: context,
      title: l10n.translate('saleChoosePayMode'),
      selected: current == null ? null : _payModes[current],
      items: [
        for (final m in modes)
          BizSheetItem(
              value: m,
              title: l10n.translate(m == 'full'
                  ? 'salePaidFull'
                  : (m == 'partial' ? 'salePaidPartial' : 'salePaidCredit')),
              icon: m == 'full'
                  ? Icons.check_circle_outline
                  : (m == 'partial'
                      ? Icons.pie_chart_outline
                      : Icons.schedule_outlined)),
      ],
    );
    if (picked == null || !context.mounted) return;
    final mode = _payModes.indexOf(picked);
    final notifier = ref.read(purchaseDraftProvider.notifier);
    notifier.setPayMode(mode);
    final draft = ref.read(purchaseDraftProvider);
    if (mode != 2 && draft.payments.isEmpty) {
      notifier.setPayments(
          [const SalePaymentRow(accountId: '', accountName: '', amount: 0)]);
    }
    if (mode == 2) notifier.setPayments(const []);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(purchaseDraftProvider);
    final accountsAsync = ref.watch(purchaseAccountsProvider);
    final l10n = AppLocalizations.of(context);
    final notifier = ref.read(purchaseDraftProvider.notifier);
    const modeTitles = ['salePaidFull', 'salePaidPartial', 'salePaidCredit'];
    return SaleSectionCard(
      titleKey: 'salePayment',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Label(text: l10n.translate('salePayMode')),
          SaleField(
            value: draft.payMode == null
                ? ''
                : l10n.translate(modeTitles[draft.payMode!]),
            placeholder: l10n.translate('saleTapToSelectPayMode'),
            onTap: () => _pickMode(context, ref, draft.payMode),
          ),
          if ((draft.payMode == 1 || draft.payMode == 2) &&
              (draft.supplier?.id ?? '').isNotEmpty) ...[
            const SizedBox(height: 10),
            DebtSectionPicker(
              partyKind: 'supplier',
              partyId: draft.supplier!.id!,
              current: draft.debtGroupId,
              onChanged: (v) => notifier.setDebtGroup(v),
            ),
          ],
          if (draft.payMode == null) ...[
            const SizedBox(height: 8),
            Text(l10n.translate('saleNeedPayMode'),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 12),
                    color: AppColors.textSecondary)),
          ],
          if (draft.payMode == 2) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(20),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.warning.withAlpha(70)),
              ),
              child: Text(
                l10n.translate('purCreditHint'),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 12),
                    color: AppColors.textPrimary),
              ),
            ),
            const SizedBox(height: 10),
            _Label(text: l10n.translate('invCurrency')),
            SaleField(
              value: draft.currency.isEmpty
                  ? ''
                  : currencyName(draft.currency),
              placeholder: l10n.translate('invChooseInvoiceCurrency'),
              onTap: () async {
                final accounts = accountsAsync.valueOrNull ?? const [];
                final currencies = await limitToBizCurrencies(
                    ref, _distinctCurrencies(accounts));
                if (currencies.isEmpty || !context.mounted) return;
                final picked = await showBusinessSelectionSheet<String>(
                  context: context,
                  title: l10n.translate('invCurrency'),
                  selected: draft.currency,
                  items: [
                    for (final c in currencies)
                      BizSheetItem(
                          value: c,
                          title: '${currencyFlagEmoji(c)} ${currencyLabel(c)}',
                          icon: Icons.monetization_on_outlined),
                  ],
                );
                if (picked == null || !context.mounted) return;
                notifier.setCurrency(picked);
                applyPurchaseInvoiceCurrency(ref, picked);
              },
            ),
          ] else if (draft.payMode != null) ...[
            const SizedBox(height: 10),
            _Label(text: l10n.translate('salePayAccount')),
            accountsAsync.when(
              loading: () => const Center(
                  child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2))),
               error: (_, __) => Text(l10n.translate('bankingLoadAccountsFailedNoDetail'),
                  style: const TextStyle(fontFamily: 'Cairo')),
              data: (accounts) {
                final rows = draft.payments;
                final firstAccIdx = rows.indexWhere((p) => p.accountId.isNotEmpty);
                return Column(
                  children: [
                    for (var i = 0; i < rows.length; i++)
                      _PurchasePaymentRow(
                        index: i,
                        row: rows[i],
                        accounts: accounts,
                        invoiceCurrency: draft.currency,
                        total: draft.total,
                        removable: rows.length > 1,
                        fullMode: draft.payMode == 0 &&
                            i == (firstAccIdx < 0 ? 0 : firstAccIdx),
                      ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        onPressed: () => notifier.setPayments([
                          ...rows,
                          const SalePaymentRow(
                              accountId: '', accountName: '', amount: 0),
                        ]),
                        icon: const Icon(Icons.add, size: 18),
                        label: Text(l10n.translate('saleSplitPayment'),
                            style: const TextStyle(fontFamily: 'Cairo')),
                      ),
                    ),
                    if (draft.payments.where((p) => p.accountId.isNotEmpty).length > 1 &&
                        draft.currency.isNotEmpty)
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          onPressed: () => _changeInvoiceCurrency(
                              context, ref, accounts, draft),
                          icon: const Icon(Icons.currency_exchange, size: 18),
                          label: Text(
                              l10n.translate('saleChangeInvoiceCurrency'),
                              style: const TextStyle(fontFamily: 'Cairo')),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
          const SizedBox(height: 4),
          if (draft.payMode != null &&
              draft.payMode != 0 &&
              draft.remaining > 0.005)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(20),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.warning.withAlpha(70)),
              ),
              child: Text(
                l10n.translate('purPayableNotice', params: {
                  'amount':
                      '${fmtNum(draft.remaining)}${draft.currency.isEmpty ? '' : ' ${draft.currency}'}'
                }),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 12),
                    color: AppColors.textPrimary),
              ),
            ),
          if (draft.paid - draft.total > 0.005)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.danger.withAlpha(20),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.danger.withAlpha(90)),
              ),
              child: Text(
                l10n.translate('saleOverpaidNotice', params: {
                  'amount':
                      '${fmtNum(draft.paid - draft.total)}${draft.currency.isEmpty ? '' : ' ${draft.currency}'}'
                }),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 12),
                    fontWeight: FontWeight.w700,
                    color: AppColors.danger),
              ),
            ),
          _Summary(label: l10n.translate('salePaid'), value: draft.paid, cur: draft.currency, color: AppColors.success),
          _Summary(label: l10n.translate('saleRemaining'), value: draft.remaining, cur: draft.currency, color: draft.remaining > 0 ? AppColors.danger : AppColors.textPrimary),
        ],
      ),
    );
  }
}

Set<String> _distinctCurrencies(List<Map<String, String>> accounts) => {
  for (final a in accounts)
    if ((a['currency'] ?? '').isNotEmpty) (a['currency']!).toUpperCase()
};

Set<String> _distinctBanks(List<Map<String, String>> accounts) => {
      for (final a in accounts)
        (a['bank'] ?? '').trim().isEmpty ? 'cash' : (a['bank'] ?? '').trim()
    };

double _rateOf(WidgetRef ref, String from, String to) {
  if (from.isEmpty || to.isEmpty || from == to) return from == to ? 1 : 0;
  final r = ref.read(currencyEngineProvider).getRate(from, to);
  return (r == null || r <= 0) ? 0 : r;
}

String _rateSource(String from, String to, double rate) {
  if (from == to) return 'same';
  return rate > 0 ? 'auto' : 'manual';
}

/// Mirrors [applySaleInvoiceCurrency] for purchase invoices: a manually edited
/// buy price is converted from the currency it was entered in (never reset to
/// the catalogue), otherwise the per-currency price is used/converted. The
/// stored product price is never mutated.
void applyPurchaseInvoiceCurrency(WidgetRef ref, String currency) {
  final draft = ref.read(purchaseDraftProvider);
  if (draft.items.isEmpty) return;
  final engine = ref.read(currencyEngineProvider);
  final next = resolvePurchasePrices(
      draft.items, currency, (from, to) => engine.getRate(from, to));
  if (!identical(next, draft.items)) {
    ref.read(purchaseDraftProvider.notifier).setItems(next);
  }
}

/// Pure price resolver for purchase lines (mirrors [resolveSalePrices]).
List<SaleItem> resolvePurchasePrices(
    List<SaleItem> items, String currency, double? Function(String, String) rateOf) {
  var changed = false;
  final next = <SaleItem>[];
  for (final it in items) {
    if (it.priceManual) {
      final from = (it.manualPriceCurrency ?? '').isNotEmpty
          ? it.manualPriceCurrency!
          : currency;
      if (from == currency) {
        if ((it.manualPriceCurrency ?? '') != currency) {
          changed = true;
          next.add(it.copyWith(manualPriceCurrency: currency));
        } else {
          next.add(it);
        }
        continue;
      }
      final r = rateOf(from, currency);
      if (r == null || r <= 0) {
        next.add(it);
        continue;
      }
      changed = true;
      next.add(it.copyWith(
        unitPrice: double.parse((it.unitPrice * r).toStringAsFixed(4)),
        manualPriceCurrency: currency,
        exchangeRateUsed: r,
        priceCurrency: from,
        originalUnitPrice: it.unitPrice,
      ));
      continue;
    }
    final sp = it.sellPrices;
    if (sp == null || sp.isEmpty || it.productId == null) {
      next.add(it);
      continue;
    }
    if (sp.containsKey(currency)) {
      changed = true;
      next.add(it.copyWith(
        unitPrice: sp[currency]!,
        priceCurrency: currency,
        originalUnitPrice: sp[currency],
        exchangeRateUsed: 1,
      ));
    } else {
      final from = it.priceCurrency ?? sp.keys.first;
      final base = sp[from] ?? it.unitPrice;
      final r = rateOf(from, currency);
      // NEVER assume 1:1 — block issuing (validation) when no real rate exists.
      if (r == null || r <= 0) {
        next.add(it);
        continue;
      }
      changed = true;
      next.add(it.copyWith(
        unitPrice: double.parse((base * r).toStringAsFixed(4)),
        priceCurrency: from,
        originalUnitPrice: base,
        exchangeRateUsed: r,
      ));
    }
  }
  return changed ? next : items;
}

class _Label extends StatelessWidget {
  final String text;
  const _Label({required this.text});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text,
          style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 13),
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary)),
    );
  }
}

class _Summary extends StatelessWidget {
  final String label;
  final double value;
  final String cur;
  final Color color;
  const _Summary(
      {required this.label, required this.value, required this.cur, required this.color});
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 13),
                color: AppColors.textSecondary)),
        Text('${fmtNum(value)}${cur.isEmpty ? '' : ' $cur'}',
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 14),
                fontWeight: FontWeight.w700,
                color: color)),
      ],
    );
  }
}

class _PurchasePaymentRow extends ConsumerWidget {
  final int index;
  final SalePaymentRow row;
  final List<Map<String, String>> accounts;
  final String invoiceCurrency;
  final double total;
  final bool removable;
  final bool fullMode;
  const _PurchasePaymentRow({
    required this.index,
    required this.row,
    required this.accounts,
    required this.invoiceCurrency,
    required this.total,
    required this.removable,
    this.fullMode = false,
  });

  void _replace(WidgetRef ref, SalePaymentRow next) {
    final draft = ref.read(purchaseDraftProvider);
    final rows = [...draft.payments];
    if (index < rows.length) {
      rows[index] = next;
    } else {
      rows.add(next);
    }
    ref.read(purchaseDraftProvider.notifier).setPayments(rows);
  }

  static String _label(Map<String, String> a) {
    final bank = a['bank'] ?? '';
    final name = a['name'] ?? '';
    if (bank.isEmpty) return name;
    if (name.isEmpty) return bank;
    return '$bank - $name';
  }

  static String _methodFor(String bank) {
    final b = bank.trim();
    return (b == 'كاش' || b == 'Cash' || b == 'CASH') ? 'cash' : 'bank';
  }

  Future<void> _pickAccount(BuildContext context, WidgetRef ref) async {
    final fresh = await ref.refresh(purchaseAccountsProvider.future);
    if (!context.mounted) return;
    final picked = await openBankCurrencyPicker(context, fresh,
        selectedId: row.accountId.isEmpty ? null : row.accountId);
    if (picked == null || !context.mounted) return;
    final newCur = picked.currency;
    final draft = ref.read(purchaseDraftProvider);
    // The FIRST payment row defines the invoice currency; changing it updates
    // the whole invoice. Later rows convert into it.
    final invoiceCur =
        (index == 0 || draft.currency.isEmpty) ? newCur : draft.currency;
    final rate = _rateOf(ref, newCur, invoiceCur);
    var updated = row.copyWith(
      accountId: picked.accountId,
      accountName: _label(picked.account),
      bankName: picked.bankName,
      currency: newCur,
      exchangeRate: rate <= 0 ? 0 : rate,
      rateSource: _rateSource(newCur, invoiceCur, rate),
      rateTimestamp: newCur == invoiceCur ? null : DateTime.now(),
      method: _methodFor(picked.bankName),
    );
    if (row.amount == 0 && draft.payMode == 0 && rate > 0) {
      final other = [
        for (var i = 0; i < draft.payments.length; i++)
          if (i != index) draft.payments[i].equivalent
      ].fold<double>(0, (s, e) => s + e);
      final target = (total - other) < 0 ? 0.0 : total - other;
      updated = updated.copyWith(amount: target / rate);
    }
    final rows = [...draft.payments];
    if (index < rows.length) {
      rows[index] = updated;
    } else {
      rows.add(updated);
    }
    ref
        .read(purchaseDraftProvider.notifier)
        .setCurrencyAndPayments(invoiceCur, rows);
    applyPurchaseInvoiceCurrency(ref, invoiceCur);
  }

  Future<void> _editRate(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController(
        text: row.exchangeRate > 0 ? _fmt(row.exchangeRate) : '');
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.translate('saleEditRate'),
            style: const TextStyle(fontFamily: 'Cairo', fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('1 ${row.currency} = ? $invoiceCurrency',
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 13)),
            const SizedBox(height: 10),
            BusinessNumberField(
              controller: ctrl,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(fontFamily: 'Cairo'),
              decoration: InputDecoration(
                  hintText: l10n.translate('saleExchangeRate'),
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10))),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.translate('saleClose'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              onPressed: () => Navigator.pop(
                  ctx, double.tryParse(ctrl.text.trim().replaceAll(',', ''))),
              child: Text(l10n.translate('saleValue'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
        ],
      ),
    );
    ctrl.dispose();
    if (result == null || result <= 0) return;
    _replace(
        ref,
        row.copyWith(
            exchangeRate: result,
            rateSource: 'manual',
            rateTimestamp: DateTime.now()));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final cross = row.currency.isNotEmpty && row.currency != invoiceCurrency;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 5,
                child: SaleField(
                  value: row.accountId.isEmpty ? '' : _acctLabel(row),
                  placeholder: l10n.translate('saleTapToSelectPayAccount'),
                  compact: true,
                  onTap: () => _pickAccount(context, ref),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 4,
                child: BusinessNumberField(
                  formField: true,
                  key: ValueKey('pur_${index}_${row.accountId}_${row.currency}'
                      '${fullMode ? '_${row.amount}' : ''}'),
                  initialValue: row.amount == 0 ? (fullMode ? '0' : '') : fmtNum(row.amount),
                  readOnly: fullMode,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [AmountInputFormatter()],
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 12),
                      fontWeight: FontWeight.w600),
                  decoration: InputDecoration(
                    hintText: l10n.translate('salePaidAmountHint'),
                    hintStyle: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11)),
                    suffixText: row.currency.isEmpty ? null : row.currency,
                    suffixStyle: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 10),
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 12),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onChanged: (v) {
                    final parsed = parseFormattedAmount(v) ?? 0;
                    ref
                        .read(purchaseDraftProvider.notifier)
                        .setPaymentAmount(index, parsed < 0 ? 0 : parsed);
                  },
                ),
              ),
              if (removable)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    final draft = ref.read(purchaseDraftProvider);
                    final rows = [...draft.payments];
                    if (index < rows.length) rows.removeAt(index);
                    ref.read(purchaseDraftProvider.notifier).setPayments(rows);
                  },
                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                  color: AppColors.danger,
                ),
            ],
          ),
          if (cross) ...[
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 4, end: 4),
              child: Row(
                children: [
                  Text(
                    '1 ${row.currency} = ${row.exchangeRate > 0 ? _fmt(row.exchangeRate) : '?'} $invoiceCurrency',
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11),
                        color: AppColors.textSecondary),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: row.rateSource == 'manual'
                          ? AppColors.warning.withAlpha(30)
                          : AppColors.success.withAlpha(24),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      l10n.translate(row.rateSource == 'manual'
                          ? 'saleRateManual'
                          : 'saleRateAuto'),
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 10),
                          fontWeight: FontWeight.w700,
                          color: row.rateSource == 'manual'
                              ? AppColors.warning
                              : AppColors.success),
                    ),
                  ),
                  const Spacer(),
                  Text('≈ ${fmtNum(row.equivalent)} $invoiceCurrency',
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 11),
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: () => _editRate(context, ref),
                    icon: const Icon(Icons.edit_outlined, size: 15),
                    color: AppColors.primary,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

Future<void> _changeInvoiceCurrency(
  BuildContext context,
  WidgetRef ref,
  List<Map<String, String>> accounts,
  PurchaseDraft draft,
) async {
  final l10n = AppLocalizations.of(context);
  final currencies = await limitToBizCurrencies(ref, [
    for (final a in accounts)
      if ((a['currency'] ?? '').isNotEmpty) a['currency']!,
  ]);
  if (!context.mounted) return;
  final picked = await showBusinessSelectionSheet<String>(
    context: context,
    title: l10n.translate('saleChangeInvoiceCurrency'),
    selected: draft.currency,
    items: [
      for (final c in currencies)
        BizSheetItem(
            value: c,
            title: '${currencyFlagEmoji(c)} ${currencyLabel(c)}',
            icon: Icons.monetization_on_outlined),
    ],
  );
  if (picked == null || !context.mounted || picked == draft.currency) return;
  final rows = [
    for (final p in draft.payments)
      p.copyWith(
        exchangeRate: _rateOf(ref, p.currency, picked) <= 0
            ? 0
            : _rateOf(ref, p.currency, picked),
        rateSource:
            _rateSource(p.currency, picked, _rateOf(ref, p.currency, picked)),
        rateTimestamp: p.currency == picked ? null : DateTime.now(),
      )
  ];
  ref
      .read(purchaseDraftProvider.notifier)
      .setCurrencyAndPayments(picked, rows);
  applyPurchaseInvoiceCurrency(ref, picked);
}

String _fmt(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);

/// Full, unambiguous account chip: «كاش-USD», «بنك التضامن-SAR».
String _acctLabel(SalePaymentRow r) {
  final bank = r.bankName.trim().isEmpty ? r.accountName : r.bankName;
  return r.currency.isEmpty ? bank : '$bank-${r.currency}';
}
