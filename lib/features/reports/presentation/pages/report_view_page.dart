import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/pdf_engine.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/storage_util.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../branches/data/branch_epoch.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../../core_business/data/local_ledger/business_money.dart';
import '../../../core_business/presentation/providers/business_ledger_session.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';
import '../../../../shared/widgets/account_type_bar.dart';
import '../../../inventory/presentation/widgets/business_product_image.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../data/reports_api.dart';
import '../../data/business_report_rates.dart';
import '../../data/report_request_guard.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../widgets/report_integrity_card.dart';
import '../widgets/report_scenes.dart';
import '../widgets/report_widgets.dart';

/// The five report DETAIL pages, rebuilt to match the «Report Identity» PDFs
/// exactly: white cards on the light canvas, burgundy accents, big honest
/// numbers first, details on demand. RTL/LTR both mirror via directional
/// widgets. Real system data only — no invented figures.
class ReportViewPage extends ConsumerStatefulWidget {
  final String kind; // sales | money | inventory | debts | overview
  // Inherited ONCE from the reports hub (currency + period apply everywhere).
  final String? currency;
  final String? period;
  final String? from;
  final String? to;
  // The hub already confirmed — start the cinematic immediately (no gate).
  final bool autoStart;
  const ReportViewPage({
    super.key,
    required this.kind,
    this.currency,
    this.period,
    this.from,
    this.to,
    this.autoStart = false,
  });

  @override
  ConsumerState<ReportViewPage> createState() => _ReportViewPageState();
}

class _ReportViewPageState extends ConsumerState<ReportViewPage> {
  String? _period;
  DateTime? _from;
  DateTime? _to;
  String _currency = 'USD';
  Map<String, dynamic>? _data;
  bool _ready = false;
  bool _refreshing = false;
  // Guards against double-tap duplicate generations.
  bool _generating = false;
  bool _refreshAfterScene = false;
  Route<void>? _sceneRoute;
  // Selected bank/account in the money report (null = first bank).
  String? _selectedBank;
  String? _selectedBankCcy;
  String? _selectedType; // checking | savings (فئة)
  String? _selectedAccountId;
  // «عرض الكل» toggles.
  bool _allProducts = false;
  bool _allSettlements = false;
  bool _allMoved = false;
  bool _allCounting = false;
  bool _allMovements = false;
  bool _showBreakdown = false;
  final _requests = ReportRequestGuard();
  Object? _reportError;
  BusinessReportsApi? _resultSource;
  (String?, String?, String, String?)? _shownWindow;

  (String?, String?, String, String?) get _window {
    final (from, to) = _bounds();
    return (from, to, _currency, _selectedAccountId);
  }

  void _clearMoneySelection() {
    _selectedAccountId = null;
    _selectedBank = null;
    _selectedBankCcy = null;
    _selectedType = null;
  }

  void _reloadDeviceReport() {
    _requests.invalidate();
    _resultSource = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _dismissScene();
      _refreshFilters();
    });
  }

  void _dismissScene() {
    final route = _sceneRoute;
    _sceneRoute = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  @override
  void initState() {
    super.initState();
    ref.listenManual(branchEpochProvider, (_, __) {
      _requests.invalidate();
      _resultSource = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _dismissScene();
        _clearMoneySelection();
        _generating = false;
        _refreshFilters();
      });
    });
    ref.listenManual(businessReportsApiProvider, (before, after) {
      if (before != null && before!.scopeKey != after.scopeKey) {
        _clearMoneySelection();
        _reloadDeviceReport();
      }
    });
    for (final kind in const [
      'sales',
      'money',
      'inventory',
      'debts',
      'overview',
    ]) {
      ref.listenManual(localReportAllowedProvider(kind), (_, _) {
        if (kind == widget.kind &&
            ref.read(businessReportsApiProvider).isDeviceLedger) {
          _reloadDeviceReport();
        }
      });
    }
    ref.listenManual(businessOperationsRevisionProvider, (_, __) {
      if (_ready &&
          const {
            'debts',
            'inventory',
            'sales',
            'overview',
          }.contains(widget.kind) &&
          ref.read(businessReportsApiProvider).isDeviceLedger) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _refreshFilters();
        });
      }
    });
    ref.listenManual(businessBankRevisionProvider, (_, __) {
      if (_ready &&
          const {'debts', 'money', 'overview'}.contains(widget.kind) &&
          ref.read(businessReportsApiProvider).isDeviceLedger) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _refreshFilters();
        });
      }
    });
    ref.listenManual(rateSnapshotRevisionProvider, (_, __) {
      if (_reportError != null &&
          BusinessReportsApi.ratesPending(_reportError!)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _refreshFilters();
        });
      }
    });
    ref.listenManual(businessReportRateRevisionProvider, (_, _) {
      if (!ref.read(businessReportsApiProvider).isDeviceLedger) return;
      if (_generating) {
        _refreshAfterScene = true;
      } else if (_ready || _refreshing) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_generating) _refreshFilters();
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      }
    });
    // The hub's currency/period are the single source of truth — the report
    // never asks for a currency again.
    if (widget.currency != null && widget.currency!.isNotEmpty) {
      _currency = widget.currency!;
    }
    if (widget.period != null) _period = widget.period;
    if (widget.from != null) _from = DateTime.tryParse(widget.from!);
    if (widget.to != null) _to = DateTime.tryParse(widget.to!);
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openCinematic();
      });
    }
  }

  @override
  void didUpdateWidget(covariant ReportViewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind ||
        oldWidget.currency != widget.currency ||
        oldWidget.period != widget.period ||
        oldWidget.from != widget.from ||
        oldWidget.to != widget.to) {
      _requests.invalidate();
      _generating = false;
      _refreshAfterScene = false;
      _ready = false;
      _data = null;
      _resultSource = null;
      _reportError = null;
      _clearMoneySelection();
      _currency = widget.currency ?? _currency;
      _from = DateTime.tryParse(widget.from ?? '');
      _to = DateTime.tryParse(widget.to ?? '');
      _period = widget.period;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _dismissScene();
        if (widget.autoStart && oldWidget.kind != widget.kind) {
          _openCinematic();
        } else {
          _refreshFilters();
        }
      });
    }
  }

  @override
  void dispose() {
    _requests.invalidate();
    super.dispose();
  }

  (String?, String?) _bounds() {
    final now = DateTime.now();
    switch (_period) {
      case 'today':
        final d = _dstr(now);
        return (d, d);
      case 'week':
        return (_dstr(now.subtract(const Duration(days: 7))), null);
      case 'year':
        return (_dstr(DateTime(now.year)), null);
      case 'custom':
        return (
          _from?.toIso8601String().split('T').first,
          _to?.toIso8601String().split('T').first,
        );
      default: // month
        return (_dstr(DateTime(now.year, now.month)), null);
    }
  }

  static String _dstr(DateTime d) => d.toIso8601String().split('T').first;

  Future<dynamic> _fetch(BusinessReportsApi api) async {
    final (f, t) = _bounds();
    switch (widget.kind) {
      case 'sales':
        return api.salesPurchases(f, t, _currency);
      case 'money':
        return api.money(f, t, _currency, _selectedAccountId);
      case 'inventory':
        return api.inventory(f, t, _currency);
      case 'debts':
        return api.debts(f, t, _currency);
      default:
        return api.overview(f, t, _currency);
    }
  }

  ReportScene get _scene => switch (widget.kind) {
    'sales' => ReportScene.sales,
    'money' => ReportScene.money,
    'inventory' => ReportScene.inventory,
    'debts' => ReportScene.debts,
    _ => ReportScene.overview,
  };

  String get _sceneKey => switch (widget.kind) {
    'sales' => 'repSceneSales',
    'money' => 'repSceneMoney',
    'inventory' => 'repSceneInventory',
    'debts' => 'repSceneDebts',
    _ => 'repSceneOverview',
  };

  String get _titleKey => switch (widget.kind) {
    'sales' => 'repSalesPurchases',
    'money' => 'repMoney',
    'inventory' => 'repInventory',
    'debts' => 'repDebts',
    _ => 'repOverview',
  };

  void _openCinematic() {
    if (_generating) return; // no duplicate generations from double taps
    final api = ref.read(businessReportsApiProvider);
    _generating = true;
    _refreshAfterScene = false;
    final ticket = _requests.begin();
    final window = _window;
    _reportError = null;
    final l10n = AppLocalizations.of(context);
    final scene = _scene;
    final sceneText = l10n.translate(_sceneKey);
    final pending = _fetch(api);
    // A local denial may resolve before the route has mounted its listener.
    // Attach an error handler now; the overlay still receives the same future.
    unawaited(pending.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    bool accepts() =>
        mounted &&
        _requests.accepts(ticket) &&
        identical(api, ref.read(businessReportsApiProvider)) &&
        window == _window;
    var completed = false;
    final navigator = Navigator.of(context);
    final page = ModalRoute.of(context);
    final route = MaterialPageRoute<void>(
      builder: (_) => ReportSceneOverlay(
        scene: scene,
        sceneText: sceneText,
        processingText: l10n.translate('repProcessing'),
        future: pending,
        onResult: (overlay, result) {
          if (!mounted) return;
          completed = true;
          if (ModalRoute.of(overlay)?.isCurrent == true) {
            Navigator.of(overlay).pop();
          }
          if (!accepts()) return;
          setState(() {
            _data = Map<String, dynamic>.from(result as Map);
            _resultSource = api;
            _shownWindow = window;
            _ready = true;
            _generating = false;
            _refreshing = false;
          });
          if (_refreshAfterScene) unawaited(_refreshFilters());
        },
        onError: (overlay, e) {
          if (!mounted) return;
          completed = true;
          if (ModalRoute.of(overlay)?.isCurrent == true) {
            Navigator.of(overlay).pop();
          }
          if (!accepts()) return;
          setState(() {
            _generating = false;
            _refreshing = false;
            _data = null;
            _ready = false;
            _reportError = e;
          });
        },
      ),
    );
    _sceneRoute = route;
    unawaited(
      navigator.push<void>(route).then((_) {
        if (identical(_sceneRoute, route)) _sceneRoute = null;
        if (completed || !accepts()) return;
        _requests.invalidate();
        setState(() => _generating = false);
        // If Back cancels the original entry scene, go back to the hub
        // instead of stranding the user on the auto-start confirmation page.
        if (widget.autoStart &&
            !_ready &&
            page?.isCurrent == true &&
            navigator.canPop()) {
          navigator.pop();
        }
      }),
    );
  }

  Future<void> _refreshFilters() async {
    final ticket = _requests.begin();
    final api = ref.read(businessReportsApiProvider);
    final window = _window;
    // Filter changes inside the report: SHORT refresh, not the full scene.
    setState(() {
      _refreshing = true;
      _reportError = null;
    });
    try {
      final result = await _fetch(api);
      if (mounted &&
          _requests.accepts(ticket) &&
          identical(api, ref.read(businessReportsApiProvider)) &&
          window == _window) {
        setState(() {
          _data = Map<String, dynamic>.from(result as Map);
          _resultSource = api;
          _shownWindow = window;
          _refreshing = false;
          _ready = true;
          _generating = false;
        });
      }
    } catch (e) {
      if (mounted &&
          _requests.accepts(ticket) &&
          identical(api, ref.read(businessReportsApiProvider)) &&
          window == _window) {
        setState(() {
          _refreshing = false;
          _generating = false;
          _data = null;
          _resultSource = null;
          _reportError = e;
          _ready = false;
        });
      }
    }
  }

  Future<void> _exportPdf() async {
    if (_refreshing || _reportError != null) return;
    final api = ref.read(businessReportsApiProvider);
    final source = _resultSource;
    final scope = BusinessReportsApi.scopeIdentity;
    final window = _window;
    final snapshot = _data;
    bool mayExport() =>
        mounted &&
        scope == BusinessReportsApi.scopeIdentity &&
        _window == window &&
        identical(_data, snapshot) &&
        identical(api, ref.read(businessReportsApiProvider)) &&
        identical(source, _resultSource) &&
        ref.read(employeeCanProvider('reports.view')) &&
        ref.read(employeeCanProvider('reports.export')) &&
        ref.read(employeeCanProvider('banks.balances')) &&
        (!api.isDeviceLedger ||
            (identical(source, api) &&
                ref.read(localReportAllowedProvider(widget.kind))));
    if (!mayExport()) return;
    final l10n = AppLocalizations.of(context);
    final data = snapshot;
    if (data == null) return;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final (f, t) = _bounds();
    final periodLabel = switch (_period) {
      'today' => l10n.translate('reconPeriodToday'),
      'week' => l10n.translate('reconPeriodWeek'),
      'year' => l10n.translate('reconPeriodYear'),
      'custom' => '${f ?? ''} → ${t ?? ''}',
      _ => l10n.translate('reconPeriodMonth'),
    };
    final allBranches = BranchScope.allMode;
    final currencyText = currencyLabel(_currency);
    final scopeText = allBranches
        ? ' • ${l10n.translate('branchAllShort')}'
        : '';
    final subtitle =
        '${l10n.translate('repPeriod')}: $periodLabel • '
        '${l10n.translate('repCurrencyPick')}: $currencyText$scopeText';
    List<String> subParts(String one) =>
        one.split('•').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    String subtitleAcc = subtitle;
    // Money PDFs never show the «اختر العملة» picker label — only the value.
    final subtitleMoneyBase =
        '${l10n.translate('repPeriod')}: $periodLabel • $currencyText$scopeText';
    try {
      final kpis = <Map<String, String>>[];
      final sections = <ReportPdfSection>[];

      void kpi(String label, dynamic v) =>
          kpis.add({'label': label, 'value': '${v ?? '—'}'});

      if (widget.kind == 'sales') {
        final sales = data['sales'] as Map? ?? {};
        final pur = data['purchases'] as Map? ?? {};
        for (final (title, section) in [
          ('repSales', sales),
          ('repPurchases', pur),
        ]) {
          kpi(l10n.translate(title), _storedTotalText(section));
          kpi(
            l10n.translate('repPaid'),
            _storedTotalText(_invoiceAmount(section, 'paid')),
          );
          kpi(
            l10n.translate('repRemaining'),
            _storedTotalText(_invoiceAmount(section, 'remaining')),
          );
          if (_storedReport) {
            kpi(
              l10n.translate('repReturnsTotal'),
              _storedTotalText(section['returns'] as Map? ?? {}),
            );
          }
        }
        sections.add(
          ReportPdfSection(
            title: l10n.translate(_productsTitle(data)),
            headers: [
              l10n.translate('repProducts'),
              l10n.translate('repQtyCol'),
              l10n.translate('repTotalCol'),
            ],
            rows: [
              for (final p
                  in ((data['top_products'] as List? ?? []).whereType<Map>()))
                [
                  '${p['name'] ?? ''}',
                  '${_f(p['qty'])} ${p['unit'] ?? ''}'.trim(),
                  _storedTotalText(p),
                ],
            ],
          ),
        );
        final invoices = (data['invoices'] as List? ?? [])
            .whereType<Map>()
            .toList();
        if (invoices.isNotEmpty) {
          sections.add(
            ReportPdfSection(
              title: l10n.translate('repDetails'),
              headers: [
                l10n.translate('invNumber'),
                l10n.translate('invParty'),
                l10n.translate('invKind'),
                l10n.translate('invTotal'),
                l10n.translate('invDate'),
              ],
              rows: [
                for (final inv in invoices)
                  [
                    '${inv['number'] ?? ''}',
                    _partyLabel(inv['party'], l10n),
                    '${inv['kind'] ?? ''}' == 'sale'
                        ? l10n.translate('txKindSale')
                        : l10n.translate('txKindPurchase'),
                    _money(inv['total'], ccy: inv['currency']),
                    '${inv['date'] ?? ''}'.split('T').first,
                  ],
              ],
            ),
          );
        }
      } else if (widget.kind == 'money') {
        final inflow = data['inflow'] as Map? ?? {};
        final outflow = data['outflow'] as Map? ?? {};
        final transfers = data['transfers'] as Map? ?? {};
        final expenses = data['expenses'] as Map? ?? {};
        final balances = data['balances'] as Map? ?? {};
        final accounts = (data['accounts'] as List? ?? [])
            .whereType<Map>()
            .toList();
        // When a bank + currency + فئة is selected, the PDF shows EXACTLY
        // that account's data — the same numbers as the screen.
        final selAcc = _selectedAccountId == null
            ? null
            : accounts.firstWhere(
                (a) => '${a['id']}' == _selectedAccountId,
                orElse: () => const {},
              );
        final scoped = selAcc != null && selAcc.isNotEmpty;
        final scopedExp = scoped
            ? (data['expense_scoped'] as Map? ?? expenses)
            : expenses;
        subtitleAcc = scoped
            ? '$subtitleMoneyBase • '
                  '${l10n.translate('invBank')}: ${selAcc!['bank_name']} • '
                  '${selAcc['currency']} • '
                  '${accountTypeLabel(l10n, '${selAcc['account_type'] ?? 'checking'}')}'
            : subtitleMoneyBase;

        if (scoped) {
          kpi(
            l10n.translate('repIncome'),
            _accountAmountText(selAcc!['inflow'], selAcc['currency']),
          );
          kpi(
            l10n.translate('repOutflow'),
            _accountAmountText(selAcc['outflow'], selAcc['currency']),
          );
          kpi(
            l10n.translate('repTransfers'),
            _accountAmountText(selAcc['transfers'], selAcc['currency']),
          );
          kpi(
            l10n.translate('repExpenses'),
            _storedTotalText(scopedExp, ccy: selAcc['currency']),
          );
          kpi(
            l10n.translate('repSettlements'),
            _accountAmountText(selAcc['settlements'], selAcc['currency']),
          );
          kpi(
            l10n.translate('repBalanceNow'),
            _money(selAcc['balance'], ccy: selAcc['currency']),
          );
        } else {
          kpi(l10n.translate('repIncome'), _storedTotalText(inflow));
          kpi(l10n.translate('repOutflow'), _storedTotalText(outflow));
          kpi(l10n.translate('repTransfers'), _storedTotalText(transfers));
          kpi(l10n.translate('repExpenses'), _storedTotalText(expenses));
          kpi(
            l10n.translate('repSettleAdjust'),
            _storedTotalText(_settlementTotal(data)),
          );
          kpi(l10n.translate('repBalancesNow'), _storedTotalText(balances));
        }
        if (scoped) {
          sections.add(
            ReportPdfSection(
              title: l10n.translate('repBanksAccounts'),
              headers: [
                l10n.translate('invBank'),
                l10n.translate('invAccount'),
                l10n.translate('currencyLabel'),
                l10n.translate('repBalanceLbl'),
              ],
              rows: [
                [
                  '${selAcc!['bank_name'] ?? ''}',
                  '${selAcc['account_name'] ?? ''}',
                  '${selAcc['currency'] ?? ''}',
                  _money(selAcc['balance'], ccy: selAcc['currency']),
                ],
              ],
            ),
          );
        } else if (accounts.isNotEmpty) {
          sections.add(
            ReportPdfSection(
              title: l10n.translate('repBanksAccounts'),
              headers: [
                l10n.translate('invBank'),
                l10n.translate('invAccount'),
                l10n.translate('currencyLabel'),
                l10n.translate('repBalanceLbl'),
              ],
              rows: [
                for (final a in accounts)
                  [
                    '${a['bank_name'] ?? ''}',
                    '${a['account_name'] ?? ''}',
                    '${a['currency'] ?? ''}',
                    _money(a['balance'], ccy: a['currency']),
                  ],
              ],
            ),
          );
        }
        final cats = (scopedExp['categories'] as List? ?? [])
            .whereType<Map>()
            .toList();
        if (cats.isNotEmpty) {
          sections.add(
            ReportPdfSection(
              title: l10n.translate(
                _storedReport && scopedExp['total'] == null
                    ? 'repLocalExpenseCategories'
                    : 'repTopExpenseCats',
              ),
              headers: [
                l10n.translate('invCategory'),
                l10n.translate('invTotal'),
              ],
              rows: [
                for (final c in cats)
                  [
                    '${c['category'] ?? l10n.translate('repExpenseOther')}',
                    _storedTotalText(c),
                  ],
              ],
            ),
          );
        }
        final settlements = data['settlements'] as Map? ?? {};
        final setItems =
            (settlements['items'] as List? ?? []).whereType<Map>().toList()
              ..sort(
                (a, b) => '${b['approved_at'] ?? ''}'.compareTo(
                  '${a['approved_at'] ?? ''}',
                ),
              );
        if (setItems.isNotEmpty) {
          sections.add(
            ReportPdfSection(
              title: l10n.translate('repSettlements'),
              headers: [
                l10n.translate('invDate'),
                l10n.translate('invAccount'),
                l10n.translate('repBeforeCol'),
                l10n.translate('repAfterCol'),
              ],
              rows: [
                for (final st in setItems)
                  for (final line
                      in ((st['settlements'] as List? ?? []).whereType<Map>()))
                    [
                      '${st['approved_at'] ?? ''}'.split('T').first,
                      '${line['name'] ?? ''}',
                      _money(line['before'], ccy: line['currency']),
                      _money(line['after'], ccy: line['currency']),
                    ],
              ],
            ),
          );
        }
      } else if (widget.kind == 'inventory') {
        kpi(l10n.translate('repProducts'), data['products']);
        kpi(
          l10n.translate(
            _storedReport ? 'repTransferredCategories' : 'repCategories',
          ),
          data['categories'],
        );
        kpi(l10n.translate('repUnits'), data['units']);
        kpi(l10n.translate('repStockValueHero'), _stockValueText(data));
        kpi(l10n.translate('repLowStock'), data['low_count']);
        kpi(l10n.translate('repOutOfStock'), data['out_count']);
        kpi(l10n.translate('repExpiring'), data['expiring_count']);
        final moved = (data['most_moved'] as List? ?? [])
            .whereType<Map>()
            .toList();
        if (moved.isNotEmpty) {
          sections.add(
            ReportPdfSection(
              title: l10n.translate('repMostMoved'),
              headers: [
                l10n.translate('repProducts'),
                l10n.translate('repQtyCol'),
              ],
              rows: [
                for (final m in moved)
                  [
                    '${m['name'] ?? ''}',
                    '${_f(m['moved'])} ${m['unit'] ?? ''}',
                  ],
              ],
            ),
          );
        }
        final counting = data['counting'] as Map? ?? {};
        final countingItems = (counting['items'] as List? ?? [])
            .whereType<Map>()
            .toList();
        if (countingItems.isNotEmpty) {
          sections.add(
            ReportPdfSection(
              title: l10n.translate('repStocktake'),
              headers: [
                l10n.translate('invDate'),
                l10n.translate('invLines'),
                l10n.translate('repStatusCol'),
              ],
              rows: [
                for (final st in countingItems)
                  [
                    '${st['approved_at'] ?? ''}'.split('T').first,
                    '${((st['settlements'] as List? ?? []).whereType<Map>()).length}',
                    l10n.translate('repReconciled'),
                  ],
              ],
            ),
          );
        }
        for (final (title, list) in [
          (l10n.translate('repOutOfStock'), data['out_of_stock']),
          (l10n.translate('repLowStock'), data['low_stock']),
          (l10n.translate('repExpiring'), data['expiring_soon']),
        ]) {
          final items = (list as List? ?? []).whereType<Map>().toList();
          if (items.isEmpty) continue;
          sections.add(
            ReportPdfSection(
              title: title,
              headers: [
                l10n.translate('repProducts'),
                l10n.translate('invStockCol'),
              ],
              rows: [
                for (final it in items)
                  [
                    '${it['name'] ?? ''}',
                    '${_f(it['stock'])} ${it['unit'] ?? ''}',
                  ],
              ],
            ),
          );
        }
      } else if (widget.kind == 'debts') {
        final customers = data['customers'] as Map? ?? {};
        final suppliers = data['suppliers'] as Map? ?? {};
        kpi(l10n.translate('repCustomersDebts'), _storedTotalText(customers));
        kpi(l10n.translate('repSuppliersDebts'), _storedTotalText(suppliers));
        kpi(
          l10n.translate('repCollected'),
          _storedTotalText(data['collected'] as Map? ?? {}),
        );
        kpi(
          l10n.translate('repPaidSuppliers'),
          _storedTotalText(data['paid_to_suppliers'] as Map? ?? {}),
        );
        for (final (title, list) in [
          (l10n.translate('repDebtors'), customers['top']),
          (l10n.translate('repOwedTo'), suppliers['top']),
        ]) {
          final items = (list as List? ?? []).whereType<Map>().toList();
          if (items.isEmpty) continue;
          sections.add(
            ReportPdfSection(
              title: title,
              headers: [l10n.translate('invParty'), l10n.translate('invTotal')],
              rows: [
                for (final c in items)
                  ['${c['name'] ?? ''}', _perCcyText(c['debts'])],
              ],
            ),
          );
        }
        final movements = (data['recent_movements'] as List? ?? [])
            .whereType<Map>()
            .toList();
        if (movements.isNotEmpty) {
          sections.add(
            ReportPdfSection(
              title: l10n.translate('repMovementsTitle'),
              headers: [
                l10n.translate('invDate'),
                l10n.translate('invParty'),
                l10n.translate('invKind'),
                l10n.translate('repAmountCol'),
              ],
              rows: [
                for (final m in movements)
                  [
                    '${m['date'] ?? ''}',
                    _partyLabel(m['party'], l10n),
                    '${m['kind'] ?? ''}' == 'customer'
                        ? l10n.translate('repDebtPay')
                        : l10n.translate('repSuppPay'),
                    '${_d(m['amount']) >= 0 ? '+' : '-'} ${_money(_d(m['amount']).abs(), ccy: m['currency'] as String?)}',
                  ],
              ],
            ),
          );
        }
      } else {
        for (final (key, label) in [
          ('sales', 'repSales'),
          ('income', 'repIncome'),
          ('purchases', 'repPurchases'),
          ('profit', 'repProfit'),
          ('expenses', 'repExpenses'),
          ('customer_debt', 'repCustomersDebts'),
          ('supplier_debt', 'repSuppliersDebts'),
        ]) {
          kpi(l10n.translate(label), _storedTotalText(data[key] as Map? ?? {}));
        }
        kpi(
          l10n.translate('repStockValueHero'),
          _stockValueText(data['inventory'] as Map? ?? {}),
        );
        final chart = (data['chart'] as List? ?? []).whereType<Map>().toList();
        if (chart.isNotEmpty) {
          sections.add(
            ReportPdfSection(
              title: l10n.translate('repTrend'),
              headers: [l10n.translate('invDate'), l10n.translate('invTotal')],
              rows: [
                for (final p in chart)
                  ['${p['date'] ?? ''}', _money(p['value'])],
              ],
            ),
          );
        }
      }

      final genAt = DateTime.now();
      final genDate =
          '${genAt.year.toString().padLeft(4, '0')}-${genAt.month.toString().padLeft(2, '0')}-${genAt.day.toString().padLeft(2, '0')} '
          '${genAt.hour.toString().padLeft(2, '0')}:${genAt.minute.toString().padLeft(2, '0')}';
      final bytes = await PdfEngine.generateReportPdf(
        title: allBranches
            ? '${l10n.translate(_titleKey)} — ${l10n.translate('branchAllShort')}'
            : l10n.translate(_titleKey),
        subtitle: widget.kind == 'money' ? subtitleAcc : subtitle,
        subtitleParts: widget.kind == 'money'
            ? subParts(subtitleAcc)
            : [
                '$periodLabel',
                '${l10n.translate('repCurrencyPick')}: $_currency',
              ],
        footerParts: widget.kind == 'money'
            ? [
                '${l10n.translate('repGeneratedAt')}',
                genDate,
                _valuationLabel(data, l10n),
              ]
            : [
                '${l10n.translate('repGeneratedAt')}',
                genDate,
                _valuationLabel(data, l10n),
              ],
        headers: const [],
        rows: const [],
        kpis: kpis,
        sections: sections,
        isAr: isAr,
        footer:
            '${l10n.translate('repGeneratedAt')}: '
            '${DateTime.now().toIso8601String().split('.').first} | '
            '${_valuationLabel(data, l10n)}',
      );
      if (!mayExport()) return;
      final dir = await Directory.systemTemp.createTemp('report_pdf');
      final file = File(
        '${dir.path}/fyona_${widget.kind}_report_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
      await file.writeAsBytes(bytes);
      if (mayExport()) {
        await StorageUtil.showPdfOptions(
          context,
          file,
          file.path.split('/').last,
        );
      } else {
        await file.delete();
      }
    } catch (e) {
      if (mounted) {
        showFyonaSnack(context, l10n.translate('repFailed'), success: false);
      }
    }
  }

  // ── helpers ──────────────────────────────────────────────────────────
  String _valuationLabel(Map data, AppLocalizations l10n) =>
      data['local_valuation'] == 'as_recorded'
      ? localReportNoticeKeys(data).map(l10n.translate).join(' • ')
      : (data['fx_valuation'] as Map?)?['basis'] == 'latest_approved'
      ? l10n.translate('repFxBasisLatest')
      : '${l10n.translate('repFxBasis')}: ${l10n.translate('repFxBasisHist')}';
  double _d(dynamic v) =>
      (v is num) ? v.toDouble() : (num.tryParse('$v') ?? 0).toDouble();

  String _f(dynamic v) {
    if (_storedReport && v is String) {
      final [whole, ...fraction] = v.split('.');
      return [_group(whole), ...fraction].join('.');
    }
    final n = _d(v);
    final r = n.roundToDouble();
    if ((r - n).abs() < 0.005 && n.abs() >= 1000 || (r == n && n.abs() >= 1)) {
      final s = n.abs() >= 1000 || r == n
          ? n.round().toString()
          : n.toStringAsFixed(2);
      return (n < 0 ? '-' : '') + _group(s);
    }
    return (n < 0 ? '-' : '') + _group(n.abs().toStringAsFixed(2));
  }

  String _group(String digits) =>
      digits.replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

  /// Company-wide reconciliation-settlement total (sum over accounts).
  Map _settlementTotal(Map data) {
    if (data['local_valuation'] == 'as_recorded') {
      return data['settlements'] as Map? ?? {};
    }
    final accounts = (data['accounts'] as List? ?? []).whereType<Map>();
    double t = 0;
    for (final a in accounts) {
      t += _d(a['settlements']);
    }
    return {'total': t};
  }

  String _money(dynamic v, {String? ccy}) =>
      '${_displayNumber(v)} ${currencyLabel(ccy ?? _currency)}'.trim();

  String _displayNumber(Object? value) =>
      _storedReport ? formatRecordedReportNumber(value) : fmtNum(_d(value));

  Widget _amount(
    dynamic v, {
    String? ccy,
    Color? color,
    TextStyle? style,
    AlignmentDirectional alignment = AlignmentDirectional.centerEnd,
  }) {
    final base =
        style ??
        TextStyle(
          fontFamily: 'Cairo',
          fontSize: 14.5,
          fontWeight: FontWeight.w800,
          color: AppColors.textPrimary,
        );
    return ReportAmount(
      number: _displayNumber(v),
      currency: currencyLabel(ccy ?? _currency),
      alignment: alignment,
      style: base.copyWith(color: color ?? base.color),
    );
  }

  String _partyLabel(dynamic party, AppLocalizations l10n) {
    final p = '$party'.trim();
    if (p.isEmpty || p == 'null' || p == '—') {
      return l10n.translate('repCashCustomer');
    }
    return p;
  }

  // ── build ────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final source = ref.watch(businessReportsApiProvider);
    final local = source.isDeviceLedger;
    if (local) ref.watch(businessReportRateWarmupProvider);
    final denied = local && !ref.watch(localReportAllowedProvider(widget.kind));
    final current = !denied && identical(_resultSource, source);
    final ready = _ready && current;
    final error = denied ? const DirectoryAccessDenied() : _reportError;
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
          l10n.translate(_titleKey),
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 17),
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
        actions: [
          if (ref.watch(employeeCanProvider('reports.view')) &&
              ref.watch(employeeCanProvider('reports.export')) &&
              ref.watch(employeeCanProvider('banks.balances')))
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 12),
              child: Center(
                child: GestureDetector(
                  onTap: ready && !_refreshing && error == null
                      ? _exportPdf
                      : null,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(
                        color: AppColors.primary.withAlpha(90),
                      ),
                    ),
                    child: const Icon(
                      Icons.picture_as_pdf_outlined,
                      size: 19,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: error != null
            ? SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: ReportIntegrityCard(
                  error: error,
                  onRetry: _openCinematic,
                ),
              )
            : !ready
            ? _confirmBody(l10n)
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
                    child: RefPeriodChips(
                      period: _period ?? 'month',
                      onSelect: (v) {
                        setState(() => _period = v);
                        _refreshFilters();
                      },
                      onCustom: _pickCustomRange,
                    ),
                  ),
                  if (_refreshing && !local)
                    const LinearProgressIndicator(
                      minHeight: 2,
                      color: AppColors.primary,
                    ),
                  if (!_refreshing || local) ReportValuationNote(data: _data),
                  Expanded(
                    child: refreshReport(
                      local: local,
                      onRefresh: _refreshFilters,
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 2, 16, 24),
                        children:
                            _refreshing && (!local || _shownWindow != _window)
                            ? const [SizedBox(height: 180)]
                            : _body(l10n),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Future<void> _pickCustomRange() async {
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
    if (picked != null) {
      setState(() {
        _period = 'custom';
        _from = picked.start;
        _to = picked.end;
      });
      _refreshFilters();
    }
  }

  /// The hub confirms BEFORE navigation, so this page starts generating at
  /// once. This fallback only shows for a frame (or when autoStart is off).
  Widget _confirmBody(AppLocalizations l10n) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.assessment_outlined,
            color: AppColors.primary,
            size: 36,
          ),
          const SizedBox(height: 14),
          Text(
            l10n.translate(_titleKey),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$_currency',
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 11,
              color: AppColors.textSecondary,
            ),
          ),
          if (!widget.autoStart) ...[
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
              onPressed: _generating ? null : _openCinematic,
              child: Text(
                l10n.translate('repViewReport'),
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _body(AppLocalizations l10n) {
    final data = _data!;
    switch (widget.kind) {
      case 'sales':
        return _salesBody(data, l10n);
      case 'money':
        return _moneyBody(data, l10n);
      case 'inventory':
        return _inventoryBody(data, l10n);
      case 'debts':
        return _debtsBody(data, l10n);
      default:
        return _overviewBody(data, l10n);
    }
  }

  // ══════════════════════════════════════════════════════════════════
  //  1) المبيعات والمشتريات
  // ══════════════════════════════════════════════════════════════════
  List<Widget> _salesBody(Map data, AppLocalizations l10n) {
    final sales = data['sales'] as Map? ?? {};
    final pur = data['purchases'] as Map? ?? {};
    final top = (data['top_products'] as List? ?? []).whereType<Map>().toList();
    final ranked = data['products_ranked'] != false;
    final maxTotal = top.isEmpty || !ranked
        ? 1.0
        : top.map((e) => _d(e['total'])).reduce((a, b) => a > b ? a : b);
    final shown = _allProducts ? top : top.take(6).toList();
    return [
      _invoiceCard(
        l10n,
        icon: Icons.shopping_cart_outlined,
        title: l10n.translate('repSales'),
        section: sales,
      ),
      const SizedBox(height: 14),
      _invoiceCard(
        l10n,
        icon: Icons.local_shipping_outlined,
        title: l10n.translate('repPurchases'),
        section: pur,
      ),
      if (!_storedReport) ..._fxNote((sales['gaps'] as List?) ?? const []),
      const SizedBox(height: 14),
      RefCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RefSectionHeader(
              Icons.bar_chart_rounded,
              l10n.translate(_productsTitle(data)),
            ),
            const SizedBox(height: 4),
            if (top.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Center(
                  child: Text(
                    l10n.translate('repNone'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              )
            else
              for (var i = 0; i < shown.length; i++)
                _productRow(l10n, shown[i], ranked ? i + 1 : null, maxTotal),
            if (top.length > 6) ...[
              const SizedBox(height: 6),
              RefPill(
                label: l10n.translate(
                  _allProducts ? 'repShowFewerProducts' : 'repShowAllProducts',
                  params: {'n': '${top.length}'},
                ),
                onTap: () => setState(() => _allProducts = !_allProducts),
              ),
            ],
          ],
        ),
      ),
    ];
  }

  /// One invoice summary card (sales / purchases) — big value + 3-stat row.
  Widget _invoiceCard(
    AppLocalizations l10n, {
    required IconData icon,
    required String title,
    required Map section,
  }) {
    Widget stat(IconData ic, String label, Widget value, Color color) =>
        Expanded(
          child: Column(
            children: [
              RefIconChip(ic, color: color, size: 30),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 10.5,
                  color: AppColors.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              value,
            ],
          ),
        );

    Widget vDiv() => Container(
      width: 1,
      height: 44,
      color: AppColors.border.withAlpha(120),
      margin: const EdgeInsets.symmetric(horizontal: 4),
    );

    return RefCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          Row(
            children: [
              RefIconChip(icon),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              Flexible(
                child: _storedTotalAmount(
                  section,
                  color: AppColors.primary,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 19),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(height: 1, color: AppColors.border.withAlpha(110)),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              stat(
                Icons.description_outlined,
                l10n.translate('repInvoicesCount'),
                ReportFitText(
                  text: '${_d(section['count']).round()}',
                  alignment: AlignmentDirectional.center,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary,
                  ),
                ),
                AppColors.primary,
              ),
              vDiv(),
              stat(
                Icons.payments_outlined,
                l10n.translate('repPaid'),
                _storedTotalAmount(
                  _invoiceAmount(section, 'paid'),
                  color: AppColors.success,
                  alignment: AlignmentDirectional.center,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                AppColors.success,
              ),
              vDiv(),
              stat(
                Icons.hourglass_bottom_rounded,
                l10n.translate('repRemaining'),
                _storedTotalAmount(
                  _invoiceAmount(section, 'remaining'),
                  color: AppColors.warning,
                  alignment: AlignmentDirectional.center,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                AppColors.warning,
              ),
            ],
          ),
          if (_storedReport) ...[
            const SizedBox(height: 8),
            _debtRow(
              Icons.assignment_return_outlined,
              l10n.translate('repReturnsTotal'),
              _storedTotalAmount(
                section['returns'] as Map? ?? {},
                color: AppColors.warning,
              ),
              AppColors.warning,
            ),
          ],
        ],
      ),
    );
  }

  Map _invoiceAmount(Map section, String key) =>
      section['${key}_amounts'] as Map? ?? {'total': section[key]};

  String _productsTitle(Map data) => data['products_ranked'] == false
      ? 'repLocalSoldProductValues'
      : 'repTopProducts';

  Widget _productRow(AppLocalizations l10n, Map p, int? rank, double maxTotal) {
    final name = '${p['name'] ?? ''}';
    final unit = '${p['unit'] ?? ''}'.trim();
    final sub = unit.isEmpty ? '${_f(p['qty'])}' : '${_f(p['qty'])} $unit';
    final source = _resultSource;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: p['product_id'] == null
          ? null
          : () {
              if (!identical(source, ref.read(businessReportsApiProvider)))
                return;
              if (source?.isDeviceLedger == true &&
                  (!ref.read(localReportAllowedProvider('sales')) ||
                      !ref.read(employeeCanProvider('inventory'))))
                return;
              openCommerceRecord(
                context,
                RouteNames.inventoryProduct,
                '${p['product_id']}',
                fromLocal: source?.deviceScope,
              );
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            if (rank != null)
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(24),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$rank',
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary,
                  ),
                ),
              ),
            const SizedBox(width: 8),
            SizedBox(
              width: 44,
              height: 44,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: (p['image'] ?? '').toString().isNotEmpty
                    ? BusinessProductImage(
                        url: p['image']?.toString(),
                        width: 44,
                        height: 44,
                        fit: BoxFit.cover,
                      )
                    : Container(
                        color: AppColors.surfaceVariant.withAlpha(120),
                        child: Icon(
                          Icons.inventory_2_outlined,
                          size: 20,
                          color: AppColors.textSecondary,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    sub,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 10.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (rank != null)
                    RefProgress(
                      value: maxTotal <= 0 ? 0 : _d(p['total']) / maxTotal,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: _storedTotalAmount(
                p,
                color: AppColors.primary,
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.chevron_left_rounded,
              size: 20,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  //  2) الفلوس والحسابات
  // ══════════════════════════════════════════════════════════════════
  List<Widget> _moneyBody(Map data, AppLocalizations l10n) {
    final source = _resultSource;
    bool sameSource() =>
        identical(source, ref.read(businessReportsApiProvider)) &&
        (source?.isDeviceLedger != true ||
            ref.read(localMoneyReportAllowedProvider));
    final inflow = data['inflow'] as Map? ?? {};
    final outflow = data['outflow'] as Map? ?? {};
    final transfers = data['transfers'] as Map? ?? {};
    final expenses = data['expenses'] as Map? ?? {};
    final scoped = data['expense_scoped'] as Map?;
    final accounts = (data['accounts'] as List? ?? [])
        .whereType<Map>()
        .toList();
    // Scoped categories follow the SELECTED account; global otherwise.
    final expCats = ((scoped ?? expenses)['categories'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final settlements = data['settlements'] as Map? ?? {};
    final setItems =
        (settlements['items'] as List? ?? []).whereType<Map>().toList()..sort(
          (a, b) => '${b['approved_at'] ?? ''}'.compareTo(
            '${a['approved_at'] ?? ''}',
          ),
        );

    // Distinct banks (with per-bank currency counts) in reference order.
    final banks = <String, List<Map>>{};
    for (final a in accounts) {
      banks.putIfAbsent('${a['bank_name'] ?? ''}', () => []).add(a);
    }
    final bankNames = banks.keys.toList();
    final selBank = _selectedBank != null && banks.containsKey(_selectedBank)
        ? _selectedBank!
        : (bankNames.isNotEmpty ? bankNames.first : '');
    final bankAccounts = banks[selBank] ?? const [];
    // فئة-aware chips: one chip per (currency, account type) pair — «جيب»
    // with USD جاري + USD توفير shows TWO chips, never one merged currency.
    final groups = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final a in bankAccounts) {
      final ccy = '${a['currency'] ?? ''}'.toUpperCase();
      final type = '${a['account_type'] ?? 'checking'}';
      final key = '$ccy|$type';
      if (seen.contains(key)) continue;
      seen.add(key);
      final same = bankAccounts
          .where(
            (x) =>
                '${x['currency'] ?? ''}'.toUpperCase() == ccy &&
                '${x['account_type'] ?? 'checking'}' == type,
          )
          .toList();
      groups.add({
        'currency': ccy,
        'type': type,
        'balance': _sumAccounts(same, 'balance'),
        'account_id': '${same.first['id'] ?? ''}',
      });
    }
    final selKey = '$_selectedBankCcy|$_selectedType';
    Map<String, dynamic>? selGroup;
    for (final g in groups) {
      if ('${g['currency']}|${g['type']}' == selKey) {
        selGroup = g;
        break;
      }
    }
    selGroup ??= groups.isEmpty ? null : groups.first;
    if (selGroup != null && _selectedAccountId != '${selGroup['account_id']}') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !sameSource()) return;
        setState(() {
          _selectedBankCcy = '${selGroup!['currency']}';
          _selectedType = '${selGroup['type']}';
          _selectedAccountId = '${selGroup['account_id']}';
        });
        _refreshFilters(); // refetch scoped settlements + expenses
      });
    }
    final ccyAccounts = selGroup == null
        ? const <Map>[]
        : bankAccounts
              .where(
                (x) =>
                    '${x['currency'] ?? ''}'.toUpperCase() ==
                        '${selGroup!['currency']}' &&
                    '${x['account_type'] ?? 'checking'}' ==
                        '${selGroup['type']}',
              )
              .toList();
    Object? sum(String k) => _sumAccounts(ccyAccounts, k);
    final bankBalance = sum('balance');
    final selCcy = '${selGroup?['currency'] ?? ''}';
    final selType = '${selGroup?['type'] ?? 'checking'}';
    final shownSet = _allSettlements ? setItems : setItems.take(3).toList();

    Widget row(IconData ic, String label, Widget value, Color color) =>
        Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: AppColors.border.withAlpha(90)),
            ),
          ),
          child: Row(
            children: [
              Icon(ic, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              Flexible(child: value),
            ],
          ),
        );

    return [
      RefCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            row(
              Icons.south_west_rounded,
              l10n.translate('repIncome'),
              _storedTotalAmount(inflow, color: AppColors.success),
              AppColors.success,
            ),
            row(
              Icons.north_east_rounded,
              l10n.translate('repOutflow'),
              _storedTotalAmount(outflow, color: AppColors.danger),
              AppColors.danger,
            ),
            row(
              Icons.swap_horiz_rounded,
              l10n.translate('repTransfers'),
              _storedTotalAmount(transfers, color: AppColors.textSecondary),
              AppColors.textSecondary,
            ),
            row(
              Icons.compare_arrows_rounded,
              l10n.translate('repSettleAdjust'),
              _storedTotalAmount(
                _settlementTotal(data),
                color: AppColors.warning,
              ),
              AppColors.warning,
            ),
          ],
        ),
      ),
      if (source?.isDeviceLedger != true)
        ..._fxNote((inflow['gaps'] as List?) ?? const []),
      const SizedBox(height: 14),
      RefSectionHeader(
        Icons.account_balance_rounded,
        l10n.translate('repBanksAccounts'),
      ),
      const SizedBox(height: 8),
      SizedBox(
        height: 84,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: bankNames.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (_, i) {
            final name = bankNames[i];
            final accs = banks[name]!;
            final ccys = accs
                .map((a) => '${a['currency'] ?? ''}'.toUpperCase())
                .toSet()
                .length;
            final sel = name == selBank;
            return GestureDetector(
              onTap: () {
                if (!sameSource()) return;
                setState(() {
                  _selectedBank = name;
                  _selectedBankCcy = null;
                  _selectedType = null;
                  _selectedAccountId = null;
                });
                _refreshFilters();
              },
              child: Container(
                width: 150,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: sel
                      ? AppColors.primary.withAlpha(14)
                      : AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: sel ? AppColors.primary : AppColors.border,
                    width: sel ? 1.6 : 1,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isEmpty ? '—' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.translate(
                        'repCurrenciesCount',
                        params: {'n': '$ccys'},
                      ),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 10.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      if (groups.isNotEmpty) ...[
        const SizedBox(height: 14),
        RefSectionHeader(
          Icons.currency_exchange_rounded,
          l10n.translate('repCurrencyPick'),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 88,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: groups.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, i) {
              final g = groups[i];
              final c = '${g['currency']}';
              final type = '${g['type']}';
              final isSel =
                  selGroup != null && '${g['currency']}|${g['type']}' == selKey;
              final typeColor = accountTypeBarColor(type);
              return GestureDetector(
                onTap: () {
                  if (!sameSource()) return;
                  setState(() {
                    _selectedBankCcy = c;
                    _selectedType = type;
                    _selectedAccountId = '${g['account_id']}';
                  });
                  _refreshFilters();
                },
                child: Container(
                  width: 158,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: isSel
                        ? AppColors.primary.withAlpha(14)
                        : AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isSel ? AppColors.primary : AppColors.border,
                      width: isSel ? 1.6 : 1,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: AlignmentDirectional.centerStart,
                              child: Text(
                                c,
                                maxLines: 1,
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 0.5,
                              ),
                              decoration: BoxDecoration(
                                color: typeColor.withAlpha(24),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                accountTypeLabel(
                                  AppLocalizations.of(context),
                                  type,
                                ),
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 8,
                                  fontWeight: FontWeight.w700,
                                  color: typeColor,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              l10n.translate('repBalanceLbl'),
                              maxLines: 1,
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 10.5,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: _amount(
                              g['balance'],
                              ccy: g['currency'],
                              color: AppColors.textSecondary,
                              style: const TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
      if (ccyAccounts.isNotEmpty) ...[
        const SizedBox(height: 14),
        RefCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  RefIconChip(Icons.account_balance_rounded),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          selBank.isEmpty ? '—' : selBank,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          ccyAccounts
                              .map((a) => '${a['account_name'] ?? ''}')
                              .where((s) => s.isNotEmpty)
                              .join(' • '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 10.5,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: accountTypeBarColor(selType).withAlpha(22),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      accountTypeLabel(AppLocalizations.of(context), selType),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: accountTypeBarColor(selType),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                l10n.translate('repBalanceNow'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: _accountAmount(
                  bankBalance,
                  ccy: selCcy,
                  color: AppColors.primary,
                  alignment: AlignmentDirectional.centerStart,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 20),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              row(
                Icons.south_west_rounded,
                l10n.translate('repIncome'),
                _accountAmount(
                  sum('inflow'),
                  ccy: selCcy,
                  color: AppColors.success,
                ),
                AppColors.success,
              ),
              row(
                Icons.north_east_rounded,
                l10n.translate('repOutflow'),
                _accountAmount(
                  sum('outflow'),
                  ccy: selCcy,
                  color: AppColors.danger,
                ),
                AppColors.danger,
              ),
              row(
                Icons.swap_horiz_rounded,
                l10n.translate('repTransfers'),
                _accountAmount(
                  sum('transfers'),
                  ccy: selCcy,
                  color: AppColors.textSecondary,
                ),
                AppColors.textSecondary,
              ),
              row(
                Icons.compare_arrows_rounded,
                l10n.translate('repSettlements'),
                _accountAmount(
                  sum('settlements'),
                  ccy: selCcy,
                  color: AppColors.warning,
                ),
                AppColors.warning,
              ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 14),
      if (expCats.isNotEmpty)
        RefCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RefSectionHeader(
                Icons.receipt_long_outlined,
                l10n.translate(
                  _storedReport && (scoped ?? expenses)['total'] == null
                      ? 'repLocalExpenseCategories'
                      : 'repTopExpenseCats',
                ),
                color: AppColors.warning,
              ),
              const SizedBox(height: 4),
              for (final c in expCats)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: AppColors.border.withAlpha(80)),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${c['category'] ?? l10n.translate('repExpenseOther')}',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: AlignmentDirectional.centerEnd,
                          child: Text(
                            _storedTotalText(c),
                            maxLines: 1,
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: AppColors.warning,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      if (setItems.isNotEmpty) ...[
        const SizedBox(height: 14),
        RefCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RefSectionHeader(
                Icons.receipt_long_outlined,
                l10n.translate('repSettlements'),
                actionLabel:
                    '${_allSettlements ? setItems.length : shownSet.length}',
              ),
              const SizedBox(height: 4),
              for (final s in shownSet)
                for (final line
                    in ((s['settlements'] as List? ?? []).whereType<Map>()))
                  _settlementRow(l10n, s, line),
              if (setItems.length > 3) ...[
                const SizedBox(height: 6),
                RefPill(
                  label: _allSettlements
                      ? l10n.translate('repShowLessSettlements')
                      : l10n.translate(
                          'repShowAllSettlements',
                          params: {'n': '${setItems.length}'},
                        ),
                  onTap: () =>
                      setState(() => _allSettlements = !_allSettlements),
                ),
              ],
            ],
          ),
        ),
      ],
    ];
  }

  Widget _settlementRow(AppLocalizations l10n, Map s, Map line) {
    final date = '${s['approved_at'] ?? ''}'.split('T').first;
    final name = '${line['name'] ?? ''}';
    final ccy = '${line['currency'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          RefIconChip(Icons.description_outlined, size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$date • $name',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 1),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _amount(
                        line['before'],
                        ccy: ccy,
                        color: AppColors.primary,
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 5),
                        child: Text(
                          '←',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            color: AppColors.primary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      _amount(
                        line['after'],
                        ccy: ccy,
                        color: AppColors.primary,
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_left_rounded,
            size: 20,
            color: AppColors.textSecondary,
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  //  3) المخزون
  // ══════════════════════════════════════════════════════════════════
  List<Widget> _inventoryBody(Map data, AppLocalizations l10n) {
    final low = (data['low_stock'] as List? ?? []).whereType<Map>().toList();
    final out = (data['out_of_stock'] as List? ?? []).whereType<Map>().toList();
    final expiring = (data['expiring_soon'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final moved = (data['most_moved'] as List? ?? []).whereType<Map>().toList();
    final counting = data['counting'] as Map? ?? {};
    final countingItems = (counting['items'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final hasCost = data['stock_value'] != null;
    final shownMoved = _allMoved ? moved : moved.take(5).toList();
    final shownCounting = _allCounting
        ? countingItems
        : countingItems.take(3).toList();
    return [
      // Hero: stock value + 3 counts.
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: AlignmentDirectional.topStart,
            end: AlignmentDirectional.bottomEnd,
            colors: [AppColors.primary.withAlpha(14), AppColors.surface],
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.translate('repStockValueHero'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                RefIconChip(Icons.storage_rounded, size: 36),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: hasCost || _storedReport
                      ? _storedTotalAmount(
                          _stockAmount(data),
                          color: AppColors.primary,
                          alignment: AlignmentDirectional.centerStart,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 22),
                            fontWeight: FontWeight.w800,
                          ),
                        )
                      : Text(
                          '—',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 22),
                            color: AppColors.primary,
                          ),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(height: 1, color: AppColors.border.withAlpha(110)),
            const SizedBox(height: 10),
            IntrinsicHeight(
              child: Row(
                children: [
                  _invCount(
                    Icons.inventory_2_outlined,
                    data['products'],
                    l10n.translate('repProducts'),
                  ),
                  _vDiv(),
                  _invCount(
                    Icons.style_outlined,
                    data['categories'],
                    l10n.translate(
                      _storedReport
                          ? 'repTransferredCategories'
                          : 'repCategories',
                    ),
                  ),
                  _vDiv(),
                  _invCount(
                    Icons.straighten_rounded,
                    data['units'],
                    l10n.translate('repUnits'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      Row(
        children: [
          Expanded(
            child: _miniStatCard(
              l10n.translate('repLowStock'),
              '${_d(data['low_count']).round()}',
              AppColors.warning,
              Icons.inventory_outlined,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _miniStatCard(
              l10n.translate('repOutOfStock'),
              '${_d(data['out_count']).round()}',
              AppColors.danger,
              Icons.cancel_outlined,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _miniStatCard(
              l10n.translate('repExpiring'),
              '${_d(data['expiring_count']).round()}',
              AppColors.success,
              Icons.calendar_month_outlined,
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      RefCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RefSectionHeader(
              Icons.bar_chart_rounded,
              l10n.translate('repMostMoved'),
              actionLabel: moved.length > 5
                  ? l10n.translate('repShowAll')
                  : null,
              onAction: () => setState(() => _allMoved = !_allMoved),
            ),
            const SizedBox(height: 4),
            if (moved.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Center(
                  child: Text(
                    l10n.translate('repNone'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              )
            else
              for (final m in shownMoved) _movedRow(l10n, m),
          ],
        ),
      ),
      if (countingItems.isNotEmpty) ...[
        const SizedBox(height: 14),
        RefCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RefSectionHeader(
                Icons.fact_check_outlined,
                l10n.translate('repStocktake'),
                actionLabel: countingItems.length > 3
                    ? l10n.translate(
                        _allCounting ? 'repShowLess' : 'repShowAll',
                      )
                    : null,
                onAction: () => setState(() => _allCounting = !_allCounting),
              ),
              const SizedBox(height: 4),
              for (final s in shownCounting) _countingRow(l10n, s),
            ],
          ),
        ),
      ],
      if (!_storedReport) ..._fxNote((data['gaps'] as List?) ?? const []),
    ];
  }

  Widget _invCount(IconData ic, dynamic v, String label) => Expanded(
    child: Column(
      children: [
        RefIconChip(ic, size: 30),
        const SizedBox(height: 4),
        Text(
          v == null ? '—' : '${_d(v).round()}',
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 10.5,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    ),
  );

  Widget _vDiv() => Container(
    width: 1,
    height: 44,
    color: AppColors.border.withAlpha(120),
    margin: const EdgeInsets.symmetric(horizontal: 4),
  );

  Widget _miniStatCard(String label, String value, Color color, IconData ic) {
    return RefCard(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: ReportFitText(
                  text: value,
                  alignment: AlignmentDirectional.centerEnd,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              RefIconChip(ic, color: color, size: 30),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 10,
              color: AppColors.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _movedRow(AppLocalizations l10n, Map m) {
    final unit = '${m['unit'] ?? ''}'.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${m['name'] ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          Text(
            unit.isEmpty ? '${_f(m['moved'])}' : '${_f(m['moved'])} $unit',
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 12.5,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _countingRow(AppLocalizations l10n, Map s) {
    final date = '${s['approved_at'] ?? ''}'.split('T').first;
    final lines = ((s['settlements'] as List? ?? []).whereType<Map>()).length;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => context.push(RouteNames.reconciliation),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            RefIconChip(Icons.fact_check_outlined, size: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$date',
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 11,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  Text(
                    l10n.translate('repReconciled'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      color: AppColors.success,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              l10n.translate('repProductsCount', params: {'n': '$lines'}),
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.chevron_left_rounded,
              size: 20,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  //  4) الديون
  // ══════════════════════════════════════════════════════════════════
  List<Widget> _debtsBody(Map data, AppLocalizations l10n) {
    final customers = data['customers'] as Map? ?? {};
    final suppliers = data['suppliers'] as Map? ?? {};
    final collected = data['collected'] as Map? ?? {};
    final paidSup = data['paid_to_suppliers'] as Map? ?? {};
    final custTop = (customers['top'] as List? ?? []).whereType<Map>().toList();
    final supTop = (suppliers['top'] as List? ?? []).whereType<Map>().toList();
    final movements = (data['recent_movements'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final shownMovements = _allMovements
        ? movements
        : movements.take(3).toList();

    Widget summaryCard({
      required String title,
      required IconData icon,
      required Color tint,
      required Map value,
      required VoidCallback onToggle,
    }) {
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: tint.withAlpha(20),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: tint.withAlpha(60)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                RefIconChip(icon, color: tint, size: 28),
              ],
            ),
            _storedTotalAmount(
              value,
              color: tint,
              alignment: AlignmentDirectional.centerStart,
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const Spacer(),
            Container(height: 1, color: tint.withAlpha(40)),
            const SizedBox(height: 6),
            GestureDetector(
              onTap: onToggle,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      l10n.translate('repViewDetails'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_left_rounded,
                    size: 20,
                    color: AppColors.primary,
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return [
      RefCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            _debtRow(
              Icons.group_outlined,
              l10n.translate('repCustomersDebts'),
              _storedTotalAmount(customers, color: AppColors.warning),
              AppColors.warning,
            ),
            _debtRow(
              Icons.local_shipping_outlined,
              l10n.translate('repSuppliersDebts'),
              _storedTotalAmount(suppliers, color: AppColors.danger),
              AppColors.danger,
            ),
            _debtRow(
              Icons.south_west_rounded,
              l10n.translate('repCollected'),
              _storedTotalAmount(collected, color: AppColors.success),
              AppColors.success,
            ),
            _debtRow(
              Icons.north_east_rounded,
              l10n.translate('repPaidSuppliers'),
              _storedTotalAmount(paidSup, color: AppColors.success),
              AppColors.success,
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: summaryCard(
                title: l10n.translate('repYouGetFromCustomers'),
                icon: Icons.group_outlined,
                tint: AppColors.success,
                value: customers,
                onToggle: () => context.push('/debts/customers'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: summaryCard(
                title: l10n.translate('repYouOweSuppliers'),
                icon: Icons.local_shipping_outlined,
                tint: AppColors.danger,
                value: suppliers,
                onToggle: () => context.push('/debts/suppliers'),
              ),
            ),
          ],
        ),
      ),
      if (movements.isNotEmpty) ...[
        const SizedBox(height: 14),
        RefCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RefSectionHeader(
                Icons.receipt_long_outlined,
                l10n.translate('repMovementsTitle'),
                actionLabel: movements.length > 3
                    ? l10n.translate(
                        _allMovements ? 'repShowLess' : 'repShowAll',
                      )
                    : null,
                onAction: () => setState(() => _allMovements = !_allMovements),
              ),
              const SizedBox(height: 4),
              for (final m in shownMovements) _movementRow(l10n, m),
            ],
          ),
        ),
      ],
    ];
  }

  Widget _debtRow(IconData ic, String label, Widget value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.border.withAlpha(90)),
        ),
      ),
      child: Row(
        children: [
          Icon(ic, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          Flexible(child: value),
        ],
      ),
    );
  }

  Widget _movementRow(AppLocalizations l10n, Map m) {
    final isCustomer = '${m['kind']}' == 'customer';
    final amount = _d(m['amount']);
    final positive = amount >= 0;
    final color = positive ? AppColors.success : AppColors.danger;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          RefIconChip(
            isCustomer ? Icons.group_outlined : Icons.local_shipping_outlined,
            color: isCustomer ? AppColors.success : AppColors.danger,
            size: 32,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _partyLabel(m['party'], l10n),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  isCustomer
                      ? l10n.translate('repDebtPay')
                      : l10n.translate('repSuppPay'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 10.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${m['date'] ?? ''}',
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 10.5,
                  color: AppColors.textSecondary,
                ),
              ),
              SizedBox(
                width: 138,
                child: ReportFitText(
                  text:
                      '${positive ? '+' : '-'} ${_money(amount.abs(), ccy: m['currency'] as String?)}',
                  alignment: AlignmentDirectional.centerEnd,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
          Icon(
            Icons.chevron_left_rounded,
            size: 20,
            color: AppColors.textSecondary,
          ),
        ],
      ),
    );
  }

  bool get _storedReport => _data?['local_valuation'] == 'as_recorded';

  String _accountAmountText(dynamic value, String? ccy) =>
      value == null && _storedReport ? '—' : _money(value, ccy: ccy);

  Widget _accountAmount(
    dynamic value, {
    required String ccy,
    required Color color,
    TextStyle? style,
    AlignmentDirectional alignment = AlignmentDirectional.centerEnd,
  }) => value == null && _storedReport
      ? Text('—', style: TextStyle(color: color))
      : _amount(
          value,
          ccy: ccy,
          color: color,
          style: style,
          alignment: alignment,
        );

  Object? _sumAccounts(List<Map> accounts, String key) {
    if (!_storedReport) {
      return accounts.fold<double>(0, (sum, row) => sum + _d(row[key]));
    }
    var total = BigInt.zero;
    for (final row in accounts) {
      final amount = row[key];
      if (amount is! String) return null;
      total += BigInt.parse(amount.replaceFirst('.', ''));
    }
    return BusinessMoney.displayTotal(total);
  }

  String _storedTotalText(Map section, {String? ccy}) =>
      section['total'] != null || !_storedReport
      ? _money(section['total'], ccy: ccy ?? section['currency'] as String?)
      : _perCcyText(section['per_currency']);

  Map _stockAmount(Map data) => {
    'total': data['stock_value'],
    'per_currency': data['stock_value_per_currency'],
  };

  String _stockValueText(Map data) =>
      !_storedReport && data['stock_value'] == null
      ? '—'
      : _storedTotalText(_stockAmount(data));

  Widget _storedTotalAmount(
    Map section, {
    required Color color,
    TextStyle? style,
    AlignmentDirectional alignment = AlignmentDirectional.centerEnd,
    bool profit = false,
  }) {
    if (section['total'] != null || !_storedReport) {
      return _amount(
        section['total'],
        ccy: section['currency'] as String?,
        color: color,
        style: style,
        alignment: alignment,
      );
    }
    final rows = (section['per_currency'] as List? ?? [])
        .whereType<Map>()
        .toList();
    if (rows.isEmpty) {
      return profit
          ? ReportProfitUnavailable(
              data: _data,
              section: section,
              style: (style ?? const TextStyle()).copyWith(color: color),
            )
          : Text('—', style: TextStyle(color: color));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in rows)
          _amount(
            row['total'],
            ccy: row['currency'] as String?,
            color: color,
            style: style,
            alignment: alignment,
          ),
      ],
    );
  }

  String _perCcyText(dynamic debts) {
    if (debts is! List) return '—';
    final value = debts
        .whereType<Map>()
        .map((d) => _money(d['total'], ccy: d['currency']))
        .join(' • ');
    return value.isEmpty ? '—' : value;
  }

  // ══════════════════════════════════════════════════════════════════
  //  5) نظرة شاملة
  // ══════════════════════════════════════════════════════════════════
  List<Widget> _overviewBody(Map data, AppLocalizations l10n) {
    final sales = data['sales'] as Map? ?? {};
    final pur = data['purchases'] as Map? ?? {};
    final profit = data['profit'] as Map? ?? {};
    final expenses = data['expenses'] as Map? ?? {};
    final cust = data['customer_debt'] as Map? ?? {};
    final supp = data['supplier_debt'] as Map? ?? {};
    final inv = data['inventory'] as Map? ?? {};
    final comparison = data['comparison'] as Map? ?? {};
    final soldDelta = _d(comparison['sold_delta']);
    final prevBuy = _storedReport ? 'prev_purchases' : 'prev_spent';
    final buyDelta = _storedReport ? 'purchases_delta' : 'spent_delta';
    final comparisonLabel = l10n.translate(
      _storedReport ? 'repLocalPreviousPeriod' : 'repVsLastMonth',
    );
    final chart = (data['chart'] as List? ?? []).whereType<Map>().toList();
    final profitColor = _d(profit['total']) >= 0
        ? AppColors.success
        : AppColors.danger;

    Widget trendBadge() {
      final up = soldDelta >= 0;
      final color = up ? AppColors.success : AppColors.danger;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withAlpha(24),
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
              '${up ? '+' : '-'} ${_money(soldDelta.abs())}',
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

    Widget cmpCard({
      required String title,
      required IconData icon,
      required Color tint,
      required Map section,
      required Color valueColor,
      String? deltaLine,
      Color? deltaColor,
    }) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: tint.withAlpha(16),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: tint.withAlpha(50)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: tint.withAlpha(26),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 17, color: tint),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _storedTotalAmount(
              section,
              color: valueColor,
              profit: identical(section, profit),
              alignment: AlignmentDirectional.centerStart,
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontSize: 15.5,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (deltaLine != null) ...[
              const SizedBox(height: 2),
              Text(
                deltaLine,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 10.5,
                  color: deltaColor ?? AppColors.textSecondary,
                ),
              ),
            ],
          ],
        ),
      );
    }

    String pct(double delta, double prev) => prev <= 0
        ? ''
        : '${delta >= 0 ? '+' : '-'} ${(delta / prev * 100).abs().toStringAsFixed(0)}% ';

    return [
      RefCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.translate('repTrend'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                if (!_storedReport || comparison['sold_delta'] != null)
                  trendBadge(),
              ],
            ),
            const SizedBox(height: 6),
            _debtRow(
              Icons.shopping_cart_outlined,
              l10n.translate('repSales'),
              _storedTotalAmount(sales, color: AppColors.primary),
              AppColors.primary,
            ),
            _debtRow(
              Icons.south_west_rounded,
              l10n.translate('repIncome'),
              _storedTotalAmount(
                data['income'] as Map? ?? {},
                color: AppColors.success,
              ),
              AppColors.success,
            ),
            _debtRow(
              Icons.local_shipping_outlined,
              l10n.translate('repPurchases'),
              _storedTotalAmount(pur, color: AppColors.primary),
              AppColors.primary,
            ),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: AppColors.border.withAlpha(90)),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.trending_up_rounded, size: 18, color: profitColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.translate('repProfit'),
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          l10n.translate('repProfitNote'),
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 9.5,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_storedReport && profit['total'] == null &&
                      ((profit['per_currency'] as List?) ?? const []).isEmpty)
                    ReportProfitUnavailable(
                      data: data,
                      section: profit,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        color: profitColor,
                      ),
                    )
                  else
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerEnd,
                      child: Text(
                        _storedTotalText(profit),
                        maxLines: 1,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                          color: profitColor,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _debtRow(
              Icons.receipt_long_outlined,
              l10n.translate('repExpenses'),
              _storedTotalAmount(expenses, color: AppColors.warning),
              AppColors.warning,
            ),
            _debtRow(
              Icons.group_outlined,
              l10n.translate('repCustomersDebts'),
              _storedTotalAmount(cust, color: AppColors.warning),
              AppColors.warning,
            ),
            _debtRow(
              Icons.local_shipping_outlined,
              l10n.translate('repSuppliersDebts'),
              _storedTotalAmount(supp, color: AppColors.danger),
              AppColors.danger,
            ),
            _debtRow(
              Icons.inventory_2_outlined,
              l10n.translate('repStockValue'),
              inv['stock_value'] == null && !_storedReport
                  ? const Text('—')
                  : _storedTotalAmount(
                      _stockAmount(inv),
                      color: AppColors.primary,
                    ),
              AppColors.primary,
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: cmpCard(
              title: l10n.translate('repSales'),
              icon: Icons.north_east_rounded,
              tint: AppColors.success,
              section: sales,
              valueColor: AppColors.primary,
              deltaLine:
                  comparison['sold_delta'] != null &&
                      _d(comparison['prev_sold']) > 0
                  ? '${pct(soldDelta, _d(comparison['prev_sold']))}'
                        '$comparisonLabel'
                  : null,
              deltaColor: soldDelta >= 0 ? AppColors.success : AppColors.danger,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: cmpCard(
              title: l10n.translate('repPurchases'),
              icon: Icons.south_east_rounded,
              tint: AppColors.danger,
              section: pur,
              valueColor: AppColors.primary,
              deltaLine:
                  comparison[buyDelta] != null && _d(comparison[prevBuy]) > 0
                  ? '${pct(_d(comparison[buyDelta]), _d(comparison[prevBuy]))}'
                        '$comparisonLabel'
                  : null,
              deltaColor: _d(comparison[buyDelta]) >= 0
                  ? AppColors.danger
                  : AppColors.success,
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: cmpCard(
              title: l10n.translate('repProfit'),
              icon: Icons.trending_up_rounded,
              tint: AppColors.success,
              section: profit,
              valueColor: profitColor,
              deltaLine:
                  comparison['profit_delta'] != null &&
                      _d(comparison['prev_profit']) != 0
                  ? '${pct(_d(comparison['profit_delta']), _d(comparison['prev_profit']).abs())}'
                        '$comparisonLabel'
                  : null,
              deltaColor: _d(comparison['profit_delta']) >= 0
                  ? AppColors.success
                  : AppColors.danger,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: cmpCard(
              title: l10n.translate('repStockValue'),
              icon: Icons.inventory_2_outlined,
              tint: AppColors.primary,
              section: _stockAmount(inv),
              valueColor: AppColors.primary,
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      RefPill(
        label: _showBreakdown
            ? l10n.translate('repHideBreakdown')
            : l10n.translate('repShowBreakdown'),
        icon: Icons.pie_chart_rounded,
        onTap: () => setState(() => _showBreakdown = !_showBreakdown),
      ),
      if (_showBreakdown && chart.isNotEmpty) ...[
        const SizedBox(height: 12),
        RefCard(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            height: 170,
            child: AnimatedReportChart(
              points: [
                for (final p in chart)
                  ChartPoint(
                    label: '${p['date']}'.substring(5),
                    value: _d(p['value']),
                  ),
              ],
              color: AppColors.primary,
            ),
          ),
        ),
      ],
      if (_showBreakdown && chart.isEmpty && _storedReport)
        Text(
          l10n.translate(
            data['chart'] == null ? 'repLocalChartUnavailable' : 'repEmpty',
          ),
        ),
    ];
  }

  List<Widget> _fxNote(List? gaps) {
    if (gaps == null || gaps.isEmpty) return [];
    // ONE warning per report (merged) — never a stack of repeats.
    final text = singleFxNotice(AppLocalizations.of(context), [
      {'gaps': gaps},
    ], _currency);
    if (text == null) return [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: singleFxCard(text),
      ),
    ];
  }
}
