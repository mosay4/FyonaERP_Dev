import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/services/connectivity_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../personal/data/merchant_api.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../data/local_directory/directory_pilot.dart';
import '../../data/local_directory/directory_scope.dart';
import '../providers/business_cash_alerts.dart';
import '../widgets/debt_widgets.dart';

/// Business debts home (ref: "Business Debt Interface.pdf") — EXACTLY two
/// boxes: ديون الموردين / ديون العملاء. No totals, no amounts, no add button.
/// A small bell opens the isolated debt-notification center.
class BusinessDebtsPage extends ConsumerStatefulWidget {
  const BusinessDebtsPage({super.key});
  @override
  ConsumerState<BusinessDebtsPage> createState() => _BusinessDebtsPageState();
}

class _BusinessDebtsPageState extends ConsumerState<BusinessDebtsPage> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        actions: <Widget>[const DebtBellButton()],
        title: Text(l10n.translate('bizDebts'),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 17),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
      ),
      body: SingleChildScrollView(child: Column(children: [
        const SizedBox(height: 4),
        SizedBox(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              if (ref.watch(employeeCanProvider('suppliers'))) Expanded(
                child: _box(
                  l10n,
                  label: l10n.translate('bizDebtSuppliers'),
                  icon: Icons.local_shipping_outlined,
                  red: true,
                   onTap: () => context.push('/debts/suppliers'),
                ),
              ),
              if (ref.watch(employeeCanProvider('suppliers')) && ref.watch(employeeCanProvider('customers'))) const SizedBox(width: 14),
              if (ref.watch(employeeCanProvider('customers'))) Expanded(
                child: _box(
                  l10n,
                  label: l10n.translate('bizDebtCustomers'),
                  icon: Icons.groups_rounded,
                  red: false,
                   onTap: () => context.push('/debts/customers'),
                ),
              ),
            ]),
          ),
        ),
      ])),
    );
  }

  Widget _box(AppLocalizations l10n,
      {required String label,
      required IconData icon,
      required bool red,
      required VoidCallback onTap}) {
    // Forward arrow points LEFT in RTL, RIGHT in LTR (forced LTR so the icon
    // is never auto-mirrored into the wrong direction).
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final fg = red ? Colors.white : DebtStyle.red;
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(18),
      child: DebtPanel(red: red, pink: !red, decorated: true, padding: const EdgeInsets.all(12),
        child: ConstrainedBox(constraints: BoxConstraints(minHeight: (MediaQuery.sizeOf(context).width - 70) / 2),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const SizedBox(height: 20),
            Icon(icon, size: 48, color: fg),
            const SizedBox(height: 12), Text(label, textAlign: TextAlign.center,
              style: DebtStyle.text(context, size: 16, bold: true, color: red ? Colors.white : null)),
            const SizedBox(height: 12), Align(alignment: AlignmentDirectional.centerEnd,
              child: CircleAvatar(radius: 18, backgroundColor: fg.withAlpha(30),
                child: Icon(rtl ? Icons.arrow_back : Icons.arrow_forward,
                  textDirection: TextDirection.ltr,
                  size: 21, color: fg))),
          ]))));
  }
}

/// Notification bell with unread badge — small, out of the way.
class DebtBellButton extends ConsumerStatefulWidget {
  const DebtBellButton({super.key});
  @override
  ConsumerState<DebtBellButton> createState() => _DebtBellButtonState();
}

class _DebtBellButtonState extends ConsumerState<DebtBellButton> {
  int _unread = 0;
  int _cashUnread = 0;
  DirectoryAccess? _cashScope;
  DirectoryAccess? _remoteScope;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    if (!mounted) return;
    final scope = ref.read(businessLocalLedgerScopeProvider);
    if (scope != null) {
      try {
        final local = await businessCashAlerts(ref, scope, AppLocalizations.of(context));
        if (!mounted || !sameDirectoryScope(scope, ref.read(businessLocalLedgerScopeProvider))) return;
        setState(() {
          _cashScope = scope;
          _cashUnread = local.where((row) => row['is_read'] != true).length;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _cashScope = null;
          _cashUnread = 0;
        });
      }
      if (!mounted || !ref.read(connectivityServiceProvider).isOnline) return;
    }
    try {
      final d = await ref.read(merchantApiProvider).debtNotifications();
      if (mounted && sameDirectoryScope(scope, ref.read(businessLocalLedgerScopeProvider))) {
        setState(() {
          _remoteScope = scope;
          _unread = (d['unread'] as num?)?.toInt() ?? 0;
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(businessLocalLedgerScopeProvider);
    ref.listen(businessLocalLedgerScopeProvider, (before, after) {
      if (!sameDirectoryScope(before, after)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _load();
        });
      }
    });
    final canSeeCash = [
      for (final key in businessCashAlertPermissions) ref.watch(employeeCanProvider(key)),
    ].every((granted) => granted);
    final unread = (sameDirectoryScope(scope, _remoteScope) ? _unread : 0) +
        (scope != null && canSeeCash && sameDirectoryScope(scope, _cashScope) ? _cashUnread : 0);
    return IconButton(
      icon: Stack(clipBehavior: Clip.none, children: [
        Icon(Icons.notifications_outlined,
            size: 22, color: AppColors.textPrimary),
        if (unread > 0)
          Positioned(
            top: -2,
            right: -2,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                  color: AppColors.danger, shape: BoxShape.circle),
               child: Text('$unread',
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 8,
                      fontWeight: FontWeight.w800,
                      color: Colors.white)),
            ),
          ),
      ]),
      onPressed: () async {
        await context.push('/debts/notifications');
        _load();
      },
    );
  }
}
