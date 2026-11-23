import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/branches/data/branch_api.dart';
import '../../features/branches/data/branch_scope.dart';
import '../../features/branches/data/branch_epoch.dart';
import '../../features/branches/data/branch_revocation.dart';
import '../../core/services/section_scope.dart';
import '../providers/current_user_provider.dart';
import '../../core/theme/app_colors.dart';

/// Blocks the merchant project, not the employee's unrelated personal account.
class MerchantWorkspaceGate extends ConsumerWidget {
  const MerchantWorkspaceGate({
    super.key,
    required this.route,
    required this.child,
  });
  final String route;
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (route.startsWith('/personal') ||
        route.startsWith('/subscription') ||
        route.startsWith('/job-requests'))
      return child;
    final user = ref.watch(currentUserProvider);
    final org = BranchScope.organizationId ?? user?.organizationId;
    final access = ref.watch(branchAccessProvider);
    final company = access.valueOrNull
        ?.where((c) => '${c['organization_id']}' == org)
        .firstOrNull;
    final scopeKey = BranchScope.token ?? '__own__';
    ref.listen(branchAccessProvider, (_, next) {
      if (next.isLoading || !next.hasValue) return;
      final current = next.valueOrNull
          ?.where((c) => '${c['organization_id']}' == org)
          .firstOrNull;
      if (current?['owner_expired'] == false)
        ref.read(merchantSubscriptionBlockedScopeProvider.notifier).state =
            null;
    });
    final blocked =
        company?['owner_expired'] == true ||
        ref.watch(merchantSubscriptionBlockedScopeProvider) == scopeKey;
    if (!blocked) return child;
    final employee = org != null && org != user?.organizationId;
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              Theme.of(context).brightness == Brightness.dark
                  ? 'assets/images/fyona_logo_light.png'
                  : 'assets/images/fyona_logo_dark.png',
              width: 100,
              height: 100,
            ),
            const SizedBox(height: 20),
            const Icon(
              Icons.workspace_premium_outlined,
              color: AppColors.primary,
              size: 44,
            ),
            const SizedBox(height: 12),
            Text(
              ar ? 'انتهى اشتراك المتجر' : 'The store subscription has expired',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              ar
                  ? 'انتهى اشتراك التاجر في FYONA ERP. يجب على مالك المتجر تجديد الاشتراك قبل متابعة العمل. حساباتك الأخرى غير متأثرة.'
                  : 'The merchant must renew their FYONA ERP subscription before this workspace can be used. Your other accounts are unaffected.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontFamily: 'Cairo', height: 1.7),
            ),
            const SizedBox(height: 22),
            FilledButton(
              onPressed: () async {
                if (!employee) {
                  context.go('/subscription');
                  return;
                }
                await BranchScope.clear();
                ref.read(activeSectionProvider.notifier).state =
                    AppSection.personal;
                ref
                        .read(merchantSubscriptionBlockedScopeProvider.notifier)
                        .state =
                    null;
                ref.read(branchEpochProvider.notifier).state++;
                if (context.mounted) context.go('/personal');
              },
              child: Text(
                ar
                    ? (employee ? 'حسناً، العودة لحسابي' : 'تجديد الاشتراك')
                    : (employee
                          ? 'Return to my account'
                          : 'Renew subscription'),
              ),
            ),
            TextButton(
              onPressed: () => ref.invalidate(branchAccessProvider),
              child: Text(ar ? 'التحقق من تجديد الاشتراك' : 'Check renewal'),
            ),
          ],
        ),
      ),
    );
  }
}
