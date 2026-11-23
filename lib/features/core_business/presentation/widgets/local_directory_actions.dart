import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/network/api_exceptions.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../data/local_directory/directory_database.dart';
import '../../data/local_directory/directory_party.dart';
import '../../data/local_directory/directory_pilot.dart';
import '../../data/local_directory/directory_scope.dart';
import '../../data/local_ledger/business_money.dart';
import '../providers/business_ledger_session.dart';
import 'add_party_debt_sheet.dart';
import 'debt_settlement.dart';

void openDirectoryParty(
  BuildContext context,
  WidgetRef ref,
  DirectoryPartyReference party,
) {
  try {
    party.requireScope(ref.read(directoryPilotAccessProvider));
    final path = party.kind == DirectoryPartyKind.customer
        ? '/customers/detail'
        : '/suppliers/detail';
    context.push(path, extra: party);
  } on DirectoryAccessDenied catch (e) {
    showFyonaSnack(
      context,
      directorySaveError(e, party.kind, AppLocalizations.of(context)),
      success: false,
    );
  }
}

Future<bool> openLocalPartyWithDebtSheet(
  BuildContext context,
  WidgetRef ref,
  DirectoryAccess scope,
  DirectoryPartyKind kind,
  List<String> names,
) {
  final commandId = const Uuid().v4();
  final l10n = AppLocalizations.of(context);
  return showAddPartyDebtSheet(
    context,
    ref,
    isSupplier: kind == DirectoryPartyKind.supplier,
    existingNames: names,
    saveLocal: (name, phone, amount, currency) => withBusinessLedger(
      ref,
      scope,
      BusinessLedgerAction.createDebt,
      ['debts.add', '${kind.name}s.add'],
      (ledger, grant) => ledger.addPartyWithOpeningDebt(
        grant,
        kind,
        commandId: commandId,
        name: name,
        phone: phone,
        amountMinor: BusinessMoney.minor(amount, halfEven: true),
        currency: currency,
      ),
    ),
    localError: (error) => directorySaveError(error, kind, l10n),
  );
}

Future<void> deleteLocalDebtParty(
  WidgetRef ref,
  DirectoryAccess scope,
  DirectoryPartyKind kind,
  String id,
) async {
  final target = DirectoryPartyReference(scope: scope, kind: kind, id: id);
  final commandId = const Uuid().v4();
  await withBusinessLedger(
    ref,
    scope,
    BusinessLedgerAction.deleteParty,
    ['${kind.name}s.delete'],
    (ledger, grant) =>
        ledger.deleteUnlinkedParty(grant, target, commandId: commandId),
  );
}

Future<bool> showLocalGroupSettlement(
  BuildContext context,
  WidgetRef ref,
  DirectoryAccess scope,
  DirectoryDebtGroupReference group,
) => _showLocalSettlement(context, ref, scope, group.party, groupId: group.id);

Future<bool> showLocalInvoiceSettlement(
  BuildContext context,
  WidgetRef ref,
  DirectoryAccess scope,
  DirectoryDebtInvoiceReference target,
) => _showLocalSettlement(context, ref, scope, target.party, invoice: target);

Future<bool> _showLocalSettlement(
  BuildContext context,
  WidgetRef ref,
  DirectoryAccess scope,
  DirectoryPartyReference party, {
  String? groupId,
  DirectoryDebtInvoiceReference? invoice,
}) async {
  final l10n = AppLocalizations.of(context);
  final permissions = [
    'debts.settle',
    'debts.details',
    '${party.kind.name}s.details',
  ];
  try {
    final rows = await withBusinessLedger(
      ref,
      scope,
      BusinessLedgerAction.readBank,
      permissions,
      (ledger, grant) => ledger.accounts(grant),
    );
    if (!context.mounted) return false;
    final Map<String, double> remaining;
    if (invoice == null) {
      remaining = (await loadLocalDebts(ref, scope, party, groupId: groupId))
          .settlementBuckets;
    } else {
      final operation = await withBusinessLedger(
        ref,
        scope,
        BusinessLedgerAction.readDebt,
        permissions,
        (ledger, grant) => ledger.openingDebtOperation(grant, invoice),
      );
      final amount = double.parse(operation['remaining'] as String);
      remaining = {if (amount > 0) operation['currency'] as String: amount};
    }
    if (!context.mounted || remaining.isEmpty) return false;
    final rates = invoice != null ? null : await ref.read(localBusinessRatesProvider.future);
    bool allowed(WidgetRef r, {required bool watch}) {
      final selected = watch
          ? r.watch(businessLocalLedgerScopeProvider)
          : r.read(businessLocalLedgerScopeProvider);
      final hasAccess = permissions.map((permission) => watch
          ? r.watch(employeeCanProvider(permission))
          : r.read(employeeCanProvider(permission))).toList();
      return !BranchScope.readOnly && sameDirectoryScope(scope, selected) &&
          selected!.canRead(party.kind) && hasAccess.every((value) => value);
    }
    if (!context.mounted || !allowed(ref, watch: false)) {
      return false;
    }
    final command = const Uuid().v4();
    return await showDebtSettlementSheet(
      context,
      ref,
      isSupplier: party.kind == DirectoryPartyKind.supplier,
      partyId: '', // No remote party ID, even in the dialog's navigation state.
      currency: remaining.keys.first,
      remaining: remaining.values.first,
      groupId: groupId,
      invoiceId: invoice?.id,
      local: LocalDebtSettlement(
        accounts: [
          for (final row in rows)
            {
              'id': row['id'] as String,
              'bank': row['bank_name'] as String,
              'name': row['account_name'] as String,
              'currency': row['currency'] as String,
              'type': row['account_type'] as String,
              'balance': BusinessMoney.display(row['balance_minor'] as int),
            },
        ],
        remainingByCurrency: remaining,
        savedRate: (from, to) => rates?.getRate(from, to),
        visible: (r) => allowed(r, watch: true),
        save: (account, currency, amount, debtCurrency, rate) =>
            withBusinessLedger(
              ref,
              scope,
              BusinessLedgerAction.settleDebt,
              permissions,
              (ledger, grant) async {
                await ledger.settle(
                  grant,
                  party,
                  commandId: command,
                  accountId: account,
                  currency: currency,
                  amountMinor: BusinessMoney.minor(amount),
                   groupId: groupId,
                   invoiceId: invoice?.id,
                   rate: currency == debtCurrency
                       ? null
                       : BusinessRate(currency, debtCurrency, rate),
                );
              },
            ),
        error: (error) => directorySaveError(error, party.kind, l10n),
      ),
    );
  } catch (error) {
    if (context.mounted) {
      showFyonaSnack(
        context,
        directorySaveError(error, party.kind, l10n),
        success: false,
      );
    }
    return false;
  }
}

String directorySaveError(
  Object error,
  DirectoryPartyKind kind,
  AppLocalizations l10n,
) {
  if (error is DirectoryValidation) {
    final customer = kind == DirectoryPartyKind.customer;
    return switch (error.problem) {
      DirectoryValidationProblem.duplicateName => l10n.translate(
        customer ? 'debtDuplicateCustomer' : 'debtDuplicateSupplier',
      ),
      DirectoryValidationProblem.duplicatePhone =>
        customer
            ? 'يوجد عميل بنفس رقم الهاتف مسبقًا'
            : 'يوجد مورد بنفس رقم الهاتف مسبقًا',
      DirectoryValidationProblem.nameLength ||
      DirectoryValidationProblem.phoneLength => l10n.translate(
        'coreInvalidData',
      ),
      DirectoryValidationProblem.groupNameLength => l10n.translate(
        'coreInvalidData',
      ),
    };
  }
  if (error is DirectoryAccessDenied) return l10n.translate('unauthorized');
  if (error is FormatException) return l10n.translate('coreInvalidData');
  if (error is BusinessLedgerError) {
    return l10n.translate(switch (error.problem) {
      BusinessLedgerProblem.invalidAmount => 'pleaseEnterAmount',
      BusinessLedgerProblem.insufficientBalance => 'insufficientBalance',
      BusinessLedgerProblem.missingRate => 'debtFxMissing',
      BusinessLedgerProblem.invalidInvoice => 'saleInvoiceNotFound',
      BusinessLedgerProblem.noDebtInCurrency => 'noDebts',
      _ => 'errorOccurred',
    });
  }
  if (error is DirectoryPartyNotFound) {
    return l10n.translate(
      kind == DirectoryPartyKind.customer
          ? 'customersCustomerNotFound'
          : 'suppliersNotFound',
    );
  }
  return error is ApiException
      ? error.message
      : l10n.translate('errorOccurred');
}

Map<String, dynamic> directoryListRow(DirectoryParty row) => {
  'id': row.id,
  'name': row.name,
  'phone': row.phone,
};
