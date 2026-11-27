import '../../../../core/help/help_content.dart';

/// Live screen catalog streamed to Sara with every query: every route the
/// installed app ships, with a bilingual title + summary. This is what lets
/// Sara know (and open) screens added in newer app versions without any
/// backend update — the app itself is the source of truth for its sections.
class SaraScreenCatalog {
  SaraScreenCatalog._();

  static List<Map<String, String>> entries({required bool arabic}) {
    final out = <Map<String, String>>[];
    final seen = <String>{};
    for (final entry in HelpContent.catalog(arabic: arabic)) {
      final route = entry['route'] ?? '';
      // A help topic for a screen this app no longer has is never offered
      // as a button: it opens its replacement, or is left out.
      if (_removed.contains(route)) continue;
      final live = _replaced[route] ?? route;
      if (seen.add(live)) out.add({...entry, 'route': live});
    }
    for (final extra in (arabic ? _extrasAr : _extrasEn)) {
      if (seen.add(extra['route']!)) out.add(extra);
    }
    return out;
  }

  /// The live screen for a route Sara may still name from an older catalog.
  static String liveRoute(String route) {
    final path = route.split('?').first;
    final live = _replaced[path];
    return live == null ? route : live;
  }

  /// Old screens and the screen that does their job now.
  static const Map<String, String> _replaced = {
    '/products': '/inventory',
    '/purchases': '/invoices',
    '/expenses': '/business/income-expense',
    '/payments': '/debts',
    '/debt-aging': '/debts',
    '/statement': '/banks',
    '/banks/statement': '/banks',
    '/banks/transfer': '/banks',
    '/sales-report': '/reports',
    '/purchase-report': '/reports',
    '/profit-loss': '/reports',
    '/cashflow': '/reports',
    '/cashflow-report': '/reports',
    '/comparative-report': '/reports',
    '/custom-report': '/reports',
    '/pos': '/sales/add',
    '/invitations': '/branches/invitations',
    '/users': '/employees',
    '/payroll': '/employees',
    // Personal reports: one entry point (see saraPersonalReportsRoute in
    // sara_action_dispatcher.dart — the new Personal reports page).
    '/personal/reports-center': '/personal/reports',
    '/import': '/data-import/smart-import',
  };

  /// Screens with no equivalent in this app.
  static const Set<String> _removed = {
    '/accounts', '/admin/subscription-requests', '/attendance',
    '/balance-sheet', '/cheques', '/contracts', '/crm-dashboard',
    '/design-studio', '/fiscal-years',
    '/fixed-assets', '/hr-reports', '/journal', '/leaves',
    '/ledger', '/projects', '/projects-dashboard', '/recurring-invoices',
    '/trial-balance',
  };

  /// Resolves a mentioned screen title to its route — the fallback used when
  /// an assistant action names a screen without an explicit route.
  /// Case-insensitive; exact matches prefer the personal section when the
  /// same title exists in both modes (e.g. البنوك).
  static String? routeForTitle(String title, {required bool arabic}) {
    final t = title.trim().toLowerCase();
    if (t.isEmpty) return null;
    final all = entries(arabic: arabic);
    final exact = all
        .where((e) => (e['title'] ?? '').trim().toLowerCase() == t)
        .toList();
    if (exact.isNotEmpty) {
      final personal = exact.firstWhere(
        (e) => (e['route'] ?? '').startsWith('/personal'),
        orElse: () => exact.first,
      );
      return personal['route'];
    }
    for (final e in all.reversed) {
      final label = (e['title'] ?? '').trim().toLowerCase();
      if (label.isEmpty) continue;
      if (t.contains(label) || label.contains(t)) {
        return e['route'];
      }
    }
    return null;
  }

  static const List<Map<String, String>> _extrasAr = [
    // Business screens the help catalog does not describe yet: Sara must
    // be able to open them (business_sara only allows catalog routes).
    {
      'route': '/invoices',
      'title': 'الفواتير',
      'summary': 'كل فواتير البيع والشراء في الفرع ومتابعة حالتها.',
    },
    {
      'route': '/returns',
      'title': 'المرتجعات',
      'summary': 'مرتجعات البيع والشراء على الفواتير.',
    },
    {
      'route': '/business/income-expense',
      'title': 'الإيرادات والمصروفات',
      'summary': 'تسجيل إيرادات ومصروفات النشاط ومتابعتها.',
    },
    {
      'route': '/business/transactions',
      'title': 'الحركات المالية',
      'summary': 'كل حركات الفرع المالية في مكان واحد.',
    },
    {
      'route': '/inventory/categories',
      'title': 'تصنيفات المنتجات',
      'summary': 'تصنيفات المخزون وصورها ومنتجاتها.',
    },
    {
      'route': '/debts/customers',
      'title': 'ديون العملاء',
      'summary': 'ما لك على العملاء وتحصيله.',
    },
    {
      'route': '/debts/suppliers',
      'title': 'ديون الموردين',
      'summary': 'ما عليك للموردين وسداده.',
    },
    {
      'route': '/branches',
      'title': 'الفروع',
      'summary': 'فروع النشاط وأعضاؤها وصلاحياتهم.',
    },
    {
      'route': '/branches/transfers',
      'title': 'تحويلات الفروع',
      'summary': 'تحويل البضاعة والمال بين الفروع.',
    },
    {
      'route': '/reconciliation',
      'title': 'المطابقة',
      'summary': 'مطابقة أرصدة البنوك والصندوق والمخزون مع الفعلي.',
    },
    {
      'route': '/reconciliation/bank',
      'title': 'مطابقة البنوك',
      'summary': 'مقارنة الرصيد الفعلي للبنوك والصندوق برصيد النظام.',
    },
    {
      'route': '/reconciliation/inventory',
      'title': 'مطابقة المخزون',
      'summary': 'جرد المخزون ومقارنته بكميات النظام.',
    },
    {
      'route': '/reconciliation/archive',
      'title': 'أرشيف المطابقات',
      'summary': 'المطابقات السابقة ونتائجها.',
    },
    {
      'route': '/business/backup',
      'title': 'النسخ الاحتياطي للأعمال',
      'summary': 'نسخة احتياطية مشفرة لبيانات الفرع.',
    },
    {
      'route': '/data-import/smart-import',
      'title': 'الاستيراد الذكي',
      'summary': 'إدخال العملاء والموردين والمنتجات وأرصدتهم من ملف، مع مراجعة كل صف قبل الحفظ.',
    },
    {
      'route': '/personal/debts?debtId=',
      'title': 'تفاصيل دين',
      'summary': 'دين واحد في القسم الشخصي بدفعاته. أكملي الرابط بمعرف الدين: /personal/debts?debtId=<id>.',
    },
    {
      'route': '/personal/budget/detail?id=',
      'title': 'تفاصيل ميزانية',
      'summary': 'ميزانية واحدة وأصنافها وصرفها. /personal/budget/detail?id=<id>.',
    },
    {
      'route': '/personal/recurring/detail?id=',
      'title': 'تفاصيل عملية متكررة',
      'summary': 'عملية متكررة واحدة: التنفيذ الآن، التخطي، التأجيل. /personal/recurring/detail?id=<id>.',
    },
    {
      'route': '/personal/savings-detail/',
      'title': 'تفاصيل هدف ادخار',
      'summary': 'هدف واحد ومساهماته. /personal/savings-detail/<goal id>.',
    },
    {
      'route': '/personal/bank-detail/',
      'title': 'تفاصيل بنك شخصي',
      'summary': 'بنك واحد بعملاته وحركاته. /personal/bank-detail/<اسم البنك>?currency=<رمز العملة>.',
    },
    {
      'route': '/personal/account-detail/',
      'title': 'تفاصيل حساب شخصي',
      'summary': 'حساب واحد وحركاته. /personal/account-detail/<account id>.',
    },
    {
      'route': '/inventory/product',
      'title': 'تفاصيل منتج',
      'summary': 'بطاقة منتج واحد: الكمية والأسعار والدفعات والإحصاءات. أضيفي ?id=<معرف المنتج>.',
    },
    {
      'route': '/inventory/product/edit',
      'title': 'تعديل منتج',
      'summary': 'تعديل الاسم والسعر والحد الأدنى والباركود والتصنيف والصورة. أضيفي ?id=<معرف المنتج>.',
    },
    {
      'route': '/inventory/product/movements',
      'title': 'حركة منتج',
      'summary': 'كل ما دخل وخرج من منتج واحد. أضيفي ?id=<معرف المنتج>.',
    },
    {
      'route': '/inventory/category',
      'title': 'تفاصيل تصنيف',
      'summary': 'منتجات تصنيف واحد وصورته. أضيفي ?id=<معرف التصنيف>.',
    },
    {
      'route': '/reentry',
      'title': 'إعادة الدخول',
      'summary': 'تأكيد الهوية قبل استئناف الجلسة.',
    },
    {
      'route': '/mfa/setup',
      'title': 'تفعيل التحقق بخطوتين',
      'summary': 'حماية الحساب بخطوة تحقق إضافية.',
    },
    {
      'route': '/mfa/verify',
      'title': 'رمز التحقق',
      'summary': 'إدخال رمز التحقق لإتمام الدخول.',
    },
  ];

  static const List<Map<String, String>> _extrasEn = [
    {
      'route': '/invoices',
      'title': 'Invoices',
      'summary': 'All sale and purchase invoices of the branch and their status.',
    },
    {
      'route': '/returns',
      'title': 'Returns',
      'summary': 'Sale and purchase returns on invoices.',
    },
    {
      'route': '/business/income-expense',
      'title': 'Income & Expenses',
      'summary': 'Record and follow the business income and expenses.',
    },
    {
      'route': '/business/transactions',
      'title': 'Transactions',
      'summary': 'Every money movement of the branch in one place.',
    },
    {
      'route': '/inventory/categories',
      'title': 'Product categories',
      'summary': 'Inventory categories with their photos and products.',
    },
    {
      'route': '/debts/customers',
      'title': 'Customer debts',
      'summary': 'What customers owe you and its collection.',
    },
    {
      'route': '/debts/suppliers',
      'title': 'Supplier debts',
      'summary': 'What you owe suppliers and its payment.',
    },
    {
      'route': '/branches',
      'title': 'Branches',
      'summary': 'Business branches, their members and permissions.',
    },
    {
      'route': '/branches/transfers',
      'title': 'Branch transfers',
      'summary': 'Move goods and money between branches.',
    },
    {
      'route': '/reconciliation',
      'title': 'Reconciliation',
      'summary': 'Match bank, cash and inventory balances with the actual ones.',
    },
    {
      'route': '/reconciliation/bank',
      'title': 'Bank reconciliation',
      'summary': 'Compare actual bank and cash balances with the system.',
    },
    {
      'route': '/reconciliation/inventory',
      'title': 'Inventory count',
      'summary': 'Count the stock and compare it with the system quantities.',
    },
    {
      'route': '/reconciliation/archive',
      'title': 'Reconciliation archive',
      'summary': 'Past reconciliations and their results.',
    },
    {
      'route': '/business/backup',
      'title': 'Business backup',
      'summary': 'An encrypted backup of the branch data.',
    },
    {
      'route': '/data-import/smart-import',
      'title': 'Smart import',
      'summary': 'Bring customers, suppliers, products and their balances in from a file, reviewing every row first.',
    },
    {
      'route': '/personal/debts?debtId=',
      'title': 'Debt details',
      'summary': 'One Personal debt with its payments: /personal/debts?debtId=<id>.',
    },
    {
      'route': '/personal/budget/detail?id=',
      'title': 'Budget details',
      'summary': 'One budget with its categories and spending: /personal/budget/detail?id=<id>.',
    },
    {
      'route': '/personal/recurring/detail?id=',
      'title': 'Recurring details',
      'summary': 'One recurring item: run now, skip, postpone. /personal/recurring/detail?id=<id>.',
    },
    {
      'route': '/personal/savings-detail/',
      'title': 'Savings goal details',
      'summary': 'One goal and its contributions: /personal/savings-detail/<goal id>.',
    },
    {
      'route': '/personal/bank-detail/',
      'title': 'Personal bank details',
      'summary': 'One bank with its currencies and movements: /personal/bank-detail/<bank name>?currency=<code>.',
    },
    {
      'route': '/personal/account-detail/',
      'title': 'Personal account details',
      'summary': 'One account and its movements: /personal/account-detail/<account id>.',
    },
    {
      'route': '/inventory/product',
      'title': 'Product details',
      'summary': 'One product: stock, prices, batches and stats. Add ?id=<product id>.',
    },
    {
      'route': '/inventory/product/edit',
      'title': 'Edit product',
      'summary': 'Edit name, price, minimum stock, barcode, category and photo. Add ?id=<product id>.',
    },
    {
      'route': '/inventory/product/movements',
      'title': 'Product movements',
      'summary': 'Everything in and out of one product. Add ?id=<product id>.',
    },
    {
      'route': '/inventory/category',
      'title': 'Category details',
      'summary': 'The products and photo of one category. Add ?id=<category id>.',
    },
    {
      'route': '/reentry',
      'title': 'Re-entry',
      'summary': 'Confirm your identity before resuming the session.',
    },
    {
      'route': '/mfa/setup',
      'title': 'Set up 2FA',
      'summary': 'Protect your account with an extra verification step.',
    },
    {
      'route': '/mfa/verify',
      'title': 'Verification code',
      'summary': 'Enter the verification code to finish signing in.',
    },
  ];
}
