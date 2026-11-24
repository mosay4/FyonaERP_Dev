import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/features/ai/domain/agent/sara_screen_catalog.dart';
import 'package:fyona_flutter/features/core_business/presentation/providers/local_commerce_navigation.dart';

/// Supported action types that Sara can execute.
enum SaraActionType {
  openScreen,
  goBack,
  createEntity,
  exportPdf,
  showSnackbar,
  copyText,
  refreshData,
  navigateToTab,
  openUrl,
  showDialog,
  openEntity,
}

/// A single action parsed from the AI agent response.
class SaraAction {
  final SaraActionType type;
  final Map<String, dynamic> params;
  final String? label;

  const SaraAction({required this.type, this.params = const {}, this.label});

  factory SaraAction.fromJson(Map<String, dynamic> json) {
    final actionStr = json['action'] as String? ?? '';
    final type = _parseActionType(actionStr);
    return SaraAction(
      type: type,
      params: json['params'] as Map<String, dynamic>? ?? {},
      label: json['label'] as String?,
    );
  }

  static SaraActionType _parseActionType(String action) {
    switch (action) {
      case 'open_screen': return SaraActionType.openScreen;
      case 'go_back': return SaraActionType.goBack;
      case 'create_entity': return SaraActionType.createEntity;
      case 'export_pdf': return SaraActionType.exportPdf;
      case 'show_snackbar': return SaraActionType.showSnackbar;
      case 'copy_text': return SaraActionType.copyText;
      case 'refresh_data': return SaraActionType.refreshData;
      case 'navigate_to_tab': return SaraActionType.navigateToTab;
      case 'open_url': return SaraActionType.openUrl;
      case 'show_dialog': return SaraActionType.showDialog;
      case 'open_entity': return SaraActionType.openEntity;
      default: return SaraActionType.openScreen;
    }
  }
}

/// Route mapping for deep links from Sara (Arabic + English).
const _routeMap = <String, String>{
  'البنوك': RouteNames.personalBanks, 'Banks': RouteNames.personalBanks, 'bank': RouteNames.personalBanks,
  'المحفظة': RouteNames.personalTransactions, 'Transactions': RouteNames.personalTransactions, 'transaction': RouteNames.personalTransactions,
  'الميزانية': RouteNames.personalBudget, 'Budget': RouteNames.personalBudget, 'budget': RouteNames.personalBudget,
  'الأهداف': RouteNames.personalSavings, 'Goals': RouteNames.personalSavings, 'goal': RouteNames.personalSavings,
  'التقارير': RouteNames.personalReports, 'Reports': RouteNames.personalReports, 'report': RouteNames.personalReports,
  'الإعدادات': RouteNames.settings, 'Settings': RouteNames.settings, 'setting': RouteNames.settings,
  'الرئيسية': RouteNames.personalDashboard, 'Dashboard': RouteNames.personalDashboard, 'home': RouteNames.personalDashboard,
  // NOTE: analytics intentionally has no entry — financial questions are
  // answered from live data (get_financial_analytics), never via navigation.
  'الديون': RouteNames.personalDebts, 'Debts': RouteNames.personalDebts, 'debt': RouteNames.personalDebts,
  'المعاملات': RouteNames.personalTransactions,
  'المتكررة': RouteNames.personalRecurring, 'Recurring': RouteNames.personalRecurring, 'recurring': RouteNames.personalRecurring,
  'التصنيفات': RouteNames.personalCategories, 'Categories': RouteNames.personalCategories, 'category': RouteNames.personalCategories,
  'التحويلات': RouteNames.personalTransfer, 'Transfer': RouteNames.personalTransfer, 'transfer': RouteNames.personalTransfer,
  'سارة': RouteNames.personalAi, 'Sara': RouteNames.personalAi, 'sara': RouteNames.personalAi,
  'الملف الشخصي': RouteNames.profile, 'Profile': RouteNames.profile, 'profile': RouteNames.profile,
  'الاشتراك': RouteNames.subscription, 'Subscription': RouteNames.subscription, 'subscription': RouteNames.subscription,
  'الإشعارات': RouteNames.notifications, 'Notifications': RouteNames.notifications, 'notification': RouteNames.notifications,
};

/// Opens a screen Sara offered. A screen of one record (a product, an
/// invoice...) on a branch whose data is on this phone opens with the same
/// device target the app's own lists use; a bare link would be refused by the
/// router and land on the home screen.
void openSaraRoute(BuildContext context, String link) {
  final live = SaraScreenCatalog.liveRoute(link.trim());
  final uri = Uri.tryParse(live);
  if (uri != null && commerceDocumentRoutes.containsKey(uri.path)) {
    final query = uri.queryParameters;
    final id = query[uri.path == RouteNames.returnsAdd ? 'invoice' : 'id'];
    final kind = query['kind'] ?? query['type'] ?? query['source'];
    if (id != null && id.isNotEmpty) {
      openCommerceRecord<void>(context, uri.path, id, kind: kind);
      return;
    }
    // No record named: open the screen that lists them.
    context.push(commerceDocumentRoutes[uri.path]!);
    return;
  }
  context.push(live);
}

/// Dispatches actions from Sara AI agent to the Flutter app.
class SaraActionDispatcher {
  final BuildContext context;
  final WidgetRef ref;

  SaraActionDispatcher(this.context, this.ref);

  Future<void> dispatch(SaraAction action) async {
    switch (action.type) {
      case SaraActionType.openScreen:
        _openScreen(action.params);
      case SaraActionType.goBack:
        if (context.mounted) context.pop();
      case SaraActionType.createEntity:
        _openCreateScreen(action.params);
      case SaraActionType.exportPdf:
        _showExport(action.params);
      case SaraActionType.showSnackbar:
        _showSnackbar(action.params);
      case SaraActionType.copyText:
        _copyText(action.params);
      case SaraActionType.refreshData:
        // Triggers a refresh - the provider will handle it
        break;
      case SaraActionType.navigateToTab:
        _navigateToTab(action.params);
      case SaraActionType.openUrl:
        _openUrl(action.params);
      case SaraActionType.showDialog:
        _showDialog(action.params);
      case SaraActionType.openEntity:
        _openEntity(action.params);
    }
  }

  /// Deep navigation — open a specific entity (bank, goal, customer, invoice...).
  void _openEntity(Map<String, dynamic> params) {
    final type = (params['entity_type'] as String? ?? '').trim();
    final name = (params['name'] as String? ?? '').trim();
    final id = (params['id'] as String? ?? '').trim();
    if (type.isEmpty) return;

    String? route;
    dynamic navigateExtra;
    switch (type) {
      case 'bank':
        route = name.isNotEmpty
            ? RouteNames.personalBankDetail.replaceFirst(':bankName', Uri.encodeComponent(name))
            : RouteNames.personalBanks;
      case 'goal':
        route = id.isNotEmpty
            ? RouteNames.personalSavingsDetail.replaceFirst(':goalId', id)
            : RouteNames.personalSavings;
      case 'debt':
        route = id.isNotEmpty
            ? '${RouteNames.personalDebts}/$id'
            : RouteNames.personalDebts;
      case 'account':
      case 'transaction':
        route = id.isNotEmpty
            ? RouteNames.personalAccountDetail.replaceFirst(':id', id)
            : RouteNames.personalTransactions;
      case 'budget':
        route = RouteNames.personalBudget;
      case 'recurring':
        route = RouteNames.personalTransactions;
        navigateExtra = 1;
        break;
    }

    if (route != null && context.mounted) {
      context.push(route, extra: navigateExtra);
    }
  }

  void _openScreen(Map<String, dynamic> params) {
    final screen = (params['screen'] as String? ?? '').trim();
    final directRoute = (params['route'] as String? ?? '').trim();
    if (screen.isEmpty && directRoute.isEmpty) return;

    // Explicit catalog route from the assistant: open it directly (covers
    // every section, including screens added in newer app builds).
    if (directRoute.startsWith('/') && !directRoute.contains(':')) {
      if (context.mounted) openSaraRoute(context, directRoute);
      return;
    }

    // Handle recurring specially - open transactions page with recurring tab
    if (screen.contains('المتكررة') || screen.contains('متكرر')) {
      if (context.mounted) context.push(RouteNames.personalTransactions, extra: 1);
      return;
    }

    // Find route in map
    for (final entry in _routeMap.entries) {
      if (screen.contains(entry.key) || entry.key.contains(screen)) {
        if (context.mounted) context.push(entry.value);
        return;
      }
    }

    // Catalog title fallback (assistant named a screen without a route).
    final catalogRoute = SaraScreenCatalog.routeForTitle(screen,
        arabic: Localizations.localeOf(context).languageCode != 'en');
    if (catalogRoute != null && context.mounted) {
      context.push(catalogRoute);
      return;
    }

    if (directRoute.isNotEmpty && context.mounted) {
      context.push(directRoute);
    }
  }

  void _openCreateScreen(Map<String, dynamic> params) {
    final type = params['entity_type'] as String? ?? '';
    switch (type) {
      case 'bank':
        if (context.mounted) context.push(RouteNames.personalBanks);
      case 'goal':
        if (context.mounted) context.push(RouteNames.personalSavings);
      default:
        // Fallback to opening the relevant list page
        _openScreen({'screen': type});
    }
  }

  void _showExport(Map<String, dynamic> params) {
    _showSnackbar({'message': 'جاري تحضير التقرير للتصدير...'});
  }

  void _showSnackbar(Map<String, dynamic> params) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        params['message'] as String? ?? '',
        style: const TextStyle(fontFamily: 'Cairo'),
      ),
      backgroundColor: const Color(0xFF171717),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  void _copyText(Map<String, dynamic> params) {
    final text = params['text'] as String? ?? '';
    if (text.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: text));
      _showSnackbar({'message': 'تم النسخ'});
    }
  }

  void _navigateToTab(Map<String, dynamic> params) {
    final tab = params['tab'] as String? ?? '';
    if (tab == 'wallet' && context.mounted) context.push(RouteNames.personalTransactions);
  }

  void _openUrl(Map<String, dynamic> params) async {
    final url = params['url'] as String? ?? '';
    if (url.isNotEmpty) {
      final uri = Uri.tryParse(url);
      if (uri != null && await canLaunchUrl(uri)) {
        await launchUrl(uri);
      }
    }
  }

  void _showDialog(Map<String, dynamic> params) {
    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF171717),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          params['title'] as String? ?? '',
          style: const TextStyle(fontFamily: 'Cairo', color: Colors.white),
        ),
        content: Text(
          params['message'] as String? ?? '',
          style: const TextStyle(fontFamily: 'Cairo', color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('حسناً', style: TextStyle(fontFamily: 'Cairo', color: Color(0xFFA01530))),
          ),
        ],
      ),
    );
  }

  /// Resolve a screen name to a GoRouter route using exact key matching.
  static String? resolveRoute(String screenName) {
    // Try exact match first
    if (_routeMap.containsKey(screenName)) return _routeMap[screenName];
    // Then try word-level matching (split on whitespace/punctuation)
    final words = screenName.split(RegExp(r'[\s,،.؟\n]+'));
    for (final entry in _routeMap.entries) {
      if (words.contains(entry.key)) return entry.value;
    }
    return null;
  }

  /// Resolve route from the first [openScreen] or [openEntity] action in the list.
  static String? resolveRouteFromActions(List<SaraAction> actions) {
    for (final action in actions) {
      if (action.type == SaraActionType.openScreen) {
        // The route Sara chose from the live catalog wins over guessing from
        // the button's title (a title like «البنوك» exists in both sections).
        final route = (action.params['route'] as String? ?? '').trim();
        if (route.startsWith('/') && !route.contains(':')) {
          return SaraScreenCatalog.liveRoute(route);
        }
        final screen = (action.params['screen'] as String? ?? '').trim();
        if (screen.isNotEmpty) return resolveRoute(screen);
      }
      if (action.type == SaraActionType.openEntity) {
        final params = action.params;
        final type = (params['entity_type'] as String? ?? '').trim();
        final name = (params['name'] as String? ?? '').trim();
        final id = (params['id'] as String? ?? '').trim();
        switch (type) {
          case 'bank':
            return name.isNotEmpty
                ? RouteNames.personalBankDetail.replaceFirst(':bankName', Uri.encodeComponent(name))
                : RouteNames.personalBanks;
          case 'goal':
            return id.isNotEmpty
                ? RouteNames.personalSavingsDetail.replaceFirst(':goalId', id)
                : RouteNames.personalSavings;
          case 'debt':
            return id.isNotEmpty
                ? '${RouteNames.personalDebts}/$id'
                : RouteNames.personalDebts;
          case 'account':
          case 'transaction':
            return id.isNotEmpty
                ? RouteNames.personalAccountDetail.replaceFirst(':id', id)
                : RouteNames.personalTransactions;
          case 'budget':
            return RouteNames.personalBudget;
          case 'recurring':
            return RouteNames.personalTransactions;
        }
      }
    }
    return null;
  }
}
