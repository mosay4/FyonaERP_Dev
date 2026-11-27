import '../import/presentation/smart_import_page.dart';
import 'dart:convert';
import 'dart:async';
import '../services/section_scope.dart';
import 'package:flutter/material.dart';
import '../../shared/widgets/liquid_glass_nav_bar.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../shared/services/notification_router.dart';
import '../../shared/services/notification_service.dart';
import '../services/fcm_service.dart';
import '../../shared/widgets/dots_loader.dart';
import '../../features/branches/presentation/pages/branches_page.dart';
import '../../features/branches/presentation/pages/branch_transfers_page.dart';
import '../../features/branches/presentation/pages/branch_invitations_page.dart';
import '../../features/branches/presentation/pages/branch_members_page.dart';
import '../../features/branches/data/branch_api.dart';
import '../../features/branches/data/branch_revocation.dart';
import '../../features/core_business/data/project_settings_api.dart';
import '../../features/core_business/data/local_directory/directory_pilot.dart';
import '../../features/core_business/data/local_directory/directory_party.dart';
import '../../features/core_business/data/local_directory/directory_scope.dart';
import '../../features/core_business/presentation/providers/business_debt_operation_source.dart';
import '../../shared/widgets/merchant_workspace_gate.dart';
import '../../features/employees/presentation/providers/employee_providers.dart';
import '../../features/employees/presentation/widgets/employee_feature_gate.dart';
import '../../features/profile/presentation/pages/business_backup_page.dart';
import '../../features/branches/data/branch_scope.dart';
import '../../shared/widgets/double_back_to_exit.dart';
import 'shell_keys.dart';
import 'route_names.dart';
import '../theme/app_colors.dart';
import '../localization/app_localizations.dart';
import '../utils/currency_formatter.dart';
import '../../features/splash/presentation/splash_screen.dart';
import '../../features/auth/presentation/pages/login_page.dart';
import '../../features/auth/presentation/pages/reentry_page.dart';
import '../../features/splash/presentation/brand_entry_view.dart';
import '../../features/splash/presentation/brand_handoff_page.dart';
import '../../features/auth/presentation/pages/register_page.dart';
import '../../features/auth/presentation/pages/otp_page.dart';
import '../../features/auth/presentation/pages/verify_device_page.dart';
import '../../features/auth/presentation/pages/social_phone_page.dart';
import '../../features/auth/presentation/pages/reset_password_page.dart';
import '../../features/auth/auth2/security/approvals_page.dart';
import '../../features/auth/auth2/security/change_phone_page.dart';
import '../../features/auth/auth2/security/devices_page.dart';
import '../../features/auth/presentation/pages/forgot_password_page.dart';
import '../../features/auth/presentation/pages/change_password_page.dart';
import '../../features/auth/presentation/pages/choose_usage_page.dart';
import '../../features/auth/presentation/pages/sessions_page.dart';
import '../../features/auth/presentation/providers/auth_provider.dart';
import '../../features/dashboard/presentation/pages/business_dashboard_page.dart';
import '../../features/business_banks/presentation/pages/business_banks_page.dart';
import '../../features/business_banks/presentation/pages/business_bank_detail_page.dart';
import '../../features/business_banks/presentation/pages/business_account_detail_page.dart';
import '../../features/business_banks/presentation/providers/local_business_banking.dart';
import '../../features/sales/presentation/pages/sale_invoice_page.dart';
import '../../features/reconciliation/presentation/pages/reconciliation_home_page.dart';
import '../../features/reconciliation/data/reconciliation_api.dart';
import '../../features/reconciliation/presentation/pages/recon_bank_pages.dart';
import '../../features/reconciliation/presentation/pages/recon_inventory_scope_page.dart';
import '../../features/reconciliation/presentation/pages/recon_inventory_pick_page.dart';
import '../../features/reconciliation/presentation/pages/recon_inventory_result_page.dart';
import '../../features/reconciliation/presentation/pages/recon_inventory_count_page.dart';
import '../../features/reconciliation/presentation/pages/recon_archive_page.dart';
import '../../features/reconciliation/presentation/pages/recon_detail_page.dart';
import '../../features/reports/presentation/pages/reports_hub_page.dart';
import '../../features/reports/presentation/pages/report_view_page.dart';
import '../../features/sales/presentation/pages/sale_invoices_page.dart';
import '../../features/purchases/presentation/pages/purchase_invoice_page.dart';
import '../../features/returns/presentation/pages/return_create_page.dart';
import '../../features/returns/presentation/pages/return_view_page.dart';
import '../../features/returns/presentation/pages/returns_page.dart';
import '../../features/returns/presentation/pages/invoice_picker_page.dart';
import '../../features/invoices/presentation/pages/invoice_design_editor_page.dart';
import '../../features/invoices/presentation/pages/invoice_design_hub_page.dart';
import '../../features/invoices/presentation/pages/invoice_view_page.dart';
import '../../features/invoices/presentation/pages/invoices_list_page.dart';
import '../../features/core_business/presentation/pages/business_debts_page.dart';
import '../../features/core_business/presentation/pages/customers_page.dart';

import '../../features/employees/presentation/pages/employees_page.dart';
import '../../features/employees/presentation/pages/employee_form_page.dart';
import '../../features/employees/presentation/pages/employee_detail_page.dart';
import '../../features/employees/presentation/pages/job_requests_page.dart';
import '../../features/employees/presentation/pages/employee_profile_page.dart';
import '../../features/employees/presentation/providers/employee_device_finance_provider.dart';
import '../../features/employees/presentation/pages/employee_salary_page.dart';
import '../../features/employees/presentation/pages/employee_finance_receipt_page.dart';
import '../../features/employees/presentation/pages/employee_debts_page.dart';
import '../../features/core_business/presentation/pages/suppliers_page.dart';
import '../../features/core_business/presentation/pages/party_detail_page.dart';
import '../../features/core_business/presentation/pages/party_debt_pages.dart';
import '../../features/inventory/presentation/pages/inventory_home_page.dart';

import '../../features/inventory/presentation/pages/product_detail_page.dart';
import '../../features/inventory/presentation/pages/product_form_page.dart';
import '../../features/inventory/presentation/pages/product_movements_page.dart';
import '../../features/inventory/presentation/pages/warehouse_settings_page.dart';
import '../../features/inventory/presentation/pages/categories_page.dart';
import '../../features/inventory/presentation/pages/category_detail_page.dart';
import '../../features/inventory/presentation/pages/falcon_page.dart';
import '../../features/dashboard/presentation/pages/widgets/business_bottom_nav.dart';
import '../../features/dashboard/presentation/pages/business_setup_page.dart';
import '../../features/dashboard/presentation/pages/business_transactions_page.dart';
import '../../features/dashboard/presentation/pages/business_income_expense_page.dart';
import '../../features/dashboard/presentation/pages/business_transaction_details_page.dart';
import '../../features/subscription/presentation/pages/account_entry_page.dart';
import '../../features/subscription/domain/section_access.dart';
import '../../features/subscription/domain/personal_offline_access.dart';

import '../../features/email/presentation/pages/email_settings_page.dart';
import '../../features/email/presentation/pages/email_compose_page.dart';
import '../../features/notifications/presentation/pages/notification_list_page.dart';
import '../../features/notifications/presentation/pages/reminder_list_page.dart';
// Phase 5 â€” Personal Finance
import '../../features/personal/presentation/pages/personal_dashboard_page.dart';
import '../../features/personal/presentation/pages/merchant_accounts_page.dart';
import '../../features/personal/presentation/pages/merchant_debt_pages.dart';
import '../../features/personal/presentation/pages/personal_invoice_document_page.dart';
import '../../features/personal/presentation/pages/chat_page.dart';
import '../../features/personal/data/merchant_api.dart';
import '../../features/personal/presentation/pages/savings_goals_page.dart';
import '../../features/personal/presentation/pages/savings_goal_detail_page.dart';
import '../../features/personal/presentation/pages/receipt_design_hub_page.dart';
import '../../features/personal/presentation/pages/receipt_design_editor_page.dart';
import '../../features/personal/presentation/providers/receipt_design_models.dart';
import '../../features/personal/presentation/pages/personal_banks_page.dart';
import '../../features/personal/presentation/pages/personal_debts_page.dart';
import '../../features/personal/presentation/pages/personal_transactions_page.dart';
import '../../features/personal/presentation/pages/sara_quick_add_page.dart';
import '../../features/personal/presentation/pages/reports/personal_reports_page.dart';
import '../../features/personal/presentation/pages/reports/personal_report_view_page.dart';
import '../../features/personal/presentation/pages/personal_ai_page.dart';
import '../../features/personal/presentation/pages/widgets/home_header.dart';
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';

// Phase 1 â€” Settings, Profile, MFA
import '../../features/settings/presentation/pages/settings_page.dart';
import '../../features/settings/presentation/pages/company_settings_page.dart';
import '../../features/settings/presentation/pages/tax_settings_page.dart';
import '../../features/settings/presentation/pages/currency_settings_page.dart';
import '../../features/settings/presentation/pages/custom_fields_page.dart';
import '../../features/settings/presentation/pages/customization_page.dart';
import '../../features/settings/presentation/pages/design_studio_page.dart';
import '../../features/settings/presentation/pages/files_page.dart';
import '../../features/settings/presentation/pages/email_logs_page.dart';
import '../../features/settings/presentation/pages/email_templates_page.dart';
import '../../features/profile/presentation/pages/profile_page.dart';
import '../../features/mfa/presentation/pages/mfa_setup_page.dart';
import '../../features/mfa/presentation/pages/mfa_verify_page.dart';
import '../../features/onboarding/presentation/pages/onboarding_page.dart';
import '../../shared/widgets/maintenance_page.dart';
import '../../shared/providers/platform_controls_provider.dart';
import '../../core/services/connectivity_service.dart';

// New Module imports
import '../../features/ai/presentation/pages/ai_assistant_page.dart';
import '../../features/ai/presentation/pages/ai_suggestions_page.dart';
import '../../features/suggestions/presentation/pages/suggestions_page.dart';

import '../../features/subscription/presentation/pages/plans_page.dart';
import '../../features/subscription/presentation/pages/payment_page.dart';
import '../../features/subscription/presentation/pages/phone_entry_page.dart';
import '../../features/subscription/presentation/pages/subscription_pending_page.dart';
import '../../features/subscription/presentation/pages/subscription_invoice_screen.dart';
import '../../features/subscription/presentation/pages/auto_renew_sheet.dart';
import '../../features/subscription/presentation/pages/subscription_rejected_page.dart';
import '../../features/personal/presentation/pages/personal_transfer_page.dart';
import '../../features/personal/presentation/pages/personal_account_tree_page.dart';
import '../../features/personal/presentation/pages/widgets/tree/tree_list_page.dart';
import '../../features/personal/presentation/pages/personal_executive_dashboard_page.dart';
import '../../features/personal/presentation/pages/personal_bank_statement_page.dart';
import '../../features/personal/presentation/pages/personal_account_detail_page.dart';
import '../../features/personal/presentation/pages/bank_detail_page.dart';
import '../../features/personal/presentation/pages/all_banks_report_page.dart';
import '../../features/personal/presentation/pages/finance_overview_page.dart';
import '../../features/personal/presentation/pages/personal_budget_page.dart';
import '../../features/personal/presentation/pages/personal_budget_form_page.dart';
import '../../features/personal/presentation/pages/personal_budget_detail_page.dart';
import '../../features/personal/data/models/personal_models.dart';
import '../../features/personal/presentation/providers/personal_providers.dart';
import '../../features/personal/presentation/pages/personal_recurring_page.dart';
import '../../features/personal/presentation/pages/personal_recurring_form_page.dart';
import '../../features/personal/presentation/pages/personal_recurring_detail_page.dart';
import '../../features/personal/presentation/pages/personal_categories_page.dart';
import '../../features/personal/presentation/pages/personal_category_form_page.dart';
import '../../features/personal/presentation/pages/personal_backup_page.dart';
import '../../features/personal/presentation/pages/widgets/home_bottom_nav.dart';

import 'role_config.dart';
import '../../shared/widgets/app_drawer.dart';
import '../widgets/app_content_container.dart';
import '../../features/subscription/presentation/providers/subscription_providers.dart';
import '../../shared/widgets/subscription_gate.dart';
import '../../features/core_business/presentation/providers/local_commerce_navigation.dart';
import '../../features/core_business/presentation/providers/business_party_sharing_provider.dart';
import '../../features/core_business/presentation/providers/business_cash_relay_provider.dart';
import '../../features/core_business/presentation/providers/business_sync_provider.dart';
import '../../features/personal/presentation/providers/peer_relay_provider.dart';
import '../../features/personal/presentation/providers/personal_relay_provider.dart';
import '../config/directory_pilot_build.dart';
import '../../features/branches/data/branch_pictures.dart';

final _shellNavigatorKey = GlobalKey<NavigatorState>();
final _rootNavigatorKey = rootNavigatorKey;

const _directoryPartyRoutes = {
  '/customers/detail',
  '/suppliers/detail',
  '/debts/party-individual',
  '/debts/party-sections',
  '/debts/party-section',
};

bool _isDirectoryRoute(String path) =>
    path == RouteNames.dashboard ||
    path == RouteNames.customers ||
    path == RouteNames.suppliers ||
    _directoryPartyRoutes.contains(path);

bool _isLocalCommerceRoute(String path) =>
    commerceDocumentRoutes.containsKey(path) ||
    const {
      RouteNames.inventory, RouteNames.sales, RouteNames.salesAdd, RouteNames.purchasesAdd,
      RouteNames.returns, RouteNames.returnsPickInvoice, RouteNames.invoices,
      RouteNames.businessTransactions,
    }.contains(path);

/// Safe percent-decoding for query params that may already be decoded by
/// GoRouter. Never throws (a stray '%' must never crash a route builder into
/// a blank/black screen).
String? _dec(String? v) {
  if (v == null) return null;
  try {
    return Uri.decodeComponent(v);
  } catch (_) {
    return v;
  }
}

/// True when the target route is a real app feature that the paywall should
/// block (everything except the subscription/paywall screens themselves).
bool requestingNonPaywall(String route) {
  if (route.startsWith('/subscription')) {
    return false;
  }
  if (route.startsWith('/settings') || route.startsWith('/profile')) {
    return false;
  }
  return route.routeMode != null;
}

/// The first disabled-button key covering [route], or null when allowed.
String? _matchedDisabledKey(List<String> keys, String route) {
  if (keys.isEmpty) return null;
  final routeSlash = route.startsWith('/') ? route : '/$route';
  for (final raw in keys) {
    final k = raw.startsWith('/') ? raw : '/$raw';
    if (routeSlash == k ||
        (k.endsWith('/*') &&
            routeSlash.startsWith(k.substring(0, k.length - 1)))) {
      return raw;
    }
  }
  return null;
}

bool _isSegmentBoundary(String route, int kLen) {
  if (route.length == kLen) return true;
  return route[kLen] == '/';
}

/// Navigation never waits for a status refresh that is already in flight
/// (the 8s enforcement poll refreshes it constantly, and on a poor network
/// that request can hang for the whole HTTP timeout — every tap used to wait
/// on it). The last live answer of the SAME account decides; the poll
/// applies any change a moment later. Only a first load (or an account
/// change) waits for the server.
Future<Map<String, dynamic>> _subscriptionForNavigation(Ref ref) {
  final current = ref.read(subscriptionStatusProvider);
  if (current.hasValue && !current.hasError && !current.isReloading) {
    return Future.value(current.requireValue);
  }
  return ref.read(subscriptionStatusProvider.future);
}

final goRouterProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    navigatorKey: _rootNavigatorKey,
    // Pages opened with an in-memory `extra` (device records such as a
    // product, an invoice or an account) keep it when the router refreshes
    // (e.g. coming back from the background): without a codec go_router
    // drops non-JSON extras and the page reopens empty.
    extraCodec: const _MemoryExtraCodec(),
    initialLocation: RouteNames.splash,
    debugLogDiagnostics: false,
    redirect: (context, state) async {
      final authState = ref.read(authProvider);
      final isAuthenticated = authState.isAuthenticated;
      final isSplash = state.matchedLocation == RouteNames.splash;
      final isRestoring = authState.status == AuthStatus.initial;
      final isExpired = authState.status == AuthStatus.sessionExpired;
      final isReentry = state.matchedLocation == RouteNames.reentry;
      final isAuthRoute =
          state.matchedLocation == RouteNames.login ||
          state.matchedLocation == RouteNames.register ||
          state.matchedLocation == RouteNames.verifyEmail ||
          state.matchedLocation == RouteNames.forgotPassword ||
          state.matchedLocation == RouteNames.authOtp ||
          state.matchedLocation == RouteNames.verifyDevice ||
          state.matchedLocation == RouteNames.socialPhone ||
          state.matchedLocation == RouteNames.resetPassword;
      final isSetupRoute =
          state.matchedLocation == RouteNames.chooseUsage ||
          state.matchedLocation == '/account-entry' ||
          state.matchedLocation == '/business-setup' ||
          state.matchedLocation == RouteNames.onboarding ||
          state.matchedLocation.startsWith('/subscription');

      if (isSplash) return null;
      // While the session is being restored, hold on the splash screen so the
      // login page never flashes on app open with a still-valid session.
      if (isRestoring) return RouteNames.splash;
      // No usage-mode question anymore: login/register always resolve
      // through /account-entry (server entitlements), then the phone gate.
      // Mandatory phone — blocks all app routes until phone saved
      if (isAuthenticated &&
          !(authState.user?.isPlatformAdmin ?? false) &&
          !(authState.user?.hasPhone ?? false) &&
          state.matchedLocation != RouteNames.phoneEntry) {
        return '${RouteNames.phoneEntry}?mandatory=true';
      }
      // Expired session with recovery on device â†’ re-entry gate only
      // (fingerprint / stored password, never the full login form).
      if (isExpired && !isReentry) return RouteNames.reentry;
      // Plain logged-out users must not sit on the gate (no recovery).
      if (!isAuthenticated && !isExpired && isReentry) {
        return RouteNames.login;
      }
      if (isAuthenticated && (isAuthRoute || isReentry)) {
        final user = authState.user;
        final mode = user?.preferredUsageMode;
        // While app/section maintenance is active the authenticated user must
        // be allowed to STAY on the login page: bouncing them into a blocked
        // dashboard causes a loginâ†”dashboard ping-pong that ends up replaying
        // the intro video endlessly (maintenance eject â†’ login â†’ dashboard â†’
        // eject â†’ â€¦ â†’ splash again).
        final maintCtrl =
            ref.read(platformControlsProvider).valueOrNull ??
            await PlatformControls.loadFromPrefs();
        if (maintCtrl != null && !(user?.isPlatformAdmin ?? false)) {
          if (maintCtrl.isAppMaintenance) return null;
          if (mode != null && maintCtrl.maintenance[mode] == true) return null;
        }
        return '/account-entry';
      }
      if (isAuthenticated && state.matchedLocation == RouteNames.chooseUsage) {
        return '/account-entry';
      }
      if (!isAuthenticated && !isAuthRoute && !isSplash && !isReentry) {
        return RouteNames.login;
      }

      final path = state.matchedLocation;
      final debtOperation = path == '/debts/operation';
      final localDebtInvoice = (path == RouteNames.invoicesView || debtOperation) &&
          state.extra is DirectoryDebtInvoiceReference;
      final localDebtsList =
          path == '/debts/customers' || path == '/debts/suppliers';
      final cashAlerts = path == '/debts/notifications' || path == '/debt-notifications';
      final bankPage = path == '/banks' || path.startsWith('/banks/');
      final extra = state.extra;
      final localBankScope = bankPage
          ? ref.read(businessLocalLedgerScopeProvider)
          : null;
      final commerceScope = _isLocalCommerceRoute(path)
          ? ref.read(businessLocalLedgerScopeProvider)
          : null;
      final commerceFallback = commerceDocumentRoutes[path];
      if (extra is LocalCommerceTarget) {
        if (!extra.allows(commerceScope, path) || state.uri.hasQuery) {
          return commerceFallback ?? RouteNames.dashboard;
        }
      } else if (commerceScope != null &&
          commerceFallback != null &&
          !localDebtInvoice) {
        final query = state.uri.queryParameters;
        // The create screens can open without a saved document.
        final newProduct =
            path == RouteNames.inventoryProductEdit && !query.containsKey('id');
        final newReturn =
            path == RouteNames.returnsAdd && !query.containsKey('invoice');
        if (!newProduct && !newReturn) {
          return commerceFallback;
        }
      }
      if (path == LocalBankAccountTarget.path) {
        if (extra is! LocalBankAccountTarget ||
            !extra.allows(localBankScope) ||
            state.uri.hasQuery) {
          return '/banks';
        }
      } else if (extra is LocalBankAccountTarget ||
          (localBankScope != null && path.startsWith('/banks/account/'))) {
        return '/banks';
      }
      final directoryAccess = localDebtInvoice || debtOperation || localDebtsList ||
               cashAlerts || bankPage || path == '/business/income-expense'
          ? ref.read(businessLocalLedgerScopeProvider)
           : commerceScope ?? (_isDirectoryRoute(path)
           ? ref.read(directoryPilotAccessProvider)
           : null);
      if (localDebtInvoice ||
          (debtOperation && ref.read(directoryPilotAccessProvider) != null)) {
        final target = state.extra is DirectoryDebtInvoiceReference
            ? state.extra as DirectoryDebtInvoiceReference
            : null;
        try {
          if (target == null || state.uri.hasQuery) {
            throw const DirectoryAccessDenied();
          }
          target.party.requireScope(directoryAccess);
        } on DirectoryAccessDenied {
          return target?.party.kind == DirectoryPartyKind.supplier
              ? RouteNames.suppliers : RouteNames.customers;
        }
      }
      if (_directoryPartyRoutes.contains(path)) {
        final target = state.extra;
        final hasTarget = target is DirectoryPartyReference ||
            target is DirectoryDebtGroupReference;
        if (directoryAccess != null || hasTarget) {
          final party = path == '/debts/party-section'
              ? (target is DirectoryDebtGroupReference ? target.party : null)
              : (target is DirectoryPartyReference ? target : null);
          // This branch has no server-side directory. Restoring a URL without
          // its scoped target must not send an arbitrary ID to the old API.
          try {
            if (party == null ||
                (path == '/customers/detail' && party.kind != DirectoryPartyKind.customer) ||
                (path == '/suppliers/detail' && party.kind != DirectoryPartyKind.supplier)) {
              throw const DirectoryAccessDenied();
            }
            party.requireScope(directoryAccess);
          } on DirectoryAccessDenied {
            return path == '/suppliers/detail' ||
                    party?.kind == DirectoryPartyKind.supplier
                ? RouteNames.suppliers
                : RouteNames.customers;
          }
        }
      }
      final section = path.startsWith('/personal')
          ? 'personal'
          : (path == RouteNames.dashboard || path == '/business-setup' ||
                directoryAccess != null)
          ? 'business'
          : null;
      final invitedWorkspaceAccess = shouldUseInvitedWorkspaceAccess(
        section: section,
        isSetupRoute: isSetupRoute,
        workspaceOrganizationId: BranchScope.organizationId,
        userOrganizationId: authState.user?.organizationId,
        hasMembership: BranchScope.hasMembership,
      );
      String? personalAccessStatus;
      if (isAuthenticated &&
          section != null &&
          !invitedWorkspaceAccess &&
          !(authState.user?.isPlatformAdmin ?? false)) {
        final user = authState.user;
        Map<String, dynamic>? snapshot;
        try {
          if (section == 'personal' && user != null) {
            final connectivity = ref.read(connectivityServiceProvider);
            snapshot = await resolvePersonalEntry(
              connected: connectivity.isOnline,
              live: () => _subscriptionForNavigation(ref),
              local: () => ref.read(personalOfflineAccessProvider).read(user),
            );
          } else if (directoryAccess != null) {
            final store = ref.read(directoryPilotStoreProvider);
            snapshot = await store.entry(directoryAccess);
            if (!sameDirectoryScope(directoryAccess, ref.read(directoryPilotAccessProvider))) {
              return '/account-entry';
            }
            final live = ref.read(subscriptionStatusProvider);
            final verified = live.asData?.value;
            // Seed the branch from a response already obtained by account
            // entry. Navigation in a local route never awaits a new request.
            if (verified != null) {
              if (snapshot == null || !hasSectionAccess(verified, 'business')) {
                await store.remember(directoryAccess, verified);
              }
              snapshot = verified;
            }
            if (verified == null &&
                (snapshot == null || path == RouteNames.dashboard)) {
              // A branch never opened online (or created offline) has no
              // branch copy yet: the account's saved Business status covers
              // every branch of the organization.
              final saved =
                  await ref.read(businessNavigationStatusProvider.future);
              if (saved != null &&
                  snapshot == null &&
                  hasSectionAccess(saved, 'business')) {
                await store.remember(directoryAccess, saved);
              }
              snapshot = path == RouteNames.dashboard ? saved : saved ?? snapshot;
            }
            if (!sameDirectoryScope(directoryAccess, ref.read(directoryPilotAccessProvider))) {
              return '/account-entry';
            }
          } else if (path == RouteNames.dashboard && user != null) {
            // The return from Personal and a local branch selection must not
            // wait for subscription HTTP. A live denial still takes priority.
            snapshot = await ref.read(businessNavigationStatusProvider.future);
            if (snapshot == null &&
                ref.read(connectivityServiceProvider).isOnline) {
              snapshot = await ref.read(subscriptionStatusProvider.future);
            }
          } else {
            snapshot = await _subscriptionForNavigation(ref);
          }
        } catch (_) {
          return '/account-entry';
        }
        if (snapshot == null) return '/account-entry';
        if (!hasSectionAccess(snapshot, section)) {
          final other = section == 'business' ? 'personal' : 'business';
          if (hasSectionAccess(snapshot, other)) return '/account-entry';
          return snapshot['status'] == 'pending'
              ? RouteNames.subscriptionPending
              : RouteNames.subscription;
        }
        if (section == 'personal') {
          // The per-section grant takes priority over a stale profile or the
          // aggregate plan status (another section can have a different plan).
          final entry = (snapshot['sections'] as Map)['personal'] as Map;
          personalAccessStatus = entry['plan'] == 'trial' ||
                  (entry['plan'] == null && snapshot['status'] == 'trial')
              ? 'trial'
              : 'active';
        }
        if (section == 'business' &&
            path != '/business-setup' &&
            snapshot['is_trial'] != true &&
            snapshot['business_setup_completed'] != true) {
          return '/business-setup';
        }
      }

      // Route Guard ظ„ظ„ط¹ط²ظ„ ط¨ظٹظ† ط´ط®طµظٹ ظˆط£ط¹ظ…ط§ظ„
      if (isAuthenticated && !isSetupRoute && !isAuthRoute) {
        final user = authState.user;
        if (user != null) {
          final role = user.role;
          final mode = user.preferredUsageMode;
          final requestedRoute = state.matchedLocation;

          // ط§ظ„ظ…ط³ط§ط±ط§طھ ط§ظ„ط¥ط¹ط¯ط§ط¯ظٹط© ظ…ط³ظ…ظˆط­ط© ظ„ظ„ط¬ظ…ظٹط¹
          if (requestedRoute == RouteNames.onboarding ||
              requestedRoute == RouteNames.subscription ||
              requestedRoute == RouteNames.phoneEntry)
            return null;

          // â”€â”€ Platform controls (admin): maintenance hierarchy APP > PERSONAL/BUSINESS > FEATURE â”€â”€
          final controls = ref.read(platformControlsProvider).valueOrNull;
          if (!isSetupRoute) {
            // If controls are still loading, check the cached version so
            // maintenance state is enforced from the very first navigation.
            final effectiveControls =
                controls ?? await PlatformControls.loadFromPrefs();
            if (effectiveControls != null && !isSetupRoute) {
              final isAdmin = (user.isPlatformAdmin ?? false);
              if (!isAdmin && !requestedRoute.startsWith('/maintenance')) {
                // APP MAINTENANCE â€” ط£ط¹ظ„ظ‰ ط£ظˆظ„ظˆظٹط©: ظٹظˆظ‚ظپ ظƒظ„ ط´ظٹط،
                if (effectiveControls.isAppMaintenance) {
                  return '${RouteNames.maintenance}?key=all';
                }
                // PERSONAL / BUSINESS full section maintenance
                final routeMode = requestedRoute.routeMode;
                if (routeMode != null &&
                    effectiveControls.maintenance[routeMode] == true) {
                  return '${RouteNames.maintenance}?key=$routeMode';
                }
                // FEATURE-LEVEL via disabled_buttons (ط£ط²ط±ط§ط± ط§ظ„ط´ط®طµظٹ ط§ظ„ط³ط¨ط¹ط©)
                if (!requestedRoute.startsWith('/settings') &&
                    !requestedRoute.startsWith('/profile')) {
                  if (effectiveControls.isRouteUnderMaintenance(
                    requestedRoute,
                  )) {
                    final hit =
                        effectiveControls.isFeatureDisabled(requestedRoute)
                        ? requestedRoute
                        : (routeMode ?? requestedRoute);
                    return '${RouteNames.maintenance}?key=$hit';
                  }
                }
              }
            }
          }

          // ط¥ط°ط§ mode ظ„ط³ظ‡ null (ظ…ط³طھط®ط¯ظ… ط¬ط¯ظٹط¯) â†’ ظ†ط³ظ…ط­ ط¨ط§ظ„ظ…ط³ط§ط±ط§طھ ط§ظ„ط¹ط§ظ…ط© ظˆظ„ظ€ /personal
          if (mode == null) {
            if (requestedRoute.startsWith('/personal') ||
                requestedRoute.startsWith('/subscription') ||
                requestedRoute.startsWith('/settings') ||
                requestedRoute.startsWith('/profile'))
              return null;
          }

          // طµظپط­ط© ط§ظ„طµظٹط§ظ†ط© ط§ظ„ظ…ط±ظƒط²ظٹط© ظ…ط³ظ…ظˆط­ط© ظ„ظƒظ„ ط§ظ„ظ…ط³طھط®ط¯ظ…ظٹظ† ط§ظ„ط´ط±ط¹ظٹظٹظ† (ظ„ط§ ط¥ط¹ط§ط¯ط©
          // طھظˆط¬ظٹظ‡ ظ„ظ‡ط§ ط£ط¨ط¯ط§ظ‹ â€” ظˆط¥ظ„ط§ ظˆظ‚ط¹ظ†ط§ ظپظٹ ط­ظ„ظ‚ط© maintenance â†” dashboard).
          if (requestedRoute.startsWith('/maintenance')) return null;

          if (!isRouteAllowed(requestedRoute, role, preferredUsageMode: mode)) {
            if (mode == 'personal') return RouteNames.personalDashboard;
            return RouteNames.dashboard;
          }

          // â”€â”€ Subscription Guard â”€â”€
           final memberWorkspace =
               (employeeSelfWorkspaceRoute(requestedRoute,
                       readOnly: state.uri.queryParameters['ro'] == '1') &&
                   ref.read(employeeDeviceSelectionProvider) != null) ||
               (BranchScope.hasMembership &&
               BranchScope.organizationId != null &&
               BranchScope.organizationId != user.organizationId &&
               (requestedRoute.routeMode == 'business' ||
                   requestedRoute.startsWith('/employee-profile')));
          if (!user.isAdmin && !isSetupRoute && !memberWorkspace) {
            // Live server status is authoritative: admin revoke/cancel must be
            // enforced instantly even when the cached user model still says
            // `active`. Falls back to the cached effective status when the
            // network snapshot is unavailable.
            final subStatus = ref
                .read(subscriptionStatusProvider)
                .valueOrNull?['status']
                ?.toString();
            final effective =
                personalAccessStatus ??
                ((subStatus != null && subStatus.isNotEmpty)
                    ? subStatus
                    : user.effectiveStatus);
            // Treat a server "cancelled" response as expired so the user is
            // pushed back to the paywall the moment the admin revokes.
            final effectiveNorm = effective == 'cancelled'
                ? 'expired'
                : effective;
            // Force-paid mode (admin): trial is off, everyone must pay.
            final subControls =
                ref.read(platformControlsProvider).valueOrNull ??
                await PlatformControls.loadFromPrefs();
            if (subControls?.forcePaidSubscription == true &&
                effectiveNorm != 'active' &&
                requestingNonPaywall(requestedRoute)) {
              return RouteNames.subscription;
            }
            if (effectiveNorm == 'expired') {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        AppLocalizations.of(
                          context,
                        ).translate('routerSubExpired'),
                      ),
                      backgroundColor: AppColors.danger,
                      behavior: SnackBarBehavior.floating,
                      duration: const Duration(seconds: 4),
                    ),
                  );
                }
              });
              return RouteNames.subscription;
            }
            // Pending review = hard gate: the user may NOT leave the waiting
            // screen until the admin approves (â†’ invoice) or rejects (â†’ reason
            // view). Every other in-app route is funneled here, including on a
            // fresh app start (router runs again with the cached pending
            // status) so a restart can never bypass the gate.
            if (effective == 'pending' &&
                requestedRoute != RouteNames.subscriptionPending) {
              return RouteNames.subscriptionPending;
            }
          }
        }
      }

      return null;
    },
    routes: [
      GoRoute(
        path: RouteNames.splash,
        name: 'splash',
        builder: (_, _) => const DoubleBackToExit(child: SplashScreen()),
      ),
      GoRoute(
        path: RouteNames.login,
        name: 'login',
        pageBuilder: (_, state) => brandHandoffPage(
            state, const DoubleBackToExit(child: LoginPage())),
      ),
      GoRoute(
        path: RouteNames.maintenance,
        name: 'maintenance',
        builder: (_, _) => const MaintenancePage(),
      ),
      GoRoute(
        path: RouteNames.reentry,
        name: 'reentry',
        pageBuilder: (_, state) =>
            brandHandoffPage(state, const ReentryPage()),
      ),
      GoRoute(
        path: RouteNames.register,
        name: 'register',
        builder: (_, _) => const RegisterPage(),
      ),
      // E-mail verification no longer exists: the old path lands on the
      // phone OTP screen (which sends back to login without a challenge).
      GoRoute(
        path: RouteNames.verifyEmail,
        name: 'verifyEmail',
        redirect: (_, _) => RouteNames.authOtp,
      ),
      GoRoute(
        path: RouteNames.forgotPassword,
        name: 'forgotPassword',
        builder: (_, _) => const ForgotPasswordPage(),
      ),
      GoRoute(
        path: RouteNames.authOtp,
        name: 'authOtp',
        builder: (_, _) => const OtpPage(),
      ),
      GoRoute(
        path: RouteNames.verifyDevice,
        name: 'verifyDevice',
        builder: (_, _) => const VerifyDevicePage(),
      ),
      GoRoute(
        path: RouteNames.socialPhone,
        name: 'socialPhone',
        builder: (_, _) => const SocialPhonePage(),
      ),
      GoRoute(
        path: RouteNames.resetPassword,
        name: 'resetPassword',
        builder: (_, _) => const ResetPasswordPage(),
      ),
      // Trusted devices / sign-in approvals / phone change (signed in).
      GoRoute(
        path: RouteNames.securityDevices,
        name: 'securityDevices',
        builder: (_, _) => const DevicesPage(),
      ),
      GoRoute(
        path: RouteNames.securityApprovals,
        name: 'securityApprovals',
        builder: (_, state) =>
            ApprovalsPage(focusId: state.uri.queryParameters['id']),
      ),
      GoRoute(
        path: RouteNames.changePhone,
        name: 'changePhone',
        builder: (_, _) => const ChangePhonePage(),
      ),
      GoRoute(
        path: RouteNames.chooseUsage,
        name: 'chooseUsage',
        builder: (_, _) => const ChooseUsagePage(),
      ),
      GoRoute(
        path: '/account-entry',
        pageBuilder: (_, state) =>
            brandHandoffPage(state, const AccountEntryPage()),
      ),
      GoRoute(
        path: '/business-setup',
        builder: (_, _) => const BusinessSetupPage(),
      ),
      GoRoute(
        path: RouteNames.onboarding,
        name: 'onboarding',
        builder: (_, _) => const OnboardingPage(),
      ),

      // â”€â”€ Protected Shell â”€â”€
      GoRoute(
        path: '/employee-profile/receipt',
        builder: (_, state) => EmployeeDeviceFinanceRuntime(
          child: EmployeeFinanceReceiptPage(
            employeeId: state.uri.queryParameters['employee_id'] ?? '',
            recordId: state.uri.queryParameters['record_id'] ?? '',
            kind: state.uri.queryParameters['kind'] ?? '',
          ),
        ),
      ),
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        // Crossfades in when opened from the branded entry (else default).
        pageBuilder: (context, state, child) =>
            brandHandoffPage(state, MainShell(child: child)),
        routes: [
          GoRoute(
            path: RouteNames.dashboard,
            name: 'dashboard',
            builder: (_, _) => const BusinessDashboardPage(),
          ),
          GoRoute(
            path: '/banks',
            name: 'businessBanks',
            builder: (_, _) => const BusinessBanksPage(),
          ),
          GoRoute(
            path: '/banks/detail',
            name: 'businessBankDetail',
            builder: (_, state) {
              return BusinessBankDetailPage(
                bankName: state.uri.queryParameters['bankName'] ?? '',
                groupId: state.uri.queryParameters['groupId'],
                initialCurrency: state.uri.queryParameters['currency'],
              );
            },
          ),
          GoRoute(
            path: LocalBankAccountTarget.path,
            builder: (_, state) => BusinessAccountDetailPage(
              localAccount: state.extra as LocalBankAccountTarget,
            ),
          ),
          GoRoute(
            path: '/banks/account/:id',
            name: 'businessAccountDetail',
            builder: (_, state) {
              return BusinessAccountDetailPage(
                accountId: state.pathParameters['id'] ?? '',
              );
            },
          ),
          GoRoute(
            path: RouteNames.sales,
            name: 'sales',
            builder: (_, _) => const SaleInvoicesPage(),
          ),
          // ── Reconciliation (قسم المطابقة) ──
          GoRoute(
            path: RouteNames.reports,
            name: 'reports',
            builder: (_, _) => const ReportsHubPage(),
          ),
          GoRoute(
            path: RouteNames.reportsView,
            name: 'reportsView',
            builder: (_, state) {
              final q = state.uri.queryParameters;
              return ReportViewPage(
                kind: q['kind'] ?? 'overview',
                currency: q['currency'],
                period: q['period'],
                from: q['from'],
                to: q['to'],
                autoStart: q['autostart'] == '1',
              );
            },
          ),
          GoRoute(
            path: RouteNames.reconciliation,
            name: 'reconciliation',
            builder: (_, _) => const ReconciliationHomePage(),
          ),
          GoRoute(
            path: RouteNames.reconciliationBank,
            name: 'reconciliationBank',
            builder: (_, _) => const ReconAccountsPage(),
          ),
          GoRoute(
            path: RouteNames.reconciliationBankSelect,
            name: 'reconciliationBankSelect',
            builder: (_, state) {
              return ReconBankSelectPage(
                accountIds: state.uri.queryParameters['ids'] ?? '',
                localLink: state.extra is LocalReconciliationLink
                    ? state.extra as LocalReconciliationLink : null,
              );
            },
          ),
          GoRoute(
            path: RouteNames.reconciliationBankRun,
            name: 'reconciliationBankRun',
            builder: (_, state) {
              return ReconBankRunPage(
                accountIds: state.uri.queryParameters['ids'] ?? '',
                localLink: state.extra is LocalReconciliationLink
                    ? state.extra as LocalReconciliationLink : null,
              );
            },
          ),
          GoRoute(
            path: RouteNames.reconciliationBankResult,
            name: 'reconciliationBankResult',
            builder: (_, state) {
              final extra = state.extra as Map? ?? const {};
              return ReconBankResultPage(
                record: Map<String, dynamic>.from(
                  (extra['record'] as Map?) ?? const {},
                ),
                localSource: extra['source'] as ReconciliationApi?,
              );
            },
          ),
          GoRoute(
            path: RouteNames.reconciliationInventoryPick,
            name: 'reconciliationInventoryPick',
            builder: (_, state) {
              return ReconInventoryPickPage(
                scope: state.uri.queryParameters['scope'] ?? 'product',
              );
            },
          ),
          GoRoute(
            path: RouteNames.reconciliationInventoryResult,
            name: 'reconciliationInventoryResult',
            builder: (_, state) {
              final extra = state.extra as Map? ?? const {};
              return ReconInventoryResultPage(
                record: Map<String, dynamic>.from(
                  (extra['record'] as Map?) ?? const {},
                ),
                localLink: extra['local'] is LocalReconciliationLink
                    ? extra['local'] as LocalReconciliationLink
                    : null,
              );
            },
          ),
          GoRoute(
            path: RouteNames.reconciliationInventory,
            name: 'reconciliationInventory',
            builder: (_, _) => const ReconInventoryScopePage(),
          ),
          GoRoute(
            path: '/reconciliation/inventory/count',
            name: 'reconciliationCount',
            builder: (_, state) {
              final extra = state.extra;
              final record = extra is Map ? extra['record'] ?? extra : const {};
              return ReconInventoryCountPage(
                record: Map<String, dynamic>.from(record as Map),
                localLink: extra is Map && extra['local'] is LocalReconciliationLink
                    ? extra['local'] as LocalReconciliationLink
                    : null,
              );
            },
          ),
          GoRoute(
            path: RouteNames.reconciliationArchive,
            name: 'reconciliationArchive',
            builder: (_, _) => const ReconArchivePage(),
          ),
          GoRoute(
            path: '/reconciliation/detail',
            name: 'reconciliationDetail',
            builder: (_, state) {
              return ReconDetailPage(
                reconId: state.uri.queryParameters['id'] ?? '',
                localLink: state.extra is LocalReconciliationLink
                    ? state.extra as LocalReconciliationLink : null,
              );
            },
          ),
          GoRoute(
            path: RouteNames.businessTransactions,
            name: 'businessTransactions',
            builder: (_, _) => const BusinessTransactionsPage(),
          ),
          GoRoute(
            path: RouteNames.businessIncomeExpense,
            name: 'businessIncomeExpense',
            builder: (_, _) => const BusinessIncomeExpensePage(),
          ),
          GoRoute(
            path: RouteNames.businessTransactionDetails,
            name: 'businessTransactionDetails',
            builder: (_, state) {
              final extra = state.extra;
              final target = extra is LocalCommerceTarget ? extra : null;
              return BusinessTransactionDetailsPage(
                sourceType: target?.kind ?? state.uri.queryParameters['source'] ?? '',
                sourceId: target?.id ?? state.uri.queryParameters['id'] ?? '',
                localTarget: target,
              );
            },
          ),
          GoRoute(
            path: RouteNames.salesAdd,
            name: 'salesAdd',
            builder: (_, state) => SaleInvoicePage(
              prefillCustomerId: state.uri.queryParameters['customer'],
              prefillGroupId: state.uri.queryParameters['group'],
              debtMode: state.uri.queryParameters['debt'] == '1',
            ),
          ),
          GoRoute(
            path: RouteNames.salesView,
            name: 'salesView',
            builder: (_, state) {
              final extra = state.extra;
              final target = extra is LocalCommerceTarget ? extra : null;
              // Legacy link → the real Business invoice screen.
              return InvoiceViewPage(
                type: 'sale',
                id: target?.id ?? state.uri.queryParameters['id'] ?? '',
                localCommerce: target == null ? null : LocalCommerceTarget(
                    target.scope, RouteNames.invoicesView, target.id, kind: 'sale'),
              );
            },
          ),
          GoRoute(
            path: RouteNames.purchasesAdd,
            name: 'purchasesAdd',
            builder: (_, state) => PurchaseInvoicePage(
              prefillSupplierId: state.uri.queryParameters['supplier'],
              prefillGroupId: state.uri.queryParameters['group'],
              debtMode: state.uri.queryParameters['debt'] == '1',
            ),
          ),
          GoRoute(
            path: RouteNames.purchasesView,
            name: 'purchasesView',
            builder: (_, state) {
              final extra = state.extra;
              final target = extra is LocalCommerceTarget ? extra : null;
              // Legacy link → the real Business invoice screen.
              return InvoiceViewPage(
                type: 'purchase',
                id: target?.id ?? state.uri.queryParameters['id'] ?? '',
                localCommerce: target == null ? null : LocalCommerceTarget(
                    target.scope, RouteNames.invoicesView, target.id, kind: 'purchase'),
              );
            },
          ),
          GoRoute(
            path: RouteNames.returns,
            name: 'returns',
            builder: (_, _) => const ReturnsPage(),
          ),
          GoRoute(
            path: RouteNames.returnsAdd,
            name: 'returnsAdd',
            builder: (_, state) {
              final extra = state.extra;
              final target = extra is LocalCommerceTarget ? extra : null;
              return ReturnCreatePage(
                kind: target?.kind ?? state.uri.queryParameters['kind'] ?? 'sale_return',
                initialInvoiceId: target?.id ?? state.uri.queryParameters['invoice'] ?? '',
                localTarget: target,
              );
            },
          ),
          GoRoute(
            path: RouteNames.returnsView,
            name: 'returnsView',
            builder: (_, state) {
              final extra = state.extra;
              final target = extra is LocalCommerceTarget ? extra : null;
              return ReturnViewPage(
                kind: target?.kind ?? state.uri.queryParameters['kind'] ?? 'sale_return',
                id: target?.id ?? state.uri.queryParameters['id'] ?? '',
                localTarget: target,
              );
            },
          ),
          GoRoute(
            path: RouteNames.returnsPickInvoice,
            name: 'returnsPickInvoice',
            builder: (_, state) {
              return InvoicePickerPage(
                kind: state.uri.queryParameters['kind'] ?? 'sale_return',
              );
            },
          ),
          GoRoute(
            path: RouteNames.invoices,
            name: 'invoices',
            builder: (_, _) => const InvoicesListPage(),
          ),
          GoRoute(
            path: RouteNames.invoicesView,
            name: 'invoicesView',
            builder: (_, state) {
              final local = state.extra;
              if (local is DirectoryDebtInvoiceReference) {
                return InvoiceViewPage(
                  type: local.party.kind == DirectoryPartyKind.supplier ? 'purchase' : 'sale',
                  id: '',
                  localOpeningInvoice: local,
                );
              }
               return InvoiceViewPage(
                 type: (local is LocalCommerceTarget ? local.kind : null) ??
                     state.uri.queryParameters['type'] ?? 'sale',
                 id: local is LocalCommerceTarget ? local.id : state.uri.queryParameters['id'] ?? '',
                 localCommerce: local is LocalCommerceTarget ? local : null,
              );
            },
          ),
          GoRoute(
            path: RouteNames.invoicesDesign,
            name: 'invoicesDesign',
            builder: (_, _) => const InvoiceDesignHubPage(),
          ),
          GoRoute(
            path: RouteNames.invoicesDesignEdit,
            name: 'invoicesDesignEdit',
            builder: (_, state) {
              return InvoiceDesignEditorPage(
                templateId: state.uri.queryParameters['template'] ?? 'paper',
              );
            },
          ),
          GoRoute(
            path: '/employees',
            name: 'employees',
            builder: (_, _) => const EmployeesPage(),
          ),
          GoRoute(
            path: '/employees/add',
            name: 'employeesAdd',
            builder: (_, _) => const EmployeeFormPage(),
          ),
          GoRoute(
            path: '/employees/edit',
            name: 'employeesEdit',
            builder: (_, state) =>
                EmployeeFormPage(id: state.uri.queryParameters['id']),
          ),
          GoRoute(
            path: '/employees/detail',
            name: 'employeesDetail',
            builder: (_, state) =>
                EmployeeDetailPage(id: state.uri.queryParameters['id'] ?? ''),
          ),
          GoRoute(
            path: '/job-requests',
            name: 'jobRequests',
            builder: (_, state) =>
                JobRequestsPage(inviteId: state.uri.queryParameters['invite']),
          ),
          GoRoute(
            path: '/employee-profile',
            name: 'employeeProfile',
            builder: (_, _) => const EmployeeProfilePage(),
          ),
          GoRoute(
            path: '/business/backup',
            builder: (_, _) => const BusinessBackupPage(),
          ),
          // Smart import (also opened by Sara): its own full-screen window.
          GoRoute(
            path: RouteNames.smartImport,
            pageBuilder: (_, state) => MaterialPage<void>(
              key: state.pageKey,
              fullscreenDialog: true,
              child: const SmartImportPage(),
            ),
          ),
          GoRoute(
            path: '/employees/salary',
            name: 'employeeSalary',
            builder: (_, state) => EmployeeSalaryPage(
              employeeId: state.uri.queryParameters['id'] ?? '',
              employeeName: _dec(state.uri.queryParameters['name']) ?? '',
              organizationName: state.uri.queryParameters['org'],
              readOnly: state.uri.queryParameters['ro'] == '1',
            ),
          ),
          GoRoute(
            path: '/employees/debts',
            name: 'employeeDebts',
            builder: (_, state) => EmployeeDebtsPage(
              employeeId: state.uri.queryParameters['id'] ?? '',
              employeeName: _dec(state.uri.queryParameters['name']) ?? '',
              organizationName: state.uri.queryParameters['org'],
              readOnly: state.uri.queryParameters['ro'] == '1',
            ),
          ),
          GoRoute(
            path: RouteNames.debts,
            name: 'debts',
            builder: (_, _) => const BusinessDebtsPage(),
          ),
          GoRoute(
            path: '/debts/customers',
            name: 'debtsCustomers',
            builder: (_, _) => const CustomersPage(debtsContext: true),
          ),
          GoRoute(
            path: '/debts/suppliers',
            name: 'debtsSuppliers',
            builder: (_, _) => const SuppliersPage(debtsContext: true),
          ),
          GoRoute(
            path: RouteNames.customers,
            name: 'customers',
            builder: (_, _) => const CustomersPage(),
          ),
          GoRoute(
            path: RouteNames.suppliers,
            name: 'suppliers',
            builder: (_, _) => const SuppliersPage(),
          ),
          GoRoute(
            path: '/customers/detail',
            name: 'customerDetail',
            builder: (_, state) {
              final name = state.uri.queryParameters['name'];
              return PartyDetailPage(
                id: state.uri.queryParameters['id'] ?? '',
                isSupplier: false,
                fallbackName: _dec(name),
                localParty: state.extra is DirectoryPartyReference
                    ? state.extra as DirectoryPartyReference : null,
              );
            },
          ),
          GoRoute(
            path: '/suppliers/detail',
            name: 'supplierDetail',
            builder: (_, state) {
              final name = state.uri.queryParameters['name'];
              return PartyDetailPage(
                id: state.uri.queryParameters['id'] ?? '',
                isSupplier: true,
                fallbackName: _dec(name),
                localParty: state.extra is DirectoryPartyReference
                    ? state.extra as DirectoryPartyReference : null,
              );
            },
          ),
          GoRoute(
            path: '/debts/party-individual',
            name: 'debtsPartyIndividual',
            builder: (_, state) => PartyDebtsPage(
              partyKind: state.uri.queryParameters['kind'] ?? 'customer',
              partyId: state.uri.queryParameters['id'] ?? '',
              name: _dec(state.uri.queryParameters['name']) ?? '' ?? '',
              localParty: state.extra is DirectoryPartyReference
                  ? state.extra as DirectoryPartyReference : null,
            ),
          ),
          GoRoute(
            path: '/debts/party-sections',
            name: 'debtsPartySections',
            builder: (_, state) => PartySectionsPage(
              partyKind: state.uri.queryParameters['kind'] ?? 'customer',
              partyId: state.uri.queryParameters['id'] ?? '',
              name: _dec(state.uri.queryParameters['name']) ?? '' ?? '',
              localParty: state.extra is DirectoryPartyReference
                  ? state.extra as DirectoryPartyReference : null,
            ),
          ),
          GoRoute(
            path: '/debts/party-section',
            name: 'debtsPartySection',
            builder: (_, state) => PartySectionPage(
              partyKind: state.uri.queryParameters['kind'] ?? 'customer',
              partyId: state.uri.queryParameters['id'] ?? '',
              name: _dec(state.uri.queryParameters['name']) ?? '' ?? '',
              groupId: state.uri.queryParameters['gid'] ?? '',
              groupName: _dec(state.uri.queryParameters['gname']) ?? '',
              localGroup: state.extra is DirectoryDebtGroupReference
                  ? state.extra as DirectoryDebtGroupReference : null,
            ),
          ),
          GoRoute(
            path: '/debts/operation',
            name: 'debtsOperation',
             builder: (_, state) {
               final extra = state.extra;
               if (extra is DirectoryDebtInvoiceReference) {
                 return DebtOperationDetailPage(
                   linkId: '', invoiceId: '', name: '', isBusiness: true,
                   localBusiness: BusinessLocalDebtOperation(extra),
                 );
               }
               return DebtOperationDetailPage(
                 linkId: '',
                 invoiceId: state.uri.queryParameters['inv'] ?? '',
                 name: _dec(state.uri.queryParameters['name']) ?? '',
                 partyKind: state.uri.queryParameters['kind'],
                 partyId: state.uri.queryParameters['id'],
                 isBusiness: true,
               );
             },
          ),
          GoRoute(
            path: RouteNames.inventory,
            name: 'inventory',
            builder: (_, _) => const InventoryHomePage(),
          ),

          GoRoute(
            path: RouteNames.inventorySettings,
            name: 'inventorySettings',
            builder: (_, _) => const WarehouseSettingsPage(),
          ),
          GoRoute(
            path: RouteNames.inventoryCategories,
            name: 'inventoryCategories',
            builder: (_, _) => const CategoriesPage(),
          ),
          GoRoute(
            path: RouteNames.inventoryCategoryDetail,
            name: 'inventoryCategoryDetail',
            builder: (_, state) {
              final extra = state.extra;
              final target = extra is LocalCommerceTarget ? extra : null;
              return CategoryDetailPage(
                id: target?.id ?? state.uri.queryParameters['id'] ?? '',
                localTarget: target,
              );
            },
          ),
          GoRoute(
            path: RouteNames.inventoryFalcon,
            name: 'inventoryFalcon',
            builder: (_, state) {
              final q = state.uri.queryParameters;
              return FalconPage(
                scope: q['scope'] ?? 'inventory',
                refId: q['id'],
                title: q['title'] ?? '',
              );
            },
          ),
          GoRoute(
            path: RouteNames.inventoryProductEdit,
            name: 'inventoryProductEdit',
            builder: (_, state) {
              final extra = state.extra;
              final target = extra is LocalCommerceTarget ? extra : null;
              return ProductFormPage(
                id: target?.id ?? state.uri.queryParameters['id'],
                initialBarcode: state.uri.queryParameters['barcode'],
                localTarget: target,
              );
            },
          ),
          GoRoute(
            path: RouteNames.inventoryProductMovements,
            name: 'inventoryProductMovements',
            builder: (_, state) {
              final extra = state.extra;
              final target = extra is LocalCommerceTarget ? extra : null;
              return ProductMovementsPage(
                id: target?.id ?? state.uri.queryParameters['id'] ?? '',
                localTarget: target,
              );
            },
          ),
          GoRoute(
            path: RouteNames.inventoryProduct,
            name: 'inventoryProduct',
            builder: (_, state) {
              final extra = state.extra;
              final target = extra is LocalCommerceTarget ? extra : null;
              return ProductDetailPage(
                id: target?.id ?? state.uri.queryParameters['id'] ?? '',
                localTarget: target,
              );
            },
          ),
          // Personal Finance
          GoRoute(
            path: RouteNames.personalDashboard,
            name: 'personal',
            builder: (_, _) => const PersonalDashboardPage(),
          ),
          GoRoute(
            path: RouteNames.personalSavings,
            name: 'personalSavings',
            builder: (_, _) => const SavingsGoalsPage(),
          ),
          GoRoute(
            path: RouteNames.personalMerchantAccounts,
            name: 'personalMerchantAccounts',
            builder: (_, _) => const MerchantAccountsPage(),
          ),
          GoRoute(
            path: RouteNames.personalMerchantPartner,
            name: 'personalMerchantPartner',
            builder: (_, state) => MerchantDebtOverviewPage(
              linkId: state.uri.queryParameters['link'] ?? '',
              merchantName: _dec(state.uri.queryParameters['name']) ?? '' ?? '',
              openOperationId: state.uri.queryParameters['op'],
              openRequestId: state.uri.queryParameters['req'],
            ),
          ),
          GoRoute(
            path: '/personal/debt-section',
            name: 'personalDebtSection',
            builder: (_, state) => DebtSectionPage(
              linkId: state.uri.queryParameters['link'] ?? '',
              groupId: state.uri.queryParameters['gid'] ?? '',
              name: _dec(state.uri.queryParameters['name']) ?? '' ?? '',
            ),
          ),
          GoRoute(
            path: '/personal/debt-operation',
            name: 'personalDebtOperation',
            builder: (_, state) => DebtOperationDetailPage(
              linkId: state.uri.queryParameters['link'] ?? '',
              invoiceId: state.uri.queryParameters['inv'] ?? '',
              name: _dec(state.uri.queryParameters['name']) ?? '' ?? '',
            ),
          ),
          GoRoute(
            path: '/personal/debt-invoice',
            name: 'personalDebtInvoice',
            builder: (_, state) => PersonalInvoiceDocumentPage(
              linkId: state.uri.queryParameters['link'] ?? '',
              invoiceId: state.uri.queryParameters['inv'] ?? '',
              name: _dec(state.uri.queryParameters['name']) ?? '' ?? '',
            ),
          ),
          GoRoute(
            path: '/personal/chat',
            name: 'personalChat',
            builder: (_, state) => ChatPage(
              linkId: state.uri.queryParameters['link'] ?? '',
              isMerchant: false,
              focusMessageId: state.uri.queryParameters['msg'],
            ),
          ),
          GoRoute(
            path: '/debts/chat',
            name: 'debtsChat',
            builder: (_, state) => ChatPage(
              linkId: state.uri.queryParameters['link'] ?? '',
              isMerchant: true,
              focusMessageId: state.uri.queryParameters['msg'],
            ),
          ),
          // Commercial-debt notification center — one per context. The paths
          // sit under the mode prefixes (/debts, /personal) so the route guard
          // (isRouteAllowed) never bounces them back to the home screen. The
          // legacy bare path is kept as an alias for older pushes/deep links.
          GoRoute(
            path: '/debts/notifications',
            name: 'debtsNotifications',
            builder: (_, state) => DebtNotificationsPage(
              linkId: state.uri.queryParameters['link'],
              partyName: _dec(state.uri.queryParameters['name']) ?? '',
              initialTab: state.uri.queryParameters['tab'] == 'alerts' ? 1 : 0,
            ),
          ),
          GoRoute(
            path: '/personal/debt-notifications',
            name: 'personalDebtNotifications',
            builder: (_, state) => DebtNotificationsPage(
              linkId: state.uri.queryParameters['link'],
              partyName: _dec(state.uri.queryParameters['name']) ?? '',
              isPersonal: true,
              initialTab: state.uri.queryParameters['tab'] == 'alerts' ? 3 : 0,
            ),
          ),
          GoRoute(
            path: '/debt-notifications',
            name: 'debtNotifications',
            builder: (_, _) => const DebtNotificationsPage(),
          ),
          // The old analytics screen was replaced by Personal › التقارير;
          // its link (drawer, help, Sara) keeps working.
          GoRoute(
            path: RouteNames.personalAnalytics,
            name: 'personalAnalytics',
            redirect: (_, _) => RouteNames.personalReports,
          ),
          GoRoute(
            path: RouteNames.personalBanks,
            name: 'personalBanks',
            builder: (_, state) {
              final extra = state.extra as Map<String, dynamic>?;
              return PersonalBanksPage(
                openTransfer: extra?['openTransfer'] == true,
              );
            },
          ),
          GoRoute(
            path: RouteNames.personalDebts,
            name: 'personalDebts',
            builder: (_, state) {
              final debtId = state.uri.queryParameters['debtId'];
              return PersonalDebtsPage(debtId: debtId);
            },
          ),
          GoRoute(
            path: RouteNames.personalTransactions,
            name: 'personalTransactions',
            builder: (_, state) {
              final initialTab = state.extra as int? ?? 0;
              return PersonalTransactionsPage(initialTab: initialTab);
            },
          ),
          // Sara's "log today's transactions" notification deep-link.
          GoRoute(
            path: '/personal/quick-add',
            name: 'personalSaraQuickAdd',
            builder: (_, state) => SaraQuickAddPage(
              type: SaraQuickAddPage.normalizeType(
                state.uri.queryParameters['type'],
              ),
            ),
          ),
          GoRoute(
            path: RouteNames.personalReportsCenter,
            name: 'personalReportsCenter',
            redirect: (_, _) => RouteNames.personalReports,
          ),
          GoRoute(
            path: RouteNames.personalReports,
            name: 'personalReports',
            builder: (_, _) => const PersonalReportsPage(),
          ),
          GoRoute(
            path: RouteNames.personalReportsView,
            name: 'personalReportsView',
            builder: (_, state) {
              final q = state.uri.queryParameters;
              return PersonalReportViewPage(
                kind: q['kind'] ?? 'overview',
                currency: q['currency'],
                period: q['period'],
                from: q['from'],
                to: q['to'],
                autoExport: q['export'] == '1',
              );
            },
          ),
          GoRoute(
            path: RouteNames.personalAi,
            name: 'personalAi',
            builder: (_, _) => const PersonalAiPage(),
          ),
          // Email
          GoRoute(
            path: '/email/settings',
            name: 'emailSettings',
            builder: (_, _) => const EmailSettingsPage(),
          ),
          GoRoute(
            path: '/email/compose',
            name: 'emailCompose',
            builder: (_, _) => const EmailComposePage(),
          ),
          // Notifications
          GoRoute(
            path: RouteNames.notifications,
            name: 'notifications',
            builder: (_, state) {
              final notifId = state.uri.queryParameters['id'];
              return NotificationListPage(notifId: notifId);
            },
          ),
          GoRoute(
            path: RouteNames.reminders,
            name: 'reminders',
            builder: (_, _) => ReminderListPage(),
          ),
          // Profile & Settings
          GoRoute(
            path: RouteNames.profile,
            name: 'profile',
            builder: (_, _) => const ProfilePage(),
          ),
          GoRoute(
            path: RouteNames.businessProfile,
            name: 'businessProfile',
            builder: (_, _) => const ProfilePage(business: true),
          ),
          GoRoute(
            path: RouteNames.changePassword,
            name: 'changePassword',
            builder: (_, _) => const ChangePasswordPage(),
          ),
          GoRoute(
            path: RouteNames.sessions,
            name: 'sessions',
            builder: (_, _) => const SessionsPage(),
          ),
          // AI & Suggestions
          GoRoute(
            path: RouteNames.ai,
            name: 'ai',
            builder: (_, _) => const AiAssistantPage(),
          ),
          GoRoute(
            path: RouteNames.aiSuggestions,
            name: 'aiSuggestions',
            builder: (_, _) => const AiSuggestionsPage(),
          ),
          // Suggestions (user submits, admin reviews)
          GoRoute(
            path: RouteNames.suggestions,
            name: 'suggestions',
            builder: (_, _) => SuggestionsPage(),
          ),
          // Personal Finance sub-screens
          GoRoute(
            path: RouteNames.personalTransfer,
            name: 'personalTransfer',
            builder: (_, _) => const PersonalTransferPage(),
          ),
          GoRoute(
            path: RouteNames.personalAccountTree,
            name: 'personalAccountTree',
            builder: (_, _) => const PersonalAccountTreePage(),
          ),
          GoRoute(
            path: RouteNames.financialTree,
            name: 'financialTree',
            builder: (_, _) => const TreeListPage(),
          ),
          GoRoute(
            path: RouteNames.personalExecutive,
            name: 'personalExecutive',
            builder: (_, _) => const PersonalExecutiveDashboardPage(),
          ),
          GoRoute(
            path: RouteNames.personalBankStatement,
            name: 'personalBankStatement',
            builder: (_, _) => const PersonalBankStatementPage(),
          ),
          GoRoute(
            path: RouteNames.personalAccountDetail,
            name: 'personalAccountDetail',
            builder: (_, state) => PersonalAccountDetailPage(
              accountId: state.pathParameters['id'] ?? '',
            ),
          ),
          GoRoute(
            path: RouteNames.personalBankDetail,
            name: 'personalBankDetail',
            builder: (_, state) => BankDetailPage(
              bankName: state.pathParameters['bankName'] ?? '',
              initialCurrency: state.uri.queryParameters['currency'],
            ),
          ),
          GoRoute(
            path: RouteNames.personalSavingsDetail,
            name: 'personalSavingsDetail',
            builder: (_, state) => SavingsGoalDetailPage(
              goalId: state.pathParameters['goalId'] ?? '',
            ),
          ),
          GoRoute(
            path: RouteNames.personalAllBanksReport,
            name: 'personalAllBanksReport',
            builder: (_, _) => const AllBanksReportPage(),
          ),
          GoRoute(
            path: RouteNames.personalFinanceOverview,
            name: 'personalFinanceOverview',
            builder: (_, _) => const FinanceOverviewPage(),
          ),
          GoRoute(
            path: RouteNames.personalBudget,
            name: 'personalBudget',
            builder: (_, _) => const PersonalBudgetPage(),
          ),
          GoRoute(
            path: '/personal/budget/add',
            name: 'personalBudgetAdd',
            builder: (_, _) => const PersonalBudgetFormPage(),
          ),
          GoRoute(
            path: '/personal/budget/edit',
            name: 'personalBudgetEdit',
            builder: (_, _) => const PersonalBudgetFormPage(),
          ),
          GoRoute(
            path: RouteNames.personalBudgetDetail,
            name: 'personalBudgetDetail',
            builder: (context, state) {
              PersonalBudget? budget;
              final extra = state.extra;
              if (extra is PersonalBudget) {
                budget = extra;
              } else if (extra is Map<String, dynamic>) {
                if (extra['budget'] is PersonalBudget) {
                  budget = extra['budget'] as PersonalBudget;
                } else if (extra['budget'] is Map<String, dynamic>) {
                  budget = PersonalBudget.fromJson(
                    extra['budget'] as Map<String, dynamic>,
                  );
                }
              }
              if (budget == null) {
                return _BudgetDetailFallback(
                  budgetId: state.uri.queryParameters['id'],
                );
              }
              return BudgetDetailPage(budget: budget);
            },
          ),
          GoRoute(
            path: RouteNames.personalRecurring,
            name: 'personalRecurring',
            builder: (_, _) => const PersonalRecurringPage(),
          ),
          GoRoute(
            path: RouteNames.personalRecurringDetail,
            name: 'personalRecurringDetail',
            builder: (_, state) {
              final rt = state.extra as RecurringTransaction?;
              final id = state.uri.queryParameters['id'];
              return PersonalRecurringDetailPage(
                transaction: rt,
                transactionId: id,
              );
            },
          ),
          GoRoute(
            path: RouteNames.personalRecurringAdd,
            name: 'personalRecurringAdd',
            builder: (_, _) => const PersonalRecurringFormPage(),
          ),
          GoRoute(
            path: RouteNames.personalRecurringEdit,
            name: 'personalRecurringEdit',
            builder: (_, _) => const PersonalRecurringFormPage(),
          ),
          GoRoute(
            path: RouteNames.personalCategories,
            name: 'personalCategories',
            builder: (_, _) => const PersonalCategoriesPage(),
          ),
          GoRoute(
            path: '/personal/categories/add',
            name: 'personalCategoryAdd',
            builder: (_, _) => const PersonalCategoryFormPage(),
          ),
          GoRoute(
            path: '/personal/categories/edit',
            name: 'personalCategoryEdit',
            builder: (_, _) => const PersonalCategoryFormPage(),
          ),
          // Personal Receipt Design
          GoRoute(
            path: '/personal/receipt-design',
            name: 'receiptDesignHub',
            builder: (_, _) => const ReceiptDesignHubPage(),
          ),
          GoRoute(
            path: '/personal/receipt-design/edit',
            name: 'receiptDesignEditor',
            builder: (_, state) => ReceiptDesignEditorPage(
              section: state.extra as PersonalReceiptSection,
            ),
          ),
          // Personal Backup
          GoRoute(
            path: RouteNames.personalBackup,
            name: 'personalBackup',
            builder: (_, _) => const BackupPage(),
          ),
          // Settings Sub-screens
          GoRoute(
            path: RouteNames.settings,
            name: 'settings',
            builder: (_, _) => const SettingsPage(),
          ),
          GoRoute(
            path: '/branches',
            name: 'branches',
            builder: (_, _) => const BranchesPage(),
          ),
          GoRoute(
            path: '/branches/transfers',
            name: 'branchTransfers',
            builder: (_, state) =>
                BranchTransfersPage(initialId: state.uri.queryParameters['id']),
          ),
          GoRoute(
            path: '/branches/transfers/:id',
            name: 'branchTransferDetail',
            builder: (_, state) =>
                BranchTransfersPage(initialId: state.pathParameters['id']),
          ),
          GoRoute(
            path: '/branches/invitations',
            name: 'branchInvitations',
            builder: (_, state) => BranchInvitationsPage(
              initialInvite: state.uri.queryParameters['invite'],
            ),
          ),
          GoRoute(
            path: '/branches/members',
            name: 'branchMembers',
            builder: (_, _) => const BranchMembersPage(),
          ),
          GoRoute(
            path: RouteNames.settingsCompany,
            name: 'companySettings',
            builder: (_, _) => const CompanySettingsPage(),
          ),
          GoRoute(
            path: RouteNames.settingsTaxes,
            name: 'taxSettings',
            builder: (_, _) => TaxSettingsPage(),
          ),
          GoRoute(
            path: RouteNames.settingsCurrencies,
            name: 'currencySettings',
            builder: (_, _) => CurrencySettingsPage(),
          ),
          GoRoute(
            path: '/settings/custom-fields',
            name: 'customFields',
            builder: (_, _) => CustomFieldsPage(),
          ),
          GoRoute(
            path: '/settings/customization',
            name: 'customization',
            builder: (_, _) => const CustomizationPage(),
          ),
          GoRoute(
            path: '/design/invoice',
            name: 'invoiceDesign',
            builder: (_, _) => const InvoiceDesignStudio(),
          ),
          GoRoute(
            path: '/design/report',
            name: 'reportDesign',
            builder: (_, _) => const ReportDesignStudio(),
          ),
          GoRoute(
            path: '/design/brand',
            name: 'brandDesign',
            builder: (_, _) => const BrandDesignStudio(),
          ),
          GoRoute(
            path: '/design/print',
            name: 'printDesign',
            builder: (_, _) => const PrintDesignStudio(),
          ),
          GoRoute(
            path: '/settings/files',
            name: 'files',
            builder: (_, _) => const FilesPage(),
          ),
          GoRoute(
            path: '/settings/email-logs',
            name: 'emailLogs',
            builder: (_, _) => const EmailLogsPage(),
          ),
          GoRoute(
            path: '/settings/email-templates',
            name: 'emailTemplates',
            builder: (_, _) => EmailTemplatesPage(),
          ),
        ],
      ),
      // â”€â”€ Full-screen flows (no bottom nav) â”€â”€
      GoRoute(
        path: RouteNames.mfaSetup,
        name: 'mfaSetup',
        builder: (_, _) => MfaSetupPage(),
      ),
      GoRoute(
        path: RouteNames.mfaVerify,
        name: 'mfaVerify',
        builder: (_, state) =>
            MfaVerifyPage(mfaToken: state.pathParameters['token']),
      ),
      GoRoute(
        path: RouteNames.subscription,
        name: 'subscription',
        builder: (_, state) => PlansPage(packageFilter: state.uri.queryParameters['package']),
      ),
      GoRoute(
        path: RouteNames.phoneEntry,
        name: 'phoneEntry',
        builder: (_, state) => PhoneEntryPage(
          isMandatory: state.uri.queryParameters['mandatory'] == 'true',
        ),
      ),
      GoRoute(
        path: RouteNames.subscriptionPay,
        name: 'subscriptionPay',
        builder: (_, state) => PaymentPage(
          planId: state.uri.queryParameters['plan_id'] ?? '',
          planName: state.uri.queryParameters['plan_name'] ?? '',
          planPrice: state.uri.queryParameters['plan_price'] ?? '',
          planCurrency: state.uri.queryParameters['plan_currency'] ?? '',
          period: state.uri.queryParameters['period'] ?? 'monthly',
        ),
      ),
      GoRoute(
        path: RouteNames.subscriptionPending,
        name: 'subscriptionPending',
        builder: (_, state) => const SubscriptionPendingPage(),
      ),
      GoRoute(
        path: RouteNames.subscriptionRejected,
        name: 'subscriptionRejected',
        builder: (_, state) => SubscriptionRejectedPage(
          reason: state.uri.queryParameters['reason'],
        ),
      ),
      GoRoute(
        path: RouteNames.subscriptionInvoice,
        name: 'subscriptionInvoice',
        builder: (_, state) {
          final qp = state.uri.queryParameters;
          return SubscriptionInvoiceScreen(
            planName:
                qp['plan'] ??
                (qp['plan_name']?.isNotEmpty == true ? qp['plan_name'] : null),
            amount:
                parseFormattedAmount(qp['amount']) ??
                parseFormattedAmount(qp['plan_price']),
            currency:
                qp['currency'] ??
                (qp['plan_currency']?.isNotEmpty == true
                    ? qp['plan_currency']
                    : null),
            method:
                qp['method'] ??
                (qp['payment_method']?.isNotEmpty == true
                    ? qp['payment_method']
                    : null),
            invoiceNo: qp['invoice_no'],
            period: qp['period'],
            start: qp['start'],
            end: qp['end'],
            bank: qp['bank'],
            card: qp['card'],
          );
        },
      ),
      GoRoute(
        path: RouteNames.subscriptionUpdateCard,
        name: 'subscriptionUpdateCard',
        builder: (_, state) {
          final qp = state.uri.queryParameters;
          final plan = qp['plan'] ?? qp['plan_name'];
          final period = qp['period'];
          return AutoRenewSheet(
            planName: (plan != null && plan.isNotEmpty) ? plan : null,
            period: (period == 'monthly' || period == 'yearly')
                ? period!
                : 'yearly',
          );
        },
      ),
    ],
    errorBuilder: (context, state) {
      // Any unknown route (e.g. stale /splas) â†’ redirect to splash instead of
      // showing a dead-end 404. This handles old shortcuts/launcher state.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          // Use GoRouter's context to go to splash; if already on splash, do nothing.
          // ignore: use_build_context_synchronously
          if (state.uri.toString() != RouteNames.splash)
            context.go(RouteNames.splash);
        } catch (_) {}
      });
      // Same branded entry as the splash/account entry (no spinner).
      return const Scaffold(
        backgroundColor: BrandEntryView.background,
        body: BrandEntryView(),
      );
    },
  );

  ref.listen(authProvider, (_, __) => router.refresh());
  if (DirectoryPilotBuild.enabled) {
    ref.listen(branchEpochProvider, (_, __) {
      if (!router.routeInformationProvider.value.uri.path.startsWith('/personal')) {
        router.refresh();
      }
    });
  }
  return router;
});

class MainShell extends ConsumerStatefulWidget {
  final Widget child;
  const MainShell({super.key, required this.child});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell>
    with WidgetsBindingObserver {
  DateTime? _lastBackPress;
  Timer? _controlsTimer;
  Timer? _subTimer;
  Timer? _presenceTimer;
  Timer? _workspaceTimer;
  StreamSubscription<bool>? _connectivitySub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !ref.read(authProvider).isAuthenticated) return;
      try {
        NotificationRouter.flushPending();
      } catch (_) {}
      try {
        ref.read(fcmServiceProvider).flushPendingNavigation();
      } catch (_) {}
      try {
        ref.read(notificationServiceProvider).flushPendingTaps();
      } catch (_) {}
    });
    // Poll platform controls so admin changes (maintenance/buttons/force-paid)
    // apply immediately even while the user is browsing.
    ref.read(platformControlsProvider.notifier).refresh();
    // Poll frequently (3s) so admin maintenance/button toggles apply almost
    // instantly for all connected users (the router + listener below bounce
    // the user out right away, and re-enable the second it is turned off).
    // Never stack polls: on a poor link one request can outlive many ticks,
    // and piled-up requests starve the screens the user is opening. Offline
    // (or very poor) the cached controls stay in force; the connectivity
    // listener below refreshes them the moment the link is back.
    var controlsInFlight = false;
    _controlsTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (controlsInFlight ||
          !ref.read(connectivityServiceProvider).isOnline) return;
      controlsInFlight = true;
      ref
          .read(platformControlsProvider.notifier)
          .refresh()
          .whenComplete(() => controlsInFlight = false);
    });
    // Poll the LIVE subscription status so an admin revoke (cancel) is
    // enforced IMMEDIATELY â€” the user is bounced to the paywall even while
    // sitting inside the app, not only on the next navigation.
    _subTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      _checkSubscriptionEnforcement();
    });
    // App-wide presence heartbeat: while the app is OPEN the user is «online»
    // in chat (green). Backgrounding stops it → offline (red) after ~45s.
    _startPresence();
    _startWorkspaceChecks();
    // First enforcement check shortly after mount (before the router has had
    // its first chance to re-route after auth).
    Timer(const Duration(seconds: 4), _checkSubscriptionEnforcement);
    // طھط­ط¯ظٹط« ظپظˆط±ظٹ ط¹ظ†ط¯ ط¹ظˆط¯ط© ط§ظ„ط§طھطµط§ظ„
    final conn = ref.read(connectivityServiceProvider);
    conn.init();
    _connectivitySub = conn.onConnectivityChanged.listen((isOnline) {
      if (isOnline) {
        ref.read(platformControlsProvider.notifier).refresh();
        _checkSubscriptionEnforcement();
      }
    });
  }

  bool _subscriptionCheckInFlight = false;

  Future<void> _checkSubscriptionEnforcement() async {
    if (!mounted) return;
    if (!ref.read(connectivityServiceProvider).isOnline) return;
    // One status request at a time (see the controls poll above).
    if (_subscriptionCheckInFlight) return;
    _subscriptionCheckInFlight = true;
    try {
      await _runSubscriptionEnforcement();
    } finally {
      _subscriptionCheckInFlight = false;
    }
  }

  Future<void> _runSubscriptionEnforcement() async {
    if (!mounted) return;
    final auth = ref.read(authProvider);
    final user = auth.user;
    if (user == null || user.isAdmin) return;
    if (auth.status != AuthStatus.authenticated) return;
    // Do not bounce while the user is already on a subscription route.
    final route = GoRouterState.of(context);
    final live = route.matchedLocation;
    if (employeeSelfWorkspaceRoute(live,
            readOnly: route.uri.queryParameters['ro'] == '1') &&
        ref.read(employeeDeviceSelectionProvider) != null) return;
      if (live.startsWith('/subscription')) return;
    try {
      final snapshot = await ref.refresh(subscriptionStatusProvider.future);
      if (!mounted) return;
      final pilotDirectory = (_isDirectoryRoute(live) &&
              ref.read(directoryPilotAccessProvider) != null) ||
          ((live == '/debts/customers' || live == '/debts/suppliers' ||
               live == RouteNames.invoicesView || live == '/debts/operation' ||
               live == '/debts/notifications' || live == '/debt-notifications' ||
               live == '/business/income-expense' || _isLocalCommerceRoute(live) ||
               live == RouteNames.banks || live.startsWith('/banks/')) &&
              ref.read(businessLocalLedgerScopeProvider) != null);
      final section = live.startsWith('/personal')
          ? 'personal'
          : live == RouteNames.dashboard || pilotDirectory
          ? 'business'
          : null;
      if (section != null && !hasSectionAccess(snapshot, section)) {
        context.go('/account-entry');
        return;
      }
      final status = snapshot['status']?.toString();
      if (status == 'active' || status == 'trial') return;
      if (status == null || status.isEmpty)
        return; // not loaded yet â€” fall back to cache
      // `none` = a brand-new account that never subscribed and has NO request
      // pending. The subscription gate (plans/trial CTA) handles the UX â€” no
      // forced lockout here, otherwise a fresh user gets bounced in a loop.
      if (status == 'none') return;
      // Expired / cancelled / pending â†’ force the paywall immediately.
      if (user.effectiveStatus == 'active') {
        ref.invalidate(subscriptionStatusProvider);
        return; // cache mismatch; retry after refresh
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            GoRouterState.of(context).matchedLocation !=
                RouteNames.subscription) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  AppLocalizations.of(context).translate('routerSubExpired'),
                ),
                backgroundColor: AppColors.danger,
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 4),
              ),
            );
          context.go(RouteNames.subscription);
        }
      });
    } catch (_) {}
  }

  void _startPresence() {
    _presenceTimer?.cancel();
    void beat() {
      if (!ref.read(connectivityServiceProvider).isOnline) return;
      try {
        ref.read(merchantApiProvider).touchPresence();
      } catch (_) {}
    }

    beat();
    _presenceTimer = Timer.periodic(const Duration(seconds: 25), (_) => beat());
  }

  void _startWorkspaceChecks() {
    _workspaceTimer?.cancel();
    var checking = false;
    Future<void> check() async {
      if (!mounted) return;
      final path = GoRouter.of(context).routeInformationProvider.value.uri.path;
      if (path.startsWith('/personal') || checking) return;
      checking = true;
      try {
        await refreshBranchAccessIfChanged(ref);
        if (!mounted) return;
        if (BranchScope.awaitingServerSelection &&
            ref.read(connectivityServiceProvider).isOnline &&
            !ref.read(branchSwitchingProvider)) {
          final resumed = await ref.read(branchApiProvider).resumeDrawerSelection(
            stillSelected: () => mounted &&
                !ref.read(branchSwitchingProvider) &&
                !GoRouter.of(context).routeInformationProvider.value.uri.path
                    .startsWith('/personal'),
          );
          if (!mounted) return;
          if (resumed) ref.read(branchEpochProvider.notifier).state++;
        }
        final org = BranchScope.organizationId;
        final settings = await ref.read(projectSettingsApiProvider).load();
        if (!mounted || org != BranchScope.organizationId) return;
        if (!workspaceDataEqual(settings, ref.read(projectSettingsProvider).valueOrNull)) {
          ref.invalidate(projectSettingsProvider);
        }
        if (org != null) {
          final profile = await ref.read(employeeApiProvider).myProfile(organizationId: org);
          if (!mounted || org != BranchScope.organizationId) return;
          if (!workspaceDataEqual(profile, ref.read(myEmployeeProfileForProvider(org)).valueOrNull)) {
            ref.invalidate(myEmployeeProfileForProvider(org));
          }
        }
      } catch (_) {
        // Transient polling failures must not blank the current identity.
      } finally {
        checking = false;
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => check());
    _workspaceTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => check(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(platformControlsProvider.notifier).refresh();
      _startPresence();
      _startWorkspaceChecks();
    } else {
      // Backgrounded/closed → stop heartbeats so presence turns offline.
      _presenceTimer?.cancel();
      _workspaceTimer?.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controlsTimer?.cancel();
    _subTimer?.cancel();
    _presenceTimer?.cancel();
    _workspaceTimer?.cancel();
    _connectivitySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    // Branch pictures are copied to the device as soon as the lists arrive.
    if (authState.isAuthenticated) ref.watch(branchPictureSyncProvider);
    ref.listen(branchRevocationProvider, (previous, next) {
      if (previous == next) return;
      ref.invalidate(myInvitationsProvider);
      ref.invalidate(myEmployeeProfileProvider);
      ref.invalidate(myEmployeeFinanceProvider);
      ref.invalidate(branchAccessProvider);
      ref.read(branchEpochProvider.notifier).state++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.go('/account-entry');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Localizations.localeOf(context).languageCode == 'ar'
                  ? 'تم إلغاء ارتباطك بالمتجر. رجعناك لحسابك الخاص.'
                  : 'This workspace was unlinked. You are back in your own account.',
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
        );
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    });
    final user = authState.user;
    final role = user?.role ?? 'personal';
    final isPlatformAdmin = user?.isPlatformAdmin ?? false;
    final preferredUsageMode = user?.preferredUsageMode;
    final persona = getPersona(
      role,
      isPlatformAdmin: isPlatformAdmin,
      preferredUsageMode: preferredUsageMode,
    );
    final currentRoute = GoRouterState.of(context).matchedLocation;
    final isPersonal = isPersonalSectionRoute(currentRoute, preferredUsageMode);
    final routeSection = currentRoute.routeMode;
    if (user != null && routeSection != null) {
      unawaited(SectionHistory.save(user.id, routeSection));
    }
    final activeNav = isPersonal
        ? personalOwnerPersona.bottomNav
        : (persona == personalPersona || persona == personalOwnerPersona
              ? (role == 'owner' ? ownerPersona : staffPersona).bottomNav
              : persona.bottomNav);

    // Live maintenance enforcement â€” ط§ظ„ظ‡ط±ظ…ظٹط© APP > PERSONAL/BUSINESS > FEATURE
    // ظٹطھط­ظ‚ظ‚ ط¹ظ†ط¯ ظƒظ„ طھط؛ظٹظٹط± ظپظٹ controlsطŒ ظˆط¹ظ†ط¯ ط§ظ„ط¹ظˆط¯ط© ظ…ظ† ط§ظ„ط®ظ„ظپظٹط© ظˆطھط؛ظٹط± ط§ظ„ط§طھطµط§ظ„.
    ref.listen(platformControlsProvider, (prev, next) {
      final ctrl = next.valueOrNull;
      if (ctrl == null) return;
      if (user?.isPlatformAdmin ?? false) return;
      final live = GoRouterState.of(context).matchedLocation;
      // طµظپط­ط© ط§ظ„طµظٹط§ظ†ط© / طھط³ط¬ظٹظ„ ط§ظ„ط¯ط®ظˆظ„ ظ„ظٹط³طھ ط®ط§ط¶ط¹ط© ظ„ظ„ط­ط§ط±ط³
      if (live.startsWith('/maintenance') ||
          live == RouteNames.login ||
          live == RouteNames.reentry)
        return;

      // 1) طµظٹط§ظ†ط© ط§ظ„طھط·ط¨ظٹظ‚ ط¨ط§ظ„ظƒط§ظ…ظ„ â€” ط£ط¹ظ„ظ‰ ط£ظˆظ„ظˆظٹط©
      if (ctrl.isAppMaintenance) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) context.go('${RouteNames.maintenance}?key=all');
        });
        return;
      }

      // 2) طµظٹط§ظ†ط© ط§ظ„ظ‚ط³ظ… ط§ظ„ط´ط®طµظٹ/ط§ظ„ط£ط¹ظ…ط§ظ„ ط¨ط§ظ„ظƒط§ظ…ظ„
      final routeMode = live.routeMode ?? user?.preferredUsageMode;
      if (routeMode != null && ctrl.maintenance[routeMode] == true) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted)
            context.go('${RouteNames.maintenance}?key=$routeMode');
        });
        return;
      }

      // 3) طµظٹط§ظ†ط© ظ…ظٹط²ط© ظ…ط­ط¯ط¯ط© (ط£ط²ط±ط§ط± ط§ظ„ط´ط®طµظٹ ط§ظ„ط³ط¨ط¹ط©)
      if (ctrl.isRouteUnderMaintenance(live)) {
        final hit = ctrl.isFeatureDisabled(live) ? live : live;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) context.go('${RouteNames.maintenance}?key=$hit');
        });
        return;
      }

      if (ctrl.forcePaidSubscription &&
          user != null &&
          !user.isAdmin &&
          (isPersonal || ref.read(employeeWorkspaceCompanyProvider) == null)) {
        final subStatus = ref
            .read(subscriptionStatusProvider)
            .valueOrNull?['status'];
        final effectiveActive =
            (user.effectiveStatus == 'active') || subStatus == 'active';
        if (!effectiveActive && requestingNonPaywall(live)) {
          context.go(RouteNames.subscription);
        }
      }
    });

    int navIndex = 0;
    int best = -1;
    for (int i = 0; i < activeNav.length; i++) {
      final r = activeNav[i].route;
      if (currentRoute == r || currentRoute.startsWith('$r/')) {
        if (r.length > best) {
          best = r.length;
          navIndex = i;
        }
      }
    }

    return PopScope(
      // Never let the system pop the shell directly: we intercept EVERY back
      // press so the behaviour is identical on all devices/Android versions —
      // pop a nested route if there is one, otherwise require a double press.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final navigator = _shellNavigatorKey.currentState;
        if (navigator != null && navigator.canPop()) {
          navigator.pop();
          return;
        }
        final now = DateTime.now();
        final last = _lastBackPress;
        if (last != null && now.difference(last) < const Duration(seconds: 2)) {
          SystemNavigator.pop();
        } else {
          _lastBackPress = now;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  AppLocalizations.of(context).pressBackAgainToExit,
                  style: const TextStyle(fontFamily: 'Cairo'),
                ),
                backgroundColor: AppColors.danger,
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 2),
              ),
            );
        }
      },
      child: Scaffold(
        key: shellScaffoldKey,
        backgroundColor: isPersonal ? AppColors.background : null,
        drawer: AppDrawer(user: user, currentRoute: currentRoute),
        body: Column(
          children: [
            // Same top bar for personal and business (identical widget).
            HomeHeader(),
            if (BranchScope.readOnly &&
                !GoRouterState.of(context).uri.path.startsWith('/personal'))
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(12, 4, 12, 2),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppColors.primary, AppColors.primaryDark],
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withAlpha(55),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.visibility_rounded,
                      color: Colors.white,
                      size: 17,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          AppLocalizations.of(
                            context,
                          ).translate('branchReadOnlyBanner'),
                          maxLines: 1,
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: Consumer(
                builder: (context, ref, _) {
                  final epoch = ref.watch(branchEpochProvider);
                  final switching = ref.watch(branchSwitchingProvider);
                  return ProviderScope(
                    key: ValueKey('branch-scope-$epoch'),
                    child: Stack(
                      children: [
                        AppContentContainer(
                          padding: EdgeInsets.zero,
                          child: SubscriptionGate(
                            fullScreen: true,
                            child: MerchantWorkspaceGate(
                              route: currentRoute,
                              child: EmployeeFeatureGate(
                                route: currentRoute,
                                 child: PersonalRelayRuntime(child: PeerRelayRuntime(child: isPersonal ? widget.child
                                      : EmployeeDeviceFinanceRuntime(
                                          child: BusinessSyncRuntime(
                                            child: BusinessCashRelayRuntime(
                                              child: BusinessPartyShareRuntime(child: widget.child),
                                            ),
                                          ),
                                        ))),
                              ),
                            ),
                          ),
                        ),
                        if (switching)
                          Positioned.fill(
                            child: AbsorbPointer(
                              child: Container(
                                color: AppColors.background.withAlpha(210),
                                child: const Center(
                                  child: SizedBox(
                                    width: 30,
                                    height: 30,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        bottomNavigationBar: ValueListenableBuilder<Color?>(
          valueListenable: NavBarBackdrop.color,
          builder: (context, backdrop, bar) => backdrop == null
              ? bar!
              : ColoredBox(color: backdrop, child: bar),
          child: isPersonal
              ? HomeBottomNav(
                  currentIndex: navIndex,
                  onTap: (i) {
                    if (i < activeNav.length) {
                      context.go(activeNav[i].route);
                    }
                  },
                )
              : const BusinessBottomNav(),
        ),
      ),
    );
  }
}

class _BudgetDetailFallback extends ConsumerWidget {
  final String? budgetId;
  const _BudgetDetailFallback({this.budgetId});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final budgetSt = ref.watch(budgetProvider);
    if (budgetSt.isLoading) {
      return const Scaffold(body: Center(child: DotsLoader()));
    }
    if (budgetId != null) {
      final id = int.tryParse(budgetId!);
      if (id != null) {
        final match = budgetSt.budgets.where((b) => b.id == id).toList();
        if (match.isNotEmpty) return BudgetDetailPage(budget: match.first);
      }
    }
    if (budgetSt.budgets.isNotEmpty) {
      return BudgetDetailPage(budget: budgetSt.budgets.first);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
          AppLocalizations.of(context).translate('homeServiceBudget'),
        ),
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: Colors.orange,
              size: 48,
            ),
            const SizedBox(height: 12),
            Text(
              AppLocalizations.of(context).translate('routerBudgetError'),
              style: TextStyle(fontFamily: 'Cairo', fontSize: 14),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                ref.read(budgetProvider.notifier).load();
                context.go(RouteNames.personalBudget);
              },
              child: Text(
                AppLocalizations.of(context).translate('routerBackToBudgets'),
                style: TextStyle(fontFamily: 'Cairo'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


/// Keeps non-JSON route extras in memory under a token; JSON values pass
/// through unchanged. Bounded so it never grows without limit.
class _MemoryExtraCodec extends Codec<Object?, Object?> {
  const _MemoryExtraCodec();
  static final Map<String, Object?> _store = {};
  static int _next = 0;
  static const _key = '__fyona_extra';

  @override
  Converter<Object?, Object?> get encoder => const _ExtraEncoder();
  @override
  Converter<Object?, Object?> get decoder => const _ExtraDecoder();

  static bool _plain(Object? value) {
    if (value == null || value is num || value is String || value is bool) {
      return true;
    }
    if (value is List) return value.every(_plain);
    if (value is Map) {
      return value.keys.every((k) => k is String) && value.values.every(_plain);
    }
    return false;
  }
}

class _ExtraEncoder extends Converter<Object?, Object?> {
  const _ExtraEncoder();
  @override
  Object? convert(Object? input) {
    if (_MemoryExtraCodec._plain(input)) return input;
    for (final entry in _MemoryExtraCodec._store.entries) {
      if (identical(entry.value, input)) {
        return {_MemoryExtraCodec._key: entry.key};
      }
    }
    final token = 'e${_MemoryExtraCodec._next++}';
    _MemoryExtraCodec._store[token] = input;
    if (_MemoryExtraCodec._store.length > 300) {
      _MemoryExtraCodec._store.remove(_MemoryExtraCodec._store.keys.first);
    }
    return {_MemoryExtraCodec._key: token};
  }
}

class _ExtraDecoder extends Converter<Object?, Object?> {
  const _ExtraDecoder();
  @override
  Object? convert(Object? input) {
    if (input is Map && input.length == 1 &&
        input[_MemoryExtraCodec._key] is String) {
      return _MemoryExtraCodec._store[input[_MemoryExtraCodec._key]];
    }
    return input;
  }
}
