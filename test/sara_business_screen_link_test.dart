import 'package:flutter_test/flutter_test.dart';

import 'package:fyona_flutter/features/ai/domain/agent/sara_link_fallback.dart';
import 'package:fyona_flutter/features/ai/domain/agent/sara_screen_catalog.dart';
import 'package:fyona_flutter/shared/widgets/sara_action_dispatcher.dart';

/// Business Sara: «افتح البنوك» answered «اضغط الزر لفتح شاشة البنوك» with
/// no button — the safety net ran for Personal only. Every Business screen
/// Sara speaks of now comes with its button, in the Business section.
void main() {
  String? route(String q, {bool ar = true}) => saraScreenRouteFromText(q, arabic: ar, business: true);

  test('Business words open Business screens', () {
    const cases = {
      'افتح البنوك': '/banks',
      'افتح الصندوق': '/banks',
      'ودني للخزينة': '/banks',
      'افتح الديون': '/debts',
      'ابي ديون العملاء': '/debts/customers',
      'افتح العملاء': '/customers',
      'افتح الموردين': '/suppliers',
      'افتح المنتجات': '/inventory',
      'افتح المخزون': '/inventory',
      'افتح الفواتير': '/invoices',
      'افتح التقارير': '/reports',
      'وديني للتقارير': '/reports',
      'افتح المطابقة': '/reconciliation',
      'افتح الموظفين': '/employees',
      'افتح الفروع': '/branches',
      'افتح الإعدادات': '/settings',
      'افتح المصروفات': '/business/income-expense',
    };
    cases.forEach((q, r) => expect(route(q), r, reason: q));
    expect(route('open the banks', ar: false), '/banks');
    expect(route('open suppliers', ar: false), '/suppliers');
    expect(route('open the cash box', ar: false), '/banks');
  });

  test('the missing banks button is attached in Business, never the Personal one', () {
    final out = saraEnsureScreenAction(
      userQuery: 'open the banks',
      reply: 'Press the button to open the banks screen.',
      actions: const [],
      arabic: false,
      business: true,
    );
    expect(out, hasLength(1));
    expect(out.first.type, SaraActionType.openScreen);
    expect(out.first.params['route'], '/banks');
    expect(out.first.label, 'Open Banks');
    expect(SaraActionDispatcher.resolveRouteFromActions(out), '/banks');

    final personal = saraEnsureScreenAction(
        userQuery: 'افتح البنوك', reply: 'اضغط الزر', actions: const [], arabic: true);
    expect(personal.first.params['route'], '/personal/banks');
  });

  test('an existing navigation action is kept; small talk gets no button', () {
    const nav = SaraAction(type: SaraActionType.openScreen, params: {'route': '/customers'});
    expect(saraEnsureScreenAction(userQuery: 'افتح البنوك', reply: 'تفضل', actions: const [nav],
        arabic: true, business: true), const [nav]);
    expect(saraEnsureScreenAction(userQuery: 'كم ربحت اليوم؟', reply: 'ربحت 500',
        actions: const [], arabic: true, business: true), isEmpty);
  });

  test('every Business screen Sara may open is in the live catalog with a title', () {
    final ar = {for (final e in SaraScreenCatalog.entries(arabic: true)) e['route']: e['title']};
    final en = {for (final e in SaraScreenCatalog.entries(arabic: false)) e['route']: e['title']};
    for (final r in ['/banks', '/debts', '/customers', '/suppliers', '/inventory', '/invoices',
        '/reports', '/reconciliation', '/employees', '/branches', '/settings',
        '/business/income-expense', '/inventory/categories', '/branches/transfers']) {
      expect(ar[r], isNotNull, reason: r);
      expect(en[r], isNotNull, reason: r);
    }
  });
}
