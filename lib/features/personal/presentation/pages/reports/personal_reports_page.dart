import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../../core/localization/app_localizations.dart';
import '../../../../../core/responsive/r_api.dart';
import '../../../../../core/router/route_names.dart';
import '../../../../../core/services/connectivity_service.dart';
import '../../../../../core/services/currency/currency_engine.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../shared/widgets/fyona_refresh.dart';
import '../../../../reports/presentation/widgets/report_widgets.dart';
import '../../providers/personal_providers.dart';
import 'personal_report_data.dart';
import 'personal_report_sections.dart';
import 'personal_report_source.dart';
import 'personal_report_widgets.dart';

/// Personal › التقارير: one currency + one period for every Personal report,
/// a live summary, and the reports themselves (each opens with its motion).
class PersonalReportsPage extends ConsumerStatefulWidget {
  const PersonalReportsPage({super.key});
  @override
  ConsumerState<PersonalReportsPage> createState() =>
      _PersonalReportsPageState();
}

class _PersonalReportsPageState extends ConsumerState<PersonalReportsPage> {
  String? _currency;
  String _period = 'month';
  DateTime? _from, _to;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      unawaited(PersonalReportSource.warm(ref));
      final saved = await PersonalReportSource.savedCurrency(ref);
      if (mounted && saved != null && saved.isNotEmpty) {
        setState(() => _currency = saved);
      }
    });
  }

  String get _ccy =>
      _currency ?? ref.read(personalFinanceProvider).walletCurrency;

  Future<void> _pickCurrency() async {
    // Only the currencies the user enabled for Personal (preferences).
    final enabled = await PersonalReportSource.enabled(ref);
    if (!mounted) return;
    final picked = await showPersonalReportCurrencyPicker(
      context,
      mine: [
        for (final c in PersonalReportSource.mine(ref))
          if (enabled.contains(c)) c,
      ],
      all: enabled,
      current: _ccy,
    );
    if (picked == null || picked == _ccy || !mounted) return;
    setState(() => _currency = picked);
    unawaited(PersonalReportSource.saveCurrency(ref, picked));
    if (ref.read(connectivityServiceProvider).isOnline) {
      unawaited(
        ref
            .read(currencyEngineProvider)
            .refreshIfStale(maxAge: const Duration(minutes: 30))
            .catchError((_) {}),
      );
    }
  }

  void _open(String kind) {
    final q = <String, String>{
      'kind': kind,
      'currency': _ccy,
      'period': _period,
      if (_period == 'custom' && _from != null) 'from': _day(_from!),
      if (_period == 'custom' && _to != null) 'to': _day(_to!),
    };
    context.push(
      Uri(path: RouteNames.personalReportsView, queryParameters: q).toString(),
    );
  }

  static String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    ref.watch(personalFinanceProvider);
    ref.watch(budgetProvider);
    ref.watch(rateSnapshotRevisionProvider);
    final window = PersonalReportWindow.of(
      _period,
      customFrom: _from,
      customTo: _to,
    );
    final data = PersonalReportSource.build(
      ref,
      currency: _ccy,
      window: window,
    );
    final s = PersonalReportSections(context, data);
    var i = 0;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          color: AppColors.textPrimary,
          onPressed: () => context.canPop()
              ? context.pop()
              : context.go(RouteNames.personalDashboard),
        ),
        title: Text(
          l10n.translate('reports'),
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 17),
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
        actions: [PrCurrencyChip(currency: _ccy, onTap: _pickCurrency)],
      ),
      body: SafeArea(
        child: FyonaRefresh(
          onRefresh: () => PersonalReportSource.warm(ref),
          color: AppColors.primary,
          backgroundColor: AppColors.surface,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
            children: [
              PrPeriodBar(
                period: _period,
                from: _from,
                to: _to,
                onChanged: (p, f, t) => setState(() {
                  _period = p;
                  _from = f;
                  _to = t;
                }),
              ),
              const SizedBox(height: 12),
              Center(
                child: Column(
                  children: [
                    Text(
                      l10n.translate('prepHow'),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 21),
                        fontWeight: FontWeight.w900,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      l10n.translate('prepHowHint'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 12),
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              PrEntrance(index: i++, child: s.netWorth()),
              const SizedBox(height: 12),
              PrEntrance(index: i++, child: s.kpiGrid()),
              const SizedBox(height: 18),
              PrEntrance(
                index: i++,
                child: Text(
                  l10n.translate('prepReportsList'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 15),
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              for (final kind in personalReportKinds) ...[
                PrEntrance(
                  index: i++,
                  child: ReportTileCard(
                    key: ValueKey('personal-report-$kind'),
                    title: l10n.translate(personalReportMeta(kind).title),
                    hint: l10n.translate(personalReportMeta(kind).hint),
                    kind: personalReportMeta(kind).art,
                    onTap: () => _open(kind),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              const SizedBox(height: 4),
              PrFxNote(data: data),
            ],
          ),
        ),
      ),
    );
  }
}
