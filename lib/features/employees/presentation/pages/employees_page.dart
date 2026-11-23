import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../data/employee_api.dart';
import '../providers/employee_providers.dart';

import '../widgets/employee_avatar.dart';
import 'employee_link_page.dart';
import '../../../core_business/presentation/widgets/business_online_gate.dart';
import '../../../branches/data/branch_scope.dart';

class EmployeesPage extends ConsumerStatefulWidget {
  const EmployeesPage({super.key});
  @override
  ConsumerState<EmployeesPage> createState() => _EmployeesPageState();
}

class _EmployeesPageState extends ConsumerState<EmployeesPage> {
  Timer? _presence;
  @override
  void initState() {
    super.initState();
    _presence = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) ref.invalidate(employeesProvider);
    });
  }

  @override
  void dispose() {
    _presence?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {

    final async = ref.watch(employeesProvider);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          'الموظفون',
          style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w800),
        ),
        backgroundColor: AppColors.background,
        actions: BranchScope.readOnly
            ? []
            : [
                IconButton(
                  tooltip: 'إضافة موظف',
                  icon: const Icon(Icons.person_add_alt_1_rounded),
                  onPressed: () async {
                    if (!await ensureBusinessOnline(context) ||
                        !context.mounted) {
                      return;
                    }
                    await context.push('/employees/add');
                    ref.invalidate(employeesProvider);
                  },
                ),
              ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Text(
            EmployeeApi.message(e),
            textAlign: TextAlign.center,
            style: const TextStyle(fontFamily: 'Cairo'),
          ),
        ),
        data: (employees) {
          if (employees.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 82,
                      height: 82,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(14),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.groups_2_outlined,
                        size: 40,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'لا يوجد موظفون في هذا الفرع',
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'أضف أول موظف لبدء إدارة الفريق والصلاحيات والرواتب.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 13,
                        height: 1.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 18),
                    if (!BranchScope.readOnly)
                      FilledButton.icon(
                        onPressed: () async {
                          if (!await ensureBusinessOnline(context) ||
                              !context.mounted) {
                            return;
                          }
                          await context.push('/employees/add');
                          ref.invalidate(employeesProvider);
                        },
                        icon: const Icon(Icons.add_rounded),
                        label: const Text(
                          'إضافة موظف',
                          style: TextStyle(fontFamily: 'Cairo'),
                        ),
                      ),
                  ],
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(employeesProvider),
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: employees.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                final e = employees[i];
                final linked = e['status'] == 'linked';
                final online = e['online'] == true;

                final salary = num.tryParse('${e['salary'] ?? 0}') ?? 0;
                final phone = '${e['phone'] ?? ''}';
                return Material(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () async {
                      if (!await ensureBusinessOnline(context) ||
                          !context.mounted) {
                        return;
                      }
                      await context.push('/employees/detail?id=${e['id']}');
                      ref.invalidate(employeesProvider);
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          EmployeeAvatar(
                            photo:
                                e['photo_url'] as String? ??
                                e['user_avatar'] as String?,
                            size: 58,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '${e['full_name'] ?? ''}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontFamily: 'Cairo',
                                          fontSize: 15,
                                          fontWeight: FontWeight.w800,
                                          color: AppColors.textPrimary,
                                        ),
                                      ),
                                    ),
                                    if (linked)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color:
                                              (online
                                                      ? AppColors.success
                                                      : AppColors.danger)
                                                  .withAlpha(18),
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Container(
                                              width: 6,
                                              height: 6,
                                              decoration: BoxDecoration(
                                                color: online
                                                    ? AppColors.success
                                                    : AppColors.danger,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              online ? 'متصل الآن' : 'غير متصل',
                                              style: TextStyle(
                                                fontFamily: 'Cairo',
                                                fontSize: 8.5,
                                                fontWeight: FontWeight.w700,
                                                color: online
                                                    ? AppColors.success
                                                    : AppColors.danger,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                                if (phone.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.phone_rounded,
                                        size: 12,
                                        color: AppColors.textSecondary,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        phone,
                                        textDirection: TextDirection.ltr,
                                        style: TextStyle(
                                          fontFamily: 'Cairo',
                                          fontSize: 10.5,
                                          color: AppColors.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                                if (salary > 0) ...[
                                  const SizedBox(height: 5),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.baseline,
                                    textBaseline: TextBaseline.alphabetic,
                                    children: [
                                      Flexible(
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            fmtNum(salary),
                                            style: const TextStyle(
                                              fontFamily: 'Cairo',
                                              fontSize: 15,
                                              fontWeight: FontWeight.w800,
                                              color: AppColors.primary,
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 3),
                                      Text(
                                        currencyLabel(
                                          '${e['salary_currency'] ?? 'SAR'}',
                                          locale: Localizations.localeOf(
                                            context,
                                          ).languageCode,
                                        ),
                                        style: TextStyle(
                                          fontFamily: 'Cairo',
                                          fontSize: 8,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                                const SizedBox(height: 6),
                                if (linked)
                                  const Row(
                                    children: [
                                      Icon(
                                        Icons.verified_rounded,
                                        size: 13,
                                        color: AppColors.success,
                                      ),
                                      SizedBox(width: 4),
                                      Text(
                                        'مربوط بالمتجر',
                                        style: TextStyle(
                                          fontFamily: 'Cairo',
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.success,
                                        ),
                                      ),
                                    ],
                                  )
                                else if (!BranchScope.readOnly)
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: OutlinedButton.icon(
                                      onPressed: () async {
                                        if (!await ensureBusinessOnline(
                                              context,
                                            ) ||
                                            !context.mounted) {
                                          return;
                                        }
                                        await Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) => EmployeeLinkPage(
                                              employeeId: '${e['id']}',
                                              employeeName:
                                                  '${e['full_name'] ?? ''}',
                                            ),
                                          ),
                                        );
                                        ref.invalidate(employeesProvider);
                                      },
                                      icon: const Icon(
                                        Icons.link_rounded,
                                        size: 14,
                                      ),
                                      label: const Text(
                                        'ربط الموظف',
                                        style: TextStyle(
                                          fontFamily: 'Cairo',
                                          fontSize: 10,
                                        ),
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: AppColors.primary,
                                        side: const BorderSide(
                                          color: AppColors.primary,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 4,
                                        ),
                                        minimumSize: const Size(0, 28),
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_left_rounded,
                            color: AppColors.textSecondary,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

}
