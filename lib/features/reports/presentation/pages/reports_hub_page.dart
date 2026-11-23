import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/material.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/services/currency/enabled_currencies_service.dart';
import '../../../../core/services/currency/business_currency_scope.dart'
    show loadBizEnabledCurrencies;
import '../../../../shared/providers/current_user_provider.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../data/reports_api.dart';
import '../../data/report_request_guard.dart';
import '../../data/business_report_rates.dart';
import '../../../branches/data/branch_epoch.dart';
import '../../../core_business/presentation/providers/business_ledger_session.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../widgets/report_integrity_card.dart';
import '../widgets/report_widgets.dart';

/// «كيف شغلك؟» — the reports hub: 4 real KPIs + one honest main chart +
/// exactly five report cards. Popular merchant language, premium visuals.
class ReportsHubPage extends ConsumerStatefulWidget {
  const ReportsHubPage({super.key});

  @override
  ConsumerState<ReportsHubPage> createState() => _ReportsHubPageState();
}

class _ReportsHubPageState extends ConsumerState<ReportsHubPage> {
  String _period = 'month';
  DateTime? _from;
  DateTime? _to;
  String _currency = 'USD';
  Map<String, dynamic>? _home;
  BusinessReportsApi? _homeSource;
  bool _loading = true;
  bool _refreshing = false;
  final _requests = ReportRequestGuard();
  Object? _loadError;
  List<String> _currencies = const ['USD'];

  @override
  void initState() {
    super.initState();
    ref.listenManual(branchEpochProvider, (_, __) {
      _requests.invalidate();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    });
    ref.listenManual(businessReportsApiProvider, (before, after) {
      if (before == null || before!.scopeKey == after.scopeKey) return;
      _requests.invalidate();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    });
    for (final kind in ['home', 'debts', 'money', 'sales', 'inventory']) {
      ref.listenManual(localReportAllowedProvider(kind), (_, __) {
        if (ref.read(businessReportsApiProvider).isDeviceLedger) {
          if (kind == 'home') {
            _requests.invalidate();
            _homeSource = null;
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (kind == 'home') {
              _load();
            } else {
              _loadCurrencies();
            }
          });
        }
      });
    }
    for (final revision in [
      businessBankRevisionProvider,
      businessOperationsRevisionProvider,
    ]) {
      ref.listenManual(revision, (_, __) {
        if (ref.read(businessReportsApiProvider).isDeviceLedger) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _load();
          });
        }
      });
    }
    ref.listenManual(rateSnapshotRevisionProvider, (_, __) {
      if (_loadError != null && BusinessReportsApi.ratesPending(_loadError!)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _load();
        });
      }
    });
    ref.listenManual(businessReportRateRevisionProvider, (_, _) {
      if (ref.read(businessReportsApiProvider).isDeviceLedger) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _load();
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      }
    });
    _load(initial: true);
    _restoreCurrency();
  }

  String get _currencyPrefKey {
    final id = ref.read(currentUserIdProvider);
    return 'report_currency_${id.isEmpty ? 'anonymous' : id}';
  }

  Future<void> _restoreCurrency() async {
    String? saved;
    try {
      saved = (await SharedPreferences.getInstance()).getString(
        _currencyPrefKey,
      );
    } catch (_) {}
    if (!mounted || saved == null || saved.isEmpty || saved == _currency)
      return;
    setState(() => _currency = saved!);
    _load();
  }

  (String?, String?) _bounds() {
    final now = DateTime.now();
    switch (_period) {
      case 'today':
        final d = now.toIso8601String().split('T').first;
        return (d, d);
      case 'week':
        final f = now.subtract(const Duration(days: 7));
        return (f.toIso8601String().split('T').first, null);
      case 'month':
        return (
          DateTime(now.year, now.month).toIso8601String().split('T').first,
          null,
        );
      case 'year':
        return (DateTime(now.year).toIso8601String().split('T').first, null);
      case 'custom':
        return (
          _from?.toIso8601String().split('T').first,
          _to?.toIso8601String().split('T').first,
        );
      default:
        return (null, null);
    }
  }

  Future<void> _load({bool initial = false}) async {
    final api = ref.read(businessReportsApiProvider);
    final local = api.isDeviceLedger;
    final allowed = local
        ? ref.read(localReportAllowedProvider('home'))
        : ref.read(employeeReportCanProvider('home'));
    if (local && (!identical(_homeSource, api) || !allowed)) {
      _enabledSet = {};
      _currencies = [_currency];
    }
    if (!allowed) {
      _requests.invalidate();
      setState(() {
        _loading = false;
        _refreshing = false;
        _home = null;
        _homeSource = null;
        _loadError = null;
      });
      if (local) unawaited(_loadCurrencies());
      return;
    }
    final ticket = _requests.begin();
    _loadError = null;
    if (!initial) setState(() => _refreshing = true);
    // Enabled currencies load in the background — never block the numbers.
    unawaited(_loadCurrencies());
    final (f, t) = _bounds();
    bool current() =>
        mounted &&
        _requests.accepts(ticket) &&
        identical(api, ref.read(businessReportsApiProvider)) &&
        (!local || ref.read(localReportAllowedProvider('home')));
    try {
      final home = await api.home(f, t, _currency);
      if (current()) {
        setState(() {
          _home = home;
          _homeSource = api;
          _loading = false;
          _refreshing = false;
        });
        _applyCurrencyMerge();
      }
    } catch (e) {
      if (current()) {
        setState(() {
          _loading = false;
          _refreshing = false;
          _home = null;
          _homeSource = null;
          _loadError = e;
        });
        if (!local) {
          final msg = BusinessReportsApi.serverMessage(e);
          showFyonaSnack(
            context,
            msg.isNotEmpty ? msg : l10nOf(context).translate('repFailed'),
            success: false,
          );
        }
      }
    }
  }

  Set<String> _enabledSet = {};

  void _applyCurrencyMerge() {
    // The picker lists the app's OWN currencies: the user's enabled set
    // UNION the currencies that really exist in this business (accounts +
    // invoices + expenses, served by the backend) — never a fixed four.
    final server = ((_home?['currencies'] as List?) ?? const [])
        .whereType<String>()
        .map((c) => c.trim().toUpperCase())
        .where((c) => c.isNotEmpty)
        .toSet();
    final merged = {..._enabledSet, ...server, _currency};
    final list = merged.where((c) => c.trim().isNotEmpty).toList()..sort();
    if (!mounted || list.isEmpty) return;
    setState(() {
      _currencies = list;
    });
  }

  Future<void> _loadCurrencies() async {
    final scope = BusinessReportsApi.scopeIdentity;
    final api = ref.read(businessReportsApiProvider);
    final ticket = ++_currencyRequest;
    try {
      final local = api.deviceScope;
      final enabled = local == null
          ? await ref.read(enabledCurrenciesProvider.future)
          : {
              ...await loadBizEnabledCurrencies(local.workspace.accountId),
              if (mounted) ...await api.deviceCurrencies(),
            };
      if (!mounted ||
          ticket != _currencyRequest ||
          scope != BusinessReportsApi.scopeIdentity ||
          !identical(api, ref.read(businessReportsApiProvider)))
        return;
      _enabledSet = enabled
          .map((c) => c.trim().toUpperCase())
          .where((c) => c.isNotEmpty)
          .toSet();
      _applyCurrencyMerge();
    } catch (_) {}
  }

  int _currencyRequest = 0;

  AppLocalizations l10nOf(BuildContext c) => AppLocalizations.of(c);

  /// Small confirm box OVER the hub (not a separate page): the report name,
  /// its period + currency, then «عرض التقرير» / «إلغاء». Confirm opens the
  /// report with the cinematic starting immediately.
  Future<void> _confirmAndOpen(
    BuildContext cardContext,
    String kind,
    String title,
  ) async {
    final source = ref.read(businessReportsApiProvider);
    final l10n = AppLocalizations.of(cardContext);
    final (f, t) = _bounds();
    final periodLabel = switch (_period) {
      'today' => l10n.translate('reconPeriodToday'),
      'week' => l10n.translate('reconPeriodWeek'),
      'year' => l10n.translate('reconPeriodYear'),
      'custom' => '${f ?? ''} → ${t ?? ''}',
      _ => l10n.translate('reconPeriodMonth'),
    };
    final ok = await showDialog<bool>(
      context: cardContext,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          decoration: BoxDecoration(
            color: Theme.of(ctx).brightness == Brightness.dark
                ? const Color(0xFF1C1C1E)
                : Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.primary.withAlpha(70)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.auto_awesome_rounded,
                size: 30,
                color: AppColors.primary,
              ),
              const SizedBox(height: 8),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                '$periodLabel • ${currencyLabel(_currency, locale: l10n.locale.languageCode)}',
                maxLines: 1,
                overflow: TextOverflow.visible,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 11.5,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 42,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          side: BorderSide(color: AppColors.border),
                        ),
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(
                          l10n.translate('cancel'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 42,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(
                          l10n.translate('repViewReport'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (ok == true &&
        mounted &&
        cardContext.mounted &&
        identical(source, ref.read(businessReportsApiProvider))) {
      // ignore: use_build_context_synchronously
      unawaited(cardContext.push(_viewRoute(kind, autoStart: true)));
    }
  }

  /// Report URL carrying the hub's SINGLE currency + period choice, so every
  /// sub-report (and its PDF) uses the same basis without asking again.
  String _viewRoute(String kind, {bool autoStart = false}) {
    final (f, t) = _bounds();
    final sb = StringBuffer('${RouteNames.reportsView}?kind=$kind');
    sb.write('&currency=$_currency&period=$_period');
    if (autoStart) sb.write('&autostart=1');
    if (f != null) sb.write('&from=$f');
    if (t != null) sb.write('&to=$t');
    return sb.toString();
  }

  Future<void> _pickCurrency() async {
    final picked = await showReportCurrencyPicker(
      context,
      _currencies,
      _currency,
    );
    if (picked == null || picked == _currency || !mounted) return;
    setState(() => _currency = picked);
    try {
      await (await SharedPreferences.getInstance()).setString(
        _currencyPrefKey,
        picked,
      );
    } catch (_) {}
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final source = ref.watch(businessReportsApiProvider);
    final local = source.isDeviceLedger;
    if (local) ref.watch(businessReportRateWarmupProvider);
    final canRead = local
        ? ref.watch(localReportAllowedProvider('home'))
        : ref.watch(employeeReportCanProvider('home'));
    final home = canRead && identical(source, _homeSource) ? _home : null;
    final kpis = home?['kpis'] as Map?;
    final chart = home?['chart'] is List
        ? (home!['chart'] as List).whereType<Map>().toList()
        : <Map>[];
    final comparison = home?['comparison'] as Map?;
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
          onPressed: () => context.pop(),
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
        actions: [
          // Report currency — a real financial choice, always visible.
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 12),
            child: Center(
              child: GestureDetector(
                onTap: _pickCurrency,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(20),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.primary.withAlpha(90)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.currency_exchange_rounded,
                        size: 14,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 5),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 138),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            currencyLabel(
                              _currency,
                              locale: l10n.locale.languageCode,
                            ),
                            maxLines: 1,
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && !local
            ? const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              )
            : refreshReport(
                local: local,
                onRefresh: () async => _load(),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  children: [
                    _periodBar(l10n),
                    const SizedBox(height: 14),
                    Center(
                      child: Column(
                        children: [
                          Text(
                            l10n.translate('reportsHow'),
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 22),
                              fontWeight: FontWeight.w900,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          Text(
                            l10n.translate('reportsHowHint'),
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 12),
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_refreshing && !local)
                      const LinearProgressIndicator(
                        minHeight: 2,
                        color: AppColors.primary,
                      ),
                    // The FOUR merchant questions — real, distinct values.
                    if (_loadError != null && canRead)
                      ReportIntegrityCard(error: _loadError!, onRetry: _load)
                    else if (!_refreshing &&
                        canRead &&
                        (!local || kpis != null)) ...[
                      ReportValuationNote(data: home),
                      _kpiGrid(kpis, l10n, local: local, home: home),
                      const SizedBox(height: 16),
                      _mainChart(
                        chart,
                        l10n,
                        dark,
                        comparison,
                        unavailable: local && home?['chart'] == null,
                      ),
                    ],
                    const SizedBox(height: 20),
                    ..._reportCards(l10n, dark),
                    if (!local &&
                        kpis != null &&
                        !_refreshing &&
                        _loadError == null) ...[
                      const SizedBox(height: 10),
                      _fxNotices(kpis),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  Widget _periodBar(AppLocalizations l10n) {
    Widget chip(String label, String value) => Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: ChoiceChip(
        label: Text(
          label,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: _period == value ? Colors.white : AppColors.textSecondary,
          ),
        ),
        selected: _period == value,
        selectedColor: AppColors.primary,
        showCheckmark: false,
        onSelected: (_) async {
          if (value == 'custom') {
            final now = DateTime.now();
            final picked = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2020),
              lastDate: now,
              initialDateRange: DateTimeRange(
                start: _from ?? now.subtract(const Duration(days: 30)),
                end: _to ?? now,
              ),
            );
            if (picked != null && mounted) {
              setState(() {
                _period = 'custom';
                _from = picked.start;
                _to = picked.end;
              });
              _load();
            }
            return;
          }
          setState(() => _period = value);
          _load();
        },
      ),
    );
    return SizedBox(
      height: 38,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          chip(l10n.translate('reconPeriodToday'), 'today'),
          chip(l10n.translate('reconPeriodWeek'), 'week'),
          chip(l10n.translate('reconPeriodMonth'), 'month'),
          chip(l10n.translate('reconPeriodYear'), 'year'),
          chip(l10n.translate('reconPeriodCustom'), 'custom'),
        ],
      ),
    );
  }

  Widget _kpiGrid(
    Map? kpis,
    AppLocalizations l10n, {
    required bool local,
    Map? home,
  }) {
    Map sold = kpis?['sold'] is Map ? kpis!['sold'] as Map : {};
    Map profit = kpis?['profit'] is Map ? kpis!['profit'] as Map : {};
    Map spent = kpis?['spent'] is Map ? kpis!['spent'] as Map : {};
    Map debt = kpis?['customer_debt'] is Map
        ? kpis!['customer_debt'] as Map
        : {};
    Widget? storedValue(Map section, Color color) {
      if (!local) return null;
      final value = section['total'];
      final rows = value != null
          ? [
              {'total': value, 'currency': _currency},
            ]
          : (section['per_currency'] as List? ?? []).whereType<Map>();
      final style = TextStyle(
        fontFamily: 'Cairo',
        fontSize: R.fontSize(context, 17),
        fontWeight: FontWeight.w900,
        color: color,
      );
      if (rows.isEmpty) {
        return identical(section, profit)
            ? ReportProfitUnavailable(data: home, section: section, style: style)
            : Text('—', style: style);
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final row in rows)
            ReportCountUp(
              end: double.tryParse('${row['total']}') ?? 0,
              exact: formatRecordedReportNumber(row['total']),
              currency: currencyLabel(
                '${row['currency']}',
                locale: l10n.locale.languageCode,
              ),
              alignment: AlignmentDirectional.centerStart,
              style: style,
            ),
        ],
      );
    }

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: ReportKpiCard(
                question: l10n.translate('repQSold'),
                value: fmtNum(sold['total']),
                valueOverride: storedValue(sold, AppColors.primary),
                currency: _currency,
                count:
                    '${sold['count'] ?? 0} ${l10n.translate('repInvoicesCount')}',
                art: ReportArtKind.sales,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ReportKpiCard(
                question: l10n.translate('repQProfit'),
                value: fmtNum(profit['total']),
                valueOverride: storedValue(profit, AppColors.success),
                currency: _currency,
                hint: l10n.translate('repProfitNote'),
                art: ReportArtKind.profit,
                color: AppColors.success,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: ReportKpiCard(
                question: l10n.translate('repQSpent'),
                value: fmtNum(spent['total']),
                valueOverride: storedValue(spent, AppColors.danger),
                currency: _currency,
                art: ReportArtKind.money,
                color: AppColors.danger,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ReportKpiCard(
                question: l10n.translate('repQDebt'),
                value: fmtNum(debt['total']),
                valueOverride: storedValue(debt, AppColors.warning),
                currency: _currency,
                count: '${debt['count'] ?? 0}',
                art: ReportArtKind.debts,
                color: AppColors.warning,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _mainChart(
    List<Map> chart,
    AppLocalizations l10n,
    bool dark,
    Map? comparison, {
    required bool unavailable,
  }) {
    final delta = double.tryParse('${comparison?['sold_delta']}');
    return ReportCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  l10n.translate('repTrend'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                const Spacer(),
                if (delta != null && delta != 0) _trendChip(delta, l10n),
              ],
            ),
            const SizedBox(height: 6),
            if (chart.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 36),
                child: Center(
                  child: Text(
                    l10n.translate(
                      unavailable ? 'repLocalChartUnavailable' : 'repEmpty',
                    ),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              )
            else
              SizedBox(
                height: 170,
                child: AnimatedReportChart(
                  points: [
                    for (final p in chart)
                      ChartPoint(
                        label: '${p['date']}'.substring(5),
                        value: double.tryParse('${p['value']}') ?? 0,
                      ),
                  ],
                  color: AppColors.primary,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _trendChip(double delta, AppLocalizations l10n) {
    final up = delta > 0;
    final color = up ? AppColors.success : AppColors.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(22),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            up ? Icons.trending_up_rounded : Icons.trending_down_rounded,
            size: 15,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            '${up ? '+' : ''}${delta.toStringAsFixed(0)}',
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _reportCards(AppLocalizations l10n, bool dark) {
    final cards = [
      (
        l10n.translate('repSalesPurchases'),
        l10n.translate('repSalesPurchasesHint'),
        ReportArtKind.sales,
        'sales',
      ),
      (
        l10n.translate('repMoney'),
        l10n.translate('repMoneyHint'),
        ReportArtKind.money,
        'money',
      ),
      (
        l10n.translate('repInventory'),
        l10n.translate('repInventoryHint'),
        ReportArtKind.inventory,
        'inventory',
      ),
      (
        l10n.translate('repDebts'),
        l10n.translate('repDebtsHint'),
        ReportArtKind.debts,
        'debts',
      ),
      (
        l10n.translate('repOverview'),
        l10n.translate('repOverviewHint'),
        ReportArtKind.overview,
        'overview',
      ),
    ];
    return [
      for (final (title, hint, kind, route) in cards)
        if (ref.watch(employeeReportCanProvider(route))) ...[
          ReportTileCard(
            title: title,
            hint: hint,
            kind: kind,
            onTap: () => _confirmAndOpen(
              context,
              route,
              l10n.translate(switch (route) {
                'sales' => 'repSalesPurchases',
                'money' => 'repMoney',
                'inventory' => 'repInventory',
                'debts' => 'repDebts',
                _ => 'repOverview',
              }),
            ),
          ),
          const SizedBox(height: 12),
        ],
    ];
  }

  Widget _fxNotices(Map kpis) {
    // ONE warning for the whole hub (merged across KPIs) — never a stack.
    final text = singleFxNotice(l10nOf(context), [
      kpis['sold'],
      kpis['profit'],
      kpis['spent'],
      kpis['customer_debt'],
    ], _currency);
    return singleFxCard(text);
  }
}
