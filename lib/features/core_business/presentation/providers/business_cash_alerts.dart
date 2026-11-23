import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../data/local_directory/directory_database.dart';
import '../../data/local_directory/directory_scope.dart';
import '../../data/local_ledger/business_money.dart';
import 'business_ledger_session.dart';

/// Private cash decisions, available on disk even when the relay is offline.
const businessCashAlertPermissions = ['expenses', 'notifications'];

Future<List<Map<String, dynamic>>> businessCashAlerts(
  WidgetRef ref,
  DirectoryAccess scope,
  AppLocalizations l10n,
) async {
  final context = ref.context;
  final rows = await withBusinessLedger(
    ref, scope, BusinessLedgerAction.syncCash, businessCashAlertPermissions,
    (ledger, grant) => ledger.cashSync.conflicts(grant),
  );
  if (!context.mounted) return [];
  final referenceVisible = ref.read(employeeCanProvider('transactions'));
  return [
    for (final row in rows)
      {
        'id': row['command_id'],
        'category': 'alert',
        'type': 'business_cash_reversed',
        'title': l10n.translate('txOperationFailed'),
        'message': l10n.translate('bizCashWithdrawalReversed', params: {
          'amount': BusinessMoney.display(row['amount_minor'] as int),
          'currency': row['currency'],
          'reason': l10n.translate(switch (row['decision']) {
            'insufficientBalance' => 'insufficientBalance',
            'permissionChanged' => 'unauthorized',
            'staleMeasurement' => 'reconDeviceCashChanged',
            _ => 'coreInvalidData',
          }),
        }),
        'is_read': row['seen'] == 1,
        'created_at': DateTime.fromMicrosecondsSinceEpoch(
          row['created_us'] as int, isUtc: true,
        ).toIso8601String(),
        if (referenceVisible) 'blocked_by': row['blocked_by'],
      },
  ];
}

Future<void> markBusinessCashAlertRead(
  WidgetRef ref, DirectoryAccess scope, String id,
) => withBusinessLedger(
  ref, scope, BusinessLedgerAction.syncCash, businessCashAlertPermissions,
  (ledger, grant) => ledger.cashSync.markConflictRead(grant, id),
);
