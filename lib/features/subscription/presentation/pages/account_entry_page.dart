import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/services/section_scope.dart';
import '../../../../core/services/connectivity_service.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../domain/personal_offline_access.dart';
import '../../domain/section_access.dart';
import '../providers/subscription_providers.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../employees/presentation/providers/employee_device_finance_provider.dart';

/// Resolves account access only after authentication and phone collection.
class AccountEntryPage extends ConsumerStatefulWidget {
  const AccountEntryPage({super.key});
  @override
  ConsumerState<AccountEntryPage> createState() => _AccountEntryPageState();
}

class _AccountEntryPageState extends ConsumerState<AccountEntryPage> {
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_enter);
  }

  Future<void> _enter() async {
    if (mounted) setState(() => _failed = false);
    try {
      final user = ref.read(authProvider).user;
      final connectivity = ref.read(connectivityServiceProvider);
      try {
        await connectivity.init();
      } catch (_) {
        // Try the live request when the platform cannot report connectivity.
      }
      if (!mounted) return;
      final employee = ref.read(employeeDeviceSelectionProvider);
      if (employee != null &&
          await SectionHistory.restore(employee.account, business: true, personal: true) == 'business' &&
          mounted) {
        // The existing employment card links to My Salary and My Debts.
        // Do not force the employee to buy their own merchant subscription.
        final keep = ref.listenManual(employeeDeviceCopyProvider, (_, _) {});
        try {
          final copy = await ref.read(employeeDeviceCopyProvider.future);
          if (!mounted) return;
          if (copy != null && ref.read(employeeDeviceSelectionProvider) == employee) {
            ref.read(activeSectionProvider.notifier).state = AppSection.business;
            context.go('/job-requests');
            return;
          }
        } catch (_) {
          // A device copy error must not block the usual personal entry.
        } finally {
          keep.close();
        }
        if (!mounted) return;
      }
      final pilot = ref.read(directoryPilotAccessProvider);
      if (pilot != null && user != null && user.preferredUsageMode == 'business') {
        final store = ref.read(directoryPilotStoreProvider);
        final saved = await store.entry(pilot);
        if (!mounted ||
            !sameDirectoryScope(pilot, ref.read(directoryPilotAccessProvider))) {
          return;
        }
        final preferBusiness = await SectionHistory.restore(
          user.id, business: true, personal: true,
        ) == 'business';
        if (!mounted) return;
        if (saved != null && preferBusiness &&
            sameDirectoryScope(pilot, ref.read(directoryPilotAccessProvider))) {
          context.go(RouteNames.dashboard);
          return;
        }
      }
      final status = await resolvePersonalEntry(
        connected: connectivity.isOnline,
        live: () => ref.refresh(subscriptionStatusProvider.future),
        local: () async => user == null
            ? null
            : ref.read(personalOfflineAccessProvider).read(user),
      );
      if (!mounted) return;
      if (ref.read(authProvider).user?.id != user?.id) return;
      if (status == null) {
        setState(() => _failed = true);
        return;
      }
      final business = hasSectionAccess(status, 'business');
      final personal = hasSectionAccess(status, 'personal');
      if (!business && !personal) {
        context.go(
          status['status'] == 'pending'
              ? RouteNames.subscriptionPending
              : RouteNames.subscription,
        );
        return;
      }
      final mode = await SectionHistory.restore(
        ref.read(authProvider).user?.id ?? '',
        business: business,
        personal: personal,
      );
      if (!mounted) return;
      await ref.read(authProvider.notifier).setUsageMode(mode);
      if (!mounted) return;
      // Paid business plans have a three-step placeholder after the invoice.
      // Free trial has full access without pretending questions exist yet.
      if (mode == 'business' &&
          status['is_trial'] != true &&
          status['business_setup_completed'] != true) {
        context.go('/business-setup');
      } else {
        context.go(
          mode == 'business'
              ? RouteNames.dashboard
              : RouteNames.personalDashboard,
        );
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: _failed
          ? FilledButton(
              onPressed: _enter,
              child: Text(AppLocalizations.of(context).translate('retry')),
            )
          : const CircularProgressIndicator(),
    ),
  );
}
