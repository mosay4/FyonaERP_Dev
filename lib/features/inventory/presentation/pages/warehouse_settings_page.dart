import 'package:flutter/material.dart';
import '../../../core_business/presentation/widgets/business_number_field.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../data/inventory_api.dart';
import '../providers/inventory_providers.dart';
import '../providers/warehouse_settings.dart';

/// Business warehouse settings. Simple switches; turning a feature off only
/// hides it — stored data is always kept.
class WarehouseSettingsPage extends ConsumerStatefulWidget {
  const WarehouseSettingsPage({super.key});

  @override
  ConsumerState<WarehouseSettingsPage> createState() =>
      _WarehouseSettingsPageState();
}

class _WarehouseSettingsPageState extends ConsumerState<WarehouseSettingsPage> {
  late final InventoryApi _source;
  bool _savingExpiry = false;

  @override
  void initState() {
    super.initState();
    _source = ref.read(inventoryApiProvider);
  }

  bool get _active =>
      mounted &&
      identical(_source, ref.read(inventoryApiProvider)) &&
      !BranchScope.readOnly &&
      ref.read(employeeCanProvider('inventory.edit'));

  Future<void> _saveExpiry(bool enabled, int days) async {
    if (!_active || _savingExpiry) return;
    setState(() => _savingExpiry = true);
    try {
      final n = ref.read(warehouseSettingsProvider.notifier);
      n.setExpiry(enabled);
      n.setExpiryWarnDays(days);
      await _source.setWarehouseSettings(
        expiryEnabled: enabled,
        warnDays: days,
      );
      // A device branch keeps its own setting in its ledger.
      if (_source is LocalInventoryApi && mounted) {
        ref.invalidate(deviceWarehouseExpiryProvider);
      }
    } catch (_) {
      // This is a connected preference mirrored to the server's push job.
    } finally {
      if (mounted) setState(() => _savingExpiry = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = ref.watch(inventoryWarehouseSettingsProvider);
    final n = ref.read(warehouseSettingsProvider.notifier);
    final same = identical(_source, ref.watch(inventoryApiProvider));
    final canEdit =
        same &&
        !BranchScope.readOnly &&
        ref.watch(employeeCanProvider('inventory.edit'));
    Widget tile(
      String key,
      bool value,
      ValueChanged<bool>? onChanged, {
      String? subtitle,
    }) {
      return SwitchListTile(
        value: value,
        onChanged: canEdit ? onChanged : null,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        title: Text(
          l10n.translate(key),
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 14),
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 11),
                  color: AppColors.textSecondary,
                ),
              ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(
          l10n.translate('invSettingsTitle'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            l10n.translate('invSettingsHint'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 13),
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          Card(
            color: AppColors.surface,
            elevation: 0,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: AppColors.border),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                tile('invSetImages', s.productImages, n.setProductImages),
                tile('invSetLow', s.lowStockAlert, n.setLowStock),
                tile('invSetCost', s.showCost, n.setShowCost),
                tile('invSetProfit', s.showProfit, n.setShowProfit),
                tile('invSetBarcode', s.barcode, n.setBarcode),
                tile('invSetFalcon', s.falcon, n.setFalcon),
                tile(
                  'invSetExpiry',
                  s.expiry,
                  !_savingExpiry
                      ? (v) => _saveExpiry(v, s.expiryWarnDays)
                      : null,
                ),
                if (s.expiry)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    title: Text(
                      l10n.translate('invSetExpiryWarn'),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 13),
                        color: AppColors.textPrimary,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${s.expiryWarnDays}',
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          onPressed: !canEdit || _savingExpiry
                              ? null
                              : () async {
                                  final c = TextEditingController(
                                    text: '${s.expiryWarnDays}',
                                  );
                                  final v = await showDialog<int>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: Text(
                                        l10n.translate('invSetExpiryWarn'),
                                        style: const TextStyle(
                                          fontFamily: 'Cairo',
                                          fontSize: 16,
                                        ),
                                      ),
                                      content: BusinessNumberField(
                                        controller: c,
                                        autofocus: true,
                                        keyboardType: TextInputType.number,
                                        style: const TextStyle(
                                          fontFamily: 'Cairo',
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(ctx),
                                          child: Text(
                                            l10n.translate('cancel'),
                                            style: const TextStyle(
                                              fontFamily: 'Cairo',
                                            ),
                                          ),
                                        ),
                                        FilledButton(
                                          onPressed: () => Navigator.pop(
                                            ctx,
                                            int.tryParse(c.text.trim()),
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
                                  c.dispose();
                                  if (v != null && v > 0 && _active)
                                    await _saveExpiry(s.expiry, v);
                                },
                        ),
                      ],
                    ),
                  ),
                tile('invSetMulti', s.multiCurrency, n.setMultiCurrency),
                tile('invSetExtra', s.extraOptions, n.setExtraOptions),
                tile('invSetCategories', s.categories, n.setCategories),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
