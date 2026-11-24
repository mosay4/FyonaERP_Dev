import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/localization/app_localizations.dart';
import '../../../core/responsive/r_api.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/currency_formatter.dart';
import '../app_icon_badge.dart';
import '../fyona_refresh.dart';
import '../fyona_text_field.dart';
import '../two_tone_icon.dart';
import '../two_tone_icons.dart';
import 'bank_detail_data.dart';

export 'bank_detail_data.dart';

const _kIn = AppColors.success;
const _kOut = AppColors.danger;
const _kCount = AppColors.info;
const _kSwap = Duration(milliseconds: 380);
const _kCurve = Curves.easeOutCubic;

/// The single bank-detail screen shared by the Personal and Business banks
/// sections. The page owns the data source (personal store / on-device
/// business ledger) and hands normalised accounts + movements here; this view
/// owns the presentation: currency selection, period, key figures, flow
/// charts, breakdown, accounts, movements and the export sheet.
class BankDetailView extends StatefulWidget {
  final String bankName;
  final List<BankDetailAccount> accounts;

  /// Every movement of the bank (all periods); the view filters by month.
  final List<BankDetailMovement> movements;
  final String walletCurrency;
  final double Function(double amount, String from) toWallet;

  /// `false` when the employee may not see balances (business permission).
  final bool showBalances;

  /// Shows the export (PDF) action.
  final bool canExport;

  /// Extra header actions (e.g. unlink).
  final List<Widget> headerActions;
  final Future<void> Function() onRefresh;
  final Future<void> Function(BankReportBundle bundle)? onExport;

  /// Only for remote (network) history; local data never shows a loader.
  final bool movementsLoading;
  final String? failureText;
  final VoidCallback? onRetry;

  const BankDetailView({
    super.key,
    required this.bankName,
    required this.accounts,
    required this.movements,
    required this.walletCurrency,
    required this.toWallet,
    required this.onRefresh,
    this.showBalances = true,
    this.canExport = true,
    this.headerActions = const [],
    this.onExport,
    this.movementsLoading = false,
    this.failureText,
    this.onRetry,
  });

  @override
  State<BankDetailView> createState() => _BankDetailViewState();
}

class _BankDetailViewState extends State<BankDetailView> {
  int _month = DateTime.now().month;
  int _year = DateTime.now().year;
  String _query = '';
  String? _picked;

  List<String> get _currencies =>
      bankCurrencies(widget.accounts, widget.movements, widget.walletCurrency);

  String _selected(List<String> currencies) {
    final p = _picked;
    if (p != null && (p == kBankAllCurrencies && currencies.length > 1 ||
        currencies.contains(p))) {
      return p;
    }
    return currencies.isEmpty ? widget.walletCurrency : currencies.first;
  }

  String _period(AppLocalizations l10n) =>
      '${l10n.translate('month$_month')} $_year';

  List<BankDetailMovement> get _periodMovements => widget.movements
      .where((m) => m.date != null && m.date!.month == _month &&
          m.date!.year == _year)
      .toList();

  BankCurrencyFigures _figures(String currency, List<BankDetailMovement> moves) =>
      BankCurrencyFigures.compute(
        currency: currency,
        walletCurrency: widget.walletCurrency,
        accounts: widget.accounts,
        periodMovements: moves,
        toWallet: widget.toWallet,
      );

  void _shiftMonth(int delta) => setState(() {
        _month += delta;
        if (_month < 1) {
          _month = 12;
          _year--;
        } else if (_month > 12) {
          _month = 1;
          _year++;
        }
      });

  Future<void> _export(List<String> currencies, String selected) async {
    final l10n = AppLocalizations.of(context);
    final request = await showModalBottomSheet<BankReportRequest>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => BankExportSheet(
        bankName: widget.bankName,
        period: _period(l10n),
        selectedCurrency: selected,
        multiCurrency: currencies.length > 1,
      ),
    );
    if (request == null || !mounted || widget.onExport == null) return;
    final moves = _periodMovements;
    final all = request.allCurrencies || selected == kBankAllCurrencies;
    final sections = all
        ? [for (final c in currencies) _figures(c, moves)]
        : [_figures(selected, moves)];
    await widget.onExport!(BankReportBundle(
      bankName: widget.bankName,
      period: _period(l10n),
      walletCurrency: widget.walletCurrency,
      request: BankReportRequest(content: request.content, allCurrencies: all),
      sections: sections,
      combined: all && currencies.length > 1
          ? _figures(kBankAllCurrencies, moves)
          : null,
      accountCount: widget.accounts.length,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final currencies = _currencies;
    final selected = _selected(currencies);
    final figures = _figures(selected, _periodMovements);
    final q = _query.trim().toLowerCase();
    final visible = q.isEmpty
        ? figures.movements
        : figures.movements.where((m) {
            return m.title.toLowerCase().contains(q) ||
                (m.category ?? '').toLowerCase().contains(q) ||
                (m.note ?? '').toLowerCase().contains(q) ||
                fmtNum(m.amount).contains(q);
          }).toList();
    final entries = _groupByDay(visible);
    final swapKey = '$selected|$_month|$_year';

    return FyonaRefresh(
      color: AppColors.primary,
      backgroundColor: AppColors.surface,
      onRefresh: widget.onRefresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                  16, MediaQuery.of(context).padding.top + 8, 16, 0),
              child: _HeroCard(
                bankName: widget.bankName,
                accountCount: widget.accounts.length,
                currencyCount: currencies.length,
                figures: figures,
                showBalance: widget.showBalances,
                actions: [
                  ...widget.headerActions,
                  if (widget.canExport && widget.onExport != null)
                    IconButton(
                      tooltip: l10n.translate('exportReport'),
                      icon: const Icon(Icons.receipt_long, color: Colors.white),
                      onPressed: () => _export(currencies, selected),
                    ),
                ],
              ),
            ),
          ),
          if (currencies.length > 1)
            SliverToBoxAdapter(
              child: _CurrencySelector(
                currencies: currencies,
                selected: selected,
                onSelect: (c) => setState(() => _picked = c),
              ),
            ),
          SliverToBoxAdapter(
            child: _PeriodBar(
              label: _period(l10n),
              onPrev: () => _shiftMonth(-1),
              onNext: () => _shiftMonth(1),
            ),
          ),
          SliverToBoxAdapter(child: _KpiGrid(figures: figures)),
          SliverToBoxAdapter(
            child: AnimatedSize(
              duration: _kSwap,
              curve: _kCurve,
              alignment: Alignment.topCenter,
              child: figures.count == 0
                  ? const SizedBox(width: double.infinity)
                  : Column(children: [
                      _FlowCard(
                          figures: figures,
                          month: _month,
                          year: _year,
                          swapKey: swapKey),
                      _BreakdownCard(figures: figures, swapKey: swapKey),
                    ]),
            ),
          ),
          SliverToBoxAdapter(
            child: _AccountsCard(
              figures: figures,
              allCount: currencies.length,
              showBalances: widget.showBalances,
              toWallet: widget.toWallet,
              walletCurrency: widget.walletCurrency,
              swapKey: swapKey,
              onPickCurrency: (c) => setState(() => _picked = c),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 22, 16, 10),
              child: Row(children: [
                Expanded(
                  child: _SectionTitle(
                      title: l10n.translate('transactionsTab'),
                      icon: TwoToneIcons.transfer),
                ),
                _CountPill(
                    text: l10n.translate('bdvMovementsBadge',
                        params: {'count': '${figures.count}'})),
              ]),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FyonaTextField(
                onChanged: (v) => setState(() => _query = v),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: l10n.translate('searchHint'),
                  hintStyle: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 12),
                      color: AppColors.textDisabled),
                  prefixIcon: const Icon(Icons.search,
                      color: AppColors.textDisabled, size: 20),
                  filled: true,
                  fillColor: AppColors.surfaceVariant,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
            ),
          ),
          if (widget.movementsLoading && visible.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(32, 28, 32, 28),
                child: LinearProgressIndicator(
                    minHeight: 2, color: AppColors.primary),
              ),
            )
          else if (widget.failureText != null && visible.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Center(
                  child: TextButton.icon(
                    onPressed: widget.onRetry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(widget.failureText!,
                        style: const TextStyle(fontFamily: 'Cairo')),
                  ),
                ),
              ),
            )
          else if (visible.isEmpty)
            SliverToBoxAdapter(child: _EmptyMovements(swapKey: swapKey))
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              sliver: SliverList.builder(
                itemCount: entries.length,
                itemBuilder: (ctx, i) {
                  final e = entries[i];
                  return _FadeSlideIn(
                    key: ValueKey('$swapKey|${e.key}'),
                    delay: Duration(milliseconds: math.min(i, 10) * 28),
                    child: e.movement == null
                        ? _DayHeader(day: e.day, net: e.dayNet,
                            currency: figures.isAll ? null : selected)
                        : _MovementTile(movement: e.movement!),
                  );
                },
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 110)),
        ],
      ),
    );
  }

  List<_Entry> _groupByDay(List<BankDetailMovement> list) {
    final out = <_Entry>[];
    DateTime? current;
    var headerIndex = -1;
    for (final m in list) {
      final d = m.date;
      final day = d == null ? null : DateTime(d.year, d.month, d.day);
      if (out.isEmpty || day != current) {
        current = day;
        headerIndex = out.length;
        out.add(_Entry('h${day?.toIso8601String() ?? 'none'}', day, null, 0));
      }
      out.add(_Entry('m${m.id}', day, m, 0));
      final h = out[headerIndex];
      out[headerIndex] = _Entry(h.key, h.day, null,
          h.dayNet + (m.isIn ? m.amount.abs() : -m.amount.abs()));
    }
    return out;
  }
}

class _Entry {
  final String key;
  final DateTime? day;
  final BankDetailMovement? movement;
  final double dayNet;
  const _Entry(this.key, this.day, this.movement, this.dayNet);
}

// ════════════════════════════════════════════════════════════
//  Shared pieces
// ════════════════════════════════════════════════════════════

/// Fade + slight lift used whenever content swaps (currency / period).
Widget _swapTransition(Widget child, Animation<double> anim) {
  return FadeTransition(
    opacity: anim,
    child: SlideTransition(
      position: Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
          .animate(anim),
      child: child,
    ),
  );
}

Widget _swap(Object key, Widget child,
    {AlignmentGeometry alignment = AlignmentDirectional.topStart}) {
  return AnimatedSwitcher(
    duration: _kSwap,
    switchInCurve: _kCurve,
    switchOutCurve: Curves.easeInCubic,
    transitionBuilder: _swapTransition,
    layoutBuilder: (current, previous) => Stack(
      alignment: alignment,
      children: [...previous, ?current],
    ),
    child: KeyedSubtree(key: ValueKey(key), child: child),
  );
}

/// Number that glides from its previous value to the new one.
class _AnimatedAmount extends StatelessWidget {
  final double value;
  final TextStyle style;
  final String prefix;
  const _AnimatedAmount(
      {required this.value, required this.style, this.prefix = ''});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: value),
      duration: const Duration(milliseconds: 650),
      curve: _kCurve,
      builder: (_, v, _) => Text('$prefix${fmtNum(v)}',
          maxLines: 1, textDirection: TextDirection.ltr, style: style),
    );
  }
}

class _FadeSlideIn extends StatelessWidget {
  final Widget child;
  final Duration delay;
  const _FadeSlideIn({super.key, required this.child, this.delay = Duration.zero});

  @override
  Widget build(BuildContext context) {
    final total = const Duration(milliseconds: 320) + delay;
    final start = delay.inMilliseconds / total.inMilliseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(start, 1, curve: _kCurve),
      builder: (_, t, c) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * 14), child: c),
      ),
      child: child,
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border.withAlpha(160)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withAlpha(AppColors.isLightMode ? 14 : 40),
              blurRadius: 18,
              offset: const Offset(0, 6)),
        ],
      ),
      child: child,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final TwoToneIconData icon;
  const _SectionTitle({required this.title, required this.icon});
  static const color = AppColors.primary;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      AppIconBadge(
          icon: icon.outline,
          size: 30,
          iconSize: 15,
          accentColor: color,
          backgroundColor: color.withAlpha(24),
          borderColor: color.withAlpha(50)),
      const SizedBox(width: 10),
      Flexible(
        child: Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 14),
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary)),
      ),
    ]);
  }
}

class _CountPill extends StatelessWidget {
  final String text;
  const _CountPill({required this.text});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: _kSwap,
      transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
      child: Container(
        key: ValueKey(text),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
            color: AppColors.primary.withAlpha(22),
            borderRadius: BorderRadius.circular(20)),
        child: Text(text,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 11),
                fontWeight: FontWeight.w700,
                color: AppColors.primary)),
      ),
    );
  }
}

String _currencyCaption(String code) {
  final flag = currencyFlagEmoji(code);
  return flag.isEmpty ? currencyShort(code) : '$flag  ${currencyShort(code)}';
}

// ════════════════════════════════════════════════════════════
//  Hero header
// ════════════════════════════════════════════════════════════
class _HeroCard extends StatelessWidget {
  final String bankName;
  final int accountCount;
  final int currencyCount;
  final BankCurrencyFigures figures;
  final bool showBalance;
  final List<Widget> actions;

  const _HeroCard({
    required this.bankName,
    required this.accountCount,
    required this.currencyCount,
    required this.figures,
    required this.showBalance,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final muted = Colors.white.withAlpha(185);
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: [Color(0xFFC81E3A), Color(0xFFB00020), Color(0xFF6E0C1B)],
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
              color: AppColors.primary.withAlpha(90),
              blurRadius: 30,
              offset: const Offset(0, 14)),
        ],
      ),
      child: Stack(children: [
        const PositionedDirectional(
          top: -46,
          end: -30,
          child: _Ring(size: 150, alpha: 22),
        ),
        const PositionedDirectional(
          bottom: -60,
          start: -40,
          child: _Ring(size: 170, alpha: 14),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.maybePop(context),
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                        color: Colors.white.withAlpha(30),
                        borderRadius: BorderRadius.circular(12)),
                    child: const Icon(Icons.arrow_back_ios_new_rounded,
                        color: Colors.white, size: 17),
                  ),
                ),
                const Spacer(),
                ...actions,
              ]),
              const SizedBox(height: 14),
              Row(children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(17),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withAlpha(40),
                          blurRadius: 12,
                          offset: const Offset(0, 5)),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: const TwoToneIcon(
                      data: TwoToneIcons.bank,
                      size: 28,
                      outlineColor: Color(0xFFB00020)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(bankName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 18),
                              fontWeight: FontWeight.w800,
                              height: 1.25,
                              color: Colors.white)),
                      const SizedBox(height: 4),
                      Wrap(spacing: 6, runSpacing: 4, children: [
                        _HeroChip(
                            text: l10n.translate('accountsCount',
                                params: {'count': '$accountCount'})),
                        if (currencyCount > 0)
                          _HeroChip(
                              text: l10n.translate('bdvCurrencies',
                                  params: {'count': '$currencyCount'})),
                      ]),
                    ],
                  ),
                ),
              ]),
              if (showBalance) ...[
                const SizedBox(height: 20),
                Container(height: 1, color: Colors.white.withAlpha(30)),
                const SizedBox(height: 14),
                _swap(
                  figures.currency,
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          figures.isAll
                              ? '${l10n.translate('totalBalances')} · ${l10n.translate('bdvConvertedTo', params: {'currency': currencyShort(figures.displayCurrency)})}'
                              : '${l10n.translate('bdvCurrentBalance')} · ${currencyLabel(figures.currency)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 11),
                              color: muted)),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: _AnimatedAmount(
                          value: figures.balance,
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 30),
                              fontWeight: FontWeight.w800,
                              color: Colors.white),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _swap(
                      figures.displayCurrency,
                      Text(currencyShort(figures.displayCurrency),
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 13),
                              fontWeight: FontWeight.w700,
                              color: muted)),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ]),
    );
  }
}

class _Ring extends StatelessWidget {
  final double size;
  final int alpha;
  const _Ring({required this.size, required this.alpha});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withAlpha(alpha), width: 18),
        ),
      );
}

class _HeroChip extends StatelessWidget {
  final String text;
  const _HeroChip({required this.text});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
        decoration: BoxDecoration(
            color: Colors.white.withAlpha(34),
            borderRadius: BorderRadius.circular(20)),
        child: Text(text,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 10.5),
                fontWeight: FontWeight.w600,
                color: Colors.white)),
      );
}

// ════════════════════════════════════════════════════════════
//  Currency selector
// ════════════════════════════════════════════════════════════
class _CurrencySelector extends StatelessWidget {
  final List<String> currencies;
  final String selected;
  final ValueChanged<String> onSelect;
  const _CurrencySelector(
      {required this.currencies, required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final options = [kBankAllCurrencies, ...currencies];
    return SizedBox(
      height: 64,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        scrollDirection: Axis.horizontal,
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final c = options[i];
          final on = c == selected;
          final all = c == kBankAllCurrencies;
          return GestureDetector(
            key: ValueKey('bank-currency-$c'),
            onTap: () => onSelect(c),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 280),
              curve: _kCurve,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: on
                    ? const LinearGradient(
                        colors: [Color(0xFFC81E3A), Color(0xFF8C0A1C)])
                    : null,
                color: on ? null : AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: on ? Colors.transparent : AppColors.border),
                boxShadow: on
                    ? [
                        BoxShadow(
                            color: AppColors.primary.withAlpha(70),
                            blurRadius: 12,
                            offset: const Offset(0, 4))
                      ]
                    : const [],
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (all)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 6),
                    child: Icon(Icons.layers_rounded,
                        size: 16,
                        color: on ? Colors.white : AppColors.textSecondary),
                  ),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 280),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 12.5),
                      fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                      color: on ? Colors.white : AppColors.textPrimary),
                  child: Text(all
                      ? l10n.translate('allCurrencies')
                      : _currencyCaption(c)),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  Period bar
// ════════════════════════════════════════════════════════════
class _PeriodBar extends StatelessWidget {
  final String label;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  const _PeriodBar(
      {required this.label, required this.onPrev, required this.onNext});

  @override
  Widget build(BuildContext context) {
    Widget arrow(IconData icon, VoidCallback onTap) => InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(icon, color: AppColors.textSecondary, size: 22)),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        decoration: BoxDecoration(
            color: AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          // RTL: the start-side arrow goes back in time.
          arrow(Icons.chevron_right, onPrev),
          Expanded(
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.calendar_month_rounded,
                  size: 16, color: AppColors.primary),
              const SizedBox(width: 6),
              _swap(
                label,
                Text(label,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 14),
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary)),
                alignment: Alignment.center,
              ),
            ]),
          ),
          arrow(Icons.chevron_left, onNext),
        ]),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  Key figures
// ════════════════════════════════════════════════════════════
class _KpiGrid extends StatelessWidget {
  final BankCurrencyFigures figures;
  const _KpiGrid({required this.figures});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final code = currencyShort(figures.displayCurrency);
    final net = figures.net;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(children: [
        Row(children: [
          _KpiTile(
              label: l10n.translate('bdvTotalIn'),
              value: figures.totalIn,
              currency: code,
              color: _kIn,
              icon: TwoToneIcons.arrowDown),
          const SizedBox(width: 10),
          _KpiTile(
              label: l10n.translate('bdvTotalOut'),
              value: figures.totalOut,
              currency: code,
              color: _kOut,
              icon: TwoToneIcons.arrowUp),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          _KpiTile(
              label: l10n.translate('net'),
              value: net,
              currency: code,
              color: net >= 0 ? AppColors.primary : _kOut,
              icon: TwoToneIcons.money,
              signed: true),
          const SizedBox(width: 10),
          _KpiTile(
              label: l10n.translate('bdvMovementsCount'),
              value: figures.count.toDouble(),
              currency: '',
              color: _kCount,
              icon: TwoToneIcons.activity,
              integer: true),
        ]),
      ]),
    );
  }
}

class _KpiTile extends StatelessWidget {
  final String label;
  final double value;
  final String currency;
  final Color color;
  final TwoToneIconData icon;
  final bool signed;
  final bool integer;

  const _KpiTile({
    required this.label,
    required this.value,
    required this.currency,
    required this.color,
    required this.icon,
    this.signed = false,
    this.integer = false,
  });

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
        fontFamily: 'Cairo',
        fontSize: R.fontSize(context, 17),
        fontWeight: FontWeight.w800,
        color: AppColors.textPrimary);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.border.withAlpha(160)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                    color: color.withAlpha(28),
                    borderRadius: BorderRadius.circular(10)),
                alignment: Alignment.center,
                child: TwoToneIcon(data: icon, size: 15, outlineColor: color),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11),
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary)),
              ),
            ]),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerStart,
                    child: integer
                        ? TweenAnimationBuilder<double>(
                            tween: Tween<double>(end: value),
                            duration: const Duration(milliseconds: 650),
                            curve: _kCurve,
                            builder: (_, v, _) =>
                                Text('${v.round()}', style: style),
                          )
                        : _AnimatedAmount(
                            value: value,
                            prefix: signed && value > 0 ? '+' : '',
                            style: style.copyWith(
                                color: signed ? color : AppColors.textPrimary),
                          ),
                  ),
                ),
                if (currency.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Text(currency,
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 10),
                          fontWeight: FontWeight.w700,
                          color: AppColors.textDisabled)),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Container(
              height: 3,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                    colors: [color, color.withAlpha(0)],
                    begin: AlignmentDirectional.centerStart,
                    end: AlignmentDirectional.centerEnd),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  Flow (in vs out + daily chart)
// ════════════════════════════════════════════════════════════
class _FlowCard extends StatelessWidget {
  final BankCurrencyFigures figures;
  final int month;
  final int year;
  final String swapKey;
  const _FlowCard(
      {required this.figures,
      required this.month,
      required this.year,
      required this.swapKey});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final total = figures.totalIn + figures.totalOut;
    final inShare = total <= 0 ? 0.5 : figures.totalIn / total;
    final days = DateUtils.getDaysInMonth(year, month);
    double maxY = 0;
    for (var d = 1; d <= days; d++) {
      maxY = math.max(maxY,
          math.max(figures.dailyIn[d] ?? 0, figures.dailyOut[d] ?? 0));
    }
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(
              title: l10n.translate('bdvInOutFlow'), icon: TwoToneIcons.barChart),
          const SizedBox(height: 14),
          LayoutBuilder(builder: (_, c) {
            final w = c.maxWidth;
            return ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 12,
                child: Row(children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 600),
                    curve: _kCurve,
                    width: w * inShare,
                    color: _kIn,
                  ),
                  Expanded(child: Container(color: _kOut)),
                ]),
              ),
            );
          }),
          const SizedBox(height: 10),
          Row(children: [
            _Legend(
                color: _kIn,
                label: l10n.translate('bdvIn'),
                value: '${(inShare * 100).round()}%'),
            const Spacer(),
            _Legend(
                color: _kOut,
                label: l10n.translate('bdvOut'),
                value: '${((1 - inShare) * 100).round()}%'),
          ]),
          if (maxY > 0) ...[
            const SizedBox(height: 18),
            Text(l10n.translate('bdvDailyFlow'),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 12),
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary)),
            const SizedBox(height: 8),
            SizedBox(
              height: 170,
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: BarChart(
                  duration: const Duration(milliseconds: 450),
                  curve: _kCurve,
                  BarChartData(
                    maxY: maxY * 1.15,
                    alignment: BarChartAlignment.spaceBetween,
                    barTouchData: const BarTouchData(enabled: false),
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      horizontalInterval: maxY / 3,
                      getDrawingHorizontalLine: (_) => FlLine(
                          color: AppColors.border.withAlpha(140),
                          strokeWidth: 0.8,
                          dashArray: const [4, 4]),
                    ),
                    borderData: FlBorderData(show: false),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(),
                      rightTitles: const AxisTitles(),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 38,
                          interval: maxY / 3,
                          getTitlesWidget: (v, meta) => v == meta.max
                              ? const SizedBox.shrink()
                              : Text(_compact(v),
                                  style: const TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 9,
                                      color: AppColors.textDisabled)),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 20,
                          getTitlesWidget: (v, _) {
                            final d = v.toInt();
                            if (d != 1 && d % 5 != 0) {
                              return const SizedBox.shrink();
                            }
                            return Text('$d',
                                style: const TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 9,
                                    color: AppColors.textDisabled));
                          },
                        ),
                      ),
                    ),
                    barGroups: [
                      for (var d = 1; d <= days; d++)
                        BarChartGroupData(x: d, barsSpace: 1, barRods: [
                          BarChartRodData(
                              toY: figures.dailyIn[d] ?? 0,
                              width: 3.2,
                              color: _kIn,
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(2))),
                          BarChartRodData(
                              toY: figures.dailyOut[d] ?? 0,
                              width: 3.2,
                              color: _kOut,
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(2))),
                        ]),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _compact(double v) {
  final a = v.abs();
  if (a >= 1e9) return '${(v / 1e9).toStringAsFixed(1)}B';
  if (a >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
  if (a >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}K';
  return v.toStringAsFixed(0);
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  final String value;
  const _Legend({required this.color, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Text(label,
          style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 11.5),
              color: AppColors.textSecondary)),
      const SizedBox(width: 6),
      Text(value,
          textDirection: TextDirection.ltr,
          style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 12),
              fontWeight: FontWeight.w800,
              color: color)),
    ]);
  }
}

// ════════════════════════════════════════════════════════════
//  Breakdown
// ════════════════════════════════════════════════════════════
class _BreakdownCard extends StatelessWidget {
  final BankCurrencyFigures figures;
  final String swapKey;
  const _BreakdownCard({required this.figures, required this.swapKey});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    Widget group(String title, Map<String, double> data, double total,
        Color color) {
      final rows = data.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 12),
                  fontWeight: FontWeight.w700,
                  color: color)),
          const SizedBox(height: 8),
          for (final e in rows.take(5))
            _BreakdownRow(
              label: e.key,
              amount: e.value,
              share: total > 0 ? e.value / total : 0,
              color: color,
            ),
        ],
      );
    }

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(
              title: l10n.translate('bdvBreakdown'), icon: TwoToneIcons.pieChart),
          const SizedBox(height: 14),
          _swap(
            swapKey,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (figures.inByKey.isNotEmpty)
                  group(l10n.translate('bdvTopIn'), figures.inByKey,
                      figures.totalIn, _kIn),
                if (figures.inByKey.isNotEmpty && figures.outByKey.isNotEmpty)
                  const SizedBox(height: 10),
                if (figures.outByKey.isNotEmpty)
                  group(l10n.translate('bdvTopOut'), figures.outByKey,
                      figures.totalOut, _kOut),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  final String label;
  final double amount;
  final double share;
  final Color color;
  const _BreakdownRow(
      {required this.label,
      required this.amount,
      required this.share,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 12.5),
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
          ),
          Text(fmtNum(amount),
              textDirection: TextDirection.ltr,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 12.5),
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary)),
          const SizedBox(width: 8),
          SizedBox(
            width: 40,
            child: Text('${(share * 100).toStringAsFixed(0)}%',
                textAlign: TextAlign.end,
                textDirection: TextDirection.ltr,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 10.5),
                    color: AppColors.textDisabled)),
          ),
        ]),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: share.clamp(0, 1).toDouble()),
            duration: const Duration(milliseconds: 700),
            curve: _kCurve,
            builder: (_, v, _) => LinearProgressIndicator(
                value: v,
                minHeight: 6,
                color: color,
                backgroundColor: color.withAlpha(26)),
          ),
        ),
      ]),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  Accounts
// ════════════════════════════════════════════════════════════
class _AccountsCard extends StatelessWidget {
  final BankCurrencyFigures figures;
  final int allCount;
  final bool showBalances;
  final double Function(double amount, String from) toWallet;
  final String walletCurrency;
  final String swapKey;
  final ValueChanged<String> onPickCurrency;

  const _AccountsCard({
    required this.figures,
    required this.allCount,
    required this.showBalances,
    required this.toWallet,
    required this.walletCurrency,
    required this.swapKey,
    required this.onPickCurrency,
  });

  static const _palette = [
    Color(0xFFB00020),
    Color(0xFF1565C0),
    Color(0xFF2E7D32),
    Color(0xFFE65100),
    Color(0xFF6A1B9A),
    Color(0xFF00838F),
    Color(0xFF8D6E63),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final share = <String, double>{};
    if (figures.isAll && showBalances && allCount > 1) {
      for (final a in figures.accounts) {
        share[a.currency] =
            (share[a.currency] ?? 0) + toWallet(a.balance, a.currency).abs();
      }
    }
    final shareTotal = share.values.fold<double>(0, (s, v) => s + v);
    final shareList = share.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(
              title: l10n.translate('bankAccountsTitle'),
              icon: TwoToneIcons.bank),
          const SizedBox(height: 12),
          AnimatedSize(
            duration: _kSwap,
            curve: _kCurve,
            alignment: Alignment.topCenter,
            child: _swap(
              swapKey,
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (shareTotal > 0) ...[
                    Text(l10n.translate('bdvCurrencyShare'),
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 12),
                            fontWeight: FontWeight.w700,
                            color: AppColors.textSecondary)),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        height: 12,
                        child: Row(children: [
                          for (var i = 0; i < shareList.length; i++)
                            Expanded(
                              flex: math.max(
                                  1,
                                  (shareList[i].value / shareTotal * 1000)
                                      .round()),
                              child: Container(
                                  color: _palette[i % _palette.length]),
                            ),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (var i = 0; i < shareList.length; i++)
                        InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => onPickCurrency(shareList[i].key),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceVariant,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                      color: _palette[i % _palette.length],
                                      shape: BoxShape.circle)),
                              const SizedBox(width: 6),
                              Text(
                                  '${currencyShort(shareList[i].key)}  ${(shareList[i].value / shareTotal * 100).toStringAsFixed(0)}%',
                                  style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: R.fontSize(context, 11),
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.textPrimary)),
                            ]),
                          ),
                        ),
                    ]),
                    const SizedBox(height: 14),
                  ],
                  for (final a in figures.accounts)
                    _AccountTile(account: a, showBalance: showBalances),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountTile extends StatelessWidget {
  final BankDetailAccount account;
  final bool showBalance;
  const _AccountTile({required this.account, required this.showBalance});

  @override
  Widget build(BuildContext context) {
    final flag = currencyFlagEmoji(account.currency);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(20),
              borderRadius: BorderRadius.circular(12)),
          alignment: Alignment.center,
          child: Text(flag.isEmpty ? currencyShort(account.currency) : flag,
              style: TextStyle(fontSize: flag.isEmpty ? 10 : 22)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${currencyShort(account.currency)} — ${account.typeLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
              Text(
                  (account.note ?? '').isNotEmpty
                      ? account.note!
                      : currencyName(account.currency),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 10.5),
                      color: AppColors.textDisabled)),
            ],
          ),
        ),
        if (showBalance)
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerEnd,
              child: Text(fmtNum(account.balance),
                  maxLines: 1,
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 15),
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary)),
            ),
          ),
      ]),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  Movements
// ════════════════════════════════════════════════════════════
class _DayHeader extends StatelessWidget {
  final DateTime? day;
  final double net;
  final String? currency;
  const _DayHeader({required this.day, required this.net, this.currency});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String label;
    final d = day;
    if (d == null) {
      label = '—';
    } else {
      final today = DateUtils.dateOnly(DateTime.now());
      if (d == today) {
        label = l10n.translate('today');
      } else if (d == today.subtract(const Duration(days: 1))) {
        label = l10n.translate('yesterday');
      } else {
        label = '${d.day} ${l10n.translate('month${d.month}')} ${d.year}';
      }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
      child: Row(children: [
        Text(label,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 12),
                fontWeight: FontWeight.w800,
                color: AppColors.textSecondary)),
        const SizedBox(width: 10),
        Expanded(child: Container(height: 1, color: AppColors.border)),
        if (currency != null) ...[
          const SizedBox(width: 10),
          Text('${net >= 0 ? '+' : '-'}${fmtNum(net.abs())}',
              textDirection: TextDirection.ltr,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 11),
                  fontWeight: FontWeight.w700,
                  color: net >= 0 ? _kIn : _kOut)),
        ],
      ]),
    );
  }
}

class _MovementTile extends StatelessWidget {
  final BankDetailMovement movement;
  const _MovementTile({required this.movement});

  @override
  Widget build(BuildContext context) {
    final m = movement;
    final subtitle = [
      if ((m.category ?? '').isNotEmpty) m.category!,
      if ((m.note ?? '').isNotEmpty) m.note!,
    ].join(' · ');
    final d = m.date;
    final time = d != null && (d.hour != 0 || d.minute != 0)
        ? '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}'
        : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border.withAlpha(140)),
      ),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
              color: m.color.withAlpha(26),
              borderRadius: BorderRadius.circular(13)),
          alignment: Alignment.center,
          child: TwoToneIcon(data: m.icon, size: 18, outlineColor: m.color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(m.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
              if (subtitle.isNotEmpty)
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11),
                        color: AppColors.textSecondary)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(
              '${m.isIn ? '+' : '-'}${fmtNum(m.amount.abs())} ${currencyShort(m.currency)}',
              textDirection: TextDirection.ltr,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 13.5),
                  fontWeight: FontWeight.w800,
                  color: m.color)),
          if (time != null)
            Text(time,
                textDirection: TextDirection.ltr,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 10),
                    color: AppColors.textDisabled)),
        ]),
      ]),
    );
  }
}

class _EmptyMovements extends StatelessWidget {
  final String swapKey;
  const _EmptyMovements({required this.swapKey});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _FadeSlideIn(
      key: ValueKey('empty|$swapKey'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 36, 16, 20),
        child: Column(children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
                color: AppColors.surfaceVariant, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: const TwoToneIcon(
                data: TwoToneIcons.receipt,
                size: 28,
                outlineColor: AppColors.textDisabled),
          ),
          const SizedBox(height: 12),
          Text(l10n.translate('noTransactions'),
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 14),
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary)),
          const SizedBox(height: 2),
          Text(l10n.translate('bdvNoMovements'),
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 11.5),
                  color: AppColors.textDisabled)),
        ]),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  Export sheet
// ════════════════════════════════════════════════════════════
class BankExportSheet extends StatefulWidget {
  final String bankName;
  final String period;
  final String selectedCurrency;
  final bool multiCurrency;

  const BankExportSheet({
    super.key,
    required this.bankName,
    required this.period,
    required this.selectedCurrency,
    required this.multiCurrency,
  });

  @override
  State<BankExportSheet> createState() => _BankExportSheetState();
}

class _BankExportSheetState extends State<BankExportSheet> {
  BankReportContent _content = BankReportContent.full;
  late bool _all = widget.selectedCurrency == kBankAllCurrencies;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final options = [
      (BankReportContent.full, 'bdvContentFull', 'bdvContentFullHint',
          TwoToneIcons.document),
      (BankReportContent.summary, 'bdvContentSummary', 'bdvContentSummaryHint',
          TwoToneIcons.chart),
      (BankReportContent.movements, 'bdvContentMovements',
          'bdvContentMovementsHint', TwoToneIcons.transfer),
      (BankReportContent.flow, 'bdvContentFlow', 'bdvContentFlowHint',
          TwoToneIcons.pieChart),
    ];
    final single = widget.selectedCurrency == kBankAllCurrencies
        ? null
        : widget.selectedCurrency;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(2))),
            ),
            const SizedBox(height: 16),
            Row(children: [
              AppIconBadge(
                  icon: TwoToneIcons.pdf.outline,
                  size: 42,
                  iconSize: 20,
                  accentColor: AppColors.primary,
                  backgroundColor: AppColors.primary.withAlpha(24),
                  borderColor: AppColors.primary.withAlpha(50)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.translate('bdvExportTitle'),
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 16),
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary)),
                    Text('${widget.bankName} · ${widget.period}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 11.5),
                            color: AppColors.textSecondary)),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 18),
            _label(context, l10n.translate('bdvExportContent')),
            const SizedBox(height: 8),
            for (var i = 0; i < options.length; i += 2)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(children: [
                  for (final o in options.sublist(i, i + 2)) ...[
                    if (o != options[i]) const SizedBox(width: 10),
                    Expanded(
                      child: _OptionCard(
                        selected: _content == o.$1,
                        title: l10n.translate(o.$2),
                        hint: l10n.translate(o.$3),
                        icon: o.$4,
                        onTap: () => setState(() => _content = o.$1),
                      ),
                    ),
                  ],
                ]),
              ),
            if (widget.multiCurrency) ...[
              const SizedBox(height: 6),
              _label(context, l10n.translate('bdvExportScope')),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                    color: AppColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(14)),
                child: Row(children: [
                  if (single != null)
                    _Segment(
                      selected: !_all,
                      text: l10n.translate('bdvScopeCurrency',
                          params: {'currency': currencyShort(single)}),
                      onTap: () => setState(() => _all = false),
                    ),
                  _Segment(
                    selected: _all || single == null,
                    text: l10n.translate('bdvScopeAll'),
                    onTap: () => setState(() => _all = true),
                  ),
                ]),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => Navigator.pop(
                    context,
                    BankReportRequest(
                        content: _content,
                        allCurrencies: _all || single == null)),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.picture_as_pdf_rounded,
                    color: Colors.white, size: 20),
                label: Text(l10n.translate('exportReport'),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 14),
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Text(text,
      style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: R.fontSize(context, 12.5),
          fontWeight: FontWeight.w700,
          color: AppColors.textSecondary));
}

class _OptionCard extends StatelessWidget {
  final bool selected;
  final String title;
  final String hint;
  final TwoToneIconData icon;
  final VoidCallback onTap;
  const _OptionCard(
      {required this.selected,
      required this.title,
      required this.hint,
      required this.icon,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: _kCurve,
        height: 104,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withAlpha(AppColors.isLightMode ? 20 : 36)
              : AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: selected ? AppColors.primary : AppColors.border,
              width: selected ? 1.6 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              TwoToneIcon(
                  data: icon,
                  size: 20,
                  outlineColor:
                      selected ? AppColors.primary : AppColors.textSecondary),
              const Spacer(),
              AnimatedScale(
                scale: selected ? 1 : 0,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutBack,
                child: const Icon(Icons.check_circle_rounded,
                    size: 18, color: AppColors.primary),
              ),
            ]),
            const Spacer(),
            Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary)),
            Text(hint,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 10),
                    height: 1.3,
                    color: AppColors.textDisabled)),
          ],
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  final bool selected;
  final String text;
  final VoidCallback onTap;
  const _Segment(
      {required this.selected, required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: _kCurve,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? AppColors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            boxShadow: selected
                ? [
                    BoxShadow(
                        color: Colors.black.withAlpha(24),
                        blurRadius: 8,
                        offset: const Offset(0, 2))
                  ]
                : const [],
          ),
          child: Text(text,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 11.5),
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected ? AppColors.primary : AppColors.textSecondary)),
        ),
      ),
    );
  }
}
