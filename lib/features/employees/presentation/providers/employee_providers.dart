import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import '../../../../core/di/providers.dart';
import '../../../../core/services/connectivity_service.dart';
import '../../data/employee_api.dart';
import '../../data/employee_local_finance.dart';
import '../../data/employee_device_finance.dart';
import '../../data/employee_permissions.dart';
import '../../../branches/data/branch_api.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../branches/data/branch_epoch.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../../core_business/data/local_ledger/business_relay_identity.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../../personal/data/models/personal_models.dart';
import 'employee_device_finance_provider.dart';
import '../../../core_business/data/local_directory/directory_database.dart';
import '../../../core_business/presentation/providers/business_sync_provider.dart';

/// The device-ledger writer for employee payroll and debts. It exists only
/// while a registered Business ledger is selected; otherwise every call in
/// this feature keeps using the connected API unchanged.
final employeeLocalFinanceProvider = Provider<EmployeeLocalFinance>((ref) {
  final selected = ref.watch(businessLocalLedgerScopeProvider);
  final container = ref.container;
  var active = true;
  ref.onDispose(() => active = false);
  return EmployeeLocalFinance(
    scope: () =>
        active &&
            selected != null &&
            BranchScope.branchId == selected.branchId &&
            BranchScope.organizationId == selected.workspace.organizationId &&
            sameDirectoryScope(
              selected,
              container.read(businessLocalLedgerScopeProvider),
            )
        ? selected
        : null,
    store: () => container.read(directoryPilotStoreProvider),
    allowed: () =>
        active &&
        container.read(employeeCanProvider('employees')) &&
        !BranchScope.readOnly,
    cashSession: () async {
      if (!active || selected == null || !businessCashRelayEnabled) return null;
      return readBusinessCashSession(
        container.read(secureStorageProvider),
        selected.workspace.accountId,
      );
    },
  );
});

final employeePaymentAccountsProvider = FutureProvider.autoDispose
    .family<List<PersonalBankAccount>, String>((ref, branchId) async {
      if (ref.watch(employeeDeviceSelectionProvider) != null) {
        throw const DirectoryAccessDenied();
      }
      final local = ref.watch(businessLocalLedgerScopeProvider);
      if (local != null) {
        if (branchId != local.branchId) throw const DirectoryAccessDenied();
        final rows = await ref
            .read(employeeLocalFinanceProvider)
            .bankAccounts();
        return [
          for (final row in rows)
            PersonalBankAccount.fromServer({
              'id': row['id'],
              'bank_name': row['bank_name'],
              'balance': (row['balance_minor'] as int) / 100.0,
              'currency': row['currency'],
              'account_type': row['account_type'],
            }),
        ];
      }
      final response = await ref
          .watch(apiClientProvider)
          .get(
            '/business/payment-options',
            queryParameters: {'branch_id': branchId},
          );
      final raw = response.data is Map ? response.data['data'] : response.data;
      return [
        for (final row in (raw as List? ?? const []).whereType<Map>())
          PersonalBankAccount.fromServer({
            ...Map<String, dynamic>.from(row),
            'balance': num.tryParse('${row['balance'] ?? 0}') ?? 0,
          }),
      ];
    });

final employeeSalarySummaryProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>(
      (ref, id) => ref.watch(employeeApiProvider).salary(id),
    );
final employeeDebtSummaryProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>(
      (ref, id) => ref.watch(employeeApiProvider).debts(id),
    );

final employeeApiProvider = Provider<EmployeeApi>((ref) {
  final finance = ref.watch(employeeLocalFinanceProvider);
  return EmployeeApi(
    ref.watch(apiClientProvider),
    localFinance: () =>
        ref.read(businessLocalLedgerScopeProvider) == null ? null : finance,
    employeeDeviceSelected: () =>
        ref.read(employeeDeviceSelectionProvider) != null,
  );
});
final employeesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      ref.watch(branchEpochProvider);
      return ref.watch(employeeApiProvider).list();
    });
final myInvitationsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final api = ref.watch(employeeApiProvider);
      return _employmentRead(
        ref,
        api.myInvitations,
        (copy) => [copy.employment],
      );
    });
final myEmployeeFinanceProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>(
      (ref) => _myFinance(ref, null),
    );
final myEmployeeProfileProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>(
      (ref) => _myProfile(ref, null),
    );

final myEmployeeProfileForProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, org) => _myProfile(ref, org));

final employeeWorkspaceCompanyProvider = Provider<Map<String, dynamic>?>((ref) {
  ref.watch(branchEpochProvider);
  final companies = ref.watch(branchAccessProvider).valueOrNull ?? const [];
  for (final company in companies) {
    if ('${company['organization_id']}' == BranchScope.organizationId &&
        company['role'] == 'member') {
      return company;
    }
  }
  return null;
});

final employeeInvitationProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, id) async {
      final api = ref.watch(employeeApiProvider);
      return _employmentRead(ref, () => api.invitation(id), (copy) {
        if (copy.employment['id'] != id) throw const DirectoryAccessDenied();
        return copy.employment;
      });
    });

Future<T> _employmentRead<T>(
  Ref ref,
  Future<T> Function() live,
  T Function(EmployeeReadCopy) saved,
) async {
  if (ref.watch(employeeDeviceSelectionProvider) == null) return live();
  final cached = ref
      .watch(employeeDeviceCopyProvider.future)
      .then<EmployeeReadCopy?>((copy) => copy, onError: (Object _) => null);
  if (ref.watch(connectivityServiceProvider).isOnline) {
    try {
      return await live();
    } on DioException catch (error) {
      if (!const {
        DioExceptionType.connectionError,
        DioExceptionType.connectionTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.sendTimeout,
      }.contains(error.type)) {
        rethrow;
      }
    }
  }
  final copy = await cached;
  if (copy == null || !DateTime.now().isBefore(copy.expires)) {
    throw const DirectoryAccessDenied();
  }
  return saved(copy);
}

final employeeFinanceForProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>(_myFinance);

Future<Map<String, dynamic>> _myFinance(Ref ref, String? id) async {
  final selected = ref.watch(employeeDeviceSelectionProvider);
  if (selected == null)
    return ref.watch(employeeApiProvider).myFinance(employeeId: id);
  if (id != null && id != selected.employee)
    throw const DirectoryAccessDenied();
  final copy = await ref.watch(employeeDeviceCopyProvider.future);
  if (copy?.finance case final Map<String, dynamic> data) return data;
  throw const DirectoryAccessDenied();
}

Future<Map<String, dynamic>> _myProfile(Ref ref, String? org) async {
  final selected = ref.watch(employeeDeviceSelectionProvider);
  if (selected == null || (org != null && org != selected.organization)) {
    return ref.watch(employeeApiProvider).myProfile(organizationId: org);
  }
  final copy = await ref.watch(employeeDeviceCopyProvider.future);
  return copy?.profile ?? (throw const DirectoryAccessDenied());
}

/// A dialog opened before an unlink or account switch must not keep a
/// printable copy alive once its source is no longer authorized.
Widget protectEmployeeReceipt(
  EmployeeReadSelection selection,
  String id,
  String collection,
  Widget receipt,
) => Consumer(
  builder: (context, ref, _) {
    if (ref.watch(employeeDeviceSelectionProvider) != selection) {
      return const SizedBox.shrink();
    }
    final snapshot = ref.watch(employeeDeviceCopyProvider);
    final view = snapshot.isLoading ? null : snapshot.asData?.value;
    final rows = view?.finance?[collection] as List? ?? const [];
    return rows.whereType<Map>().any((row) => row['id'] == id)
        ? receipt
        : const SizedBox.shrink();
  },
);

/// An employee device's own permissions as synced from the owner through the
/// relay — the owner can change them offline and they arrive on reconnect.
final localMemberPermissionsProvider = FutureProvider<Map<String, bool>?>((ref) async {
  ref.watch(businessSyncRevisionProvider);
  final scope = ref.watch(businessLocalLedgerScopeProvider);
  final user = ref.watch(currentUserProvider);
  if (scope == null || !scope.member || user == null) return null;
  return ref
      .read(directoryPilotStoreProvider)
      .withSync(scope, (db) => db.memberPermissions(scope, user.id));
});

final employeePermissionsProvider = Provider<Map<String, bool>>((ref) {
  ref.watch(branchEpochProvider);
  final synced = ref.watch(localMemberPermissionsProvider).valueOrNull;
  if (synced != null) return {...synced, 'employees': false};
  final companies = ref.watch(branchAccessProvider).valueOrNull ?? const [];
  final org = BranchScope.organizationId;
  for (final c in companies) {
    if ('${c['organization_id']}' == org && '${c['role']}' == 'member') {
      final raw = c['permissions'];
      if (raw is Map) {
        return {
          for (final e in raw.entries) '${e.key}': e.value == true,
          'employees': false,
        };
      }
      return defaultEmployeePermissions(value: false);
    }
  }
  if (BranchScope.token != null &&
      BranchScope.organizationId != null &&
      ref.watch(currentUserProvider)?.organizationId !=
          BranchScope.organizationId) {
    return defaultEmployeePermissions(value: false);
  }
  return {...defaultEmployeePermissions(), 'employees': true};
});

/// True when the active employee workspace grants [key] (or its parent).
/// Merchant accounts always have every permission.
final employeeCanProvider = Provider.family<bool, String>((ref, key) {
  final perms = ref.watch(employeePermissionsProvider);
  final user = ref.watch(currentUserProvider);
  final foreign =
      BranchScope.organizationId != null &&
      user != null &&
      BranchScope.organizationId != user.organizationId;
  if (ref.watch(employeeWorkspaceCompanyProvider) == null && !foreign)
    return true;
  return employeePermissionAllowed(perms, key);
});

final employeeReportCanProvider = Provider.family<bool, String>((ref, kind) {
  final keys = <String>['reports.view'];
  if (kind == 'inventory') {
    keys.add('inventory');
  } else {
    keys.add('banks.balances');
    if (kind == 'money') {
      keys.addAll(['banks.details', 'transactions']);
    } else if (kind == 'debts') {
      keys.add('debts.details');
    } else {
      keys.addAll([
        'sales.view',
        'purchases.view',
        'income',
        'expenses',
        'debts.details',
      ]);
    }
  }
  return keys.every((key) => ref.watch(employeeCanProvider(key)));
});
