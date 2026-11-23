import 'package:flutter/material.dart';
import '../../../../core_business/data/local_directory/directory_pilot.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/business_dashboard_providers.dart';
import '../../../../employees/presentation/providers/employee_providers.dart';
import '../../../../../core/localization/app_localizations.dart';
import '../../../../../core/responsive/r_api.dart';
import '../../../../../core/router/route_names.dart';
import 'package:hugeicons/hugeicons.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../branches/data/branch_scope.dart';
import '../../../../core_business/presentation/widgets/business_online_gate.dart';

import '../../../../../shared/widgets/two_tone_icon.dart';
import '../../../../../shared/widgets/two_tone_icons.dart';

/// Business services grid — the 9 shell buttons from the approved PDF design
/// (`FYONA_Main_Screen.pdf`).
///
/// Layout metrics mirror the personal home grid (3 per row, 8px tile gap,
/// card radius 12, label 11/w600). Glyphs and colors follow the PDF exactly:
/// crimson [bizIconRed] on a light-pink chip [bizIconChip], including the
/// mixed solid/outline compositions (invoice+$ badge, cart+receipt,
/// wallet+arrow, person+box). Every button is a shell: taps acknowledge with
/// haptics + a "coming soon" note until the features are wired. Nothing here
/// touches the personal section.
class BusinessServicesGrid extends ConsumerWidget {
  const BusinessServicesGrid({super.key});

  static const _rows = [
    ['bizSaleInvoice', 'bizPurchaseInvoice', 'bizReturns'],
    ['bizCustomers', 'bizSuppliers', 'bizWarehouse'],
    ['bizExpenses', 'bizReconcile', 'bizInvoices'],
    ['bizTransactions', 'bizSara', 'bizEmployees'],
  ];

  /// The same visual language as the Personal home grid: ONE two-tone
  /// icon per button (32px, theme-aware grey outline + the burgundy
  /// detail accent). No colored chips, no per-button palettes.
  static Widget _glyph(BuildContext context, String key) {
    switch (key) {
      case 'bizSaleInvoice':
        return TwoToneIcon(
          data: TwoToneIcons.receiptDollar,
          size: 32,
          outlineColor: AppColors.textSecondary,
          detailColor: AppColors.primary,
        );
      case 'bizPurchaseInvoice':
        // Purchase invoice: a distinct invoice variant + the shopping-bag
        // purchase symbol as the burgundy detail (same two-tone language).
        return TwoToneIcon(
          data: const TwoToneIconData(
            outline: HugeIcons.strokeRoundedInvoice03,
            detail: HugeIcons.strokeRoundedShoppingBag01,
            detailScale: 0.36,
            detailOffsetX: 1,
            detailOffsetY: 2,
          ),
          size: 32,
          outlineColor: AppColors.textSecondary,
          detailColor: AppColors.primary,
        );
      case 'bizReturns':
        return TwoToneIcon(
          data: TwoToneIcons.repeat,
          size: 32,
          outlineColor: AppColors.textSecondary,
          detailColor: AppColors.primary,
        );
      case 'bizCustomers':
        return TwoToneIcon(
          data: TwoToneIcons.users,
          size: 32,
          outlineColor: AppColors.textSecondary,
          detailColor: AppColors.primary,
        );
      case 'bizSuppliers':
        return TwoToneIcon(
          data: TwoToneIcons.truck,
          size: 32,
          outlineColor: AppColors.textSecondary,
          detailColor: AppColors.primary,
        );
      case 'bizWarehouse':
        // Clear storage box/crate (tape + label), same stroke language.
        return TwoToneIcon(
          data: const TwoToneIconData(
            outline: HugeIcons.strokeRoundedDeliveryBox01,
          ),
          size: 32,
          outlineColor: AppColors.textSecondary,
          detailColor: AppColors.primary,
        );
      case 'bizExpenses':
        // Financial FLOW: green arrow IN (income) + red arrow OUT (expense)
        // around a theme-adaptive money mark. The arrows keep their
        // semantic colors in both themes; the rest follows the theme.
        final dark = Theme.of(context).brightness == Brightness.dark;
        final inColor = dark
            ? const Color(0xFF66BB6A)
            : const Color(0xFF2E7D32);
        final outColor = dark
            ? const Color(0xFFEF5350)
            : const Color(0xFFC62828);
        return SizedBox(
          width: 32,
          height: 32,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Transform.translate(
                offset: const Offset(-8, 2),
                child: HugeIcon(
                  icon: HugeIcons.strokeRoundedArrowDown02,
                  color: inColor,
                  size: 18,
                  strokeWidth: 1.8,
                ),
              ),
              Transform.translate(
                offset: const Offset(8, -2),
                child: HugeIcon(
                  icon: HugeIcons.strokeRoundedArrowUp02,
                  color: outColor,
                  size: 18,
                  strokeWidth: 1.8,
                ),
              ),
              HugeIcon(
                icon: HugeIcons.strokeRoundedDollar01,
                color: AppColors.textSecondary,
                size: 13,
              ),
            ],
          ),
        );
      case 'bizReconcile':
        return TwoToneIcon(
          data: TwoToneIcons.check,
          size: 32,
          outlineColor: AppColors.textSecondary,
          detailColor: AppColors.primary,
        );
      case 'bizInvoices':
        return TwoToneIcon(
          data: TwoToneIcons.invoice,
          size: 32,
          outlineColor: AppColors.textSecondary,
          detailColor: AppColors.primary,
        );
      case 'bizTransactions':
        // Financial transactions log: a ledger book with the money mark —
        // visually unrelated to the expense/income flow arrows.
        return TwoToneIcon(
          data: const TwoToneIconData(
            outline: HugeIcons.strokeRoundedBook02,
            detail: HugeIcons.strokeRoundedDollar01,
            detailScale: 0.34,
            detailOffsetY: -2,
          ),
          size: 32,
          outlineColor: AppColors.textSecondary,
          detailColor: AppColors.primary,
        );
      case 'bizEmployees':
        // Employees: a person-group with the burgundy add-badge detail —
        // the SAME two-tone language as every other tile.
        return TwoToneIcon(
          data: const TwoToneIconData(
            outline: HugeIcons.strokeRoundedUserGroup,
            detail: HugeIcons.strokeRoundedUserAdd01,
            detailScale: 0.36,
            detailOffsetX: 1,
            detailOffsetY: -1,
          ),
          size: 32,
          outlineColor: AppColors.textSecondary,
          detailColor: AppColors.primary,
        );
      case 'bizSara':
      default:
        return TwoToneIcon(
          data: TwoToneIcons.sara,
          size: 32,
          outlineColor: AppColors.textSecondary,
          detailColor: AppColors.primary,
        );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const permissionKeys = <String, String>{
      'bizSaleInvoice': 'sales.create',
      'bizPurchaseInvoice': 'purchases.create',
      'bizReturns': 'returns',
      'bizCustomers': 'customers',
      'bizSuppliers': 'suppliers',
      'bizWarehouse': 'inventory',
      'bizExpenses': 'expenses',
      'bizReconcile': 'reconciliation',
      'bizInvoices': 'invoices',
      'bizTransactions': 'transactions',
      'bizSara': 'ai',
      'bizEmployees': 'employees',
    };
    final allowed = _rows
        .expand((r) => r)
        .where((key) => !BranchScope.readOnly || key != 'bizExpenses')
        .where(
          (k) => k == 'bizReturns'
              ? ref.watch(employeeCanProvider('returns')) && (ref.watch(employeeCanProvider('sales.returns')) || ref.watch(employeeCanProvider('purchases.returns')))
              : k == 'bizExpenses'
              ? ref.watch(employeeCanProvider('income')) ||
                  ref.watch(employeeCanProvider('expenses'))
              : ref.watch(employeeCanProvider(permissionKeys[k] ?? 'dashboard')),
        )
        .toList();
    final rows = <List<String>>[];
    for (var i = 0; i < allowed.length; i += 3) {
      rows.add(allowed.sublist(i, (i + 3).clamp(0, allowed.length)));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          for (var r = 0; r < rows.length; r++) ...[
            if (r > 0) const SizedBox(height: 8),
            Row(
              children: [
                // Natural 3-column grid: the last row keeps the EXACT same
                // tile sizes; its third slot stays completely empty.
                for (var i = 0; i < rows[r].length; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: _BusinessActionCard(labelKey: rows[r][i]),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _BusinessActionCard extends StatefulWidget {
  final String labelKey;

  const _BusinessActionCard({required this.labelKey});

  @override
  State<_BusinessActionCard> createState() => _BusinessActionCardState();
}

class _BusinessActionCardState extends State<_BusinessActionCard>
    with SingleTickerProviderStateMixin {
  double _scale = 1.0;

  Future<void> _tap(BuildContext context) async {
    HapticFeedback.lightImpact();
    setState(() => _scale = 0.96);
    Future.delayed(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _scale = 1.0);
    });
    // Live buttons navigate; the rest stay shells until their step lands.
    final key = widget.labelKey;
    // Sara always needs the internet. Employees work on the device when
    // the branch is local; only linking an account needs the internet.
    final local = ProviderScope.containerOf(context, listen: false)
            .read(businessLocalLedgerScopeProvider) !=
        null;
    if (key == 'bizSara' || (key == 'bizEmployees' && !local)) {
      if (!await ensureBusinessOnline(context) || !context.mounted) return;
    }
    if (BranchScope.readOnly &&
        (key == 'bizSaleInvoice' ||
            key == 'bizPurchaseInvoice' ||
            key == 'bizReconcile')) {
      await _showReadOnly(context);
      return;
    }
    if (key == 'bizSaleInvoice') {
      await context.push(RouteNames.salesAdd);
      if (context.mounted) {
        ProviderScope.containerOf(context).invalidate(businessRecentProvider);
      }
      return;
    }
    if (key == 'bizInvoices') {
      await context.push(RouteNames.invoices);
      if (context.mounted) {
        ProviderScope.containerOf(context).invalidate(businessRecentProvider);
      }
      return;
    }
    if (key == 'bizPurchaseInvoice') {
      await context.push(RouteNames.purchasesAdd);
      if (context.mounted) {
        ProviderScope.containerOf(context).invalidate(businessRecentProvider);
      }
      return;
    }
    if (key == 'bizReturns') {
      await context.push(RouteNames.returns);
      if (context.mounted) {
        ProviderScope.containerOf(context).invalidate(businessRecentProvider);
      }
      return;
    }
    if (key == 'bizCustomers') {
      await context.push(RouteNames.customers);
      if (context.mounted) {
        ProviderScope.containerOf(context).invalidate(businessRecentProvider);
      }
      return;
    }
    if (key == 'bizSuppliers') {
      await context.push(RouteNames.suppliers);
      if (context.mounted) {
        ProviderScope.containerOf(context).invalidate(businessRecentProvider);
      }
      return;
    }
    if (key == 'bizWarehouse') {
      await context.push(RouteNames.inventory);
      if (context.mounted) {
        ProviderScope.containerOf(context).invalidate(businessRecentProvider);
      }
      return;
    }
    if (key == 'bizExpenses') {
      await context.push(RouteNames.businessIncomeExpense);
      if (context.mounted) {
        ProviderScope.containerOf(context).invalidate(businessRecentProvider);
      }
      return;
    }
    if (key == 'bizTransactions') {
      await context.push(RouteNames.businessTransactions);
      if (context.mounted) {
        ProviderScope.containerOf(context).invalidate(businessRecentProvider);
      }
      return;
    }
    if (key == 'bizEmployees') {
      await context.push('/employees');
      if (context.mounted) {
        ProviderScope.containerOf(context).invalidate(businessRecentProvider);
      }
      return;
    }
    if (key == 'bizSara') {
      await context.push(RouteNames.ai);
      return;
    }
    if (key == 'bizReconcile') {
      await context.push(RouteNames.reconciliation);
      if (context.mounted) {
        ProviderScope.containerOf(context).invalidate(businessRecentProvider);
      }
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).translate('bizComingSoon'),
            style: const TextStyle(fontFamily: 'Cairo'),
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  Future<void> _showReadOnly(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(15),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.visibility_rounded,
                color: AppColors.primary,
                size: 27,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.translate('branchReadOnlyDialogTitle'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              l10n.translate('branchReadOnlyDialogBody'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 11.5,
                height: 1.55,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                l10n.translate('branchReadOnlyDialogOk'),
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return GestureDetector(
      onTap: () => _tap(context),
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 120),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
          decoration: BoxDecoration(
            color: AppColors.surface,
            // Every business tile carries the same burgundy border as Sara.
            border: Border.all(color: AppColors.primary.withAlpha(80)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The icon floats directly (no chip) — identical to Personal.
              BusinessServicesGrid._glyph(context, widget.labelKey),
              const SizedBox(height: 8),
              // Fixed label slot → every tile is the same height, and the
              // FULL name always fits (scaled down, never cut or wrapped).
              SizedBox(
                height: R.fontSize(context, 18),
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      l10n.translate(widget.labelKey),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11),
                        fontWeight: FontWeight.w600,
                        // Label follows the theme (black on light, white on
                        // dark) on every tile — only the border stays burgundy.
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 1,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
