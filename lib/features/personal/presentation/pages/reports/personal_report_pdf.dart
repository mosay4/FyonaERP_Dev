import 'dart:typed_data';

import '../../../../../core/localization/app_localizations.dart';
import '../../../../../core/pdf_engine.dart';
import '../../../../../core/utils/currency_formatter.dart';
import 'personal_report_data.dart';
import 'personal_report_sections.dart';
import 'personal_report_widgets.dart';
import '../../../../../core/utils/time_format.dart';

/// The Personal report PDF: the same [PersonalReportData] the screen shows
/// (same currency, period and conversions), laid out with the shared report
/// template (meta, KPI cards, visuals, tables).
class PersonalReportPdf {
  PersonalReportPdf._();

  static Future<Uint8List> build({
    required PersonalReportData data,
    required String kind,
    required AppLocalizations l10n,
    String? owner,
  }) {
    final isAr = l10n.locale.languageCode == 'ar';
    final ccy = data.currency;
    String m(double v) => prMoney(v, ccy);
    String t(String k, [Map<String, dynamic>? p]) =>
        l10n.translate(k, params: p);
    final all = kind == 'overview';
    bool has(String k) => all || kind == k;
    final meta = personalReportMeta(kind);
    final period = personalPeriodLabel(l10n, data.window);
    String day(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    // ── KPI cards
    final kpis = <Map<String, String>>[
      if (all || kind == 'banks' || kind == 'debts')
        {
          'label': t('prepNetWorth'),
          'value': m(data.netWorth),
          'tone': 'brand',
        },
      if (has('cashflow') || kind == 'categories') ...[
        {'label': t('prepIncome'), 'value': m(data.income), 'tone': 'in'},
        {'label': t('prepSpending'), 'value': m(data.spending), 'tone': 'out'},
      ],
      if (has('cashflow')) ...[
        {'label': t('prepNet'), 'value': m(data.net), 'tone': 'info'},
        {
          'label': t('prepSavingsRate'),
          'value': prPercent(data.savingsRate),
          'tone': 'amber',
        },
      ],
      if (kind == 'categories')
        {
          'label': t('prepAvgDaily'),
          'value': m(data.dailySpending),
          'tone': 'slate',
        },
      if (kind == 'budgets') ...[
        {
          'label': t('prepColBudget'),
          'value': m(data.budgetsTotal),
          'tone': 'info',
        },
        {
          'label': t('prepColSpent'),
          'value': m(data.budgetsSpent),
          'tone': 'out',
        },
      ],
      if (kind == 'goals') ...[
        {
          'label': t('prepGoalsSaved'),
          'value': m(data.goalsSaved),
          'tone': 'in',
        },
        {
          'label': t('prepGoalsTarget'),
          'value': m(data.goalsTarget),
          'tone': 'brand',
        },
      ],
      if (has('debts')) ...[
        {'label': t('prepOwedToMe'), 'value': m(data.owedToMe), 'tone': 'in'},
        {'label': t('prepIOwe'), 'value': m(data.iOwe), 'tone': 'out'},
      ],
      if (kind == 'banks' || all)
        {
          'label': t('prepBalances'),
          'value': m(data.balances),
          'tone': 'slate',
        },
    ];

    // ── visuals
    final charts = <ReportPdfChart>[];
    if (has('cashflow') && (data.income > 0 || data.spending > 0)) {
      charts.add(
        ReportPdfChart(
          title: t('prepKindCashflow'),
          ratio: true,
          bars: [
            ReportPdfBar(
              t('prepIncome'),
              data.income,
              m(data.income),
              tone: 'in',
            ),
            ReportPdfBar(
              t('prepSpending'),
              data.spending,
              m(data.spending),
              tone: 'out',
            ),
            if (data.toGoals > 0)
              ReportPdfBar(
                t('prepToGoals'),
                data.toGoals,
                m(data.toGoals),
                tone: 'amber',
              ),
          ],
        ),
      );
    }
    if (has('categories') && data.categories.isNotEmpty) {
      final top = data.categories.take(6).toList();
      charts.add(
        ReportPdfChart(
          title: t('prepKindCategories'),
          bars: [
            for (var i = 0; i < top.length; i++)
              ReportPdfBar(
                top[i].label,
                top[i].amount,
                m(top[i].amount),
                tone: personalReportPdfTones[i % personalReportPdfTones.length],
              ),
          ],
        ),
      );
    }
    if (has('cashflow') && data.months.any((b) => b.spending > 0)) {
      charts.add(
        ReportPdfChart(
          title: '${t('prepSpending')} — ${t('prepSixMonths')}',
          singleTone: true,
          bars: [
            for (final b in data.months)
              ReportPdfBar(
                t('month${b.start.month}'),
                b.spending,
                m(b.spending),
                tone: 'out',
              ),
          ],
        ),
      );
    }
    if (has('debts') && data.debts.isNotEmpty) {
      charts.add(
        ReportPdfChart(
          title: t('prepKindDebts'),
          ratio: true,
          bars: [
            ReportPdfBar(
              t('prepOwedToMe'),
              data.owedToMe,
              m(data.owedToMe),
              tone: 'in',
            ),
            ReportPdfBar(t('prepIOwe'), data.iOwe, m(data.iOwe), tone: 'out'),
          ],
        ),
      );
    }
    if (has('banks') && data.balancesByCurrency.length > 1) {
      charts.add(
        ReportPdfChart(
          title: t('prepByCurrency'),
          ratio: true,
          bars: [
            for (final s in data.balancesByCurrency)
              ReportPdfBar(
                currencyLabel(s.label, locale: l10n.locale.languageCode),
                s.amount < 0 ? 0 : s.amount,
                m(s.amount),
              ),
          ],
        ),
      );
    }
    if (has('goals') && data.goals.isNotEmpty) {
      charts.add(
        ReportPdfChart(
          title: t('prepKindGoals'),
          singleTone: true,
          bars: [
            for (final g in data.goals.take(6))
              ReportPdfBar(
                g.name,
                g.progress * 100,
                prPercent(g.progress),
                tone: 'in',
              ),
          ],
        ),
      );
    }

    // ── tables
    final sections = <ReportPdfSection>[];
    if (has('cashflow')) {
      final buckets = data.buckets.length >= 2 && data.buckets.length <= 31
          ? data.buckets
          : data.months;
      final months = !identical(buckets, data.buckets);
      sections.add(
        ReportPdfSection(
          title: t('prepTrend'),
          headers: [
            t('prepColPeriod'),
            t('prepColIncome'),
            t('prepColSpending'),
          ],
          rows: [
            for (final b in buckets)
              if (b.income != 0 || b.spending != 0)
                [
                  months ? t('month${b.start.month}') : day(b.start),
                  m(b.income),
                  m(b.spending),
                ],
          ],
        ),
      );
      sections.add(
        ReportPdfSection(
          title: t('prepIncomeSources'),
          headers: [
            t('prepColCategory'),
            t('prepColCount'),
            t('prepColAmount'),
          ],
          rows: [
            for (final s in data.incomeSources)
              [s.label, '${s.count}', m(s.amount)],
          ],
        ),
      );
    }
    if (has('categories')) {
      sections.add(
        ReportPdfSection(
          title: t('prepKindCategories'),
          headers: [
            t('prepColCategory'),
            t('prepColCount'),
            t('prepColShare'),
            t('prepColAmount'),
          ],
          rows: [
            for (final s in data.categories)
              [
                s.label,
                '${s.count}',
                prPercent(data.spending > 0 ? s.amount / data.spending : 0),
                m(s.amount),
              ],
          ],
        ),
      );
      sections.add(
        ReportPdfSection(
          title: t('prepTopExpenses'),
          headers: [
            t('prepColDate'),
            t('prepColCategory'),
            t('prepColOriginal'),
            t('prepColAmount'),
          ],
          rows: [
            for (final e in data.topExpenses)
              [
                day(e.date),
                e.description.isEmpty
                    ? e.category
                    : '${e.category} — ${e.description}',
                prMoney(e.originalAmount, e.originalCurrency),
                m(e.amount),
              ],
          ],
        ),
      );
    }
    if (has('budgets')) {
      sections.add(
        ReportPdfSection(
          title: t('prepKindBudgets'),
          headers: [
            t('prepColName'),
            t('prepColPeriod'),
            t('prepColBudget'),
            t('prepColSpent'),
            t('prepColUsage'),
          ],
          rows: [
            for (final b in data.budgets)
              [b.name, b.period, m(b.total), m(b.spent), prPercent(b.usage)],
          ],
        ),
      );
    }
    if (has('goals')) {
      sections.add(
        ReportPdfSection(
          title: t('prepKindGoals'),
          headers: [
            t('prepColName'),
            t('prepColSaved'),
            t('prepColTarget'),
            t('prepColProgress'),
          ],
          rows: [
            for (final g in data.goals)
              [g.name, m(g.saved), m(g.target), prPercent(g.progress)],
          ],
        ),
      );
    }
    if (has('debts')) {
      sections.add(
        ReportPdfSection(
          title: t('prepKindDebts'),
          headers: [
            t('prepColPerson'),
            t('prepColType'),
            t('prepColDue'),
            t('prepColRemaining'),
          ],
          rows: [
            for (final d in data.debts)
              [
                d.person,
                d.owedToMe ? t('prepOwedToMe') : t('prepIOwe'),
                d.dueDate == null
                    ? '—'
                    : '${day(d.dueDate!)}${d.overdue ? ' • ${t('prepOverdue')}' : ''}',
                m(d.remaining),
              ],
          ],
        ),
      );
    }
    if (has('banks')) {
      sections.add(
        ReportPdfSection(
          title: t('prepKindBanks'),
          headers: [
            t('prepColBank'),
            t('prepColBalance'),
            t('prepColConverted'),
          ],
          rows: [
            for (final b in data.banks)
              [
                b.name,
                prMoney(b.balance, b.currency),
                b.converted == null ? t('prepNoRate') : m(b.converted!),
              ],
          ],
        ),
      );
    }

    final basis = t('prepConverted', {
      'c': currencyLabel(ccy, locale: l10n.locale.languageCode),
    });
    final missing = data.unconvertedCount == 0
        ? null
        : t('prepUnconverted', {
            'n': '${data.unconvertedCount}',
            'codes': data.unconverted.keys.map(currencyShort).join('، '),
            't': currencyShort(ccy),
          });
    final now = DateTime.now();
    final issued =
        '${day(now)} ${formatClock(now)}';
    final title = kind == 'overview'
        ? t('prepPdfTitle')
        : '${t('prepPdfTitle')} — ${t(meta.title)}';
    return PdfEngine.generateReportPdf(
      title: title,
      subtitleParts: [period, '${t('repPdfCurrency')}: ${currencyShort(ccy)}'],
      footerParts: [basis],
      headers: const [],
      rows: const [],
      kpis: kpis,
      charts: charts,
      sections: sections,
      isAr: isAr,
      meta: [
        (t('repPeriod'), period),
        (
          t('repPdfCurrency'),
          currencyLabel(ccy, locale: l10n.locale.languageCode),
        ),
        if (owner != null && owner.trim().isNotEmpty)
          (t('prepPdfOwner'), owner),
        (t('prepPdfPeriodOps'), '${data.operations}'),
        (t('bdvPdfIssued'), issued),
      ],
      kpiTitle: t('repPdfKpis'),
      chartsTitle: t('repPdfVisuals'),
      notes: [basis, ?missing].join('\n'),
    );
  }
}
