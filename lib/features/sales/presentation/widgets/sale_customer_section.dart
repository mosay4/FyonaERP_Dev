import 'package:flutter/material.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../../../core/localization/app_localizations.dart';
import '../../../../../core/responsive/r_api.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/utils/currency_formatter.dart';
import '../../../../../shared/widgets/business_selection_sheet.dart';
import '../providers/sale_providers.dart';
import '../../../core_business/presentation/widgets/debt_widgets.dart';
import '../../../core_business/presentation/widgets/business_operation_error.dart';
import '../../domain/sale_totals.dart' show parseMoney;
import 'sale_field.dart';
import 'sale_section_card.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Customer: ONE field opening a 3-option sheet (cash / existing / quick-add).
///
/// After choosing, the sheet closes and only the choice shows in the field.
/// Debt needs a real customer — surfaced as the customer's open debt line.
class SaleCustomerSection extends ConsumerWidget {
  const SaleCustomerSection({super.key});

  Future<void> _choose(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final picked = await showBusinessSelectionSheet<String>(
      context: context,
      title: l10n.translate('saleChooseCustomer'),
      items: [
        BizSheetItem(
            value: 'cash',
            title: l10n.translate('saleCashCustomer'),
            icon: Icons.payments_outlined),
        if (ref.read(employeeCanProvider('customers'))) BizSheetItem(
            value: 'existing',
            title: l10n.translate('saleSelectCustomer'),
            subtitle: l10n.translate('saleSearchCustomerHint'),
            icon: Icons.search),
        if (ref.read(employeeCanProvider('customers.add'))) BizSheetItem(
            value: 'quick',
            title: l10n.translate('saleQuickAdd'),
            icon: Icons.person_add_outlined),
      ],
    );
    if (picked == null || !context.mounted) return;
    if (picked == 'cash') {
      ref.read(saleDraftProvider.notifier).setCustomer(SaleCustomer.cash);
    } else if (picked == 'existing') {
      _pickExisting(context, ref);
    } else {
      _quickAdd(context, ref);
    }
  }

  Future<void> _pickExisting(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final source = ref.read(salesApiProvider);
    final picked = await showBusinessSelectionSheet<Map<String, dynamic>>(
      context: context,
      title: l10n.translate('saleSelectCustomer'),
      showSearch: true,
      searchHint: l10n.translate('saleSearchCustomerHint'),
      emptyText: l10n.translate('saleNoCustomers'),
      onSearch: (q) async {
        final raw = await source.searchCustomers(q);
        return [
          for (final c in raw.whereType<Map>())
            BizSheetItem(
              value: Map<String, dynamic>.from(c),
              title: (c['name'] ?? '').toString(),
              subtitle: (c['phone']?.toString().isNotEmpty ?? false)
                  ? c['phone'].toString()
                  : null,
              icon: Icons.person_outline,
            ),
        ];
      },
    );
    if (picked == null || !context.mounted ||
        !identical(source, ref.read(salesApiProvider))) return;
    ref.read(saleDraftProvider.notifier).setCustomer(SaleCustomer(
          id: picked['id']?.toString(),
          name: (picked['name'] ?? '').toString(),
          phone: picked['phone']?.toString(),
        ));
  }

  Future<void> _quickAdd(BuildContext context, WidgetRef ref) async {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final l10n = AppLocalizations.of(context);
    final source = ref.read(salesApiProvider);
    final command = const Uuid().v4();
    var saving = false;
    final saved = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.translate('saleQuickAdd'),
            style: const TextStyle(
                fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FyonaTextField(
              controller: nameCtrl,
              decoration: InputDecoration(
                  labelText: l10n.translate('saleCustomerName'),
                  hintText: l10n.translate('saleCustomerNameHint')),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
            const SizedBox(height: 12),
            FyonaTextField(
              controller: phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                  labelText: l10n.translate('saleCustomerPhoneOpt')),
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
                  !identical(source, ref.read(salesApiProvider))) return;
              final name = nameCtrl.text.trim();
              if (name.isEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                    content: Text(
                        l10n.translate('saleCustomerNameRequired'),
                        style: const TextStyle(fontFamily: 'Cairo'))));
                return;
              }
              saving = true;
              try {
                final created =
                    await source.createCustomer(
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
                       content: Text(businessOperationError(l10n, e, fallback: 'txOperationFailed'),
                          style:
                              const TextStyle(fontFamily: 'Cairo'))));
                }
              } finally { saving = false; }
            },
            child: Text(l10n.translate('save'),
                style: const TextStyle(fontFamily: 'Cairo')),
          ),
        ],
      ),
    );
    if (saved != null && context.mounted && identical(source, ref.read(salesApiProvider))) {
      ref.read(saleDraftProvider.notifier).setCustomer(SaleCustomer(
            id: saved['id']?.toString(),
            name: (saved['name'] ?? '').toString(),
            phone: saved['phone']?.toString(),
          ));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final customer = ref.watch(saleDraftProvider.select((d) => d.customer));
    final l10n = AppLocalizations.of(context);
    final display = customer == null
        ? ''
        : customer.isCash
            ? l10n.translate('saleCashCustomer')
            : customer.name;
    return SaleSectionCard(
      titleKey: 'saleCustomer',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SaleField(
            value: display,
            placeholder: l10n.translate('saleTapToSelectCustomer'),
            onTap: () => _choose(context, ref),
          ),
          if (customer != null && !customer.isCash && ref.watch(employeeCanProvider('customers.details'))) ...[
            const SizedBox(height: 8),
            _DebtLine(customerId: customer.id!),
          ],
        ],
      ),
    );
  }
}

class _DebtLine extends ConsumerWidget {
  final String customerId;
  const _DebtLine({required this.customerId});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return FutureBuilder(
      future: ref.read(salesApiProvider).customerBalance(customerId),
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        final debts = (snap.data!['debts'] as List?) ?? const [];
        final items = (snap.data!['items'] as List?) ?? const [];
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
                Text(l10n.translate('saleExistingDebt'),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11.5),
                        fontWeight: FontWeight.w800,
                        color: AppColors.danger)),
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
                        Text(debtAmount(d['debt']),
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

  void _showDebts(BuildContext context, List items) {
    final l10n = AppLocalizations.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(l10n.translate('saleViewCustomerDebts'),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary)),
            ),
            for (final d in items.whereType<Map>())
              ListTile(
                leading: Icon(Icons.circle,
                    size: 10, color: AppColors.danger),
                title: Text(
                    '${fmtNum(parseMoney(d['debt']))} ${currencyLabel((d['currency'] ?? '').toString())}',
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary)),
                subtitle: (d['date'] ?? '').toString().isNotEmpty
                    ? Text(
                        '${l10n.translate('debtDate')}: ${d['date'].toString().split('T').first}',
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 11,
                            color: AppColors.textSecondary))
                    : null,
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
