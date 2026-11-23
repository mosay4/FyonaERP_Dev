import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../auth/presentation/widgets/app_pin_sheet.dart';
import '../../../branches/data/branch_api.dart';
import '../../../branches/data/branch_revocation.dart';
import '../../../branches/data/branch_scope.dart';
import '../../data/employee_api.dart';
import '../providers/employee_providers.dart';

typedef EmployeeUnlinkVerifier =
    Future<bool> Function(BuildContext, WidgetRef, String);

/// Uses the app's existing hardware-biometric / offline app-PIN verification.
final employeeUnlinkVerifierProvider = Provider<EmployeeUnlinkVerifier>(
  (ref) =>
      (context, ref, reason) =>
          verifySensitiveAction(context, ref, reason: reason),
);
final employeeUnlinkBusyProvider = StateProvider.family<bool, String>(
  (ref, id) => false,
);

Future<bool> confirmEmployeeUnlink(
  BuildContext context,
  WidgetRef ref, {
  required String employeeId,
  required String name,
  required bool merchant,
}) async {
  if (ref.read(employeeUnlinkBusyProvider(employeeId))) return false;
  final container = ProviderScope.containerOf(context, listen: false);
  final ar = Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  container.read(employeeUnlinkBusyProvider(employeeId).notifier).state = true;
  try {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        icon: const Icon(
          Icons.link_off_rounded,
          color: AppColors.danger,
          size: 36,
        ),
        title: Text(
          t('إلغاء الربط', 'Unlink workspace'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          merchant
              ? t(
                  'تبغى تلغي ربط $name؟ بيوقف دخوله لكل فروعك. ملفه ورواتبه وديونه عندك تبقى محفوظة.',
                  'Unlink $name? Access to all your branches will stop. Their HR file and salary/debt records will be kept.',
                )
              : t(
                  'تبغى تلغي ارتباطك بـ $name؟ ما راح تقدر تدخل فروعه أو تديرها بعد الإلغاء.',
                  'Leave $name? You will no longer be able to enter or manage its branches.',
                ),
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('رجوع', 'Back')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('إلغاء الربط', 'Unlink')),
          ),
        ],
      ),
    );
    if (yes != true || !context.mounted) return false;
    final verified = await container.read(employeeUnlinkVerifierProvider)(
      context,
      ref,
      t(
        'أكد إلغاء الربط بالبصمة أو رمز التطبيق',
        'Verify unlinking with biometrics or your app PIN',
      ),
    );
    if (!verified || !context.mounted) return false;
    final result = await container.read(employeeApiProvider).unlink(employeeId);
    final activeToken = BranchScope.token;
    if (!merchant &&
        BranchScope.organizationId == '${result['organization_id']}') {
      if (await clearRevokedBranchScope(activeToken)) {
        container.read(branchRevocationProvider.notifier).state++;
      }
    }
    container.invalidate(employeesProvider);
    container.invalidate(myInvitationsProvider);
    container.invalidate(myEmployeeProfileProvider);
    container.invalidate(myEmployeeFinanceProvider);
    container.invalidate(branchAccessProvider);
    if (context.mounted)
      showFyonaSnack(
        context,
        t(
          'تم إلغاء الربط وإيقاف الدخول',
          'Unlinked. Workspace access has stopped.',
        ),
        success: true,
      );
    return true;
  } catch (e) {
    if (context.mounted)
      showFyonaSnack(context, EmployeeApi.message(e), success: false);
    return false;
  } finally {
    container.read(employeeUnlinkBusyProvider(employeeId).notifier).state =
        false;
  }
}
