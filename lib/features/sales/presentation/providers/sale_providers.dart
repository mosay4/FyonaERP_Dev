import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/network/dio_provider.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../../core_business/presentation/providers/business_ledger_session.dart';
import '../../data/sales_api.dart';
import '../../domain/sale_totals.dart';
import '../../../branches/data/branch_epoch.dart';

final salesApiProvider = Provider<SalesApi>(
  (ref) => localCommerceApi<SalesApi>(
    SalesApi.new,
    LocalSalesApi.new,
    ref.watch(apiClientProvider),
    ref.watch(localCommerceBridgeProvider),
  ),
);

/// Opaque client key making re-issue safe (double-tap / retries return the
/// original invoice instead of creating a duplicate).
String newIdempotencyKey() => const Uuid().v4();

class SaleCustomer {
  final String? id;
  final String name;
  final String? phone;
  const SaleCustomer({this.id, required this.name, this.phone});
  bool get isCash => id == null;
  static const cash = SaleCustomer(name: 'عميل نقدي');
  SaleCustomer copyWith({String? id, String? name, String? phone}) =>
      SaleCustomer(
        id: id ?? this.id,
        name: name ?? this.name,
        phone: phone ?? this.phone,
      );
}

class SaleItem {
  final String? productId;
  final String? unitId;
  final String description;
  final String unitName;
  final double factor;
  final double quantity;
  final double unitPrice;
  final double discount;

  /// Line discount as a PERCENT (0-100); the merchant enters a %.
  final double discountPercent;
  final bool isService;
  final double stock;

  /// Optional inline quick-add definition (purchase invoices only). Sale flows
  /// never set it, so existing sale behaviour is unchanged.
  final Map<String, dynamic>? newProduct;

  /// Optional batch/expiry for the purchase line (lot tracking).
  final DateTime? expiryDate;
  final String? lotNumber;

  /// Independent per-currency SELL prices of the product (currency -> price).
  final Map<String, double>? sellPrices;

  /// Snapshot: the price originally used + its currency + the FX rate applied
  /// to reach the invoice currency.
  final String? priceCurrency;
  final double? originalUnitPrice;
  final double? exchangeRateUsed;

  /// True when the merchant edited the unit price by hand. A manual price is
  /// NEVER discarded or re-derived from the catalogue when the invoice
  /// currency changes — it is converted from [manualPriceCurrency] to the new
  /// currency using a correct rate (scenario: edit then switch currency).
  final bool priceManual;

  /// The invoice currency that [unitPrice] is expressed in when [priceManual]
  /// is true (so a later currency switch converts the edited value, not the
  /// original product price).
  final String? manualPriceCurrency;
  const SaleItem({
    this.productId,
    this.unitId,
    required this.description,
    this.unitName = 'قطعة',
    this.factor = 1,
    this.quantity = 1,
    this.unitPrice = 0,
    this.discount = 0,
    this.discountPercent = 0,
    this.isService = false,
    this.stock = 0,
    this.newProduct,
    this.expiryDate,
    this.lotNumber,
    this.sellPrices,
    this.priceCurrency,
    this.originalUnitPrice,
    this.exchangeRateUsed,
    this.priceManual = false,
    this.manualPriceCurrency,
  });

  /// Discount amount derived from the percent.
  double get discountAmount {
    final gross = quantity * unitPrice;
    final amt = gross * discountPercent / 100;
    return amt < 0 ? 0 : amt;
  }

  double get lineTotal => quantity * unitPrice - discountAmount;
  SaleItem copyWith({
    String? unitId,
    String? description,
    String? unitName,
    double? factor,
    double? quantity,
    double? unitPrice,
    double? discount,
    double? discountPercent,
    bool? isService,
    double? stock,
    Map<String, dynamic>? newProduct,
    DateTime? expiryDate,
    String? lotNumber,
    Map<String, double>? sellPrices,
    String? priceCurrency,
    double? originalUnitPrice,
    double? exchangeRateUsed,
    bool? priceManual,
    String? manualPriceCurrency,
  }) => SaleItem(
    productId: productId,
    unitId: unitId ?? this.unitId,
    description: description ?? this.description,
    unitName: unitName ?? this.unitName,
    factor: factor ?? this.factor,
    quantity: quantity ?? this.quantity,
    unitPrice: unitPrice ?? this.unitPrice,
    discount: discount ?? this.discount,
    discountPercent: discountPercent ?? this.discountPercent,
    isService: isService ?? this.isService,
    stock: stock ?? this.stock,
    newProduct: newProduct ?? this.newProduct,
    expiryDate: expiryDate ?? this.expiryDate,
    lotNumber: lotNumber ?? this.lotNumber,
    sellPrices: sellPrices ?? this.sellPrices,
    priceCurrency: priceCurrency ?? this.priceCurrency,
    originalUnitPrice: originalUnitPrice ?? this.originalUnitPrice,
    exchangeRateUsed: exchangeRateUsed ?? this.exchangeRateUsed,
    priceManual: priceManual ?? this.priceManual,
    manualPriceCurrency: manualPriceCurrency ?? this.manualPriceCurrency,
  );
}

/// One split payment: an account + its currency, the amount entered in that
/// currency, and the frozen conversion snapshot toward the invoice currency.
///
/// [amount] is always the ORIGINAL amount in [currency]. [exchangeRate] means
/// `1 [currency] = exchangeRate <invoice currency>`, so the equivalent in the
/// invoice currency is `amount * exchangeRate`. When both currencies match the
/// rate is 1 and the source is `same` (no snapshot needed).
class SalePaymentRow {
  final String accountId;
  final String accountName;
  final String bankName;
  final String currency;
  final double amount;
  final double exchangeRate;
  final String rateSource; // 'same' | 'auto' | 'manual'
  final DateTime? rateTimestamp;
  final String method;
  const SalePaymentRow({
    required this.accountId,
    required this.accountName,
    required this.amount,
    this.bankName = '',
    this.currency = '',
    this.exchangeRate = 1,
    this.rateSource = 'same',
    this.rateTimestamp,
    this.method = 'cash',
  });

  /// Value contributed to the invoice in its own currency.
  double get equivalent => amount * exchangeRate;

  SalePaymentRow copyWith({
    String? accountId,
    String? accountName,
    String? bankName,
    String? currency,
    double? amount,
    double? exchangeRate,
    String? rateSource,
    DateTime? rateTimestamp,
    String? method,
  }) => SalePaymentRow(
    accountId: accountId ?? this.accountId,
    accountName: accountName ?? this.accountName,
    bankName: bankName ?? this.bankName,
    currency: currency ?? this.currency,
    amount: amount ?? this.amount,
    exchangeRate: exchangeRate ?? this.exchangeRate,
    rateSource: rateSource ?? this.rateSource,
    rateTimestamp: rateTimestamp ?? this.rateTimestamp,
    method: method ?? this.method,
  );
}

/// Sentinel so `copyWith` can distinguish "not passed" from "explicitly null".
const Object _unset = Object();

/// 0 = paid in full, 1 = partial, 2 = credit (null = not chosen yet)
class SaleDraft {
  /// Null until the merchant picks (cash / existing / quick-add).
  final SaleCustomer? customer;
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

  const SaleDraft({
    this.customer,
    this.items = const [],
    // No default currency: the merchant must choose it explicitly.
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
        (quantity: it.quantity, unitPrice: it.unitPrice, discount: it.discount),
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
      customer != null ||
      payments.any((p) => p.accountId.isNotEmpty) ||
      (notes ?? '').trim().isNotEmpty;

  SaleDraft copyWith({
    SaleCustomer? customer,
    List<SaleItem>? items,
    String? currency,
    Object? discountType = _unset,
    double? discountValue,
    Object? taxType = _unset,
    double? taxRate,
    String? notes,
    DateTime? dueDate,
    int? payMode,
    Object? debtGroupId = _unset,
    List<SalePaymentRow>? payments,
    String? idempotencyKey,
    bool? issuing,
    String? error,
  }) => SaleDraft(
    customer: customer ?? this.customer,
    items: items ?? this.items,
    currency: currency ?? this.currency,
    discountType: identical(discountType, _unset)
        ? this.discountType
        : discountType as String?,
    discountValue: discountValue ?? this.discountValue,
    taxType: identical(taxType, _unset) ? this.taxType : taxType as String?,
    taxRate: taxRate ?? this.taxRate,
    notes: notes ?? this.notes,
    dueDate: dueDate ?? this.dueDate,
    payMode: payMode ?? this.payMode,
    debtGroupId: identical(debtGroupId, _unset)
        ? this.debtGroupId
        : debtGroupId as String?,
    payments: payments ?? this.payments,
    idempotencyKey: idempotencyKey ?? this.idempotencyKey,
    issuing: issuing ?? this.issuing,
    error: error,
  );
}

class SaleDraftNotifier extends StateNotifier<SaleDraft> {
  SaleDraftNotifier() : super(SaleDraft(idempotencyKey: newIdempotencyKey()));

  void reset() => state = SaleDraft(idempotencyKey: newIdempotencyKey());

  void setCustomer(SaleCustomer c) =>
      state = state.copyWith(customer: c, error: null);

  void setDebtGroup(String? id) => state = state.copyWith(debtGroupId: id);

  void setCurrency(String c) {
    // Invoice currency is normally derived from the first picked account.
    // Changing it (manually) must NOT drop the split payments — the UI
    // recomputes their conversion snapshots against the new reference.
    state = state.copyWith(currency: c, error: null);
    _syncFullPayment();
  }

  /// Set the invoice currency and the split rows together (atomic) so a
  /// currency-derived row never lands against a stale reference.
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

  void setHeaderDiscount(String? type, double value) {
    state = state.copyWith(
      discountType: type,
      discountValue: value,
      error: null,
    );
    _syncFullPayment();
  }

  void setTax(String? type, double rate) {
    state = state.copyWith(taxType: type, taxRate: rate, error: null);
    _syncFullPayment();
  }

  void setNotes(String? v) => state = state.copyWith(notes: v);
  void setDueDate(DateTime? v) => state = state.copyWith(dueDate: v);

  void setPayMode(int mode) {
    // Rows are managed by the payment UI (multi-account / multi-currency);
    // switching the mode just records the intent.
    state = state.copyWith(payMode: mode, error: null);
    _syncFullPayment();
  }

  void setPayments(List<SalePaymentRow> rows) {
    state = state.copyWith(payments: rows, error: null);
    _syncFullPayment();
  }

  /// Edit ONE payment row's amount manually. In «دفع كامل» with MORE THAN ONE
  /// receiving account, the invoice total is redistributed instantly across
  /// the accounts: the OTHER (balancing) row absorbs the remainder — converted
  /// by its own frozen rate when the currencies differ. A single receiving
  /// account stays fully automatic (never editable).
  void setPaymentAmount(int index, double amount) {
    final rows = [...state.payments];
    if (index < 0 || index >= rows.length) return;
    rows[index] = rows[index].copyWith(amount: amount < 0 ? 0 : amount);
    if (state.payMode == 0) {
      final idxs = [
        for (var i = 0; i < rows.length; i++)
          if (rows[i].accountId.isNotEmpty || rows[i].currency.isNotEmpty) i,
      ];
      if (idxs.length > 1) {
        final first = idxs.first;
        // The FIRST account is ALWAYS the balancing account: it receives the
        // remainder (in its own currency) after every other account's
        // rate-converted equivalent. Other accounts keep what was entered.
        if (index != first) {
          final others = [
            for (final i in idxs)
              if (i != first) rows[i].equivalent,
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

  /// «دفع كامل»: the amount is auto-filled to the WHOLE invoice total in the
  /// payment's own currency, and re-computed every time the total OR the
  /// invoice currency changes — so switching the invoice currency never leaves
  /// a stale amount carried over from the previous currency. Only the single
  /// (non-split) full-payment row is auto-managed; split rows stay user-driven.
  /// «دفع كامل» keeps the invoice FULLY covered in the payment currency: the
  /// FIRST receiving account absorbs the remainder after all other accounts'
  /// (rate-converted) equivalents, and is recomputed whenever the total or the
  /// invoice currency changes. A single account is simply the whole total.
  void _syncFullPayment() {
    if (state.payMode != 0) return;
    final rows = state.payments;
    if (rows.isEmpty) return;
    final idxs = [
      for (var i = 0; i < rows.length; i++)
        if (rows[i].accountId.isNotEmpty || rows[i].currency.isNotEmpty) i,
    ];
    if (idxs.isEmpty) return;
    final first = idxs.first;
    final r = rows[first];
    final rate = r.exchangeRate <= 0 ? 1.0 : r.exchangeRate;
    final others = [
      for (final i in idxs)
        if (i != first) rows[i].equivalent,
    ].fold<double>(0, (s, e) => s + e);
    var amount = (state.total - others) / rate;
    if (amount < 0) amount = 0;
    if ((r.amount - amount).abs() < 0.0000001) return;
    final next = [...rows];
    next[first] = r.copyWith(amount: amount);
    state = state.copyWith(payments: next, error: null);
  }

  void setIssuing(bool v, {String? error}) =>
      state = state.copyWith(issuing: v, error: error);

  void finishIssuing(String commandId) {
    if (mounted && state.idempotencyKey == commandId) setIssuing(false);
  }

  /// Balance that would remain — credit needs a real customer.
  /// Returns a localization key for the blocking problem, if any.
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
    // Full payment must actually cover the invoice, otherwise the merchant
    // must complete the amount or switch to partial (clear, explicit error).
    if (state.payMode == 0 && state.paid < state.total - 0.005) {
      return 'saleErrFullShort';
    }
    final customer = state.customer;
    if (state.remaining > 0.005 && (customer == null || customer.isCash)) {
      return 'saleErrNeedCustomer';
    }
    return null;
  }
}

final saleDraftProvider = StateNotifierProvider<SaleDraftNotifier, SaleDraft>(
  (ref) => SaleDraftNotifier(),
);

/// All bank/cash accounts (unfiltered). Currency strictness is enforced by
/// selection: picking an account adopts its currency, and rows of other
/// currencies are dropped. The draft starts currency-less by design.
final saleAccountsProvider = FutureProvider<List<Map<String, String>>>((
  ref,
) async {
  ref.watch(branchEpochProvider);
  final api = ref.watch(salesApiProvider);
  if (api is LocalSalesApi) ref.watch(businessBankRevisionProvider);
  return businessPaymentRows(await api.bankAccounts());
});

List<Map<String, String>> businessPaymentRows(List<dynamic> raw) {
  final unique = <String, Map>{};
  for (final a in raw.whereType<Map>()) {
    final id = a['id']?.toString() ?? '';
    if (id.isNotEmpty) unique[id] = a;
  }
  return [
    for (final a in unique.values)
      {
        'id': a['id'].toString(),
        'bank': (a['bank_name'] ?? '').toString(),
        'name': (a['account_name'] ?? '').toString(),
        'balance': a['balance_visible'] == false ? '' : (a['balance']?.toString() ?? ''),
        'balance_visible': '${a['balance_visible'] ?? true}',
        'currency': (a['currency']?.toString() ?? '').toUpperCase(),
        // checking (جاري) / savings (توفير) — shown with its colored bar.
        'type': (a['account_type']?.toString() ?? 'checking'),
      },
  ];
}

final saleInvoicesProvider = FutureProvider.family<List<dynamic>, String>((
  ref,
  search,
) async {
  final api = ref.watch(salesApiProvider);
  return api.saleInvoices(search: search);
});

/// Which sale-invoice section to flash red after a failed issue attempt
/// ('customer' | 'items' | 'payment'). Cleared automatically after a moment.
final saleHighlightProvider = StateProvider<String?>((ref) => null);
