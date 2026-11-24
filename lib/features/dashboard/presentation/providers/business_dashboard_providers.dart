import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_provider.dart';
import '../../../branches/data/branch_epoch.dart';
import '../../../business_banks/presentation/providers/local_business_banking.dart';
import '../../../core_business/data/local_commerce/all_branches_commerce.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../../core_business/presentation/providers/business_ledger_session.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../data/business_finance_api.dart';

// The personal account model is reused here as a pure data carrier
// (read-only import — nothing in the personal section is modified) so the
// business home renders the EXACT same card widgets with zero drift.
import '../../../personal/data/models/personal_models.dart';

final businessFinanceApiProvider = Provider<BusinessFinanceApi>((ref) {
  // «جميع الفروع»: every branch's operations, read-only.
  final all = ref.watch(allBranchesCommerceProvider);
  if (all != null) return AllBranchesFinanceApi(all);
  return localCommerceApi<BusinessFinanceApi>(
    BusinessFinanceApi.new,
    LocalBusinessFinanceApi.new,
    ref.watch(apiClientProvider),
    ref.watch(localCommerceBridgeProvider),
  );
});

final visibleBusinessOperationKindsProvider = Provider<Set<String>>((ref) {
  if (!ref.watch(employeeCanProvider('transactions'))) return const {};
  return {
    for (final entry in businessOperationPermissions.entries)
      if (entry.value
          .map((p) => ref.watch(employeeCanProvider(p)))
          .toList()
          .every((p) => p))
        entry.key,
  };
});

final businessPaymentAccountsProvider =
    FutureProvider<List<PersonalBankAccount>>((ref) async {
      final response = await ref
          .watch(apiClientProvider)
          .get('/business/payment-options');
      final raw = response.data is Map ? response.data['data'] : response.data;
      return [
        for (final a in (raw as List? ?? const []).whereType<Map>())
          PersonalBankAccount.fromServer({
            ...Map<String, dynamic>.from(a),
            'balance': num.tryParse('${a['balance'] ?? 0}') ?? 0,
          }),
      ];
    });

/// Business bank accounts for the home cards. The backend guarantees the
/// default non-deletable "كاش" account exists, so this is never empty for a
/// synced org; loading/error states fall back to the card's own empty state.
final businessAccountsProvider = FutureProvider<List<PersonalBankAccount>>((
  ref,
) async {
  ref.watch(branchEpochProvider);
  final all = ref.watch(allBranchesBankingProvider);
  final local = ref.watch(localBusinessBankingProvider);
  if (local != null) ref.watch(businessBankRevisionProvider);
  final raw = all != null
      ? await all.accounts(requireBalances: true)
      : local == null
      ? await ref.watch(businessFinanceApiProvider).listAccounts()
      : await local.accounts(requireBalances: true);
  // All-branches returns aggregate cards with their ORIGINAL accounts nested.
  // The home cards need the real per-branch rows (real balances/currencies),
  // never the aggregate envelope whose own `balance` is absent (→ zero).
  final flattened = <Map>[];
  for (final row in raw.whereType<Map>()) {
    final nested = row['accounts'];
    if (nested is List && nested.isNotEmpty) {
      flattened.addAll(nested.whereType<Map>());
    } else {
      flattened.add(row);
    }
  }
  return flattened.map((j) {
    final m = Map<String, dynamic>.from(j);
    m['balance'] = num.tryParse('${m['balance'] ?? 0}') ?? 0;
    final acct = PersonalBankAccount.fromServer(m);
    // The personal carrier forces cash rows to accountType 'cash'; for
    // Business we keep the REAL type so جاري/توفير stay distinguishable.
    final realType = m['account_type'] as String?;
    if (realType == null || realType.isEmpty) return acct;
    return PersonalBankAccount(
      id: acct.id,
      bankName: acct.bankName,
      balance: acct.balance,
      currency: acct.currency,
      notes: acct.notes,
      accountType: realType,
    );
  }).toList();
});

/// Newest business movements for the home «أحدث العمليات» strip.
/// Same unified timeline as the full transactions page (top 5).
/// Auto-disposed; reloaded on dashboard pull-to-refresh and whenever the
/// grid returns from a pushed page, so new operations appear immediately.
final businessRecentProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final api = ref.watch(businessFinanceApiProvider);
      if (!ref.watch(employeeCanProvider('transactions'))) return const [];
      if (api is LocalBusinessFinanceApi) {
        ref.watch(businessBankRevisionProvider);
        ref.watch(businessOperationsRevisionProvider);
      }
      final raw = api is AllBranchesFinanceApi
          ? await api.recent(ref.watch(visibleBusinessOperationKindsProvider), 5)
          : api is LocalBusinessFinanceApi
          ? await api.bridge.operations(
              kinds: ref.watch(visibleBusinessOperationKindsProvider),
              limit: 5,
            )
          : await api.listTransactions();
      return [
        for (final s in raw.whereType<Map>().take(5))
          Map<String, dynamic>.from(s),
      ];
    });
