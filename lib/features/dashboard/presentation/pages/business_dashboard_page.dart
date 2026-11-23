import 'package:flutter/cupertino.dart' show CupertinoSliverRefreshControl;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'widgets/business_recent_ops.dart';
// Same widgets as the personal home (read-only import — the personal section
// itself is untouched): identical sizes, spacing, and behavior by construction.
import '../../../personal/presentation/pages/widgets/home_account_card.dart';
import '../../../personal/presentation/pages/widgets/home_promo_banner.dart';
import '../providers/business_dashboard_providers.dart';
import 'widgets/business_services_grid.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../business_banks/presentation/providers/local_business_banking.dart';
import '../../../reports/data/business_report_rates.dart';

/// Business section home: bank cards + promo banners, mirroring the personal
/// home layout exactly (same widgets, same sizes) minus the net-worth card.
///
/// Business-only refresh gesture. A small reserved extent makes the cards
/// settle gently; the existing cards stay mounted and no spinner is drawn.
///
/// Tapping a bank card opens that account's detail — same destination pattern
/// as the personal home (account detail, not the bank group page).
class BusinessDashboardPage extends ConsumerWidget {
  const BusinessDashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(businessReportRateWarmupProvider);
    final balances = ref.watch(employeeCanProvider('banks.balances'));
    final local = ref.watch(localBusinessBankingProvider);
    final accountsAsync = balances ? ref.watch(businessAccountsProvider) : null;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return CustomScrollView(
      clipBehavior: Clip.none,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        CupertinoSliverRefreshControl(
          refreshIndicatorExtent: reducedMotion ? 0 : 32,
          builder: (_, __, ___, ____, _____) => const SizedBox.shrink(),
          onRefresh: () async {
            if (!context.mounted) return;
            if (balances) ref.invalidate(businessAccountsProvider);
            if (ref.read(employeeCanProvider('transactions'))) {
              ref.invalidate(businessRecentProvider);
            }
            // This is only for the release animation, not a delay in saving
            // and not tied to HTTP or even a slow local read.
            if (!reducedMotion) {
              await Future<void>.delayed(const Duration(milliseconds: 240));
            }
          },
        ),
        SliverToBoxAdapter(
          child: Column(
            children: [
              const SizedBox(height: 16),
              if (accountsAsync != null)
                accountsAsync.when(
                  skipLoadingOnRefresh: true,
                  skipLoadingOnReload: false,
                  data: (accounts) => HomeAccountCard(
                    accounts: accounts,
                    distinctAccountTypes: true,
                    onAccountTap: (account) {
                      // Riverpod may keep previous data while refreshing. A
                      // stale card must not turn into a URL for the next scope.
                      if (accountsAsync.isLoading ||
                          !identical(
                            local,
                            ref.read(localBusinessBankingProvider),
                          ))
                        return;
                      if (local == null) {
                        context.push('/banks/account/${account.id}');
                      } else if (local.isCurrent) {
                        context.push(
                          LocalBankAccountTarget.path,
                          extra: LocalBankAccountTarget(
                            local.scope,
                            account.id,
                          ),
                        );
                      }
                    },
                  ),
                  loading: () => const HomeAccountCard(accounts: []),
                  error: (_, _) => const HomeAccountCard(accounts: []),
                ),
              if (accountsAsync != null) const SizedBox(height: 12),
              const HomePromoBanners(),
              const SizedBox(height: 20),
              const BusinessServicesGrid(),
              const SizedBox(height: 20),
              if (ref.watch(employeeCanProvider('transactions')))
                const BusinessRecentOps(),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ],
    );
  }
}
