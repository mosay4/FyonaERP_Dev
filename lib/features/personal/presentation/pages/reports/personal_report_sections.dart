import 'package:flutter/material.dart';

import '../../../../../core/localization/app_localizations.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/utils/currency_formatter.dart';
import '../../../../reports/presentation/widgets/report_widgets.dart';
import 'personal_report_data.dart';
import 'personal_report_widgets.dart';

/// Title/hint keys and icon of each Personal report kind.
({String title, String hint, ReportArtKind art}) personalReportMeta(
  String kind,
) => switch (kind) {
  'cashflow' => (
    title: 'prepKindCashflow',
    hint: 'prepKindCashflowHint',
    art: ReportArtKind.sales,
  ),
  'categories' => (
    title: 'prepKindCategories',
    hint: 'prepKindCategoriesHint',
    art: ReportArtKind.profit,
  ),
  'budgets' => (
    title: 'prepKindBudgets',
    hint: 'prepKindBudgetsHint',
    art: ReportArtKind.inventory,
  ),
  'goals' => (
    title: 'prepKindGoals',
    hint: 'prepKindGoalsHint',
    art: ReportArtKind.personal,
  ),
  'debts' => (
    title: 'prepKindDebts',
    hint: 'prepKindDebtsHint',
    art: ReportArtKind.debts,
  ),
  'banks' => (
    title: 'prepKindBanks',
    hint: 'prepKindBanksHint',
    art: ReportArtKind.money,
  ),
  _ => (
    title: 'prepKindOverview',
    hint: 'prepKindOverviewHint',
    art: ReportArtKind.overview,
  ),
};

/// Short label of a trend bucket.
String personalBucketLabel(
  AppLocalizations l10n,
  PersonalReportData data,
  DateTime d, {
  bool months = false,
}) {
  final days = data.window.days;
  if (months || days > 98) return l10n.translate('month${d.month}');
  return '${d.day}/${d.month}';
}

String personalPeriodLabel(AppLocalizations l10n, PersonalReportWindow w) {
  String day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  return switch (w.period) {
    'today' => l10n.translate('reconPeriodToday'),
    'week' => l10n.translate('reconPeriodWeek'),
    'year' => l10n.translate('reconPeriodYear'),
    'custom' =>
      '${day(w.from)} → ${day(w.to.subtract(const Duration(days: 1)))}',
    _ => l10n.translate('reconPeriodMonth'),
  };
}

/// Builds the on-screen sections of a Personal report kind. `overview`
/// stacks every section; the PDF is built from the same data object.
class PersonalReportSections {
  PersonalReportSections(this.context, this.data);
  final BuildContext context;
  final PersonalReportData data;

  AppLocalizations get l10n => AppLocalizations.of(context);
  String get ccy => data.currency;
  String money(double v) => prMoney(v, ccy);

  List<Widget> forKind(String kind) {
    final parts = switch (kind) {
      'cashflow' => [cashflow(full: true)],
      'categories' => [categories(full: true)],
      'budgets' => [budgets()],
      'goals' => [goals()],
      'debts' => [debts()],
      'banks' => [banks()],
      _ => [
        netWorth(),
        cashflow(full: false),
        categories(full: false),
        budgets(),
        goals(),
        debts(),
        banks(),
      ],
    };
    return [
      for (final p in parts) ...[p, const SizedBox(height: 14)],
      PrFxNote(data: data),
    ];
  }

  Widget _empty(String key) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Center(
      child: Text(
        l10n.translate(key),
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 12,
          color: AppColors.textSecondary,
        ),
      ),
    ),
  );

  // ─────────────────────────────────────────────── net worth (hero)

  Widget netWorth() {
    final lang = l10n.locale.languageCode;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: dark
              ? const [Color(0xFF5E1222), Color(0xFF2A1016)]
              : const [AppColors.primary, AppColors.primaryDark],
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withAlpha(dark ? 40 : 60),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.translate('prepNetWorth'),
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
              Text(
                personalPeriodLabel(l10n, data.window),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 11,
                  color: Colors.white.withAlpha(200),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ReportCountUp(
            end: data.netWorth,
            currency: currencyLabel(ccy, locale: lang),
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontSize: 28,
              fontWeight: FontWeight.w900,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _heroCell(l10n.translate('prepBalances'), data.balances),
              _heroCell(l10n.translate('prepOwedToMe'), data.owedToMe),
              _heroCell(l10n.translate('prepIOwe'), data.iOwe),
            ],
          ),
        ],
      ),
    );
  }

  Widget _heroCell(String label, double v) => Expanded(
    child: Container(
      margin: const EdgeInsetsDirectional.only(end: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(30),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 10,
              color: Colors.white.withAlpha(210),
            ),
          ),
          ReportFitText(
            text: fmtNum(v),
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontSize: 13.5,
              fontWeight: FontWeight.w900,
              color: Colors.white,
            ),
          ),
        ],
      ),
    ),
  );

  // ─────────────────────────────────────────────── income & spending

  Widget kpiGrid() {
    Widget pair(Widget a, Widget b) => Row(
      children: [
        Expanded(child: a),
        const SizedBox(width: 10),
        Expanded(child: b),
      ],
    );
    return Column(
      children: [
        pair(
          PrKpi(
            label: l10n.translate('prepIncome'),
            value: data.income,
            currency: ccy,
            color: personalIncomeColor,
            icon: Icons.south_west_rounded,
          ),
          PrKpi(
            label: l10n.translate('prepSpending'),
            value: data.spending,
            currency: ccy,
            color: personalSpendColor,
            icon: Icons.north_east_rounded,
          ),
        ),
        const SizedBox(height: 10),
        pair(
          PrKpi(
            label: l10n.translate('prepNet'),
            value: data.net,
            currency: ccy,
            color: data.net >= 0 ? AppColors.textPrimary : AppColors.danger,
            icon: Icons.account_balance_wallet_outlined,
          ),
          PrKpi(
            label: l10n.translate('prepSavingsRate'),
            value: data.savingsRate,
            currency: '',
            percent: true,
            color: data.savingsRate >= .2
                ? personalIncomeColor
                : (data.savingsRate >= 0
                      ? AppColors.warning
                      : AppColors.danger),
            icon: Icons.savings_outlined,
          ),
        ),
      ],
    );
  }

  Widget cashflow({required bool full}) {
    final useWindow = data.buckets.length >= 2 && data.buckets.length <= 31;
    return Column(
      children: [
        kpiGrid(),
        const SizedBox(height: 14),
        PrCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PrSectionTitle(
                Icons.bar_chart_rounded,
                l10n.translate('prepTrend'),
                trailing: useWindow
                    ? personalPeriodLabel(l10n, data.window)
                    : l10n.translate('prepSixMonths'),
              ),
              PrDualBars(
                buckets: useWindow ? data.buckets : data.months,
                labelOf: (d) =>
                    personalBucketLabel(l10n, data, d, months: !useWindow),
                incomeLabel: l10n.translate('prepIncome'),
                spendLabel: l10n.translate('prepSpending'),
              ),
              if (data.transfers > 0) ...[
                const SizedBox(height: 10),
                Text(
                  l10n.translate(
                    'prepTransfersNote',
                    params: {'n': '${data.transfers}'},
                  ),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 10.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (full && useWindow) ...[
          const SizedBox(height: 14),
          PrCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PrSectionTitle(
                  Icons.calendar_month_rounded,
                  l10n.translate('prepSixMonths'),
                ),
                PrDualBars(
                  buckets: data.months,
                  height: 140,
                  labelOf: (d) =>
                      personalBucketLabel(l10n, data, d, months: true),
                  incomeLabel: l10n.translate('prepIncome'),
                  spendLabel: l10n.translate('prepSpending'),
                ),
              ],
            ),
          ),
        ],
        if (full && data.incomeSources.isNotEmpty) ...[
          const SizedBox(height: 14),
          PrCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PrSectionTitle(
                  Icons.south_west_rounded,
                  l10n.translate('prepIncomeSources'),
                ),
                for (final s in data.incomeSources.take(6))
                  PrRow(
                    title: s.label,
                    subtitle: l10n.translate(
                      'prepOps',
                      params: {'n': '${s.count}'},
                    ),
                    value: money(s.amount),
                    valueColor: personalIncomeColor,
                    bottom: PrBar(
                      value: data.income > 0 ? s.amount / data.income : 0,
                      color: personalIncomeColor,
                      height: 5,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // ─────────────────────────────────────────────── categories

  Widget categories({required bool full}) => PrCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PrSectionTitle(
          Icons.donut_large_rounded,
          l10n.translate('prepKindCategories'),
        ),
        if (data.categories.isEmpty)
          _empty('prepEmpty')
        else
          PrDonut(
            slices: data.categories,
            currency: ccy,
            centerLabel: l10n.translate('prepSpending'),
            otherLabel: l10n.translate('repExpenseOther'),
            maxSlices: full ? 7 : 5,
          ),
        if (full && data.topExpenses.isNotEmpty) ...[
          const SizedBox(height: 12),
          Divider(color: AppColors.border, height: 1),
          const SizedBox(height: 10),
          PrSectionTitle(
            Icons.receipt_long_rounded,
            l10n.translate('prepTopExpenses'),
          ),
          for (final e in data.topExpenses)
            PrRow(
              title: e.description.isEmpty ? e.category : e.description,
              subtitle:
                  '${e.category} • ${e.date.day}/${e.date.month}/${e.date.year}'
                  '${e.originalCurrency != ccy ? ' • ${prMoney(e.originalAmount, e.originalCurrency)}' : ''}',
              value: money(e.amount),
              valueColor: personalSpendColor,
            ),
        ],
      ],
    ),
  );

  // ─────────────────────────────────────────────── budgets

  Widget budgets() => PrCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PrSectionTitle(
          Icons.pie_chart_outline_rounded,
          l10n.translate('prepKindBudgets'),
          trailing: data.budgets.isEmpty
              ? null
              : prPercent(
                  data.budgetsTotal > 0
                      ? data.budgetsSpent / data.budgetsTotal
                      : 0,
                ),
        ),
        if (data.budgets.isEmpty)
          _empty('prepNoBudgets')
        else
          for (final b in data.budgets)
            PrRow(
              title: b.name,
              subtitle:
                  '${b.period} • ${b.over ? l10n.translate('prepOverBudget') : l10n.translate('prepBudgetLeft', params: {'v': money(b.remaining)})}',
              value: prPercent(b.usage),
              valueColor: b.over
                  ? AppColors.danger
                  : (b.usage >= .8 ? AppColors.warning : personalIncomeColor),
              bottom: Column(
                children: [
                  PrGrow(
                    trigger: Object.hash(b.spent, ccy),
                    builder: (_, v) => PrBar(
                      value: b.usage * v,
                      color: b.over
                          ? AppColors.danger
                          : (b.usage >= .8
                                ? AppColors.warning
                                : personalIncomeColor),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      l10n.translate(
                        'prepBudgetUsed',
                        params: {
                          'spent': money(b.spent),
                          'total': money(b.total),
                        },
                      ),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 10.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
      ],
    ),
  );

  // ─────────────────────────────────────────────── goals

  Widget goals() => PrCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PrSectionTitle(
          Icons.savings_outlined,
          l10n.translate('prepKindGoals'),
          trailing: data.goals.isEmpty
              ? null
              : prPercent(
                  data.goalsTarget > 0 ? data.goalsSaved / data.goalsTarget : 0,
                ),
        ),
        if (data.goals.isEmpty)
          _empty('prepNoGoals')
        else
          for (final g in data.goals)
            PrRow(
              title: g.name,
              subtitle: g.completed
                  ? l10n.translate('prepGoalDone')
                  : l10n.translate(
                      'prepGoalLeft',
                      params: {'v': money(g.remaining)},
                    ),
              value: prPercent(g.progress),
              valueColor: g.completed ? personalIncomeColor : AppColors.primary,
              leading: SizedBox(
                width: 40,
                height: 40,
                child: PrGrow(
                  trigger: Object.hash(g.saved, ccy),
                  builder: (_, v) => CircularProgressIndicator(
                    value: g.progress * v,
                    strokeWidth: 4.5,
                    backgroundColor: AppColors.border.withAlpha(110),
                    color: g.completed
                        ? personalIncomeColor
                        : AppColors.primary,
                  ),
                ),
              ),
              bottom: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  '${l10n.translate('prepGoalsSaved')}: ${money(g.saved)}  •  ${l10n.translate('prepGoalsTarget')}: ${money(g.target)}',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 10.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ),
      ],
    ),
  );

  // ─────────────────────────────────────────────── debts

  Widget debts() {
    final total = data.owedToMe + data.iOwe;
    return PrCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PrSectionTitle(
            Icons.handshake_outlined,
            l10n.translate('prepKindDebts'),
            trailing: data.overdueDebts > 0
                ? l10n.translate(
                    'prepOverdueCount',
                    params: {'n': '${data.overdueDebts}'},
                  )
                : null,
          ),
          if (data.debts.isEmpty)
            _empty('prepNoDebts')
          else ...[
            Row(
              children: [
                Expanded(
                  child: _split(
                    l10n.translate('prepOwedToMe'),
                    data.owedToMe,
                    personalIncomeColor,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _split(
                    l10n.translate('prepIOwe'),
                    data.iOwe,
                    AppColors.danger,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            PrGrow(
              trigger: Object.hash(total, ccy),
              builder: (_, v) => ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  height: 10,
                  child: Row(
                    children: [
                      Expanded(
                        flex: (1000 * (total > 0 ? data.owedToMe / total : .5))
                            .round()
                            .clamp(1, 1000),
                        child: Container(
                          color: personalIncomeColor.withValues(
                            alpha: .25 + .75 * v,
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      Expanded(
                        flex: (1000 * (total > 0 ? data.iOwe / total : .5))
                            .round()
                            .clamp(1, 1000),
                        child: Container(
                          color: AppColors.danger.withValues(
                            alpha: .25 + .75 * v,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            for (final d in data.debts.take(8))
              PrRow(
                title: d.person,
                subtitle: [
                  d.owedToMe
                      ? l10n.translate('prepOwedToMe')
                      : l10n.translate('prepIOwe'),
                  if (d.dueDate != null)
                    '${d.dueDate!.day}/${d.dueDate!.month}/${d.dueDate!.year}',
                  if (d.overdue) l10n.translate('prepOverdue'),
                ].join(' • '),
                value: money(d.remaining),
                valueColor: d.owedToMe ? personalIncomeColor : AppColors.danger,
                bottom: PrBar(
                  value: d.progress,
                  color: d.owedToMe ? personalIncomeColor : AppColors.danger,
                  height: 4,
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _split(String label, double v, Color color) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: color.withAlpha(18),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary,
          ),
        ),
        ReportCountUp(
          end: v,
          currency: currencyShort(ccy),
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 16,
            fontWeight: FontWeight.w900,
            color: color,
          ),
        ),
      ],
    ),
  );

  // ─────────────────────────────────────────────── banks

  Widget banks() => PrCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PrSectionTitle(
          Icons.account_balance_outlined,
          l10n.translate('prepKindBanks'),
          trailing: data.banks.isEmpty ? null : money(data.balances),
        ),
        if (data.banks.isEmpty)
          _empty('prepNoBanks')
        else ...[
          if (data.balancesByCurrency.length > 1) ...[
            PrDonut(
              slices: [
                for (final s in data.balancesByCurrency)
                  PersonalReportSlice(
                    currencyLabel(s.label, locale: l10n.locale.languageCode),
                    s.amount < 0 ? 0 : s.amount,
                    s.count,
                  ),
              ],
              currency: ccy,
              centerLabel: l10n.translate('prepBalances'),
              otherLabel: l10n.translate('repExpenseOther'),
            ),
            const SizedBox(height: 8),
            Divider(color: AppColors.border, height: 1),
          ],
          for (final b in data.banks)
            PrRow(
              leading: Text(
                currencyFlagEmoji(b.currency).isEmpty
                    ? '¤'
                    : currencyFlagEmoji(b.currency),
                style: const TextStyle(fontSize: 20),
              ),
              title: b.name,
              subtitle: b.currency == ccy
                  ? currencyShort(b.currency)
                  : prMoney(b.balance, b.currency),
              value: b.converted == null
                  ? l10n.translate('prepNoRate')
                  : money(b.converted!),
              valueColor: b.converted == null
                  ? AppColors.warning
                  : ((b.converted ?? 0) < 0
                        ? AppColors.danger
                        : AppColors.textPrimary),
            ),
        ],
      ],
    ),
  );
}
