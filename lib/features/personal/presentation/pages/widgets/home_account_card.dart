import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/localization/app_localizations.dart';
import '../../../../../shared/widgets/two_tone_icon.dart';
import '../../../../../shared/widgets/two_tone_icons.dart';
import '../../../data/models/personal_models.dart';
import '../../../../../core/responsive/r_api.dart';
import '../../../../../core/utils/currency_formatter.dart' show currencyLabel, fmtNum;
import '../../../../../shared/widgets/app_icon_badge.dart';
import '../../../../../shared/widgets/account_type_bar.dart';
import '../../../domain/services/personal_finance_service.dart';

class HomeAccountCard extends StatefulWidget {
  final List<PersonalBankAccount> accounts;
  final void Function(PersonalBankAccount account)? onAccountTap;

  /// When true, accounts are kept per (currency + account type) instead of
  /// collapsing to one row per currency. Business uses this so a currency that
  /// exists as BOTH جاري and توفير shows two independent entries. Default
  /// false → Personal behavior is byte-for-byte unchanged.
  final bool distinctAccountTypes;

  const HomeAccountCard({
    super.key,
    required this.accounts,
    this.onAccountTap,
    this.distinctAccountTypes = false,
  });

  @override
  State<HomeAccountCard> createState() => _HomeAccountCardState();
}

class _HomeAccountCardState extends State<HomeAccountCard> {
  int _activeIndex = 0;
  final Map<String, ValueNotifier<int>> _currencyPage = {};
  PageController? _pageCtrl;
  double _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController(viewportFraction: 0.62);
    _pageCtrl!.addListener(() {
      final v = _pageCtrl!.page ?? 0;
      if ((v - _currentPage).abs() > 0.01 && mounted) {
        setState(() => _currentPage = v);
      }
    });
  }

  @override
  void dispose() {
    _pageCtrl?.dispose();
    for (final n in _currencyPage.values) {
      n.dispose();
    }
    super.dispose();
  }

  /// Logical currency key for display dedup. Mirrors the engine's cash
  /// bucket rule (YER_NEW shares YER's bucket; YER_OLD stays distinct) and
  /// uses the exact code otherwise — read-only, no engine change. Restore
  /// merge keeps the source clean; this keeps the card truthful even when
  /// historical duplicate rows exist.
  static String _logicalCurrencyKey(PersonalBankAccount a) {
    final cur = a.currency.trim().toUpperCase();
    final name = a.bankName.trim();
    final isCash = name == 'كاش' || name == 'Cash' || name == 'CASH';
    if (isCash) return cur == 'YER_NEW' ? 'YER' : cur;
    return cur;
  }

  List<_BankGroup> get _grouped {
    final map = <String, List<PersonalBankAccount>>{};
    for (final a in widget.accounts) {
      final key = a.bankName;
      map.putIfAbsent(key, () => []).add(a);
    }
    return map.entries
        .map((e) {
          var rows = e.value;
          // Business keeps EVERY currency+type as an independent entry: a
          // currency that exists as both جاري and توفير must show two rows.
          if (widget.distinctAccountTypes) {
            // Business all-branches: the SAME bank/currency/type exists once
            // per branch. Sum them into ONE row (50 + 500 = 550) instead of
            // showing only the first branch's balance.
            final merged = <String, PersonalBankAccount>{};
            for (final a in rows) {
              final key =
                  '${a.currency.trim().toUpperCase()}|${a.accountType}';
              final existing = merged[key];
              if (existing == null) {
                merged[key] = a;
              } else {
                merged[key] = PersonalBankAccount(
                  id: existing.id,
                  bankName: existing.bankName,
                  balance: existing.balance + a.balance,
                  currency: existing.currency,
                  notes: existing.notes,
                  accountType: existing.accountType,
                );
              }
            }
            return _BankGroup(name: e.key, accounts: merged.values.toList());
          }
          // Cash: one logical row per currency bucket. Historical duplicate
          // rows (same bucket) collapse here with SUMMED balances — a stale
          // zero stub can never again be the visible card while the money
          // sits on its twin. Identity taps through to the canonical
          // (first non-zero, else first) row.
          if (rows.isNotEmpty && isCashAccount(rows.first.bankName)) {
            rows = PersonalFinanceService.canonicalCashAccounts(rows);
          }
          final seen = <String>{};
          final unique = <PersonalBankAccount>[];
          for (final a in rows) {
            if (seen.add(_logicalCurrencyKey(a))) unique.add(a);
          }
          return _BankGroup(name: e.key, accounts: unique);
        })
        .toList();
  }

  ValueNotifier<int> _getCurrencyNotifier(String bankName) {
    return _currencyPage.putIfAbsent(bankName, () => ValueNotifier(0));
  }

  @override
  Widget build(BuildContext context) {
    final groups = _grouped;
    if (groups.isEmpty) return const _EmptyCard();

    if (groups.length == 1) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: _WalletCard(
          group: groups[0],
          isActive: true,
          currencyPage: _getCurrencyNotifier(groups[0].name),
          onTap: widget.onAccountTap == null
              ? null
              : () {
                  final notifier = _getCurrencyNotifier(groups[0].name);
                  final idx = notifier.value.clamp(0, groups[0].accounts.length - 1);
                  widget.onAccountTap?.call(groups[0].accounts[idx]);
                },
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 165,
          child: PageView.builder(
            controller: _pageCtrl,
            padEnds: true,
            clipBehavior: Clip.none,
            itemCount: groups.length,
            onPageChanged: (i) {
              HapticFeedback.lightImpact();
              setState(() => _activeIndex = i);
            },
            itemBuilder: (context, i) {
              final bn = groups[i].name;
              final rel = i - _currentPage;
              final dist = rel.abs().clamp(0.0, 2.0);

              final t = (dist / 1.5).clamp(0.0, 1.0);
              final angle = rel.clamp(-1.0, 1.0) * -0.12;
              final scale = 1.0 - (t * 0.2);
              final opacity = 1.0 - (t * 0.5);

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: AnimatedOpacity(
                  opacity: opacity,
                  duration: const Duration(milliseconds: 100),
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.001)
                      ..rotateY(angle)
                      ..setEntry(0, 0, scale)
                      ..setEntry(1, 1, scale),
                    child: _WalletCard(
                      group: groups[i],
                      isActive: i == _activeIndex,
                      currencyPage: _getCurrencyNotifier(bn),
                      onTap: widget.onAccountTap == null
                          ? null
                          : () {
                              if (i == _activeIndex) {
                                final notifier = _getCurrencyNotifier(bn);
                                final idx = notifier.value.clamp(0, groups[i].accounts.length - 1);
                                widget.onAccountTap?.call(groups[i].accounts[idx]);
                              } else {
                                HapticFeedback.mediumImpact();
                                _pageCtrl!.animateToPage(
                                  i,
                                  duration: const Duration(milliseconds: 400),
                                  curve: Curves.easeOutCubic,
                                );
                              }
                            },
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (groups.length > 1) ...[
          const SizedBox(height: 12),
          _DotIndicator(count: groups.length, activeIndex: _activeIndex),
        ],
      ],
    );
  }
}

class _BankGroup {
  final String name;
  final List<PersonalBankAccount> accounts;
  _BankGroup({required this.name, required this.accounts});
}

class _WalletCard extends StatelessWidget {
  final _BankGroup group;
  final bool isActive;
  final ValueNotifier<int> currencyPage;
  final VoidCallback? onTap;

  const _WalletCard({
    required this.group,
    required this.isActive,
    required this.currencyPage,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasMultiple = group.accounts.length > 1;
    final l10n = AppLocalizations.of(context);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment(-1.0, -1.0),
            end: Alignment(1.5, 1.5),
            colors: [Color(0xFFC01838), AppColors.primary, Color(0xFF7A1020)],
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withAlpha(isActive ? 90 : 40),
              blurRadius: 28,
              offset: const Offset(0, 12),
            ),
            BoxShadow(
              color: AppColors.primaryDark.withAlpha(isActive ? 50 : 20),
              blurRadius: 40,
              offset: const Offset(0, 17),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: -20, right: -12,
                child: _dc(60, 12),
              ),
              Positioned(
                bottom: -20, left: -8,
                child: _dc(68, 8),
              ),
              Positioned(
                top: 30, left: -24,
                child: _dc(48, 6),
              ),
              Positioned(
                bottom: 22, right: -16,
                child: _dc(40, 5),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AppIconBadge(
                        icon: TwoToneIcons.bank.outline,
                        size: 32,
                        iconSize: 15,
                        backgroundColor: Colors.white.withAlpha(20),
                        borderColor: Colors.white.withAlpha(30),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          isCashAccount(group.name) ? cashDisplayName() : group.name,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 13),
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (hasMultiple) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(20),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            l10n.translate('personalCurrenciesCount', params: {'count': '${group.accounts.length}'}),
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 9),
                              fontWeight: FontWeight.w700,
                              color: Colors.white.withAlpha(180),
                            ),
                          ),
                        ),
                      ] else ...[
                        if (group.accounts.first.accountType != 'cash') ...[
                          const SizedBox(width: 6),
                          AccountTypeBadge(
                              type: group.accounts.first.accountType,
                              dense: true),
                        ],
                      ],
                    ],
                  ),
                  const SizedBox(height: 10),
                  ValueListenableBuilder<int>(
                    valueListenable: currencyPage,
                    builder: (context, cPage, _) {
                      final account = group.accounts[cPage.clamp(0, group.accounts.length - 1)];
                      final curLabel = _currencyDisplay(account.currency, l10n);
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${fmtNum(account.balance)}',
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 22),
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              height: 1.0,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha(25),
                              borderRadius: BorderRadius.circular(5),
                              border: Border.all(color: Colors.white.withAlpha(40), width: 0.5),
                            ),
                            child: Text(
                              curLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: R.fontSize(context, 9),
                                fontWeight: FontWeight.w600,
                                color: Colors.white.withAlpha(220),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  if (hasMultiple && isActive) ...[
                    const SizedBox(height: 6),
                    _CurrencyWheel(
                      accounts: group.accounts,
                      currencyPage: currencyPage,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dc(double s, double a) => Container(
        width: s,
        height: s,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withAlpha(a.toInt()),
        ),
      );
}

class _CurrencyWheel extends StatelessWidget {
  final List<PersonalBankAccount> accounts;
  final ValueNotifier<int> currencyPage;

  const _CurrencyWheel({
    required this.accounts,
    required this.currencyPage,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    if (accounts.length == 1) {
      final a = accounts.first;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: AccountTypeBadge(type: a.accountType, dense: true),
      );
    }

    return SizedBox(
      height: 32,
      child: ValueListenableBuilder<int>(
        valueListenable: currencyPage,
        builder: (context, cIndex, _) {
          // A branch switch can replace the accounts list while this stateful
          // card keeps its old page index. Clamp before indexing; otherwise
          // the wheel throws RangeError and renders the white empty strip.
          final cPage = cIndex.clamp(0, accounts.length - 1);
          if (cPage != cIndex) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (currencyPage.value != cPage) currencyPage.value = cPage;
            });
          }
          final a = accounts[cPage];
          final hasNext = cPage < accounts.length - 1;
          final hasPrev = cPage > 0;

          return Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: hasPrev
                    ? () {
                        HapticFeedback.lightImpact();
                        currencyPage.value = cPage - 1;
                      }
                    : null,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: hasPrev ? Colors.white.withAlpha(25) : Colors.white.withAlpha(10),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white.withAlpha(hasPrev ? 40 : 12), width: 0.5),
                  ),
                  child: TwoToneIcon(
                    data: TwoToneIcons.arrowRight,
                    size: 17,
                    outlineColor: hasPrev ? Colors.white.withAlpha(220) : Colors.white.withAlpha(60),
                    detailColor: hasPrev ? AppColors.primary : Colors.white.withAlpha(60),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (a.accountType != 'cash')
                Container(
                  height: 26,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(25),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white.withAlpha(40), width: 0.5),
                  ),
                  child: Center(
                    child: AccountTypeBadge(type: a.accountType, dense: true),
                  ),
                ),
              const SizedBox(width: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: hasNext
                    ? () {
                        HapticFeedback.lightImpact();
                        currencyPage.value = cPage + 1;
                      }
                    : null,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: hasNext ? Colors.white.withAlpha(25) : Colors.white.withAlpha(10),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white.withAlpha(hasNext ? 40 : 12), width: 0.5),
                  ),
                  child: TwoToneIcon(
                    data: TwoToneIcons.arrowLeft,
                    size: 17,
                    outlineColor: hasNext ? Colors.white.withAlpha(220) : Colors.white.withAlpha(60),
                    detailColor: hasNext ? AppColors.primary : Colors.white.withAlpha(60),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DotIndicator extends StatelessWidget {
  final int count;
  final int activeIndex;

  const _DotIndicator({required this.count, required this.activeIndex});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final isActive = i == activeIndex;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: isActive ? 22 : 6,
          height: 6,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            color: isActive
                ? AppColors.primary
                : AppColors.primary.withAlpha(60),
          ),
        );
      }),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.all(20),
        height: 175,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment(-1.0, -1.0),
            end: Alignment(1.5, 1.5),
            colors: [
              Color(0xFFC01838),
              AppColors.primary,
              Color(0xFF7A1020),
            ],
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withAlpha(100),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: AppColors.primaryDark.withAlpha(60),
              blurRadius: 40,
              offset: const Offset(0, 16),
            ),
          ],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              top: -20,
              right: -12,
              child: _ec(60, 12),
            ),
            Positioned(
              bottom: -20,
              left: -8,
              child: _ec(68, 8),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIconBadge(
                  icon: TwoToneIcons.wallet.outline,
                  size: 36,
                  iconSize: 18,
                  backgroundColor: Colors.white.withAlpha(20),
                  borderColor: Colors.white.withAlpha(30),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.translate('noBankAccounts'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withAlpha(180),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '0',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 26),
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    height: 1.0,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.translate('addBankAccountToStart'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 10),
                    color: Colors.white.withAlpha(100),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _ec(double s, double a) => Container(
        width: s,
        height: s,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withAlpha(a.toInt()),
        ),
      );
}

String _accountTypeKey(String type) {
  switch (type) {
    case 'checking': return 'accountTypeCheckingFull';
    case 'savings': return 'accountTypeSavingsFull';
    case 'credit': return 'accountTypeCreditFull';
    case 'wallet': return 'accountTypeWalletFull';
    case 'cash': return 'accountTypeCashFull';
    default: return 'accountTypeCheckingFull';
  }
}


String _currencyDisplay(String currency, AppLocalizations l10n) {
  // Compact badge → the short ISO code (YER_OLD, YER_NEW, SAR, USD, …) so a
  // long name can never crowd or wrap next to the balance.
  return currencyLabel(currency, locale: l10n.locale.languageCode);
}
