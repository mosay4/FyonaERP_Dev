import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fyona_flutter/core/utils/document_number.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/services/currency/enabled_currencies_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../data/local_directory/directory_party.dart';
import '../../data/local_directory/directory_pilot.dart';
import '../../data/local_directory/directory_scope.dart';
import '../widgets/debt_widgets.dart';
import '../widgets/debt_settlement.dart';
import '../widgets/local_directory_actions.dart';
import '../providers/business_ledger_session.dart';
import '../../../personal/data/merchant_api.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

DirectoryAccess _localScope(
  WidgetRef ref,
  DirectoryPartyReference party, {
  bool write = false,
}) {
  final permission = '${party.kind.name}s.${write ? 'edit' : 'details'}';
  if (BranchScope.readOnly ||
      !ref.read(employeeCanProvider('debts.details')) ||
      !ref.read(employeeCanProvider(permission)) ||
      (write && !ref.read(employeeCanProvider('debts.add')))) {
    throw const DirectoryAccessDenied();
  }
  return party.requireScope(
    ref.read(directoryPilotAccessProvider),
    write: write,
  );
}

bool _watchLocalVisibility(WidgetRef ref, DirectoryPartyReference? party) {
  if (party == null) return true;
  ref.watch(directoryPilotAccessProvider);
  ref.watch(employeeCanProvider('debts.details'));
  ref.watch(employeeCanProvider('${party.kind.name}s.details'));
  try {
    _localScope(ref, party);
    return true;
  } on DirectoryAccessDenied {
    return false;
  }
}

Future<DirectoryParty> _lookupLocalParty(
  WidgetRef ref,
  DirectoryPartyReference party,
) => ref
    .read(directoryPilotStoreProvider)
    .find(_localScope(ref, party), party.kind, party.id);

Future<Map<String, dynamic>> _localDebtReport(
  WidgetRef ref,
  DirectoryPartyReference party, {
  required String currency,
  required String? dateFrom,
  required String? dateTo,
  String? group,
  bool individual = false,
}) async {
  final scope = _localScope(ref, party);
  final rates = await ref.read(localBusinessRatesProvider.future);
  final ledger = await loadLocalDebts(
    ref,
    scope,
    party,
    individual: individual,
    groupId: group,
    dateFrom: dateFrom,
    dateTo: dateTo,
  );
  return ledger.report(
    currency,
    (from, to) => businessSavedQuote(rates, from, to),
  );
}

// Keep not-yet-migrated writers off the old API; there is no server party ID
// behind a device-only route. Use the existing error style and strings.
void _unmigratedFinance(BuildContext context) => showFyonaSnack(
  context,
  AppLocalizations.of(context).translate('errorOccurred'),
  success: false,
);

/// A device-ledger party's new debt (single or inside a section) is a credit
/// sale/purchase on this phone — the same invoice screen and ledger command
/// as the buttons, in the party's own branch. Used to be refused here with a
/// red «حدث خطأ» for every device party.
Future<bool> _addLocalDebt(
  BuildContext context,
  WidgetRef ref,
  DirectoryPartyReference party, {
  String? group,
}) async {
  try {
    _localScope(ref, party);
  } on DirectoryAccessDenied {
    _unmigratedFinance(context);
    return false;
  }
  if (!sameDirectoryScope(party.scope, ref.read(businessLocalLedgerScopeProvider))) {
    _unmigratedFinance(context);
    return false;
  }
  final supplier = party.kind == DirectoryPartyKind.supplier;
  await context.push(Uri(
    path: supplier ? '/purchases/add' : '/sales/add',
    queryParameters: {
      supplier ? 'supplier' : 'customer': party.id,
      if (group != null && group.isNotEmpty) 'group': group,
      'debt': '1',
    },
  ).toString());
  return true;
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _invoiceCount(AppLocalizations l10n, int n) {
  if (n == 1) return l10n.translate('debtInvoicesOne');
  if (n == 2) return l10n.translate('debtInvoicesTwo');
  if (n >= 3 && n <= 10) {
    return l10n.translate('debtInvoicesFew', params: {'n': '$n'});
  }
  return l10n.translate('debtInvoicesMany', params: {'n': '$n'});
}

mixin _FiltersMixin {
  String period = 'all';
  DateTime? from;
  DateTime? to;
  String? get dateFrom {
    final now = DateTime.now();
    switch (period) {
      case 'today':
        return _iso(now);
      case 'month':
        return _iso(DateTime(now.year, now.month, 1));
      case 'range':
        return from == null ? null : _iso(from!);
      default:
        return null;
    }
  }

  String? get dateTo {
    final now = DateTime.now();
    switch (period) {
      case 'today':
        return _iso(now);
      case 'month':
        return _iso(DateTime(now.year, now.month + 1, 0));
      case 'range':
        return to == null ? null : _iso(to!);
      default:
        return null;
    }
  }
}

Map<String, String> _periodLabels(AppLocalizations l10n) => {
  'all': l10n.translate('debtFiltersAll'),
  'today': l10n.translate('debtFiltersToday'),
  'month': l10n.translate('debtFiltersMonth'),
  'range': l10n.translate('debtFiltersRange'),
};

Future<String?> _pickCurrency(
  BuildContext context,
  WidgetRef ref,
  String? current,
) async {
  final enabled = await loadEnabledCurrencies(ref.read(currentUserIdProvider));
  if (!context.mounted || enabled.isEmpty) return null;
  final sorted = enabled.toList()..sort();
  return showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('عملة العرض', style: TextStyle(fontFamily: 'Cairo')),
      children: [
        for (final c in sorted)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, c),
            child: Text(
              debtCurrencyLabel(c),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
      ],
    ),
  );
}

// ════════════════════════════════════════════════════════════════
//  Business party → individual debts (same design as Personal)
// ════════════════════════════════════════════════════════════════
class PartyDebtsPage extends ConsumerStatefulWidget {
  final String partyKind; // customer | supplier
  final String partyId;
  final String name;
  final DirectoryPartyReference? localParty;
  const PartyDebtsPage({
    super.key,
    required this.partyKind,
    required this.partyId,
    required this.name,
    this.localParty,
  });
  @override
  ConsumerState<PartyDebtsPage> createState() => _PartyDebtsPageState();
}

class _PartyDebtsPageState extends ConsumerState<PartyDebtsPage>
    with _FiltersMixin {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;
  String? _ccy;
  String? _localName;
  int _readRevision = 0;

  bool get _isSupplier => widget.localParty != null
      ? widget.localParty!.kind == DirectoryPartyKind.supplier
      : widget.partyKind == 'supplier';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final revision = ++_readRevision;
    setState(() {
      _loading = widget.localParty == null && widget.partyId.isNotEmpty;
      _error = null;
    });
    try {
      final local = widget.localParty;
      if (local != null) {
        final cutover = ref.read(businessLocalLedgerScopeProvider);
        final party = await _lookupLocalParty(ref, local);
        if (!mounted || revision != _readRevision) return;
        final currency = cutover == null
            ? _ccy
            : _ccy ??
                  await resolveDefaultCurrency(ref.read(currentUserIdProvider));
        if (!mounted || revision != _readRevision) return;
        final report = cutover == null
            ? null
            : await _localDebtReport(
                ref,
                local,
                currency: currency!,
                dateFrom: dateFrom,
                dateTo: dateTo,
                individual: true,
              );
        if (!mounted || revision != _readRevision) return;
        _localScope(ref, local);
        setState(() {
          _localName = party.name;
          _ccy = currency;
          _data = report;
        });
        return;
      }
      if (widget.partyId.isEmpty) throw const DirectoryAccessDenied();
      _ccy ??= await resolveDefaultCurrency(ref.read(currentUserIdProvider));
      final d = await ref
          .read(merchantApiProvider)
          .businessOverview(
            partyKind: widget.partyKind,
            partyId: widget.partyId,
            currency: _ccy,
            dateFrom: dateFrom,
            dateTo: dateTo,
          );
      if (!mounted || revision != _readRevision) return;
      setState(() {
        _data = d;
        final s = '${d['display_currency'] ?? ''}';
        if (s.isNotEmpty) _ccy = s;
        _loading = false;
      });
    } catch (e) {
      if (mounted && revision == _readRevision) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  List<Map> get _ops =>
      ((_data?['individual'] as List?) ?? const []).whereType<Map>().toList();

  Future<void> _openInvoice(Map op) async {
    if (widget.localParty != null) {
      await context.push(
         '/debts/operation',
        extra: DirectoryDebtInvoiceReference(
          party: widget.localParty!,
          id: '${op['id']}',
        ),
      );
      if (mounted) _load();
      return;
    }
    if (widget.partyId.isEmpty) return;
    await context.push(
      '/debts/operation?kind=${widget.partyKind}'
      '&id=${widget.partyId}&inv=${op['id']}'
      '&name=${Uri.encodeComponent(shortDocumentNumber(op['number']))}',
    );
    if (mounted) _load();
  }

  Future<void> _addDebt() async {
    final local = widget.localParty;
    if (local != null) {
      if (await _addLocalDebt(context, ref, local) && mounted) _load();
      return;
    }
    if (widget.partyId.isEmpty) {
      _unmigratedFinance(context);
      return;
    }
    final q = _isSupplier
        ? 'supplier=${widget.partyId}'
        : 'customer=${widget.partyId}';
    context.push('${_isSupplier ? '/purchases/add' : '/sales/add'}?$q&debt=1');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final visible = _watchLocalVisibility(ref, widget.localParty);
    final name = visible ? _localName ?? widget.name : '';
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
      ),
      body: !visible
          ? DebtRetry(message: l10n.translate('unauthorized'), retry: _load)
          : _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _data == null
          ? DebtRetry(
              message: debtFriendlyError(
                _error ?? '',
                (k) => l10n.translate(k),
              ),
              retry: _load,
            )
          : FyonaRefresh(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                children: [
                  DebtPeriodFilter(
                    period: period,
                    from: from,
                    to: to,
                    labels: _periodLabels(l10n),
                    onChanged: (p, f, t) {
                      setState(() {
                        period = p;
                        from = f;
                        to = t;
                      });
                      _load();
                    },
                  ),
                  const SizedBox(height: 12),
                  DebtTotalHeroCard(
                    currency: _ccy,
                    grand: _data?['grand_total'],
                    paid: _data?['paid_total'],
                    remaining:
                        _data?['remaining_total'] ?? _data?['display_total'],
                    fxGaps:
                        ((_data?['fx_missing'] as List?) ?? const []).length,
                    title: l10n.translate('debtTotalTitle'),
                    subtitle: name,
                    paidLabel: l10n.translate('debtPaid'),
                    remainingLabel: l10n.translate('debtRemaining'),
                    fxGapText: l10n.translate('debtFxGap'),
                    emptyText: l10n.translate('debtEmptyOps'),
                    onPickCurrency: () async {
                      final c = await _pickCurrency(context, ref, _ccy);
                      if (c != null && c != _ccy && mounted) {
                        setState(() => _ccy = c);
                        _load();
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const DebtIcon(Icons.history, size: 30),
                      const SizedBox(width: 8),
                      Text(
                        l10n.translate('debtRecords'),
                        style: DebtStyle.text(context, size: 15, bold: true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_ops.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 36),
                      child: Center(
                        child: Text(
                          l10n.translate('debtNoneIndividual'),
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 13,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                    )
                  else
                    for (final op in _ops)
                      DebtOperationTile(
                        operation: op,
                        titlePrefix: l10n.translate('debtInvoiceWord'),
                        onTap: () => _openInvoice(op),
                      ),
                  const SizedBox(height: 14),
                  if (!BranchScope.readOnly &&
                      ref.watch(employeeCanProvider('debts.add')))
                    SizedBox(
                      width: double.infinity,
                      child: BranchScope.readOnly
                          ? const SizedBox.shrink()
                          : FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: DebtStyle.red,
                                minimumSize: const Size(0, 54),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed: _addDebt,
                              icon: const Icon(Icons.add, size: 20),
                              label: Text(
                                l10n.translate('bizAddDebt'),
                                maxLines: 1,
                                style: const TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 14,
                                  height: 1.4,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                    ),
                ],
              ),
            ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
//  Business party → sections grid (same design as Personal)
// ════════════════════════════════════════════════════════════════
class PartySectionsPage extends ConsumerStatefulWidget {
  final String partyKind;
  final String partyId;
  final String name;
  final DirectoryPartyReference? localParty;
  const PartySectionsPage({
    super.key,
    required this.partyKind,
    required this.partyId,
    required this.name,
    this.localParty,
  });
  @override
  ConsumerState<PartySectionsPage> createState() => _PartySectionsPageState();
}

class _PartySectionsPageState extends ConsumerState<PartySectionsPage> {
  List<Map> _groups = [];
  bool _loading = true;
  String? _error;
  String? _localName;
  bool _writing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = widget.localParty == null && widget.partyId.isNotEmpty;
      _error = null;
    });
    try {
      final local = widget.localParty;
      if (local != null) {
        final party = await _lookupLocalParty(ref, local);
        if (!mounted) return;
        final groups = await ref
            .read(directoryPilotStoreProvider)
            .groups(_localScope(ref, local), local);
        if (!mounted) return;
        _localScope(ref, local);
        setState(() {
          _localName = party.name;
          _groups = groups;
        });
        return;
      }
      if (widget.partyId.isEmpty) throw const DirectoryAccessDenied();
      final d = await ref
          .read(merchantApiProvider)
          .businessOverview(
            partyKind: widget.partyKind,
            partyId: widget.partyId,
          );
      if (!mounted) return;
      setState(() {
        _groups = ((d['groups'] as List?) ?? const [])
            .whereType<Map>()
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = '$e';
        });
    }
  }

  Future<void> _renameSection(Map g) async {
    if (_writing) return;
    _writing = true;
    try {
      await _renameSectionOnce(g);
    } finally {
      _writing = false;
    }
  }

  Future<void> _renameSectionOnce(Map g) async {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController(text: '${g['name'] ?? ''}');
    final navigator = Navigator.of(context, rootNavigator: true);
    var confirmed = false;
    final route = DialogRoute<bool>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      builder: (ctx) => AlertDialog(
        title: Text(
          l10n.translate('debtEditGroup'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontWeight: FontWeight.w800,
          ),
        ),
        content: FyonaTextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: l10n.translate('debtGroupNameExample'),
            hintMaxLines: 2,
            hintStyle: const TextStyle(fontFamily: 'Cairo', fontSize: 10.5),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              l10n.translate('cancel'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: DebtStyle.red),
            onPressed: () {
              if (confirmed) return;
              confirmed = true;
              Navigator.pop(ctx, true);
            },
            child: Text(
              l10n.translate('save'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
        ],
      ),
    );
    final ok = await navigator.push(route);
    final name = ctrl.text.trim();
    route.completed.whenComplete(ctrl.dispose);
    if (ok != true || name.isEmpty || !mounted) return;
    try {
      final local = widget.localParty;
      if (local != null) {
        await ref
            .read(directoryPilotStoreProvider)
            .renameGroup(
              _localScope(ref, local, write: true),
              local,
              '${g['id']}',
              name,
            );
      } else {
        if (widget.partyId.isEmpty) throw const DirectoryAccessDenied();
        await ref
            .read(merchantApiProvider)
            .renameDebtGroup(groupId: '${g['id']}', name: name);
      }
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.localParty == null
                  ? '$e'
                  : directorySaveError(e, widget.localParty!.kind, l10n),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
            backgroundColor: AppColors.danger,
          ),
        );
      }
    }
  }

  Future<void> _addSection() async {
    if (_writing) return;
    _writing = true;
    try {
      await _addSectionOnce();
    } finally {
      _writing = false;
    }
  }

  Future<void> _addSectionOnce() async {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController();
    final navigator = Navigator.of(context, rootNavigator: true);
    var confirmed = false;
    final command = const Uuid().v4();
    final route = DialogRoute<bool>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      builder: (ctx) => AlertDialog(
        title: Text(
          l10n.translate('debtAddGroup'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontWeight: FontWeight.w800,
          ),
        ),
        content: FyonaTextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: l10n.translate('debtGroupNameExample'),
            hintMaxLines: 2,
            hintStyle: const TextStyle(fontFamily: 'Cairo', fontSize: 10.5),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              l10n.translate('cancel'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: DebtStyle.red),
            onPressed: () {
              if (confirmed) return;
              confirmed = true;
              Navigator.pop(ctx, true);
            },
            child: Text(
              l10n.translate('save'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
        ],
      ),
    );
    final ok = await navigator.push(route);
    final name = ctrl.text.trim();
    route.completed.whenComplete(ctrl.dispose);
    if (ok != true || name.isEmpty || !mounted) return;
    try {
      final local = widget.localParty;
      if (local != null) {
        await ref
            .read(directoryPilotStoreProvider)
            .createGroup(
              _localScope(ref, local, write: true),
              local,
              name,
              commandId: command,
            );
      } else {
        if (widget.partyId.isEmpty) throw const DirectoryAccessDenied();
        await ref
            .read(merchantApiProvider)
            .createDebtGroup(
              partyKind: widget.partyKind,
              partyId: widget.partyId,
              name: name,
            );
      }
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.localParty == null
                  ? '$e'
                  : directorySaveError(e, widget.localParty!.kind, l10n),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
            backgroundColor: AppColors.danger,
          ),
        );
      }
    }
  }

  void _openGroup(Map g) {
    final local = widget.localParty;
    if (local != null) {
      context.push(
        '/debts/party-section',
        extra: DirectoryDebtGroupReference(party: local, id: '${g['id']}'),
      );
      return;
    }
    if (widget.partyId.isEmpty) return;
    context.push(
      '/debts/party-section?kind=${widget.partyKind}'
      '&id=${widget.partyId}'
      '&name=${Uri.encodeComponent(widget.name)}'
      '&gid=${g['id']}'
      '&gname=${Uri.encodeComponent('${g['name'] ?? ''}')}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final visible = _watchLocalVisibility(ref, widget.localParty);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(
          visible ? _localName ?? widget.name : '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
        actions: [
          if (visible &&
              !BranchScope.readOnly &&
              ref.watch(employeeCanProvider('debts.add')))
            IconButton(
              tooltip: l10n.translate('debtAddGroup'),
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: _addSection,
            ),
        ],
      ),
      body: !visible
          ? DebtRetry(message: l10n.translate('unauthorized'), retry: _load)
          : _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? DebtRetry(
              message: debtFriendlyError(
                _error ?? '',
                (k) => l10n.translate(k),
              ),
              retry: _load,
            )
          : FyonaRefresh(
              onRefresh: _load,
              child: _groups.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.fromLTRB(24, 44, 24, 24),
                      children: [
                        Center(
                          child: Container(
                            width: 72,
                            height: 72,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: DebtStyle.red.withAlpha(14),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: DebtStyle.red.withAlpha(50),
                              ),
                            ),
                            child: Icon(
                              Icons.folder_off_outlined,
                              size: 34,
                              color: DebtStyle.red,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          l10n.translate('debtNoSectionsParty'),
                          textAlign: TextAlign.center,
                          style: DebtStyle.text(context, size: 14, bold: true),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.translate('debtNoSectionsPartyHint'),
                          textAlign: TextAlign.center,
                          style: DebtStyle.text(
                            context,
                            size: 11,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 14),
                        if (!BranchScope.readOnly &&
                            ref.watch(employeeCanProvider('debts.add')))
                          Center(
                            child: BranchScope.readOnly
                                ? const SizedBox.shrink()
                                : FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: DebtStyle.red,
                                      minimumSize: const Size(0, 44),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 18,
                                        vertical: 12,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(22),
                                      ),
                                    ),
                                    onPressed: _addSection,
                                    icon: const Icon(Icons.add, size: 18),
                                    label: Text(
                                      l10n.translate('debtAddGroupCta'),
                                      maxLines: 1,
                                      style: const TextStyle(
                                        fontFamily: 'Cairo',
                                        fontSize: 13,
                                        height: 1.35,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                          ),
                      ],
                    )
                  : GridView(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        mainAxisExtent:
                            160 * MediaQuery.textScalerOf(context).scale(1),
                      ),
                      padding: const EdgeInsets.all(16),
                      children: [
                        for (final g in _groups)
                          DebtGroupTile(
                            group: g,
                            onEdit:
                                BranchScope.readOnly ||
                                    !ref.watch(employeeCanProvider('debts.add'))
                                ? null
                                : () => _renameSection(g),
                            countLabel: _invoiceCount(
                              l10n,
                              (g['count'] as num?)?.toInt() ?? 0,
                            ),
                            onTap: () => _openGroup(g),
                          ),
                      ],
                    ),
            ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
//  Business party → one section (same design as Personal + add debt)
// ════════════════════════════════════════════════════════════════
class PartySectionPage extends ConsumerStatefulWidget {
  final String partyKind;
  final String partyId;
  final String name;
  final String groupId;
  final String groupName;
  final DirectoryDebtGroupReference? localGroup;
  const PartySectionPage({
    super.key,
    required this.partyKind,
    required this.partyId,
    required this.name,
    required this.groupId,
    required this.groupName,
    this.localGroup,
  });
  @override
  ConsumerState<PartySectionPage> createState() => _PartySectionPageState();
}

class _PartySectionPageState extends ConsumerState<PartySectionPage>
    with _FiltersMixin {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;
  String? _ccy;
  String? _localGroupName;
  int _readRevision = 0;
  bool _settling = false;

  bool get _isSupplier => widget.localGroup != null
      ? widget.localGroup!.party.kind == DirectoryPartyKind.supplier
      : widget.partyKind == 'supplier';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final revision = ++_readRevision;
    setState(() {
      _loading = widget.localGroup == null && widget.partyId.isNotEmpty;
      _error = null;
    });
    try {
      final group = widget.localGroup;
      if (group != null) {
        final cutover = ref.read(businessLocalLedgerScopeProvider);
        final groups = await ref
            .read(directoryPilotStoreProvider)
            .groups(_localScope(ref, group.party), group.party);
        if (!mounted || revision != _readRevision) return;
        _localScope(ref, group.party);
        final selected = groups
            .where((row) => row['id'] == group.id)
            .singleOrNull;
        if (selected == null) throw const DirectoryPartyNotFound();
        final currency = cutover == null
            ? _ccy
            : _ccy ??
                  await resolveDefaultCurrency(ref.read(currentUserIdProvider));
        if (!mounted || revision != _readRevision) return;
        final report = cutover == null
            ? null
            : await _localDebtReport(
                ref,
                group.party,
                currency: currency!,
                dateFrom: dateFrom,
                dateTo: dateTo,
                group: group.id,
              );
        if (!mounted || revision != _readRevision) return;
        _localScope(ref, group.party);
        setState(() {
          _localGroupName = '${selected['name']}';
          _ccy = currency;
          _data = report;
        });
        return;
      }
      if (widget.partyId.isEmpty || widget.groupId.isEmpty) {
        throw const DirectoryAccessDenied();
      }
      _ccy ??= await resolveDefaultCurrency(ref.read(currentUserIdProvider));
      final d = await ref
          .read(merchantApiProvider)
          .businessOverview(
            partyKind: widget.partyKind,
            partyId: widget.partyId,
            currency: _ccy,
            groupId: widget.groupId,
            dateFrom: dateFrom,
            dateTo: dateTo,
          );
      if (!mounted || revision != _readRevision) return;
      setState(() {
        _data = d;
        final s = '${d['display_currency'] ?? ''}';
        if (s.isNotEmpty) _ccy = s;
        _loading = false;
      });
    } catch (e) {
      if (mounted && revision == _readRevision) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  List<Map> get _ops =>
      ((_data?['operations'] as List?) ?? const []).whereType<Map>().toList();

  double _n(dynamic v) =>
      v is num ? v.toDouble() : (double.tryParse('$v') ?? 0);

  Future<void> _settleSection() async {
    final group = widget.localGroup;
    if (group != null) {
      final scope = ref.read(businessLocalLedgerScopeProvider);
      if (scope == null || _settling) return;
      _settling = true;
      try {
        if (await showLocalGroupSettlement(context, ref, scope, group) &&
            mounted) {
          await _load();
        }
      } finally {
        _settling = false;
      }
      return;
    }
    if (widget.partyId.isEmpty) return;
    final remaining = _n(_data?['remaining_total'] ?? _data?['display_total']);
    if (remaining <= 0.004 || (_ccy ?? '').isEmpty) return;
    final ok = await showDebtSettlementSheet(
      context,
      ref,
      isSupplier: _isSupplier,
      partyId: widget.partyId,
      currency: _ccy!,
      remaining: remaining,
      groupId: widget.groupId,
    );
    if (ok && mounted) await _load();
  }

  Future<void> _openInvoice(Map op) async {
    final group = widget.localGroup;
    if (group != null) {
      await context.push(
         '/debts/operation',
        extra: DirectoryDebtInvoiceReference(
          party: group.party,
          id: '${op['id']}',
        ),
      );
      if (mounted) _load();
      return;
    }
    if (widget.partyId.isEmpty) return;
    await context.push(
      '/debts/operation'
      '?kind=${widget.partyKind}&id=${widget.partyId}&inv=${op['id']}'
      '&name=${Uri.encodeComponent(shortDocumentNumber(op['number']))}',
    );
    if (mounted) _load();
  }

  Future<void> _addDebt() async {
    final local = widget.localGroup;
    if (local != null) {
      if (await _addLocalDebt(context, ref, local.party, group: local.id) && mounted) _load();
      return;
    }
    if (widget.partyId.isEmpty) {
      _unmigratedFinance(context);
      return;
    }
    final q = _isSupplier
        ? 'supplier=${widget.partyId}'
        : 'customer=${widget.partyId}';
    context.push(
      '${_isSupplier ? '/purchases/add' : '/sales/add'}?$q&group=${widget.groupId}&debt=1',
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final visible = _watchLocalVisibility(ref, widget.localGroup?.party);
    final groupName = visible ? _localGroupName ?? widget.groupName : '';
    final hasLocalDebt = _ops.any((op) => _n(op['remaining']) > 0.004);
    final settled = widget.localGroup != null
        ? !hasLocalDebt
        : _n(_data?['remaining_total'] ?? _data?['display_total']) <= 0.004;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(
          groupName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
      ),
      body: !visible
          ? DebtRetry(message: l10n.translate('unauthorized'), retry: _load)
          : _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _data == null
          ? DebtRetry(
              message: debtFriendlyError(
                _error ?? '',
                (k) => l10n.translate(k),
              ),
              retry: _load,
            )
          : FyonaRefresh(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                children: [
                  DebtPeriodFilter(
                    period: period,
                    from: from,
                    to: to,
                    labels: _periodLabels(l10n),
                    onChanged: (p, f, t) {
                      setState(() {
                        period = p;
                        from = f;
                        to = t;
                      });
                      _load();
                    },
                  ),
                  const SizedBox(height: 12),
                  DebtTotalHeroCard(
                    currency: _ccy,
                    grand: _data?['grand_total'],
                    paid: _data?['paid_total'],
                    remaining:
                        _data?['remaining_total'] ?? _data?['display_total'],
                    fxGaps:
                        ((_data?['fx_missing'] as List?) ?? const []).length,
                    title: l10n.translate('debtTotalTitle'),
                    subtitle: groupName,
                    paidLabel: l10n.translate('debtPaid'),
                    remainingLabel: l10n.translate('debtRemaining'),
                    fxGapText: l10n.translate('debtFxGap'),
                    emptyText: l10n.translate('debtEmptyOps'),
                    onPickCurrency: () async {
                      final c = await _pickCurrency(context, ref, _ccy);
                      if (c != null && c != _ccy && mounted) {
                        setState(() => _ccy = c);
                        _load();
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  if (settled && (widget.localGroup == null || _ops.isNotEmpty))
                    SizedBox(
                      width: double.infinity,
                      child: BranchScope.readOnly
                          ? const SizedBox.shrink()
                          : FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(
                                  0xFF1F9D55,
                                ).withAlpha(30),
                                disabledBackgroundColor: const Color(
                                  0xFF1F9D55,
                                ).withAlpha(30),
                                foregroundColor: const Color(0xFF1F9D55),
                                disabledForegroundColor: const Color(
                                  0xFF1F9D55,
                                ),
                                minimumSize: const Size(0, 54),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed: null,
                              icon: const Icon(
                                Icons.check_circle,
                                size: 19,
                                color: Color(0xFF1F9D55),
                              ),
                              label: Text(
                                l10n.translate('debtSettledFull'),
                                style: const TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 14,
                                  height: 1.4,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF1F9D55),
                                ),
                              ),
                            ),
                    )
                  else if (!settled &&
                      !BranchScope.readOnly &&
                      ref.watch(employeeCanProvider('debts.settle')))
                    SizedBox(
                      width: double.infinity,
                      child: BranchScope.readOnly
                          ? const SizedBox.shrink()
                          : FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF1F9D55),
                                minimumSize: const Size(0, 54),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed: _settleSection,
                              icon: Icon(
                                _isSupplier
                                    ? Icons.payments_outlined
                                    : Icons.request_quote_outlined,
                                size: 19,
                              ),
                              label: Text(
                                l10n.translate(
                                  _isSupplier
                                      ? 'debtPaySupplier'
                                      : 'debtCollectCustomer',
                                ),
                                maxLines: 1,
                                style: const TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 14,
                                  height: 1.4,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                    ),
                  const SizedBox(height: 12),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const DebtIcon(Icons.history, size: 30),
                      const SizedBox(width: 8),
                      Text(
                        l10n.translate('debtRecords'),
                        style: DebtStyle.text(context, size: 15, bold: true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_ops.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 36),
                      child: Center(
                        child: Text(
                          l10n.translate('debtNoneIndividual'),
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 13,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                    )
                  else
                    for (final op in _ops)
                      DebtOperationTile(
                        operation: op,
                        titlePrefix: l10n.translate('debtInvoiceWord'),
                        onTap: () => _openInvoice(op),
                      ),
                  const SizedBox(height: 14),
                  if (!BranchScope.readOnly &&
                      ref.watch(employeeCanProvider('debts.add')))
                    SizedBox(
                      width: double.infinity,
                      child: BranchScope.readOnly
                          ? const SizedBox.shrink()
                          : FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: DebtStyle.red,
                                minimumSize: const Size(0, 54),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed: _addDebt,
                              icon: const Icon(Icons.add, size: 20),
                              label: Text(
                                l10n.translate('bizAddDebt'),
                                maxLines: 1,
                                style: const TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 14,
                                  height: 1.4,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                    ),
                ],
              ),
            ),
    );
  }
}
