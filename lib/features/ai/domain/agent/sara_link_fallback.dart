import '../../../../core/router/route_names.dart';
import '../../../../shared/widgets/sara_action_dispatcher.dart';
import 'sara_screen_catalog.dart';

/// Safety net for Sara's screen buttons (Personal section).
///
/// The model sometimes answers «الزر تحت جاهز — اضغط عليه» without calling
/// open_app_screen (it imitates an earlier reply whose button it no longer
/// sees in the text history), so the user gets a promise and no button.
/// When the user asked to open/send a screen, or Sara's reply talks about a
/// button/opening a screen, and the reply carries no navigation action, the
/// screen is derived deterministically — first from the user's words, then
/// from Sara's — and the chip is attached.
///
/// Returns [actions] unchanged when a navigation action is already there or
/// nothing in the text names a Personal screen.
List<SaraAction> saraEnsureScreenAction({
  required String userQuery,
  required String reply,
  required List<SaraAction> actions,
  required bool arabic,
}) {
  final hasNav = actions.any((a) =>
      a.type == SaraActionType.openScreen || a.type == SaraActionType.openEntity ||
      a.type == SaraActionType.exportPdf);
  if (hasNav) return actions;
  if (!saraAsksForScreen(userQuery) && !saraReplyPromisesButton(reply)) {
    return actions;
  }
  final route = saraScreenRouteFromText(userQuery, arabic: arabic) ??
      saraScreenRouteFromText(reply, arabic: arabic);
  if (route == null) return actions;
  final title = _titleFor(route, arabic: arabic);
  return [
    SaraAction(
      type: SaraActionType.openScreen,
      params: {'screen': title, 'route': route},
      label: '${arabic ? 'فتح' : 'Open'} $title',
    ),
    ...actions,
  ];
}

String _norm(String s) => s
    .toLowerCase()
    .replaceAll(RegExp('[ً-ٟـ]'), '')
    .replaceAll(RegExp('[أإآ]'), 'ا')
    .replaceAll('ة', 'ه')
    .replaceAll('ى', 'ي');

/// The user asked for a screen/button: «افتح…», «ودّيني…», «رسل لي زر…»,
/// «أعطني رابط…», "open …", "button for …".
bool saraAsksForScreen(String text) {
  final t = _norm(text);
  const cues = [
    'افتح', 'فتح', 'وديني', 'ودني', 'خذني', 'روح', 'انتقل', 'اعرض لي صفحه', 'صفحه', 'شاشه',
    'زر', 'زرار', 'رابط', 'لينك', 'ارسل لي', 'رسل لي', 'رسلي', 'ارسلي', 'ابعث', 'ابعتلي', 'دزلي',
    'open', 'button', 'link', 'take me', 'go to', 'navigate', 'send me',
  ];
  return cues.any(t.contains);
}

/// Sara's reply speaks of a button or of opening a screen.
bool saraReplyPromisesButton(String text) {
  final t = _norm(text);
  const cues = [
    'الزر', 'زر ', 'اضغط', 'يوديك', 'يفتح لك', 'فتحت لك', 'افتح لك', 'تفتح', 'الرابط', 'رابط',
    'button', 'tap', 'press', 'opens', 'link below',
  ];
  return cues.any(t.contains);
}

/// Personal screens by the words people use for them (Arabic dialects +
/// English), normalized. Phrases (with a space) match anywhere; single words
/// match a whole word after its prefixes (ال/و/ب/ل/لل…) — a keyword of 4+
/// letters also matches its suffixed forms (تقارير → تقاريري). Earlier
/// entries win on the same word (اشتراكات → المتكررة, not الاشتراك).
const List<MapEntry<String, String>> _keywords = [
  MapEntry('كشف حساب', RouteNames.personalBankStatement),
  MapEntry('bank statement', RouteNames.personalBankStatement),
  MapEntry('الشجره الماليه', RouteNames.financialTree),
  MapEntry('شجره', RouteNames.financialTree),
  MapEntry('financial tree', RouteNames.financialTree),
  MapEntry('حسابات التجار', RouteNames.personalMerchantAccounts),
  MapEntry('التجار', RouteNames.personalMerchantAccounts),
  MapEntry('merchant', RouteNames.personalMerchantAccounts),
  MapEntry('النسخ الاحتياطي', RouteNames.personalBackup),
  MapEntry('نسخه احتياطيه', RouteNames.personalBackup),
  MapEntry('backup', RouteNames.personalBackup),
  MapEntry('تقرير', saraPersonalReportsRoute),
  MapEntry('تقارير', saraPersonalReportsRoute),
  MapEntry('report', saraPersonalReportsRoute),
  MapEntry('متكرر', RouteNames.personalRecurring),
  MapEntry('اشتراكات', RouteNames.personalRecurring),
  MapEntry('recurring', RouteNames.personalRecurring),
  MapEntry('ميزاني', RouteNames.personalBudget),
  MapEntry('budget', RouteNames.personalBudget),
  MapEntry('اهداف', RouteNames.personalSavings),
  MapEntry('هدف', RouteNames.personalSavings),
  MapEntry('هدفي', RouteNames.personalSavings),
  MapEntry('ادخار', RouteNames.personalSavings),
  MapEntry('goal', RouteNames.personalSavings),
  MapEntry('saving', RouteNames.personalSavings),
  MapEntry('ديون', RouteNames.personalDebts),
  MapEntry('دين', RouteNames.personalDebts),
  MapEntry('debt', RouteNames.personalDebts),
  MapEntry('تصنيف', RouteNames.personalCategories),
  MapEntry('categor', RouteNames.personalCategories),
  MapEntry('تحويل', RouteNames.personalTransfer),
  MapEntry('transfer', RouteNames.personalTransfer),
  MapEntry('بنوك', RouteNames.personalBanks),
  MapEntry('بنك', RouteNames.personalBanks),
  MapEntry('بنكي', RouteNames.personalBanks),
  MapEntry('bank', RouteNames.personalBanks),
  MapEntry('محفظه', RouteNames.personalTransactions),
  MapEntry('معاملات', RouteNames.personalTransactions),
  MapEntry('عمليات', RouteNames.personalTransactions),
  MapEntry('wallet', RouteNames.personalTransactions),
  MapEntry('transaction', RouteNames.personalTransactions),
  MapEntry('اعدادات', RouteNames.settings),
  MapEntry('settings', RouteNames.settings),
  MapEntry('اشتراك', RouteNames.subscription),
  MapEntry('subscription', RouteNames.subscription),
  MapEntry('اشعارات', RouteNames.notifications),
  MapEntry('notification', RouteNames.notifications),
  MapEntry('الملف الشخصي', RouteNames.profile),
  MapEntry('profile', RouteNames.profile),
  MapEntry('رئيسيه', RouteNames.personalDashboard),
  MapEntry('dashboard', RouteNames.personalDashboard),
  MapEntry('home', RouteNames.personalDashboard),
];

/// The Personal screen [text] names, or null. Keyword table first (covers
/// dialect words), then the live screen catalog's Personal titles (longest
/// title found in the text wins, so screens added later are covered too).
String? saraScreenRouteFromText(String text, {required bool arabic}) {
  final t = _norm(text);
  if (t.trim().isEmpty) return null;
  // Earliest mention wins («افتح الديون… وبعدها البنوك» → الديون).
  final words = t.split(RegExp(r'''[\s,،.؟?!:؛\-_/«»"'()\[\]]+''')).where((w) => w.isNotEmpty).toList();
  int? bestAt;
  String? best;
  for (final e in _keywords) {
    final kw = _norm(e.key);
    int at = -1;
    if (kw.contains(' ')) {
      final i = t.indexOf(kw);
      // Phrase position in words ≈ words before it.
      if (i >= 0) at = t.substring(0, i).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    } else {
      for (var i = 0; i < words.length; i++) {
        if (_wordForms(words[i]).any((f) => f == kw || (kw.length >= 4 && f.startsWith(kw)))) {
          at = i;
          break;
        }
      }
    }
    if (at >= 0 && (bestAt == null || at < bestAt)) {
      bestAt = at;
      best = e.value;
    }
  }
  if (best != null) return best;
  String? catalogRoute;
  var longest = 0;
  for (final entry in SaraScreenCatalog.entries(arabic: arabic)) {
    final route = entry['route'] ?? '';
    final title = _norm((entry['title'] ?? '').trim());
    if (!route.startsWith('/personal') || route.contains('?') || route.endsWith('/')) continue;
    if (title.length < 3 || !t.contains(title)) continue;
    if (title.length > longest) {
      longest = title.length;
      catalogRoute = route;
    }
  }
  return catalogRoute;
}

/// A word and its forms without Arabic clitic prefixes.
Iterable<String> _wordForms(String w) sync* {
  yield w;
  const prefixes = ['وال', 'بال', 'فال', 'كال', 'لل', 'ال', 'و', 'ب', 'ل', 'ف'];
  for (final p in prefixes) {
    if (w.startsWith(p) && w.length - p.length >= 3) yield w.substring(p.length);
  }
}

String _titleFor(String route, {required bool arabic}) {
  for (final entry in SaraScreenCatalog.entries(arabic: arabic)) {
    if (entry['route'] == route && (entry['title'] ?? '').trim().isNotEmpty) {
      return entry['title']!.trim();
    }
  }
  const fallbackAr = {
    RouteNames.personalBanks: 'البنوك',
    RouteNames.personalTransactions: 'المحفظة',
    RouteNames.personalBudget: 'الميزانية',
    RouteNames.personalSavings: 'الأهداف',
    RouteNames.personalDebts: 'الديون',
    RouteNames.personalRecurring: 'المتكررة',
    RouteNames.personalCategories: 'التصنيفات',
    RouteNames.personalTransfer: 'التحويلات',
    saraPersonalReportsRoute: 'التقارير',
  };
  const fallbackEn = {
    RouteNames.personalBanks: 'Banks',
    RouteNames.personalTransactions: 'Wallet',
    RouteNames.personalBudget: 'Budget',
    RouteNames.personalSavings: 'Goals',
    RouteNames.personalDebts: 'Debts',
    RouteNames.personalRecurring: 'Recurring',
    RouteNames.personalCategories: 'Categories',
    RouteNames.personalTransfer: 'Transfers',
    saraPersonalReportsRoute: 'Reports',
  };
  return (arabic ? fallbackAr : fallbackEn)[route] ?? route;
}
