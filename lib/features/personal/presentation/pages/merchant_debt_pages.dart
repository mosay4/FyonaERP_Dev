import 'dart:convert';

import 'package:flutter/material.dart';
import '../../../../shared/widgets/invoice_amount.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/services/currency/enabled_currencies_service.dart';
import '../../../../core/services/connectivity_service.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/amount_input_formatter.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../../shared/widgets/chat_unread_icon.dart';
import '../../../core_business/presentation/widgets/debt_widgets.dart';
import '../../../core_business/presentation/widgets/debt_settlement.dart';
import '../../../core_business/presentation/providers/business_debt_operation_source.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../../core_business/presentation/providers/business_cash_alerts.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../data/merchant_api.dart';
import '../providers/merchant_unread_provider.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

/// Personal-side commercial-debt screens per the «Debt References» PDFs:
/// merchant overview (total + currency switcher + individual/sections tabs),
/// sections grid, section operations, operation detail, and the isolated
/// debt-notification center. Popular wording, real data only.
String _fmt(dynamic v) {
  final d = (v is num) ? v.toDouble() : (num.tryParse('$v') ?? 0).toDouble();
  return d == d.roundToDouble() ? d.round().toString() : d.toStringAsFixed(2);
}

/// Correct Arabic invoice count: فاتورة واحدة / فاتورتان / 3 فواتير / 11 فاتورة.
String _invoiceCountLabel(AppLocalizations l10n, int n) {
  if (n == 1) return l10n.translate('debtInvoicesOne');
  if (n == 2) return l10n.translate('debtInvoicesTwo');
  if (n >= 3 && n <= 10) {
    return l10n.translate('debtInvoicesFew', params: {'n': '$n'});
  }
  return l10n.translate('debtInvoicesMany', params: {'n': '$n'});
}

class DebtNotificationsPage extends ConsumerStatefulWidget {
  /// When set, ONLY this commercial relationship's notifications are shown.
  final String? linkId;
  final String? partyName;
  final bool isPersonal;
  final int initialTab;
  const DebtNotificationsPage(
      {super.key,
      this.linkId,
      this.partyName,
      this.isPersonal = false,
      this.initialTab = 0});
  @override
  ConsumerState<DebtNotificationsPage> createState() =>
      _DebtNotificationsPageState();
}

class _DebtNotificationsPageState extends ConsumerState<DebtNotificationsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(
      length: widget.isPersonal ? 4 : 2,
      initialIndex: widget.initialTab.clamp(
          0, (widget.isPersonal ? 4 : 2) - 1),
      vsync: this);
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _cashAlerts = const [];
  DirectoryAccess? _cashScope;
  int _businessLoad = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final scope = widget.isPersonal || widget.linkId != null
        ? null
        : ref.read(businessLocalLedgerScopeProvider);
    if (scope == null) {
      _load();
    } else {
      _cashScope = scope;
      _loading = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _tab.addListener(_markVisibleCashAlerts);
        _load();
      });
    }
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  String _cat(Map n) {
    final c = '${n['category'] ?? ''}';
    if (c.isNotEmpty) return c;
    final t = '${n['type'] ?? ''}';
    if (t == 'chat_message') return 'chat';
    if (t.startsWith('settlement') || t == 'payment') return 'settlement';
    return 'debt';
  }

  Future<void> _load() async {
    final scope = widget.isPersonal || widget.linkId != null
        ? null : ref.read(businessLocalLedgerScopeProvider);
    final load = widget.isPersonal ? 0 : ++_businessLoad;
    bool stillSelected() => mounted &&
        (widget.isPersonal || (load == _businessLoad &&
          (scope == null || sameDirectoryScope(scope, ref.read(businessLocalLedgerScopeProvider)))));
    setState(() {
      _loading = scope == null;
      if (!sameDirectoryScope(_cashScope, scope)) {
        _cashScope = scope;
        _cashAlerts = const [];
        _items = [];
      }
    });
    if (scope != null) {
      try {
        final local = await businessCashAlerts(ref, scope, AppLocalizations.of(context));
        if (!stillSelected()) return;
        setState(() => _cashAlerts = local);
        _markVisibleCashAlerts();
      } catch (_) {
        // A failed/denied local read is not permission to expose another scope.
      }
      if (!stillSelected() || !ref.read(connectivityServiceProvider).isOnline) return;
    }
    try {
      final side = widget.isPersonal ? 'personal' : 'merchant';
      final d = await ref
          .read(merchantApiProvider)
          .debtNotifications(linkId: widget.linkId, side: side);
      if (!stillSelected()) return;
      final items = (d['items'] as List? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      setState(() {
        _items = items;
        _loading = false;
      });
      final unreadIds = items
          .where((n) => n['is_read'] != true)
          .map((n) => '${n['id']}')
          .toList();
      if (unreadIds.isNotEmpty) {
        try {
          await ref
              .read(merchantApiProvider)
              .markDebtNotificationsRead(ids: unreadIds);
          ref.invalidate(debtUnreadProvider(widget.isPersonal ? 'personal' : 'merchant'));
          ref.invalidate(
              chatUnreadProvider(widget.isPersonal ? 'personal' : 'merchant'));
        } catch (_) {}
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> _of(String cat) =>
      _items.where((n) => _cat(n) == cat).toList();

  bool _markingCashAlerts = false;
  Future<void> _markVisibleCashAlerts() async {
    final scope = _cashScope;
    if (scope == null || _tab.index != 1 || _tab.indexIsChanging ||
        _markingCashAlerts || _cashAlerts.every((row) => row['is_read'] == true)) return;
    _markingCashAlerts = true;
    try {
      for (final row in _cashAlerts.where((row) => row['is_read'] != true)) {
        if (!mounted || _tab.index != 1) return;
        await markBusinessCashAlertRead(ref, scope, row['id'] as String);
      }
    } catch (_) {
      // Retry on the next page open; the on-disk notice is still present.
    } finally {
      _markingCashAlerts = false;
    }
  }

  Map _payloadOf(Map n) {
    final raw = n['action_payload'];
    if (raw is Map) return raw;
    try {
      final d = jsonDecode('$raw');
      return d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  void _open(Map n) {
    final payload = _payloadOf(n);
    final linkId = '${payload['link_id'] ?? ''}';
    final msgId = '${payload['message_id'] ?? ''}';
    final type = '${n['type'] ?? ''}';
    if (!widget.isPersonal && type == 'business_cash_reversed') {
      if (_cashScope == null ||
          !sameDirectoryScope(_cashScope, ref.read(businessLocalLedgerScopeProvider)) ||
          !businessCashAlertPermissions.every((key) => ref.read(employeeCanProvider(key)))) {
        return;
      }
      final l10n = AppLocalizations.of(context);
      showDialog<void>(
        context: context,
        builder: (ctx) => Consumer(
          builder: (_, r, _) {
            final selected = r.watch(businessLocalLedgerScopeProvider);
            final permissions = [
              for (final key in businessCashAlertPermissions) r.watch(employeeCanProvider(key)),
            ];
            final canRead = sameDirectoryScope(_cashScope, selected) && permissions.every((p) => p);
            final reference = r.watch(employeeCanProvider('transactions')) ? n['blocked_by'] : null;
            return AlertDialog(
              title: Text('${n['title']}'),
              content: Text(canRead ? [
                '${n['message']}',
                if (reference != null)
                  l10n.translate('bizCashConflictReference', params: {'id': reference}),
              ].join('\n') : l10n.translate('unauthorized')),
              actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.translate('saleClose')))],
            );
          },
        ),
      );
      return;
    }
    var route = '${n['route'] ?? ''}';
    // Keep the exact deep link whenever it belongs to the CURRENT side (so a
    // debt notification opens its invoice via ?op=, a settlement keeps ?req=).
    if (widget.isPersonal) {
      if (type == 'chat_message' && linkId.isNotEmpty) {
        route =
            '/personal/chat?link=$linkId${msgId.isNotEmpty ? '&msg=$msgId' : ''}';
      } else if (!route.startsWith('/personal')) {
        route = linkId.isNotEmpty
            ? '/personal/merchant-partner?link=$linkId'
            : RouteNames.personalMerchantAccounts;
      }
    } else {
      if (type == 'chat_message' && linkId.isNotEmpty) {
        route =
            '/debts/chat?link=$linkId${msgId.isNotEmpty ? '&msg=$msgId' : ''}';
      } else if (!(route.startsWith('/customers') ||
          route.startsWith('/suppliers') ||
          route.startsWith('/debts'))) {
        route = '/debts/notifications';
      }
    }
    if (route.isNotEmpty) {
      context.push(route);
    } else {
      context.push(RouteNames.personalMerchantAccounts);
    }
  }

  IconData _icon(String cat) => switch (cat) {
        'chat' => Icons.chat_bubble_outline,
        'settlement' => Icons.payments_outlined,
        'alert' => Icons.notifications_active_outlined,
        _ => Icons.receipt_long_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scope = _cashScope;
    final current = scope == null || sameDirectoryScope(scope, ref.watch(businessLocalLedgerScopeProvider));
    final canSeeCash = scope != null && [
      for (final key in businessCashAlertPermissions) ref.watch(employeeCanProvider(key)),
    ].every((granted) => granted);
    final name = (widget.partyName ?? '').trim();
    final title = name.isNotEmpty
        ? l10n.translate('debtNotifForParty', params: {'name': name})
        : l10n.translate('debtNotifCenter');
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
      ),
      body: Column(children: [
        _tabs(l10n),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(controller: _tab, children: widget.isPersonal
                  ? [
                      _list(l10n, _of('debt'), 'debt'),
                      _list(l10n, _of('settlement'), 'settlement'),
                      _list(l10n, _of('chat'), 'chat'),
                      _list(l10n, _of('alert'), 'alert'),
                    ]
                  : [
                      _list(l10n, current ? _of('chat') : [], 'chat'),
                      _list(
                          l10n,
                          [
                            if (current && canSeeCash) ..._cashAlerts,
                            if (current) ..._items.where((n) => _cat(n) != 'chat'),
                          ],
                          'alert'),
                    ]),
        ),
      ]),
    );
  }

  Widget _tabs(AppLocalizations l10n) {
    final dark = DebtStyle.dark(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF2A2026) : const Color(0xFFF6E9ED),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DebtStyle.red.withAlpha(40)),
      ),
      child: TabBar(
        controller: _tab,
        indicator: BoxDecoration(
            color: DebtStyle.red, borderRadius: BorderRadius.circular(11)),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        labelColor: Colors.white,
        unselectedLabelColor: dark ? Colors.white70 : DebtStyle.red,
        labelStyle: const TextStyle(
            fontFamily: 'Cairo', fontSize: 12.5, fontWeight: FontWeight.w800),
        unselectedLabelStyle: const TextStyle(
            fontFamily: 'Cairo', fontSize: 12.5, fontWeight: FontWeight.w700),
        labelPadding: EdgeInsets.zero,
        tabs: widget.isPersonal
            ? [
                _tabItem(Icons.receipt_long_outlined, 'debtNotifTabDebts', l10n),
                _tabItem(Icons.payments_outlined, 'debtNotifTabSettlement', l10n),
                _tabItem(Icons.chat_bubble_outline, 'debtNotifTabMessages', l10n),
                _tabItem(
                    Icons.notifications_active_outlined, 'debtNotifTabAlerts', l10n),
              ]
            : [
                _tabItem(Icons.chat_bubble_outline, 'debtNotifTabMessages', l10n),
                _tabItem(
                    Icons.notifications_active_outlined, 'debtNotifTabAlerts', l10n),
              ],
      ),
    );
  }

  Tab _tabItem(IconData icon, String labelKey, AppLocalizations l10n) => Tab(
        height: 42,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 14),
              const SizedBox(width: 4),
              Text(l10n.translate(labelKey),
                  maxLines: 1,
                  style: const TextStyle(
                      fontFamily: 'Cairo', fontSize: 11.5, height: 1.2)),
            ]),
          ),
        ),
      );

  Widget _list(
      AppLocalizations l10n, List<Map<String, dynamic>> items, String cat) {
    if (items.isEmpty) {
      return Center(
        child: Text(l10n.translate('debtNotifEmptyTab'),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 13,
                color: AppColors.textSecondary)),
      );
    }
    return FyonaRefresh(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        itemCount: items.length,
        itemBuilder: (_, i) {
          final n = items[i];
          final read = n['is_read'] == true;
          final settlement = cat == 'settlement';
          return GestureDetector(
            onTap: () => _open(n),
            child: Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: read ? AppColors.surface : AppColors.primary.withAlpha(14),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: read
                        ? AppColors.border
                        : AppColors.primary.withAlpha(60)),
              ),
              child: Row(children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                      color: AppColors.primary.withAlpha(22),
                      borderRadius: BorderRadius.circular(11)),
                  child: Icon(_icon(cat),
                      size: 20, color: AppColors.primary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(
                            child: Text('${n['title'] ?? ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.textPrimary)),
                          ),
                          if (!read)
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                  color: DebtStyle.red,
                                  shape: BoxShape.circle),
                            ),
                        ]),
                        const SizedBox(height: 2),
                        Text('${n['message'] ?? ''}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 11.5,
                                color: AppColors.textSecondary)),
                        if (settlement) ...[
                          const SizedBox(height: 5),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                                color: const Color(0xFF1F9D55).withAlpha(20),
                                borderRadius: BorderRadius.circular(7)),
                            child: Text(
                                l10n.translate('debtNotifTabSettlement'),
                                style: const TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF1F9D55))),
                          ),
                        ],
                        const SizedBox(height: 2),
                        Text(
                            '${'${n['created_at'] ?? ''}'.split('T').first}',
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 10,
                                color: AppColors.textSecondary)),
                      ]),
                ),
                const DebtArrow(),
              ]),
            ),
          );
        },
      ),
    );
  }
}

class MerchantDebtOverviewPage extends ConsumerStatefulWidget {
  final String linkId;
  final String merchantName;
  final String? openOperationId;
  final String? openRequestId;
  final bool openEdits;
  const MerchantDebtOverviewPage(
      {super.key,
      required this.linkId,
      required this.merchantName,
      this.openOperationId,
      this.openRequestId,
      this.openEdits = false});
  @override
  ConsumerState<MerchantDebtOverviewPage> createState() =>
      _MerchantDebtOverviewPageState();
}

class _MerchantDebtOverviewPageState
    extends ConsumerState<MerchantDebtOverviewPage> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;
  String? _displayCcy;
  bool _deepOpened = false;

  // Report filters: all | today | month | range
  String _period = 'all';
  DateTime? _from;
  DateTime? _to;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  String? get _dateFrom {
    final now = DateTime.now();
    switch (_period) {
      case 'today':
        return _iso(now);
      case 'month':
        return _iso(DateTime(now.year, now.month, 1));
      case 'range':
        return _from == null ? null : _iso(_from!);
      default:
        return null;
    }
  }

  String? get _dateTo {
    final now = DateTime.now();
    switch (_period) {
      case 'today':
        return _iso(now);
      case 'month':
        return _iso(DateTime(now.year, now.month + 1, 0));
      case 'range':
        return _to == null ? null : _iso(_to!);
      default:
        return null;
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _displayCcy ??=
          await resolveDefaultCurrency(ref.read(currentUserIdProvider));
      final d = await ref.read(merchantApiProvider).debtOverview(
            widget.linkId,
            currency: _displayCcy,
            dateFrom: _dateFrom,
            dateTo: _dateTo,
          );
      if (!mounted) return;
      setState(() {
        _data = d;
        final serverCcy = '${d['display_currency'] ?? ''}';
        if (serverCcy.isNotEmpty) _displayCcy = serverCcy;
        _loading = false;
      });
      _maybeDeepOpen();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  /// Notification deep link: open the exact operation once its data is ready.
  void _maybeDeepOpen() {
    if (_deepOpened || !mounted) return;
    final op = (widget.openOperationId ?? '').trim();
    if (op.isEmpty) return;
    _deepOpened = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.push('/personal/debt-operation?link=${widget.linkId}&inv=$op'
          '&name=${Uri.encodeComponent(widget.merchantName)}'
          '${widget.openEdits ? '&edits=1' : ''}');
    });
  }

  Future<void> _pickCurrency() async {
    if (!mounted) return;
    final enabled =
        await loadEnabledCurrencies(ref.read(currentUserIdProvider));
    if (!mounted || enabled.isEmpty) return;
    final sorted = enabled.toList()..sort();
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('عملة العرض',
            style: TextStyle(fontFamily: 'Cairo')),
        children: [
          for (final c in sorted)
            SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, c),
                child: Text(debtCurrencyLabel(c),
                    style: const TextStyle(fontFamily: 'Cairo'))),
        ],
      ),
    );
    if (picked != null && picked != _displayCcy && mounted) {
      setState(() => _displayCcy = picked);
      _load();
    }
  }

  Future<void> _selectPeriod(String p) async {
    if (p == 'range') {
      final now = DateTime.now();
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(now.year - 5),
        lastDate: DateTime(now.year + 1, 12, 31),
        initialDateRange: (_from != null && _to != null)
            ? DateTimeRange(start: _from!, end: _to!)
            : DateTimeRange(
                start: DateTime(now.year, now.month, 1), end: now),
      );
      if (!mounted) return;
      if (picked == null) return;
      setState(() {
        _period = 'range';
        _from = picked.start;
        _to = picked.end;
      });
      _load();
      return;
    }
    setState(() => _period = p);
    _load();
  }

  Widget _filters(AppLocalizations l10n) {
    final items = <String, String>{
      'all': l10n.translate('debtFiltersAll'),
      'today': l10n.translate('debtFiltersToday'),
      'month': l10n.translate('debtFiltersMonth'),
      'range': l10n.translate('debtFiltersRange'),
    };
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final e in items.entries) ...[
            _filterChip(e.value, _period == e.key,
                () => _selectPeriod(e.key)),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _filterChip(String label, bool active, VoidCallback onTap) {
    final dark = DebtStyle.dark(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: active
                ? DebtStyle.red
                : (dark ? const Color(0xFF2A2026) : Colors.white),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: active
                    ? DebtStyle.red
                    : DebtStyle.red.withAlpha(dark ? 70 : 45)),
            boxShadow: active
                ? [
                    BoxShadow(
                        color: DebtStyle.red.withAlpha(50),
                        blurRadius: 10,
                        offset: const Offset(0, 4))
                  ]
                : null,
          ),
          child: Text(label,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: active
                      ? Colors.white
                      : (dark ? Colors.white70 : DebtStyle.red))),
        ),
      ),
    );
  }

  Widget _tabs(AppLocalizations l10n) {
    final dark = DebtStyle.dark(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF2A2026) : const Color(0xFFF6E9ED),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DebtStyle.red.withAlpha(40)),
      ),
      child: TabBar(
        indicator: BoxDecoration(
            color: DebtStyle.red, borderRadius: BorderRadius.circular(11)),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        labelColor: Colors.white,
        unselectedLabelColor: dark ? Colors.white70 : DebtStyle.red,
        labelStyle: const TextStyle(
            fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w800),
        unselectedLabelStyle: const TextStyle(
            fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w700),
        tabs: [
          Tab(height: 40, text: l10n.translate('debtIndividualTab')),
          Tab(height: 40, text: l10n.translate('debtSectionsTab')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final individual = ((_data?['individual'] as List?) ?? const [])
        .whereType<Map>()
        .toList();
    final groups =
        ((_data?['groups'] as List?) ?? const []).whereType<Map>().toList();
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          title: Text(widget.merchantName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary)),
          actions: [
            ChatUnreadIcon(
                side: 'personal',
                linkId: widget.linkId,
                onPressed: () => context.push(
                    '/personal/chat?link=${widget.linkId}')),
            IconButton(
                icon: const Icon(Icons.notifications_outlined),
                onPressed: () => context.push(
                    '/personal/debt-notifications?link=${widget.linkId}'
                    '&name=${Uri.encodeComponent(widget.merchantName)}')),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null && _data == null
                ? DebtRetry(
                    message: debtFriendlyError(
                        _error ?? '', (k) => l10n.translate(k)),
                    retry: _load)
                : Column(children: [
                    _tabs(l10n),
                    Expanded(
                      child: TabBarView(children: [
                        // ── الديون الفردية: فلاتر + إجمالي + سجلات ──
                        FyonaRefresh(
                          onRefresh: _load,
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                            children: [
                              DebtPeriodFilter(
                                period: _period,
                                from: _from,
                                to: _to,
                                labels: {
                                  'all': l10n.translate('debtFiltersAll'),
                                  'today': l10n.translate('debtFiltersToday'),
                                  'month': l10n.translate('debtFiltersMonth'),
                                  'range': l10n.translate('debtFiltersRange'),
                                },
                                onChanged: (p, f, t) {
                                  setState(() {
                                    _period = p;
                                    _from = f;
                                    _to = t;
                                  });
                                  _load();
                                },
                              ),
                              const SizedBox(height: 12),
                              DebtTotalHeroCard(
                                currency: _displayCcy,
                                grand: _data?['grand_total'],
                                paid: _data?['paid_total'],
                                remaining: _data?['remaining_total'] ??
                                    _data?['display_total'],
                                fxGaps: ((_data?['fx_missing'] as List?) ??
                                        const [])
                                    .length,
                                title: l10n.translate('debtTotalTitle'),
                                subtitle: l10n.translate('merchantDebts'),
                                paidLabel: l10n.translate('debtPaid'),
                                remainingLabel:
                                    l10n.translate('debtRemaining'),
                                fxGapText: l10n.translate('debtFxGap'),
                                emptyText: l10n.translate('debtEmptyOps'),
                                onPickCurrency: _pickCurrency,
                              ),
                              const SizedBox(height: 16),
                              Row(children: [
                                const DebtIcon(Icons.history, size: 30),
                                const SizedBox(width: 8),
                                Text(l10n.translate('debtRecords'),
                                    style: DebtStyle.text(context,
                                        size: 15, bold: true)),
                              ]),
                              const SizedBox(height: 8),
                              if (individual.isEmpty)
                                _empty(l10n.translate('debtNoneIndividual'))
                              else
                                for (final op in individual)
                                  _opTile(l10n, op, widget.linkId),
                            ],
                          ),
                        ),
                        // ── الأقسام ──
                        FyonaRefresh(
                          onRefresh: _load,
                          child: groups.isEmpty
                              ? ListView(children: [
                                  _empty(l10n.translate('debtNoneSections')),
                                ])
                              : GridView.count(
                                  crossAxisCount: 2,
                                  padding: const EdgeInsets.all(16),
                                  mainAxisSpacing: 10,
                                  crossAxisSpacing: 10,
                                  childAspectRatio: 1.35,
                                  children: [
                                    for (final g in groups)
                                      DebtGroupTile(
                                        group: g,
                                        countLabel: _invoiceCountLabel(
                                            l10n,
                                            (g['count'] as num?)?.toInt() ?? 0),
                                        onTap: () => context.push(
                                            '/personal/debt-section?link=${widget.linkId}'
                                            '&gid=${g['id']}'
                                            '&name=${Uri.encodeComponent('${g['name'] ?? ''}')}'),
                                      ),
                                  ],
                                ),
                        ),
                      ]),
                    ),
                  ]),
      ),
    );
  }

  /// Total-debts hero card — SAME size/shape as the banks «إجمالي الأرصدة»
  /// card, with an inline paid (green) / remaining (red) breakdown.
  Widget _totalCard(AppLocalizations l10n) {
    final grand = _data?['grand_total'];
    final paid = _data?['paid_total'];
    final remaining = _data?['remaining_total'] ?? _data?['display_total'];
    final gaps = ((_data?['fx_missing'] as List?) ?? const []).length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            begin: Alignment(-1.0, -1.0),
            end: Alignment(1.5, 1.5),
            colors: [Color(0xFFC01838), DebtStyle.red, Color(0xFF7A1020)]),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: DebtStyle.red.withAlpha(100),
              blurRadius: 32,
              offset: const Offset(0, 12)),
        ],
      ),
      child: Stack(children: [
        Positioned(
            top: -30,
            right: -20,
            child: Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                    shape: BoxShape.circle, color: Colors.white.withAlpha(15)))),
        Positioned(
            bottom: -40,
            left: -10,
            child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                    shape: BoxShape.circle, color: Colors.white.withAlpha(10)))),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                  color: Colors.white.withAlpha(20),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: Colors.white.withAlpha(30))),
              child: const Icon(Icons.account_balance_wallet_outlined,
                  size: 22, color: Colors.white),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.translate('debtTotalTitle'),
                        style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Colors.white70)),
                    const SizedBox(height: 2),
                    Text(l10n.translate('merchantDebts'),
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 11,
                            color: Colors.white.withAlpha(120))),
                  ]),
            ),
            GestureDetector(
              onTap: _pickCurrency,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                    color: Colors.white.withAlpha(25),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withAlpha(40))),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('${_displayCcy ?? ''}',
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                  const Icon(Icons.expand_more,
                      size: 16, color: Colors.white),
                ]),
              ),
            ),
          ]),
          const SizedBox(height: 20),
          if (grand == null && remaining == null)
            Text(
                gaps > 0
                    ? l10n.translate('debtFxGap')
                    : l10n.translate('debtEmptyOps'),
                style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.white))
          else ...[
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(debtAmount(grand ?? remaining),
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 34,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                  const SizedBox(width: 6),
                  Text('${_displayCcy ?? ''}',
                      textDirection: TextDirection.ltr,
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                          color: Colors.white.withAlpha(180))),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: _breakdown(
                    l10n.translate('debtPaid'),
                    '${debtAmount(paid)} ${_displayCcy ?? ''}',
                    const Color(0xFF7BF1A8)),
              ),
              Container(width: 1, height: 30, color: Colors.white24),
              const SizedBox(width: 12),
              Expanded(
                child: _breakdown(
                    l10n.translate('debtRemaining'),
                    '${debtAmount(remaining)} ${_displayCcy ?? ''}',
                    const Color(0xFFFFC1C1)),
              ),
            ]),
          ],
        ]),
      ]),
    );
  }

  Widget _breakdown(String label, String value, Color color) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontFamily: 'Cairo', fontSize: 11, color: Colors.white70)),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(value,
                maxLines: 1,
                textDirection: TextDirection.ltr,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: color)),
          ),
        ],
      );

  Widget _opTile(AppLocalizations l10n, Map op, String linkId) {
    return DebtOperationTile(
      operation: op,
      titlePrefix: l10n.translate('debtInvoiceWord'),
      onTap: () => context.push(
          '/personal/debt-operation?link=$linkId&inv=${op['id']}'
          '&name=${Uri.encodeComponent('${op['number'] ?? ''}')}'),
    );
  }

  Widget _empty(String t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
            child: Text(t,
                style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    color: Colors.grey))),
      );
}

class DebtSectionPage extends ConsumerStatefulWidget {
  final String linkId;
  final String groupId;
  final String name;
  const DebtSectionPage(
      {super.key, required this.linkId, required this.groupId, required this.name});
  @override
  ConsumerState<DebtSectionPage> createState() => _DebtSectionPageState();
}

class _DebtSectionPageState extends ConsumerState<DebtSectionPage> {
  Map<String, dynamic>? _overview;
  bool _loading = true;
  String? _error;
  String? _displayCcy;

  String _period = 'all';
  DateTime? _from;
  DateTime? _to;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  String? get _dateFrom {
    final now = DateTime.now();
    switch (_period) {
      case 'today':
        return _iso(now);
      case 'month':
        return _iso(DateTime(now.year, now.month, 1));
      case 'range':
        return _from == null ? null : _iso(_from!);
      default:
        return null;
    }
  }

  String? get _dateTo {
    final now = DateTime.now();
    switch (_period) {
      case 'today':
        return _iso(now);
      case 'month':
        return _iso(DateTime(now.year, now.month + 1, 0));
      case 'range':
        return _to == null ? null : _iso(_to!);
      default:
        return null;
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _displayCcy ??=
          await resolveDefaultCurrency(ref.read(currentUserIdProvider));
      final d = await ref.read(merchantApiProvider).debtOverview(
            widget.linkId,
            groupId: widget.groupId,
            currency: _displayCcy,
            dateFrom: _dateFrom,
            dateTo: _dateTo,
          );
      if (mounted) {
        setState(() {
          _overview = d;
          final serverCcy = '${d['display_currency'] ?? ''}';
          if (serverCcy.isNotEmpty) _displayCcy = serverCcy;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = '$e'; });
    }
  }

  Future<void> _pickCurrency() async {
    if (!mounted) return;
    final enabled =
        await loadEnabledCurrencies(ref.read(currentUserIdProvider));
    if (!mounted || enabled.isEmpty) return;
    final sorted = enabled.toList()..sort();
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('عملة العرض',
            style: TextStyle(fontFamily: 'Cairo')),
        children: [
          for (final c in sorted)
            SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, c),
                child: Text(debtCurrencyLabel(c),
                    style: const TextStyle(fontFamily: 'Cairo'))),
        ],
      ),
    );
    if (picked != null && picked != _displayCcy && mounted) {
      setState(() => _displayCcy = picked);
      _load();
    }
  }

  /// Group-scoped overview: `operations` holds ONLY this section's invoices
  /// (server-filtered, newest first).
  List<Map> get _ops =>
      ((_overview?['operations'] as List?) ??
              ((_overview?['individual'] as List?) ?? const []))
          .whereType<Map>()
          .toList();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final ops = _loading || _error != null ? const <Map>[] : _ops;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Text(widget.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
        actions: [
          ChatUnreadIcon(
              side: 'personal',
              linkId: widget.linkId,
              onPressed: () =>
                  context.push('/personal/chat?link=${widget.linkId}')),
          IconButton(
              icon: const Icon(Icons.notifications_outlined),
              onPressed: () => context.push(
                  '/personal/debt-notifications?link=${widget.linkId}'
                  '&name=${Uri.encodeComponent(widget.name)}')),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _overview == null
              ? DebtRetry(
                  message: debtFriendlyError(
                      _error ?? '', (k) => l10n.translate(k)),
                  retry: _load)
              : FyonaRefresh(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    children: [
                      DebtPeriodFilter(
                        period: _period,
                        from: _from,
                        to: _to,
                        labels: {
                          'all': l10n.translate('debtFiltersAll'),
                          'today': l10n.translate('debtFiltersToday'),
                          'month': l10n.translate('debtFiltersMonth'),
                          'range': l10n.translate('debtFiltersRange'),
                        },
                        onChanged: (p, f, t) {
                          setState(() {
                            _period = p;
                            _from = f;
                            _to = t;
                          });
                          _load();
                        },
                      ),
                      const SizedBox(height: 12),
                      DebtTotalHeroCard(
                        currency: _displayCcy,
                        grand: _overview?['grand_total'],
                        paid: _overview?['paid_total'],
                        remaining: _overview?['remaining_total'] ??
                            _overview?['display_total'],
                        fxGaps:
                            ((_overview?['fx_missing'] as List?) ?? const [])
                                .length,
                        title: l10n.translate('debtTotalTitle'),
                        subtitle: widget.name,
                        paidLabel: l10n.translate('debtPaid'),
                        remainingLabel: l10n.translate('debtRemaining'),
                        fxGapText: l10n.translate('debtFxGap'),
                        emptyText: l10n.translate('debtEmptyOps'),
                        onPickCurrency: _pickCurrency,
                      ),
                      const SizedBox(height: 16),
                      Row(children: [
                        const DebtIcon(Icons.history, size: 30),
                        const SizedBox(width: 8),
                        Text(l10n.translate('debtRecords'),
                            style: DebtStyle.text(context,
                                size: 15, bold: true)),
                      ]),
                      const SizedBox(height: 8),
                      if (ops.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          child: Center(
                              child: Text(
                                  l10n.translate('debtNoneIndividual'),
                                  style: const TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 13,
                                      color: Colors.grey))),
                        )
                      else
                        for (final op in ops)
                          DebtOperationTile(
                            operation: op,
                            titlePrefix: l10n.translate('debtInvoiceWord'),
                            onTap: () => context.push(
                                '/personal/debt-operation?link=${widget.linkId}'
                                '&inv=${op['id']}'
                                '&name=${Uri.encodeComponent('${op['number'] ?? ''}')}'),
                          ),
                    ],
                  ),
                ),
    );
  }
}

class DebtOperationDetailPage extends ConsumerStatefulWidget {
  final String linkId;
  final String invoiceId;
  final String name;
  final String? partyKind;
  final String? partyId;
  final bool isBusiness;
  final bool openEdits;
  // Only populated by the Business router. Personal and connected Business
  // continue to use the original API paths below.
  final BusinessLocalDebtOperation? localBusiness;
  const DebtOperationDetailPage(
      {super.key,
      required this.linkId,
      required this.invoiceId,
      required this.name,
      this.partyKind,
      this.partyId,
      this.isBusiness = false,
      this.openEdits = false,
      this.localBusiness})
      : assert(localBusiness == null || isBusiness);
  @override
  ConsumerState<DebtOperationDetailPage> createState() =>
      _DebtOperationDetailPageState();
}

class _DebtOperationDetailPageState
    extends ConsumerState<DebtOperationDetailPage> {
  Map<String, dynamic>? _d;
  bool _loading = true;
  String? _error;
  String _chatLinkId = '';
  late bool _showEdits = widget.openEdits;
  bool _localBusinessBusy = false;
  int _localRead = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final local = widget.localBusiness;
    if (local != null) {
      final revision = ++_localRead;
      try {
        final detail = await local.read(ref);
        if (!mounted || revision != _localRead || !local.canRead(ref)) return;
        setState(() {
          _d = detail;
          _error = null;
        });
      } catch (e) {
        if (!mounted || revision != _localRead) return;
        setState(() {
          _d = null;
          _error = local.error(e, AppLocalizations.of(context));
        });
      }
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(merchantApiProvider);
      final d = widget.isBusiness
          ? await api.businessOperationDetail(
              partyKind: widget.partyKind ?? 'customer',
              partyId: widget.partyId ?? '',
              invoiceId: widget.invoiceId)
          : await api.operationDetail(widget.linkId, widget.invoiceId);
      var chatLink = widget.linkId;
      if (chatLink.isEmpty &&
          (widget.partyKind ?? '').isNotEmpty &&
          (widget.partyId ?? '').isNotEmpty) {
        try {
          final st = await api.linkStatus(
              partyKind: widget.partyKind!, partyId: widget.partyId!);
          if (st['linked'] == true) chatLink = '${st['id'] ?? ''}';
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _d = d;
          _chatLinkId = chatLink;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = '$e'; });
    }
  }

  double _n(dynamic v) =>
      v is num ? v.toDouble() : (double.tryParse('$v') ?? 0);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final local = widget.localBusiness;
    final visible = local?.canRead(ref, watch: true) ?? true;
    final canEdit = local?.canEdit(ref, watch: true) ?? true;
    final canSettle = local?.canSettle(ref, watch: true) ?? true;
    final canViewInvoice = local?.canViewInvoice(ref, watch: true) ?? true;
    final d = visible ? _d : null;
    final items = ((d?['items'] as List?) ?? const []).whereType<Map>().toList();
    final changes =
        ((d?['item_changes'] as List?) ?? const []).whereType<Map>().toList();
    final modified = d?['is_modified'] == true;
    final isSupplier = '${d?['perspective'] ?? 'customer'}' == 'supplier';
    final settled = _n(d?['remaining']) <= 0.004;
    final ccy = '${d?['currency'] ?? ''}';
    final isArabic = Localizations.localeOf(context).languageCode == 'ar';
    final ccyLabel = debtCurrencyShort(ccy, isArabic);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        actions: [
          if (_chatLinkId.isNotEmpty)
            ChatUnreadIcon(
              side: widget.isBusiness ? 'merchant' : 'personal',
              linkId: _chatLinkId,
              onPressed: () => context.push(widget.isBusiness
                  ? '/debts/chat?link=$_chatLinkId'
                  : '/personal/chat?link=$_chatLinkId'),
            ),
        ],
        title: Text('${d?['number'] ?? widget.name}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
      ),
      body: !visible
          ? DebtRetry(message: l10n.translate('unauthorized'), retry: _load)
          : local == null && _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && d == null
              ? DebtRetry(
                  message: local != null
                      ? _error!
                      : debtFriendlyError(_error ?? '', (k) => l10n.translate(k)),
                  retry: _load)
              : local != null && d == null
              ? const SizedBox.shrink()
              : FyonaRefresh(
                  onRefresh: _load,
                  child: CustomScrollView(slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          // ── Modified + settled badges ──
                          Row(children: [
                            _badge(l10n, modified),
                            if (settled) ...[
                              const SizedBox(width: 8),
                              _settledBadge(l10n),
                            ],
                            const Spacer(),
                             if (widget.isBusiness && canEdit) ...[
                              IconButton(
                                tooltip: l10n.translate('debtEditInvoice'),
                                 onPressed: () => _runBusinessAction(_editInvoice),
                                icon: const Icon(Icons.edit_outlined,
                                    size: 20),
                              ),
                              IconButton(
                                tooltip:
                                    l10n.translate('debtDeleteInvoice'),
                                 onPressed: () => _runBusinessAction(_deleteInvoice),
                                icon: const Icon(Icons.delete_outline,
                                    size: 20, color: AppColors.danger),
                              ),
                            ],
                          ]),
                          if (modified) _editsPanel(l10n, changes, items),
                          const SizedBox(height: 10),
                          // ── Summary rectangle ──
                          DebtPanel(
                            red: true,
                            decorated: true,
                            child: Row(children: [
                              Expanded(
                                child: _sumCol(
                                    l10n.translate('saleGrandTotal'),
                                    d?['total'], ccyLabel),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _sumCol(
                                    l10n.translate('repPaid'),
                                    d?['paid'], ccyLabel,
                                    color: const Color(0xFF7BF1A8)),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _sumCol(
                                    l10n.translate('debtRemaining'),
                                    d?['remaining'], ccyLabel,
                                    color: const Color(0xFFFFC1C1)),
                              ),
                            ]),
                          ),
                          const SizedBox(height: 16),
                          // ── Products table header ──
                          _tableHeader(l10n),
                        ]),
                      ),
                    ),
                    // Lazy rows: handles thousands of products without lag.
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      sliver: SliverList.builder(
                        itemCount: items.length,
                        itemBuilder: (_, i) => _productRow(
                            l10n, items[i], _changesFor(changes, items[i])),
                      ),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(16, 14, 16,
                          40 + MediaQuery.of(context).padding.bottom),
                      sliver: SliverToBoxAdapter(
                        child: widget.isBusiness
                            ? Column(children: [
                                Row(children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: settled
                                            ? const Color(0xFF1F9D55)
                                                .withAlpha(30)
                                            : const Color(0xFF1F9D55),
                                        disabledBackgroundColor:
                                            const Color(0xFF1F9D55)
                                                .withAlpha(30),
                                        disabledForegroundColor:
                                            const Color(0xFF1F9D55),
                                        minimumSize: const Size(0, 54),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 12),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(12)),
                                      ),
                                      onPressed: settled || !canSettle
                                          ? null
                                          : () => _runBusinessAction(_settleBusiness),
                                      icon: Icon(
                                          settled
                                              ? Icons.check_circle
                                              : (isSupplier
                                                  ? Icons.payments_outlined
                                                  : Icons
                                                      .request_quote_outlined),
                                          size: 18,
                                          color: settled
                                              ? const Color(0xFF1F9D55)
                                              : Colors.white),
                                      label: Text(
                                          l10n.translate(settled
                                              ? 'debtSettledFull'
                                              : (isSupplier
                                                  ? 'debtPaySupplier'
                                                  : 'debtCollectCustomer')),
                                          maxLines: 2,
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                              fontFamily: 'Cairo',
                                              fontSize: 12,
                                              height: 1.4,
                                              fontWeight: FontWeight.w800,
                                              color: settled
                                                  ? const Color(0xFF1F9D55)
                                                  : Colors.white)),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: DebtStyle.red,
                                        minimumSize: const Size(0, 54),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 12),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(12)),
                                      ),
                                      onPressed: !canViewInvoice ? null : () {
                                        if (local != null) {
                                          local.openInvoice(context, ref);
                                        } else {
                                          context.push(
                                            '/invoices/view?id=${widget.invoiceId}'
                                            '&type=${isSupplier ? 'purchase' : 'sale'}',
                                          );
                                        }
                                      },
                                      icon: const Icon(
                                          Icons.description_outlined,
                                          size: 18),
                                      label: Text(
                                          l10n.translate('debtViewInvoice'),
                                          maxLines: 2,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                              fontFamily: 'Cairo',
                                              fontSize: 12,
                                              height: 1.4,
                                              fontWeight: FontWeight.w800)),
                                    ),
                                  ),
                                ]),
                                const SizedBox(height: 8),
                                SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton.icon(
                                    onPressed: () => _showPayments(l10n, d),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: DebtStyle.red,
                                      minimumSize: const Size(0, 54),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 14),
                                      side: BorderSide(
                                          color: DebtStyle.red.withAlpha(120)),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12)),
                                    ),
                                    icon: const Icon(Icons.payments_outlined,
                                        size: 18),
                                    label: Text(l10n.translate('debtPayments'),
                                        maxLines: 1,
                                        style: const TextStyle(
                                            fontFamily: 'Cairo',
                                            fontSize: 13,
                                            height: 1.4,
                                            fontWeight: FontWeight.w800)),
                                  ),
                                ),
                              ])
                            : Row(children: [
                                Expanded(
                                  child: SizedBox(
                                    height: 48,
                                    child: OutlinedButton.icon(
                                      onPressed: () => _showPayments(l10n, d),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: DebtStyle.red,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6),
                                        side: BorderSide(
                                            color:
                                                DebtStyle.red.withAlpha(120)),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(12)),
                                      ),
                                      icon: const Icon(
                                          Icons.payments_outlined,
                                          size: 17),
                                      label: Text(
                                          l10n.translate('debtPayments'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontFamily: 'Cairo',
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w800)),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: SizedBox(
                                    height: 48,
                                    child: FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: DebtStyle.red,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(12)),
                                      ),
                                      onPressed: () => context.push(
                                          '/personal/debt-invoice?link=${widget.linkId}'
                                          '&inv=${widget.invoiceId}'
                                          '&name=${Uri.encodeComponent(widget.name)}'),
                                      icon: const Icon(
                                          Icons.description_outlined,
                                          size: 17),
                                      label: Text(
                                          l10n.translate(
                                              'debtOriginalInvoice'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontFamily: 'Cairo',
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w800)),
                                    ),
                                  ),
                                ),
                              ]),
                      ),
                    ),
                  ]),
                ),
    );
  }

  Future<void> _runBusinessAction(Future<void> Function() action) async {
    if (widget.localBusiness == null) return action();
    if (_localBusinessBusy) return;
    _localBusinessBusy = true;
    try {
      await action();
    } finally {
      _localBusinessBusy = false;
    }
  }

  Widget _guardLocalOperationDialog(Widget child, {bool edit = false}) {
    final local = widget.localBusiness;
    if (local == null) return child;
    return Consumer(builder: (ctx, r, _) {
      final allowed = edit
          ? local.canEdit(r, watch: true)
          : local.canRead(r, watch: true);
      if (allowed) return child;
      final l10n = AppLocalizations.of(ctx);
      return AlertDialog(
        content: Text(l10n.translate('unauthorized')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.translate('saleClose')),
          ),
        ],
      );
    });
  }

  Future<void> _editInvoice() async {
    final d = _d;
    final local = widget.localBusiness;
    if (d == null || (local != null && !local.canEdit(ref))) return;
    final l10n = AppLocalizations.of(context);
    final items =
        ((d['items'] as List?) ?? const []).whereType<Map>().toList();
    final editable =
        items.where((it) => '${it['id'] ?? ''}'.isNotEmpty).toList();
    if (editable.isEmpty) return;
    final qty = <String, TextEditingController>{};
    final price = <String, TextEditingController>{};
    for (final it in editable) {
      final id = '${it['id']}';
      final qText = local != null ? '${it['qty']}' : debtPlainNum(it['qty']);
      final pText = local != null ? '${it['price']}' : fmtNum(_n(it['price']));
      qty[id] = TextEditingController.fromValue(TextEditingValue(
          text: qText,
          selection: TextSelection.collapsed(offset: qText.length)));
      price[id] = TextEditingController.fromValue(TextEditingValue(
          text: pText,
          selection: TextSelection.collapsed(offset: pText.length)));
    }
    var confirmed = false;
    Future<Object?>? closed;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        closed = ModalRoute.of(ctx)?.completed;
        return _guardLocalOperationDialog(Container(
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: EdgeInsets.fromLTRB(
            16, 14, 16, 16 + MediaQuery.of(ctx).padding.bottom),
        child: StatefulBuilder(builder: (ctx, setSt) {
          double total = 0;
          var changed = false;
          var valid = true;
          for (final it in editable) {
            final id = '${it['id']}';
            final q = double.tryParse(qty[id]!.text.trim()) ?? 0;
            final p = parseFormattedAmount(price[id]!.text) ?? 0;
            total += q * p;
            if (q <= 0 || p < 0) valid = false;
            if ((q - _n(it['qty'])).abs() > 1e-9 ||
                (p - _n(it['price'])).abs() > 1e-9) {
              changed = true;
            }
          }
          return Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const DebtIcon(Icons.edit_outlined, size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Text(l10n.translate('debtEditInvoice'),
                    style: DebtStyle.text(context, size: 16, bold: true)),
              ),
              IconButton(
                tooltip: l10n.translate('cancel'),
                onPressed: () => Navigator.pop(ctx, false),
                icon: const Icon(Icons.close_rounded),
              ),
            ]),
            const SizedBox(height: 10),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: editable.length,
                itemBuilder: (_, i) {
                  final it = editable[i];
                  final id = '${it['id']}';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${it['name'] ?? ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: DebtStyle.text(context,
                                  size: 12.5, bold: true)),
                          const SizedBox(height: 4),
                          Row(children: [
                            Expanded(
                              child: FyonaTextField(
                                controller: qty[id],
                                keyboardType: const TextInputType
                                    .numberWithOptions(decimal: true),
                                onChanged: (_) => setSt(() {}),
                                decoration: InputDecoration(
                                    isDense: true,
                                    labelText:
                                        l10n.translate('debtQtyCol'),
                                    labelStyle: const TextStyle(
                                        fontFamily: 'Cairo', fontSize: 11)),
                                style: const TextStyle(
                                    fontFamily: 'Cairo', fontSize: 13),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FyonaTextField(
                                controller: price[id],
                                keyboardType: const TextInputType
                                    .numberWithOptions(decimal: true),
                                inputFormatters: [AmountInputFormatter()],
                                onChanged: (_) => setSt(() {}),
                                decoration: InputDecoration(
                                    isDense: true,
                                    labelText:
                                        l10n.translate('debtUnitPriceCol'),
                                    labelStyle: const TextStyle(
                                        fontFamily: 'Cairo', fontSize: 11)),
                                style: const TextStyle(
                                    fontFamily: 'Cairo', fontSize: 13),
                              ),
                            ),
                          ]),
                        ]),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: Text(l10n.translate('debtNewTotal'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DebtStyle.text(context,
                        size: 12.5, color: Colors.grey)),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerEnd,
                  child: Text(
                      '${debtAmount(total)} ${debtCurrencyLabel('${d['currency'] ?? ''}')}',
                      maxLines: 1,
                      textDirection: TextDirection.ltr,
                      style: DebtStyle.text(context,
                          size: 14, bold: true, color: DebtStyle.red)),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: DebtStyle.red,
                  disabledBackgroundColor: DebtStyle.red.withAlpha(45),
                  disabledForegroundColor: Colors.white70,
                  minimumSize: const Size(0, 54),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: (changed && valid)
                    ? () {
                        if (confirmed) return;
                        confirmed = true;
                        Navigator.pop(ctx, true);
                      }
                    : null,
                child: Text(l10n.translate('debtSaveChanges'),
                    maxLines: 1,
                    style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 14,
                        height: 1.4,
                        fontWeight: FontWeight.w800)),
              ),
            ),
          ]);
        }),
        ), edit: true);
      },
    );
    final changes = <Map<String, dynamic>>[];
    for (final it in editable) {
      final id = '${it['id']}';
      final q = double.tryParse(qty[id]!.text.trim()) ?? 0;
      final p = parseFormattedAmount(price[id]!.text) ?? 0;
      if (q <= 0 || p < 0) continue;
      changes.add({'item_id': id, 'quantity': q, 'unit_price': p});
    }
    final typedQuantity = qty.values.first.text.trim();
    final typedPrice = price.values.first.text.trim();
    // The dismiss animation still holds the input widgets after pop.
    void disposeInputs() {
      for (final c in [...qty.values, ...price.values]) {
        c.dispose();
      }
    }
    if (closed case final animation?) {
      animation.whenComplete(disposeInputs);
    } else {
      disposeInputs();
    }
    if (ok != true || changes.isEmpty || !mounted) return;
    try {
      if (local != null) {
        await local.edit(
          ref,
          revision: d['revision'] as int,
          itemId: '${editable.single['id']}',
          quantity: typedQuantity,
          unitPrice: typedPrice,
        );
      } else {
        await ref.read(merchantApiProvider).businessAdjustInvoice(
            partyKind: widget.partyKind ?? 'customer',
            partyId: widget.partyId ?? '',
            invoiceId: widget.invoiceId,
            items: changes,
        );
      }
      await _load();
      if (mounted && (local?.canRead(ref) ?? true)) {
        showFyonaSnack(context, l10n.translate('debtEditedOk'),
            success: true);
      }
    } catch (e) {
      if (mounted) showFyonaSnack(context, local?.error(e, l10n) ?? '$e', success: false);
    }
  }

  Future<void> _deleteInvoice() async {
    final d = _d;
    final local = widget.localBusiness;
    if (d == null || (local != null && !local.canEdit(ref))) return;
    final l10n = AppLocalizations.of(context);
    final linked = d['linked'] == true;
    var confirmed = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => _guardLocalOperationDialog(AlertDialog(
        title: Text(l10n.translate('debtDeleteInvoice'),
            style: const TextStyle(
                fontFamily: 'Cairo', fontWeight: FontWeight.w800)),
        content: Text(
            l10n.translate(linked
                ? 'debtDeleteInvoiceLinked'
                : 'debtDeleteInvoicePlain'),
            style: const TextStyle(fontFamily: 'Cairo', fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.translate('cancel'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              style:
                  FilledButton.styleFrom(backgroundColor: AppColors.danger),
               onPressed: () {
                 if (confirmed) return;
                 confirmed = true;
                 Navigator.pop(ctx, true);
               },
              child: Text(l10n.translate('debtDeleteInvoice'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
        ],
      ), edit: true),
    );
    if (ok != true || !mounted) return;
    try {
      if (local != null) {
        await local.delete(ref, d['revision'] as int);
      } else {
        await ref.read(merchantApiProvider).businessDeleteInvoice(
            partyKind: widget.partyKind ?? 'customer',
            partyId: widget.partyId ?? '',
            invoiceId: widget.invoiceId,
        );
      }
      if (!mounted || local?.canRead(ref) == false) return;
      if (local != null) {
        showFyonaSnack(context, l10n.translate('debtDeletedOk'), success: true);
        Navigator.pop(context);
      } else {
        Navigator.pop(context);
        showFyonaSnack(context, l10n.translate('debtDeletedOk'), success: true);
      }
    } catch (e) {
      if (mounted) showFyonaSnack(context, local?.error(e, l10n) ?? '$e', success: false);
    }
  }

  Future<void> _settleBusiness() async {
    final d = _d;
    final local = widget.localBusiness;
    if (local != null) {
      if (d == null || !local.canSettle(ref)) return;
      if (await local.settle(context, ref) && mounted) await _load();
      return;
    }
    if (d == null || widget.partyId == null) return;
    final isSupplier = '${d['perspective']}' == 'supplier';
    final remaining = _n(d['remaining']);
    if (remaining <= 0.004) return;
    final ok = await showDebtSettlementSheet(
      context,
      ref,
      isSupplier: isSupplier,
      partyId: widget.partyId!,
      currency: '${d['currency'] ?? ''}',
      remaining: remaining,
      invoiceId: widget.invoiceId,
    );
    if (ok && mounted) await _load();
  }

  Widget _settledBadge(AppLocalizations l10n) {
    const color = Color(0xFF1F9D55);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withAlpha(24),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: color.withAlpha(90)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.check_circle, size: 15, color: color),
        const SizedBox(width: 5),
        Text(l10n.translate('debtSettledFull'),
            style: const TextStyle(
                fontFamily: 'Cairo',
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: color)),
      ]),
    );
  }

  Widget _badge(AppLocalizations l10n, bool modified) {
    final color =
        modified ? const Color(0xFFD32F2F) : const Color(0xFF1F9D55);
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withAlpha(22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withAlpha(90)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(modified ? Icons.edit_note : Icons.verified_outlined,
            size: 16, color: color),
        const SizedBox(width: 5),
        Text(l10n.translate(modified ? 'debtModified' : 'debtNotModified'),
            maxLines: 1,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 11.5,
                height: 1.3,
                fontWeight: FontWeight.w800,
                color: color)),
        if (modified) ...[
          const SizedBox(width: 4),
          AnimatedRotation(
            turns: _showEdits ? 0.5 : 0,
            duration: const Duration(milliseconds: 180),
            child: Icon(Icons.keyboard_arrow_down_rounded,
                size: 18, color: color),
          ),
        ],
      ]),
    );
    if (!modified) return chip;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => setState(() => _showEdits = !_showEdits),
      child: chip,
    );
  }

  Widget _editsPanel(
      AppLocalizations l10n, List<Map> changes, List<Map> items) {
    String itemName(String key) {
      for (final it in items) {
        if ('${it['id'] ?? ''}' == key) {
          return '${it['name'] ?? ''}';
        }
      }
      for (final c in changes) {
        if ('${c['item_id'] ?? c['description'] ?? ''}' == key) {
          return '${c['description'] ?? ''}';
        }
      }
      return key;
    }

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: _showEdits
          ? Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFD32F2F).withAlpha(8),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: const Color(0xFFD32F2F).withAlpha(45)),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.history_rounded,
                          size: 18, color: Color(0xFFD32F2F)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(l10n.translate('debtEditDetailsTitle'),
                            style: const TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFFD32F2F))),
                      ),
                      InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => setState(() => _showEdits = false),
                        child: const Padding(
                          padding: EdgeInsets.all(2),
                          child: Icon(Icons.close_rounded,
                              size: 18, color: Color(0xFFD32F2F)),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    if (changes.isEmpty)
                      Text(l10n.translate('debtEditDetailsEmpty'),
                          style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 11.5,
                              color: Colors.grey))
                    else
                      // ONE card per change event — every edit keeps its own
                      // date and employee/manager, even for the same product.
                      for (final c in changes)
                        _editGroup(
                            l10n,
                            itemName('${c['item_id'] ?? ''}'.isNotEmpty
                                ? '${c['item_id']}'
                                : '${c['description'] ?? ''}'),
                            [c]),
                  ]),
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _editGroup(AppLocalizations l10n, String name, List<Map> rows) {
    final first = rows.isEmpty ? const <String, dynamic>{} : rows.first;
    final by = '${first['changed_by_name'] ?? ''}'.trim();
    final manager = first['changed_by_is_manager'] == true;
    final when = _fmtWhen('${first['changed_at'] ?? ''}');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: DebtStyle.surface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DebtStyle.border(context)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(name.isEmpty ? '—' : name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: DebtStyle.text(context, size: 12.5, bold: true)),
          ),
          if (when.isNotEmpty)
            Text(when,
                textDirection: TextDirection.ltr,
                style: DebtStyle.text(context,
                    size: 10, color: Colors.grey)),
        ]),
        if (manager || by.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(children: [
            Icon(manager ? Icons.verified_user_outlined : Icons.person_outline,
                size: 13, color: Colors.grey),
            const SizedBox(width: 4),
            Flexible(
              child: Text(manager
                  ? l10n.translate('debtEditByManager')
                  : l10n.translate('debtEditByEmployee',
                      params: {'name': by}),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DebtStyle.text(context,
                      size: 10.5, color: Colors.grey)),
            ),
          ]),
        ],
        const SizedBox(height: 6),
        for (final r in rows) ...[
          if (r['new_quantity'] != null)
            _diffRow(
                l10n.translate('debtQtyCol'),
                debtPlainNum(r['old_quantity']),
                debtPlainNum(r['new_quantity'])),
          if (r['new_unit_price'] != null) ...[
            if (r['new_quantity'] != null) const SizedBox(height: 4),
            _diffRow(
                l10n.translate('debtUnitPriceCol'),
                debtAmount(r['old_unit_price']),
                debtAmount(r['new_unit_price'])),
          ],
        ],
      ]),
    );
  }

  Widget _diffRow(String label, String before, String after) {
    final l10n = AppLocalizations.of(context);
    TextStyle h() => DebtStyle.text(context, size: 9.5, color: Colors.grey);
    TextStyle v() => DebtStyle.text(context, size: 11.5, bold: true);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: DebtStyle.red.withAlpha(6),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(children: [
        Expanded(flex: 3, child: Text(label, style: h())),
        Expanded(
          flex: 3,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l10n.translate('debtBefore'), style: h()),
            Text(before,
                textDirection: TextDirection.ltr,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: v()),
          ]),
        ),
        Icon(Icons.arrow_forward_rounded, size: 14, color: DebtStyle.red),
        const SizedBox(width: 6),
        Expanded(
          flex: 3,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l10n.translate('debtAfter'), style: h()),
            Text(after,
                textDirection: TextDirection.ltr,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: v().copyWith(color: DebtStyle.red)),
          ]),
        ),
      ]),
    );
  }

  static String _fmtWhen(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    final l = d.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  Widget _sumCol(String label, dynamic amount, String currency,
      {Color? color}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontFamily: 'Cairo', fontSize: 10, color: Colors.white70)),
      const SizedBox(height: 3),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(debtAmount(amount),
                textDirection: TextDirection.ltr,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: color ?? Colors.white)),
            const SizedBox(width: 4),
            Text(currency,
                maxLines: 1,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    color: color?.withAlpha(210) ??
                        Colors.white.withAlpha(200))),
          ],
        ),
      ),
    ]);
  }

  Widget _tableHeader(AppLocalizations l10n) {
    final style = TextStyle(
        fontFamily: 'Cairo',
        fontSize: 11.5,
        fontWeight: FontWeight.w800,
        color: AppColors.textSecondary);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: DebtStyle.red.withAlpha(10),
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(12)),
        border: Border.all(color: DebtStyle.border(context)),
      ),
      child: Row(children: [
        Expanded(flex: 5, child: Text(l10n.translate('debtProductCol'), style: style)),
        Expanded(
            flex: 2,
            child: Text(l10n.translate('debtQtyCol'),
                textAlign: TextAlign.center, style: style)),
        Expanded(
            flex: 2,
            child: Text(l10n.translate('debtUnitPriceCol'),
                textAlign: TextAlign.center, style: style)),
        Expanded(
            flex: 2,
            child: Text(l10n.translate('debtLineTotalCol'),
                textAlign: TextAlign.center, style: style)),
      ]),
    );
  }

  List<Map> _changesFor(List<Map> changes, Map item) {
    final id = '${item['id'] ?? ''}';
    final name = '${item['name'] ?? ''}';
    return changes
        .where((c) =>
            ('${c['item_id'] ?? ''}'.isNotEmpty && '${c['item_id']}' == id) ||
            ('${c['item_id'] ?? ''}'.isEmpty &&
                '${c['description'] ?? ''}' == name))
        .toList();
  }

  Widget _productRow(AppLocalizations l10n, Map it, List<Map> changes) {
    final qty = _n(it['qty']);
    final price = _n(it['price']);
    final total = _n(it['total']);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: DebtStyle.surface(context),
        border: Border(
            left: BorderSide(color: DebtStyle.border(context)),
            right: BorderSide(color: DebtStyle.border(context)),
            bottom: BorderSide(color: DebtStyle.border(context))),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            flex: 5,
            child: Row(children: [
              _productImage('${it['image'] ?? ''}'),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    '${it['name'] ?? ''}'
                    '${'${it['unit'] ?? ''}'.isNotEmpty ? ' (${it['unit']})' : ''}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary)),
              ),
            ]),
          ),
          Expanded(
            flex: 2,
            child: InvoiceAmount(debtPlainNum(qty),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12.5,
                    color: AppColors.textSecondary)),
          ),
          Expanded(
            flex: 2,
            child: InvoiceAmount(debtAmount(price),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12.5,
                    color: AppColors.textSecondary)),
          ),
          Expanded(
            flex: 2,
            child: InvoiceAmount(debtAmount(total),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary)),
          ),
        ]),
      ]),
    );
  }

  String _changeText(AppLocalizations l10n, Map c) {
    final before = l10n.translate('debtBefore');
    final after = l10n.translate('debtAfter');
    final oq = c['old_quantity'];
    final nq = c['new_quantity'];
    final op = c['old_unit_price'];
    final np = c['new_unit_price'];
    if (oq != null && nq != null) {
      return '${l10n.translate('debtQtyCol')}: $before ${debtAmount(oq)} → $after ${debtAmount(nq)}';
    }
    return '${l10n.translate('debtUnitPriceCol')}: $before ${debtAmount(op)} → $after ${debtAmount(np)}';
  }

  Widget _productImage(String url) {
    final u = url.trim();
    final fallback = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
          color: DebtStyle.red.withAlpha(14),
          borderRadius: BorderRadius.circular(9)),
      child: const Icon(Icons.inventory_2_outlined,
          size: 18, color: DebtStyle.red),
    );
    if (u.isEmpty) return fallback;
    if (u.startsWith('http')) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: Image.network(u,
            width: 40,
            height: 40,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => fallback),
      );
    }
    return fallback;
  }

  void _showPayments(AppLocalizations l10n, Map<String, dynamic>? d) {
    final payments =
        ((d?['payments'] as List?) ?? const []).whereType<Map>().toList();
    final isCustomer = '${d?['perspective'] ?? 'customer'}' == 'customer';
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _guardLocalOperationDialog(Container(
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: EdgeInsets.fromLTRB(
            16, 14, 16, 16 + MediaQuery.of(ctx).padding.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const DebtIcon(Icons.payments_outlined, size: 36),
            const SizedBox(width: 10),
            Expanded(
              child: Text(l10n.translate('debtPayments'),
                  style: DebtStyle.text(context, size: 16, bold: true)),
            ),
          ]),
          const SizedBox(height: 12),
          if (payments.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(l10n.translate('debtNoPayments'),
                  style: DebtStyle.text(context, color: Colors.grey)),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: payments.length,
                itemBuilder: (_, i) {
                  final p = payments[i];
                  final ccy = '${p['currency'] ?? d?['currency'] ?? ''}';
                  // Perspective: the merchant RECEIVES on a customer debt and
                  // PAYS on a supplier debt; the personal party is the mirror.
                  final iAmPayer =
                      widget.isBusiness ? !isCustomer : isCustomer;
                  final verb = l10n.translate(
                      iAmPayer ? 'debtPaidByYou' : 'debtReceivedByYou');
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: DebtPanel(
                      padding: const EdgeInsets.all(12),
                      child: Row(children: [
                        Container(
                          width: 26,
                          height: 26,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                              color: DebtStyle.red.withAlpha(18),
                              shape: BoxShape.circle),
                          child: Text('${i + 1}',
                              style: DebtStyle.text(context,
                                  size: 12, bold: true, color: DebtStyle.red)),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                    '$verb ${debtAmount(p['amount'])} '
                                    '${debtCurrencyLabel(ccy)}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: DebtStyle.text(context,
                                        size: 13, bold: true)),
                                const SizedBox(height: 2),
                                Text(
                                    '${l10n.translate('debtOnDate')}: '
                                    '${'${p['date'] ?? ''}'.split('T').first}',
                                    style: DebtStyle.text(context,
                                        size: 11, color: Colors.grey)),
                              ]),
                        ),
                      ]),
                    ),
                  );
                },
              ),
            ),
        ]),
      )),
    );
  }
}
