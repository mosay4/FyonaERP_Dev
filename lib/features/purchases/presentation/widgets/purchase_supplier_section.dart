import 'package:flutter/material.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../../../core/localization/app_localizations.dart';
import '../../../../../core/responsive/r_api.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../shared/widgets/business_selection_sheet.dart';
import '../../../sales/presentation/widgets/sale_field.dart';
import '../../../sales/presentation/widgets/sale_section_card.dart';
import '../providers/purchase_providers.dart';
import '../../../core_business/presentation/widgets/debt_widgets.dart';
import '../../../core_business/presentation/widgets/business_operation_error.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Supplier: ONE field opening a 3-option sheet (cash / existing / quick-add),
/// mirroring the sale customer section exactly.
class PurchaseSupplierSection extends ConsumerWidget {
  const PurchaseSupplierSection({super.key});

  Future<void> _choose(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final picked = await showBusinessSelectionSheet<String>(
      context: context,
      title: l10n.translate('purChooseSupplier'),
      items: [
        BizSheetItem(
            value: 'cash',
            title: l10n.translate('purCashSupplier'),
            icon: Icons.payments_outlined),
        if (ref.read(employeeCanProvider('suppliers'))) BizSheetItem(
            value: 'existing',
            title: l10n.translate('purSelectSupplier'),
            subtitle: l10n.translate('purSearchSupplierHint'),
            icon: Icons.search),
        if (ref.read(employeeCanProvider('suppliers.add'))) BizSheetItem(
            value: 'quick',
            title: l10n.translate('purQuickAddSupplier'),
            icon: Icons.person_add_outlined),
      ],
    );
    if (picked == null || !context.mounted) return;
    if (picked == 'cash') {
      ref.read(purchaseDraftProvider.notifier).setSupplier(PurchaseSupplier.cash);
    } else if (picked == 'existing') {
      _pickExisting(context, ref);
    } else {
      _quickAdd(context, ref);
    }
  }

  Future<void> _pickExisting(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final source = ref.read(purchaseApiProvider);
    final picked = await showBusinessSelectionSheet<Map<String, dynamic>>(
      context: context,
      title: l10n.translate('purSelectSupplier'),
      showSearch: true,
      searchHint: l10n.translate('purSearchSupplierHint'),
      emptyText: l10n.translate('purNoSuppliers'),
      onSearch: (q) async {
        final raw = await source.searchSuppliers(q);
        return [
          for (final s in raw.whereType<Map>())
            BizSheetItem(
              value: Map<String, dynamic>.from(s),
              title: (s['name'] ?? '').toString(),
              subtitle: (s['phone']?.toString().isNotEmpty ?? false)
                  ? s['phone'].toString()
                  : null,
              icon: Icons.person_outline,
            ),
        ];
      },
    );
    if (picked == null || !context.mounted ||
        !identical(source, ref.read(purchaseApiProvider))) return;
    ref.read(purchaseDraftProvider.notifier).setSupplier(PurchaseSupplier(
          id: picked['id']?.toString(),
          name: (picked['name'] ?? '').toString(),
          phone: picked['phone']?.toString(),
        ));
  }

  Future<void> _quickAdd(BuildContext context, WidgetRef ref) async {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final l10n = AppLocalizations.of(context);
    final source = ref.read(purchaseApiProvider);
    final command = const Uuid().v4();
    var saving = false;
    final saved = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.translate('purQuickAddSupplier'),
            style: const TextStyle(
                fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FyonaTextField(
              controller: nameCtrl,
              decoration: InputDecoration(
                  labelText: l10n.translate('purSupplierName')),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
            const SizedBox(height: 12),
            FyonaTextField(
              controller: phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration:
                  InputDecoration(labelText: l10n.translate('purSupplierPhoneOpt')),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.translate('cancel'),
                style: const TextStyle(fontFamily: 'Cairo')),
          ),
          FilledButton(
            onPressed: () async {
              if (saving || !context.mounted ||
                  !identical(source, ref.read(purchaseApiProvider))) return;
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              saving = true;
              try {
                final created =
                    await source.createSupplier(
                          name: name,
                          phone: phoneCtrl.text.trim().isEmpty
                              ? null
                              : phoneCtrl.text.trim(),
                          commandId: command,
                        );
                if (ctx.mounted) Navigator.pop(ctx, created);
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                    content: Text(businessOperationError(l10n, e, fallback: 'txOperationFailed')),
                  ));
                }
              } finally { saving = false; }
            },
            child: Text(l10n.translate('save'),
                style: const TextStyle(fontFamily: 'Cairo')),
          ),
        ],
      ),
    );
    if (saved != null && context.mounted && identical(source, ref.read(purchaseApiProvider))) {
      ref.read(purchaseDraftProvider.notifier).setSupplier(PurchaseSupplier(
            id: saved['id']?.toString(),
            name: (saved['name'] ?? '').toString(),
            phone: saved['phone']?.toString(),
          ));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supplier = ref.watch(purchaseDraftProvider.select((d) => d.supplier));
    final l10n = AppLocalizations.of(context);
    final display = supplier == null
        ? ''
        : supplier.isCash
            ? l10n.translate('purCashSupplier')
            : supplier.name;
    return SaleSectionCard(
      titleKey: 'purSupplier',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SaleField(
            value: display,
            placeholder: l10n.translate('purTapToSelectSupplier'),
            onTap: () => _choose(context, ref),
          ),
          if (supplier != null && !supplier.isCash && ref.watch(employeeCanProvider('suppliers.details'))) ...[
            const SizedBox(height: 8),
            _PayableLine(supplierId: supplier.id!),
          ],
        ],
      ),
    );
  }
}

class _PayableLine extends ConsumerWidget {
  final String supplierId;
  const _PayableLine({required this.supplierId});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder(
      future: ref.read(purchaseApiProvider).supplierBalance(supplierId),
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        final debts = (snap.data!['debts'] as List?) ?? const [];
        if (debts.isEmpty) return const SizedBox.shrink();
        final rows = debts.whereType<Map>().toList()
          ..sort((a, b) => '${a['currency']}'.compareTo('${b['currency']}'));
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.danger.withAlpha(55)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.account_balance_wallet_outlined,
                    size: 15, color: AppColors.danger),
                const SizedBox(width: 6),
                Text(
                    AppLocalizations.of(context)
                        .translate('purExistingPayable'),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11.5),
                        fontWeight: FontWeight.w800,
                        color: AppColors.danger)),
                const Spacer(),
              ]),
              const SizedBox(height: 7),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final d in rows)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 5),
                      decoration: BoxDecoration(
                        color: AppColors.danger.withAlpha(12),
                        borderRadius: BorderRadius.circular(9),
                        border:
                            Border.all(color: AppColors.danger.withAlpha(45)),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(debtRowAmount(d),
                            textDirection: TextDirection.ltr,
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: R.fontSize(context, 12.5),
                                fontWeight: FontWeight.w800,
                                color: AppColors.textPrimary)),
                        const SizedBox(width: 4),
                        Text(
                            debtCurrencyLabel(
                                '${d['currency'] ?? ''}'.toString()),
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: R.fontSize(context, 10.5),
                                color: AppColors.textSecondary)),
                      ]),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
