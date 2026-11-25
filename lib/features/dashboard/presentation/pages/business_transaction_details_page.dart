import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fyona_flutter/core/utils/document_number.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/router/route_names.dart';
import '../../../dashboard/presentation/providers/business_dashboard_providers.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../../core_business/data/local_directory/directory_party.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../reconciliation/data/reconciliation_api.dart';
import '../../data/business_finance_api.dart';
import '../../../../core/utils/time_format.dart';

/// تفاصيل المعاملة — all the important data of ONE real movement + a
/// «عرض الفاتورة» button when the movement is linked to an actual
/// sale/purchase invoice (opens the ORIGINAL invoice page, not a copy).
class BusinessTransactionDetailsPage extends ConsumerStatefulWidget {
  final String sourceType;
  final String sourceId;
  final LocalCommerceTarget? localTarget;
  const BusinessTransactionDetailsPage({
    super.key,
    required this.sourceType,
    required this.sourceId,
    this.localTarget,
  });
  @override
  ConsumerState<BusinessTransactionDetailsPage> createState() =>
      _BusinessTransactionDetailsPageState();
}

class _BusinessTransactionDetailsPageState
    extends ConsumerState<BusinessTransactionDetailsPage> {
  Map<String, dynamic>? _tx;
  bool _loading = true;
  late final BusinessFinanceApi _source;

  bool get _current => mounted &&
      identical(_source, ref.read(businessFinanceApiProvider)) &&
      (_source is LocalBusinessFinanceApi
          ? widget.localTarget?.allows(ref.read(businessLocalLedgerScopeProvider),
              RouteNames.businessTransactionDetails) == true
          : widget.localTarget == null);

  @override
  void initState() {
    super.initState();
    _source = ref.read(businessFinanceApiProvider);
    _load();
  }

  Future<void> _load() async {
    if (!_current) return;
    // A reload keeps what is on screen until the new copy is read.
    if (_tx == null) setState(() => _loading = true);
    try {
      final raw = await _source.getTransaction(widget.sourceType, widget.sourceId);
      if (_current)
        setState(() {
          _tx = raw;
          _loading = false;
        });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Backend status codes → correct Arabic/English labels (100% translated,
  /// never the raw English word in an Arabic UI).
  String _statusLabel(String status, AppLocalizations l10n) {
    const keys = {
      'draft': 'txStatusDraft',
      'confirmed': 'txStatusConfirmed',
      'open': 'txStatusOpen',
      'paid': 'txStatusPaid',
      'partial': 'txStatusPartial',
      'partially_paid': 'txStatusPartiallyPaid',
      'cancelled': 'txStatusCancelled',
      'canceled': 'txStatusCancelled',
    };
    final key = keys[status.toLowerCase()];
    return key != null ? l10n.translate(key) : status;
  }

  String _kindLabel(String k, AppLocalizations l10n) {
    const keys = {
      'sale': 'txKindSale',
      'purchase': 'txKindPurchase',
      'sale_return': 'txKindSaleReturn',
      'purchase_return': 'txKindPurchaseReturn',
      'collection': 'txKindCollection',
      'supplier_payment': 'txKindSupplierPayment',
      'income': 'txKindIncome',
      'expense': 'txKindExpense',
      'transfer': 'txKindTransfer',
      'transfer_reversal': 'txKindTransferReversal',
      'bank_withdrawal': 'txKindBankWithdrawal',
      'withdrawal_reversal': 'bizCashWithdrawalReversed',
      'reconciliation': 'reconMovement',
      'opening': 'txKindOpening',
    };
    return l10n.translate(keys[k] ?? 'txKindSale');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final scope = widget.localTarget?.scope;
    if (!identical(_source, ref.watch(businessFinanceApiProvider)) || !_current) {
      return Scaffold(body: Center(child: Text(l10n.translate('unauthorized'))));
    }
    final visible = scope == null ? null : ref.watch(visibleBusinessOperationKindsProvider);

    if (_loading) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(backgroundColor: AppColors.background, elevation: 0),
        body: scope != null ? const SizedBox.shrink()
            : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final t = _tx;
    if (t == null || (visible != null && !visible.contains(t['kind']))) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(backgroundColor: AppColors.background, elevation: 0),
        body: Center(
          child: Text(
            l10n.translate('txNotFound'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 13),
              color: AppColors.textSecondary,
            ),
          ),
        ),
      );
    }

    final isIn = t['direction'] == 'in';
    final accent = isIn ? AppColors.success : AppColors.danger;
    final amount = asDoubleValue(t['amount']);
    final currency = (t['currency'] ?? '').toString();
    final kind = _kindLabel((t['kind'] ?? '').toString(), l10n);
    final party = (t['party'] ?? '').toString();
    final account = (t['account'] ?? '').toString();
    final reference = shortDocumentNumber(t['reference']);
    final notes = (t['notes'] ?? '').toString();
    final status = (t['status'] ?? '').toString();
    final invoiceId = (t['invoice_id'] ?? '').toString();
    final byName = (t['by_employee_name'] ?? t['by_name'] ?? '').toString();
    final byIsManager = t['by_is_manager'] == true;
    // Money-transfer (مصارفة) extra details: both legs with their own
    // account, currency and amount (sent vs received).
    final transfer = t['transfer'] is Map
        ? Map<String, dynamic>.from(t['transfer'] as Map)
        : null;

    String when = '';
    final iso = (t['date'] ?? '').toString();
    if (iso.isNotEmpty) {
      final d = DateTime.tryParse(iso)?.toLocal();
      if (d != null) {
        String two(int n) => n.toString().padLeft(2, '0');
        when =
            '${d.year}/${two(d.month)}/${two(d.day)} — '
            '${formatClock(d, context: context)}';
      }
    }

    // Open the ORIGINAL document: the invoice page for sale/purchase, or the
    // return page for a return. The return/invoice pages then offer printing.
    final bool isSaleSide =
        (const {'invoice', 'opening_debt'}.contains(t['source_type']) && t['kind'] == 'sale') ||
        t['source_type'] == 'sale_return';
    final bool isPurchaseSide =
        (const {'invoice', 'opening_debt'}.contains(t['source_type']) && t['kind'] == 'purchase') ||
        t['source_type'] == 'purchase_return';
    final bool isSaleReturn = t['source_type'] == 'sale_return';
    final bool isPurchaseReturn = t['source_type'] == 'purchase_return';
    final bool isInvoice = t['source_type'] == 'invoice';
    final bool isOpeningDebt = t['source_type'] == 'opening_debt';
    final bool hasInvoice =
        isInvoice || (invoiceId.isNotEmpty && (isSaleSide || isPurchaseSide));
    final String sourceId = (t['source_id'] ?? '').toString();
    final bool canViewDoc = isSaleReturn || isPurchaseReturn ||
        (hasInvoice && ref.watch(employeeCanProvider(
          isSaleSide ? 'sales.view' : 'purchases.view')));

    String partyLabel = '';
    if (party.isNotEmpty) {
      partyLabel =
          (t['kind'] == 'sale' ||
              t['kind'] == 'sale_return' ||
              t['kind'] == 'collection')
          ? l10n.translate('txPartyCustomer')
          : (t['kind'] == 'purchase' ||
                t['kind'] == 'purchase_return' ||
                t['kind'] == 'supplier_payment')
          ? l10n.translate('txPartySupplier')
          : l10n.translate('txPartyCategory');
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Text(
          l10n.translate('txDetails'),
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 17),
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Amount hero ──
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border.all(color: accent.withAlpha(dark ? 70 : 50)),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: accent.withAlpha(dark ? 40 : 24),
                    ),
                    child: Icon(
                      isIn ? Icons.south : Icons.north,
                      size: 26,
                      color: dark ? accent.withAlpha(230) : accent,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text.rich(
                    TextSpan(
                      text: '${isIn ? '+' : '−'} ${fmtNum(amount)}',
                      children: [
                        if (currency.isNotEmpty)
                          TextSpan(
                            text: '  ${currencySymbol(currency)}',
                            style: TextStyle(
                              fontSize: R.fontSize(context, 12),
                              fontWeight: FontWeight.w600,
                              color: AppColors.textSecondary,
                            ),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 22),
                      fontWeight: FontWeight.w800,
                      color: dark ? accent.withAlpha(230) : accent,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    kind,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // ── Data rows ──
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  _row(l10n.translate('txDate'), when),
                  if (partyLabel.isNotEmpty) _row(partyLabel, party),
                  if (account.isNotEmpty && transfer == null)
                    _row(l10n.translate('txAccount'), account),
                  if (reference.isNotEmpty)
                    _row(l10n.translate('txReference'), reference),
                  if (status.isNotEmpty)
                    _row(
                      l10n.translate('txStatus'),
                      _statusLabel(status, l10n),
                    ),
                  if (byName.isNotEmpty)
                    _row(
                      l10n.translate('txExecutedBy'),
                      byIsManager ? l10n.translate('txManager') : byName,
                    ),
                  if (notes.isNotEmpty) _row(l10n.translate('txNotes'), notes),
                ],
              ),
            ),
            if (transfer != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(
                    color: AppColors.primary.withAlpha(dark ? 80 : 60),
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  children: [
                    _row(
                      l10n.translate('transferFrom'),
                      _accountLine(
                        transfer['from_account'],
                        transfer['from_currency'],
                      ),
                    ),
                    _row(
                      l10n.translate('transferSentAmount'),
                      '${fmtNum(transfer['from_amount'])} '
                      '${currencySymbol((transfer['from_currency'] ?? '').toString())}',
                    ),
                    _row(
                      l10n.translate('transferTo'),
                      _accountLine(
                        transfer['to_account'],
                        transfer['to_currency'],
                      ),
                    ),
                    _row(
                      l10n.translate('transferReceivedAmount'),
                      '${fmtNum(transfer['to_amount'])} '
                      '${currencySymbol((transfer['to_currency'] ?? '').toString())}',
                    ),
                    if (transfer['rate'] != null)
                      _rateRow(
                        l10n.translate('transferRate'),
                        transfer['from_currency'],
                        transfer['rate'],
                        transfer['to_currency'],
                      ),
                  ],
                ),
              ),
            ],
            if (canViewDoc) ...[
              const SizedBox(height: 16),
              SizedBox(
                height: 52,
                child: ElevatedButton.icon(
                   onPressed: () {
                     if (!_current) return;
                     if (isSaleReturn || isPurchaseReturn) {
                       openCommerceRecord(context, RouteNames.returnsView, sourceId,
                         kind: isSaleReturn ? 'sale_return' : 'purchase_return',
                         fromLocal: scope,
                       );
                     } else if (isOpeningDebt && scope != null) {
                       context.push(RouteNames.invoicesView, extra: DirectoryDebtInvoiceReference(
                         id: sourceId,
                         party: DirectoryPartyReference(scope: scope,
                           kind: isSaleSide ? DirectoryPartyKind.customer : DirectoryPartyKind.supplier,
                           id: '${t['party_id']}'),
                       ));
                     } else if (hasInvoice) {
                      // For a real invoice transaction the invoice id IS the
                      // source_id (the backend row keeps invoice_id null on that
                      // path) — otherwise the view would load with an empty id
                      // and show «null»/no lines.
                      final invId = isInvoice ? sourceId : invoiceId;
                       openCommerceRecord(context, RouteNames.invoicesView, invId,
                         kind: isSaleSide ? 'sale' : 'purchase', fromLocal: scope,
                       );
                    }
                  },
                  icon: const Icon(Icons.receipt_long, size: 20),
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      l10n.translate('viewInvoice'),
                      maxLines: 1,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 14),
                        height: 1.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
            if (t['reconciliation_id'] case final String reconId
                when scope != null && ref.watch(localBankReconciliationAllowedProvider)) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () {
                  if (!_current) return;
                  final source = ref.read(reconciliationApiProvider);
                  if (!source.canReadDeviceBank) return;
                  context.push('/reconciliation/detail', extra: LocalReconciliationLink(source, reconId));
                },
                icon: const Icon(Icons.fact_check_outlined),
                label: Text(l10n.translate('reconDetailsTitle')),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// «اسم الحساب (رمز العملة)» — account + its currency for a transfer leg.
  String _accountLine(dynamic name, dynamic currency) {
    final n = (name ?? '').toString().trim();
    final c = (currency ?? '').toString().trim();
    if (n.isEmpty && c.isEmpty) return '—';
    if (c.isEmpty) return n;
    return '$n · ${currencySymbol(c)}';
  }

  String _rateName(dynamic code) {
    final c = '${code ?? ''}'.toUpperCase();
    if (c == 'USD' && AppLocalizations.currentLanguage == 'ar') {
      return 'دولار';
    }
    return currencyLabel(c, locale: AppLocalizations.currentLanguage);
  }

  Widget _rateRow(String label, dynamic from, dynamic rate, dynamic to) {
    final style = TextStyle(
      fontFamily: 'Cairo',
      fontSize: R.fontSize(context, 13),
      fontWeight: FontWeight.w700,
      color: AppColors.textPrimary,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 12),
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Wrap(
                spacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('1', style: style),
                  Text(_rateName(from), style: style),
                  Text('=', style: style),
                  Text(fmtRate(rate), style: style),
                  Text(_rateName(to), style: style),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool ltr = false}) {
    final valueStyle = TextStyle(
      fontFamily: 'Cairo',
      fontSize: R.fontSize(context, 13),
      fontWeight: FontWeight.w700,
      color: AppColors.textPrimary,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 12),
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: ltr
                ? Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(
                      value,
                      textAlign: TextAlign.left,
                      style: valueStyle,
                    ),
                  )
                : Text(value, style: valueStyle),
          ),
        ],
      ),
    );
  }
}
