import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../../core/localization/app_localizations.dart';
import '../../../../../../core/theme/app_colors.dart';
import '../../../../../../shared/widgets/dots_loader.dart';
import '../../../../../../shared/widgets/currency_selector.dart';
import '../../../providers/financial_tree_provider.dart';
import 'app_tree_theme.dart';
import 'tree_shared_widgets.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Bottom sheet to edit tree metadata: name, client, base amount,
/// currency (wealth display currency) and notes.
class TreeSettingsSheet extends ConsumerStatefulWidget {
  const TreeSettingsSheet({super.key});

  @override
  ConsumerState<TreeSettingsSheet> createState() => _TreeSettingsSheetState();
}

class _TreeSettingsSheetState extends ConsumerState<TreeSettingsSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _clientCtrl;
  late final TextEditingController _amountCtrl;
  late final TextEditingController _notesCtrl;
  late String _currency;
  bool _saving = false;

  String _tr(String key) => AppLocalizations.of(context).translate(key);

  @override
  void initState() {
    super.initState();
    final tree = ref.read(financialTreeProvider).currentTree!;
    _nameCtrl = TextEditingController(text: tree.name);
    _clientCtrl = TextEditingController(text: tree.clientName);
    _amountCtrl = TextEditingController(
      text: tree.baseAmount == tree.baseAmount.roundToDouble()
          ? tree.baseAmount.toStringAsFixed(0)
          : tree.baseAmount.toStringAsFixed(2),
    );
    _notesCtrl = TextEditingController(text: tree.notes);
    _currency = tree.currency;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _clientCtrl.dispose();
    _amountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amountCtrl.text.trim()) ?? 0;
    if (_nameCtrl.text.trim().isEmpty) return;
    setState(() => _saving = true);
    await ref.read(financialTreeProvider.notifier).updateTreeMeta(
          name: _nameCtrl.text.trim(),
          clientName: _clientCtrl.text.trim(),
          baseAmount: amount,
          currency: _currency,
          notes: _notesCtrl.text.trim(),
        );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration:  BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(TreeTheme.radiusXl)),
        ),
        padding: const EdgeInsets.fromLTRB(TreeTheme.space16, TreeTheme.space12, TreeTheme.space16, TreeTheme.space16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
              ),
              const SizedBox(height: TreeTheme.space16),
              Text(_tr('treeSettings'), style: TreeTheme.headingSm),
              const SizedBox(height: TreeTheme.space16),
              TreeTextField(controller: _nameCtrl, hint: _tr('treeName'), label: _tr('treeName')),
              const SizedBox(height: TreeTheme.space16),
              TreeTextField(controller: _clientCtrl, hint: _tr('treeClientName'), label: _tr('treeClientName')),
              const SizedBox(height: TreeTheme.space16),
              TreeTextField(
                controller: _amountCtrl,
                hint: '0',
                label: _tr('baseAmount'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: TreeTheme.space16),
              CurrencySelector(
                label: _tr('treeCurrency'),
                value: _currency,
                showCode: false,
                onChanged: (v) => setState(() => _currency = v),
              ),
              const SizedBox(height: TreeTheme.space16),
              TreeTextField(controller: _notesCtrl, hint: _tr('treeNotes'), label: _tr('treeNotes'), maxLines: 2),
              const SizedBox(height: TreeTheme.space24),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(TreeTheme.radiusMd)),
                  ),
                  icon: _saving
                      ? const DotsLoader.button()
                      : const Icon(Icons.check, size: 18),
                  label: Text(_tr('save'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: TreeTheme.space8),
            ],
          ),
        ),
      ),
    );
  }
}
