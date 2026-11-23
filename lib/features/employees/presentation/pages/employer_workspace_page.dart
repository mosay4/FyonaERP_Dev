import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/premium_switch_transition.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../branches/data/branch_api.dart';
import '../../../branches/data/branch_epoch.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../../core/services/section_scope.dart';
import '../../data/employee_api.dart';
import '../providers/employee_providers.dart';
import '../widgets/employee_avatar.dart';
import '../widgets/employee_unlink_action.dart';
import 'employee_salary_page.dart';
import 'employee_debts_page.dart';

class EmployerWorkspacePage extends ConsumerWidget {
  const EmployerWorkspacePage({super.key, required this.invitation});
  final Map<String, dynamic> invitation;

  Future<void> _enter(BuildContext context) async {
    final org = invitation['organization'] as Map? ?? const {};
    final id = '${org['id'] ?? ''}';
    if (id.isEmpty) return;
    final router = GoRouter.of(context);
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await PremiumSwitch.run(
        kind: PremiumSwitchKind.branch,
        from: 'الشخصي',
        to: '${org['name'] ?? 'مساحة العمل'}',
        arabic: true,
        action: () async {
          final api = container.read(branchApiProvider);
          final ids = invitation['branch_ids'] as List?;
          {
            final branches = (invitation['branches'] as List? ?? const [])
                .whereType<Map>();
            final branchId =
                branches
                    .map((b) => '${b['id'] ?? ''}')
                    .where((b) => ids == null || ids.any((id) => '$id' == b))
                    .firstOrNull ??
                ids
                    ?.map((id) => '$id')
                    .where((id) => id.isNotEmpty)
                    .firstOrNull;
            if (branchId == null) throw StateError('لا توجد فروع متاحة');
            await api.select(branchId: branchId, organizationId: id);
          }
          await BranchScope.setHasMembership(true);
          container.read(activeSectionProvider.notifier).state =
              AppSection.business;
          container.read(branchEpochProvider.notifier).state++;
          container.invalidate(branchAccessProvider);
          container.invalidate(branchesProvider);
          router.go('/dashboard');
          await WidgetsBinding.instance.endOfFrame;
        },
      );
    } catch (e) {
      if (context.mounted)
        showFyonaSnack(context, EmployeeApi.message(e), success: false);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final org = invitation['organization'] as Map? ?? const {};
    final merchant = invitation['merchant'] as Map? ?? const {};
    final emp = invitation['employee'] as Map? ?? const {};
    final employeeId = '${emp['id'] ?? invitation['employee_id'] ?? ''}';
    final name = '${emp['full_name'] ?? ''}';
    final orgName = '${org['name'] ?? ''}';
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          orgName,
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: EmployeeAvatar(
              photo: (org['photo_url'] ?? merchant['photo_url']) as String?,
              size: 88,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            orgName,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            '${merchant['name'] ?? ''}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontFamily: 'Cairo'),
          ),
          if ('${merchant['phone'] ?? ''}'.trim().isNotEmpty)
            Text(
              '${merchant['phone']}',
              textAlign: TextAlign.center,
              textDirection: TextDirection.ltr,
            ),
          const SizedBox(height: 12),
          Text(
            'مربوط',
            textAlign: TextAlign.center,
            style: TextStyle(fontFamily: 'Cairo', color: AppColors.success),
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.payments_outlined),
                  label: const Text(
                    'راتبي',
                    style: TextStyle(fontFamily: 'Cairo'),
                  ),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => EmployeeSalaryPage(
                        employeeId: employeeId,
                        employeeName: name,
                        organizationName: orgName,
                        readOnly: true,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: const Text(
                    'ديوني',
                    style: TextStyle(fontFamily: 'Cairo'),
                  ),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => EmployeeDebtsPage(
                        employeeId: employeeId,
                        employeeName: name,
                        organizationName: orgName,
                        readOnly: true,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => _enter(context),
            icon: const Icon(Icons.storefront_rounded),
            label: const Text(
              'الدخول إلى المتجر',
              style: TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          const SizedBox(height: 24),
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            icon: const Icon(Icons.link_off_rounded),
            label: const Text(
              'إلغاء الربط',
              style: TextStyle(fontFamily: 'Cairo'),
            ),
            onPressed: () async {
              if (await confirmEmployeeUnlink(
                context,
                ref,
                employeeId: employeeId,
                name: orgName,
                merchant: false,
              )) {
                ref.invalidate(
                  employeeInvitationProvider('${invitation['id']}'),
                );
                if (context.mounted) Navigator.maybePop(context);
              }
            },
          ),
        ],
      ),
    );
  }
}
