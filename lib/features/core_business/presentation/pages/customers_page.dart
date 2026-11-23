import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/network/api_exceptions.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../purchases/presentation/providers/purchase_providers.dart';
import '../../../personal/data/merchant_api.dart';
import '../widgets/party_tracking.dart';
import '../widgets/debt_widgets.dart';
import 'business_debts_page.dart';
import '../widgets/add_party_debt_sheet.dart';
import '../../../../shared/widgets/fyona_text_field.dart';
import '../../data/local_directory/directory_pilot.dart';
import '../../data/local_directory/directory_party.dart';
import '../../data/local_directory/directory_scope.dart';
import '../widgets/local_directory_actions.dart';

/// Customers list: search + add + cards (name, phone, outstanding balance).
class CustomersPage extends ConsumerStatefulWidget {
  /// When opened from the DEBTS section the list shows names only (per the
  /// reference) and gains the «إضافة دين جديد» action.
  final bool debtsContext;
  const CustomersPage({super.key, this.debtsContext = false});
  @override
  ConsumerState<CustomersPage> createState() => _CustomersPageState();
}

class _CustomersPageState extends ConsumerState<CustomersPage> {
  static const _kind = DirectoryPartyKind.customer;
  String _q = '';
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _selectedId;
  DirectoryAccess? _rowsScope;
  bool _adding = false;
  int _loadRevision = 0;

  Provider<DirectoryAccess?> get _scopeProvider => widget.debtsContext
      ? businessLocalLedgerScopeProvider
      : directoryPilotAccessProvider;

  DirectoryAccess? get _pilot => ref.read(_scopeProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final revision = ++_loadRevision;
    final pilot = _pilot;
    final query = _q;

    setState(() {
      if (!sameDirectoryScope(_rowsScope, pilot)) _items = [];
      _rowsScope = pilot;
      _loading = pilot == null;
    });
    try {
      final rows = pilot == null
          ? [
              for (final s in (await ref.read(purchaseApiProvider).searchCustomers(query)).whereType<Map>())
                Map<String, dynamic>.from(s),
            ]
          : (await ref.read(directoryPilotStoreProvider).search(pilot, _kind, query))
              .map(directoryListRow).toList();
      if (mounted && revision == _loadRevision && sameDirectoryScope(pilot, _pilot)) {
        setState(() => _items = rows);
      }
    } catch (_) {
      if (mounted && revision == _loadRevision && sameDirectoryScope(pilot, _pilot)) {
        setState(() => _items = []);
      }
    } finally {
      if (mounted && revision == _loadRevision && _loading) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _add() async {
    if (_adding) return;
    _adding = true;
    final pilot = _pilot;
    try {
      await _addOnce(pilot);
    } finally {
      _adding = false;
    }
  }

  Future<void> _addDebtParty() async {
    if (_adding || BranchScope.readOnly) return;
    _adding = true;
    try {
      final scope = _pilot;
      final names = _items.map((e) => '${e['name'] ?? ''}').toList();
      final added = scope != null
          ? await openLocalPartyWithDebtSheet(context, ref, scope, _kind, names)
          : await showAddPartyDebtSheet(
              context, ref, isSupplier: false, existingNames: names);
      if (added && mounted) await _load();
    } finally {
      _adding = false;
    }
  }

  Future<void> _addOnce(DirectoryAccess? pilot) async {
    final l10n = AppLocalizations.of(context);
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    String? dupErr;
    var confirmed = false;
    final route = DialogRoute<bool>(
      context: context,
      themes: InheritedTheme.capture(
        from: context,
        to: Navigator.of(context, rootNavigator: true).context,
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(
            l10n.translate('purAddCustomer'),
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
              if (dupErr != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        size: 16,
                        color: AppColors.danger,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          dupErr!,
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 11,
                            height: 1.35,
                            color: AppColors.danger,
                          ),
                        ),
                      ),
                    ],
                  ),
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
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                final dup = _items.any(
                  (e) =>
                      '${e['name'] ?? ''}'.trim().toLowerCase() ==
                      name.toLowerCase(),
                );
                if (dup) {
                  setSt(() => dupErr = l10n.translate('debtDuplicateCustomer'));
                  return;
                }
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
      ),
    );
    final saved = await Navigator.of(context, rootNavigator: true).push(route);
    if (mounted && saved == true && nameCtrl.text.trim().isNotEmpty) {
      try {
        if (!sameDirectoryScope(pilot, _pilot) ||
            BranchScope.readOnly ||
            !ref.read(employeeCanProvider('customers.add'))) {
          throw const DirectoryAccessDenied();
        }
        final name = nameCtrl.text.trim();
        final phone = phoneCtrl.text.trim();
        if (pilot != null) {
          await ref.read(directoryPilotStoreProvider).add(
            pilot, _kind, name: name, phone: phone,
          );
        } else {
          await ref.read(purchaseApiProvider).createCustomer(
            name: name, phone: phone.isEmpty ? null : phone,
          );
        }
        if (mounted) await _load();
      } catch (e) {
        if (mounted) {
          final msg = pilot != null || e is DirectoryAccessDenied
              ? directorySaveError(e, _kind, l10n)
              : e is ApiException ? e.message : e.toString();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: AppColors.danger,
              content: Text(
                msg,
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  color: Colors.white,
                ),
              ),
            ),
          );
        }
      }
    }
    await route.completed;
    nameCtrl.dispose();
    phoneCtrl.dispose();
  }

  Future<void> _deleteSelected() async {
    final id = _selectedId;
    if (id == null || !sameDirectoryScope(_rowsScope, _pilot)) return;
    final scope = _pilot;
    if (scope != null && BranchScope.readOnly) return;
    final l10n = AppLocalizations.of(context);
    final kindWord = l10n.translate(
      'customer' == 'customer' ? 'debtKindCustomer' : 'debtKindSupplier',
    );
    bool linked = false;
    if (scope == null) {
      try {
        final st = await ref
            .read(merchantApiProvider)
            .linkStatus(partyKind: 'customer', partyId: id);
        linked = st['linked'] == true || st['status'] == 'pending';
      } catch (_) {}
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.danger.withAlpha(15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                linked ? Icons.link_off_rounded : Icons.delete_forever,
                color: AppColors.danger,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10n.translate('debtPartyDelete'),
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          l10n.translate(
            linked
                ? 'debtPartyDeleteLinkedBody'
                : 'debtPartyDeleteUnlinkedBody',
            params: {'kind': kindWord},
          ),
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 12.5),
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
              l10n.translate('debtPartyDeleteConfirm'),
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      if (!sameDirectoryScope(scope, _pilot)) throw const DirectoryAccessDenied();
      if (scope != null) {
        await deleteLocalDebtParty(ref, scope, _kind, id);
      } else {
        await ref.read(merchantApiProvider).deleteParty(partyKind: 'customer', partyId: id);
      }
      if (!mounted) return;
      setState(() => _selectedId = null);
      await _load();
      if (mounted) {
        showFyonaSnack(
          context,
          l10n.translate('debtPartyDeleteDone'),
          success: true,
        );
      }
    } catch (_) {
      if (mounted) {
        showFyonaSnack(
          context,
          l10n.translate('debtPartyDeleteFailed'),
          success: false,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {

    final l10n = AppLocalizations.of(context);
    final debts = widget.debtsContext;
    final pilot = ref.watch(_scopeProvider);
    if (pilot != null) {
      ref.listen(directoryPartyRevisionProvider(_kind), (_, _) {
        if (mounted) _load();
      });
    }
    ref.listen(_scopeProvider, (before, after) {
      if (!sameDirectoryScope(before, after)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _selectedId = null;
            _load();
          }
        });
      }
    });
    final items = sameDirectoryScope(_rowsScope, pilot)
        ? _items : const <Map<String, dynamic>>[];
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          l10n.translate('bizCustomers'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontWeight: FontWeight.w700,
          ),
        ),
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        // Reference 2: the list carries ONE clear action («إضافة دين جديد»
        // at the bottom), so no duplicate add button in the app bar.
        actions: debts
            ? [
                if (ref.watch(employeeCanProvider('customers.delete'))) IconButton(
                  tooltip: l10n.translate('debtPartyDeleteTooltip'),
                  icon: const Icon(Icons.delete_outline_rounded),
                  color: _selectedId == null
                      ? AppColors.textDisabled
                      : AppColors.danger,
                  onPressed:
                      _selectedId == null ||
                          !ref.watch(employeeCanProvider('customers.delete'))
                      ? null
                      : _deleteSelected,
                ),
                const DebtBellButton(),
              ]
            : [
                if (!BranchScope.readOnly)
                  if (ref.watch(employeeCanProvider('customers.add')))
                    IconButton(onPressed: _add, icon: const Icon(Icons.add)),
              ],
      ),
      body: Column(
        children: [
          if (debts)
            DebtPanel(
              red: true,
              decorated: true,
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const DebtIcon(Icons.groups_rounded, size: 52, inverse: true),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.translate('bizDebtCustomers'),
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          l10n.translate('bizDebtCustomersSub'),
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 12,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FyonaTextField(
              decoration: InputDecoration(
                hintText: l10n.translate('saleSearchCustomerHint'),
                prefixIcon: const Icon(Icons.search, size: 20),
              ),
              style: const TextStyle(fontFamily: 'Cairo'),
              onChanged: (v) {
                _q = v;
                _load();
              },
            ),
          ),
          Expanded(
            child: _loading && pilot == null
                ? const Center(child: CircularProgressIndicator())
                : items.isEmpty
                ? Center(
                    child: Text(
                      l10n.translate('saleNoCustomers'),
                      style: const TextStyle(fontFamily: 'Cairo'),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: items.length,
                    separatorBuilder: (context, index) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _CustomerCard(
                      customer: items[i],
                      directoryAccess: pilot,
                      cardDebtsContext: widget.debtsContext,
                      selecting: _selectedId != null,
                      selected: _selectedId == '${items[i]['id']}',
                      onToggle: () => setState(
                          () => _selectedId = _selectedId == '${items[i]['id']}'
                            ? null
                              : '${items[i]['id']}',
                      ),
                    ),
                  ),
          ),
        ],
      ),
      bottomNavigationBar:
          debts &&
              !BranchScope.readOnly &&
              ref.watch(employeeCanProvider('debts.add'))
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
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
                     onPressed: _addDebtParty,
                    icon: const Icon(Icons.add, size: 20),
                    label: Text(
                      l10n.translate('bizAddCustomerNew'),
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
              ),
            )
          : null,
    );
  }
}

class _CustomerCard extends ConsumerWidget {
  final Map<String, dynamic> customer;
  final DirectoryAccess? directoryAccess;
  final bool cardDebtsContext;
  final bool selecting;
  final bool selected;
  final VoidCallback onToggle;
  const _CustomerCard({
    required this.customer,
    this.directoryAccess,
    this.cardDebtsContext = false,
    this.selecting = false,
    this.selected = false,
    this.onToggle = _noop,
  });
  static void _noop() {}

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = customer['id']?.toString() ?? '';
    final name = (customer['name'] ?? '').toString();
    final detailRoute =
        '/customers/detail?id=$id&name=${Uri.encodeComponent(name)}';
    void open() {
      final scope = directoryAccess;
      if (scope == null) {
        context.push(detailRoute);
      } else {
        openDirectoryParty(context, ref, DirectoryPartyReference(
          scope: scope, kind: DirectoryPartyKind.customer, id: id,
        ));
      }
    }
    // Reference 2 (Post-entry): compact row — letter avatar + person icon +
    // name + chevron. No phone, no balance in the list.
    if (cardDebtsContext) {
      return InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: !ref.watch(employeeCanProvider('customers.details')) ? null : () {
          if (selecting) {
            onToggle();
          } else {
            open();
          }
        },
        onLongPress: onToggle,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? DebtStyle.red : DebtStyle.border(context),
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.person_outline, size: 22, color: DebtStyle.red),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  name.isEmpty ? '—' : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 15),
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (selecting)
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? DebtStyle.red : DebtStyle.border(context),
                )
              else
                const DebtArrow(),
            ],
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: ref.watch(employeeCanProvider('customers.details')) ? open : null,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(18),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.groups, color: AppColors.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 14),
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  if ((customer['phone']?.toString() ?? '').isNotEmpty)
                    Text(
                      customer['phone'].toString(),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 12),
                        color: AppColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            if (!BranchScope.readOnly && ref.watch(employeeCanProvider('customers.edit')))
              IconButton(
                tooltip: AppLocalizations.of(
                  context,
                ).translate('merchantTrack'),
                icon: const Icon(Icons.person_add_alt_1_rounded, size: 20),
                color: AppColors.primary,
                onPressed: () => showPartyTrackingDialog(
                  context, ref, partyKind: 'customer', partyId: id,
                  localParty: directoryAccess == null ? null : DirectoryPartyReference(
                    scope: directoryAccess!, kind: DirectoryPartyKind.customer, id: id,
                  ),
                ),
              ),
            if (ref.watch(employeeCanProvider('customers.details'))) const DebtArrow(),
          ],
        ),
      ),
    );
  }
}
