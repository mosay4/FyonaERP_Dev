import 'package:flutter/material.dart';
import '../../../branches/data/branch_scope.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/services/currency/enabled_currencies_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../data/employee_api.dart';
import '../../data/employee_branch_context.dart';
import '../../../branches/data/branch_api.dart';
import '../../data/employee_permissions.dart';
import '../providers/employee_providers.dart';
import '../widgets/employee_avatar.dart';
import 'employee_salary_page.dart';
import 'employee_debts_page.dart';
import 'employee_link_page.dart';
import '../../../core_business/presentation/widgets/business_online_gate.dart';
import '../widgets/salary_receipt.dart';
import '../widgets/employee_unlink_action.dart';
import '../../../auth/presentation/widgets/app_pin_sheet.dart';

class EmployeeDetailPage extends ConsumerWidget {
  const EmployeeDetailPage({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(employeesProvider);
    final employee = async.valueOrNull
        ?.where((e) => '${e['id']}' == id)
        .firstOrNull;
    final unlinking = ref.watch(employeeUnlinkBusyProvider(id));
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        title: const FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            'ملف الموظف',
            maxLines: 1,
            style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w800),
          ),
        ),
        actions: BranchScope.readOnly ? [] : [
          IconButton(
            tooltip: 'حذف الموظف نهائياً',
            icon: const Icon(
              Icons.delete_forever_rounded,
              color: AppColors.danger,
            ),
            onPressed: employee == null
                ? null
                : () async {
                    final linked = employee['status'] == 'linked';
                    final yes = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text(
                          'حذف الموظف نهائياً',
                          style: TextStyle(fontFamily: 'Cairo'),
                        ),
                        content: Text(
                          linked
                              ? 'سيتم حذف هذا الموظف وبياناته نهائياً وإلغاء الربط بينك وبينه. لن تستطيع استعادة بياناته. هل أنت متأكد؟'
                              : 'سيتم حذف هذا الموظف وبياناته نهائياً ولن تستطيع استعادتها. هل أنت متأكد؟',
                          style: const TextStyle(fontFamily: 'Cairo'),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('إلغاء'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('حذف نهائي'),
                          ),
                        ],
                      ),
                    );
                    if (yes != true || !context.mounted) return;
                    if (!await verifySensitiveAction(
                      context,
                      ref,
                      reason: 'تأكيد حذف الموظف نهائياً',
                    ))
                      return;
                    try {
                      await ref.read(employeeApiProvider).remove(id);
                      ref.invalidate(employeesProvider);
                      if (context.mounted) context.pop();
                    } catch (e) {
                      if (context.mounted)
                        showFyonaSnack(
                          context,
                          EmployeeApi.message(e),
                          success: false,
                        );
                    }
                  },
          ),
          if (employee?['status'] == 'linked')
            TextButton.icon(
              onPressed: unlinking
                  ? null
                  : () => confirmEmployeeUnlink(
                      context,
                      ref,
                      employeeId: id,
                      name: '${employee?['full_name'] ?? ''}',
                      merchant: true,
                    ),
              style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              icon: const Icon(Icons.link_off_rounded, size: 18),
              label: Text(
                Localizations.localeOf(context).languageCode == 'ar'
                    ? 'إلغاء الربط'
                    : 'Unlink',
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 11),
              ),
            ),
          IconButton(
            icon: Icon(Icons.edit_rounded),
            onPressed: () async {
              await context.push('/employees/edit?id=$id');
              ref.invalidate(employeesProvider);
            },
          ),
        ],
      ),
      body: async.when(
        loading: () => const SizedBox.shrink(), // device read: no loading screen
        error: (e, _) => Center(
          child: Text(
            EmployeeApi.message(e),
            style: TextStyle(fontFamily: 'Cairo'),
          ),
        ),
        data: (list) {
          final e = list.where((x) => '${x['id']}' == id).firstOrNull;
          if (e == null) return const Center(child: Text('الموظف غير موجود'));
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF5B1020), Color(0xFF97203B)],
                  ),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(
                  children: [
                    EmployeeAvatar(
                      photo:
                          e['photo_url'] as String? ??
                          e['user_avatar'] as String?,
                      size: 86,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '${e['full_name']}',
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 20,
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if ('${e['phone'] ?? ''}'.isNotEmpty)
                      Text(
                        '${e['phone']}',
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 11.5,
                          color: Colors.white70,
                        ),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              fmtNum(num.tryParse('${e['salary'] ?? 0}') ?? 0),
                              style: const TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 16,
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 3),
                        Text(
                          currencyLabel('${e['salary_currency'] ?? 'SAR'}'),
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 8,
                            color: Colors.white70,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(30),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (e['status'] == 'linked')
                                Container(
                                  width: 7,
                                  height: 7,
                                  decoration: BoxDecoration(
                                    color: e['online'] == true
                                        ? const Color(0xFF7CFF9B)
                                        : const Color(0xFFFF8A8A),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              if (e['status'] == 'linked')
                                const SizedBox(width: 4),
                              Text(
                                e['status'] == 'linked'
                                    ? (e['online'] == true
                                          ? 'مربوط • متصل الآن'
                                          : 'مربوط • غير متصل')
                                    : 'مو مرتبط بحساب',
                                style: const TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 10,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (e['status'] != 'linked' && !BranchScope.readOnly) ...[
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: () async {
                              if (!await ensureBusinessOnline(context) ||
                                  !context.mounted) {
                                return;
                              }
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => EmployeeLinkPage(
                                    employeeId: id,
                                    employeeName: '${e['full_name'] ?? ''}',
                                  ),
                                ),
                              );
                              ref.invalidate(employeesProvider);
                            },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white70),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 2,
                              ),
                              minimumSize: const Size(0, 28),
                            ),
                            child: const Text(
                              'ربط الموظف',
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _action(
                      context,
                      ref,
                      e,
                      Icons.payments_rounded,
                      'الراتب',
                      _openSalary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _action(
                      context,
                      ref,
                      e,
                      Icons.handshake_rounded,
                      'الديون',
                      _openDebts,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _permissionsCard(context, e),
              const SizedBox(height: 14),
              _responsibleBranches(context, e),
              if ('${e['user_name'] ?? ''}'.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'الحساب المرتبط: ${e['user_name']} • ${e['user_code']}',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _action(
    BuildContext context,
    WidgetRef ref,
    Map e,
    IconData icon,
    String label,
    Future<void> Function(BuildContext, WidgetRef, Map) open,
  ) => Material(
    color: AppColors.surface,
    borderRadius: BorderRadius.circular(16),
    child: InkWell(
      onTap: () => open(context, ref, e),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            Icon(icon, color: AppColors.primary, size: 26),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _responsibleBranches(BuildContext context, Map e) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    final branches = (e['managed_branches'] as List? ?? const []).whereType<Map>();
    return Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(
      color: AppColors.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [const Icon(Icons.storefront_rounded, color: AppColors.primary, size: 20),
          const SizedBox(width: 8), Expanded(child: Text(ar ? 'الفروع المسؤول عليها الموظف' : 'Assigned branches',
            style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w800)))]),
        const SizedBox(height: 10),
        if (branches.isEmpty) Text(ar ? 'لا توجد فروع مرتبطة بهذا الموظف حالياً' : 'No branches are currently assigned.',
          style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary, fontSize: 11)),
        for (final branch in branches) Padding(padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [const Icon(Icons.check_circle_outline_rounded, color: AppColors.success, size: 17),
            const SizedBox(width: 8), Expanded(child: Text('${branch['name'] ?? ''}',
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 12)))])),
        if (branches.isNotEmpty && e['status'] != 'linked') Text(ar ? 'تُفعّل بعد موافقة الموظف على الربط' : 'Access starts after accepting the invitation.',
          style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary, fontSize: 10)),
      ]));
  }

  Widget _permissionsCard(BuildContext context, Map e) {
    final perms = (e['permissions'] as Map?) ?? const {};
    final arabic = Localizations.localeOf(context).languageCode == 'ar';
    final enabled = employeePermissionGroups.keys
        .where((k) => perms[k] == true)
        .toList();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            arabic ? 'إيش يقدر يسوي الموظف؟' : 'What can the employee do?',
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            arabic
                ? 'هذي الأقسام المفتوحة له. الباقي مقفول وما يشوفه.'
                : 'These sections are available. Other sections are hidden.',
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 10,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          if (enabled.isEmpty)
            Text(
              arabic ? 'ما عنده أي صلاحية حالياً' : 'No permissions currently',
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 11,
                color: AppColors.textSecondary,
              ),
            )
          else
            for (final k in enabled)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(16),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: const Icon(
                        Icons.check_rounded,
                        size: 17,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            employeeGroupLabel(k, arabic: arabic),
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Wrap(
                            spacing: 4,
                            runSpacing: 3,
                            children: [
                              for (final c
                                  in (employeePermissionGroups[k] ??
                                          const <String>[])
                                      .where((c) => perms['$k.$c'] == true))
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.background,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    employeeChildLabel(c, arabic: arabic),
                                    style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 9,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Future<EmployeeBranchContext> _financeBranch(WidgetRef ref, Map e) async {
    final cached = ref.read(branchAccessProvider).valueOrNull;
    final branch = EmployeeBranchContext.resolve(e, cached ?? const []);
    if (cached != null || (branch.id != null && branch.name != null)) {
      return branch;
    }
    try {
      final companies = await ref.read(branchAccessProvider.future);
      return EmployeeBranchContext.resolve(e, companies);
    } catch (_) {
      // History remains accessible even when branch access cannot be loaded.
      return branch;
    }
  }

  Future<void> _openSalary(BuildContext context, WidgetRef ref, Map e) async {
    final branch = await _financeBranch(ref, e);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EmployeeSalaryPage(
          employeeId: '${e['id']}',
          employeeName: '${e['full_name'] ?? ''}',
          photo: e['photo_url'] as String?,
          branchId: branch.id,
          branchName: branch.name,
        ),
      ),
    );
  }

  Future<void> _payDialog(BuildContext context, WidgetRef ref, Map e) async {
    final amount = TextEditingController();
    final notes = TextEditingController();
    String currency = '${e['salary_currency'] ?? 'SAR'}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('صرف راتب', style: TextStyle(fontFamily: 'Cairo')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: amount,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'المبلغ'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: notes,
                decoration: const InputDecoration(labelText: 'ملاحظات'),
              ),
              const SizedBox(height: 8),
              Text(
                currencyLabel(currency),
                style: TextStyle(fontFamily: 'Cairo'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('إلغاء', style: TextStyle(fontFamily: 'Cairo')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('صرف', style: TextStyle(fontFamily: 'Cairo')),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await ref.read(employeeApiProvider).paySalary('${e['id']}', {
          'amount': num.tryParse(amount.text.replaceAll(',', '')) ?? 0,
          'currency': currency,
          'notes': notes.text.trim().isEmpty ? null : notes.text.trim(),
        });
        if (context.mounted)
          showFyonaSnack(context, 'تم صرف الراتب', success: true);
      } catch (err) {
        if (context.mounted)
          showFyonaSnack(context, EmployeeApi.message(err), success: false);
      }
    }
    amount.dispose();
    notes.dispose();
  }

  Future<void> _openDebts(BuildContext context, WidgetRef ref, Map e) async {
    final branch = await _financeBranch(ref, e);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EmployeeDebtsPage(
          employeeId: '${e['id']}',
          employeeName: '${e['full_name'] ?? ''}',
          branchId: branch.id,
          branchName: branch.name,
        ),
      ),
    );
  }

  Future<void> _debtDialog(BuildContext context, WidgetRef ref, Map e) async {
    final amount = TextEditingController();
    String direction = 'employee_owes';
    String kind = 'charge';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('تسجيل دين', style: TextStyle(fontFamily: 'Cairo')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: direction,
                items: const [
                  DropdownMenuItem(
                    value: 'employee_owes',
                    child: Text('على الموظف'),
                  ),
                  DropdownMenuItem(
                    value: 'employer_owes',
                    child: Text('للموظف'),
                  ),
                ],
                onChanged: (v) => set(() => direction = v!),
              ),
              DropdownButtonFormField<String>(
                value: kind,
                items: const [
                  DropdownMenuItem(value: 'charge', child: Text('دين جديد')),
                  DropdownMenuItem(value: 'settlement', child: Text('سداد')),
                ],
                onChanged: (v) => set(() => kind = v!),
              ),
              TextField(
                controller: amount,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'المبلغ'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('إلغاء', style: TextStyle(fontFamily: 'Cairo')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('حفظ', style: TextStyle(fontFamily: 'Cairo')),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await ref.read(employeeApiProvider).addDebt('${e['id']}', {
          'direction': direction,
          'kind': kind,
          'amount': num.tryParse(amount.text.replaceAll(',', '')) ?? 0,
          'currency': '${e['salary_currency'] ?? 'SAR'}',
        });
        if (context.mounted)
          showFyonaSnack(context, 'تم تسجيل العملية', success: true);
      } catch (err) {
        if (context.mounted)
          showFyonaSnack(context, EmployeeApi.message(err), success: false);
      }
    }
    amount.dispose();
  }
}
