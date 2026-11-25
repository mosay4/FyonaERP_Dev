import '../../shared/widgets/two_tone_icons.dart';
import '../../shared/widgets/two_tone_icon.dart';
import '../localization/app_localizations.dart';
import '../../features/branches/data/branch_scope.dart';

class NavItem {
  final String label;
  final TwoToneIconData twoToneIcon;
  final String route;
  NavItem(this.label, this.twoToneIcon, this.route);
}

class NavGroup {
  final String name;
  final List<NavItem> items;
  NavGroup(this.name, this.items);
}

class RolePersona {
  final String key;
  final String label;
  final List<NavGroup> sidebarGroups;
  final List<NavItem> bottomNav;
  RolePersona(this.key, this.label, this.sidebarGroups, this.bottomNav);
}

final ownerPersona = RolePersona(
  'owner',
  'مالك',
  [
    NavGroup('الرئيسية', [
      NavItem('لوحة التحكم', TwoToneIcons.building, '/dashboard'),
    ]),
    NavGroup('سارة', [NavItem('سارة', TwoToneIcons.ai, '/ai')]),
    NavGroup('الباقات', [
      NavItem('الباقات والاشتراك', TwoToneIcons.crown, '/subscription'),
    ]),
    NavGroup('الإعدادات', [
      NavItem('الإعدادات', TwoToneIcons.settings, '/settings'),
      NavItem('الإشعارات', TwoToneIcons.bell, '/notifications'),
    ]),
  ],
  [
    NavItem('الرئيسية', TwoToneIcons.home, '/dashboard'),
    NavItem('الإعدادات', TwoToneIcons.settings, '/settings'),
  ],
);

final staffPersona = RolePersona(
  'staff',
  'موظف',
  [
    NavGroup('الرئيسية', [
      NavItem('المهام', TwoToneIcons.building, '/dashboard'),
    ]),
    NavGroup('سارة', [NavItem('سارة', TwoToneIcons.ai, '/ai')]),
  ],
  [NavItem('الرئيسية', TwoToneIcons.home, '/dashboard')],
);

final personalPersona = RolePersona(
  'personal',
  'مستخدم فردي',
  [
    NavGroup('الرئيسية', [
      NavItem('لوحة التحكم', TwoToneIcons.home, '/personal'),
    ]),
    NavGroup('المعاملات', [
      NavItem('المدفوعات', TwoToneIcons.creditCard, '/personal/transactions'),
      NavItem('المصروفات', TwoToneIcons.expense, '/personal/transactions'),
    ]),
    NavGroup('الإعدادات', [
      NavItem('الملف الشخصي', TwoToneIcons.userCircle, '/profile'),
      NavItem('الباقات', TwoToneIcons.crown, '/subscription'),
    ]),
  ],
  [
    NavItem('الرئيسية', TwoToneIcons.home, '/personal'),
    NavItem('البنوك', TwoToneIcons.bank, '/personal/banks'),
    NavItem('الديون', TwoToneIcons.debt, '/personal/debts'),
    NavItem('الأهداف', TwoToneIcons.savingsGoal, '/personal/savings'),
    NavItem('الميزانية', TwoToneIcons.chart, '/personal/budget'),
  ],
);

final personalOwnerPersona = RolePersona(
  'owner_personal',
  'المالية الشخصية',
  [
    NavGroup('الرئيسية', [
      NavItem('لوحة التحكم', TwoToneIcons.home, '/personal'),
    ]),
    NavGroup('المالية', [
      NavItem('الحسابات البنكية', TwoToneIcons.bank, '/personal/banks'),
      NavItem('المعاملات', TwoToneIcons.creditCard, '/personal/transactions'),
      NavItem('الديون', TwoToneIcons.debt, '/personal/debts'),
    ]),
    NavGroup('الأهداف', [
      NavItem('أهداف الادخار', TwoToneIcons.savingsGoal, '/personal/savings'),
    ]),
    NavGroup('التقارير', [
      NavItem('التقارير', TwoToneIcons.barChart, '/personal/reports'),
    ]),
    NavGroup('المساعد الذكي', [
      NavItem('سارة', TwoToneIcons.ai, '/personal/ai'),
    ]),
    NavGroup('الميزانية', [
      NavItem('الميزانية', TwoToneIcons.chart, '/personal/budget'),
    ]),
    NavGroup('الباقات', [
      NavItem('الباقات والاشتراك', TwoToneIcons.crown, '/subscription'),
    ]),
  ],
  [
    NavItem('الرئيسية', TwoToneIcons.home, '/personal'),
    NavItem('البنوك', TwoToneIcons.bank, '/personal/banks'),
    NavItem('الديون', TwoToneIcons.debt, '/personal/debts'),
    NavItem('الأهداف', TwoToneIcons.savingsGoal, '/personal/savings'),
    NavItem('الميزانية', TwoToneIcons.chart, '/personal/budget'),
  ],
);

final ownerBothPersona = RolePersona(
  'owner_both',
  'أعمال وشخصي',
  [
    ...ownerPersona.sidebarGroups,
    NavGroup('المالية الشخصية', [
      NavItem('لوحة التحكم', TwoToneIcons.home, '/personal'),
      NavItem('الحسابات البنكية', TwoToneIcons.bank, '/personal/banks'),
      NavItem('المعاملات', TwoToneIcons.creditCard, '/personal/transactions'),
      NavItem('الديون', TwoToneIcons.debt, '/personal/debts'),
      NavItem('الأهداف', TwoToneIcons.savingsGoal, '/personal/savings'),
      NavItem('الميزانية', TwoToneIcons.chart, '/personal/budget'),
      NavItem('سارة', TwoToneIcons.ai, '/personal/ai'),
    ]),
  ],
  [
    NavItem('الرئيسية', TwoToneIcons.home, '/dashboard'),
    NavItem('المالية', TwoToneIcons.wallet, '/personal'),
    NavItem('الإعدادات', TwoToneIcons.settings, '/settings'),
  ],
);

RolePersona getPersona(
  String role, {
  bool isPlatformAdmin = false,
  String? preferredUsageMode,
}) {
  if (role == 'owner') {
    if (preferredUsageMode == 'personal') return personalOwnerPersona;
    if (preferredUsageMode == 'both') return ownerBothPersona;
    return ownerPersona;
  }
  if (['admin', 'accountant', 'employee', 'viewer'].contains(role))
    return staffPersona;
  return personalPersona;
}

const businessAllowedRoutes = <String>{
  '/accounts', '/journal', '/trial-balance', '/profit-loss', '/balance-sheet',
  '/cheques',
  '/business/backup',
  '/choose-usage',
  '/dashboard',
  // Unified transactions timeline (prefix also covers /details) — without
  // this the route guard bounces the page straight back to the dashboard.
  '/business/transactions',
  '/business/income-expense',
  '/banks', '/banks/detail', '/banks/account',
  '/sales', '/sales/add', '/sales/view',
  '/purchases', '/purchases/add', '/purchases/view',
  '/returns', '/returns/add', '/returns/view',
  '/invoices', '/invoices/view', '/invoices/design',
  '/business/profile',
  '/inventory', '/inventory/product',
  '/customers', '/customers/detail',
  '/suppliers', '/suppliers/detail',
  '/debts',
  // Isolated commercial-debt notification center (business context) + the
  // legacy bare path used by older pushes so a tap never bounces to home.
  '/debts/notifications', '/debt-notifications',
  '/settings', '/settings/files', '/settings/custom-fields',
  '/notifications', '/reminders',
  '/subscription', '/subscription/pay',
  '/ai', '/ai-suggestions', '/suggestions',
  '/onboarding', '/mfa/setup',
  '/receipt-preview',
  '/change-password', '/sessions', '/customization',
  '/design/invoice', '/design/report', '/design/brand', '/design/print',
  // Reconciliation (قسم المطابقة) + Reports (قسم التقارير) — without these
  // the route guard bounces every press straight back to the dashboard.
  '/reconciliation',
  '/reports',
  '/branches', '/branches/transfers', '/branches/invitations',
  '/branches/members',
  '/employees', '/employees/add', '/employees/edit', '/employees/detail',
  '/job-requests', '/employee-profile', '/employees/salary', '/employees/debts',
};

const personalAllowedRoutes = <String>{
  '/choose-usage',
  '/personal', '/personal/transactions',
  '/personal/savings', '/personal/analytics', '/personal/reports',
  '/personal/banks', '/personal/debts', '/personal/budget',
  '/personal/recurring', '/personal/categories',
  '/personal/transfer',
  '/personal/reports-center',
  '/personal/finance-overview',
  '/personal/executive',
  '/personal/bank-statement',
  '/personal/account-detail',
  '/personal/bank-detail',
  '/personal/savings-detail',
  '/personal/all-banks-report',
  '/personal/budget/add',
  '/personal/budget/edit',
  '/personal/receipt-design',
  '/personal/receipt-design/edit',
  '/personal/ai',
  // Isolated commercial-debt notifications (personal context) + legacy path.
  '/personal/debt-notifications', '/debt-notifications',
  '/settings', '/notifications', '/reminders',
  '/subscription', '/subscription/pay',
  '/change-password', '/profile', '/sessions', '/customization',
  '/design/invoice', '/design/report', '/design/brand', '/design/print',
  '/suggestions',
  // Invitation taps must open the invitation card even before the user has
  // accepted (they are still a Personal account at that moment).
  '/branches/invitations',
  '/job-requests', '/employee-profile', '/employees/salary', '/employees/debts',
};

const staffAllowedRoutes = <String>{
  '/accounts', '/journal', '/trial-balance', '/profit-loss', '/balance-sheet',
  '/cheques',
  '/choose-usage',
  '/receipt-preview',
  '/suggestions',
  '/change-password', '/sessions', '/customization',
  '/business/profile',
  '/design/invoice', '/design/report', '/design/brand', '/design/print',
  // Managers/accountants may open Reports + Reconciliation; the BACKEND
  // remains authoritative (employees get 403 → honest error snack).
  '/reconciliation',
  '/reports',
  '/debts', '/debts/notifications', '/debt-notifications',
  '/branches', '/branches/transfers',
  '/employees', '/employees/add', '/employees/edit', '/employees/detail',
  '/job-requests', '/employee-profile', '/employees/salary', '/employees/debts',
};

const personalRoleAllowedRoutes = <String>{
  '/choose-usage',
  '/personal',
  '/personal/transactions',
  '/personal/savings',
  '/personal/analytics',
  '/personal/reports',
  '/personal/banks',
  '/personal/debts',
  '/personal/budget',
  '/personal/recurring',
  '/personal/categories',
  '/personal/transfer',
  '/personal/reports-center',
  '/personal/finance-overview',
  '/personal/executive',
  '/personal/bank-statement',
  '/personal/account-detail',
  '/personal/bank-detail',
  '/personal/savings-detail',
  '/personal/all-banks-report',
  '/personal/budget/add',
  '/personal/budget/edit',
  '/personal/recurring/add',
  '/personal/recurring/detail',
  '/personal/recurring/edit',
  '/personal/categories/add',
  '/personal/categories/edit',
  '/personal/receipt-design',
  '/personal/receipt-design/edit',
  '/personal/ai',
  '/personal/account-tree',
  '/personal/financial-tree',
  '/personal/debt-notifications',
  '/debt-notifications',
  '/notifications',
  '/reminders',
  '/subscription',
  '/subscription/pay',
  '/subscription/phone-entry',
  '/change-password',
  '/profile',
  '/sessions',
  '/customization',
  '/suggestions',
  '/branches/invitations',
};

/// Union of business + personal routes for the combined ('both') mode.
/// Built with [union] because the two sets share entries ('/choose-usage'…).
final _ownerBothRoutes = businessAllowedRoutes.union(personalAllowedRoutes);

final allowedRoutes = <String, Set<String>>{
  'owner_both': _ownerBothRoutes,
  'super_admin': {
    ...businessAllowedRoutes,
    ..._ownerBothRoutes,
    '/notifications',
    '/reminders',
    '/profile',
    '/sessions',
    '/customization',
    '/design/invoice',
    '/design/report',
    '/design/brand',
    '/design/print',
  },
  'owner': businessAllowedRoutes,
  'owner_personal': personalAllowedRoutes,
  'staff': staffAllowedRoutes,
  'personal': personalRoleAllowedRoutes,
};

/// Route -> ARB key for navigation labels (single source of truth:
/// assets/l10n/app_ar.arb + app_en.arb). Generated from the inline Arabic
/// labels and the English table; Arabic rendering still uses [NavItem.label].
const _navKeyByRoute = <String, String>{
  '/ai': 'navAi',
  '/dashboard': 'navDashboard',
  '/notifications': 'navNotifications',
  '/personal': 'navPersonal',
  '/personal/ai': 'navPersonalAi',
  '/personal/reports': 'navReports',
  '/personal/banks': 'navPersonalBanks',
  '/personal/budget': 'navPersonalBudget',
  '/personal/debts': 'navPersonalDebts',
  '/personal/savings': 'navPersonalSavings',
  '/personal/transactions': 'navPersonalTransactions',
  '/profile': 'navProfile',
  '/settings': 'navSettings',
  '/subscription': 'navSubscription',
  '/suggestions': 'navSuggestions',
};

/// Arabic group name -> ARB key (single source: assets/l10n).
const _navGroupKeyByArabic = <String, String>{
  'الرئيسية': 'navGroupHome',
  'المالية الشخصية': 'navGroupPersonalFinance',
  'الإعدادات': 'navGroupSettings',
  'سارة': 'navGroupSara',
  'الباقات': 'navGroupPlans',
  'المالية': 'navGroupFinance',
  'المعاملات': 'navGroupTransactions',
  'الأهداف': 'navGroupGoals',
  'التحليلات': 'navGroupAnalytics',
  'التقارير': 'navGroupReports',
  'المساعد الذكي': 'navGroupSmartAssistant',
  'الميزانية': 'navGroupBudget',
};

/// Navigation label in the current language.
/// Arabic uses the inline [NavItem.label] (unchanged); any other language
/// resolves through the central ARB tables via [AppLocalizations.t].
String navLabel(NavItem item, {bool isAr = true}) {
  if (isAr) return item.label;
  final key = _navKeyByRoute[item.route];
  if (key == null) return item.label;
  final v = AppLocalizations.t(key);
  return v == key ? item.label : v;
}

/// Group title in the current language (same contract as [navLabel]).
String navGroupLabel(String arabicName, {bool isAr = true}) {
  if (isAr) return arabicName;
  final key = _navGroupKeyByArabic[arabicName];
  if (key == null) return arabicName;
  final v = AppLocalizations.t(key);
  return v == key ? arabicName : v;
}

bool isRouteAllowed(
  String route,
  String personaKey, {
  String? preferredUsageMode,
}) {
  var key = switch (personaKey) {
    'employee' || 'admin' || 'accountant' || 'viewer' => 'staff',
    _ => personaKey,
  };
  if (personaKey == 'owner' && preferredUsageMode == 'personal') {
    key = 'owner_personal';
  } else if (personaKey == 'owner' && preferredUsageMode == 'both') {
    key = 'owner_both';
  }
  final allowed = allowedRoutes[key] ?? <String>{};
  if (allowed.isEmpty) return false;
  if (key == 'staff' &&
      personalRoleAllowedRoutes.any((prefix) => route.startsWith(prefix)))
    return true;
  final sorted = allowed.toList()..sort((a, b) => b.length.compareTo(a.length));
  for (final prefix in sorted) {
    if (route.startsWith(prefix)) return true;
  }
  // An invited member may be a Personal account; while they hold an active
  // branch membership they can enter the Business surface WITHOUT buying a
  // Business subscription of their own.
  if ((key == 'personal' || key == 'staff' || key == 'owner_personal') &&
      BranchScope.hasMembership) {
    final biz = businessAllowedRoutes.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final prefix in biz) {
      if (route.startsWith(prefix)) return true;
    }
  }
  return false;
}
