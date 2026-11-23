import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart' show secureStorageProvider;
import '../../../../core/services/currency/currency_engine.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../data/local_directory/directory_database.dart';
import '../../data/local_directory/directory_pilot.dart';
import '../../data/local_directory/directory_party.dart';
import '../../data/local_directory/directory_scope.dart';
import '../../data/local_ledger/business_relay_identity.dart';
import '../../data/local_ledger/business_debt_projection.dart';
import '../../data/local_ledger/business_money.dart';

/// Restoration-only reader of approved quotes. This instance has no client
/// and does not write to the shared rate snapshot cache. Existing currency
/// refresh remains a separate background action.
final localBusinessRatesProvider = FutureProvider.autoDispose<CurrencyEngine>((
  ref,
) async {
  final rates = CurrencyEngine();
  await rates.load();
  return rates;
});

BusinessRate? businessSavedQuote(CurrencyEngine rates, String from, String to) {
  final raw = rates.getRate(from, to);
  if (raw == null || !raw.isFinite || raw <= 0) return null;
  try {
    return BusinessRate(from, to, raw.toStringAsFixed(8));
  } on FormatException {
    return null;
  }
}

/// Refresh Business account projections only after a money commit.
final businessBankRevisionProvider = StateProvider<int>((ref) => 0);

/// Also covers debt-only documents and returns with no bank leg.
final businessOperationsRevisionProvider = StateProvider<int>((ref) => 0);

Future<BusinessDebtProjection> loadLocalDebts(
  WidgetRef ref,
  DirectoryAccess scope,
  DirectoryPartyReference party, {
  bool individual = false,
  bool debtsDetailsRequired = true,
  String? groupId,
  String? dateFrom,
  String? dateTo,
}) async {
  final rows = await withBusinessLedger(
    ref,
    scope,
    BusinessLedgerAction.readDebt,
    ['${party.kind.name}s.details', if (debtsDetailsRequired) 'debts.details'],
    (ledger, grant) => ledger.debts(
      grant,
      party,
      groupId: groupId,
      individual: individual,
      dateFrom: dateFrom,
      dateTo: dateTo,
    ),
  );
  return BusinessDebtProjection(rows);
}

/// Checks the concrete branch and permissions again after a dialog or queued
/// database open. No callback is allowed to fall back to a connected writer.
Future<T> withBusinessLedger<T>(
  WidgetRef ref,
  DirectoryAccess scope,
  BusinessLedgerAction action,
  List<String> permissions,
  Future<T> Function(BusinessLedger ledger, BusinessLedgerAccess access) run,
) async {
  final context = ref.context;
  final store = ref.read(directoryPilotStoreProvider);
  final session =
      businessCashRelayEnabled && action == BusinessLedgerAction.moveMoney
      ? await readBusinessCashSession(
          ref.read(secureStorageProvider),
          scope.workspace.accountId,
        )
      : null;
  final access = BusinessLedgerAccess(scope, {action}, cashSessionId: session);
  final result = await store.withLedger(
    access,
    () =>
        context.mounted &&
            !BranchScope.readOnly &&
            permissions.every((p) => ref.read(employeeCanProvider(p)))
        ? ref.read(businessLocalLedgerScopeProvider)
        : null,
    (ledger) => run(ledger, access),
  );
  if (context.mounted &&
      sameDirectoryScope(scope, ref.read(businessLocalLedgerScopeProvider))) {
    if (const {
      BusinessLedgerAction.moveMoney,
      BusinessLedgerAction.settleDebt,
      BusinessLedgerAction.deleteDebtInvoice,
    }.contains(action)) {
      ref.read(businessBankRevisionProvider.notifier).state++;
    }
    if (const {
      BusinessLedgerAction.createDebt,
      BusinessLedgerAction.editDebtInvoice,
      BusinessLedgerAction.deleteDebtInvoice,
      BusinessLedgerAction.deleteParty,
    }.contains(action)) {
      ref.read(businessOperationsRevisionProvider.notifier).state++;
    }
  }
  return result;
}
