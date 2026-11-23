import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/router/route_names.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../data/local_directory/directory_database.dart';
import '../../data/local_directory/directory_party.dart';
import '../../data/local_directory/directory_pilot.dart';
import '../../data/local_directory/directory_scope.dart';
import '../../data/local_ledger/business_money.dart';
import '../widgets/local_directory_actions.dart';
import 'business_ledger_session.dart';

/// Only the Business route supplies this source to the existing debt screen.
/// The Personal partner view and its API, cache, and sync are unchanged.
final class BusinessLocalDebtOperation {
  const BusinessLocalDebtOperation(this.target);
  final DirectoryDebtInvoiceReference target;

  List<String> get _read => ['debts.details', '${target.party.kind.name}s.details'];
  List<String> get _edit => [..._read, 'debts.add', '${target.party.kind.name}s.edit'];
  List<String> get _settle => [..._read, 'debts.settle'];

  bool canRead(WidgetRef ref, {bool watch = false}) => _allowed(ref, _read, watch: watch);
  bool canEdit(WidgetRef ref, {bool watch = false}) => _allowed(ref, _edit, write: true, watch: watch);
  bool canSettle(WidgetRef ref, {bool watch = false}) => _allowed(ref, _settle, watch: watch);
  bool canViewInvoice(WidgetRef ref, {bool watch = false}) => _allowed(
    ref, [..._read, target.party.kind == DirectoryPartyKind.supplier ? 'purchases.view' : 'sales.view'],
    watch: watch,
  );

  bool _allowed(
    WidgetRef ref,
    List<String> permissions, {
    bool write = false,
    required bool watch,
  }) {
    final scope = watch ? ref.watch(businessLocalLedgerScopeProvider) : ref.read(businessLocalLedgerScopeProvider);
    final grants = [
      for (final key in permissions)
        watch ? ref.watch(employeeCanProvider(key)) : ref.read(employeeCanProvider(key)),
    ];
    try {
      target.party.requireScope(scope, write: write);
      return !BranchScope.readOnly && grants.every((granted) => granted);
    } on DirectoryAccessDenied {
      return false;
    }
  }

  Future<Map<String, dynamic>> read(WidgetRef ref) {
    return withBusinessLedger(
      ref, target.party.scope, BusinessLedgerAction.readDebt, _read,
      (ledger, access) => ledger.openingDebtOperation(access, target),
    );
  }

  Future<void> edit(
    WidgetRef ref, {
    required String itemId,
    required int revision,
    required String quantity,
    required String unitPrice,
  }) async {
    final command = const Uuid().v4();
    final price = unitPrice.replaceAll(',', '').trim();
    final line = BusinessOpeningDebtLine(quantity, price.isEmpty ? '0' : price);
    await withBusinessLedger(
      ref, target.party.scope, BusinessLedgerAction.editDebtInvoice, _edit,
      (ledger, access) => ledger.editOpeningDebt(
        access, target, commandId: command, itemId: itemId, revision: revision, line: line,
      ),
    );
  }

  Future<void> delete(WidgetRef ref, int revision) async {
    final command = const Uuid().v4();
    await withBusinessLedger(
      ref, target.party.scope, BusinessLedgerAction.deleteDebtInvoice, _edit,
      (ledger, access) => ledger.deleteOpeningDebt(
        access, target, commandId: command, revision: revision,
      ),
    );
  }

  Future<bool> settle(BuildContext context, WidgetRef ref) =>
      showLocalInvoiceSettlement(context, ref, target.party.scope, target);

  void openInvoice(BuildContext context, WidgetRef ref) {
    if (canViewInvoice(ref)) context.push(RouteNames.invoicesView, extra: target);
  }

  String error(Object e, AppLocalizations l10n) => directorySaveError(e, target.party.kind, l10n);
}
