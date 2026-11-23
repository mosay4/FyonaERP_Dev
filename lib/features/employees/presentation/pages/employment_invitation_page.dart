import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../branches/data/branch_api.dart';
import '../../data/employee_api.dart';
import '../providers/employee_providers.dart';
import '../widgets/employee_avatar.dart';
import 'employer_workspace_page.dart';

class EmploymentInvitationPage extends ConsumerStatefulWidget {
  const EmploymentInvitationPage({super.key, required this.inviteId});
  final String inviteId;
  @override
  ConsumerState<EmploymentInvitationPage> createState() =>
      _EmploymentInvitationPageState();
}

class _EmploymentInvitationPageState
    extends ConsumerState<EmploymentInvitationPage> {
  bool _busy = false;

  Future<void> _respond(bool accept) async {
    setState(() => _busy = true);
    try {
      await ref.read(employeeApiProvider).respond(widget.inviteId, accept);
      ref.invalidate(myInvitationsProvider);
      ref.invalidate(branchAccessProvider);
      ref.invalidate(employeeInvitationProvider(widget.inviteId));
      if (!mounted) return;
      if (!accept) {
        Navigator.pop(context);
        return;
      }
      // Read the authoritative accepted relationship, never reuse pending data.
      await ref.read(employeeInvitationProvider(widget.inviteId).future);
    } catch (e) {
      if (mounted)
        showFyonaSnack(context, EmployeeApi.message(e), success: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final invitation = ref.watch(employeeInvitationProvider(widget.inviteId));
    return invitation.when(
      skipLoadingOnRefresh: false,
      loading: () => Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('التوظيف')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.link_off_rounded, size: 48),
                const SizedBox(height: 16),
                const Text(
                  'طلب التوظيف غير متاح أو تم إلغاء الربط',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: 'Cairo'),
                ),
                TextButton(
                  onPressed: () => Navigator.maybePop(context),
                  child: const Text('رجوع'),
                ),
              ],
            ),
          ),
        ),
      ),
      data: (inv) {
        if (inv['status'] == 'accepted')
          return EmployerWorkspacePage(invitation: inv);
        final org = inv['organization'] as Map? ?? const {};
        final merchant = inv['merchant'] as Map? ?? const {};
        final salary = num.tryParse('${inv['salary']}') ?? 0;
        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            title: const Text(
              'طلب الانضمام',
              style: TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const SizedBox(height: 20),
              Center(
                child: EmployeeAvatar(
                  photo: merchant['photo_url'] as String?,
                  size: 88,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '${merchant['name'] ?? org['name'] ?? ''}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if ('${merchant['phone'] ?? ''}'.trim().isNotEmpty)
                Text(
                  '${merchant['phone']}',
                  textAlign: TextAlign.center,
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppColors.textSecondary,
                  ),
                ),
              const SizedBox(height: 28),
              Card(
                color: AppColors.surface,
                elevation: 0,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      EmployeeAvatar(
                        photo: org['photo_url'] as String?,
                        size: 60,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '${org['name'] ?? ''}',
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'يدعوك هذا التاجر للانضمام إلى فريق متجره. يمكنك مراجعة بياناته ثم الموافقة أو الرفض.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontFamily: 'Cairo'),
                      ),
                      if (salary > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Text(
                            'راتبك المحدد: ${fmtNum(salary)} ${currencySymbol('${inv['salary_currency'] ?? 'SAR'}')}',
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy ? null : () => _respond(true),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.success,
                      ),
                      child: const Text(
                        'أوافق',
                        style: TextStyle(fontFamily: 'Cairo'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy ? null : () => _respond(false),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.danger,
                      ),
                      child: const Text(
                        'لا أوافق',
                        style: TextStyle(fontFamily: 'Cairo'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
