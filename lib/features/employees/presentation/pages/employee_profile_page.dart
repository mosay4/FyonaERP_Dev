import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../branches/data/branch_epoch.dart';
import '../../../profile/presentation/pages/profile_page.dart';
import '../../data/employee_permissions.dart';
import '../providers/employee_providers.dart';
import '../providers/employee_device_finance_provider.dart';

/// Uses the original profile's controls, sheets, icons and layout. Only the
/// identity and the explicitly allowed sections differ in a merchant workspace.
class EmployeeProfilePage extends ConsumerWidget {
  const EmployeeProfilePage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(branchEpochProvider);
    final org = BranchScope.organizationId;
    final workspace = ref.watch(employeeWorkspaceCompanyProvider);
    final livePermissions = workspace != null
        ? ref.watch(employeePermissionsProvider)
        : null;
    final profile = org == null
        ? ref.watch(myEmployeeProfileProvider)
        : ref.watch(myEmployeeProfileForProvider(org));
    return profile.when(
      skipLoadingOnRefresh: ref.watch(employeeDeviceSelectionProvider) == null,
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (_, _) =>
          const Scaffold(body: Center(child: Text('تعذر تحميل ملف الموظف'))),
      data: (data) {
        final employee = Map<String, dynamic>.from(
          data['employee'] as Map? ?? {},
        );
        if (employee.isEmpty)
          return const Scaffold(
            body: Center(child: Text('لا يوجد ارتباط بهذا المتجر')),
          );
        final permissions = (employee['permissions'] as Map? ?? {}).map(
          (k, v) => MapEntry('$k', v == true),
        );
        return ProfilePage(
          business: true,
          employee: employee,
          employeeFull: employeeHasFullAccess(livePermissions ?? permissions),
        );
      },
    );
  }
}
