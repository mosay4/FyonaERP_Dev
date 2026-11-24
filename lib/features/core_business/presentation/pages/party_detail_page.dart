import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:fyona_flutter/core/utils/document_number.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../widgets/business_number_field.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/network/api_exceptions.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/amount_input_formatter.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/phone_format.dart';
import '../../../sales/presentation/widgets/sale_payment_section.dart'
    show openBankCurrencyPicker;
import '../../../sales/presentation/providers/sale_providers.dart'
    show saleAccountsProvider;
import '../../../purchases/presentation/providers/purchase_providers.dart';
import '../providers/biz_payment_pref.dart';
import '../../../personal/data/merchant_api.dart';
import '../../../../shared/widgets/secure_image.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../../shared/widgets/chat_unread_icon.dart';
import '../../../../core/router/route_names.dart';
import '../../data/local_directory/directory_party.dart';
import '../../data/local_directory/directory_pilot.dart';
import '../../data/local_directory/directory_scope.dart';
import '../providers/business_ledger_session.dart';
import '../widgets/debt_widgets.dart';
import '../widgets/party_tracking.dart';
import '../providers/business_party_sharing_provider.dart';
import '../widgets/local_directory_actions.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

/// Supplier / customer detail: party info, per-currency balance, and the
/// single clear action (pay supplier / collect from customer).
class PartyDetailPage extends ConsumerStatefulWidget {
  final String id;
  final bool isSupplier;
  final DirectoryPartyReference? localParty;

  /// Name passed from the list so the identity card shows it instantly even
  /// before the overview request returns (never a fake name — just the one
  /// the list already displayed, or null).
  final String? fallbackName;
  const PartyDetailPage({
    super.key,
    required this.id,
    required this.isSupplier,
    this.fallbackName,
    this.localParty,
  });
  @override
  ConsumerState<PartyDetailPage> createState() => _PartyDetailPageState();
}

class _PartyDetailPageState extends ConsumerState<PartyDetailPage> {
  Map<String, dynamic> _data = const {};
  List<Map<String, dynamic>> _debts = [];
  List<Map<String, dynamic>> _ops = [];
  List<Map<String, dynamic>> _groups = [];
  Map<String, dynamic> _link = const {};
  Map<String, dynamic> _contact = const {};
  List<Map<String, dynamic>> _proofs = [];
  bool _loading = true;
  String? _error;
  Object? _directoryError;
  int _directoryLoad = 0;
  bool _editing = false;

  String get _kind => widget.isSupplier ? 'supplier' : 'customer';
  DirectoryPartyKind get _directoryKind =>
      widget.isSupplier ? DirectoryPartyKind.supplier : DirectoryPartyKind.customer;
  bool get _hasLegacyTarget => widget.localParty == null && widget.id.isNotEmpty;
  String get _editPermission => '${_kind}s.edit';

  DirectoryAccess _directoryScope({bool write = false}) {
    final local = widget.localParty;
    if (local == null || local.kind != _directoryKind || BranchScope.readOnly) {
      throw const DirectoryAccessDenied();
    }
    if (!ref.read(employeeCanProvider(write ? _editPermission : '${_kind}s.details'))) {
      throw const DirectoryAccessDenied();
    }
    return local.requireScope(ref.read(directoryPilotAccessProvider), write: write);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Single source: the merchant overview (same Invoice + receivable/payable
  /// rows the personal side reads). Balances/ops fall back to the legacy
  /// endpoints only if the overview itself is unreachable.
  Future<void> _load() async {
    if (!_hasLegacyTarget) {
      await _loadDirectory();
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final mapi = ref.read(merchantApiProvider);
      final data = await mapi.businessOverview(
        partyKind: _kind,
        partyId: widget.id,
      );
      if (!mounted) return;
      final ops = [
        for (final o
            in ((data['operations'] as List?) ?? const []).whereType<Map>())
          {
            'invoice_id': '${o['id'] ?? ''}',
            'invoice_number': '${o['number'] ?? ''}',
            'date': '${o['date'] ?? ''}',
            'total': o['total'],
            'paid': o['paid'],
            'balance': o['remaining'],
            'currency': '${o['currency'] ?? ''}',
            'status': '${o['status'] ?? ''}',
            'group_id': o['group_id']?.toString(),
          },
      ];
      setState(() {
        _data = data;
        _debts = [
          for (final d
              in ((data['per_currency'] as List?) ?? const []).whereType<Map>())
            {
              'currency': '${d['currency'] ?? ''}',
              'debt': double.tryParse('${d['total'] ?? 0}') ?? 0,
            },
        ];
        _ops = ops;
        _groups = [
          for (final g
              in ((data['groups'] as List?) ?? const []).whereType<Map>())
            Map<String, dynamic>.from(g),
        ];
        _link = Map<String, dynamic>.from(data['link'] as Map? ?? const {});
        _contact = Map<String, dynamic>.from(
          data['contact'] as Map? ?? const {},
        );
        _proofs = [
          for (final p
              in ((data['requests'] as List?) ?? const []).whereType<Map>())
            if ('${p['status']}' == 'pending') Map<String, dynamic>.from(p),
        ];
      });
      // ALWAYS load the complete operation timeline for this party (newest
      // first), even when a settled invoice is no longer in the debt overview.
      try {
        final api = ref.read(purchaseApiProvider);
        final full = widget.isSupplier
            ? await api.supplierOperations(widget.id)
            : await api.customerOperations(widget.id);
        if (mounted && full.isNotEmpty) {
          final groupsByInvoice = {
            for (final o in ops)
              '${o['invoice_id']}': o['group_id']?.toString(),
          };
          setState(() {
            _ops = [
              for (final o in full.whereType<Map>())
                {
                  ...Map<String, dynamic>.from(o),
                  'group_id': groupsByInvoice['${o['invoice_id']}'],
                },
            ];
          });
        }
      } catch (_) {}
    } catch (e) {
      if (!mounted) return;
      // Legacy fallback: balances + ops + link status stay readable even if
      // the overview endpoint is down; groups simply stay empty.
      try {
        final api = ref.read(purchaseApiProvider);
        final res = widget.isSupplier
            ? await api.supplierBalance(widget.id)
            : await api.customerBalance(widget.id);
        if (mounted) {
          setState(
            () => _debts = [
              for (final d
                  in (res['debts'] as List? ?? const []).whereType<Map>())
                Map<String, dynamic>.from(d),
            ],
          );
        }
        final ops = widget.isSupplier
            ? await api.supplierOperations(widget.id)
            : await api.customerOperations(widget.id);
        if (mounted) {
          setState(
            () => _ops = [
              for (final o in ops.whereType<Map>())
                Map<String, dynamic>.from(o),
            ],
          );
        }
        final mapi = ref.read(merchantApiProvider);
        final st = await mapi.linkStatus(partyKind: _kind, partyId: widget.id);
        final pr = await mapi.settlementRequests(
          partyKind: _kind,
          partyId: widget.id,
        );
        if (mounted) {
          setState(() {
            _link = st;
            _proofs = pr.where((p) => '${p['status']}' == 'pending').toList();
          });
        }
      } catch (_) {
        if (mounted) setState(() => _error = '$e');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadDirectory() async {
    final revision = ++_directoryLoad;
    try {
      final scope = _directoryScope();
      final local = widget.localParty!;
      final party = await ref.read(directoryPilotStoreProvider).find(
        scope, _directoryKind, local.id,
      );
      if (!mounted || revision != _directoryLoad) return;
      _directoryScope();
      final finance = ref.read(businessLocalLedgerScopeProvider);
      final ledger = finance == null || !ref.read(employeeCanProvider('debts.details'))
          ? null : await loadLocalDebts(ref, scope, local);
      if (!mounted || revision != _directoryLoad) return;
      _directoryScope();
      final sharing = ref.read(localBusinessPartySharingProvider);
      Map<String, dynamic> link = const {};
      if (sharing != null) {
        try {
          link = await sharing.cachedStatus(local);
        } on DirectoryAccessDenied {
          // Optional sharing never prevents the scoped card and debt read.
        }
      }
      if (!mounted || revision != _directoryLoad) return;
      _directoryScope();
      setState(() {
        _data = {
          'party': {
            'id': party.id,
            'name': party.name,
            'phone': party.phone,
            'created_at': party.createdAt.toIso8601String(),
          },
        };
        _ops = [
          for (final o in ledger?.operations ?? const <Map<String, dynamic>>[])
            {
              'invoice_id': o['id'],
              'invoice_number': o['number'],
              'date': o['date'],
              'total': o['total'],
              'paid': o['paid'],
              'balance': o['remaining'],
              'currency': o['currency'],
              'status': o['status'],
              'group_id': o['group_id'],
            },
        ];
        _debts = [
          for (final row in ledger?.perCurrency ?? const <Map<String, dynamic>>[])
            {'currency': row['currency'], 'debt': row['total']},
        ];
        _contact = {'via': 'phone', 'value': party.phone};
        _link = link;
        _loading = false;
        _directoryError = null;
      });
    } catch (error) {
      if (!mounted || revision != _directoryLoad) return;
      setState(() {
        _data = const {};
        _contact = const {};
        _link = const {};
        _ops = [];
        _debts = [];
        _loading = false;
        _directoryError = error;
      });
    }
  }

  Future<void> _openPartyDebts(String path, String title) async {
    final local = widget.localParty;
    if (local != null) {
      await context.push(path, extra: local);
      if (mounted) await _loadDirectory();
      return;
    }
    if (!_hasLegacyTarget) return;
    context.push('$path?kind=$_kind&id=${widget.id}&name=${Uri.encodeComponent(title)}');
  }

  List<Map<String, dynamic>> _groupOps(String groupId) =>
      _ops.where((o) => '${o['group_id'] ?? ''}' == groupId).toList();

  List<Map<String, dynamic>> get _individualOps =>
      _ops.where((o) => '${o['group_id'] ?? ''}'.isEmpty).toList();

  List<Map<String, dynamic>> get _sortedOps {
    final list = [..._ops];
    list.sort((a, b) {
      final da = '${a['date'] ?? ''}';
      final db = '${b['date'] ?? ''}';
      return db.compareTo(da);
    });
    return list;
  }

  Future<void> _createGroup() async {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          l10n.translate('debtAddGroup'),
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        content: FyonaTextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: l10n.translate('debtGroupNameHint'),
          ),
          style: const TextStyle(fontFamily: 'Cairo'),
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
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.translate('save'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
        ],
      ),
    );
    final name = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || name.isEmpty || !mounted) return;
    try {
      await ref
          .read(merchantApiProvider)
          .createDebtGroup(partyKind: _kind, partyId: widget.id, name: name);
      await _load();
    } catch (e) {
      if (mounted) showFyonaSnack(context, '$e', success: false);
    }
  }

  Future<void> _renameGroup(Map g) async {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController(text: '${g['name'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          l10n.translate('debtRename'),
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        content: FyonaTextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(fontFamily: 'Cairo'),
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
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.translate('save'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
        ],
      ),
    );
    final name = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || name.isEmpty || !mounted) return;
    try {
      await ref
          .read(merchantApiProvider)
          .renameDebtGroup(groupId: '${g['id']}', name: name);
      await _load();
    } catch (e) {
      if (mounted) showFyonaSnack(context, '$e', success: false);
    }
  }

  Future<void> _deleteGroup(Map g) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          '${g['name'] ?? ''}',
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        content: Text(
          l10n.translate('debtDeleteGroupConfirm'),
          style: const TextStyle(fontFamily: 'Cairo'),
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
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.translate('debtDelete'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref
          .read(merchantApiProvider)
          .deleteDebtGroup(groupId: '${g['id']}');
      await _load();
    } catch (e) {
      if (mounted) showFyonaSnack(context, '$e', success: false);
    }
  }

  /// Move an operation into a section (or back to individual debts).
  Future<void> _assignOp(Map o) async {
    final l10n = AppLocalizations.of(context);
    final picked = await showDialog<String?>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(
          l10n.translate('debtAssignGroup'),
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ''),
            child: Text(
              l10n.translate('debtNoGroup'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          for (final g in _groups)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, '${g['id']}'),
              child: Text(
                '${g['name'] ?? ''}',
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    try {
      await ref
          .read(merchantApiProvider)
          .assignOperationGroup(
            invoiceId: '${o['invoice_id'] ?? ''}',
            partyKind: _kind,
            partyId: widget.id,
            groupId: picked.isEmpty ? null : picked,
          );
      await _load();
    } catch (e) {
      if (mounted) showFyonaSnack(context, '$e', success: false);
    }
  }

  Future<void> _editParty() async {
    if (_editing) return;
    _editing = true;
    try {
      await _editPartyOnce();
    } finally {
      _editing = false;
    }
  }

  Future<void> _editPartyOnce() async {
    final l10n = AppLocalizations.of(context);
    if (!_hasLegacyTarget) {
      try {
        _directoryScope(write: true);
      } catch (e) {
        showFyonaSnack(context, directorySaveError(e, _directoryKind, l10n), success: false);
        return;
      }
    }
    final party = Map<String, dynamic>.from(_data['party'] as Map? ?? const {});
    final nameCtrl = TextEditingController(text: '${party['name'] ?? ''}');
    final phoneCtrl = TextEditingController(
      text: '${_contact['via'] == 'phone' ? _contact['value'] ?? '' : ''}',
    );
    var confirmed = false;
    final dialog = DialogRoute<bool>(
      context: context,
      themes: InheritedTheme.capture(
        from: context,
        to: Navigator.of(context, rootNavigator: true).context,
      ),
      builder: (ctx) => AlertDialog(
        title: Text(
          l10n.translate('debtEditParty'),
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FyonaTextField(
              controller: nameCtrl,
              decoration: InputDecoration(
                labelText: l10n.translate('purSupplierName'),
              ),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
            const SizedBox(height: 10),
            FyonaTextField(
              controller: phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: l10n.translate('purSupplierPhoneOpt'),
              ),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ],
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
    final ok = await Navigator.of(context, rootNavigator: true).push(dialog);
    final name = nameCtrl.text.trim();
    final phone = phoneCtrl.text.trim();
    dialog.completed.whenComplete(() {
      nameCtrl.dispose();
      phoneCtrl.dispose();
    });
    if (ok != true || !mounted) return;
    try {
      if (!_hasLegacyTarget) {
        final scope = _directoryScope(write: true);
        await ref.read(directoryPilotStoreProvider).update(
          scope, _directoryKind, widget.localParty!.id,
          name: name, phone: phone,
        );
        if (!mounted) return;
        ref.read(directoryPartyRevisionProvider(_directoryKind).notifier).state++;
        await _loadDirectory();
        return;
      }
      final api = ref.read(purchaseApiProvider);
      if (widget.isSupplier) {
        await api.updateSupplier(
          widget.id,
          name: name.isEmpty ? null : name,
          phone: phone.isEmpty ? null : phone,
        );
      } else {
        await api.updateCustomer(
          widget.id,
          name: name.isEmpty ? null : name,
          phone: phone.isEmpty ? null : phone,
        );
      }
      await _load();
    } catch (e) {
      if (mounted) {
        showFyonaSnack(context, _hasLegacyTarget
            ? '$e' : directorySaveError(e, _directoryKind, l10n), success: false);
      }
    }
  }

  void _showPendingInvite(AppLocalizations l10n) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: dark ? const Color(0xFF2A2A2A) : Colors.white,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
          content: Row(
            children: [
              const Icon(
                Icons.schedule_rounded,
                size: 16,
                color: AppColors.warning,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    l10n.translate(
                      widget.isSupplier
                          ? 'merchantInvitePendingSupplier'
                          : 'merchantInvitePendingCustomer',
                    ),
                    maxLines: 1,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 10.5,
                      color: dark ? Colors.white : Colors.black87,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
  }

  String _apiMessage(Object e) {
    if (e is ApiException) return e.message;
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map) {
        final d = data['detail'] ?? data['message'] ?? data['error'];
        if (d is List && d.isNotEmpty) return '${d.first}';
        if (d != null) return '$d';
      }
    }
    return '$e';
  }

  Future<void> _invite() async {
    if (!_hasLegacyTarget && widget.localParty == null) return;
    final l10n = AppLocalizations.of(context);
    if ('${_link['status'] ?? ''}' == 'pending') {
      _showPendingInvite(l10n);
      return;
    }
    final invited = await showPartyTrackingDialog(
      context,
      ref,
      partyKind: _kind,
      partyId: widget.id,
      localParty: widget.localParty,
    );
    if (invited && mounted) await _load();
  }

  Future<void> _decideProof(Map p, bool approve) async {
    final l10n = AppLocalizations.of(context);
    String? reason;
    String? accountId;
    if (approve) {
      final accounts = ref.read(saleAccountsProvider).valueOrNull ?? const [];
      final pick = await openBankCurrencyPicker(context, accounts);
      if (pick == null || !context.mounted) return;
      accountId = '${pick.accountId}';
    } else {
      final ctrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            l10n.translate('merchantRejectReason'),
            style: const TextStyle(fontFamily: 'Cairo'),
          ),
          content: FyonaTextField(
            controller: ctrl,
            autofocus: true,
            style: const TextStyle(fontFamily: 'Cairo'),
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
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                l10n.translate('merchantReject'),
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      reason = ctrl.text.trim();
      ctrl.dispose();
    }
    try {
      await ref
          .read(merchantApiProvider)
          .decideSettlement(
            requestId: '${p['id']}',
            approve: approve,
            bankAccountId: accountId,
            reason: reason,
          );
      if (mounted) {
        showFyonaSnack(
          context,
          l10n.translate(
            widget.isSupplier
                ? 'merchantInviteSentSupplier'
                : 'merchantInviteSentCustomer',
          ),
          success: true,
        );
      }
      _load();
    } catch (e) {
      if (mounted) {
        showFyonaSnack(context, '$e', success: false);
      }
    }
  }

  Future<void> _settle() async {
    // The connected banking picker and writer cannot be used with a local
    // route. Release the action on the Business ledger only after cutover.
    if (!_hasLegacyTarget) return;
    final l10n = AppLocalizations.of(context);
    final accounts = ref.read(saleAccountsProvider).valueOrNull ?? const [];
    final pick = await openBankCurrencyPicker(context, accounts);
    if (pick == null || !context.mounted) return;
    final debtCur = _debts.isNotEmpty
        ? (_debts.first['currency'] ?? '').toString().toUpperCase()
        : pick.currency;
    final cross = debtCur.isNotEmpty && pick.currency != debtCur;
    double rate = 1;
    if (cross) {
      final r = ref
          .read(currencyEngineProvider)
          .getRate(pick.currency, debtCur);
      rate = (r == null || r <= 0) ? 1 : r;
    }
    final ctrl = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            16 + MediaQuery.of(ctx).padding.bottom,
          ),
          child: StatefulBuilder(
            builder: (ctx, setSt) {
              final amt = parseFormattedAmount(ctrl.text) ?? 0;
              final converted = amt * rate;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.translate(
                      widget.isSupplier
                          ? 'purPaySupplier'
                          : 'purCollectCustomer',
                    ),
                    style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${pick.bankName} - ${currencyName(pick.currency)}',
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  BusinessNumberField(
                    controller: ctrl,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [AmountInputFormatter()],
                    onChanged: (_) => setSt(() {}),
                    decoration: InputDecoration(
                      labelText: l10n.translate('salePaidAmountHint'),
                      suffixText: currencyName(pick.currency),
                    ),
                    style: const TextStyle(fontFamily: 'Cairo'),
                  ),
                  if (cross) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(16),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '1 ${currencyName(pick.currency)} = ${rate.toStringAsFixed(4)} ${currencyName(debtCur)}',
                                  style: const TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  '${l10n.translate('purAppliedAmount')}: ${fmtNum(converted)} ${currencyName(debtCur)}',
                                  style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            color: AppColors.primary,
                            onPressed: () async {
                              final rc = TextEditingController(
                                 text: rate.toStringAsFixed(4),
                               );
                               final nr = await showDialog<double>(
                                 context: ctx,
                                 builder: (c2) => AlertDialog(
                                  title: Text(
                                    l10n.translate('saleEditRate'),
                                    style: const TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 16,
                                    ),
                                  ),
                                  content: BusinessNumberField(
                                    controller: rc,
                                    autofocus: true,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    style: const TextStyle(fontFamily: 'Cairo'),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(c2),
                                      child: Text(
                                        l10n.translate('cancel'),
                                        style: const TextStyle(
                                          fontFamily: 'Cairo',
                                        ),
                                      ),
                                    ),
                                    FilledButton(
                                      onPressed: () => Navigator.pop(
                                        c2,
                                         double.tryParse(rc.text.trim()),
                                      ),
                                      child: Text(
                                        l10n.translate('save'),
                                        style: const TextStyle(
                                          fontFamily: 'Cairo',
                                        ),
                                      ),
                                    ),
                                  ],
                                 ),
                               );
                               rc.dispose();
                               if (nr != null && nr > 0) setSt(() => rate = nr);
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: FilledButton(
                       onPressed: () => Navigator.pop(ctx, true),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        l10n.translate(
                          widget.isSupplier ? 'purSettle' : 'collect',
                        ),
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          height: 1.6,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    final amount = parseFormattedAmount(ctrl.text) ?? 0;
    ctrl.dispose();
    if (ok != true || amount <= 0 || !context.mounted) return;
    // Business: block paying more than the account balance unless allowed.
    final pref = ref.read(bizPaymentPrefProvider);
    final acct = accounts.firstWhere(
      (a) => a['id'] == pick.accountId,
      orElse: () => const <String, String>{},
    );
    final bal = double.tryParse('${acct['balance'] ?? 0}') ?? 0;
    if (amount > bal + 0.0001 && !pref.allowNegative) {
      if (pref.promptShown) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppColors.danger,
            content: Text(
              l10n.translate('purOverpayBody'),
              style: const TextStyle(fontFamily: 'Cairo', color: Colors.white),
            ),
          ),
        );
        return;
      }
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            l10n.translate('payNegTitle'),
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontSize: 16,
              height: 1.5,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'always'),
              child: Text(
                l10n.translate('payNegAlways'),
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'once'),
              child: Text(
                l10n.translate('payNegOnce'),
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              child: Text(
                l10n.translate('payNegCancel'),
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
            ),
          ],
        ),
      );
      await ref.read(bizPaymentPrefProvider.notifier).markPromptShown();
      if (choice == 'always') {
        await ref.read(bizPaymentPrefProvider.notifier).setAllowNegative(true);
      } else if (choice != 'once') {
        return;
      }
    }
    try {
      final body = {
        'bank_account_id': pick.accountId,
        'amount': amount,
        'currency': pick.currency,
        'payment_method': pick.bankName.trim() == 'كاش' ? 'cash' : 'bank',
        if (cross) 'exchange_rate': rate,
      };
      final api = ref.read(purchaseApiProvider);
      final result = widget.isSupplier
          ? await api.paySupplier(widget.id, body)
          : await api.collectCustomer(widget.id, body);

      await _load();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppColors.success,
            content: Text(
              l10n.translate(
                widget.isSupplier ? 'purSettleOk' : 'debtCollectOk',
              ),
              style: const TextStyle(
                fontFamily: 'Cairo',
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      String msg;
      if (e is ApiException) {
        msg = e.message;
      } else if (e is DioException) {
        final d = e.response?.data;
        if (d is Map) {
          msg = (d['message'] ?? d['detail'] ?? e.message ?? '').toString();
        } else {
          msg = e.message ?? e.toString();
        }
      } else {
        msg = e.toString();
      }
      final over = msg.contains('المستحق') || msg.contains('يتجاوز');
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              const Icon(Icons.error_outline, color: AppColors.danger),
              const SizedBox(width: 8),
              Text(
                l10n.translate('purOverpayTitle'),
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.w700,
                  color: AppColors.danger,
                ),
              ),
            ],
          ),
          content: Text(
            over ? l10n.translate('purOverpayBody') : msg,
            style: const TextStyle(fontFamily: 'Cairo', height: 1.5),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              child: Text(
                l10n.translate('saleClose'),
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
            ),
          ],
        ),
      );
    }
  }

  /// Red identity card (reference 3 "After accessing a client or supplier
  /// account"): avatar + real name + public code + تعديل, then a 3-column
  /// footer (تاريخ الإضافة | رقم الهاتف | الرقم المميز). A not-linked party
  /// gets a compact «دعوة للمتابعة» chip — never a separate empty card.
  /// Identity card: linked photo (if any), full name, a pencil-only edit,
  /// added date and ONE contact (phone if the merchant has it, else the public
  /// code) — no duplicated code.
  Widget _identityCard(AppLocalizations l10n) {
    final party = Map<String, dynamic>.from(_data['party'] as Map? ?? const {});
    final name = '${party['name'] ?? widget.fallbackName ?? ''}'.trim();
    final added = '${party['created_at'] ?? ''}'.split('T').first;
    final partyPhone = '${party['phone'] ?? ''}'.trim();
    final via = '${_link['linked_via'] ?? ''}';
    final linkPhone = '${_link['phone'] ?? ''}'.trim();
    final code = '${_link['public_code'] ?? ''}'.trim();
    final avatar = '${_link['avatar'] ?? ''}'.trim();
    final status = '${_link['status'] ?? 'none'}';
    final linked = status == 'accepted';

    // Follow the LINK METHOD exactly: linked by public code → the merchant
    // sees the code; linked by phone → the merchant sees the phone only.
    String contactLabel = l10n.translate('debtPhoneLabel');
    String contactValue = '';
    if (via == 'code' && code.isNotEmpty) {
      contactLabel = l10n.translate('debtPublicCodeLabel');
      contactValue = code;
    } else if (partyPhone.isNotEmpty) {
      contactValue = formatIntlPhone(partyPhone);
    } else if (linkPhone.isNotEmpty) {
      contactValue = formatIntlPhone(linkPhone);
    } else if (code.isNotEmpty) {
      contactLabel = l10n.translate('debtPublicCodeLabel');
      contactValue = code;
    }

    Widget avatarWidget = const DebtIcon(
      Icons.person_outline,
      size: 54,
      inverse: true,
    );
    if (avatar.isNotEmpty) {
      avatarWidget = ClipOval(
        child: SecureImage(
          url: avatar.startsWith('uploads/') ? '/$avatar' : avatar,
          width: 54,
          height: 54,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) =>
              const DebtIcon(Icons.person_outline, size: 54, inverse: true),
        ),
      );
    }

    Widget col(String label, String value, {bool ltr = false}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 11,
            color: Colors.white70,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value.isEmpty ? '—' : value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textDirection: ltr ? TextDirection.ltr : null,
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ],
    );

    return DebtPanel(
      red: true,
      decorated: true,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              avatarWidget,
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  name.isEmpty ? '—' : name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
              if (!BranchScope.readOnly &&
                  ref.watch(
                    employeeCanProvider(
                      '${widget.isSupplier ? 'suppliers' : 'customers'}.edit',
                    ),
                  ))
                IconButton(
                  tooltip: l10n.translate('debtEditParty'),
                  onPressed: _editParty,
                  icon: const Icon(
                    Icons.edit_outlined,
                    size: 20,
                    color: Colors.white,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: col(l10n.translate('debtAddedAt'), added)),
              Container(width: 1, height: 32, color: Colors.white24),
              const SizedBox(width: 12),
              Expanded(child: col(contactLabel, contactValue, ltr: true)),
            ],
          ),
          if (!linked &&
              !BranchScope.readOnly &&
              ref.watch(
                employeeCanProvider(
                  '${widget.isSupplier ? 'suppliers' : 'customers'}.edit',
                ),
              )) ...[
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: _invite,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white70),
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                icon: const Icon(Icons.person_add_alt_1, size: 16),
                label: Text(
                  l10n.translate('merchantInviteBtn'),
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// «ديونه حسب العملة» — per-currency balance boxes (reference 3). Raw codes
  /// are never shown; each box shows the localized currency name + amount.
  Widget _totalsCard(AppLocalizations l10n) {
    return DebtPanel(
      decorated: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const DebtIcon(Icons.account_balance_wallet_outlined, size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.translate('debtBalanceByCurrency'),
                      style: DebtStyle.text(context, size: 13, bold: true),
                    ),
                    if (!BranchScope.readOnly &&
                        ref.watch(employeeCanProvider('debts.settle')))
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton(
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 22),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: _settle,
                          child: Text(
                            l10n.translate('debtRecordPayment'),
                            style: DebtStyle.text(
                              context,
                              size: 12,
                              bold: true,
                              color: DebtStyle.red,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_debts.isEmpty)
            Text(
              '0',
              style: DebtStyle.text(
                context,
                size: 20,
                bold: true,
                color: AppColors.success,
              ),
            )
          else
            // 2 boxes per row via Expanded (no MediaQuery width math — safe on
            // any screen size / orientation).
            Column(
              children: [
                for (var i = 0; i < _debts.length; i += 2)
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: _ccyBox(
                            '${_debts[i]['currency'] ?? ''}',
                            _debts[i]['debt'],
                          ),
                        ),
                        const SizedBox(width: 10),
                        if (i + 1 < _debts.length)
                          Expanded(
                            child: _ccyBox(
                              '${_debts[i + 1]['currency'] ?? ''}',
                              _debts[i + 1]['debt'],
                            ),
                          )
                        else
                          const Spacer(),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _ccyBox(String code, dynamic amount) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: DebtStyle.red.withAlpha(10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DebtStyle.red.withAlpha(40)),
      ),
      child: Row(
        children: [
          const DebtArrow(color: DebtStyle.red),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  debtCurrencyLabel(code),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DebtStyle.text(context, size: 11, color: Colors.grey),
                ),
                Text(
                  debtAmount(amount),
                  textDirection: TextDirection.ltr,
                  style: DebtStyle.text(
                    context,
                    size: 17,
                    bold: true,
                    color: DebtStyle.red,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Compact navigation row (reference 3: مجموعات الديون / ديون منفردة /
  /// طلبات السداد) — opens a sheet with the real content + management.
  Widget _navRow(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: DebtPanel(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              DebtIcon(icon, size: 38),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: DebtStyle.text(context, size: 14, bold: true),
                    ),
                    Text(
                      subtitle,
                      style: DebtStyle.text(
                        context,
                        size: 11.5,
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
              const DebtArrow(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _groupTile(AppLocalizations l10n, Map<String, dynamic> g) {
    final ops = _groupOps('${g['id'] ?? ''}');
    return DebtPanel(
      decorated: true,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const DebtIcon(Icons.folder_outlined, size: 38),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${g['name'] ?? ''}',
                      style: DebtStyle.text(context, size: 14, bold: true),
                    ),
                    Text(
                      l10n.translate(
                        'debtOpsCount',
                        params: {'n': '${ops.length}'},
                      ),
                      style: DebtStyle.text(
                        context,
                        size: 11,
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
              if (!BranchScope.readOnly &&
                  ref.watch(employeeCanProvider('debts.add')))
                IconButton(
                  tooltip: l10n.translate('debtRename'),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: () => _renameGroup(g),
                ),
              if (!BranchScope.readOnly &&
                  ref.watch(employeeCanProvider('debts.add')))
                IconButton(
                  tooltip: l10n.translate('debtDelete'),
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: AppColors.danger,
                  ),
                  onPressed: () => _deleteGroup(g),
                ),
            ],
          ),
          if (ops.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final o in ops.take(3)) _opTile(context, l10n, o),
            if (ops.length > 3)
              Text(
                '+${ops.length - 3}',
                style: DebtStyle.text(context, size: 11, color: Colors.grey),
              ),
          ],
        ],
      ),
    );
  }

  Widget _proofsCard(AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.warning.withAlpha(16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.translate('merchantPendingProofs'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          for (final p in _proofs) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${p['amount']} ${p['currency']}',
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                if (!BranchScope.readOnly &&
                    ref.watch(employeeCanProvider('debts.settle')))
                  TextButton(
                    onPressed: () => _decideProof(p, false),
                    child: Text(
                      l10n.translate('merchantReject'),
                      style: const TextStyle(fontFamily: 'Cairo', fontSize: 12),
                    ),
                  ),
                if (!BranchScope.readOnly &&
                    ref.watch(employeeCanProvider('debts.settle')))
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.success,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed: () => _decideProof(p, true),
                    child: Text(
                      l10n.translate('merchantApprove'),
                      style: const TextStyle(fontFamily: 'Cairo', fontSize: 12),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.localParty != null) {
      ref.listen(businessPartyShareRevisionProvider, (_, __) => _loadDirectory());
    }
    final l10n = AppLocalizations.of(context);
    var canSeeDirectoryParty = true;
    if (!_hasLegacyTarget) {
      ref.watch(directoryPilotAccessProvider);
      ref.watch(employeeCanProvider('${_kind}s.details'));
      ref.listen(directoryPilotAccessProvider, (before, after) {
        if (!sameDirectoryScope(before, after)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _loadDirectory();
          });
        }
      });
      ref.listen(businessLocalLedgerScopeProvider, (before, after) {
        if (!sameDirectoryScope(before, after)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _loadDirectory();
          });
        }
      });
      ref.listen(employeeCanProvider('debts.details'), (before, after) {
        if (before != after) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _loadDirectory();
          });
        }
      });
      ref.listen(employeeCanProvider('${_kind}s.details'), (before, after) {
        if (before != after) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _loadDirectory();
          });
        }
      });
      try {
        _directoryScope();
      } on DirectoryAccessDenied {
        canSeeDirectoryParty = false;
      }
    }
    final party = canSeeDirectoryParty
        ? Map<String, dynamic>.from(_data['party'] as Map? ?? const {})
        : const <String, dynamic>{};
    final title = '${party['name'] ?? (_hasLegacyTarget ? widget.fallbackName : null) ?? ''}'.trim();
    final shownTitle = title.isEmpty
        ? l10n.translate(widget.isSupplier ? 'bizSuppliers' : 'bizCustomers')
        : title;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          shownTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontWeight: FontWeight.w700,
          ),
        ),
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        actions: [
          if ('${_link['status'] ?? ''}' == 'accepted' &&
              '${_link['id'] ?? ''}'.isNotEmpty) ...[
            ChatUnreadIcon(
              side: 'merchant',
              linkId: '${_link['id']}',
              onPressed: () async {
                // The conversation opens offline from the device copy; what
                // is written waits as «sending» until the connection is back.
                if (!context.mounted) return;
                context.push('/debts/chat?link=${_link['id']}');
              },
            ),
            IconButton(
              tooltip: 'notifications',
              icon: const Icon(Icons.notifications_outlined),
              onPressed: () => context.push(
                '/debts/notifications?link=${_link['id']}'
                '&name=${Uri.encodeComponent(shownTitle)}',
              ),
            ),
          ],
        ],
      ),
      body: !canSeeDirectoryParty
          ? DebtRetry(message: l10n.translate('unauthorized'), retry: _load)
          : _loading
          ? (_hasLegacyTarget
              ? const Center(child: CircularProgressIndicator())
              : const SizedBox.shrink())
          : (_error != null || _directoryError != null) && _data.isEmpty
          ? DebtRetry(
              message: !_hasLegacyTarget
                  ? directorySaveError(_directoryError!, _directoryKind, l10n)
                  : debtFriendlyError(
                _error ?? '',
                (k) => l10n.translate(k),
              ),
              retry: _load,
            )
          : FyonaRefresh(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _identityCard(l10n),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _navButton(
                          Icons.description_outlined,
                          l10n.translate('debtIndividualRow'),
                          true,
                          () => _openPartyDebts('/debts/party-individual', shownTitle),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _navButton(
                          Icons.folder_special_outlined,
                          l10n.translate('debtGroupsRow'),
                          false,
                          () => _openPartyDebts('/debts/party-sections', shownTitle),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.translate('debtRecentOps'),
                          style: DebtStyle.text(context, size: 14, bold: true),
                        ),
                      ),
                      Text(
                        l10n.translate(
                          'debtOpsCount',
                          params: {'n': '${_ops.length}'},
                        ),
                        style: DebtStyle.text(
                          context,
                          size: 11,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_ops.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      child: Text(
                        l10n.translate('debtEmptyOps'),
                        textAlign: TextAlign.center,
                        style: DebtStyle.text(
                          context,
                          size: 12,
                          color: Colors.grey,
                        ),
                      ),
                    )
                  else
                    for (final o in _sortedOps) _opTile(context, l10n, o),
                ],
              ),
            ),
    );
  }

  Widget _navButton(IconData icon, String label, bool red, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: 116,
        child: DebtPanel(
          red: red,
          pink: !red,
          decorated: true,
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 38, color: red ? Colors.white : DebtStyle.red),
              const SizedBox(height: 8),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: DebtStyle.text(
                  context,
                  size: 14,
                  bold: true,
                  color: red ? Colors.white : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── management sheets (real data + real actions) ──────────────────

  void _openGroupsSheet(AppLocalizations l10n) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _sheetShell(
        title: l10n.translate('debtGroupsTitle'),
        action: BranchScope.readOnly
            ? const SizedBox.shrink()
            : TextButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _createGroup();
                },
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: Text(
                  l10n.translate('debtAddGroup'),
                  style: const TextStyle(fontFamily: 'Cairo'),
                ),
              ),
        child: _groups.isEmpty
            ? _sheetEmpty(l10n.translate('debtEmptyGroups'))
            : Column(
                children: [
                  for (final g in _groups)
                    Row(
                      children: [
                        Expanded(child: _groupTile(l10n, g)),
                        if (!BranchScope.readOnly)
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            onPressed: () => _renameGroup(g),
                          ),
                        if (!BranchScope.readOnly)
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              size: 18,
                              color: AppColors.danger,
                            ),
                            onPressed: () => _deleteGroup(g),
                          ),
                      ],
                    ),
                ],
              ),
      ),
    );
  }

  void _openIndividualSheet(AppLocalizations l10n) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _sheetShell(
        title: l10n.translate('debtIndividualTab'),
        child: _individualOps.isEmpty
            ? _sheetEmpty(l10n.translate('debtNoneIndividual'))
            : Column(
                children: [
                  for (final o in _individualOps) _opTile(context, l10n, o),
                ],
              ),
      ),
    );
  }

  void _openRequestsSheet(AppLocalizations l10n) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _sheetShell(
        title: l10n.translate('debtRequestsTitle'),
        child: _proofs.isEmpty
            ? _sheetEmpty(l10n.translate('debtEmptyRequests'))
            : _proofsCard(l10n),
      ),
    );
  }

  Widget _sheetShell({
    required String title,
    Widget? action,
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        bottom:
            MediaQuery.of(context).viewInsets.bottom +
            MediaQuery.of(context).padding.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: DebtStyle.text(context, size: 16, bold: true),
                    ),
                  ),
                  if (action != null) action,
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sheetEmpty(String t) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 30),
    child: Center(
      child: Text(
        t,
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 13,
          color: AppColors.textSecondary,
        ),
      ),
    ),
  );

  /// Operation row (reference 6/7): document icon — invoice number (one line,
  /// never wrapped mid-number) + date — amount (red) + friendly currency.
  Widget _opTile(
    BuildContext context,
    AppLocalizations l10n,
    Map<String, dynamic> o,
  ) {
    final balance = _asNum(o['balance']);
    final cur = (o['currency'] ?? '').toString();
    final no = shortDocumentNumber(o['invoice_number']);
    final date = (o['date'] ?? '').toString();
    return InkWell(
      onTap: () {
        final id = '${o['invoice_id'] ?? ''}';
        if (id.isEmpty) return;
        if (widget.localParty != null) {
          context.push(RouteNames.invoicesView, extra: DirectoryDebtInvoiceReference(
            party: widget.localParty!, id: id,
          ));
          return;
        }
        if (!_hasLegacyTarget) return;
        final opType = '${o['invoice_type'] ?? ''}'.toLowerCase();
        final purchase = opType.contains('purchase') || widget.isSupplier;
        context.push(
          '${RouteNames.invoicesView}'
          '?type=${purchase ? 'purchase' : 'sale'}&id=$id',
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const DebtIcon(Icons.receipt_long_outlined, size: 36),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    no.isEmpty ? '—' : no,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.start,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  Text(
                    date.split('T').first,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 11),
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  debtAmount(balance),
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 16),
                    fontWeight: FontWeight.w800,
                    color: balance > 0 ? DebtStyle.red : AppColors.success,
                  ),
                ),
                Text(
                  debtCurrencyLabel(cur),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 10.5),
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 6),
            const DebtArrow(),
          ],
        ),
      ),
    );
  }

  void _opDetails(
    BuildContext context,
    AppLocalizations l10n,
    Map<String, dynamic> o,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.of(ctx).padding.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '#${shortDocumentNumber(o['invoice_number'])}',
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            _row2(
              ctx,
              l10n.translate('saleGrandTotal'),
              '${_fmt(o['total'])} ${currencyName((o['currency'] ?? '').toString())}',
            ),
            _row2(ctx, l10n.translate('salePaid'), _fmt(o['paid'])),
            _row2(ctx, l10n.translate('purDebt'), _fmt(o['balance'])),
            _row2(ctx, l10n.translate('date'), (o['date'] ?? '').toString()),
            const SizedBox(height: 8),
            if (!BranchScope.readOnly &&
                ref.watch(employeeCanProvider('debts.add')))
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _assignOp(o);
                  },
                  icon: const Icon(Icons.drive_file_move_outlined, size: 18),
                  label: Text(
                    l10n.translate('debtAssignGroup'),
                    style: const TextStyle(fontFamily: 'Cairo'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row2(BuildContext context, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 13),
            color: AppColors.textSecondary,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 13),
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
      ],
    ),
  );
}

/// Safe numeric coercion: the debt API returns Decimals as STRINGS, so a
/// direct `as num` cast would throw. Never throws.
double _asNum(dynamic v) =>
    v is num ? v.toDouble() : (double.tryParse('$v') ?? 0);

String _fmt(dynamic v) => fmtNum(_asNum(v));
