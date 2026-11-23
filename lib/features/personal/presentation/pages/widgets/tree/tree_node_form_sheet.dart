import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../../../core/services/currency/enabled_currencies_service.dart';
import '../../../../../../shared/providers/current_user_provider.dart';
import '../../../../../../core/localization/app_localizations.dart';
import '../../../../../../core/theme/app_colors.dart';
import '../../../../../../core/utils/currency_formatter.dart';
import '../../../../../../features/personal/data/models/financial_tree_models.dart';
import '../../../../../../shared/widgets/currency_selector.dart';
import '../../../providers/financial_tree_provider.dart';
import 'app_tree_theme.dart';
import 'tree_shared_widgets.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Premium bottom sheet for adding/editing a tree node.
class TreeNodeFormSheet extends ConsumerStatefulWidget {
  final String? nodeId;
  final String? parentId;
  const TreeNodeFormSheet({super.key, this.nodeId, this.parentId});

  @override
  ConsumerState<TreeNodeFormSheet> createState() => _TreeNodeFormSheetState();
}

class _TreeNodeFormSheetState extends ConsumerState<TreeNodeFormSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _amountCtrl;
  late final TextEditingController _notesCtrl;
  late String _currency;
  bool _currencyTouched = false;
  late FinancialTreeNodeType _type;
  String? _selectedParentId;
  bool _saving = false;

  bool get _isEdit => widget.nodeId != null;

  String _tr(String key) => AppLocalizations.of(context).translate(key);

  /// Resolves USD-if-enabled-else-enabled without ever overriding an
  /// explicit user pick, an edit, or the parent tree's currency.
  Future<void> _resolveCurrencyDefault() async {
    try {
      final code =
          await resolveDefaultCurrency(ref.read(currentUserIdProvider));
      if (!mounted || _currencyTouched) return;
      setState(() => _currency = code);
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    final state = ref.read(financialTreeProvider);
    final node = _isEdit
        ? state.nodes.where((n) => n.id == widget.nodeId).firstOrNull
        : null;
    _nameCtrl = TextEditingController(text: node?.name ?? '');
    _amountCtrl = TextEditingController(text: node != null ? _fmtNum(node.amount) : '');
    _notesCtrl = TextEditingController(text: node?.notes ?? '');
    _currency = node?.currency ?? state.currentTree?.currency ?? 'USD';
    if (node?.currency != null || state.currentTree?.currency != null) {
      _currencyTouched = true;
    } else {
      _resolveCurrencyDefault();
    }
    _type = node?.type ?? FinancialTreeNodeType.custom;
    _selectedParentId = widget.parentId ?? node?.parentId;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _amountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  String _fmtNum(double v) {
    return fmtNum(v);
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) return;
    setState(() => _saving = true);
    try {
      final amount = double.tryParse(_amountCtrl.text.replaceAll(',', '')) ?? 0;
      final notifier = ref.read(financialTreeProvider.notifier);

      if (_isEdit) {
        final node = ref.read(financialTreeProvider).nodes.where((n) => n.id == widget.nodeId).firstOrNull;
        if (node != null) {
          await notifier.updateNode(node.copyWith(
            name: _nameCtrl.text.trim(),
            type: _type,
            amount: amount,
            currency: _currency,
            notes: _notesCtrl.text.trim(),
            parentId: _selectedParentId,
            updatedAt: DateTime.now(),
          ));
        }
      } else if (_selectedParentId != null) {
        await notifier.addNode(
          parentId: _selectedParentId!,
          name: _nameCtrl.text.trim(),
          type: _type,
          amount: amount,
          currency: _currency,
          notes: _notesCtrl.text.trim(),
        );
      }
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(financialTreeProvider);
    final nodes = state.nodes;

    final parentNode = _selectedParentId != null
        ? nodes.where((n) => n.id == _selectedParentId).firstOrNull
        : null;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: TreeTheme.space20,
        right: TreeTheme.space20,
        top: TreeTheme.space16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            treeSheetHandle(),
            const SizedBox(height: TreeTheme.space16),
            Row(
              children: [
                Icon(_isEdit ? Icons.edit : Icons.add_circle_outline, color: AppColors.primary, size: 22),
                const SizedBox(width: TreeTheme.space8),
                Text(
                  _isEdit ? _tr('editNode') : _tr('addChild'),
                  style: TreeTheme.headingMd,
                ),
              ],
            ),
            if (parentNode != null) ...[
              const SizedBox(height: TreeTheme.space8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(15),
                  borderRadius: BorderRadius.circular(TreeTheme.radiusSm),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.arrow_downward, size: 14, color: AppColors.primary),
                    const SizedBox(width: 6),
                    Text('${_tr('willBeAddedUnder')}: ${parentNode.name}',
                        style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.primary)),
                  ],
                ),
              ),
            ],
            const SizedBox(height: TreeTheme.space16),
            TreeTextField(controller: _nameCtrl, hint: _tr('nodeName'), label: _tr('nodeName')),
            const SizedBox(height: TreeTheme.space16),
            Text(_tr('selectNodeType'), style: TreeTheme.label),
            const SizedBox(height: TreeTheme.space8),
            _buildTypeSelector(),
            const SizedBox(height: TreeTheme.space16),
            TreeTextField(
              controller: _amountCtrl,
              hint: '0',
              label: _tr('nodeAmount'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              isAmount: true,
            ),
            const SizedBox(height: TreeTheme.space16),
            CurrencySelector(
              label: _tr('nodeCurrency'),
              value: _currency,
              showCode: false,
              onChanged: (v) =>
                  setState(() => {_currency = v, _currencyTouched = true}),
            ),
            const SizedBox(height: TreeTheme.space16),
            TreeTextField(controller: _notesCtrl, hint: _tr('nodeNotes'), label: _tr('nodeNotes'), maxLines: 2),
            const SizedBox(height: TreeTheme.space8),
            Text(_tr('parentNode'), style: TreeTheme.label),
            const SizedBox(height: TreeTheme.space8),
            _buildParentSelector(nodes),
            const SizedBox(height: TreeTheme.space24),
            TreePrimaryButton(
              label: _isEdit ? _tr('save') : _tr('addChild'),
              onPressed: _save,
              loading: _saving,
              icon: _isEdit ? Icons.check : Icons.add,
            ),
            const SizedBox(height: TreeTheme.space16),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeSelector() {
    final types = FinancialTreeNodeType.values.where((t) => t != FinancialTreeNodeType.root).toList();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: types.map((t) {
        final color = Color(t.color);
        final selected = _type == t;
        return GestureDetector(
          onTap: () => setState(() => _type = t),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? color.withAlpha(20) : AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(TreeTheme.radiusFull),
              border: Border.all(
                color: selected ? color : AppColors.border,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(iconForNodeType(t), size: 14, color: selected ? color : AppColors.textSecondary),
                const SizedBox(width: 6),
                Text(
                  _tr(t.labelKey),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: selected ? color : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildParentSelector(List<FinancialTreeNode> nodes) {
    final parentNode = _selectedParentId != null
        ? nodes.where((n) => n.id == _selectedParentId).firstOrNull
        : null;
    return InkWell(
      onTap: () => _showParentPicker(nodes),
      borderRadius: BorderRadius.circular(TreeTheme.radiusMd),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(TreeTheme.radiusMd),
          border: Border.all(color: AppColors.border, width: 1),
        ),
        child: Row(
          children: [
            Icon(
              parentNode != null ? iconForNodeType(parentNode.type) : Icons.account_tree,
              size: 18,
              color: parentNode != null ? Color(parentNode.type.color) : AppColors.textSecondary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                parentNode?.name ?? _tr('selectParent'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 13,
                  color: parentNode != null ? AppColors.textPrimary : AppColors.textPlaceholder,
                ),
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.textDisabled, size: 20),
          ],
        ),
      ),
    );
  }

  void _showParentPicker(List<FinancialTreeNode> nodes) {
    final searchCtrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(TreeTheme.radiusXl)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final query = searchCtrl.text.toLowerCase();
          final filtered = nodes.where((n) {
            if (n.id == widget.nodeId) return false;
            return n.name.toLowerCase().contains(query);
          }).toList();

          return FractionallySizedBox(
            heightFactor: 0.7,
            child: Column(
              children: [
                treeSheetHandle(),
                const SizedBox(height: TreeTheme.space12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: TreeTheme.space16),
                  child: FyonaTextField(
                    controller: searchCtrl,
                    autofocus: true,
                    style: const TextStyle(fontFamily: 'Cairo'),
                    onChanged: (_) => setSheetState(() {}),
                    decoration: TreeTheme.inputDecoration(_tr('searchParent')),
                  ),
                ),
                const SizedBox(height: TreeTheme.space8),
                Expanded(
                  child: ListView(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.account_tree, color: AppColors.primary, size: 20),
                        title: Text(_tr('rootLevel'), style: TreeTheme.bodyMd),
                        subtitle: Text(_tr('noParent'), style: TreeTheme.caption),
                        onTap: () {
                          Navigator.pop(ctx);
                          setState(() => _selectedParentId = null);
                        },
                      ),
                      const Divider(height: 1),
                      ...filtered.where((n) => n.isRoot).map((n) => _parentTile(n, 0)),
                      ..._buildChildrenTiles(filtered, null, 0),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _buildChildrenTiles(List<FinancialTreeNode> all, String? parentId, int depth) {
    final children = all.where((n) => n.parentId == parentId && !n.isRoot).toList();
    return children.expand((n) => [
      _parentTile(n, depth + 1),
      ..._buildChildrenTiles(all, n.id, depth + 1),
    ]).toList();
  }

  Widget _parentTile(FinancialTreeNode node, int depth) {
    final color = Color(node.type.color);
    return ListTile(
      contentPadding: EdgeInsets.only(left: 16 + depth * 24.0, right: 16),
      leading: Container(
        width: 8, height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      title: Text(node.name, style: TreeTheme.bodyMd),
      subtitle: Text('${_tr(node.type.labelKey)} • ${_fmtNum(node.amount)} ${currencySymbol(node.currency)}', style: TreeTheme.caption),
      onTap: () {
        Navigator.pop(context);
        setState(() => _selectedParentId = node.id);
      },
    );
  }
}
