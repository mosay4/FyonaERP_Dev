import 'package:flutter/material.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/core/utils/document_number.dart';
import '../../../core_business/presentation/widgets/business_number_field.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../core_business/presentation/providers/biz_payment_pref.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../../core_business/data/local_directory/directory_database.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/data/local_ledger/business_money.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';
import '../../../core_business/presentation/widgets/business_operation_error.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../dashboard/presentation/providers/business_dashboard_providers.dart';
import '../../../inventory/domain/services/invalidate_inventory_data.dart';
import '../../../inventory/presentation/widgets/business_unit_image.dart';
import '../../../sales/domain/sale_totals.dart' show parseMoney;
import '../../../sales/presentation/widgets/sale_payment_section.dart'
    show openBankCurrencyPicker, AccountCurrencyPick;
import '../providers/returns_providers.dart';
import '../../data/returns_api.dart';
import 'return_success_dialog.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Merchant-friendly return wizard for ONE invoice (customer or supplier).
///
/// Steps on a single scroll page: pick the original invoice → tick the
/// products + quantities (never more than what is still returnable) → pick
/// the account for the money → review → confirm. All money/stock/report
/// effects commit together in the selected ledger.
class ReturnCreatePage extends ConsumerStatefulWidget {
  final String kind; // 'sale_return' | 'purchase_return'
  final String initialInvoiceId;
  final LocalCommerceTarget? localTarget;
  const ReturnCreatePage(
      {super.key, required this.kind, this.initialInvoiceId = '', this.localTarget});
  @override
  ConsumerState<ReturnCreatePage> createState() => _ReturnCreatePageState();
}

class _ReturnCreatePageState extends ConsumerState<ReturnCreatePage> {
  final _reasonCtrl = TextEditingController();

  Map<String, dynamic>? _invoice;
  List<Map<String, dynamic>> _items = [];
  final Map<String, double> _returned = {}; // invoice_item_id -> qty
  final Map<String, double> _qty = {}; // invoice_item_id -> chosen qty
  final Map<String, bool> _restock = {}; // invoice_item_id -> restock
  AccountCurrencyPick? _account;
  double? _rate; // 1 account currency = _rate invoice currency
  String _rateSource = 'same';
  DateTime? _rateTimestamp;
  bool _loadingInvoice = false;
  bool _saving = false;
  String? _commandId;
  late final ReturnsApi _source;

  bool get _isSale => widget.kind == 'sale_return';
  String get _invoiceType => _isSale ? 'sale' : 'purchase';
  bool get _current => mounted &&
      identical(_source, ref.read(returnsApiProvider)) &&
      (widget.localTarget?.allows(ref.read(businessLocalLedgerScopeProvider), RouteNames.returnsAdd) ?? true);

  @override
  void initState() {
    super.initState();
    _source = ref.read(returnsApiProvider);
    if (widget.initialInvoiceId.isNotEmpty && _current) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _loadInvoiceById(widget.initialInvoiceId));
    }
  }

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  double _remaining(Map<String, dynamic> item) {
    final id = (item['id'] ?? '').toString();
    final sold = parseMoney(item['quantity']);
    return (sold - (_returned[id] ?? 0)).clamp(0, double.infinity);
  }

  double _lineTotal(Map<String, dynamic> item, double qty) {
    final sold = parseMoney(item['quantity']);
    final price = parseMoney(item['unit_price']);
    final discount = parseMoney(item['discount']);
    if (_source is LocalReturnsApi && sold > 0) {
      return BusinessMoney.returnLineMinor(
        quantityMicro: (qty * 1000000).round(),
        soldMicro: (sold * 1000000).round(),
        unitMinor: (price * 100).round(),
        discountMinor: (discount * 100).round(),
      ) / 100;
    }
    final ratio = sold > 0 ? qty / sold : 0.0;
    return qty * price - discount * ratio;
  }

  double get _returnTotal {
    var total = 0.0;
    for (final it in _items) {
      final id = (it['id'] ?? '').toString();
      total += _lineTotal(it, _qty[id] ?? 0);
    }
    return total;
  }

  double get _invoiceBalance {
    final b = _invoice?['balance'];
    return b is num ? b.toDouble() : double.tryParse('$b') ?? 0;
  }

  double get _debtReduction {
    final t = _returnTotal;
    final b = _invoiceBalance;
    return t < b ? t : b;
  }

  double get _cashRefund {
    final r = _returnTotal - _debtReduction;
    return r > 0.005 ? r : 0;
  }

  String get _currency =>
      (_invoice?['currency'] ?? '').toString().toUpperCase();

  String get _accountCurrency =>
      (_account?.currency ?? _currency).toUpperCase();

  bool get _isCross =>
      _account != null && _accountCurrency != _currency;

  /// The cash refund expressed in the chosen account currency (converted with
  /// the frozen rate when currencies differ; base value stays in invoice
  /// currency).
  double get _accountRefundAmount {
    if (_account == null || !_isCross) return _cashRefund;
    final r = _rate ?? 0;
    if (_source is LocalReturnsApi && r > 0) {
      try {
        return BusinessRate(_accountCurrency, _currency, r.toStringAsFixed(8))
                .original((_cashRefund * 100).round()) / 100;
      } on FormatException {
        return 0;
      }
    }
    return r > 0 ? _cashRefund / r : 0;
  }

  double get _accountBalance =>
      double.tryParse('${_account?.account['balance'] ?? 0}') ?? 0;

  Future<void> _pickAccount() async {
    if (!_current || _saving) return;
    // Await the accounts provider so the FIRST tap is never empty (it used to
    // show «لا توجد حسابات» until a second tap).
    List<Map<String, String>> all;
    try {
      all = await ref.refresh(returnAccountsProvider.future);
    } catch (e) {
      if (mounted) {
        _msg(businessOperationError(AppLocalizations.of(context), e,
            fallback: 'bankingLoadAccountsFailedNoDetail'));
      }
      return;
    }
    if (!_current || _saving) return;
    if (all.isEmpty) {
      _msg(AppLocalizations.of(context).translate('retNoAccounts'));
      return;
    }
    final picked = await openBankCurrencyPicker(context, all,
        selectedId: _account?.accountId);
    if (picked != null && _current && !_saving) _onAccountPicked(picked);
  }

  void _onAccountPicked(AccountCurrencyPick picked) {
    final acctCur = picked.currency.toUpperCase();
    final invCur = _currency;
    if (acctCur == invCur) {
      setState(() {
        _account = picked;
        _rate = 1;
        _rateSource = 'same';
        _rateTimestamp = null;
      });
      return;
    }
    final r = ref.read(currencyEngineProvider).getRate(acctCur, invCur);
    final rate = (r == null || r <= 0) ? 0.0 : r;
    setState(() {
      _account = picked;
      _rate = rate;
      _rateSource = rate > 0 ? 'auto' : 'manual';
      _rateTimestamp = rate > 0 ? DateTime.now() : null;
    });
  }

  Future<void> _editRate() async {
    if (!_current || _saving) return;
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController(
        text: (_rate ?? 0) > 0 ? _fmt(_rate!) : '');
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(l10n.translate('saleEditRate'),
            style: const TextStyle(fontFamily: 'Cairo', fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('1 $_accountCurrency = ? $_currency',
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
                hintStyle: const TextStyle(fontFamily: 'Cairo'),
                isDense: true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.translate('saleClose'),
                style: const TextStyle(fontFamily: 'Cairo')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
                ctx, double.tryParse(ctrl.text.trim().replaceAll(',', ''))),
            child: Text(l10n.translate('saleValue'),
                style: const TextStyle(fontFamily: 'Cairo')),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (result == null || result <= 0 || !_current || _saving) return;
    setState(() {
      _rate = result;
      _rateSource = 'manual';
      _rateTimestamp = DateTime.now();
    });
  }

  /// Same «الدفع بالسالب» guard used by the customer/supplier settlement flow:
  /// same dialog, same temporary/permanent choice, same persistence.
  Future<String?> _confirmConnectedOverdraft(double accountAmount) async {
    // A redacted balance is unknown, not zero. The server still checks funds.
    if (!ref.read(employeeCanProvider('banks.balances'))) return 'normal';
    final l10n = AppLocalizations.of(context);
    final pref = ref.read(bizPaymentPrefProvider);
    if (accountAmount <= _accountBalance + 0.0001 || pref.allowNegative) {
      return 'normal';
    }
    if (pref.promptShown) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          backgroundColor: AppColors.danger,
          content: Text(l10n.translate('retOverdraftBody'),
              style: const TextStyle(fontFamily: 'Cairo')),
          behavior: SnackBarBehavior.floating,
        ));
      return null;
    }
    final choice = await _askOverdraft();
    if (!_current) return null;
    final prefs = ref.read(bizPaymentPrefProvider.notifier);
    await prefs.markPromptShown();
    if (choice == 'always' && _current) await prefs.setAllowNegative(true);
    return choice == 'always' || choice == 'once' ? choice : null;
  }

  Future<String?> _askOverdraft({bool canRemember = true}) {
    final l10n = AppLocalizations.of(context);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(l10n.translate('payNegTitle'),
            style: const TextStyle(fontFamily: 'Cairo')),
        actions: [
          TextButton(
              onPressed: canRemember ? () => Navigator.pop(ctx, 'always') : null,
              child: Text(l10n.translate('payNegAlways'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'once'),
              child: Text(l10n.translate('payNegOnce'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              child: Text(l10n.translate('payNegCancel'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
        ],
      ),
    );
  }

  Future<void> _pickInvoice() async {
    if (!_current || _saving) return;
    final chosen = await context.push<Map<String, dynamic>>(
        '${RouteNames.returnsPickInvoice}?kind=${widget.kind}');
    if (chosen == null || !_current || _saving) return;
    final chosenType = (chosen['invoice_type'] ?? '').toString();
    if (chosenType.isNotEmpty && chosenType != _invoiceType) {
      // Barcode search matched the OTHER invoice kind: warn and offer to
      // switch to the correct returns section, auto-opening the invoice.
      await _showWrongTypeDialog(chosen);
      return;
    }
    await _loadInvoiceById((chosen['id'] ?? '').toString());
  }

  Future<void> _showWrongTypeDialog(Map<String, dynamic> chosen) async {
    final l10n = AppLocalizations.of(context);
    final isSaleInvoice = (chosen['invoice_type'] ?? '') == 'sale';
    final targetKind = isSaleInvoice ? 'sale_return' : 'purchase_return';
    final targetLabel =
        l10n.translate(isSaleInvoice ? 'retCustomerReturn' : 'retSupplierReturn');
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(l10n.translate('retWrongTypeTitle'),
            style: const TextStyle(
                fontFamily: 'Cairo', fontWeight: FontWeight.w800)),
        content: Text(
            l10n.translate(
                isSaleInvoice ? 'retWrongTypeSupplierMsg' : 'retWrongTypeCustomerMsg'),
            style: const TextStyle(fontFamily: 'Cairo', height: 1.5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.translate('cancel'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(targetLabel,
                  style: const TextStyle(fontFamily: 'Cairo'))),
        ],
      ),
    );
    if (go != true || !_current) return;
    openCommerceRecord(context, RouteNames.returnsAdd, '${chosen['id']}', kind: targetKind, replace: true);
  }

  Future<void> _loadInvoiceById(String invoiceId) async {
    if (invoiceId.isEmpty) return;
    if (!_current) return;
    final api = _source;
    setState(() => _loadingInvoice = true);
    try {
      final inv = await api.getInvoice(invoiceId);
      if (!_current) return;
      final prior = await api.list(invoiceId: invoiceId);
      final returned = <String, double>{};
      for (final r in prior.whereType<Map>()) {
        for (final it in (r['items'] as List? ?? const [])) {
          if (it is! Map) continue;
          final iid = (it['invoice_item_id'] ?? '').toString();
          if (iid.isEmpty) continue;
          returned[iid] = (returned[iid] ?? 0) + parseMoney(it['quantity']);
        }
      }
      if (!_current) return;
      setState(() {
        _invoice = inv;
        _items = [
          for (final m in (inv['items'] as List? ?? const []))
            if (m is Map) Map<String, dynamic>.from(m)
        ];
        _returned
          ..clear()
          ..addAll(returned);
        _qty.clear();
        _restock.clear();
        for (final it in _items) {
          final id = (it['id'] ?? '').toString();
          // Nothing returned by default: the stepper shows the FULL invoiced
          // quantity (kept) and the merchant presses − to add it to the return.
          _qty[id] = 0;
          _restock[id] = true;
        }
        _account = null;
        _commandId = null;
        _loadingInvoice = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loadingInvoice = false);
        _msg(businessOperationError(AppLocalizations.of(context), e, fallback: 'errorOccurred'));
      }
    }
  }

  void _selectAll() {
    if (_saving) return;
    setState(() {
      for (final it in _items) {
        final id = (it['id'] ?? '').toString();
        _qty[id] = _remaining(it);
        _restock[id] = true;
      }
    });
  }

  Future<void> _submit() async {
    if (_saving || _loadingInvoice) return;
    final l10n = AppLocalizations.of(context);
    if (BranchScope.readOnly || !_current) {
      _msg(l10n.translate('unauthorized'));
      return;
    }
    final selected = [
      for (final it in _items)
        if ((_qty[(it['id'] ?? '').toString()] ?? 0) > 0) it
    ];
    if (selected.isEmpty) {
      _msg(l10n.translate('retPickAtLeastOne'));
      return;
    }
    if (_cashRefund > 0 && _account == null) {
      _msg(l10n.translate('retNeedAccount'));
      return;
    }
    if (_cashRefund > 0 && _isCross && (_rate ?? 0) <= 0) {
      _msg(l10n.translate('saleErrNeedRate'));
      return;
    }
    final local = _source is LocalReturnsApi ? _source : null;
    final invoiceId = '${_invoice!['id']}';
    final body = <String, dynamic>{
      'command_id': _commandId ??= const Uuid().v4(),
      'reason': _reasonCtrl.text.trim(),
      'lines': [
        for (final it in selected)
          {
            'invoice_item_id': '${it['id']}',
            'quantity': _qty['${it['id']}'],
            'restock': _restock['${it['id']}'] ?? true,
          },
      ],
      if (local != null) 'expected_refund_minor': (_cashRefund * 100).round(),
      if (_account != null && _cashRefund > 0) ...{
        'refund_account_id': _account!.accountId,
        'refund_currency': _accountCurrency,
        // The local ledger computes the exact amount from the frozen rate
        // and current invoice; a UI estimate cannot drive a bank posting.
        if (local == null) 'refund_amount': _accountRefundAmount,
        'refund_exchange_rate': _rate,
        'refund_exchange_rate_source': _rateSource,
        if (_rateTimestamp != null)
          'refund_exchange_rate_timestamp': _rateTimestamp!.toIso8601String(),
      },
    };
    setState(() => _saving = true);
    try {
      if (local == null && _isSale && _cashRefund > 0) {
        final choice = await _confirmConnectedOverdraft(_accountRefundAmount);
        if (choice == null || !_current) return;
        if (choice == 'once') body['allow_negative'] = true;
      }
      Map<String, dynamic> res;
      try {
        res = await _source.create(invoiceId, body);
      } on BusinessReturnOverdraft {
        if (!_current || local == null) return;
        final choice = await _askOverdraft(canRemember: local.canRememberOverdraft);
        if (!_current || (choice != 'once' && choice != 'always')) return;
        res = await local.create(invoiceId, {
          ...body,
          'allow_negative': true,
          if (choice == 'always') 'remember_allow_negative': true,
        });
        if (choice == 'always' && _current) ref.invalidate(bizPaymentPrefProvider);
      }
      if (!_current) return;

      invalidateInventoryData(ref);
      ref.invalidate(returnsListProvider);
      ref.invalidate(businessRecentProvider);
      ref.invalidate(businessAccountsProvider);
      ref.invalidate(returnAccountsProvider);
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => ReturnSuccessDialog(result: res, isSale: _isSale),
      );
    } catch (e) {
      if (!_current) return;
      if (local != null && e is BusinessLedgerError &&
          e.problem == BusinessLedgerProblem.invoiceChanged) {
        await _loadInvoiceById(invoiceId);
        if (_current) _msg(l10n.translate('retReviewUpdatedInvoice'));
        return;
      }
      _msg(businessOperationError(l10n, e, fallback: 'txOperationFailed'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _msg(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text, style: const TextStyle(fontFamily: 'Cairo')),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (!identical(_source, ref.watch(returnsApiProvider)) || !_current) {
      return Scaffold(body: Center(child: Text(l10n.translate('unauthorized'))));
    }
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
            l10n.translate(_isSale ? 'retCustomerReturn' : 'retSupplierReturn'),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 18),
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary)),
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          color: AppColors.textPrimary,
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: [
            _Card(
              title: l10n.translate('retInvoice'),
              child: Column(children: [
                _PickerField(
                  icon: Icons.receipt_long_outlined,
                  text: _invoice == null
                      ? l10n.translate('retChooseInvoice')
                      : '${shortDocumentNumber(_invoice!['invoice_number'])} • '
                          '${parseMoney(_invoice!['total'])} $_currency',
                  placeholder: _invoice == null,
                  onTap: _pickInvoice,
                ),
                 if (_loadingInvoice && _source is! LocalReturnsApi)
                  const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(minHeight: 2)),
              ]),
            ),
            if (_invoice != null && _items.isNotEmpty) ...[
              const SizedBox(height: 12),
              _Card(
                title: l10n.translate('retItems'),
                trailing: TextButton(
                  onPressed: _selectAll,
                  child: Text(l10n.translate('retSelectAll'),
                      style: const TextStyle(fontFamily: 'Cairo')),
                ),
                child: Column(children: [
                  for (final it in _items) _itemRow(it, l10n),
                ]),
              ),
              const SizedBox(height: 12),
              // A clear summary of what will actually be returned, before the
              // merchant confirms.
              _Card(
                title: l10n.translate('retSummaryTitle'),
                child: _returnedSummary(l10n),
              ),
              const SizedBox(height: 12),
              _Card(
                title: l10n.translate('retAccount'),
                child: _PickerField(
                  icon: Icons.account_balance_wallet_outlined,
                  text: _account == null
                      ? l10n.translate('retChooseAccount')
                      : '${_account!.bankName} • ${_account!.currency}'
                          '${_account!.accountName.isNotEmpty ? ' • ${_account!.accountName}' : ''}',
                  placeholder: _account == null,
                  onTap: _pickAccount,
                ),
              ),
              const SizedBox(height: 12),
              _Card(
                title: l10n.translate('retSummary'),
                child: Column(children: [
                  _summaryRow(
                      l10n.translate('retInvoice'),
                      '$_currency — ${_fmt(_returnTotal)}',
                      AppColors.primary),
                  const SizedBox(height: 6),
                  _summaryRow(
                      l10n.translate(
                          _isSale ? 'retReduceDebt' : 'retReducePayable'),
                      '${_fmt(_debtReduction)} $_currency',
                      AppColors.textSecondary),
                  const SizedBox(height: 6),
                  if (_cashRefund > 0)
                    _summaryRow(
                        l10n.translate('retReturnLabel'),
                        '$_accountCurrency — ${_fmt(_accountRefundAmount)}',
                        _isSale ? AppColors.danger : AppColors.success)
                  else
                    _summaryRow(
                        l10n.translate(
                            _isSale ? 'retCashOut' : 'retCashIn'),
                        '—',
                        AppColors.textDisabled),
                  if (_isCross && _cashRefund > 0) ...[
                    const SizedBox(height: 6),
                    Row(children: [
                      Expanded(
                        child: Text(l10n.translate('saleExchangeRate'),
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: R.fontSize(context, 13),
                                color: AppColors.textSecondary)),
                      ),
                      Text('1 $_accountCurrency = ${_fmt(_rate ?? 0)} $_currency',
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 13),
                              fontWeight: FontWeight.w700,
                              color: _rateSource == 'manual'
                                  ? AppColors.warning
                                  : AppColors.success)),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        color: AppColors.primary,
                        onPressed: _editRate,
                      ),
                    ]),
                  ],
                ]),
              ),
              const SizedBox(height: 12),
              _Card(
                title: l10n.translate('retReason'),
                 child: FyonaTextField(
                   controller: _reasonCtrl,
                   readOnly: _saving,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontFamily: 'Cairo'),
                  decoration: InputDecoration(
                    hintText: l10n.translate('retReasonHint'),
                    hintStyle: const TextStyle(fontFamily: 'Cairo'),
                    filled: true,
                    fillColor: AppColors.surfaceVariant.withAlpha(70),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: AppColors.border)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 90),
          ],
        ),
      ),
      bottomNavigationBar: _invoice == null
          ? null
          : Container(
              padding: EdgeInsets.fromLTRB(
                  16, 12, 16, 12 + MediaQuery.of(context).padding.bottom),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border(top: BorderSide(color: AppColors.border)),
              ),
              child: SizedBox(
                height: 54,
                child: FilledButton(
                  onPressed: _saving ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: _isSale
                        ? AppColors.success
                        : AppColors.danger,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                   child: _saving && _source is! LocalReturnsApi
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : Text(l10n.translate('retConfirm'),
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 16),
                              fontWeight: FontWeight.w700)),
                ),
              ),
            ),
    );
  }

  Widget _returnedSummary(AppLocalizations l10n) {
    final rows = <(Map<String, dynamic>, double)>[
      for (final it in _items)
        if (((_qty[(it['id'] ?? '').toString()] ?? 0) > 0.0001))
          (it, _qty[(it['id'] ?? '').toString()]!),
    ];
    if (rows.isEmpty) {
      return Text(l10n.translate('retNothingReturned'),
          style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 12),
              color: AppColors.textSecondary));
    }
    return Column(children: [
      for (final (it, q) in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Expanded(
                child: Text(
                    '${(it['description'] ?? '').toString()} × ${_fmt(q)} ${(it['unit_name'] ?? '').toString()}'
                        .trim(),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 13),
                        color: AppColors.textPrimary)),
              ),
              Text('${_fmt(_lineTotal(it, q))} $_currency',
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w700,
                      color: AppColors.success)),
            ],
          ),
        ),
      const Divider(height: 14),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(l10n.translate('retSummary'),
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 13),
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
          Text('${_fmt(_returnTotal)} $_currency',
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 14),
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary)),
        ],
      ),
    ]);
  }

  Widget _itemRow(Map<String, dynamic> item, AppLocalizations l10n) {
    final id = (item['id'] ?? '').toString();
    final remaining = _remaining(item);
    final qty = _qty[id] ?? 0;
    final isService = (item['is_service'] ?? false) == true;
    final selected = qty > 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withAlpha(selected ? 90 : 40),
        border: Border.all(
            color: selected ? AppColors.primary.withAlpha(90) : AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          // The returned unit's photo (its own, else the product's).
          if (!isService && item['product_id'] != null) ...[
            BusinessLineUnitImage(
              productId: '${item['product_id']}',
              unitId: item['unit_id']?.toString(),
              unitName: item['unit_name']?.toString(),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text((item['description'] ?? '').toString(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 14),
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
          ),
          Text('${_fmt(parseMoney(item['unit_price']))} $_currency',
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 13),
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary)),
        ]),
        const SizedBox(height: 4),
        Text(
          '${l10n.translate('retAvailable')}: ${_fmt(remaining)} '
          '${(item['unit_name'] ?? '').toString()}'.trim(),
          style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 11),
              color: AppColors.textSecondary),
        ),
        const SizedBox(height: 8),
        Row(children: [
          // The stepper shows the quantity KEPT (not returned), starting at the
          // full invoiced qty. Pressing − reduces the kept amount, i.e. ADDS
          // that difference to the return; the shown number is what stays.
          _Stepper(
            value: remaining - qty,
            max: remaining,
             onChanged: remaining <= 0 || _saving
                ? null
                : (kept) => setState(() => _qty[id] = remaining - kept),
          ),
          const Spacer(),
          if (selected)
            Text(
                '${l10n.translate('retReturning')}: ${_fmt(qty)} • ${_fmt(_lineTotal(item, qty))} $_currency',
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 12),
                    fontWeight: FontWeight.w800,
                    color: AppColors.success)),
        ]),
        // «رجّع المنتج للمخزون» applies to CUSTOMER returns only.
        if (_isSale && !isService && item['product_id'] != null) ...[
          const SizedBox(height: 4),
          InkWell(
             onTap: _saving ? null
                 : () => setState(() => _restock[id] = !(_restock[id] ?? true)),
            child: Row(children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: _restock[id] ?? true,
                   onChanged: _saving ? null : (v) =>
                      setState(() => _restock[id] = v ?? true),
                  activeColor: AppColors.primary,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(l10n.translate('retRestockProduct'),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 12),
                        color: AppColors.textPrimary)),
              ),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _summaryRow(String label, String value, Color color) {
    return Row(children: [
      Expanded(
        child: Text(label,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 13),
                color: AppColors.textSecondary)),
      ),
      Text(value,
          style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 14),
              fontWeight: FontWeight.w800,
              color: color)),
    ]);
  }
}

String _fmt(double v) {
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toStringAsFixed(2);
}

class _Card extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;
  const _Card({required this.title, required this.child, this.trailing});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(title,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 15),
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
          ),
          if (trailing != null) trailing!,
        ]),
        const SizedBox(height: 12),
        child,
      ]),
    );
  }
}

class _PickerField extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool placeholder;
  final VoidCallback onTap;
  const _PickerField({
    required this.icon,
    required this.text,
    required this.placeholder,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant.withAlpha(70),
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          Icon(icon, size: 20, color: AppColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontWeight: placeholder ? FontWeight.w500 : FontWeight.w700,
                    color: placeholder
                        ? AppColors.textSecondary
                        : AppColors.textPrimary)),
          ),
          Icon(Icons.keyboard_arrow_down_rounded,
              size: 22, color: AppColors.textSecondary),
        ]),
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  final double value;
  final double max;
  final ValueChanged<double>? onChanged;
  const _Stepper({required this.value, required this.max, this.onChanged});
  @override
  Widget build(BuildContext context) {
    final can = onChanged != null;
    return Row(children: [
      _btn(Icons.remove, can && value > 0
          ? () => onChanged!((value - 1).clamp(0, max))
          : null),
      SizedBox(
        width: 44,
        child: Text(value == value.roundToDouble()
                ? value.toStringAsFixed(0)
                : value.toStringAsFixed(2),
            textAlign: TextAlign.center,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 15),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
      ),
      _btn(Icons.add, can && value < max ? () => onChanged!(value + 1) : null),
    ]);
  }

  Widget _btn(IconData icon, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: onTap == null
              ? AppColors.surface
              : AppColors.primary.withAlpha(24),
          border: Border.all(
              color: onTap == null
                  ? AppColors.border
                  : AppColors.primary.withAlpha(90)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon,
            size: 18,
            color: onTap == null ? AppColors.textDisabled : AppColors.primary),
      ),
    );
  }
}
