// Sara's REAL answers (recorded from DeepSeek through FYONA's own import
// endpoints on 2026-11-28, support/sara_live/answers.json) shown in the
// import window: «تحليل سارة» in the header, her changes marked on each
// table with an undo — no chat window. Also: Sara unreachable shows a
// clear state with «إعادة المحاولة» while manual editing stays possible.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/import/import_plan.dart';
import 'package:fyona_flutter/core/import/import_session.dart';
import 'package:fyona_flutter/core/import/import_source.dart';
import 'package:fyona_flutter/core/import/presentation/smart_import_page.dart';
import 'package:fyona_flutter/core/import/sara_mapping.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/services/currency/business_currency_scope.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart' show currencyLabel;
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';

DirectoryAccess _scope() => DirectoryAccess(
      workspace: DirectoryWorkspace(
          server: 'https://x.test/api/v1',
          accountId: '11111111-1111-4111-8111-111111111111',
          organizationId: '22222222-2222-4222-8222-222222222222'),
      branchId: '33333333-3333-4333-8333-333333333333',
      readable: DirectoryPartyKind.values.toSet(),
      writable: DirectoryPartyKind.values.toSet(),
      financialCutover: true,
    );

final _answers = jsonDecode(File('test/import/support/sara_live/answers.json').readAsStringSync()) as Map<String, dynamic>;

SaraAgentAnswer _agent(String message) {
  final a = (_answers['agent'] as Map)[message] as Map;
  return SaraAgentAnswer('${a['reply']}', [for (final o in a['ops'] as List) Map<String, dynamic>.from(o as Map)]);
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<void> open(WidgetTester tester, File f, {required bool online}) async {
    tester.view.physicalSize = const Size(1080, 2316);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await AppLocalizations.preload('ar');
      await tester.pumpWidget(ProviderScope(
        overrides: [
          businessLocalLedgerScopeProvider.overrideWithValue(_scope()),
          bizEnabledCurrenciesProvider.overrideWith((ref) async => {'SAR', 'USD', 'YER_NEW'}),
          smartImportBranchesProvider.overrideWith((ref) async => const []),
          smartImportSaraProvider.overrideWithValue(SmartImportSara(
            schema: (t) async => online
                ? [for (final x in _answers['schema'] as List) Map<String, dynamic>.from(x as Map)]
                : null,
            agent: (m, s) async => online ? _agent(m) : null,
          )),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: SmartImportPage(initialFile: f),
        ),
      ));
      for (var i = 0; i < 100 && find.byKey(const Key('si-review')).evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    });
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Until Sara's work (real file reads) is over and the window settled.
  Future<void> wait(WidgetTester tester) async {
    bool working() =>
        find.byKey(const Key('si-sara-status')).evaluate().isNotEmpty &&
        tester.widget<Text>(find.byKey(const Key('si-sara-status'))).data == 'سارة تفحص الملف…';
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
      if (i > 2 && !working()) break;
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('«فحص بواسطة سارة» and her real answers change the window', (tester) async {
    final dir = Directory.systemTemp.createTempSync('fyona-sara-live-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('test/import/support/sara_live/messy-en.db').copySync('${dir.path}/messy-en.db');
    await open(tester, f, online: true);
    expect(find.byKey(const Key('si-sara-check')), findsOneWidget);
    expect(find.byType(SaraAvatar), findsWidgets); // her picture, not stars
    // The four sections found; invoices, staff and branches not imported.
    for (final t in ['tblMstItm', 'tbl_cust_master', 'VendorsList', 'CashAndBank']) {
      await tester.scrollUntilVisible(find.byKey(Key('si-table-$t')), 120, scrollable: find.byType(Scrollable).first);
      expect(find.byKey(Key('si-table-$t')), findsOneWidget);
    }
    await tester.scrollUntilVisible(find.byKey(const Key('si-excluded')), 120, scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 4000)); // back to the top
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const Key('si-sara-check')));
    await wait(tester);
    // Her result in one line; every table she changed is marked «عدّلته
    // سارة» with «تراجع» back to the system's arrangement (no chat).
    expect(find.textContaining(RegExp('فحصت سارة|سارة عدّلت')), findsOneWidget);
    expect(find.byKey(const Key('si-sara-ask')), findsNothing);
    Finder keyed(String prefix) => find.byWidgetPredicate(
        (w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith(prefix));
    final marked = keyed('si-bysara-');
    if (marked.evaluate().isNotEmpty) {
      final name = (marked.evaluate().first.widget.key as ValueKey<String>).value.substring('si-bysara-'.length);
      final undo = find.byKey(Key('si-sara-undo-$name'));
      await tester.ensureVisible(undo);
      await tester.tap(undo);
      await wait(tester);
      expect(find.byKey(Key('si-bysara-$name')), findsNothing);
      expect(find.text('رجع الجدول لترتيب النظام'), findsOneWidget);
    }
  });

  testWidgets('Sara unreachable: a clear state, «إعادة المحاولة», manual tools still there', (tester) async {
    final dir = Directory.systemTemp.createTempSync('fyona-sara-off-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('test/import/support/sara_live/messy-en.db').copySync('${dir.path}/messy-en.db');
    await open(tester, f, online: false);
    await tester.tap(find.byKey(const Key('si-sara-check')));
    await wait(tester);
    expect(find.text('إعادة المحاولة'), findsOneWidget);
    expect(find.textContaining('تعذّر الوصول إلى سارة'), findsOneWidget);
    // Manual tools stay: any table can be put in its place by hand (here
    // the items table, which the rules alone could not be sure of).
    // (the message goes away by itself; here it is closed to reach the list)
    ScaffoldMessenger.of(tester.element(find.byKey(const Key('si-review')))).hideCurrentSnackBar();
    await tester.pump(const Duration(milliseconds: 600));
    final dest = find.byKey(const Key('si-dest-tblMstItm'));
    final list = find.byType(Scrollable).first;
    // Look through the whole check (top to bottom), opening the "not
    // imported" group when the table is there.
    Future<bool> look() async {
      await tester.drag(list, const Offset(0, 6000));
      await tester.pump(const Duration(milliseconds: 300));
      for (var i = 0; i < 60 && dest.evaluate().isEmpty; i++) {
        await tester.drag(list, const Offset(0, -150));
        await tester.pump(const Duration(milliseconds: 80));
      }
      return dest.evaluate().isNotEmpty;
    }

    if (!await look()) {
      await tester.tap(find.byKey(const Key('si-excluded')));
      await tester.pump(const Duration(milliseconds: 400));
      await look();
    }
    expect(dest, findsOneWidget);
    expect(find.byKey(const Key('si-review')), findsOneWidget);
  });

  testWidgets('her currency answer reaches the review: only rows without a currency become USD', (tester) async {
    final f = File('test/import/support/sara_live/messy-en.db');
    final s = (await tester.runAsync(() async {
      final s = await ImportSession.analyze(await readImportFile(f), enabled: {'SAR', 'USD', 'YER_NEW'});
      await s.applySara([for (final x in _answers['schema'] as List) Map<String, dynamic>.from(x as Map)]);
      await s.buildReviews();
      await s.applyOps(_agent('أسعار المنتجات اللي ما لها عملة بالدولار').ops);
      return s;
    }))!;
    final products = s.reviews.entries.firstWhere((e) => e.key.table.name == 'tblMstItm').value;
    // No currency was assumed: before Sara, the rows without one waited.
    expect(products.rows.every((r) => r['currency'] == 'USD'), isTrue);
    expect(products.refusedByReason['needs_currency'], isNull);
    final p = products.toPreview().products;
    expect(p.every((x) => x.currency == 'USD' && x.prices.first['currency'] == 'USD'), isTrue);
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    tester.view.physicalSize = const Size(1080, 2316);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      // The app's buttons ask for infinite width: the review must still lay out.
      theme: ThemeData(
          filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 52)))),
      home: Scaffold(body: ImportReviewView(review: products, onChanged: () {})),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('si-rows')), findsOneWidget);
    expect(find.textContaining(currencyLabel('USD')), findsWidgets);
    expect(importFields[ImportTarget.products]!.any((x) => x.key == 'sku'), isFalse);
  });
}
