import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fyona_flutter/core/utils/document_number.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../data/branch_epoch.dart';
import '../../data/branch_scope.dart';
import '../../../core_business/presentation/widgets/business_number_field.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/amount_input_formatter.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../data/branch_api.dart';
import '../../../inventory/presentation/widgets/business_product_image.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../../../core_business/presentation/providers/biz_payment_pref.dart';
import '../../../reports/data/business_report_rates.dart';
import '../../../../core/utils/currency_formatter.dart';
import 'branch_inventory_picker_page.dart';

typedef _TransferSelection = ({String? org, String? branch, bool all, int epoch, bool device});

_TransferSelection _selection(WidgetRef ref) => (
  org: BranchScope.organizationId,
  branch: BranchScope.branchId,
  all: BranchScope.allMode,
  epoch: ref.read(branchEpochProvider),
  device: ref.read(branchApiProvider).transfersOnDevice,
);

String _transferError(AppLocalizations l10n, Object? error) =>
    BranchTransferDeviceScope.matches(error)
    ? l10n.translate('branchTransferDeviceScope')
    : '$error';

class BranchTransfersPage extends ConsumerStatefulWidget {
  const BranchTransfersPage({super.key, this.initialId});
  final String? initialId;

  @override
  ConsumerState<BranchTransfersPage> createState() =>
      _BranchTransfersPageState();
}

class _BranchTransfersPageState extends ConsumerState<BranchTransfersPage> {
  String? _kind;
  late final _TransferSelection _retainedScope;
  Future<List<Map<String, dynamic>>>? _future;

  Future<List<Map<String, dynamic>>>? _loadTransfers() {
    final api = ref.read(branchApiProvider);
    if (_selection(ref) != _retainedScope) return null;
    return api.transfers(
      kind: _kind,
      branchId: _retainedScope.all ? null : _retainedScope.branch,
    );
  }

  @override
  void initState() {
    super.initState();
    _retainedScope = _selection(ref);
    _future = _loadTransfers();
    if (widget.initialId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openDetail(widget.initialId!);
      });
    }
  }

  void _reload() {
    setState(() {
      _future = _loadTransfers();
    });
  }

  @override
  Widget build(BuildContext context) {

    final l10n = AppLocalizations.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    ref.watch(businessLocalLedgerScopeProvider);
    ref.watch(branchEpochProvider);
    final thisScope = _selection(ref) == _retainedScope;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        actions: [],
        title: Text(
          l10n.translate('branchTransfers'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      floatingActionButton: !ref.watch(employeeCanProvider('branches.transfer')) || BranchScope.readOnly ? null : FloatingActionButton.extended(
        key: const ValueKey('transfer_create'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        onPressed: _pickType,
        icon: const Icon(Icons.swap_horiz_rounded),
        label: Text(
          l10n.translate('branchTransferFromTo'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Row(
              children: [
                _chip(l10n.translate('branchAllShort'), null),
                const SizedBox(width: 8),
                _chip(l10n.translate('branchFinancial'), 'financial'),
                const SizedBox(width: 8),
                _chip(l10n.translate('branchInventory'), 'inventory'),
              ],
            ),
          ),
          Expanded(
            child: !thisScope
                ? _error(l10n, l10n.translate('branchNoPermission'))
                : FutureBuilder<List<Map<String, dynamic>>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                   return _error(l10n, _transferError(l10n, snap.error));
                }
                final rows = snap.data ?? const [];
                if (rows.isEmpty) return _empty(l10n);
                return RefreshIndicator(
                  onRefresh: () async => _reload(),
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final t = rows[i];
                      return TweenAnimationBuilder<double>(
                        key: ValueKey('${t['id']}-$i'),
                        tween: Tween(begin: 0, end: 1),
                        duration: Duration(
                          milliseconds: 260 + (i * 35).clamp(0, 240),
                        ),
                        curve: Curves.easeOutCubic,
                        builder: (context, v, child) => Opacity(
                          opacity: v,
                          child: Transform.translate(
                            offset: Offset(0, 14 * (1 - v)),
                            child: child,
                          ),
                        ),
                        child: _card(context, t, dark),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, String? kind) {
    final selected = _kind == kind;
    return ChoiceChip(
      selected: selected,
      label: Text(
        label,
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: selected ? Colors.white : AppColors.textSecondary,
        ),
      ),
      selectedColor: AppColors.primary,
      backgroundColor: AppColors.surface,
      side: BorderSide(color: selected ? AppColors.primary : AppColors.border),
      onSelected: (_) {
        _kind = kind;
        _reload();
      },
    );
  }

  Widget _empty(AppLocalizations l10n) => ListView(
    children: [
      const SizedBox(height: 120),
      Icon(
        Icons.swap_horiz_rounded,
        size: 64,
        color: AppColors.primary.withAlpha(120),
      ),
      const SizedBox(height: 12),
      Text(
        l10n.translate('branchNoTransfers'),
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontFamily: 'Cairo',
          fontSize: 14,
          color: Colors.grey,
        ),
      ),
    ],
  );

  Widget _error(AppLocalizations l10n, String e) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            color: AppColors.danger,
            size: 42,
          ),
          const SizedBox(height: 10),
          Text(
            e,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: 'Cairo', fontSize: 12),
          ),
          const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            onPressed: _reload,
            child: Text(
              l10n.translate('branchRetry'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
        ],
      ),
    ),
  );

  String _fmt(dynamic v) {
    final d = double.tryParse('${v ?? ''}') ?? 0;
    return fmtNum(d);
  }

  Widget _card(BuildContext context, Map<String, dynamic> t, bool dark) {
    final l10n = AppLocalizations.of(context);
    final isFinancial = t['kind'] == 'financial';
    final status = '${t['status'] ?? ''}';
    final color = status == 'reversed'
        ? Colors.grey
        : status == 'partially_reversed'
        ? AppColors.warning
        : AppColors.success;
    final amount = isFinancial
        ? '${_fmt(t['amount'])} ${t['currency'] ?? ''} → ${_fmt(t['received_amount'])} ${t['to_currency'] ?? ''}'
        : l10n.translate(
            'branchProductCount',
            params: {'count': '${(t['items'] as List?)?.length ?? 0}'},
          );
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? [const Color(0xFF241417), const Color(0xFF151012)]
              : [Colors.white, const Color(0xFFF7F2F3)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(dark ? 45 : 18),
            blurRadius: 16,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _openDetail('${t['id']}'),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        (isFinancial ? AppColors.primary : AppColors.info),
                        (isFinancial
                            ? AppColors.primaryDark
                            : AppColors.chartCyan),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color:
                            (isFinancial ? AppColors.primary : AppColors.info)
                                .withAlpha(70),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(
                    isFinancial
                        ? Icons.account_balance_rounded
                        : Icons.inventory_2_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        shortDocumentNumber(t['number'], uuidPrefix: 'TRF'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      _RouteLabel(
                        from: _routeFrom(t),
                        to: _routeTo(t),
                        fontSize: 11,
                        color: AppColors.textSecondary,
                      ),
                      const SizedBox(height: 2),
                      if (isFinancial) ...[
                        Text(
                          '${l10n.translate('branchSentAmount')}: ${_fmt(t['amount'])} ${currencyLabel('${t['currency'] ?? ''}')}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                          ),
                        ),
                        Text(
                          '${l10n.translate('branchReceivedAmount')}: ${_fmt(t['received_amount'])} ${currencyLabel('${t['to_currency'] ?? ''}')}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 10,
                            color: AppColors.primary.withAlpha(190),
                          ),
                        ),
                      ] else
                        Text(
                          amount,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                          ),
                        ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: color.withAlpha(20),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        l10n.translate(
                          status == 'reversed'
                              ? 'branchStatusReversed'
                              : status == 'partially_reversed'
                              ? 'branchStatusPartiallyReversed'
                              : 'branchStatusCompleted',
                        ),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800,
                          color: color,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Icon(
                      Icons.chevron_left_rounded,
                      size: 18,
                      color: AppColors.textTertiary,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickType() async {
    final l10n = AppLocalizations.of(context);
    final kind = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.translate('branchPickType'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 14),
              if (ref.watch(employeeCanProvider('banks.transfer'))) ListTile(
                key: const ValueKey('transfer_financial'),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                tileColor: AppColors.primary.withAlpha(14),
                leading: const Icon(
                  Icons.account_balance_rounded,
                  color: AppColors.primary,
                ),
                title: Text(
                  l10n.translate('branchFinancial'),
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontWeight: FontWeight.w700,
                  ),
                ),
                onTap: () => Navigator.pop(ctx, 'financial'),
              ),
              const SizedBox(height: 8),
              if (ref.watch(employeeCanProvider('inventory.transfer'))) ListTile(
                key: const ValueKey('transfer_inventory'),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                tileColor: AppColors.info.withAlpha(14),
                leading: const Icon(
                  Icons.inventory_2_rounded,
                  color: AppColors.info,
                ),
                title: Text(
                  l10n.translate('branchInventory'),
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontWeight: FontWeight.w700,
                  ),
                ),
                onTap: () => Navigator.pop(ctx, 'inventory'),
              ),
            ],
          ),
        ),
      ),
    );
    if (kind == null || !mounted || _selection(ref) != _retainedScope ||
        BranchScope.readOnly || !ref.read(employeeCanProvider('branches.transfer')) ||
        !ref.read(employeeCanProvider(kind == 'financial' ? 'banks.transfer' : 'inventory.transfer'))) return;
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => _TransferFormPage(kind: kind)),
    );
    if (mounted && created == true) _reload();
  }

  Future<void> _openDetail(String id) async {
    if (!mounted || _selection(ref) != _retainedScope) return;
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => _TransferDetailPage(id: id)),
    );
    if (mounted && changed == true) _reload();
  }
}

// ─────────────────────────────────────────────────────────────────────
class _TransferFormPage extends ConsumerStatefulWidget {
  const _TransferFormPage({required this.kind});
  final String kind;

  @override
  ConsumerState<_TransferFormPage> createState() => _TransferFormPageState();
}

class _BranchOption {
  _BranchOption(this.id, this.name, this.orgName, {this.archived = false});
  final String id;
  final String name;
  final String orgName;
  final bool archived;
}

bool _isReversedOriginal(Map t) =>
    '${t['status'] ?? ''}' == 'reversed' &&
    '${t['reversal_of_id'] ?? ''}'.isEmpty;

String _routeFrom(Map t) => _isReversedOriginal(t)
    ? '${t['to_branch_name'] ?? ''}'
    : '${t['from_branch_name'] ?? ''}';

String _routeTo(Map t) => _isReversedOriginal(t)
    ? '${t['from_branch_name'] ?? ''}'
    : '${t['to_branch_name'] ?? ''}';

class _RouteLabel extends StatelessWidget {
  const _RouteLabel({
    required this.from,
    required this.to,
    this.fontSize = 12,
    this.fontWeight = FontWeight.w700,
    this.color,
    this.centered = false,
  });
  final String from, to;
  final double fontSize;
  final FontWeight fontWeight;
  final Color? color;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
        fontFamily: 'Cairo',
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color ?? AppColors.textPrimary);
    // Explicit LTR row: sender is always FIRST on the left and the arrow
    // points to the receiver on the right, unaffected by Arabic bidi mirroring.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        mainAxisSize: centered ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment:
            centered ? MainAxisAlignment.center : MainAxisAlignment.start,
        children: [
          Flexible(
              child: Text(from,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.left,
                  style: style)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Icon(Icons.arrow_forward_rounded,
                size: fontSize + 2,
                color: color ?? AppColors.textSecondary),
          ),
          Flexible(
              child: Text(to,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.left,
                  style: style)),
        ],
      ),
    );
  }
}

class _PickerOption {
  const _PickerOption({
    required this.value,
    required this.label,
    required this.subtitle,
    required this.icon,
    this.flag = '',
    this.disabled = false,
    this.header = false,
  });
  final String value;
  final String label;
  final String? subtitle;
  final IconData icon;
  final String flag;
  /// Shown faded and not selectable (e.g. an archived branch).
  final bool disabled;
  /// A section title row, not an option.
  final bool header;
}

class _Line {
  _Line();
  Map<String, dynamic>? source;
  Map<String, dynamic>? target;
  String? unitId;
  String? targetUnitId;
  double? conversionFactor;
  String? conversionUnitName;
  String? conversionTargetUnit;
  final TextEditingController qty = TextEditingController();
}

class _TransferFormPageState extends ConsumerState<_TransferFormPage> {

  late final _TransferSelection _retainedScope;
  bool get _mayEdit =>
      _selection(ref) == _retainedScope &&
      !BranchScope.readOnly &&
      ref.read(employeeCanProvider('branches.transfer')) &&
      ref.read(employeeCanProvider(_financial ? 'banks.transfer' : 'inventory.transfer'));

  final _notes = TextEditingController();
  Future<List<_BranchOption>>? _branchesFuture;
  List<_BranchOption> _branches = const [];
  _BranchOption? _from;
  _BranchOption? _to;
  Map<String, dynamic>? _fromOptions;
  Map<String, dynamic>? _toOptions;
  Map<String, dynamic>? _fromAccount;
  Map<String, dynamic>? _toAccount;
  String? _fromBankName;
  String? _toBankName;
  final _amount = TextEditingController();
  final _rate = TextEditingController();
  final List<_Line> _lines = [];
  bool _busy = false;
  bool _loadingProducts = false;
  String? _targetSearch;

  bool get _financial => widget.kind == 'financial';
  String? _commandId, _commandContent;
  String _command(List<Object?> content) {
    final digest = jsonEncode(content);
    if (digest != _commandContent) {
      _commandContent = digest;
      _commandId = const Uuid().v4();
    }
    return _commandId!;
  }

  @override
  void initState() {
    super.initState();
    _retainedScope = _selection(ref);
    final api = ref.read(branchApiProvider);
    if (_mayEdit) _branchesFuture = _loadBranches();
    if (!_financial) _lines.add(_Line());
  }

  @override
  void dispose() {
    _amount.dispose();
    _rate.dispose();
    _notes.dispose();
    for (final l in _lines) {
      l.qty.dispose();
    }
    super.dispose();
  }

  Future<List<_BranchOption>> _loadBranches() async {
    final companies = await ref.read(branchApiProvider).transferBranches();
    if (!mounted || !_mayEdit) {
      return const [];
    }
    final out = <_BranchOption>[];
    for (final c in companies) {
      if (BranchScope.organizationId != null && '${c['organization_id']}' != BranchScope.organizationId) continue;
      final orgName = '${c['organization_name'] ?? ''}';
      for (final b in (c['branches'] as List? ?? const [])) {
        if (b is Map) {
          out.add(_BranchOption('${b['id']}', '${b['name'] ?? ''}', orgName));
        }
      }
    }
    // Archived branches: named, listed last, never selectable.
    Map<String, String> archived = const {};
    try {
      archived = {
        for (final row in await ref.read(branchApiProvider).savedList())
          if (row['is_archived'] == true)
            '${row['id']}': '${row['name'] ?? ''}',
      };
    } catch (_) {}
    if (!mounted || !_mayEdit) return const [];
    final seen = <String>{};
    final listed = <_BranchOption>[
      for (final b in out)
        if (seen.add(b.id))
          archived.containsKey(b.id)
              ? _BranchOption(b.id, b.name.trim().isEmpty ? archived[b.id]! : b.name, b.orgName, archived: true)
              : b,
    ];
    for (final entry in archived.entries) {
      if (seen.add(entry.key) && entry.value.trim().isNotEmpty) {
        listed.add(_BranchOption(entry.key, entry.value, '', archived: true));
      }
    }
    final result = [
      for (final b in listed)
        if (!b.archived && b.name.trim().isNotEmpty) b,
      for (final b in listed)
        if (b.archived && b.name.trim().isNotEmpty) b,
    ];
    _branches = result;
    return result;
  }

  Future<void> _loadFrom(_BranchOption? b) async {
    if (_busy || !_mayEdit) return;

    _from = b;
    _fromOptions = null;
    _fromAccount = null;
    _toAccount = null;
    _fromBankName = null;
    _toBankName = null;
    for (final old in _lines) {
      old.qty.dispose();
    }
    _lines.clear();
    if (_financial) {
      _toAccount = null;
    }
    if (_to?.id == b?.id) {
      _to = null;
      _toOptions = null;
    }
    setState(() {});
    if (b == null) return;
    try {
      final data = await ref.read(branchApiProvider).transferOptions(b.id);
      if (!mounted || !_mayEdit || _from?.id != b.id) return;
      setState(() => _fromOptions = data);
    } catch (e) {
      if (mounted && _mayEdit) {
        showFyonaSnack(context, _transferError(AppLocalizations.of(context), e), success: false);
      }
    }
  }

  Future<void> _loadTo(_BranchOption? b) async {
    if (_busy || !_mayEdit) return;
    if (b != null && _from != null && b.id == _from!.id) return;
    _to = b;
    _toOptions = null;
    _toAccount = null;
    _toBankName = null;
    for (final l in _lines) {
      l.target = null;
    }
    setState(() {});
    if (b == null) return;
    try {
      final data = await ref
          .read(branchApiProvider)
          .transferOptions(b.id, search: _targetSearch);
      if (!mounted || !_mayEdit || _to?.id != b.id) return;
      setState(() => _toOptions = data);
    } catch (e) {
      if (mounted && _mayEdit) {
        showFyonaSnack(context, _transferError(AppLocalizations.of(context), e), success: false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {

    final l10n = AppLocalizations.of(context);
    ref.watch(businessLocalLedgerScopeProvider);
    ref.watch(branchEpochProvider);
    ref.watch(employeeCanProvider('branches.transfer'));
    ref.watch(employeeCanProvider(_financial ? 'banks.transfer' : 'inventory.transfer'));
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        title: Text(
          l10n.translate(_financial ? 'branchFinancial' : 'branchInventory'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        leading: BackButton(
          key: const ValueKey('transfer_form_back'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
      ),
      body: FutureBuilder<List<_BranchOption>>(
        future: _branchesFuture,
        builder: (context, snap) {
          if (!_mayEdit) {
            return Center(child: Text(l10n.translate('branchNoPermission')));
          }
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError || _branches.isEmpty) {
            return Center(
              child: Text(
                 snap.hasError ? _transferError(l10n, snap.error) : l10n.translate('branchNoPermission'),
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
            );
          }
          return AbsorbPointer(absorbing: _busy, child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 120),
            children: [
               if (_financial)
                ..._financialFields(l10n)
              else ...[
                ..._branchFields(l10n),
                const SizedBox(height: 14),
                ..._inventoryFields(l10n),
              ],
              const SizedBox(height: 20),
              TextField(key: const ValueKey('transfer_notes'), controller: _notes, enabled: !_busy,
                decoration: InputDecoration(labelText: l10n.translate('branchTransferNotes'))),
              const SizedBox(height: 14),
              FilledButton(
                key: const ValueKey('transfer_submit'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: _busy ? null : _submit,
                 child: _busy && !_retainedScope.device
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        l10n.translate('branchConfirmTransfer'),
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
              ),
            ],
          ));
        },
      ),
      ),
    );
  }

  List<String> _bankNames(List<Map> accounts) {
    final out = <String>[];
    for (final a in accounts) {
      final name = '${a['bank_name'] ?? ''}'.trim();
      if (name.isNotEmpty && !out.contains(name)) out.add(name);
    }
    return out;
  }

  List<Map> _bankAccounts(List<Map> accounts, String? bank) {
    if (bank == null) return const [];
    return accounts
        .where((a) => '${a['bank_name'] ?? ''}'.trim() == bank)
        .toList();
  }

  Widget _sectionCard(String title, IconData icon, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(12),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: AppColors.primary),
              ),
              const SizedBox(width: 9),
              Text(
                title,
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _pickerField({
    Key? key,
    required String label,
    required String? value,
    required String placeholder,
    required VoidCallback? onTap,
    IconData icon = Icons.expand_more_rounded,
  }) {
    return InkWell(
      key: key,
      borderRadius: BorderRadius.circular(13),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 9.5,
                      color: AppColors.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    (value == null || value.trim().isEmpty)
                        ? placeholder
                        : value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: (value == null || value.trim().isEmpty)
                          ? AppColors.textTertiary
                          : AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(icon, size: 18, color: AppColors.textTertiary),
          ],
        ),
      ),
    );
  }

  Future<String?> _chooseOption({
    required String title,
    required List<_PickerOption> options,
    String? selected,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        final maxH = MediaQuery.of(ctx).size.height * 0.72;
        final height = (options.length * 60.0 + 78.0).clamp(150.0, maxH);
        return SizedBox(
          height: height,
          child: Material(
            color: AppColors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.black12,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close_rounded, size: 20),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                    itemCount: options.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 2),
                    itemBuilder: (ctx, i) {
                      final o = options[i];
                      final active = o.value == selected;
                      if (o.header) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(8, 14, 8, 4),
                          child: Text(
                            o.label,
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        );
                      }
                      final tile = ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13),
                        ),
                        tileColor: active
                            ? AppColors.primary.withAlpha(12)
                            : null,
                        leading: Container(
                          width: 38,
                          height: 38,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withAlpha(14),
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: o.flag.isNotEmpty
                              ? Text(
                                  o.flag,
                                  style: const TextStyle(fontSize: 19),
                                )
                              : Icon(
                                  o.icon,
                                  size: 19,
                                  color: AppColors.primary,
                                ),
                        ),
                        title: Text(
                          o.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: (o.subtitle == null || o.subtitle!.isEmpty)
                            ? null
                            : Text(
                                o.subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 10,
                                  color: AppColors.textTertiary,
                                ),
                              ),
                        trailing: active
                            ? const Icon(
                                Icons.check_circle_rounded,
                                color: AppColors.primary,
                                size: 20,
                              )
                            : null,
                        onTap: o.disabled
                            ? null
                            : () => Navigator.pop(ctx, o.value),
                      );
                      return o.disabled
                          ? Opacity(opacity: 0.4, child: IgnorePointer(child: tile))
                          : tile;
                    },
                  ),
                ),
              ],
            ),
          ),
          ),
        );
      },
    );
  }

  Future<void> _pickBranch(bool sender, List<_BranchOption> options) async {
    final l10n = AppLocalizations.of(context);
    final list = sender
        ? options
        : options.where((b) => b.id != _from?.id).toList();
    final active = list.where((b) => !b.archived).toList();
    final archived = list.where((b) => b.archived).toList();
    final id = await _chooseOption(
      title: l10n.translate('branchSelectBranch'),
      options: [
        for (final b in active)
          _PickerOption(
            value: b.id,
            label: b.name,
            subtitle: '',
            icon: Icons.storefront_rounded,
          ),
        if (archived.isNotEmpty)
          _PickerOption(
            value: '',
            label: l10n.translate('branchArchived'),
            subtitle: null,
            icon: Icons.archive_outlined,
            header: true,
          ),
        for (final b in archived)
          _PickerOption(
            value: b.id,
            label: b.name,
            subtitle: '',
            icon: Icons.storefront_rounded,
            disabled: true,
          ),
      ],
      selected: sender ? _from?.id : _to?.id,
    );
    if (id == null) return;
    final b = options.where((e) => e.id == id).firstOrNull;
    if (sender) {
      await _loadFrom(b);
    } else {
      await _loadTo(b);
    }
  }

  List<Widget> _branchFields(AppLocalizations l10n) {
    return [
      _sectionCard(
        l10n.translate('branchSenderSection'),
        Icons.upload_rounded,
        [
          _pickerField(
            key: const ValueKey('transfer_source_branch'),
            label: l10n.translate('branchSenderBranch'),
            value: _from?.name,
            placeholder: l10n.translate('branchSelectBranch'),
            onTap: () => _pickBranch(true, _branches),
          ),
        ],
      ),
      const SizedBox(height: 12),
      _sectionCard(
        l10n.translate('branchReceiverSection'),
        Icons.download_rounded,
        [
          _pickerField(
            key: const ValueKey('transfer_target_branch'),
            label: l10n.translate('branchReceiverBranch'),
            value: _to?.name,
            placeholder: l10n.translate('branchSelectBranch'),
            onTap: () => _pickBranch(false, _branches),
          ),
        ],
      ),
    ];
  }

  List<Widget> _financialFields(AppLocalizations l10n) {
    final accounts = (_fromOptions?['accounts'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final toAccounts = (_toOptions?['accounts'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final fromBanks = _bankNames(accounts);
    final toBanks = _bankNames(toAccounts);
    final fromCurrencies = _bankAccounts(accounts, _fromBankName);
    final toCurrencies = _bankAccounts(toAccounts, _toBankName);
    final rate = parseFormattedAmount(_rate.text);
    final amount = parseFormattedAmount(_amount.text) ?? 0;
    final received = (rate != null && amount > 0) ? amount * rate : null;
    final fromCur = '${_fromAccount?['currency'] ?? ''}';
    final toCur = '${_toAccount?['currency'] ?? ''}';

    return [
      _sectionCard(l10n.translate('branchSenderSection'), Icons.upload_rounded, [
        _pickerField(
          key: const ValueKey('transfer_source_branch'),
          label: l10n.translate('branchSenderBranch'),
          value: _from?.name,
          placeholder: l10n.translate('branchSelectBranch'),
          onTap: () => _pickBranch(true, _branches),
        ),
        const SizedBox(height: 10),
        _pickerField(
          key: const ValueKey('transfer_source_bank'),
          label: l10n.translate('branchSourceBank'),
          value: _fromBankName,
          placeholder: _from == null
              ? l10n.translate('branchSelectBranch')
              : l10n.translate('branchSelectBank'),
          onTap: _from == null
              ? null
              : () async {
                  final v = await _chooseOption(
                    title: l10n.translate('branchSelectBank'),
                    options: fromBanks
                        .map(
                          (name) => _PickerOption(
                            value: name,
                            label: name,
                            subtitle:
                                '${_bankAccounts(accounts, name).length} ${l10n.translate('branchSelectCurrency')}',
                            icon: Icons.account_balance_rounded,
                          ),
                        )
                        .toList(),
                    selected: _fromBankName,
                  );
                  if (v != null) {
                    setState(() {
                      _fromBankName = v;
                      _fromAccount = null;
                    });
                  }
                },
        ),
        const SizedBox(height: 10),
        _pickerField(
          key: const ValueKey('transfer_source_currency'),
          label: l10n.translate('branchSelectCurrency'),
          value: _fromAccount == null
              ? null
              : '${currencyLabel('${_fromAccount!['currency']}')}${ref.watch(employeeCanProvider('banks.balances')) ? ' · ${_fromAccount!['balance']}' : ''}',
          placeholder: _fromBankName == null
              ? l10n.translate('branchSelectBankFirst')
              : l10n.translate('branchSelectCurrency'),
          onTap: _fromBankName == null
              ? null
              : () async {
                  final v = await _chooseOption(
                    title: l10n.translate('branchSelectCurrency'),
                    options: fromCurrencies
                        .map(
                          (a) => _PickerOption(
                            value: '${a['id']}',
                            label:
                                '${currencyLabel('${a['currency']}')}${ref.read(employeeCanProvider('banks.balances')) ? ' · ${a['balance']}' : ''}',
                            subtitle: '${a['account_name'] ?? ''}',
                            icon: Icons.payments_rounded,
                            flag: currencyFlagEmoji('${a['currency']}'),
                          ),
                        )
                        .toList(),
                    selected: _fromAccount?['id']?.toString(),
                  );
                  if (v == null) return;
                  final found = fromCurrencies
                      .where((a) => '${a['id']}' == v)
                      .firstOrNull;
                  setState(
                    () => _fromAccount = found is Map
                        ? Map<String, dynamic>.from(found)
                        : null,
                  );
                  _prefillRate();
                },
        ),
      ]),
      const SizedBox(height: 12),
      _sectionCard(l10n.translate('branchReceiverSection'), Icons.download_rounded, [
        _pickerField(
          key: const ValueKey('transfer_target_branch'),
          label: l10n.translate('branchReceiverBranch'),
          value: _to?.name,
          placeholder: l10n.translate('branchSelectBranch'),
          onTap: () => _pickBranch(false, _branches),
        ),
        const SizedBox(height: 10),
        _pickerField(
          key: const ValueKey('transfer_target_bank'),
          label: l10n.translate('branchReceiverBank'),
          value: _toBankName,
          placeholder: _to == null
              ? l10n.translate('branchSelectBranch')
              : l10n.translate('branchSelectBank'),
          onTap: _to == null
              ? null
              : () async {
                  final v = await _chooseOption(
                    title: l10n.translate('branchSelectBank'),
                    options: toBanks
                        .map(
                          (name) => _PickerOption(
                            value: name,
                            label: name,
                            subtitle:
                                '${_bankAccounts(toAccounts, name).length} ${l10n.translate('branchSelectCurrency')}',
                            icon: Icons.account_balance_rounded,
                          ),
                        )
                        .toList(),
                    selected: _toBankName,
                  );
                  if (v != null) {
                    setState(() {
                      _toBankName = v;
                      _toAccount = null;
                    });
                  }
                },
        ),
        const SizedBox(height: 10),
        _pickerField(
          key: const ValueKey('transfer_target_currency'),
          label: l10n.translate('branchSelectCurrency'),
          value: _toAccount == null
              ? null
              : '${currencyLabel('${_toAccount!['currency']}')}${ref.watch(employeeCanProvider('banks.balances')) ? ' · ${_toAccount!['balance']}' : ''}',
          placeholder: _toBankName == null
              ? l10n.translate('branchSelectBankFirst')
              : l10n.translate('branchSelectCurrency'),
          onTap: _toBankName == null
              ? null
              : () async {
                  final v = await _chooseOption(
                    title: l10n.translate('branchSelectCurrency'),
                    options: toCurrencies
                        .map(
                          (a) => _PickerOption(
                            value: '${a['id']}',
                            label:
                                '${currencyLabel('${a['currency']}')}${ref.read(employeeCanProvider('banks.balances')) ? ' · ${a['balance']}' : ''}',
                            subtitle: '${a['account_name'] ?? ''}',
                            icon: Icons.payments_rounded,
                            flag: currencyFlagEmoji('${a['currency']}'),
                          ),
                        )
                        .toList(),
                    selected: _toAccount?['id']?.toString(),
                  );
                  if (v == null) return;
                  final found = toCurrencies
                      .where((a) => '${a['id']}' == v)
                      .firstOrNull;
                  setState(
                    () => _toAccount = found is Map
                        ? Map<String, dynamic>.from(found)
                        : null,
                  );
                  _prefillRate();
                },
        ),
      ]),
      const SizedBox(height: 12),
      _sectionCard(
        l10n.translate('branchTransferDetailsSection'),
        Icons.swap_horiz_rounded,
        [
          Row(
            children: [
              Expanded(
                child: _numField(
                  l10n.translate('branchAmount'),
                  _amount,
                  onChanged: (_) {
                    setState(() {});
                    // Typing the amount fills a still-empty rate.
                    if (_rate.text.trim().isEmpty) _prefillRate();
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _numField(
                  l10n.translate('branchExchangeRate'),
                  _rate,
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
          if (_from != null && _to != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(9),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: AppColors.primary.withAlpha(35)),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _RouteLabel(
                          from: _from!.name,
                          to: _to!.name,
                          centered: true,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _summaryRow(
                    l10n.translate('branchSentAmount'),
                    amount > 0 && fromCur.isNotEmpty
                        ? '${fmtNum(amount)} ${currencyLabel(fromCur)}'
                        : '—',
                  ),
                  const SizedBox(height: 4),
                  _summaryRow(
                    l10n.translate('branchReceivedAmount'),
                    (received != null && toCur.isNotEmpty)
                        ? '${fmtNum(received)} ${currencyLabel(toCur)}'
                        : '—',
                  ),
                  const SizedBox(height: 4),
                  _summaryRow(
                    l10n.translate('branchExchangeRate'),
                    rate == null ? '—' : _plainRate(rate),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    ];
  }

  Widget _summaryRow(String label, String value) => Row(
    children: [
      Expanded(
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 10.5,
            color: AppColors.textSecondary,
          ),
        ),
      ),
      Text(
        value,
        style: const TextStyle(
          fontFamily: 'Cairo',
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    ],
  );

  String _fmtQty(double value) {
    if ((value - value.roundToDouble()).abs() < 0.00005) {
      return value.toInt().toString();
    }
    return value
        .toStringAsFixed(4)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  List<Widget> _inventoryFields(AppLocalizations l10n) {
    final products = (_fromOptions?['products'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final ready = _from != null && _to != null;
    return [
      _sectionCard(
        l10n.translate('branchInventory'),
        Icons.inventory_2_rounded,
        [
          Text(
            l10n.translate('inventoryPickerHint'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 10.5,
              height: 1.45,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.translate('inventoryWillMatch'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 10,
              height: 1.4,
              color: AppColors.textTertiary,
            ),
          ),
          const SizedBox(height: 12),
          if (!ready)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                l10n.translate('branchSelectBranch'),
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 11),
              ),
            )
          else ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const ValueKey('transfer_inventory_picker'),
                onPressed: _loadingProducts
                    ? null
                    : () => _openProductPicker(l10n, products),
                icon: _loadingProducts
                    ? const SizedBox(
                        width: 17,
                        height: 17,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.playlist_add_check_rounded, size: 18),
                label: Text(
                  _loadingProducts
                      ? l10n.translate('loading')
                      : (_lines.isEmpty
                            ? l10n.translate('inventoryChooseProducts')
                            : l10n.translate('inventoryEditSelection')),
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontWeight: FontWeight.w800,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: AppColors.primary),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            if (_lines.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                l10n.translate(
                  'inventorySelectedCount',
                  params: {'count': '${_lines.length}'},
                ),
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(height: 6),
              for (var i = 0; i < _lines.length; i++)
                _selectedInventoryRow(l10n, i),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  l10n.translate('branchNoProducts'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 10.5,
                    color: AppColors.textTertiary,
                  ),
                ),
              ),
          ],
        ],
      ),
    ];
  }

  Widget _selectedInventoryRow(AppLocalizations l10n, int index) {
    final line = _lines[index];
    final p = line.source;
    if (p == null) return const SizedBox.shrink();
    final image = '${p['image'] ?? ''}';
    final qty = double.tryParse(line.qty.text.trim()) ?? 0;
    final unit = (p['units'] as List? ?? const [])
        .whereType<Map>()
        .where((u) => '${u['id']}' == line.unitId)
        .map((u) => '${u['name']}')
        .firstOrNull;
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: image.isNotEmpty
                ? BusinessProductImage(url: image, width: 38, height: 38)
                : Container(
                    width: 38,
                    height: 38,
                    color: AppColors.primary.withAlpha(15),
                    child: const Icon(
                      Icons.inventory_2_outlined,
                      size: 18,
                      color: AppColors.primary,
                    ),
                  ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${p['name'] ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '${_fmtQty(qty)} ${unit ?? p['unit'] ?? ''}',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 10,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('transfer_remove_line_$index'),
            onPressed: _busy ? null : () => setState(() {
              _lines.removeAt(index).qty.dispose();
            }),
            icon: const Icon(
              Icons.close_rounded,
              size: 18,
              color: AppColors.danger,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openProductPicker(
    AppLocalizations l10n,
    List<Map<String, dynamic>> products,
  ) async {
    if (_from == null || _to == null) return;
    final sender = _from!;
    final receiver = _to!;
    // Always fetch the sender inventory fresh at tap time. A stale/empty
    // cached options response used to show an empty picker.
    setState(() => _loadingProducts = true);
    List<Map<String, dynamic>> fresh = products;
    List<Map<String, dynamic>> categories = const [];
    try {
      final data = await ref
          .read(branchApiProvider)
          .transferOptions(sender.id, includeZero: true);
      if (data['products'] is! List) {
        throw const FormatException('Invalid sender inventory response');
      }
      fresh = (data['products'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      categories = (data['categories'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (e) {
      if (mounted) {
        setState(() => _loadingProducts = false);
        showFyonaSnack(context, '$e', success: false);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _loadingProducts = false);
    if (_from?.id != sender.id || _to?.id != receiver.id) return;
    final freshById = {for (final p in fresh) '${p['id']}': p};
    final initial = [
      for (final line in _lines)
        if (line.source != null &&
            freshById.containsKey('${line.source!['id']}'))
          {
            'product': freshById['${line.source!['id']}'],
            'unitId': line.unitId,
            'quantity': line.qty.text,
          },
    ];
    final result = await Navigator.push<List<Map<String, dynamic>>>(
      context,
      MaterialPageRoute(
        builder: (_) => BranchInventoryPickerPage(
          products: fresh,
          sourceBranchName: sender.name,
          targetBranchName: receiver.name,
          initialLines: initial,
          categories: categories,
          l10n: l10n,
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (_from?.id != sender.id || _to?.id != receiver.id) return;
    final updated = <_Line>[];
    for (final row in result) {
      final p = row['product'];
      if (p is! Map) continue;
      final line = _Line();
      line.source = Map<String, dynamic>.from(p);
      line.unitId = row['unitId']?.toString();
      line.qty.text = '${row['quantity'] ?? ''}';
      updated.add(line);
    }
    setState(() {
      for (final old in _lines) {
        old.qty.dispose();
      }
      _lines
        ..clear()
        ..addAll(updated);
    });
  }

  Widget _numField(
    String label,
    TextEditingController c, {
    ValueChanged<String>? onChanged,
  }) {
    return BusinessNumberField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        if (identical(c, _rate))
          TextInputFormatter.withFunction((oldValue, newValue) =>
            RegExp(r'^\d{0,12}(\.\d{0,8})?$').hasMatch(newValue.text.replaceAll(',', ''))
                ? newValue : oldValue)
        else
          AmountInputFormatter(),
      ],
      style: const TextStyle(fontFamily: 'Cairo', fontSize: 12.5),
      decoration: _decoration(label),
      onChanged: onChanged,
    );
  }

  InputDecoration _decoration(String label) => InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(fontFamily: 'Cairo', fontSize: 11.5),
    filled: true,
    fillColor: AppColors.surface,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: AppColors.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: AppColors.border),
    ),
  );

  String? _baseUnitId(Map<String, dynamic>? p) {
    final units = (p?['units'] as List?) ?? const [];
    for (final u in units.whereType<Map>()) {
      if (u['is_base'] == true) return '${u['id']}';
    }
    return units.isNotEmpty ? '${(units.first as Map)['id']}' : null;
  }

  static String _plainRate(double rate) {
    final digits = rate >= 100 ? 2 : rate >= 1 ? 4 : 6;
    return rate
        .toStringAsFixed(digits)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  Future<double?> _reportRate(String from, String to) async {
    try {
      final fx = await ref.read(businessReportRatesProvider)?.read();
      final unit = BigInt.from(10).pow(8);
      final value = fx?.convert(unit, from, to);
      if (value == null || value <= BigInt.zero) return null;
      return value / unit;
    } catch (_) {
      return null;
    }
  }

  Future<void> _prefillRate() async {
    if (_fromAccount == null || _toAccount == null) return;
    final from = '${_fromAccount!['currency'] ?? 'SAR'}'.toUpperCase();
    final to = '${_toAccount!['currency'] ?? 'SAR'}'.toUpperCase();
    if (from == to) {
      if (mounted) setState(() => _rate.text = '1');
      return;
    }
    final initialRate = _rate.text;
    final sourceAccount = _fromAccount!['id'];
    final destinationAccount = _toAccount!['id'];
    try {
      final engine = ref.read(currencyEngineProvider);
      await engine.load();
      var rate = engine.getRate(from, to);
      // Same saved rates the reports use (direct, inverse or through USD).
      rate ??= await _reportRate(from, to);
      if (rate == null) {
        // Nothing saved yet: fetch now (online), then try again.
        try {
          await engine
              .refreshIfStale(maxAge: Duration.zero)
              .timeout(const Duration(seconds: 12));
        } catch (_) {}
        rate = engine.getRate(from, to) ?? await _reportRate(from, to);
      }
      final same = mounted && _rate.text == initialRate &&
          _fromAccount?['id'] == sourceAccount && _toAccount?['id'] == destinationAccount;
      final found = rate;
      if (found != null && found > 0 && same) {
        // The rate saved on this device (also offline), editable.
        setState(() => _rate.text = _plainRate(found));
      } else if (same && initialRate == '1') {
        // «1» was only right for the same currency; never send it silently.
        setState(() => _rate.text = '');
      }
    } catch (_) {}
  }

  Future<bool> _ensureUnitConversion(_Line line, {bool force = false}) async {
    if (!_mayEdit || line.source == null || line.target == null) return false;
    if (!force && line.conversionFactor != null) return true;
    final srcId = '${line.source!['id']}';
    final dstId = '${line.target!['id']}';
    final fromUnit = line.unitId;
    try {
      final info = await ref
          .read(branchApiProvider)
          .unitConversion(
            fromProductId: srcId,
            toProductId: dstId,
             fromUnitId: fromUnit,
             fromBranchId: _from?.id,
            toBranchId: _to?.id,
          );
      if (!mounted ||
          !_mayEdit ||
          line.source == null ||
          line.target == null ||
          '${line.source!['id']}' != srcId ||
          '${line.target!['id']}' != dstId ||
          line.unitId != fromUnit) {
        return false;
      }
      final required = info['required'] == true;
      if (!required && !force) {
        setState(() {
          line.conversionFactor = (info['conversion_factor'] as num?)
              ?.toDouble();
          line.conversionUnitName = '${info['source_unit_name'] ?? ''}';
          line.conversionTargetUnit = '${info['target_base_unit'] ?? ''}';
        });
        return true;
      }
      final factor = await _askConversionFactor(
        info,
        initial: (info['suggested_factor'] as num?)?.toDouble(),
      );
      if (factor == null || !mounted || !_mayEdit) return false;
      setState(() {
        line.conversionFactor = factor;
        line.conversionUnitName = '${info['source_unit_name'] ?? ''}';
        line.conversionTargetUnit = '${info['target_base_unit'] ?? ''}';
      });
      return true;
    } catch (e) {
      if (mounted && _mayEdit) {
        showFyonaSnack(context, _transferError(AppLocalizations.of(context), e), success: false);
      }
      return false;
    }
  }

  Future<double?> _askConversionFactor(
    Map<String, dynamic> info, {
    double? initial,
  }) async {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController(
      text: initial != null && initial > 0
          ? initial.toStringAsFixed(6).replaceFirst(RegExp(r'\.?0+$'), '') : '',
    );
    String? error;
    final result = await showDialog<double>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: AppColors.gradientPrimary,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.straighten_rounded,
                  color: Colors.white,
                  size: 27,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.translate('branchUnitConversionTitle'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.translate('branchUnitConversionBody'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 11,
                  height: 1.45,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(9),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.primary.withAlpha(40)),
                ),
                child: Column(
                  children: [
                    Text(
                      '1 ${info['source_unit_name'] ?? ''} =',
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    BusinessNumberField(
                      key: const ValueKey('transfer_conversion_factor'),
                      controller: ctrl,
                      autofocus: true,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      textAlign: TextAlign.center,
                      inputFormatters: [TextInputFormatter.withFunction((oldValue, newValue) =>
                        RegExp(r'^\d{0,12}(\.\d{0,6})?$').hasMatch(newValue.text)
                            ? newValue : oldValue)],
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                      decoration:
                          _decoration(
                            l10n.translate('branchUnitConversionFactor'),
                          ).copyWith(
                            errorText: error,
                            helperText: l10n.translate(
                              'branchUnitConversionHint',
                            ),
                          ),
                      onChanged: (_) => setLocal(() => error = null),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${info['target_base_unit'] ?? ''}',
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
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                l10n.translate('branchCancel'),
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
            ),
            FilledButton(
              key: const ValueKey('transfer_conversion_save'),
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
              onPressed: () {
                final v = double.tryParse(ctrl.text.trim());
                if (v == null || !v.isFinite || v <= 0) {
                  setLocal(
                    () =>
                        error = l10n.translate('branchUnitConversionRequired'),
                  );
                  return;
                }
                Navigator.pop(ctx, v);
              },
              child: Text(
                l10n.translate('branchUnitConversionSave'),
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    return result;
  }

  Future<bool> _prepareInventoryLines(AppLocalizations l10n) async {
    final missing = <String>[];
    for (final line in _lines) {
      if (line.source == null) continue;
      if (!mounted || !_mayEdit) return false;
      final match = await ref
          .read(branchApiProvider)
          .productMatch(
            fromProductId: '${line.source!['id']}',
            fromBranchId: _from!.id,
            toBranchId: _to!.id,
          );
      if (!mounted || !_mayEdit) return false;
      if (match['exists'] == true && match['product'] is Map) {
        final product = Map<String, dynamic>.from(match['product'] as Map);
        line.target = product;
        line.targetUnitId = _baseUnitId(product);
        line.conversionFactor = null;
        line.conversionUnitName = null;
        line.conversionTargetUnit = null;
        final ok = await _ensureUnitConversion(line);
        if (!ok) return false;
      } else {
        line.target = null;
        line.targetUnitId = null;
        line.conversionFactor = null;
        line.conversionUnitName = null;
        line.conversionTargetUnit = null;
        final name = '${line.source!['name'] ?? ''}';
        if (!missing.contains(name)) missing.add(name);
      }
    }
    if (missing.isEmpty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          l10n.translate('inventoryWillCreateTitle'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: SingleChildScrollView(
          child: Text(
            l10n.translate(
              'inventoryWillCreateBody',
              params: {'products': missing.map((e) => '• $e').join('\n')},
            ),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 11.5,
              height: 1.6,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              l10n.translate('branchCancel'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.translate('inventoryCreateConfirm'),
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
    return ok == true;
  }

  String _errorMessage(Object error, AppLocalizations l10n) {
    if (BranchTransferDeviceScope.matches(error)) return l10n.translate('branchTransferDeviceScope');
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map) {
        final detail = data['detail'] ?? data['message'] ?? data['error'];
        if (detail is String && detail.trim().isNotEmpty) {
          final lower = detail.toLowerCase();
          if (lower.contains('رصيد') || lower.contains('balance')) {
            return l10n.translate('branchInsufficientBankBalance');
          }
          return detail;
        }
        if (detail is Map) {
          final message = detail['message'];
          if (message is String && message.trim().isNotEmpty) return message;
        }
      }
    }
    final raw = '$error'.replaceFirst('Exception: ', '');
    return raw;
  }

  /// The overdraft question used by payments: true to continue (once or
  /// always — «always» is saved as the branch's preference).
  Future<bool> _askOverdraft(AppLocalizations l10n) async {
    if (!mounted) return false;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          l10n.translate('payNegTitle'),
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 16, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'always'),
            child: Text(l10n.translate('payNegAlways'),
                style: const TextStyle(fontFamily: 'Cairo')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'once'),
            child: Text(l10n.translate('payNegOnce'),
                style: const TextStyle(fontFamily: 'Cairo')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text(l10n.translate('payNegCancel'),
                style: const TextStyle(fontFamily: 'Cairo')),
          ),
        ],
      ),
    );
    if (choice == 'always') {
      try {
        await ref.read(bizPaymentPrefProvider.notifier).setAllowNegative(true);
      } catch (_) {}
    }
    return choice == 'always' || choice == 'once';
  }

  Future<void> _submit() async {
    if (_busy || !_mayEdit) return;
    final l10n = AppLocalizations.of(context);
    if (_from == null || _to == null) {
      showFyonaSnack(
        context,
        l10n.translate('branchSelectBranch'),
        success: false,
      );
      return;
    }
    if (_from!.id == _to!.id) {
      showFyonaSnack(
        context,
        l10n.translate('branchNoPermission'),
        success: false,
      );
      return;
    }
    setState(() => _busy = true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          l10n.translate('branchConfirmTransfer'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          _RouteLabel(
            from: _from!.name,
            to: _to!.name,
            centered: true,
            fontSize: 12,
            color: AppColors.textPrimary,
          ),
          const SizedBox(height: 4),
          Text(l10n.translate(_financial ? 'branchFinancial' : 'branchInventory'),
              style: const TextStyle(
                  fontFamily: 'Cairo', fontSize: 12, color: Colors.grey)),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              l10n.translate('branchCancel'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.translate('branchConfirmTransfer'),
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmed != true || !_mayEdit) {
      setState(() => _busy = false);
      return;
    }
    setState(() => _busy = true);
    try {
      if (_financial) {
        final amount = parseFormattedAmount(_amount.text) ?? 0;
        final rate = parseFormattedAmount(_rate.text);
        if (_fromAccount == null || _toAccount == null || amount <= 0) {
          throw Exception(l10n.translate('branchSelectAccount'));
        }
        final available =
            double.tryParse('${_fromAccount!['balance'] ?? ''}');
        // Beyond the balance: the app's own overdraft question (once /
        // always / don't), asked only when it is actually needed.
        var allowNegative = ref.read(bizPaymentPrefProvider).allowNegative;
        if (!allowNegative &&
            available != null &&
            amount > available + 0.0001) {
          if (!await _askOverdraft(l10n)) return;
          allowNegative = true;
        }
        Future<void> send(bool negative) => ref
            .read(branchApiProvider)
            .financialTransfer(
              fromBranchId: _from!.id,
              toBranchId: _to!.id,
              fromAccountId: '${_fromAccount!['id']}',
              toAccountId: '${_toAccount!['id']}',
              amount: amount,
              exchangeRate: rate,
              allowNegative: negative,
              notes: _notes.text,
              commandId: _command([
                _from!.id, _to!.id, _fromAccount!['id'], _toAccount!['id'],
                amount, rate, negative, _notes.text,
              ]),
            );
        try {
          await send(allowNegative);
        } catch (e) {
          // The balance on this screen may be older than the ledger's.
          if (allowNegative ||
              _errorMessage(e, l10n) != 'الرصيد في الحساب ما يكفي' ||
              !mounted ||
              !await _askOverdraft(l10n)) {
            rethrow;
          }
          await send(true);
        }
      } else {
        if (_from == null || _to == null) {
          throw Exception(l10n.translate('branchSelectBranch'));
        }
        if (_lines.isEmpty) {
          throw Exception(l10n.translate('branchNoProducts'));
        }
        final prepared = await _prepareInventoryLines(l10n);
        if (!prepared) return;
        final items = <Map<String, dynamic>>[];
        for (final line in _lines) {
          if (line.source == null) continue;
          final q = double.tryParse(line.qty.text.trim()) ?? 0;
          if (q <= 0) continue;
          if (line.target != null) {
            final ok = await _ensureUnitConversion(line);
            if (!ok) {
              throw Exception(l10n.translate('branchUnitConversionRequired'));
            }
          }
          items.add({
            'from_product_id': '${line.source!['id']}',
            'quantity': _retainedScope.device ? line.qty.text.trim() : q,
            if (line.unitId != null) 'from_unit_id': line.unitId,
            if (line.target != null) 'to_product_id': '${line.target!['id']}',
            if (line.targetUnitId != null) 'to_unit_id': line.targetUnitId,
            if (line.conversionFactor != null)
              'conversion_factor': line.conversionFactor,
          });
        }
        if (items.isEmpty) {
          throw Exception(l10n.translate('branchNoProducts'));
        }
        if (!mounted || !_mayEdit) return;
        await ref
            .read(branchApiProvider)
            .inventoryTransfer(
              fromBranchId: _from!.id,
              toBranchId: _to!.id,
              items: items,
              notes: _notes.text,
              commandId: _command([_from!.id, _to!.id, items, _notes.text]),
            );
      }
      if (!mounted || !_mayEdit) return;
      showFyonaSnack(
        context,
        l10n.translate('branchTransferSuccess'),
        success: true,
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      showFyonaSnack(context, _errorMessage(e, l10n), success: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
class _TransferDetailPage extends ConsumerStatefulWidget {
  const _TransferDetailPage({required this.id});
  final String id;

  @override
  ConsumerState<_TransferDetailPage> createState() =>
      _TransferDetailPageState();
}

class _TransferDetailPageState extends ConsumerState<_TransferDetailPage> {

  late final _TransferSelection _retainedScope;
  bool get _sameSelection => _selection(ref) == _retainedScope;
  bool _reversing = false;
  late final _reversalCommand = const Uuid().v4();
  Future<Map<String, dynamic>>? _future;

  @override
  void initState() {
    super.initState();
    _retainedScope = _selection(ref);
    final api = ref.read(branchApiProvider);
    if (_sameSelection) _future = api.transfer(widget.id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    ref.watch(businessLocalLedgerScopeProvider);
    ref.watch(branchEpochProvider);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        title: Text(
          l10n.translate('branchTransferDetails'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      body: !_sameSelection
          ? Center(child: Text(l10n.translate('branchNoPermission')))
          : FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Text(
                 _transferError(l10n, snap.error),
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
            );
          }
          final t = snap.data ?? {};
          final items = (t['items'] as List? ?? const []).whereType<Map>();
          final canReverse = t['can_reverse'] == true;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 100),
            children: [
              _hero(t),
              const SizedBox(height: 14),
              _row(
                l10n.translate('branchOperationNumber'),
                shortDocumentNumber(t['number'], uuidPrefix: 'TRF'),
              ),
              _row(
                l10n.translate('branchFrom'),
                _routeFrom(t),
              ),
              _row(l10n.translate('branchTo'), _routeTo(t)),
              _row(
                l10n.translate('branchBy'),
                _actorText(l10n, t),
              ),
              if (t['kind'] == 'financial') ...[
                _row(
                  l10n.translate('branchAmount'),
                  '${_fmt(t['amount'])} ${currencyLabel('${t['currency'] ?? ''}')}',
                ),
                // Only a transfer between two different currencies has a rate.
                if (t['exchange_rate'] != null &&
                    '${t['exchange_rate']}'.trim().isNotEmpty &&
                    '${t['exchange_rate']}' != 'null' &&
                    '${t['currency'] ?? ''}' != '${t['to_currency'] ?? ''}')
                  _row(
                    l10n.translate('branchExchangeRate'),
                    '${t['exchange_rate']}',
                  ),
                _row(
                  l10n.translate('branchExpectedAmount'),
                  '${_fmt(t['received_amount'])} ${currencyLabel('${t['to_currency'] ?? ''}')}',
                ),
              ] else ...[
                _row(
                  l10n.translate('branchItemCount'),
                  l10n.translate(
                    'branchProductCount',
                    params: {'count': '${items.length}'},
                  ),
                ),
                _row(
                  l10n.translate('branchTotalCost'),
                  _inventoryTotalText(t, items),
                ),
              ],
              if ((t['notes'] ?? '').toString().isNotEmpty)
                _row(l10n.translate('branchTransferNotes'), '${t['notes']}'),
              const SizedBox(height: 12),
              if (items.isNotEmpty) ...[
                Text(
                  l10n.translate('branchInventory'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                for (final it in items) _inventoryItemCard(l10n, it),
              ],
              const SizedBox(height: 16),
              if (canReverse && !BranchScope.readOnly && ref.watch(employeeCanProvider('branches.transfer')) && ref.watch(employeeCanProvider(t['kind'] == 'financial' ? 'banks.transfer' : 'inventory.transfer')))
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.danger,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  key: const ValueKey('transfer_reverse'),
                   onPressed: _reversing ? null : () => _reverse('${t['kind']}'),
                  icon: const Icon(Icons.undo_rounded, color: Colors.white),
                  label: Text(
                    l10n.translate('branchReverseAction'),
                    style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _inventoryItemCard(AppLocalizations l10n, Map it) {
    final image = '${it['from_product_image'] ?? ''}';
    final name = '${it['from_product_name'] ?? ''}';
    final target = '${it['to_product_name'] ?? ''}';
    final factor = (it['conversion_factor'] as num?)?.toDouble() ?? 1;
    final unitName = '${it['unit_name'] ?? ''}';
    final qty = it['from_quantity'];
    final purchase = (it['unit_cost'] as num?)?.toDouble() ?? 0;
    final sale = (it['sale_price'] as num?)?.toDouble() ?? 0;
    final total = (it['total_cost'] as num?)?.toDouble() ?? 0;
    final currency = '${it['currency'] ?? ''}';
    final reversed = (it['reversed_quantity'] as num?)?.toDouble() ?? 0;
    final purchaseUnit = purchase * (factor <= 0 ? 1 : factor);
    final saleUnit = sale * (factor <= 0 ? 1 : factor);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: image.isNotEmpty
                    ? BusinessProductImage(url: image, width: 46, height: 46)
                    : Container(
                        width: 46,
                        height: 46,
                        color: AppColors.primary.withAlpha(15),
                        child: const Icon(
                          Icons.inventory_2_outlined,
                          size: 22,
                          color: AppColors.primary,
                        ),
                      ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (target.isNotEmpty && target != name)
                      Text(
                        '${l10n.translate('branchMatchedProduct')}: $target',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 9.5,
                          color: AppColors.textTertiary,
                        ),
                      ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(12),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  '${_qtyText(qty)} $unitName',
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Container(
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                _itemTableRow(
                  l10n.translate('branchPurchasePrice'),
                  '${_fmt(purchaseUnit)} ${currencyLabel(currency)}',
                ),
                Divider(height: 1, color: AppColors.border),
                _itemTableRow(
                  l10n.translate('branchSalePrice'),
                  '${_fmt(saleUnit)} ${currencyLabel(currency)}',
                ),
                Divider(height: 1, color: AppColors.border),
                _itemTableRow(
                  l10n.translate('branchTotal'),
                  '${_fmt(total)} ${currencyLabel(currency)}',
                  strong: true,
                ),
                if (reversed > 0) ...[
                  Divider(height: 1, color: AppColors.border),
                  _itemTableRow(
                    l10n.translate('branchStatusPartiallyReversed'),
                    _qtyText(reversed),
                    strong: false,
                    warning: true,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _itemTableRow(
    String label,
    String value, {
    bool strong = false,
    bool warning = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 10,
                color: warning ? AppColors.warning : AppColors.textSecondary,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: strong ? 11.5 : 10.5,
              fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
              color: warning ? AppColors.warning : AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(dynamic v) {
    final d = double.tryParse('${v ?? ''}') ?? 0;
    return fmtNum(d);
  }

  String _qtyText(dynamic v) {
    final d = double.tryParse('${v ?? ''}') ?? 0;
    if ((d - d.roundToDouble()).abs() < 0.00005) {
      return d.toInt().toString();
    }
    return d
        .toStringAsFixed(4)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  String _inventoryTotalText(Map<String, dynamic> t, Iterable<Map> items) {
    var currency = '${t['currency'] ?? ''}'.trim();
    if (currency.isEmpty || currency == 'null') {
      currency = '${items.isNotEmpty ? (items.first['currency'] ?? '') : ''}';
    }
    if (currency == 'MIXED') {
      return AppLocalizations.of(context).translate('branchMixedCurrencies');
    }
    final total = _fmt(t['total_cost']);
    return currency.isEmpty ? total : '$total ${currencyLabel(currency)}';
  }

  /// «الاسم · الدور»; an older transfer that did not record its author says
  /// only the role it can prove, never a stray dot.
  String _actorText(AppLocalizations l10n, Map t) {
    final name = '${t['actor_name'] ?? ''}'.trim();
    final role = '${t['actor_role'] ?? ''}'.trim();
    final hasName = name.isNotEmpty && name != 'null';
    final hasRole = role.isNotEmpty && role != 'null';
    if (!hasName && !hasRole) return '—';
    if (!hasName) return _roleLabel(l10n, role);
    if (!hasRole) return name;
    return '$name · ${_roleLabel(l10n, role)}';
  }

  String _roleLabel(AppLocalizations l10n, String role) {
    switch (role.toLowerCase()) {
      case 'owner':
        return l10n.translate('branchRoleOwner');
      case 'admin':
        return l10n.translate('branchRoleAdmin');
      case 'manager':
        return l10n.translate('branchRoleManager');
      case 'employee':
        return l10n.translate('branchRoleEmployee');
      default:
        return role.isEmpty ? '—' : role;
    }
  }

  String _statusLabel(AppLocalizations l10n, String status) {
    if (status == 'reversed') return l10n.translate('branchStatusReversed');
    if (status == 'partially_reversed') {
      return l10n.translate('branchStatusPartiallyReversed');
    }
    return l10n.translate('branchStatusCompleted');
  }

  Widget _hero(Map<String, dynamic> t) {
    final l10n = AppLocalizations.of(context);
    final reversed = t['status'] == 'reversed';
    final isFinancial = t['kind'] == 'financial';
    String invCurrency = '${t['currency'] ?? ''}'.trim();
    if (invCurrency.isEmpty || invCurrency == 'null') {
      final list = (t['items'] as List? ?? const []).whereType<Map>();
      invCurrency = list.isEmpty ? '' : '${list.first['currency'] ?? ''}';
    }
    final amountText = isFinancial
        ? '${_fmt(t['amount'])} ${currencyLabel('${t['currency'] ?? ''}')}'
        : (invCurrency == 'MIXED'
              ? l10n.translate('branchMixedCurrencies')
              : '${_fmt(t['total_cost'])} $invCurrency');
    final receivedText = isFinancial
        ? '${_fmt(t['received_amount'])} ${currencyLabel('${t['to_currency'] ?? ''}')}'
        : null;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: reversed
              ? [Colors.grey.shade700, Colors.grey.shade900]
              : [AppColors.primary, AppColors.primaryDark],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withAlpha(70),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                isFinancial
                    ? Icons.account_balance_rounded
                    : Icons.inventory_2_rounded,
                color: Colors.white,
                size: 30,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      shortDocumentNumber(t['number'], uuidPrefix: 'TRF'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _statusLabel(l10n, '${t['status'] ?? ''}'),
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 10.5,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(22),
              borderRadius: BorderRadius.circular(12),
            ),
            child: _RouteLabel(
              from: _routeFrom(t),
              to: _routeTo(t),
              centered: true,
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  l10n.translate(
                    isFinancial ? 'branchSentAmount' : 'branchTotalCost',
                  ),
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 10,
                    color: Colors.white70,
                  ),
                ),
              ),
              Text(
                amountText,
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          if (receivedText != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.translate('branchReceivedAmount'),
                    style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 10,
                      color: Colors.white70,
                    ),
                  ),
                ),
                Text(
                  receivedText,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 11.5,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        ),
      ],
    ),
  );

  Future<void> _reverse(String kind) async {
    bool allowed() => _sameSelection &&
        !BranchScope.readOnly &&
        ref.read(employeeCanProvider('branches.transfer')) &&
        ref.read(employeeCanProvider(kind == 'financial' ? 'banks.transfer' : 'inventory.transfer'));
    if (_reversing || !allowed()) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _reversing = true);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          l10n.translate('branchReverseConfirm'),
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 15),
        ),
        content: Text(
          l10n.translate('branchReverseBody'),
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              l10n.translate('branchCancel'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.translate('branchReverse'),
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (ok != true || !allowed()) {
      setState(() => _reversing = false);
      return;
    }
    setState(() => _reversing = true);
    try {
      await ref.read(branchApiProvider).reverseTransfer(widget.id, commandId: _reversalCommand);
      if (!mounted || !allowed()) return;
      showFyonaSnack(context, l10n.translate('branchReversed'), success: true);
      setState(() {
        _future = ref.read(branchApiProvider).transfer(widget.id);
      });
    } catch (e) {
      if (mounted && allowed()) {
        showFyonaSnack(context, _transferError(l10n, e), success: false);
      }
    } finally {
      if (mounted) setState(() => _reversing = false);
    }
  }
}
