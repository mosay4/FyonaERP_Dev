import 'package:flutter/material.dart';
import 'business_number_field.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/amount_input_formatter.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../purchases/presentation/providers/purchase_providers.dart';
import '../../../sales/presentation/providers/sale_providers.dart'
    show saleAccountsProvider;
import 'debt_widgets.dart';
import '../../../employees/presentation/providers/employee_providers.dart';

/// Collect-from-customer / pay-supplier sheet.
///
/// Flow (same professional bank → currency order as the personal
/// income/expense sheet): pick the BANK first, then a currency/account of that
/// bank, then the amount. A debt SECTION may be settled from any currency with
/// a live (editable) exchange rate; a SINGLE invoice is restricted to its own
/// original currency.
Future<bool> showDebtSettlementSheet(
  BuildContext context,
  WidgetRef ref, {
  required bool isSupplier,
  required String partyId,
  required String currency,
  required double remaining,
  String? groupId,
  String? invoiceId,
  LocalDebtSettlement? local,
}) async {
  if (!ref.read(employeeCanProvider('debts.settle'))) return false;
  final debtCur = currency.trim().toUpperCase();
  final crossAllowed =
      (groupId != null && groupId.isNotEmpty) &&
      (invoiceId == null || invoiceId.isEmpty);

  final result = await showModalBottomSheet<_SettlementResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => Consumer(
      builder: (ctx, r, __) {
        if (local != null && !local.visible(r)) {
          return SafeArea(
            child: Material(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(AppLocalizations.of(ctx).translate('unauthorized')),
              ),
            ),
          );
        }
        return _SettlementSheet(
          ref: r,
          isSupplier: isSupplier,
          debtCur: debtCur,
          remaining: remaining,
          crossAllowed: crossAllowed,
          local: local,
        );
      },
    ),
  );
  if (result == null || result.amount <= 0 || !context.mounted) return false;
  final body = <String, dynamic>{
    'bank_account_id': result.accountId,
    'amount': result.amount,
    'currency': result.currency,
    'payment_method': 'bank',
    'exchange_rate': result.rate,
    if (groupId != null && groupId.isNotEmpty) 'debt_group_id': groupId,
    if (invoiceId != null && invoiceId.isNotEmpty) 'invoice_id': invoiceId,
  };
  try {
    if (local != null) {
      await local.save(
        result.accountId,
        result.currency,
        result.rawAmount,
        result.debtCurrency,
        result.rawRate,
      );
    } else {
      final api = ref.read(purchaseApiProvider);
      if (isSupplier) {
        await api.paySupplier(partyId, body);
      } else {
        await api.collectCustomer(partyId, body);
      }
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      showFyonaSnack(context, local?.error(e) ?? '$e', success: false);
    }
    return false;
  }
}

/// A preloaded Business-only account picker and writer. It never watches the
/// connected payment-options provider; the caller rechecks the grant on save.
final class LocalDebtSettlement {
  const LocalDebtSettlement({
    required this.accounts,
    required this.remainingByCurrency,
    required this.savedRate,
    required this.save,
    required this.error,
    required this.visible,
  });

  final List<Map<String, String>> accounts;
  // Ordered oldest debt first, to match the posting engine's FX target.
  final Map<String, double> remainingByCurrency;
  final double? Function(String from, String to) savedRate;
  final Future<void> Function(
    String account,
    String currency,
    String amount,
    String debtCurrency,
    String rate,
  )
  save;
  final String Function(Object error) error;
  final bool Function(WidgetRef ref) visible;
}

class _SettlementResult {
  final String accountId;
  final String currency;
  final double amount;
  final double rate;
  final String debtCurrency, rawAmount, rawRate;
  const _SettlementResult({
    required this.accountId,
    required this.currency,
    required this.amount,
    required this.rate,
    required this.debtCurrency,
    required this.rawAmount,
    required this.rawRate,
  });
}

class _SettlementSheet extends StatefulWidget {
  final WidgetRef ref;
  final bool isSupplier;
  final String debtCur;
  final double remaining;
  final bool crossAllowed;
  final LocalDebtSettlement? local;
  const _SettlementSheet({
    required this.ref,
    required this.isSupplier,
    required this.debtCur,
    required this.remaining,
    required this.crossAllowed,
    required this.local,
  });
  @override
  State<_SettlementSheet> createState() => _SettlementSheetState();
}

class _SettlementSheetState extends State<_SettlementSheet> {
  String? _bank;
  Map<String, String>? _account;
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _rate = TextEditingController();
  bool _confirmed = false;

  String get _payCur => (_account?['currency'] ?? '').toUpperCase();
  String get _debtCur {
    final groups = widget.local?.remainingByCurrency;
    if (groups == null || groups.isEmpty || _account == null)
      return widget.debtCur;
    return groups.containsKey(_payCur) ? _payCur : groups.keys.first;
  }

  double get _remaining =>
      widget.local?.remainingByCurrency[_debtCur] ?? widget.remaining;
  bool get _sameCur => _payCur == _debtCur;
  double get _rateValue =>
      double.tryParse(_rate.text.trim().replaceAll(',', '')) ?? 0;
  double get _amountValue =>
      double.tryParse(_amount.text.trim().replaceAll(',', '')) ?? 0;
  double get _applied => _sameCur ? _amountValue : _amountValue * _rateValue;

  @override
  void initState() {
    super.initState();
    _amount.addListener(() => setState(() {}));
    _rate.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _amount.dispose();
    _rate.dispose();
    super.dispose();
  }

  void _pickAccount(Map<String, String> a) {
    setState(() {
      _account = a;
      final rate = _sameCur ? 1.0 : _autoRate();
      _rate.text = rate > 0 ? _fmtRate(rate) : '';
      if (widget.local != null && rate > 0)
        _rate.text = rate.toStringAsFixed(8);
      if (_sameCur) {
        _amount.text = _remaining > 0
            ? (widget.local == null
                  ? fmtNum(_remaining)
                  : _remaining.toStringAsFixed(2))
            : '';
      } else if (rate > 0) {
        _amount.text = widget.local == null
            ? fmtNum(_remaining / rate)
            : (_remaining / rate).toStringAsFixed(2);
      } else {
        _amount.text = '';
      }
    });
  }

  double _autoRate() {
    try {
      final local = widget.local;
      final r = local != null
          ? local.savedRate(_payCur, _debtCur)
          : widget.ref.read(currencyEngineProvider).getRate(_payCur, _debtCur);
      return (r != null && r.isFinite && r > 0) ? r.toDouble() : 0;
    } catch (_) {
      return 0;
    }
  }

  static String _fmtRate(double r) {
    if (r == r.roundToDouble()) return r.toStringAsFixed(0);
    return r
        .toStringAsFixed(r < 1 ? 6 : 4)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  static String _balance(Map<String, String> a) {
    final n = double.tryParse('${a['balance'] ?? ''}') ?? 0;
    return debtAmount(n);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final accounts =
        widget.local?.accounts ??
        widget.ref.watch(saleAccountsProvider).valueOrNull ??
        const <Map<String, String>>[];
    // Invoice debts: only banks that actually hold the invoice currency.
    final usable = widget.crossAllowed
        ? accounts
        : accounts
              .where((a) => '${a['currency']}'.toUpperCase() == widget.debtCur)
              .toList();
    final banks = <String, List<Map<String, String>>>{};
    for (final a in usable) {
      final bank = '${a['bank'] ?? ''}'.trim().isEmpty
          ? l10n.translate('payMethodCash')
          : '${a['bank']}'.trim();
      banks.putIfAbsent(bank, () => []).add(a);
    }
    final bankAccounts = _bank == null
        ? <Map<String, String>>[]
        : banks[_bank] ?? [];
    // Over-payment is fine: only the rate (when currencies differ) must exist.
    final canConfirm =
        _account != null &&
        _amountValue.isFinite &&
        _amountValue > 0 &&
        (_sameCur || (_rateValue.isFinite && _rateValue > 0));

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.88,
        ),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              // ── Header ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Row(
                  children: [
                    DebtIcon(
                      widget.isSupplier
                          ? Icons.payments_outlined
                          : Icons.request_quote_outlined,
                      size: 38,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.translate(
                              widget.isSupplier
                                  ? 'debtPaySupplier'
                                  : 'debtCollectCustomer',
                            ),
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            '${l10n.translate('debtRemaining')}: '
                            '${debtAmount(_remaining)} '
                            '${debtCurrencyLabel(_debtCur)}',
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 11.5,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              if (!widget.crossAllowed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                  child: Text(
                    l10n.translate(
                      'debtInvoiceOriginalCurrency',
                      params: {'c': debtCurrencyLabel(widget.debtCur)},
                    ),
                    style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 11,
                      color: Colors.grey,
                    ),
                  ),
                ),
              const Divider(height: 1),
              Expanded(
                child: usable.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            l10n.translate(
                              'debtNoAccountCurrency',
                              params: {'c': debtCurrencyLabel(widget.debtCur)},
                            ),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              color: Colors.grey,
                            ),
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                        children: [
                          _sectionTitle(
                            l10n.translate(
                              widget.isSupplier
                                  ? 'debtPayFromBank'
                                  : 'debtCollectToBank',
                            ),
                          ),
                          const SizedBox(height: 6),
                          for (final b in banks.keys) _bankTile(b, banks[b]!),
                          const SizedBox(height: 14),
                          if (_bank != null) ...[
                            _sectionTitle(
                              l10n.translate(
                                'debtCurrencyOfBank',
                                params: {'bank': _bank!},
                              ),
                            ),
                            const SizedBox(height: 6),
                            for (final a in bankAccounts)
                              _currencyTile(l10n, a),
                            const SizedBox(height: 14),
                          ],
                          if (_account != null) ...[
                            BusinessNumberField(
                              controller: _amount,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              inputFormatters: [AmountInputFormatter()],
                              style: const TextStyle(fontFamily: 'Cairo'),
                              decoration: InputDecoration(
                                labelText: l10n.translate(
                                  'debtSettleAmountHint',
                                ),
                                labelStyle: const TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 12,
                                ),
                                suffixText: debtCurrencyLabel(_payCur),
                              ),
                            ),
                            if (!_sameCur) ...[
                              const SizedBox(height: 12),
                              BusinessNumberField(
                                controller: _rate,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                style: const TextStyle(fontFamily: 'Cairo'),
                                decoration: InputDecoration(
                                  labelText: l10n.translate(
                                    'debtFxRateLabel',
                                    params: {
                                      'from': debtCurrencyLabel(_payCur),
                                      'to': debtCurrencyLabel(_debtCur),
                                    },
                                  ),
                                  labelStyle: const TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 11.5,
                                  ),
                                  helperText: _autoRate() > 0
                                      ? null
                                      : l10n.translate('debtFxMissing'),
                                  helperStyle: const TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 10.5,
                                    color: AppColors.warning,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            Builder(
                              builder: (_) {
                                final appliedToDebt = _applied > _remaining
                                    ? _remaining
                                    : _applied;
                                final remainingAfter =
                                    (_remaining - appliedToDebt).clamp(
                                      0.0,
                                      double.infinity,
                                    );
                                final extraPay = _sameCur
                                    ? (_amountValue - _remaining)
                                    : (_amountValue - _remaining / _rateValue);
                                final surplus = extraPay > 0.004
                                    ? extraPay
                                    : 0.0;
                                return Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: DebtStyle.red.withAlpha(10),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: DebtStyle.red.withAlpha(40),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      _previewRow(
                                        l10n.translate('debtFxAppliedLabel'),
                                        '${debtAmount(appliedToDebt)} '
                                        '${debtCurrencyLabel(_debtCur)}',
                                      ),
                                      if (surplus > 0) ...[
                                        const SizedBox(height: 4),
                                        _previewRow(
                                          l10n.translate('debtFxExtra'),
                                          '${debtAmount(surplus)} '
                                          '${debtCurrencyLabel(_payCur)}',
                                          valueColor: const Color(0xFFE08A00),
                                        ),
                                      ],
                                      const SizedBox(height: 4),
                                      _previewRow(
                                        l10n.translate(
                                          'debtFxRemainingAfterLabel',
                                        ),
                                        '${debtAmount(remainingAfter)} '
                                        '${debtCurrencyLabel(_debtCur)}',
                                      ),
                                      if (!canConfirm && _amountValue > 0) ...[
                                        const SizedBox(height: 6),
                                        Text(
                                          l10n.translate('debtFxMissing'),
                                          style: const TextStyle(
                                            fontFamily: 'Cairo',
                                            fontSize: 10.5,
                                            color: AppColors.danger,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                );
                              },
                            ),
                          ],
                        ],
                      ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1F9D55),
                      minimumSize: const Size(0, 52),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: canConfirm
                        ? () {
                            if (_confirmed) return;
                            _confirmed = true;
                            Navigator.pop(
                              context,
                              _SettlementResult(
                                accountId: '${_account!['id']}',
                                currency: _payCur,
                                amount: _amountValue,
                                rate: _sameCur ? 1 : _rateValue,
                                debtCurrency: _debtCur,
                                rawAmount: _amount.text.trim().replaceAll(
                                  ',',
                                  '',
                                ),
                                rawRate: _sameCur
                                    ? '1'
                                    : _rate.text.trim().replaceAll(',', ''),
                              ),
                            );
                          }
                        : null,
                    child: Text(
                      l10n.translate(
                        widget.isSupplier ? 'purSettle' : 'collect',
                      ),
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 14,
                        height: 1.35,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String t) => Text(
    t,
    style: DebtStyle.text(context, size: 12.5, bold: true, color: Colors.grey),
  );

  Widget _bankTile(String bank, List<Map<String, String>> accounts) {
    final selected = bank == _bank;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: () {
          setState(() {
            _bank = bank;
            _account = null;
          });
          if (accounts.isNotEmpty) _pickAccount(accounts.first);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: selected
                ? DebtStyle.red.withAlpha(12)
                : AppColors.background,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: selected ? DebtStyle.red : DebtStyle.border(context),
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.account_balance_outlined,
                size: 20,
                color: selected ? DebtStyle.red : Colors.grey,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  bank,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DebtStyle.text(context, size: 13, bold: selected),
                ),
              ),
              Text(
                '${accounts.length}',
                style: DebtStyle.text(context, size: 11, color: Colors.grey),
              ),
              if (selected) ...[
                const SizedBox(width: 6),
                const Icon(Icons.check_circle, size: 17, color: DebtStyle.red),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _currencyTile(AppLocalizations l10n, Map<String, String> a) {
    final cur = '${a['currency']}'.toUpperCase();
    final selected = _account?['id'] == a['id'];
    final type = '${a['type']}' == 'savings'
        ? l10n.translate('accountTypeSavings')
        : l10n.translate('accountTypeChecking');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: () => _pickAccount(a),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? DebtStyle.red.withAlpha(12)
                : AppColors.background,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: selected ? DebtStyle.red : DebtStyle.border(context),
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: DebtStyle.red.withAlpha(20),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  cur.length > 3 ? cur.substring(0, 3) : cur,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: DebtStyle.red,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      debtCurrencyLabel(cur),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DebtStyle.text(context, size: 13, bold: selected),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      type,
                      style: DebtStyle.text(
                        context,
                        size: 10.5,
                        color: Colors.grey,
                      ),
                    ),
                    if (widget.ref.watch(employeeCanProvider('banks.balances')))
                      Text(
                        l10n.translate(
                          'debtAvailableShort',
                          params: {'v': _balance(a), 'c': cur},
                        ),
                        style: DebtStyle.text(
                          context,
                          size: 10.5,
                          color: Colors.grey,
                        ),
                      ),
                  ],
                ),
              ),
              if (selected)
                const Icon(Icons.check_circle, size: 18, color: DebtStyle.red),
            ],
          ),
        ),
      ),
    );
  }

  Widget _previewRow(String label, String value, {Color? valueColor}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: DebtStyle.text(context, size: 11.5, color: Colors.grey),
          ),
        ),
        Text(
          value,
          style: DebtStyle.text(
            context,
            size: 12,
            bold: true,
            color: valueColor,
          ),
        ),
      ],
    );
  }
}
