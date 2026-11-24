import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_provider.dart';
import '../../../core_business/data/local_commerce/all_branches_commerce.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../../core_business/presentation/providers/business_ledger_session.dart';
import '../../data/purchase_api.dart';
import '../../../sales/domain/sale_totals.dart';

import '../../../sales/presentation/providers/sale_providers.dart'
    show SaleItem, SalePaymentRow, newIdempotencyKey, businessPaymentRows;

final purchaseApiProvider = Provider<PurchaseApi>((ref) {
  // «جميع الفروع»: every branch's records, read-only.
  final all = ref.watch(allBranchesCommerceProvider);
  if (all != null) return AllBranchesPurchaseApi(all);
  return localCommerceApi<PurchaseApi>(
    PurchaseApi.new,
    LocalPurchaseApi.new,
    ref.watch(apiClientProvider),
    ref.watch(localCommerceBridgeProvider),
  );
});

final purchaseAccountsProvider = FutureProvider<List<Map<String, String>>>((ref) async {
  final api = ref.watch(purchaseApiProvider);
  if (api is LocalPurchaseApi) ref.watch(businessBankRevisionProvider);
  return businessPaymentRows(await api.bankAccounts());
});

/// Payments and items reuse the exact sale row types (multi-currency snapshot).
typedef PurchasePaymentRow = SalePaymentRow;

class PurchaseSupplier {
  final String? id;
  final String name;
  final String? phone;
  const PurchaseSupplier({this.id, required this.name, this.phone});
  bool get isCash => id == null;
  static const cash = PurchaseSupplier(name: 'مورد نقدي');
  PurchaseSupplier copyWith({String? id, String? name, String? phone}) =>
      PurchaseSupplier(
          id: id ?? this.id, name: name ?? this.name, phone: phone ?? this.phone);
}

/// Purchase draft: same shape/philosophy as the sale draft, reversed money
/// direction. Items + payment rows are the SAME types as sales so the UI and
/// snapshots behave identically.
const _unsetP = Object();

class PurchaseDraft {
  final PurchaseSupplier? supplier;
  final List<SaleItem> items;
  final String currency;
  final String? discountType;
  final double discountValue;
  final String? taxType;
  final double taxRate;
  final String? notes;
  final DateTime? dueDate;
  final int? payMode;
  final String? debtGroupId;
  final List<SalePaymentRow> payments;
  final String idempotencyKey;
  final bool issuing;
  final String? error;

  const PurchaseDraft({
    this.supplier,
    this.items = const [],
    this.currency = '',
    this.discountType,
    this.discountValue = 0,
    this.taxType,
    this.taxRate = 0,
    this.notes,
    this.dueDate,
    this.payMode,
    this.debtGroupId,
    this.payments = const [],
    required this.idempotencyKey,
    this.issuing = false,
    this.error,
  });

  Map<String, double> get totals => calcSaleTotals(
        lines: [
          for (final it in items)
            (
              quantity: it.quantity,
              unitPrice: it.unitPrice,
              discount: it.discount
            ),
        ],
        discountType: discountType,
        discountValue: discountValue,
        taxType: taxType,
        taxRate: taxRate,
      );
  double get total => totals['total']!;
  double get paid => payments.fold(0.0, (s, p) => s + p.equivalent);
  double get remaining => (total - paid) < 0 ? 0 : total - paid;

  /// Anything the merchant entered that the invoice exit prompt protects.
  bool get hasEnteredData =>
      items.isNotEmpty ||
      supplier != null ||
      payments.any((p) => p.accountId.isNotEmpty) ||
      (notes ?? '').trim().isNotEmpty;

  PurchaseDraft copyWith({
    PurchaseSupplier? supplier,
    List<SaleItem>? items,
    String? currency,
    String? discountType,
    double? discountValue,
    String? taxType,
    double? taxRate,
    String? notes,
    DateTime? dueDate,
    int? payMode,
    Object? debtGroupId = _unsetP,
    List<SalePaymentRow>? payments,
    String? idempotencyKey,
    bool? issuing,
    String? error,
  }) =>
      PurchaseDraft(
        supplier: supplier ?? this.supplier,
        items: items ?? this.items,
        currency: currency ?? this.currency,
        discountType: discountType ?? this.discountType,
        discountValue: discountValue ?? this.discountValue,
        taxType: taxType ?? this.taxType,
        taxRate: taxRate ?? this.taxRate,
        notes: notes ?? this.notes,
        dueDate: dueDate ?? this.dueDate,
        payMode: payMode ?? this.payMode,
        debtGroupId: identical(debtGroupId, _unsetP)
            ? this.debtGroupId
            : debtGroupId as String?,
        payments: payments ?? this.payments,
        idempotencyKey: idempotencyKey ?? this.idempotencyKey,
        issuing: issuing ?? this.issuing,
        error: error,
      );
}

class PurchaseDraftNotifier extends StateNotifier<PurchaseDraft> {
  PurchaseDraftNotifier()
      : super(PurchaseDraft(idempotencyKey: newIdempotencyKey()));

  void reset() => state = PurchaseDraft(idempotencyKey: newIdempotencyKey());

  void setSupplier(PurchaseSupplier s) =>
      state = state.copyWith(supplier: s, error: null);

  void setDebtGroup(String? id) =>
      state = state.copyWith(debtGroupId: id);
  void setCurrency(String c) {
    state = state.copyWith(currency: c, error: null);
    _syncFullPayment();
  }

  void setCurrencyAndPayments(String c, List<SalePaymentRow> rows) {
    state = state.copyWith(currency: c, payments: rows, error: null);
    _syncFullPayment();
  }

  void addItem(SaleItem item) {
    state = state.copyWith(items: [...state.items, item], error: null);
    _syncFullPayment();
  }

  void updateItem(int index, SaleItem item) {
    final list = [...state.items];
    list[index] = item;
    state = state.copyWith(items: list, error: null);
    _syncFullPayment();
  }

  void removeItem(int index) {
    final list = [...state.items];
    list.removeAt(index);
    state = state.copyWith(items: list, error: null);
    _syncFullPayment();
  }

  void setNotes(String? v) => state = state.copyWith(notes: v);
  void setDueDate(DateTime? v) => state = state.copyWith(dueDate: v);
  void setPayMode(int mode) {
    state = state.copyWith(payMode: mode, error: null);
    _syncFullPayment();
  }

  void setPayments(List<SalePaymentRow> rows) {
    state = state.copyWith(payments: rows, error: null);
    _syncFullPayment();
  }

  /// Edit ONE payment row's amount manually (mirrors the sale invoice): in
  /// «دفع كامل» with more than one receiving account the total is redistributed
  /// instantly, the balancing row absorbing the remainder by its frozen rate.
  void setPaymentAmount(int index, double amount) {
    final rows = [...state.payments];
    if (index < 0 || index >= rows.length) return;
    rows[index] = rows[index].copyWith(amount: amount < 0 ? 0 : amount);
    if (state.payMode == 0) {
      final idxs = [
        for (var i = 0; i < rows.length; i++)
          if (rows[i].accountId.isNotEmpty || rows[i].currency.isNotEmpty) i
      ];
      if (idxs.length > 1) {
        final first = idxs.first;
        // The FIRST account is ALWAYS the balancing account (remainder in its
        // own currency); the other accounts keep their entered amounts.
        if (index != first) {
          final others = [
            for (final i in idxs)
              if (i != first) rows[i].equivalent
          ].fold<double>(0, (s, e) => s + e);
          final rate = rows[first].exchangeRate <= 0
              ? 1.0
              : rows[first].exchangeRate;
          var rem = (state.total - others) / rate;
          if (rem < 0) rem = 0;
          rows[first] = rows[first].copyWith(amount: rem);
        }
      }
    }
    state = state.copyWith(payments: rows, error: null);
  }

  void setItems(List<SaleItem> items) {
    state = state.copyWith(items: items, error: null);
    _syncFullPayment();
  }

  void setIssuing(bool v, {String? error}) =>
      state = state.copyWith(issuing: v, error: error);

  void finishIssuing(String commandId) {
    if (mounted && state.idempotencyKey == commandId) setIssuing(false);
  }

  /// «دفع كامل»: auto-fill the amount to the WHOLE invoice total in the
  /// payment's own currency, re-computed whenever the total or invoice
  /// currency changes (never leaves a stale amount from the old currency).
  void _syncFullPayment() {
    if (state.payMode != 0) return;
    final rows = state.payments;
    if (rows.isEmpty) return;
    final idxs = [
      for (var i = 0; i < rows.length; i++)
        if (rows[i].accountId.isNotEmpty || rows[i].currency.isNotEmpty) i
    ];
    if (idxs.isEmpty) return;
    final first = idxs.first;
    final r = rows[first];
    final rate = r.exchangeRate <= 0 ? 1.0 : r.exchangeRate;
    final others = [
      for (final i in idxs)
        if (i != first) rows[i].equivalent
    ].fold<double>(0, (s, e) => s + e);
    var amount = (state.total - others) / rate;
    if (amount < 0) amount = 0;
    if ((r.amount - amount).abs() < 0.0000001) return;
    final next = [...rows];
    next[first] = r.copyWith(amount: amount);
    state = state.copyWith(payments: next, error: null);
  }

  String? validateForIssue() {
    if (state.items.isEmpty) return 'saleErrEmpty';
    if (state.currency.isEmpty) return 'saleErrNeedCurrency';
    if (state.payMode == null) return 'saleNeedPayMode';
    // A line priced in another currency needs a REAL rate (never 1:1): either
    // a converted price (exchangeRateUsed > 0) or a manual price.
    final ic = state.currency.toUpperCase();
    for (final it in state.items) {
      final pc = (it.priceCurrency ?? '').toUpperCase();
      if (pc.isEmpty || pc == ic || it.priceManual) continue;
      if (it.exchangeRateUsed == null || it.exchangeRateUsed! <= 0) {
        return 'saleErrItemRate';
      }
    }
    for (final p in state.payments) {
      if (p.accountId.isEmpty) return 'saleErrNeedAccount';
      if (p.currency.isEmpty) return 'saleErrNeedCurrency';
      if (p.currency != state.currency && p.exchangeRate <= 0) {
        return 'saleErrNeedRate';
      }
    }
    if (state.paid - state.total > 0.005) return 'saleErrOverpaid';
    if (state.payMode == 0 && state.paid < state.total - 0.005) {
      return 'saleErrFullShort';
    }
    final supplier = state.supplier;
    if (state.remaining > 0.005 && (supplier == null || supplier.isCash)) {
      return 'saleErrNeedSupplier';
    }
    return null;
  }
}

final purchaseDraftProvider =
    StateNotifierProvider<PurchaseDraftNotifier, PurchaseDraft>(
        (ref) => PurchaseDraftNotifier());

final purchaseInvoicesProvider =
    FutureProvider.family<List<dynamic>, String>((ref, search) async {
  final api = ref.watch(purchaseApiProvider);
  return api.purchaseInvoices(search: search);
});

/// Which purchase-invoice section to flash red after a failed issue attempt
/// ('supplier' | 'items' | 'payment').
final purchaseHighlightProvider = StateProvider<String?>((ref) => null);
