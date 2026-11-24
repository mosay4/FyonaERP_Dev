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
  };

  /// Screens with no equivalent in this app.
  static const Set<String> _removed = {
    '/accounts', '/admin/subscription-requests', '/attendance',
    '/balance-sheet', '/cheques', '/contracts', '/crm-dashboard',
    '/data-import/smart-import', '/design-studio', '/fiscal-years',
    '/fixed-assets', '/hr-reports', '/import', '/journal', '/leaves',
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
