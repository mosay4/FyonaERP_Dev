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
import '../../../business_banks/presentation/providers/business_banks_providers.dart'
    show localCashWarmupProvider;
import '../../../reports/data/business_report_rates.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

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
    ref.watch(localCashWarmupProvider);
    final balances = ref.watch(employeeCanProvider('banks.balances'));
    final local = ref.watch(localBusinessBankingProvider);
    final accountsAsync = balances ? ref.watch(businessAccountsProvider) : null;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return FyonaRefresh(
      onRefresh: () async {
        if (!context.mounted) return;
        if (balances) ref.invalidate(businessAccountsProvider);
        if (ref.read(employeeCanProvider('transactions'))) {
          ref.invalidate(businessRecentProvider);
        }
        // Only for the release motion; the data itself is local.
        if (!reducedMotion) {
          await Future<void>.delayed(const Duration(milliseconds: 420));
        }
      },
      child: CustomScrollView(
        clipBehavior: Clip.none,
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
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
                        if (local != null && !local.isCurrent) return;
                        if (!ref.read(employeeCanProvider('banks.details'))) {
                          return;
                        }
                        // The same bank screen as the Banks section, opened
                        // on this card's currency.
                        context.push(
                          '/banks/detail?bankName=${Uri.encodeComponent(account.bankName)}'
                          '&currency=${Uri.encodeComponent(account.currency)}',
                        );
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
      ),
    );
  }
}
