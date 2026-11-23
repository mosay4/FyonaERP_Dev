import 'package:flutter_test/flutter_test.dart';

import 'package:fyona_flutter/core/help/help_content.dart';
import 'package:fyona_flutter/features/ai/domain/agent/sara_screen_catalog.dart';

/// Sara's live screen catalog: every route the installed app ships must be
/// streamed to the assistant so she can explain and open any section —
/// including screens added in newer builds — with no backend update.
void main() {
  test('catalog covers the whole app with unique routes', () {
    final ar = SaraScreenCatalog.entries(arabic: true);
    expect(ar.length, greaterThanOrEqualTo(80));
    final routes = ar.map((e) => e['route'] ?? '').toList();
    expect(routes.toSet().length, routes.length);
    expect(routes.every((r) => r.startsWith('/')), isTrue);
    expect(routes.any((r) => r.contains(':')), isFalse);
  });

  test('catalog carries bilingual titles and summaries', () {
    final ar = SaraScreenCatalog.entries(arabic: true);
    final banks = ar.firstWhere((e) => e['route'] == '/personal/banks');
    expect(banks['title'], 'البنوك');
    expect((banks['summary'] ?? '').isNotEmpty, isTrue);

    final en = SaraScreenCatalog.entries(arabic: false);
    final customers = en.firstWhere((e) => e['route'] == '/customers');
    expect(customers['title'], 'Customers');
  });

  test('key sections and future screens resolve to routes', () {
    expect(SaraScreenCatalog.routeForTitle('البنوك', arabic: true),
        '/personal/banks');
    expect(SaraScreenCatalog.routeForTitle('نقطة البيع', arabic: true), '/pos');
    expect(SaraScreenCatalog.routeForTitle('Point of Sale', arabic: false),
        '/pos');
    expect(SaraScreenCatalog.routeForTitle('المشاريع', arabic: true),
        '/projects');
  });

  test('HelpContent.catalog skips parameterized routes', () {
    final all = HelpContent.catalog(arabic: true);
    expect(all, isNotEmpty);
    expect(all.every((e) => !(e['route'] ?? '').contains(':')), isTrue);
    expect(all.any((e) => e['route'] == '/personal/transfer'), isTrue);
  });
}
