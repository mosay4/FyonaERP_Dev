import 'package:flutter/material.dart';
import '../../../../employees/presentation/providers/employee_navigation_guard.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../../core/localization/app_localizations.dart';
import '../../../../../shared/widgets/liquid_glass_nav_bar.dart';
import '../../../../../core/router/route_names.dart';
import '../../../../../core/theme/app_colors.dart';
import 'business_icon_theme.dart';
import '../../../../personal/presentation/providers/merchant_unread_provider.dart';
import '../../../../purchases/presentation/providers/purchase_providers.dart';
import '../../../../sales/presentation/providers/sale_providers.dart';
import '../../../../invoices/presentation/providers/invoice_design_provider.dart';
import '../../../../../shared/widgets/unsaved_exit_dialog.dart';
import '../../../../employees/presentation/providers/employee_providers.dart';

/// Business bottom navigation — الرئيسية / البنوك / الديون / التقارير.
///
/// Metrics mirror the personal `HomeBottomNav` (height 68 + pad, surface +
/// 0.5 top border, 36px chip, 18px glyph, 10sp label). Glyphs and colors follow
/// the approved PDF exactly: outline bank / coin-$ / doc-chart in grey, the
/// active home as a solid house in PDF crimson on the pink chip (no extra
/// circle or indicator bar, as drawn). Home and banks are live; debts and
/// reports are shells until their steps land.
class BusinessBottomNav extends ConsumerStatefulWidget {
  const BusinessBottomNav({super.key});
  @override
  ConsumerState<BusinessBottomNav> createState() => _BusinessBottomNavState();
}

class _BusinessBottomNavState extends ConsumerState<BusinessBottomNav> {
  static const _items = [
    _BizNavItem(icon: Icons.home_rounded, labelKey: 'bizHome', route: null),
    _BizNavItem(icon: Icons.account_balance_outlined, labelKey: 'bizBanks'),
    _BizNavItem(icon: Icons.monetization_on_outlined, labelKey: 'bizDebts'),
    _BizNavItem(
      icon: Icons.assessment_outlined,
      labelKey: 'bizReports',
      route: RouteNames.reports,
    ),
  ];

  Future<void> _onTap(BuildContext context, WidgetRef ref, int i) async {
    HapticFeedback.lightImpact();
    if (!await _leaveInvoiceIfNeeded(context, ref)) return;
    if (!context.mounted) return;
    final item = _items[i];
    if (item.route != null) {
      // Reports section is LIVE — open it (same shell, consistent with /banks).
      context.push(item.route!);
      return;
    }
    if (i == 0) {
      context.go(RouteNames.dashboard);
      return;
    }
    if (i == 1) {
      // Banks section is live now.
      context.go('/banks');
      return;
    }
    if (i == 2) {
      // Debts section (لك عند العملاء / عليك للموردين) is live now.
      context.push(RouteNames.debts);
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

  /// Bottom navigation must never bypass the sale/purchase invoice guard.
  /// The back arrow and system back already use PopScope, but `go` replaces
  /// the shell route and skips it; this asks the same keep/discard/cancel
  /// question before any bottom-tab navigation away from a filled invoice.
  Future<bool> _leaveInvoiceIfNeeded(
    BuildContext context,
    WidgetRef ref,
  ) async {
    if (employeePermissionsLeaveGuard != null &&
        !await employeePermissionsLeaveGuard!())
      return false;
    final path = GoRouterState.of(context).uri.path;
    final isSale = path == RouteNames.salesAdd;
    final isPurchase = path == RouteNames.purchasesAdd;
    final isDesign = path == RouteNames.invoicesDesignEdit;
    if (isDesign && ref.read(invoiceDesignDirtyProvider)) {
      final l10n = AppLocalizations.of(context);
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            l10n.translate('invUnsavedTitle'),
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontWeight: FontWeight.w800,
            ),
          ),
          content: Text(
            l10n.translate('invUnsavedBody'),
            style: const TextStyle(fontFamily: 'Cairo', height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: Text(
                l10n.translate('cancel'),
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'discard'),
              child: Text(
                l10n.translate('invExitWithoutSave'),
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: Text(
                l10n.translate('invSaveAndExit'),
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
            ),
          ],
        ),
      );
      if (action == null || action == 'cancel') return false;
      if (action == 'save') {
        try {
          await invoiceDesignSaveAndExitCallback?.call();
        } catch (_) {}
      }
      ref.read(invoiceDesignDirtyProvider.notifier).state = false;
      return true;
    }
    if (!isSale && !isPurchase) return true;
    final hasData = isSale
        ? ref.read(saleDraftProvider).hasEnteredData
        : ref.read(purchaseDraftProvider).hasEnteredData;
    if (!hasData) return true;
    final action = await showUnsavedExitDialog(context);
    if (action == UnsavedExitAction.cancel) return false;
    if (action == UnsavedExitAction.discard) {
      if (isSale) {
        ref.read(saleDraftProvider.notifier).reset();
      } else {
        ref.read(purchaseDraftProvider.notifier).reset();
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final unread = ref.watch(debtUnreadProvider('merchant')).valueOrNull ?? 0;
    final allowed = [
      ref.watch(employeeCanProvider('dashboard')),
      ref.watch(employeeCanProvider('banks')),
      ref.watch(employeeCanProvider('debts')),
      ref.watch(employeeCanProvider('reports.view')),
    ];
    final visible = <(int, _BizNavItem)>[
      for (var i = 0; i < _items.length; i++)
        if (allowed[i])
          (i, _items[i]),
    ];
    final path = GoRouterState.of(context).uri.path;
    final currentOriginal = path.startsWith('/banks')
        ? 1
        : path.startsWith('/debts')
        ? 2
        : path.startsWith('/reports')
        ? 3
        : 0;
    final currentIndex = visible.indexWhere((e) => e.$1 == currentOriginal);
    final l10n = AppLocalizations.of(context);
    return LiquidGlassNavBar(
      currentIndex: currentIndex,
      accent: bizIconRed(context),
      onTap: (vi) => _onTap(context, ref, visible[vi].$1),
      items: [
        for (final (originalIndex, item) in visible)
          LiquidGlassNavItem(
            label: l10n.translate(item.labelKey),
            badge: originalIndex == 2 && unread > 0,
            icon: (active, color) => Icon(item.icon, size: 20, color: color),
          ),
      ],
    );
  }
}

class _BizNavItem {
  final IconData icon;
  final String labelKey;
  final String? route;
  const _BizNavItem({required this.icon, required this.labelKey, this.route});
}
