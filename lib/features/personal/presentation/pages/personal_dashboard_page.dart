import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import '../providers/receipt_design_provider.dart';
import '../providers/receipt_design_models.dart';
import 'widgets/home_account_card.dart';
import 'widgets/home_promo_banner.dart';
import 'widgets/home_services_grid.dart';
import 'widgets/net_worth_frame.dart';
import '../../../../shared/widgets/money_text.dart';
import '../../../../shared/widgets/subscription_gate.dart';
import '../../../../shared/widgets/app_icon_badge.dart';
import '../../../../features/auth/presentation/providers/auth_provider.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/currency_selector.dart';
import '../../../../shared/widgets/receipt/receipt_modal.dart';
import '../../../../shared/widgets/receipt/receipt_data.dart';
import '../../../../core/help/information_clicker.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';
import '../../domain/services/personal_country_cash.dart';
import '../../di/personal_providers.dart' show personalFinanceServiceProvider;
import '../../../../shared/providers/current_user_provider.dart';
import '../../../../core/utils/time_format.dart';

class PersonalDashboardPage extends ConsumerStatefulWidget {
  const PersonalDashboardPage({super.key});

  @override
  ConsumerState<PersonalDashboardPage> createState() =>
      _PersonalDashboardPageState();
}

class _PersonalDashboardPageState extends ConsumerState<PersonalDashboardPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _animCtrl;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;
  bool _refreshing = false;
  bool _prevLoading = true;
  bool _showNetWorth = true;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.03),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic));
    _prevLoading = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(personalFinanceProvider.notifier).load();
      _seedCountryCash();
      ref.read(budgetProvider.notifier).load();
      ref.read(recurringProvider.notifier).load();
      // NOTE (navigation-safety): the subscription snapshot is NOT
      // invalidated on every open — it is fetched once per app run and the
      // gate reads the cached value, so opening the dashboard never waits
      // for a subscription network round-trip. Fresh activations are picked
      // up by the subscription screens' own refresh paths.
      try {
        Future.microtask(() async {
          try {
            await ref.read(authProvider.notifier).refreshProfile();
          } catch (_) {}
        });
      } catch (_) {}
    });
  }

  /// Once per session: the cash currencies of the account's country (from
  /// its phone), for accounts that never passed the old phone screen.
  static final Set<String> _seededUsers = {};
  Future<void> _seedCountryCash() async {
    try {
      final user = ref.read(currentUserProvider);
      final uid = ref.read(currentUserIdProvider).trim();
      if (user == null || uid.isEmpty || !_seededUsers.add(uid)) return;
      await seedPersonalCountryCash(
        userId: uid,
        phone: user.phone,
        ensure: (currencies, enabled) async {
          await ref
              .read(personalFinanceServiceProvider)
              .ensureCashAccounts(currencies, enabled: enabled);
          if (mounted) await ref.read(personalFinanceProvider.notifier).load();
        },
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  Future<void> _onRefresh() async {
    if (!mounted) return;
    setState(() => _refreshing = true);
    await ref.read(personalFinanceProvider.notifier).load();
    await ref.read(budgetProvider.notifier).load();
    await ref.read(recurringProvider.notifier).load();
    if (!mounted) return;
    setState(() => _refreshing = false);
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(personalFinanceProvider);
    final notifier = ref.read(personalFinanceProvider.notifier);
    final budgetSt = ref.watch(budgetProvider);
    final recSt = ref.watch(recurringProvider);
    final l10n = AppLocalizations.of(context);

    final isLoading = st.isLoading && !_refreshing;

    if (_prevLoading && !isLoading) {
      _prevLoading = false;
      if (_animCtrl.status != AnimationStatus.completed) {
        _animCtrl.forward();
      }
    }
    if (isLoading) {
      _prevLoading = true;
    }

    final accounts = st.bankAccounts;
    final txs = st.transactions;
    final activeGoals = st.savingsGoals.where((g) => g.progress < 1.0).toList();

    if (isLoading && !_refreshing) {
      return const _SkeletonLoader();
    }

    if (st.error != null && accounts.isEmpty && txs.isEmpty) {
      final isOffline = st.isOfflineError;
      // Offline with no cached data: show the normal dashboard with empty
      // sections + a compact offline banner, instead of a full-screen error
      // that blocks the user from creating their first account offline.
      if (isOffline) {
        return FadeTransition(
          opacity: _fadeAnim,
          child: SlideTransition(
            position: _slideAnim,
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withAlpha(18),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.warning.withAlpha(60)),
                  ),
                  child: Row(children: [
                    Icon(Icons.wifi_off_rounded, size: 20, color: AppColors.warning),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        l10n.translate('offlineNoDataHint'),
                        style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textSecondary),
                      ),
                    ),
                  ]),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: Column(
                      children: [
                        const SizedBox(height: 24),
                        Icon(Icons.account_balance_wallet_outlined, size: 64, color: AppColors.textTertiary),
                        const SizedBox(height: 16),
                        Text(l10n.translate('noAccountsYet'), style: TextStyle(fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                        const SizedBox(height: 8),
                        Text(l10n.translate('createFirstAccountHint'), textAlign: TextAlign.center, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppColors.textTertiary)),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          onPressed: () => ref.read(personalFinanceProvider.notifier).load(),
                          icon: const Icon(Icons.refresh_rounded, size: 20),
                          label: Text(l10n.translate('retry'), style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w600)),
                          style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }
      return SingleChildScrollView(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline_rounded, color: AppColors.danger, size: 56),
                const SizedBox(height: 16),
                Text(l10n.translate('errorOccurred'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 18), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                const SizedBox(height: 8),
                Text(_shortError(st.error!), textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textTertiary)),
                const SizedBox(height: 24),
                SizedBox(
                  height: 44,
                  child: ElevatedButton.icon(
                    onPressed: () => ref.read(personalFinanceProvider.notifier).load(),
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    label: Text(l10n.translate('retry'), style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w600)),
                    style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return FadeTransition(
      opacity: _fadeAnim,
      child: SlideTransition(
        position: _slideAnim,
        child: SubscriptionGate(
          child: Column(
            children: [
              Expanded(
                child: FyonaRefresh(
                  onRefresh: _onRefresh,
                  color: AppColors.primary,
                  backgroundColor: AppColors.surface,
                  child: SingleChildScrollView(
                    clipBehavior: Clip.none,
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    child: Column(
                      children: [
                        const SizedBox(height: 16),
                        HomeAccountCard(
                          accounts: accounts,
                          // The same bank screen as the Banks section,
                          // opened on this card's currency.
                          onAccountTap: (account) => context.push(
                            '${RouteNames.personalBankDetail.replaceFirst(':bankName', Uri.encodeComponent(account.bankName))}'
                            '?currency=${Uri.encodeComponent(account.currency)}',
                          ),
                        ),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          // The collapse arrow is pinned at the card's
                          // top-left corner and never moves between states.
                          child: NetWorthFrame(
                            expanded: _showNetWorth,
                            onToggle: () => setState(() => _showNetWorth = !_showNetWorth),
                            expandedChild: _NetWorthCard(
                              key: const ValueKey('netWorthCard'),
                              netWorth: st.netWorth,
                              payable: notifier.totalPayable,
                              receivable: notifier.totalReceivable,
                              currency: st.walletCurrency,
                            ),
                            collapsedChild: const _CollapsedNetWorthPill(
                              key: ValueKey('netWorthPill'),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const HomePromoBanners(),
                        const SizedBox(height: 20),
                        HomeServicesGrid(),
                        const SizedBox(height: 24),
                        if (txs.isNotEmpty)
                          _RecentTransactions(
                            transactions: _newestThree(txs),
                          ),
                        const SizedBox(height: 20),
                        if (activeGoals.isNotEmpty)
                          _SavingsGoals(goals: activeGoals.take(3).toList()),
                        const SizedBox(height: 20),
                        if (budgetSt.budgets.isNotEmpty)
                          _BudgetSection(budgets: budgetSt.budgets),
                        if (budgetSt.budgets.isNotEmpty) const SizedBox(height: 20),
                        if (recSt.activeCount > 0)
                          _RecurringSummary(activeCount: recSt.activeCount),
                        if (recSt.activeCount > 0) const SizedBox(height: 20),
                        const SizedBox(height: 100),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}



// ── Net Worth Card ──
class _NetWorthCard extends ConsumerWidget {
  final double netWorth;
  final double payable;
  final double receivable;
  final String currency;

  const _NetWorthCard({
    super.key,
    required this.netWorth,
    required this.payable,
    required this.receivable,
    required this.currency,
  });

  void _showCurrencyPicker(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(sheetCtx).viewInsets.bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppLocalizations.of(sheetCtx).translate('currencyLabel'),
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(sheetCtx, 15), fontWeight: FontWeight.w700, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 12),
            CurrencySelector(
              label: AppLocalizations.of(sheetCtx).translate('currencyLabel'),
              value: currency,
              showCode: false,
              onChanged: (v) {
                ref.read(personalFinanceProvider.notifier).setWalletCurrency(v);
                Navigator.pop(sheetCtx);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sym = currencySymbol(currency);
    final positive = netWorth >= 0;
    final l10n = AppLocalizations.of(context);

    // Same width as the folded pill (no own margin): the pinned arrow sits
    // inside the card in both states.
    return Container(
      padding: const EdgeInsets.fromLTRB(16, kNetWorthCardTopPadding, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(children: [
        // The physical-left gutter stays free for the pinned collapse arrow
        // (see [NetWorthFrame]); the title reflows instead of being cut.
        Padding(
          padding: const EdgeInsets.only(left: kNetWorthArrowGutter - 16),
          child: Row(children: [
          AppIconBadge(
            icon: TwoToneIcons.netWorth.outline,
            size: 36,
            iconSize: 18,
            backgroundColor: AppColors.primary.withAlpha(20),
            borderColor: AppColors.primary.withAlpha(40),
            accentColor: AppColors.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(l10n.translate('personalNetWorth'), maxLines: 1, softWrap: false, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(l10n.translate('personalYourCapital'), maxLines: 1, softWrap: false, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.textTertiary)),
                ),
              ],
            ),
          ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => _showCurrencyPicker(context, ref),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(16),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.primary.withAlpha(60)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(currency, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), fontWeight: FontWeight.w700, color: AppColors.primary)),
                  const SizedBox(width: 2),
                  Icon(Icons.expand_more, size: 12, color: AppColors.primary),
                ]),
              ),
            ),
          ]),
        ),
          const SizedBox(height: 12),
          MoneyText(
            amount: fmtNum(netWorth),
            currency: sym,
            alignment: Alignment.center,
            currencyScale: .54,
            currencyStyle: TextStyle(color: AppColors.textSecondary),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 26),
              fontWeight: FontWeight.w800,
              color: positive ? AppColors.success : AppColors.danger,
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _NetWorthStat(label: l10n.translate('personalOwedToYou'), value: '${fmtNum(payable)} $sym', color: AppColors.danger, icon: TwoToneIcons.arrowUp)),
            const SizedBox(width: 8),
            Expanded(child: _NetWorthStat(label: l10n.translate('personalOwedByYou'), value: '${fmtNum(receivable)} $sym', color: AppColors.success, icon: TwoToneIcons.arrowDown)),
          ]),
        ]),
    );
  }
}

class _CollapsedNetWorthPill extends StatelessWidget {
  const _CollapsedNetWorthPill({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Same height as the pinned arrow + its insets, with the physical-left
    // gutter kept free so the arrow sits exactly where it does on the card.
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(
          minHeight: kNetWorthArrowSize + 2 * kNetWorthArrowInset),
      alignment: AlignmentDirectional.centerStart,
      padding: const EdgeInsets.only(
          left: kNetWorthArrowGutter, right: 14, top: 6, bottom: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerStart,
        child: Text(
          l10n.translate('personalNetWorth'),
          maxLines: 1,
          softWrap: false,
          style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: AppColors.textPrimary),
        ),
      ),
    );
  }
}

class _NetWorthStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final TwoToneIconData icon;
  const _NetWorthStat({required this.label, required this.value, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          TwoToneIcon(data: icon, size: 11, outlineColor: color, detailColor: color),
          const SizedBox(width: 3),
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 9), color: AppColors.textSecondary))),
        ]),
        const SizedBox(height: 3),
        MoneyText.parse(value, alignment: Alignment.center, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
      ]),
    );
  }
}

// ── Recent Transactions ──
/// Newest-3 across ALL accounts for the home "recent" section. Sorts a copy
/// defensively by EXECUTION time (created_at fingerprint, fractions of a
/// second): the last operation that ran is always on top, whether rows came
/// from the server, the offline mirror, or a merge of both.
List<PersonalTransaction> _newestThree(List<PersonalTransaction> all) {
  final sorted = List<PersonalTransaction>.of(all);
  sortTransactionsNewestExecutedFirst(sorted);
  return sorted.take(3).toList();
}

class _RecentTransactions extends StatelessWidget {
  final List<PersonalTransaction> transactions;
  _RecentTransactions({required this.transactions});
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          Row(
            children: [
               Text(
                l10n.translate('personalRecentTransactions'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 16),
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
               Spacer(),
              GestureDetector(
                onTap: () => context.push(RouteNames.personalTransactions),
                child: Text(
                  l10n.translate('viewAll'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          ...transactions.map((t) => _TransactionTile(tx: t)),
        ],
      ),
    );
  }
}

class _TransactionTile extends ConsumerWidget {
  final PersonalTransaction tx;

  _TransactionTile({required this.tx});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isIncome = tx.type == 'income';
    final color = isIncome ? AppColors.success : AppColors.danger;
    final iconData = isIncome
        ? TwoToneIcons.arrowDown
        : TwoToneIcons.arrowUp;
    final amtNum = '${isIncome ? '+' : '-'}${fmtNum(tx.amount)}';
    final amtCur = currencySymbol(tx.currency);
    final date = tx.date != null ? DateFormat('yyyy-MM-dd').format(tx.date!) : '';

    return ClickerQuiet(
      // Transaction rows stay silent under the Information Clicker: no
      // progress border, no explanation card. Long-press (like tap) opens
      // the native receipt/delete sheet only.
      child: GestureDetector(
        onTap: () => _showOptions(context, ref, tx),
        onLongPress: () => _showOptions(context, ref, tx),
        child: Container(
      margin: EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(
          bottom: BorderSide(color: AppColors.divider, width: 1),
        ),
      ),
      child: Row(
        children: [
          TwoToneIcon(
            data: iconData,
            detailColor: AppColors.primary,
            outlineColor: AppColors.textSecondary,
            size: 22,
          ),
           SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tx.category,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 14),
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (tx.description != null && tx.description!.isNotEmpty)
                  Text(
                    tx.description!,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 11),
                      fontWeight: FontWeight.w400,
                      color: AppColors.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text.rich(
                TextSpan(
                  text: amtNum,
                  children: [
                    if (amtCur.isNotEmpty)
                      TextSpan(
                        text: '  $amtCur',
                        style: TextStyle(
                          fontSize: R.fontSize(context, 9),
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary,
                        ),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 14),
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              Text(
                date,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 10),
                  fontWeight: FontWeight.w400,
                  color: AppColors.textDisabled,
                ),
              ),
            ],
          ),
        ],
      ),
    ),
      ),
    );
  }

  static void _showOptions(BuildContext context, WidgetRef ref, PersonalTransaction t) {
    final l10n = AppLocalizations.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.receipt_long, color: AppColors.primary),
              title: Text(l10n.translate('txViewReceipt'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(ctx, 14), fontWeight: FontWeight.w600)),
              onTap: () { Navigator.pop(ctx); _showReceipt(context, ref, t); },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: AppColors.danger),
              title: Text(l10n.translate('delete'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(ctx, 14), fontWeight: FontWeight.w600, color: AppColors.danger)),
              onTap: () async {
                Navigator.pop(ctx);
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (dCtx) => AlertDialog(
                    backgroundColor: AppColors.surface,
                    title: Text(l10n.translate('txConfirmDeleteTitle'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.bold)),
                    content: Text(l10n.translate('txConfirmDeleteTx'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13))),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(dCtx, false), child: Text(l10n.translate('cancel'), style: TextStyle(fontFamily: 'Cairo'))),
                      TextButton(onPressed: () => Navigator.pop(dCtx, true), child: Text(l10n.translate('delete'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.danger))),
                    ],
                  ),
                );
                if (confirmed == true) {
                  final ok = await ref.read(personalFinanceProvider.notifier).deleteTransaction(t.id);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(
                            ok ? l10n.translate('txDeleted') : l10n.translate('personalErrDeleteTx'),
                            style: TextStyle(fontFamily: 'Cairo')),
                        backgroundColor: ok ? AppColors.success : AppColors.danger));
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  static void _showReceipt(
      BuildContext context, WidgetRef ref, PersonalTransaction t) {
    final isIncome = t.type == 'income';
    final l10n = AppLocalizations.of(context);
    // Every receipt renders its own section's customization no matter which
    // list opened it: debt/goal/budget/transfer operations show their
    // section design even from home recent; plain rows use income_expense.
    final preset = ref
        .read(personalReceiptDesignProvider.notifier)
        .getPreset(receiptSectionForTransaction(
          debtId: t.debtId,
          goalId: t.goalId,
          budgetId: t.budgetId,
          txType: t.type,
          category: t.category,
        ));
    ReceiptModal.show(
      context,
      ReceiptData(
        title: isIncome ? l10n.translate('deposit') : l10n.translate('withdrawal'),
        amount: t.amount,
        currencySymbol: currencySymbol(t.currency),
        dateTime: t.date != null ? formatDateTimeDisplay(t.date!) : '-',
        referenceNumber: '#TX-${t.id}',
        senderName: isIncome ? (t.description ?? '-') : null,
        receiverName: !isIncome ? (t.description ?? '-') : null,
        details: [
          ReceiptDetail(label: l10n.translate('txDetailCategory'), value: t.category),
          ReceiptDetail(label: l10n.translate('txDetailType'), value: isIncome ? l10n.translate('deposit') : l10n.translate('withdrawal')),
          if (t.description != null && t.description!.isNotEmpty)
            ReceiptDetail(label: l10n.translate('description'), value: t.description!),
        ],
      ),
      preset: preset,
    );
  }
}

// ── Savings Goals ──
class _SavingsGoals extends StatelessWidget {
  final List<SavingsGoal> goals;

  _SavingsGoals({required this.goals});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
               Text(
                l10n.translate('personalSavingsGoals'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 16),
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
               Spacer(),
              GestureDetector(
                onTap: () => context.push(RouteNames.personalSavings),
                child: Text(
                  l10n.translate('viewAll'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          ...goals.map((g) => _GoalCard(goal: g)),
        ],
      ),
    );
  }
}

class _GoalCard extends StatelessWidget {
  final SavingsGoal goal;

  _GoalCard({required this.goal});

  @override
  Widget build(BuildContext context) {
    final progress = goal.targetAmount > 0
        ? (goal.currentAmount / goal.targetAmount).clamp(0.0, 1.0)
        : 0.0;
    final percent = (progress * 100).toInt();

    return Container(
      margin: EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            children: [
              TwoToneIcon(
                data: TwoToneIcons.savingsGoal,
                detailColor: AppColors.primary,
                outlineColor: AppColors.textSecondary,
                size: 22,
              ),
               SizedBox(width: 10),
              Expanded(
                child: Text(
                  goal.name,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 14),
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: AppColors.divider,
              valueColor: AlwaysStoppedAnimation(AppColors.primary),
            ),
          ),
           SizedBox(height: 6),
          Text(
            '${fmtNum(goal.currentAmount)} / ${fmtNum(goal.targetAmount)} ($percent%)',
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 12),
              fontWeight: FontWeight.w500,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}


// ── Budget Section ──
class _BudgetSection extends StatelessWidget {
  final List<PersonalBudget> budgets;
  const _BudgetSection({required this.budgets});

  @override
  Widget build(BuildContext context) {
    final activeCount = budgets.where((b) => b.isActive).length;
    final l10n = AppLocalizations.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          Row(
            children: [
              Text(l10n.translate('smartBudgetTitle'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              Spacer(),
              GestureDetector(
                onTap: () => context.push(RouteNames.personalBudget),
                child: Text(l10n.translate('manage'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w600, color: AppColors.primary)),
              ),
            ],
          ),
          SizedBox(height: 12),
          GestureDetector(
            onTap: () => context.push(RouteNames.personalBudget),
            child: Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(color: AppColors.surface, border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Container(padding: EdgeInsets.all(10), decoration: BoxDecoration(color: AppColors.primary.withAlpha(15), borderRadius: BorderRadius.circular(10)),
                  child: TwoToneIcon(data: TwoToneIcons.wallet, size: 22, outlineColor: AppColors.primary, detailColor: AppColors.primary)),
                SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l10n.translate('personalActiveBudgets', params: {'count': '$activeCount'}), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                ])),
                Icon(Icons.arrow_forward_ios, size: 14, color: AppColors.textDisabled),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Recurring Summary ──
class _RecurringSummary extends StatelessWidget {
  final int activeCount;
  const _RecurringSummary({required this.activeCount});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          Row(
            children: [
              Text(l10n.translate('personalRecurringTransactions'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              Spacer(),
              GestureDetector(
                onTap: () => context.push(RouteNames.personalTransactions, extra: 1),
                child: Text(l10n.translate('manage'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w600, color: AppColors.primary)),
              ),
            ],
          ),
          SizedBox(height: 12),
          GestureDetector(
            onTap: () => context.push(RouteNames.personalTransactions, extra: 1),
            child: Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(color: AppColors.surface, border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Container(padding: EdgeInsets.all(10), decoration: BoxDecoration(color: AppColors.primary.withAlpha(15), borderRadius: BorderRadius.circular(10)),
                  child: TwoToneIcon(data: TwoToneIcons.repeat, size: 22, outlineColor: AppColors.primary, detailColor: AppColors.primary)),
                SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l10n.translate('personalActiveTransactions', params: {'count': '$activeCount'}), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                ])),
                Icon(Icons.arrow_forward_ios, size: 14, color: AppColors.textDisabled),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Skeleton Loader ──
class _SkeletonLoader extends StatefulWidget {
  const _SkeletonLoader();

  @override
  State<_SkeletonLoader> createState() => _SkeletonLoaderState();
}

class _SkeletonLoaderState extends State<_SkeletonLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.3, end: 0.7).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  static const _boxColor = Color(0xFF24272D);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, _) {
          return Opacity(
            opacity: _anim.value,
            child: SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _shimmerBox(140, 24),
                      const Spacer(),
                      _shimmerBox(52, 52, radius: 16),
                      const SizedBox(width: 10),
                      _shimmerBox(52, 52, radius: 16),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _shimmerBox(double.infinity, 190, radius: 22),
                  const SizedBox(height: 20),
                  _shimmerBox(double.infinity, 110, radius: 14),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(child: _shimmerBox(double.infinity, 120, radius: 14)),
                      const SizedBox(width: 10),
                      Expanded(child: _shimmerBox(double.infinity, 120, radius: 14)),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _shimmerBox(100, 20),
                  const SizedBox(height: 16),
                  Row(
                    children: List.generate(3, (_) => Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: _shimmerBox(double.infinity, 100, radius: 12),
                      ),
                    )),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _shimmerBox(double w, double h, {double radius = 14}) {
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: _boxColor,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

String _shortError(String raw) {
  final clean = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (clean.length > 180) return clean.substring(0, 180) + '…';
  return clean;
}
